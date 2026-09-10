//! linalg — matrix linear algebra.
//!
//! Zig port of Free42's `common/core_linalg1.cc` and `common/core_linalg2.cc`:
//! LU decomposition (real + complex), back-substitution, matrix multiply,
//! solve (`/`), inverse, and determinant.
//!
//! The C++ original threads an interruptibility callback through every
//! function (the `STATE(s)` / `goto suspend` / `completion` machinery) so the
//! EXIT key can abort a long computation. The MCP/AI driver has no EXIT key,
//! so this port drops that machinery entirely and computes directly, returning
//! `Err` on failure.
//!
//! The public entry points take the DB48X-grade nested-array `Vartype` (a
//! matrix is an array of arrays) and extract a flat row-major buffer for the
//! LU core, then rebuild the nested array on the way out. Real matrices are
//! `data[i*n+j]`; complex matrices are interleaved (re, im) pairs,
//! `data[2*(i*n+j)]` = re and `data[2*(i*n+j)+1]` = im.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");

const Err = globals.Err;
const Vartype = vartype.Vartype;

const alloc = std.heap.c_allocator;

/// Flat real matrix (row-major). Private working representation for the LU
/// core; the public surface is the nested-array `Vartype`.
const RealMatrix = struct {
    rows: i32,
    columns: i32,
    data: []phloat.Phloat,
};

/// Flat complex matrix (interleaved re/im). Private working representation.
const ComplexMatrix = struct {
    rows: i32,
    columns: i32,
    data: []phloat.Phloat,
};

// ---------------------------------------------------------------------------
// Local helpers
// ---------------------------------------------------------------------------

/// `p_isinf`: -1 for -Inf, 0 for finite, +1 for +Inf.
fn pIsinf(p: phloat.Phloat) i32 {
    if (!phloat.isInf(p)) return 0;
    return if (phloat.isNegative(p)) -1 else 1;
}

/// Clamp an infinite matrix-multiply sum to ±huge, or report out-of-range.
/// (Matches the `p_isinf(sum)` check in `matrix_mul_*_worker`.)
fn clampInf(sum: phloat.Phloat, out: *phloat.Phloat) Err {
    const inf = pIsinf(sum);
    if (inf == 0) {
        out.* = sum;
        return .none;
    }
    if (globals.settings.matrix_outofrange and !globals.flags.range_error_ignore)
        return .out_of_range;
    out.* = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
    return .none;
}

/// Clamp a back-substitution division result. Unlike `clampInf`, this also
/// catches NaN (a NaN pivot produces a NaN quotient, which the C++ original
/// folds to +huge).
fn clampDiv(t: phloat.Phloat, out: *phloat.Phloat) Err {
    const inf = pIsinf(t);
    if (inf == 0 and !phloat.isNaN(t)) {
        out.* = t;
        return .none;
    }
    if (globals.settings.matrix_outofrange and !globals.flags.range_error_ignore)
        return .out_of_range;
    out.* = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
    return .none;
}

/// `sum -= x * y` for complex values (matches the `sum_re -= xre*yre - xim*yim;
/// sum_im -= xim*yre + xre*yim;` pattern throughout the C++ original).
fn csubmul(sum_re: *phloat.Phloat, sum_im: *phloat.Phloat, xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat) void {
    sum_re.* = phloat.sub(sum_re.*, phloat.sub(phloat.mul(xre, yre), phloat.mul(xim, yim)));
    sum_im.* = phloat.sub(sum_im.*, phloat.add(phloat.mul(xim, yre), phloat.mul(xre, yim)));
}

/// The "tiniest" zero-pivot substitute: 1e20 / POS_HUGE (≈ 1e-6124).
fn tiniestPivot() phloat.Phloat {
    return phloat.div(phloat.fromString("1e20"), phloat.POS_HUGE);
}

/// The zero-pivot substitute for a column whose max magnitude is `scale`:
/// about 10^-20 times the column max, floored at `tiniestPivot()`.
fn tinyPivot(scale: phloat.Phloat) phloat.Phloat {
    const tiniest = tiniestPivot();
    if (phloat.isZero(scale)) return tiniest;
    const tiny = phloat.pow(phloat.fromInt(10), phloat.sub(phloat.floor(phloat.log10(scale)), phloat.fromInt(20)));
    return if (phloat.lt(tiny, tiniest)) tiniest else tiny;
}

// ---------------------------------------------------------------------------
// Nested-array ↔ flat-buffer conversion
// ---------------------------------------------------------------------------

/// Extract a real matrix (2D all-real numeric array) into a flat buffer.
/// Returns null if `v` is not a real matrix or on allocation failure.
fn extractReal(v: *const Vartype) ?RealMatrix {
    const info = vartype.matrixInfo(v) orelse return null;
    if (info.is_complex) return null;
    const a = v.array;
    const data = alloc.alloc(phloat.Phloat, @intCast(info.rows * info.columns)) catch return null;
    var i: i32 = 0;
    while (i < info.rows) : (i += 1) {
        const row = a.data[@intCast(i)].?.array;
        var j: i32 = 0;
        while (j < info.columns) : (j += 1) {
            data[@intCast(i * info.columns + j)] = row.data[@intCast(j)].?.real;
        }
    }
    return .{ .rows = info.rows, .columns = info.columns, .data = data };
}

