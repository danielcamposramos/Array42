//! commands3 — the HP-42S matrix commands.
//!
//! Zig port of the matrix commands scattered across Free42's
//! `common/core_commands2.cc` (NEWMAT, DIM?), `core_commands3.cc` (DET, DOT,
//! CROSS) and `core_commands4.cc` (INVRT, TRANS). The heavy lifting is done by
//! `linalg.zig`; these commands are the thin stack-facing wrappers.
//!
//! Deferred (depend on the unported variable system): SIZE, DIM, SIMQ.
//! FNORM is a DB48X command (not in Free42) and lands in step 4b.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const helpers = @import("helpers.zig");
const linalg = @import("linalg.zig");
const commands1 = @import("commands1.zig");

const Err = globals.Err;
const Vartype = vartype.Vartype;
const Arg = commands1.Arg;

fn x() *Vartype {
    return globals.stack[helpers.xIndex()].?;
}
fn y() *Vartype {
    return globals.stack[helpers.xIndex() - 1].?;
}

/// `p_isinf`: -1 for -Inf, 0 for finite, +1 for +Inf.
fn pIsinf(p: phloat.Phloat) i32 {
    if (!phloat.isInf(p)) return 0;
    return if (phloat.isNegative(p)) -1 else 1;
}

/// Clamp an infinite result to ±huge, or report out-of-range.
fn clampInf(r: phloat.Phloat, out: *phloat.Phloat) Err {
    const inf = pIsinf(r);
    if (inf == 0) {
        out.* = r;
        return .none;
    }
    if (globals.flags.range_error_ignore) {
        out.* = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
        return .none;
    }
    return .out_of_range;
}

// ---------------------------------------------------------------------------
// DET — determinant
// ---------------------------------------------------------------------------

pub fn docmdDet(arg: ?*const Arg) Err {
    _ = arg;
    var res: ?*Vartype = null;
    const e = linalg.linalgDet(x(), &res);
    if (e != .none) return e;
    helpers.unaryResult(res.?);
    return .none;
}

// ---------------------------------------------------------------------------
// INVRT — matrix inverse
// ---------------------------------------------------------------------------

pub fn docmdInvrt(arg: ?*const Arg) Err {
    _ = arg;
    var res: ?*Vartype = null;
    const e = linalg.linalgInv(x(), &res);
    if (e != .none) return e;
    helpers.unaryResult(res.?);
    return .none;
}

// ---------------------------------------------------------------------------
// TRANS — transpose
// ---------------------------------------------------------------------------

pub fn docmdTrans(arg: ?*const Arg) Err {
    _ = arg;
    switch (x().*) {
        .realmatrix => |src| {
            const rows = src.rows;
            const columns = src.columns;
            const dst = vartype.newRealMatrix(columns, rows) orelse return .insufficient_memory;
            errdefer vartype.free(dst);
            var i: i32 = 0;
            while (i < rows) : (i += 1) {
                var j: i32 = 0;
                while (j < columns) : (j += 1) {
                    const n1: usize = @intCast(i * columns + j);
                    const n2: usize = @intCast(j * rows + i);
                    dst.realmatrix.is_string[n2] = src.is_string[n1];
                    dst.realmatrix.data[n2] = src.data[n1];
                }
            }
            helpers.unaryResult(dst);
            return .none;
        },
        .complexmatrix => |src| {
            const rows = src.rows;
            const columns = src.columns;
            const dst = vartype.newComplexMatrix(columns, rows) orelse return .insufficient_memory;
            errdefer vartype.free(dst);
            var i: i32 = 0;
            while (i < rows) : (i += 1) {
                var j: i32 = 0;
                while (j < columns) : (j += 1) {
                    const n1: usize = @intCast(2 * (i * columns + j));
                    const n2: usize = @intCast(2 * (j * rows + i));
                    dst.complexmatrix.data[n2] = src.data[n1];
                    dst.complexmatrix.data[n2 + 1] = src.data[n1 + 1];
                }
            }
            helpers.unaryResult(dst);
            return .none;
        },
        else => return .invalid_type,
    }
}

// ---------------------------------------------------------------------------
// DOT — dot product
// ---------------------------------------------------------------------------

pub fn docmdDot(arg: ?*const Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    if (x().* == .string or y().* == .string) return .alpha_data_is_invalid;

    switch (x().*) {
        .realmatrix => |rm1| switch (y().*) {
            .realmatrix => |rm2| {
                const size = rm1.rows * rm1.columns;
                if (size != rm2.rows * rm2.columns) return .dimension_error;
                if (vartype.containsStrings(&rm1) or vartype.containsStrings(&rm2)) return .alpha_data_is_invalid;
                var dot = phloat.fromInt(0);
                var i: i32 = 0;
                while (i < size) : (i += 1) {
                    dot = phloat.add(dot, phloat.mul(rm1.data[@intCast(i)], rm2.data[@intCast(i)]));
                }
                var r: phloat.Phloat = undefined;
                const e = clampInf(dot, &r);
                if (e != .none) return e;
                v = vartype.newReal(r) orelse return .insufficient_memory;
            },
            .complexmatrix => |cm| {
                const size = rm1.rows * rm1.columns;
                if (size != cm.rows * cm.columns) return .dimension_error;
                if (vartype.containsStrings(&rm1)) return .alpha_data_is_invalid;
                var dot_re = phloat.fromInt(0);
                var dot_im = phloat.fromInt(0);
                var i: i32 = 0;
                while (i < size) : (i += 1) {
                    dot_re = phloat.add(dot_re, phloat.mul(rm1.data[@intCast(i)], cm.data[@intCast(2 * i)]));
                    dot_im = phloat.add(dot_im, phloat.mul(rm1.data[@intCast(i)], cm.data[@intCast(2 * i + 1)]));
                }
                var rre: phloat.Phloat = undefined;
                var rim: phloat.Phloat = undefined;
                const e1 = clampInf(dot_re, &rre);
                if (e1 != .none) return e1;
                const e2 = clampInf(dot_im, &rim);
                if (e2 != .none) return e2;
                v = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
            },
            else => return .invalid_type,
        },
        .complexmatrix => |cm1| switch (y().*) {
            .realmatrix => |rm| {
                const size = rm.rows * rm.columns;
                if (size != cm1.rows * cm1.columns) return .dimension_error;
                if (vartype.containsStrings(&rm)) return .alpha_data_is_invalid;
                var dot_re = phloat.fromInt(0);
                var dot_im = phloat.fromInt(0);
                var i: i32 = 0;
                while (i < size) : (i += 1) {
                    dot_re = phloat.add(dot_re, phloat.mul(rm.data[@intCast(i)], cm1.data[@intCast(2 * i)]));
                    dot_im = phloat.add(dot_im, phloat.mul(rm.data[@intCast(i)], cm1.data[@intCast(2 * i + 1)]));
                }
                var rre: phloat.Phloat = undefined;
                var rim: phloat.Phloat = undefined;
                const e1 = clampInf(dot_re, &rre);
                if (e1 != .none) return e1;
                const e2 = clampInf(dot_im, &rim);
                if (e2 != .none) return e2;
                v = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
            },
            .complexmatrix => |cm2| {
                const size = cm1.rows * cm1.columns;
                if (size != cm2.rows * cm2.columns) return .dimension_error;
                var dot_re = phloat.fromInt(0);
                var dot_im = phloat.fromInt(0);
                var i: i32 = 0;
                while (i < size) : (i += 1) {
                    const re1 = cm1.data[@intCast(2 * i)];
                    const im1 = cm1.data[@intCast(2 * i + 1)];
                    const re2 = cm2.data[@intCast(2 * i)];
                    const im2 = cm2.data[@intCast(2 * i + 1)];
                    dot_re = phloat.add(dot_re, phloat.sub(phloat.mul(re1, re2), phloat.mul(im1, im2)));
                    dot_im = phloat.add(dot_im, phloat.add(phloat.mul(re1, im2), phloat.mul(re2, im1)));
                }
                var rre: phloat.Phloat = undefined;
                var rim: phloat.Phloat = undefined;
                const e1 = clampInf(dot_re, &rre);
                if (e1 != .none) return e1;
                const e2 = clampInf(dot_im, &rim);
                if (e2 != .none) return e2;
                v = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
            },
            else => return .invalid_type,
        },
        .complex => |xc| switch (y().*) {
            .complex => |yc| {
                const d = phloat.add(phloat.mul(xc.re, yc.re), phloat.mul(xc.im, yc.im));
                var r: phloat.Phloat = undefined;
                const e = clampInf(d, &r);
                if (e != .none) return e;
                v = vartype.newReal(r) orelse return .insufficient_memory;
            },
            else => return .invalid_type,
        },
        else => return .invalid_type,
    }
    return helpers.binaryResult(v.?);
}

// ---------------------------------------------------------------------------
// CROSS — cross product
// ---------------------------------------------------------------------------