/// Extract a complex matrix (2D numeric array, any complex) into a flat
/// interleaved buffer. Returns null if `v` is not a matrix or on allocation
/// failure.
fn extractComplex(v: *const Vartype) ?ComplexMatrix {
    const info = vartype.matrixInfo(v) orelse return null;
    const a = v.array;
    const data = alloc.alloc(phloat.Phloat, @intCast(2 * info.rows * info.columns)) catch return null;
    var i: i32 = 0;
    while (i < info.rows) : (i += 1) {
        const row = a.data[@intCast(i)].?.array;
        var j: i32 = 0;
        while (j < info.columns) : (j += 1) {
            const elem = row.data[@intCast(j)].?;
            switch (elem.*) {
                .real => |x| {
                    data[@intCast(2 * (i * info.columns + j))] = x;
                    data[@intCast(2 * (i * info.columns + j) + 1)] = phloat.fromInt(0);
                },
                .complex => |c| {
                    data[@intCast(2 * (i * info.columns + j))] = c.re;
                    data[@intCast(2 * (i * info.columns + j) + 1)] = c.im;
                },
                else => unreachable,
            }
        }
    }
    return .{ .rows = info.rows, .columns = info.columns, .data = data };
}

/// Rebuild a nested array (array of arrays of reals) from a flat real matrix.
fn rebuildReal(m: RealMatrix) ?*Vartype {
    const a = vartype.newArray(m.rows) orelse return null;
    errdefer vartype.free(a);
    var i: i32 = 0;
    while (i < m.rows) : (i += 1) {
        const row = vartype.newArray(m.columns) orelse return null;
        a.array.data[@intCast(i)] = row;
        var j: i32 = 0;
        while (j < m.columns) : (j += 1) {
            row.array.data[@intCast(j)] = vartype.newReal(m.data[@intCast(i * m.columns + j)]) orelse return null;
        }
    }
    return a;
}

/// Rebuild a nested array (array of arrays of complexes) from a flat complex
/// matrix.
fn rebuildComplex(m: ComplexMatrix) ?*Vartype {
    const a = vartype.newArray(m.rows) orelse return null;
    errdefer vartype.free(a);
    var i: i32 = 0;
    while (i < m.rows) : (i += 1) {
        const row = vartype.newArray(m.columns) orelse return null;
        a.array.data[@intCast(i)] = row;
        var j: i32 = 0;
        while (j < m.columns) : (j += 1) {
            row.array.data[@intCast(j)] = vartype.newComplex(m.data[@intCast(2 * (i * m.columns + j))], m.data[@intCast(2 * (i * m.columns + j) + 1)]) orelse return null;
        }
    }
    return a;
}

// ---------------------------------------------------------------------------
// LU decomposition
// ---------------------------------------------------------------------------

/// In-place LU decomposition of a real matrix (Crout's algorithm with partial
/// pivoting). `perm` (length `n`) receives the row permutation; `det` receives
/// the determinant. On a zero pivot, either reports `.singular_matrix` (when
/// `settings.matrix_singularmatrix`) or substitutes a tiny value.
pub fn luDecompR(a: *RealMatrix, perm: []i32, det: *phloat.Phloat) Err {
    const n = a.rows;
    const data = a.data;
    const scale = alloc.alloc(phloat.Phloat, @intCast(n)) catch return .insufficient_memory;
    defer alloc.free(scale);

    det.* = phloat.fromInt(1);

    var i: i32 = 0;
    while (i < n) : (i += 1) {
        var max = phloat.fromInt(0);
        var j: i32 = 0;
        while (j < n) : (j += 1) {
            var tmp = data[@intCast(i * n + j)];
            if (phloat.isNegative(tmp)) tmp = phloat.neg(tmp);
            if (phloat.gt(tmp, max)) max = tmp;
        }
        scale[@intCast(i)] = max;
    }

    var j: i32 = 0;
    while (j < n) : (j += 1) {
        i = 0;
        while (i < j) : (i += 1) {
            var sum = data[@intCast(i * n + j)];
            var k: i32 = 0;
            while (k < i) : (k += 1) {
                sum = phloat.sub(sum, phloat.mul(data[@intCast(i * n + k)], data[@intCast(k * n + j)]));
            }
            data[@intCast(i * n + j)] = sum;
        }

        var max = phloat.fromInt(0);
        var imax = j;
        i = j;
        while (i < n) : (i += 1) {
            var sum = data[@intCast(i * n + j)];
            var k: i32 = 0;
            while (k < j) : (k += 1) {
                sum = phloat.sub(sum, phloat.mul(data[@intCast(i * n + k)], data[@intCast(k * n + j)]));
            }
            data[@intCast(i * n + j)] = sum;
            if (phloat.isZero(scale[@intCast(i)])) {
                imax = i;
                break;
            }
            const tmp = phloat.div(if (phloat.isNegative(sum)) phloat.neg(sum) else sum, scale[@intCast(i)]);
            if (phloat.gt(tmp, max)) {
                imax = i;
                max = tmp;
            }
        }

        if (j != imax) {
            var k: i32 = 0;
            while (k < n) : (k += 1) {
                const tmp = data[@intCast(imax * n + k)];
                data[@intCast(imax * n + k)] = data[@intCast(j * n + k)];
                data[@intCast(j * n + k)] = tmp;
            }
            det.* = phloat.neg(det.*);
            scale[@intCast(imax)] = scale[@intCast(j)];
        }

        perm[@intCast(j)] = imax;
        if (phloat.isZero(data[@intCast(j * n + j)])) {
            if (globals.settings.matrix_singularmatrix) {
                return .singular_matrix;
            } else {
                data[@intCast(j * n + j)] = tinyPivot(scale[@intCast(j)]);
            }
        }
        det.* = phloat.mul(det.*, data[@intCast(j * n + j)]);
        if (j != n - 1) {
            const tmp = phloat.div(phloat.fromInt(1), data[@intCast(j * n + j)]);
            i = j + 1;
            while (i < n) : (i += 1) {
                data[@intCast(i * n + j)] = phloat.mul(data[@intCast(i * n + j)], tmp);
            }
        }
    }

    return .none;
}