pub fn docmdCross(arg: ?*const Arg) Err {
    _ = arg;
    if (x().* == .string or y().* == .string) return .alpha_data_is_invalid;

    switch (x().*) {
        .complex => |right| switch (y().*) {
            .complex => |left| {
                // 2-D cross product: left.re·right.im − left.im·right.re.
                const d = phloat.sub(phloat.mul(left.re, right.im), phloat.mul(left.im, right.re));
                var r: phloat.Phloat = undefined;
                const e = clampInf(d, &r);
                if (e != .none) return e;
                const v = vartype.newReal(r) orelse return .insufficient_memory;
                return helpers.binaryResult(v);
            },
            else => return .invalid_type,
        },
        .realmatrix => |right| switch (y().*) {
            .realmatrix => |left| {
                const ls = left.rows * left.columns;
                const rs = right.rows * right.columns;
                if (ls > 3 or rs > 3) return .dimension_error;
                if (vartype.containsStrings(&left) or vartype.containsStrings(&right)) return .alpha_data_is_invalid;
                var xl = phloat.fromInt(0);
                var yl = phloat.fromInt(0);
                var zl = phloat.fromInt(0);
                var xr = phloat.fromInt(0);
                var yr = phloat.fromInt(0);
                var zr = phloat.fromInt(0);
                if (ls >= 1) xl = left.data[0];
                if (ls >= 2) yl = left.data[1];
                if (ls >= 3) zl = left.data[2];
                if (rs >= 1) xr = right.data[0];
                if (rs >= 2) yr = right.data[1];
                if (rs >= 3) zr = right.data[2];
                var xres: phloat.Phloat = undefined;
                var yres: phloat.Phloat = undefined;
                var zres: phloat.Phloat = undefined;
                const e1 = clampInf(phloat.sub(phloat.mul(yl, zr), phloat.mul(zl, yr)), &xres);
                if (e1 != .none) return e1;
                const e2 = clampInf(phloat.sub(phloat.mul(zl, xr), phloat.mul(xl, zr)), &yres);
                if (e2 != .none) return e2;
                const e3 = clampInf(phloat.sub(phloat.mul(xl, yr), phloat.mul(yl, xr)), &zres);
                if (e3 != .none) return e3;
                const res = vartype.newRealMatrix(1, 3) orelse return .insufficient_memory;
                errdefer vartype.free(res);
                res.realmatrix.data[0] = xres;
                res.realmatrix.data[1] = yres;
                res.realmatrix.data[2] = zres;
                return helpers.binaryResult(res);
            },
            else => return .invalid_type,
        },
        else => return .invalid_type,
    }
}

// ---------------------------------------------------------------------------
// NEWMAT — create a zero matrix (Y = rows, X = columns)
// ---------------------------------------------------------------------------

/// Convert a stack dimension argument to a positive i32, or null if it is
/// zero or out of the representable range (HP-42S NEWMAT semantics).
fn toMatrixDim(p: phloat.Phloat) ?i32 {
    if (phloat.le(p, phloat.fromInt(-2147483648)) or phloat.ge(p, phloat.fromUint(2147483648))) return null;
    var n = phloat.toInt(p);
    if (n == 0) return null;
    if (n < 0) n = -n;
    return n;
}

pub fn docmdNewmat(arg: ?*const Arg) Err {
    _ = arg;
    const xx = toMatrixDim(x().real) orelse return .dimension_error;
    const yy = toMatrixDim(y().real) orelse return .dimension_error;
    const m = vartype.newRealMatrix(yy, xx) orelse return .insufficient_memory;
    return helpers.binaryResult(m);
}

// ---------------------------------------------------------------------------
// DIM? — matrix dimensions (Y = rows, X = columns)
// ---------------------------------------------------------------------------