/// In-place LU decomposition of a complex matrix. Same algorithm as
/// `luDecompR`, with complex arithmetic and interleaved storage.
pub fn luDecompC(a: *ComplexMatrix, perm: []i32, det_re: *phloat.Phloat, det_im: *phloat.Phloat) Err {
    const n = a.rows;
    const data = a.data;
    const scale = alloc.alloc(phloat.Phloat, @intCast(n)) catch return .insufficient_memory;
    defer alloc.free(scale);

    det_re.* = phloat.fromInt(1);
    det_im.* = phloat.fromInt(0);

    var i: i32 = 0;
    while (i < n) : (i += 1) {
        var max = phloat.fromInt(0);
        var j: i32 = 0;
        while (j < n) : (j += 1) {
            const tmp = phloat.hypot(data[@intCast(2 * (i * n + j))], data[@intCast(2 * (i * n + j) + 1)]);
            if (phloat.gt(tmp, max)) max = tmp;
        }
        scale[@intCast(i)] = max;
    }

    var j: i32 = 0;
    while (j < n) : (j += 1) {
        i = 0;
        while (i < j) : (i += 1) {
            var sum_re = data[@intCast(2 * (i * n + j))];
            var sum_im = data[@intCast(2 * (i * n + j) + 1)];
            var k: i32 = 0;
            while (k < i) : (k += 1) {
                csubmul(&sum_re, &sum_im, data[@intCast(2 * (i * n + k))], data[@intCast(2 * (i * n + k) + 1)], data[@intCast(2 * (k * n + j))], data[@intCast(2 * (k * n + j) + 1)]);
            }
            data[@intCast(2 * (i * n + j))] = sum_re;
            data[@intCast(2 * (i * n + j) + 1)] = sum_im;
        }

        var max = phloat.fromInt(0);
        var imax = j;
        i = j;
        while (i < n) : (i += 1) {
            var sum_re = data[@intCast(2 * (i * n + j))];
            var sum_im = data[@intCast(2 * (i * n + j) + 1)];
            var k: i32 = 0;
            while (k < j) : (k += 1) {
                csubmul(&sum_re, &sum_im, data[@intCast(2 * (i * n + k))], data[@intCast(2 * (i * n + k) + 1)], data[@intCast(2 * (k * n + j))], data[@intCast(2 * (k * n + j) + 1)]);
            }
            data[@intCast(2 * (i * n + j))] = sum_re;
            data[@intCast(2 * (i * n + j) + 1)] = sum_im;
            if (phloat.isZero(scale[@intCast(i)])) {
                imax = i;
                break;
            }
            const tmp = phloat.div(phloat.hypot(sum_re, sum_im), scale[@intCast(i)]);
            if (phloat.gt(tmp, max)) {
                imax = i;
                max = tmp;
            }
        }

        if (j != imax) {
            var k: i32 = 0;
            while (k < n) : (k += 1) {
                var tmp = data[@intCast(2 * (imax * n + k))];
                data[@intCast(2 * (imax * n + k))] = data[@intCast(2 * (j * n + k))];
                data[@intCast(2 * (j * n + k))] = tmp;
                tmp = data[@intCast(2 * (imax * n + k) + 1)];
                data[@intCast(2 * (imax * n + k) + 1)] = data[@intCast(2 * (j * n + k) + 1)];
                data[@intCast(2 * (j * n + k) + 1)] = tmp;
            }
            det_re.* = phloat.neg(det_re.*);
            det_im.* = phloat.neg(det_im.*);
            scale[@intCast(imax)] = scale[@intCast(j)];
        }

        perm[@intCast(j)] = imax;
        var tmp_re = data[@intCast(2 * (j * n + j))];
        var tmp_im = data[@intCast(2 * (j * n + j) + 1)];
        if (phloat.isZero(tmp_re) and phloat.isZero(tmp_im)) {
            if (globals.settings.matrix_singularmatrix) {
                // NOTE: the C++ original returns ERR_NONE with det 0,0 here
                // (unlike the real case, which returns ERR_SINGULAR_MATRIX).
                // We match that quirk faithfully.
                det_re.* = phloat.fromInt(0);
                det_im.* = phloat.fromInt(0);
                return .none;
            } else {
                const tiny = tinyPivot(scale[@intCast(j)]);
                data[@intCast(2 * (j * n + j))] = tiny;
                data[@intCast(2 * (j * n + j) + 1)] = phloat.fromInt(0);
                tmp_re = tiny;
                tmp_im = phloat.fromInt(0);
            }
        }
        const tmp = phloat.sub(phloat.mul(det_re.*, tmp_re), phloat.mul(det_im.*, tmp_im));
        det_im.* = phloat.add(phloat.mul(det_im.*, tmp_re), phloat.mul(det_re.*, tmp_im));
        det_re.* = tmp;
        if (j != n - 1) {
            const mag = phloat.hypot(tmp_re, tmp_im);
            const s_re = phloat.div(tmp_re, phloat.mul(mag, mag));
            const s_im = phloat.neg(phloat.div(tmp_im, phloat.mul(mag, mag)));
            i = j + 1;
            while (i < n) : (i += 1) {
                const xre = data[@intCast(2 * (i * n + j))];
                const xim = data[@intCast(2 * (i * n + j) + 1)];
                data[@intCast(2 * (i * n + j))] = phloat.sub(phloat.mul(xre, s_re), phloat.mul(xim, s_im));
                data[@intCast(2 * (i * n + j) + 1)] = phloat.add(phloat.mul(xim, s_re), phloat.mul(xre, s_im));
            }
        }
    }

    return .none;
}

// ---------------------------------------------------------------------------
// Back-substitution
// ---------------------------------------------------------------------------

/// Solve `a x = b` for a real LU-decomposed `a` and a real `b`, in place on
/// `b`. `perm` is the row permutation from `luDecompR`.
pub fn luBacksubstRR(a: *const RealMatrix, perm: []const i32, b: *RealMatrix) Err {
    const n = a.rows;
    const q = b.columns;
    const adata = a.data;
    const bdata = b.data;

    var k: i32 = 0;
    while (k < q) : (k += 1) {
        var ii: i32 = -1;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            const ll = perm[@intCast(i)];
            var sum = bdata[@intCast(ll * q + k)];
            bdata[@intCast(ll * q + k)] = bdata[@intCast(i * q + k)];
            if (ii != -1) {
                var j: i32 = ii;
                while (j < i) : (j += 1) {
                    sum = phloat.sub(sum, phloat.mul(adata[@intCast(i * n + j)], bdata[@intCast(j * q + k)]));
                }
            } else if (!phloat.isZero(sum)) {
                ii = i;
            }
            bdata[@intCast(i * q + k)] = sum;
        }
        i = n - 1;
        while (i >= 0) : (i -= 1) {
            var sum = bdata[@intCast(i * q + k)];
            var j: i32 = i + 1;
            while (j < n) : (j += 1) {
                sum = phloat.sub(sum, phloat.mul(adata[@intCast(i * n + j)], bdata[@intCast(j * q + k)]));
            }
            var t: phloat.Phloat = undefined;
            const e = clampDiv(phloat.div(sum, adata[@intCast(i * n + i)]), &t);
            if (e != .none) return e;
            bdata[@intCast(i * q + k)] = t;
        }
    }
    return .none;
}

/// Solve `a x = b` for a real LU-decomposed `a` and a complex `b`, in place.
pub fn luBacksubstRC(a: *const RealMatrix, perm: []const i32, b: *ComplexMatrix) Err {
    const n = a.rows;
    const q = b.columns;
    const adata = a.data;
    const bdata = b.data;

    var k: i32 = 0;
    while (k < q) : (k += 1) {
        var ii: i32 = -1;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            const ll = perm[@intCast(i)];
            var sum_re = bdata[@intCast(2 * (ll * q + k))];
            var sum_im = bdata[@intCast(2 * (ll * q + k) + 1)];
            bdata[@intCast(2 * (ll * q + k))] = bdata[@intCast(2 * (i * q + k))];
            bdata[@intCast(2 * (ll * q + k) + 1)] = bdata[@intCast(2 * (i * q + k) + 1)];
            if (ii != -1) {
                var j: i32 = ii;
                while (j < i) : (j += 1) {
                    const tmp = adata[@intCast(i * n + j)];
                    sum_re = phloat.sub(sum_re, phloat.mul(tmp, bdata[@intCast(2 * (j * q + k))]));
                    sum_im = phloat.sub(sum_im, phloat.mul(tmp, bdata[@intCast(2 * (j * q + k) + 1)]));
                }
            } else if (!phloat.isZero(sum_re) or !phloat.isZero(sum_im)) {
                ii = i;
            }
            bdata[@intCast(2 * (i * q + k))] = sum_re;
            bdata[@intCast(2 * (i * q + k) + 1)] = sum_im;
        }
        i = n - 1;
        while (i >= 0) : (i -= 1) {
            var sum_re = bdata[@intCast(2 * (i * q + k))];
            var sum_im = bdata[@intCast(2 * (i * q + k) + 1)];
            var j: i32 = i + 1;
            while (j < n) : (j += 1) {
                const tmp = adata[@intCast(i * n + j)];
                sum_re = phloat.sub(sum_re, phloat.mul(tmp, bdata[@intCast(2 * (j * q + k))]));
                sum_im = phloat.sub(sum_im, phloat.mul(tmp, bdata[@intCast(2 * (j * q + k) + 1)]));
            }
            const tmp = adata[@intCast(i * n + i)];
            var t_re: phloat.Phloat = undefined;
            var t_im: phloat.Phloat = undefined;
            const e1 = clampDiv(phloat.div(sum_re, tmp), &t_re);
            if (e1 != .none) return e1;
            const e2 = clampDiv(phloat.div(sum_im, tmp), &t_im);
            if (e2 != .none) return e2;
            bdata[@intCast(2 * (i * q + k))] = t_re;
            bdata[@intCast(2 * (i * q + k) + 1)] = t_im;
        }
    }
    return .none;
}