pub fn docmdDimT(arg: ?*const Arg) Err {
    _ = arg;
    const rows: i32 = switch (x().*) {
        .realmatrix => |m| m.rows,
        .complexmatrix => |m| m.rows,
        else => return .invalid_type,
    };
    const columns: i32 = switch (x().*) {
        .realmatrix => |m| m.columns,
        .complexmatrix => |m| m.columns,
        else => return .invalid_type,
    };
    const new_y = vartype.newReal(phloat.fromInt(rows)) orelse return .insufficient_memory;
    errdefer vartype.free(new_y);
    const new_x = vartype.newReal(phloat.fromInt(columns)) orelse return .insufficient_memory;
    return helpers.unaryTwoResults(new_x, new_y);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectPhloat(expected: f64, p: phloat.Phloat) !void {
    try std.testing.expectApproxEqAbs(expected, phloat.toDouble(p), 1e-20);
}

/// Put a real matrix on the stack at X (replacing whatever is there).
fn setXMatrix(rows: i32, cols: i32, values: []const f64) void {
    const m = vartype.newRealMatrix(rows, cols) orelse unreachable;
    for (values, 0..) |v, i| m.realmatrix.data[i] = phloat.fromDouble(v);
    vartype.freeOpt(globals.stack[helpers.xIndex()]);
    globals.stack[helpers.xIndex()] = m;
}

test "NEWMAT creates a zero matrix and DIM? reports its shape" {
    globals.init();
    defer globals.deinit();
    // 2 ENTER 3 NEWMAT → 2×3 zero matrix in X.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("2"));
    try std.testing.expectEqual(Err.none, commands1.docmdEnter(null));
    try std.testing.expectEqual(Err.none, commands1.pushNumber("3"));
    try std.testing.expectEqual(Err.none, docmdNewmat(null));
    try std.testing.expectEqual(vartype.Type.realmatrix, std.meta.activeTag(x().*));
    try std.testing.expectEqual(@as(i32, 2), x().realmatrix.rows);
    try std.testing.expectEqual(@as(i32, 3), x().realmatrix.columns);

    // DIM? → Y = rows (2), X = columns (3).
    try std.testing.expectEqual(Err.none, docmdDimT(null));
    try std.testing.expectEqualStrings("3", phloat.toString(x().real));
    try std.testing.expectEqualStrings("2", phloat.toString(y().real));
}

test "TRANS transposes a matrix" {
    globals.init();
    defer globals.deinit();
    // [[1,2,3],[4,5,6]] → transpose [[1,4],[2,5],[3,6]].
    setXMatrix(2, 3, &.{ 1, 2, 3, 4, 5, 6 });
    try std.testing.expectEqual(Err.none, docmdTrans(null));
    try std.testing.expectEqual(@as(i32, 3), x().realmatrix.rows);
    try std.testing.expectEqual(@as(i32, 2), x().realmatrix.columns);
    try expectPhloat(1, x().realmatrix.data[0]);
    try expectPhloat(4, x().realmatrix.data[1]);
    try expectPhloat(2, x().realmatrix.data[2]);
    try expectPhloat(5, x().realmatrix.data[3]);
    try expectPhloat(3, x().realmatrix.data[4]);
    try expectPhloat(6, x().realmatrix.data[5]);
}

test "DET computes a determinant" {
    globals.init();
    defer globals.deinit();
    // [[2,0],[0,3]] → det 6.
    setXMatrix(2, 2, &.{ 2, 0, 0, 3 });
    try std.testing.expectEqual(Err.none, docmdDet(null));
    try expectPhloat(6, x().real);
}

test "INVRT inverts a matrix" {
    globals.init();
    defer globals.deinit();
    // [[2,0],[0,4]] → inverse [[0.5,0],[0,0.25]].
    setXMatrix(2, 2, &.{ 2, 0, 0, 4 });
    try std.testing.expectEqual(Err.none, docmdInvrt(null));
    try expectPhloat(0.5, x().realmatrix.data[0]);
    try expectPhloat(0, x().realmatrix.data[1]);
    try expectPhloat(0, x().realmatrix.data[2]);
    try expectPhloat(0.25, x().realmatrix.data[3]);
}

test "DOT computes a dot product" {
    globals.init();
    defer globals.deinit();
    // [1,2,3] DOT [4,5,6] = 32.
    setXMatrix(1, 3, &.{ 4, 5, 6 });
    const m = vartype.newRealMatrix(1, 3) orelse unreachable;
    m.realmatrix.data[0] = phloat.fromInt(1);
    m.realmatrix.data[1] = phloat.fromInt(2);
    m.realmatrix.data[2] = phloat.fromInt(3);
    vartype.freeOpt(globals.stack[helpers.xIndex() - 1]);
    globals.stack[helpers.xIndex() - 1] = m;
    try std.testing.expectEqual(Err.none, docmdDot(null));
    try expectPhloat(32, x().real);
}

test "CROSS computes a cross product" {
    globals.init();
    defer globals.deinit();
    // [1,0,0] × [0,1,0] = [0,0,1].
    setXMatrix(1, 3, &.{ 0, 1, 0 });
    const m = vartype.newRealMatrix(1, 3) orelse unreachable;
    m.realmatrix.data[0] = phloat.fromInt(1);
    m.realmatrix.data[1] = phloat.fromInt(0);
    m.realmatrix.data[2] = phloat.fromInt(0);
    vartype.freeOpt(globals.stack[helpers.xIndex() - 1]);
    globals.stack[helpers.xIndex() - 1] = m;
    try std.testing.expectEqual(Err.none, docmdCross(null));
    try expectPhloat(0, x().realmatrix.data[0]);
    try expectPhloat(0, x().realmatrix.data[1]);
    try expectPhloat(1, x().realmatrix.data[2]);
}