/// Solve `a x = b` for a complex LU-decomposed `a` and a complex `b`, in place.
pub fn luBacksubstCC(a: *const ComplexMatrix, perm: []const i32, b: *ComplexMatrix) Err {
    const n = a.rows;
    const q = b.columns;
    const adata = a.data;
    const bdata = b.data;

    var k: i32 = 0;
    while (k < q) : (k += 1) {
        var ii: i32 = -1;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            const ll = perm[@intCast(i)];
            var sum_re = bdata[@intCast(2 * (ll * q + k))];
            var sum_im = bdata[@intCast(2 * (ll * q + k) + 1)];
            bdata[@intCast(2 * (ll * q + k))] = bdata[@intCast(2 * (i * q + k))];
            bdata[@intCast(2 * (ll * q + k) + 1)] = bdata[@intCast(2 * (i * q + k) + 1)];
            if (ii != -1) {
                var j: i32 = ii;
                while (j < i) : (j += 1) {
                    csubmul(&sum_re, &sum_im, adata[@intCast(2 * (i * n + j))], adata[@intCast(2 * (i * n + j) + 1)], bdata[@intCast(2 * (j * q + k))], bdata[@intCast(2 * (j * q + k) + 1)]);
                }
            } else if (!phloat.isZero(sum_re) or !phloat.isZero(sum_im)) {
                ii = i;
            }
            bdata[@intCast(2 * (i * q + k))] = sum_re;
            bdata[@intCast(2 * (i * q + k) + 1)] = sum_im;
        }
        i = n - 1;
        while (i >= 0) : (i -= 1) {
            var sum_re = bdata[@intCast(2 * (i * q + k))];
            var sum_im = bdata[@intCast(2 * (i * q + k) + 1)];
            var j: i32 = i + 1;
            while (j < n) : (j += 1) {
                csubmul(&sum_re, &sum_im, adata[@intCast(2 * (i * n + j))], adata[@intCast(2 * (i * n + j) + 1)], bdata[@intCast(2 * (j * q + k))], bdata[@intCast(2 * (j * q + k) + 1)]);
            }
            const tmp_re = adata[@intCast(2 * (i * n + i))];
            const tmp_im = adata[@intCast(2 * (i * n + i) + 1)];
            const mag = phloat.hypot(tmp_re, tmp_im);
            const s_re = phloat.div(tmp_re, phloat.mul(mag, mag));
            const s_im = phloat.neg(phloat.div(tmp_im, phloat.mul(mag, mag)));
            var t_re: phloat.Phloat = undefined;
            var t_im: phloat.Phloat = undefined;
            const e1 = clampDiv(phloat.sub(phloat.mul(sum_re, s_re), phloat.mul(sum_im, s_im)), &t_re);
            if (e1 != .none) return e1;
            const e2 = clampDiv(phloat.add(phloat.mul(sum_im, s_re), phloat.mul(sum_re, s_im)), &t_im);
            if (e2 != .none) return e2;
            bdata[@intCast(2 * (i * q + k))] = t_re;
            bdata[@intCast(2 * (i * q + k) + 1)] = t_im;
        }
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Matrix multiply
// ---------------------------------------------------------------------------

fn matrixMulRR(left: *const RealMatrix, right: *const RealMatrix, result: *?*Vartype) Err {
    if (left.columns != right.rows) return .dimension_error;
    const m = left.rows;
    const n = right.columns;
    const q = left.columns;
    const data = alloc.alloc(phloat.Phloat, @intCast(m * n)) catch return .insufficient_memory;
    defer alloc.free(data);
    const l = left.data;
    const r = right.data;
    var i: i32 = 0;
    while (i < m) : (i += 1) {
        var j: i32 = 0;
        while (j < n) : (j += 1) {
            var sum = phloat.fromInt(0);
            var k: i32 = 0;
            while (k < q) : (k += 1) {
                sum = phloat.add(sum, phloat.mul(l[@intCast(i * q + k)], r[@intCast(k * n + j)]));
            }
            const e = clampInf(sum, &data[@intCast(i * n + j)]);
            if (e != .none) return e;
        }
    }
    result.* = rebuildReal(.{ .rows = m, .columns = n, .data = data }) orelse return .insufficient_memory;
    return .none;
}

fn matrixMulRC(left: *const RealMatrix, right: *const ComplexMatrix, result: *?*Vartype) Err {
    if (left.columns != right.rows) return .dimension_error;
    const m = left.rows;
    const n = right.columns;
    const q = left.columns;
    const data = alloc.alloc(phloat.Phloat, @intCast(2 * m * n)) catch return .insufficient_memory;
    defer alloc.free(data);
    const l = left.data;
    const r = right.data;
    var i: i32 = 0;
    while (i < m) : (i += 1) {
        var j: i32 = 0;
        while (j < n) : (j += 1) {
            var sum_re = phloat.fromInt(0);
            var sum_im = phloat.fromInt(0);
            var k: i32 = 0;
            while (k < q) : (k += 1) {
                const tmp = l[@intCast(i * q + k)];
                sum_re = phloat.add(sum_re, phloat.mul(tmp, r[@intCast(2 * (k * n + j))]));
                sum_im = phloat.add(sum_im, phloat.mul(tmp, r[@intCast(2 * (k * n + j) + 1)]));
            }
            const e1 = clampInf(sum_re, &data[@intCast(2 * (i * n + j))]);
            if (e1 != .none) return e1;
            const e2 = clampInf(sum_im, &data[@intCast(2 * (i * n + j) + 1)]);
            if (e2 != .none) return e2;
        }
    }
    result.* = rebuildComplex(.{ .rows = m, .columns = n, .data = data }) orelse return .insufficient_memory;
    return .none;
}

fn matrixMulCR(left: *const ComplexMatrix, right: *const RealMatrix, result: *?*Vartype) Err {
    if (left.columns != right.rows) return .dimension_error;
    const m = left.rows;
    const n = right.columns;
    const q = left.columns;
    const data = alloc.alloc(phloat.Phloat, @intCast(2 * m * n)) catch return .insufficient_memory;
    defer alloc.free(data);
    const l = left.data;
    const r = right.data;
    var i: i32 = 0;
    while (i < m) : (i += 1) {
        var j: i32 = 0;
        while (j < n) : (j += 1) {
            var sum_re = phloat.fromInt(0);
            var sum_im = phloat.fromInt(0);
            var k: i32 = 0;
            while (k < q) : (k += 1) {
                const tmp = r[@intCast(k * n + j)];
                sum_re = phloat.add(sum_re, phloat.mul(tmp, l[@intCast(2 * (i * q + k))]));
                sum_im = phloat.add(sum_im, phloat.mul(tmp, l[@intCast(2 * (i * q + k) + 1)]));
            }
            const e1 = clampInf(sum_re, &data[@intCast(2 * (i * n + j))]);
            if (e1 != .none) return e1;
            const e2 = clampInf(sum_im, &data[@intCast(2 * (i * n + j) + 1)]);
            if (e2 != .none) return e2;
        }
    }
    result.* = rebuildComplex(.{ .rows = m, .columns = n, .data = data }) orelse return .insufficient_memory;
    return .none;
}

fn matrixMulCC(left: *const ComplexMatrix, right: *const ComplexMatrix, result: *?*Vartype) Err {
    if (left.columns != right.rows) return .dimension_error;
    const m = left.rows;
    const n = right.columns;
    const q = left.columns;
    const data = alloc.alloc(phloat.Phloat, @intCast(2 * m * n)) catch return .insufficient_memory;
    defer alloc.free(data);
    const l = left.data;
    const r = right.data;
    var i: i32 = 0;
    while (i < m) : (i += 1) {
        var j: i32 = 0;
        while (j < n) : (j += 1) {
            var sum_re = phloat.fromInt(0);
            var sum_im = phloat.fromInt(0);
            var k: i32 = 0;
            while (k < q) : (k += 1) {
                const l_re = l[@intCast(2 * (i * q + k))];
                const l_im = l[@intCast(2 * (i * q + k) + 1)];
                const r_re = r[@intCast(2 * (k * n + j))];
                const r_im = r[@intCast(2 * (k * n + j) + 1)];
                sum_re = phloat.add(sum_re, phloat.sub(phloat.mul(l_re, r_re), phloat.mul(l_im, r_im)));
                sum_im = phloat.add(sum_im, phloat.add(phloat.mul(l_im, r_re), phloat.mul(l_re, r_im)));
            }
            const e1 = clampInf(sum_re, &data[@intCast(2 * (i * n + j))]);
            if (e1 != .none) return e1;
            const e2 = clampInf(sum_im, &data[@intCast(2 * (i * n + j) + 1)]);
            if (e2 != .none) return e2;
        }
    }
    result.* = rebuildComplex(.{ .rows = m, .columns = n, .data = data }) orelse return .insufficient_memory;
    return .none;
}

// ---------------------------------------------------------------------------
// High-level entry points
// ---------------------------------------------------------------------------

/// Matrix-matrix multiplication. Both operands must be matrices (2D numeric
/// arrays); the result type follows the usual real/complex promotion rules.
pub fn linalgMul(left: *const Vartype, right: *const Vartype, result: *?*Vartype) Err {
    const li = vartype.matrixInfo(left) orelse return .invalid_type;
    const ri = vartype.matrixInfo(right) orelse return .invalid_type;
    if (vartype.containsStrings(left) or vartype.containsStrings(right)) return .alpha_data_is_invalid;
    if (!li.is_complex and !ri.is_complex) {
        const lm = extractReal(left) orelse return .insufficient_memory;
        defer alloc.free(lm.data);
        const rm = extractReal(right) orelse return .insufficient_memory;
        defer alloc.free(rm.data);
        return matrixMulRR(&lm, &rm, result);
    } else if (!li.is_complex and ri.is_complex) {
        const lm = extractReal(left) orelse return .insufficient_memory;
        defer alloc.free(lm.data);
        const rm = extractComplex(right) orelse return .insufficient_memory;
        defer alloc.free(rm.data);
        return matrixMulRC(&lm, &rm, result);
    } else if (li.is_complex and !ri.is_complex) {
        const lm = extractComplex(left) orelse return .insufficient_memory;
        defer alloc.free(lm.data);
        const rm = extractReal(right) orelse return .insufficient_memory;
        defer alloc.free(rm.data);
        return matrixMulCR(&lm, &rm, result);
    } else {
        const lm = extractComplex(left) orelse return .insufficient_memory;
        defer alloc.free(lm.data);
        const rm = extractComplex(right) orelse return .insufficient_memory;
        defer alloc.free(rm.data);
        return matrixMulCC(&lm, &rm, result);
    }
}

/// Matrix-matrix division: `left / right` = `left * right^-1`, computed by LU
/// decomposition of `right` followed by back-substitution of `left`.
pub fn linalgDiv(left: *const Vartype, right: *const Vartype, result: *?*Vartype) Err {
    const li = vartype.matrixInfo(left) orelse return .invalid_type;
    const ri = vartype.matrixInfo(right) orelse return .invalid_type;
    if (vartype.containsStrings(left) or vartype.containsStrings(right)) return .alpha_data_is_invalid;
    const rows = li.rows;
    const columns = li.columns;
    if (ri.rows != rows or ri.columns != rows) return .dimension_error;
    const perm = alloc.alloc(i32, @intCast(rows)) catch return .insufficient_memory;
    defer alloc.free(perm);

    if (!li.is_complex and !ri.is_complex) {
        const num = extractReal(left) orelse return .insufficient_memory;
        defer alloc.free(num.data);
        var denom = extractReal(right) orelse return .insufficient_memory;
        defer alloc.free(denom.data);
        var det: phloat.Phloat = undefined;
        const e = luDecompR(&denom, perm, &det);
        if (e != .none) return e;
        var res = RealMatrix{ .rows = rows, .columns = columns, .data = alloc.alloc(phloat.Phloat, @intCast(rows * columns)) catch return .insufficient_memory };
        defer alloc.free(res.data);
        @memcpy(res.data, num.data);
        const e2 = luBacksubstRR(&denom, perm, &res);
        if (e2 != .none) return e2;
        result.* = rebuildReal(res) orelse return .insufficient_memory;
        return .none;
    } else if (!li.is_complex and ri.is_complex) {
        const num = extractReal(left) orelse return .insufficient_memory;
        defer alloc.free(num.data);
        var denom = extractComplex(right) orelse return .insufficient_memory;
        defer alloc.free(denom.data);
        var det_re: phloat.Phloat = undefined;
        var det_im: phloat.Phloat = undefined;
        const e = luDecompC(&denom, perm, &det_re, &det_im);
        if (e != .none) return e;
        var res = ComplexMatrix{ .rows = rows, .columns = columns, .data = alloc.alloc(phloat.Phloat, @intCast(2 * rows * columns)) catch return .insufficient_memory };
        defer alloc.free(res.data);
        var i: i32 = 0;
        while (i < rows * columns) : (i += 1) {
            res.data[@intCast(2 * i)] = num.data[@intCast(i)];
            res.data[@intCast(2 * i + 1)] = phloat.fromInt(0);
        }
        const e2 = luBacksubstCC(&denom, perm, &res);
        if (e2 != .none) return e2;
        result.* = rebuildComplex(res) orelse return .insufficient_memory;
        return .none;
    } else if (li.is_complex and !ri.is_complex) {
        const num = extractComplex(left) orelse return .insufficient_memory;
        defer alloc.free(num.data);
        var denom = extractReal(right) orelse return .insufficient_memory;
        defer alloc.free(denom.data);
        var det: phloat.Phloat = undefined;
        const e = luDecompR(&denom, perm, &det);
        if (e != .none) return e;
        var res = ComplexMatrix{ .rows = rows, .columns = columns, .data = alloc.alloc(phloat.Phloat, @intCast(2 * rows * columns)) catch return .insufficient_memory };
        defer alloc.free(res.data);
        @memcpy(res.data, num.data);
        const e2 = luBacksubstRC(&denom, perm, &res);
        if (e2 != .none) return e2;
        result.* = rebuildComplex(res) orelse return .insufficient_memory;
        return .none;
    } else {
        const num = extractComplex(left) orelse return .insufficient_memory;
        defer alloc.free(num.data);
        var denom = extractComplex(right) orelse return .insufficient_memory;
        defer alloc.free(denom.data);
        var det_re: phloat.Phloat = undefined;
        var det_im: phloat.Phloat = undefined;
        const e = luDecompC(&denom, perm, &det_re, &det_im);
        if (e != .none) return e;
        var res = ComplexMatrix{ .rows = rows, .columns = columns, .data = alloc.alloc(phloat.Phloat, @intCast(2 * rows * columns)) catch return .insufficient_memory };
        defer alloc.free(res.data);
        @memcpy(res.data, num.data);
        const e2 = luBacksubstCC(&denom, perm, &res);
        if (e2 != .none) return e2;
        result.* = rebuildComplex(res) orelse return .insufficient_memory;
        return .none;
    }
}

/// Matrix inverse, computed by LU decomposition followed by back-substitution
/// of the identity matrix.
pub fn linalgInv(src: *const Vartype, result: *?*Vartype) Err {
    const info = vartype.matrixInfo(src) orelse return .invalid_type;
    if (vartype.containsStrings(src)) return .alpha_data_is_invalid;
    const n = info.rows;
    if (n != info.columns) return .dimension_error;
    const perm = alloc.alloc(i32, @intCast(n)) catch return .insufficient_memory;
    defer alloc.free(perm);

    if (!info.is_complex) {
        var ma = extractReal(src) orelse return .insufficient_memory;
        defer alloc.free(ma.data);
        var det: phloat.Phloat = undefined;
        const e = luDecompR(&ma, perm, &det);
        if (e != .none) return e;
        var inv = RealMatrix{ .rows = n, .columns = n, .data = alloc.alloc(phloat.Phloat, @intCast(n * n)) catch return .insufficient_memory };
        defer alloc.free(inv.data);
        @memset(inv.data, phloat.fromInt(0));
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            inv.data[@intCast(i * (n + 1))] = phloat.fromInt(1);
        }
        const e2 = luBacksubstRR(&ma, perm, &inv);
        if (e2 != .none) return e2;
        result.* = rebuildReal(inv) orelse return .insufficient_memory;
        return .none;
    } else {
        var ma = extractComplex(src) orelse return .insufficient_memory;
        defer alloc.free(ma.data);
        var det_re: phloat.Phloat = undefined;
        var det_im: phloat.Phloat = undefined;
        const e = luDecompC(&ma, perm, &det_re, &det_im);
        if (e != .none) return e;
        var inv = ComplexMatrix{ .rows = n, .columns = n, .data = alloc.alloc(phloat.Phloat, @intCast(2 * n * n)) catch return .insufficient_memory };
        defer alloc.free(inv.data);
        @memset(inv.data, phloat.fromInt(0));
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            inv.data[@intCast(2 * (i * (n + 1)))] = phloat.fromInt(1);
        }
        const e2 = luBacksubstCC(&ma, perm, &inv);
        if (e2 != .none) return e2;
        result.* = rebuildComplex(inv) orelse return .insufficient_memory;
        return .none;
    }
}

/// Matrix determinant. Forces singular-matrix error mode so a zero pivot is
/// reported (and folded to det = 0) rather than fudged.
pub fn linalgDet(src: *const Vartype, result: *?*Vartype) Err {
    const info = vartype.matrixInfo(src) orelse return .invalid_type;
    if (vartype.containsStrings(src)) return .alpha_data_is_invalid;
    const n = info.rows;
    if (n != info.columns) return .dimension_error;
    const perm = alloc.alloc(i32, @intCast(n)) catch return .insufficient_memory;
    defer alloc.free(perm);
    const prev = globals.settings.matrix_singularmatrix;
    globals.settings.matrix_singularmatrix = true;
    defer globals.settings.matrix_singularmatrix = prev;

    if (!info.is_complex) {
        var ma = extractReal(src) orelse return .insufficient_memory;
        defer alloc.free(ma.data);
        var det: phloat.Phloat = undefined;
        const e = luDecompR(&ma, perm, &det);
        if (e == .singular_matrix) {
            det = phloat.fromInt(0);
        } else if (e != .none) {
            return e;
        }
        const inf = pIsinf(det);
        if (inf != 0) {
            if (globals.flags.range_error_ignore) {
                det = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
            } else {
                return .out_of_range;
            }
        }
        result.* = vartype.newReal(det) orelse return .insufficient_memory;
        return .none;
    } else {
        var ma = extractComplex(src) orelse return .insufficient_memory;
        defer alloc.free(ma.data);
        var det_re: phloat.Phloat = undefined;
        var det_im: phloat.Phloat = undefined;
        const e = luDecompC(&ma, perm, &det_re, &det_im);
        if (e == .singular_matrix) {
            det_re = phloat.fromInt(0);
            det_im = phloat.fromInt(0);
        } else if (e != .none) {
            return e;
        }
        var inf = pIsinf(det_re);
        if (inf != 0) {
            if (globals.flags.range_error_ignore) {
                det_re = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
            } else {
                return .out_of_range;
            }
        }
        inf = pIsinf(det_im);
        if (inf != 0) {
            if (globals.flags.range_error_ignore) {
                det_im = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
            } else {
                return .out_of_range;
            }
        }
        result.* = vartype.newComplex(det_re, det_im) orelse return .insufficient_memory;
        return .none;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeReal2x2(a: i32, b: i32, c: i32, d: i32) ?*Vartype {
    const m = vartype.newArray(2) orelse return null;
    const r0 = vartype.newArray(2) orelse return null;
    const r1 = vartype.newArray(2) orelse return null;
    m.array.data[0] = r0;
    m.array.data[1] = r1;
    r0.array.data[0] = vartype.newReal(phloat.fromInt(a)) orelse return null;
    r0.array.data[1] = vartype.newReal(phloat.fromInt(b)) orelse return null;
    r1.array.data[0] = vartype.newReal(phloat.fromInt(c)) orelse return null;
    r1.array.data[1] = vartype.newReal(phloat.fromInt(d)) orelse return null;
    return m;
}

/// Read element (i, j) of a real matrix.
fn matElem(m: *const Vartype, i: i32, j: i32) phloat.Phloat {
    return m.array.data[@intCast(i)].?.array.data[@intCast(j)].?.real;
}

/// Compare a phloat against an f64 within a tolerance that absorbs the
/// rounding the LU decomposition introduces at 34-digit precision.
fn expectPhloat(p: phloat.Phloat, expected: f64) !void {
    try std.testing.expectApproxEqAbs(expected, phloat.toDouble(p), 1e-20);
}

test "matrix multiply 2x2" {
    globals.init();
    defer globals.deinit();
    const a = makeReal2x2(1, 2, 3, 4) orelse return error.OOM;
    const b = makeReal2x2(5, 6, 7, 8) orelse return error.OOM;
    defer vartype.free(a);
    defer vartype.free(b);
    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.none, linalgMul(a, b, &r));
    defer vartype.freeOpt(r);
    try expectPhloat(matElem(r.?, 0, 0), 19.0);
    try expectPhloat(matElem(r.?, 0, 1), 22.0);
    try expectPhloat(matElem(r.?, 1, 0), 43.0);
    try expectPhloat(matElem(r.?, 1, 1), 50.0);
}

test "matrix determinant 2x2" {
    globals.init();
    defer globals.deinit();
    const a = makeReal2x2(1, 2, 3, 4) orelse return error.OOM;
    defer vartype.free(a);
    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.none, linalgDet(a, &r));
    defer vartype.freeOpt(r);
    try expectPhloat(r.?.real, -2.0);
}

test "matrix inverse 2x2" {
    globals.init();
    defer globals.deinit();
    const a = makeReal2x2(1, 2, 3, 4) orelse return error.OOM;
    defer vartype.free(a);
    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.none, linalgInv(a, &r));
    defer vartype.freeOpt(r);
    // A^-1 = [[-2, 1], [1.5, -0.5]]
    try expectPhloat(matElem(r.?, 0, 0), -2.0);
    try expectPhloat(matElem(r.?, 0, 1), 1.0);
    try expectPhloat(matElem(r.?, 1, 0), 1.5);
    try expectPhloat(matElem(r.?, 1, 1), -0.5);
}

test "matrix solve (division) 2x2" {
    globals.init();
    defer globals.deinit();
    const a = makeReal2x2(1, 2, 3, 4) orelse return error.OOM;
    defer vartype.free(a);
    // b = [[5], [11]]; solve A x = b → x = [[1], [2]]
    const b = vartype.newArray(2) orelse return error.OOM;
    defer vartype.free(b);
    const b0 = vartype.newArray(1) orelse return error.OOM;
    const b1 = vartype.newArray(1) orelse return error.OOM;
    b.array.data[0] = b0;
    b.array.data[1] = b1;
    b0.array.data[0] = vartype.newReal(phloat.fromInt(5)) orelse return error.OOM;
    b1.array.data[0] = vartype.newReal(phloat.fromInt(11)) orelse return error.OOM;
    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.none, linalgDiv(b, a, &r));
    defer vartype.freeOpt(r);
    try expectPhloat(matElem(r.?, 0, 0), 1.0);
    try expectPhloat(matElem(r.?, 1, 0), 2.0);
}

test "singular matrix determinant is zero" {
    globals.init();
    defer globals.deinit();
    const a = makeReal2x2(1, 2, 2, 4) orelse return error.OOM;
    defer vartype.free(a);
    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.none, linalgDet(a, &r));
    defer vartype.freeOpt(r);
    try expectPhloat(r.?.real, 0.0);
}
