//! commands3 — the HP-42S matrix commands.
//!
//! Zig port of the matrix commands scattered across Free42's
//! `common/core_commands2.cc` (NEWMAT, DIM?), `core_commands3.cc` (DET, DOT,
//! CROSS) and `core_commands4.cc` (INVRT, TRANS). The heavy lifting is done by
//! `linalg.zig`; these commands are the thin stack-facing wrappers.
//!
//! Arrays use the DB48X-grade nested representation: a matrix is an array of
//! arrays (rows), a vector is an array of scalars, and arrays nest to
//! arbitrary depth.
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

/// True if a value contains a complex at any depth.
fn containsComplex(v: *const Vartype) bool {
    return switch (v.*) {
        .complex => true,
        .array => |a| {
            for (a.data) |item| {
                if (item) |p| {
                    if (containsComplex(p)) return true;
                }
            }
            return false;
        },
        else => false,
    };
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
    const info = vartype.matrixInfo(x()) orelse return .invalid_type;
    const rows = info.rows;
    const columns = info.columns;
    const src = x().array;
    const dst = vartype.newArray(columns) orelse return .insufficient_memory;
    errdefer vartype.free(dst);
    var j: i32 = 0;
    while (j < columns) : (j += 1) {
        const row = vartype.newArray(rows) orelse return .insufficient_memory;
        dst.array.data[@intCast(j)] = row;
        var i: i32 = 0;
        while (i < rows) : (i += 1) {
            const elem = src.data[@intCast(i)].?.array.data[@intCast(j)].?;
            row.array.data[@intCast(i)] = vartype.dup(elem) orelse return .insufficient_memory;
        }
    }
    helpers.unaryResult(dst);
    return .none;
}

// ---------------------------------------------------------------------------
// DOT — dot product
// ---------------------------------------------------------------------------

/// Accumulate the element-wise product of two numeric values into (re, im).
/// Recurses into arrays; both sides must have the same shape.
fn dotAccum(a: *const Vartype, b: *const Vartype, re: *phloat.Phloat, im: *phloat.Phloat) Err {
    switch (a.*) {
        .real => |av| switch (b.*) {
            .real => |bv| re.* = phloat.add(re.*, phloat.mul(av, bv)),
            .complex => |c| {
                re.* = phloat.add(re.*, phloat.mul(av, c.re));
                im.* = phloat.add(im.*, phloat.mul(av, c.im));
            },
            else => return .invalid_type,
        },
        .complex => |c| switch (b.*) {
            .real => |bv| {
                re.* = phloat.add(re.*, phloat.mul(c.re, bv));
                im.* = phloat.add(im.*, phloat.mul(c.im, bv));
            },
            .complex => |c2| {
                re.* = phloat.add(re.*, phloat.sub(phloat.mul(c.re, c2.re), phloat.mul(c.im, c2.im)));
                im.* = phloat.add(im.*, phloat.add(phloat.mul(c.re, c2.im), phloat.mul(c2.re, c.im)));
            },
            else => return .invalid_type,
        },
        .array => |aa| switch (b.*) {
            .array => |ba| {
                if (aa.data.len != ba.data.len) return .dimension_error;
                for (aa.data, 0..) |item, i| {
                    const p1 = item orelse return .invalid_type;
                    const p2 = ba.data[i] orelse return .invalid_type;
                    const e = dotAccum(p1, p2, re, im);
                    if (e != .none) return e;
                }
            },
            else => return .invalid_type,
        },
        else => return .invalid_type,
    }
    return .none;
}

pub fn docmdDot(arg: ?*const Arg) Err {
    _ = arg;
    if (x().* == .string or y().* == .string) return .alpha_data_is_invalid;

    // complex × complex scalar → real dot (re·re + im·im), faithful to Free42.
    if (x().* == .complex and y().* == .complex) {
        const xc = x().complex;
        const yc = y().complex;
        const d = phloat.add(phloat.mul(xc.re, yc.re), phloat.mul(xc.im, yc.im));
        var r: phloat.Phloat = undefined;
        const e = clampInf(d, &r);
        if (e != .none) return e;
        const v = vartype.newReal(r) orelse return .insufficient_memory;
        return helpers.binaryResult(v);
    }

    // Otherwise both operands must be numeric arrays of the same shape.
    if (x().* != .array or y().* != .array) return .invalid_type;
    if (vartype.containsStrings(x()) or vartype.containsStrings(y())) return .alpha_data_is_invalid;
    var re = phloat.fromInt(0);
    var im = phloat.fromInt(0);
    const e = dotAccum(x(), y(), &re, &im);
    if (e != .none) return e;
    var rre: phloat.Phloat = undefined;
    var rim: phloat.Phloat = undefined;
    const e1 = clampInf(re, &rre);
    if (e1 != .none) return e1;
    const e2 = clampInf(im, &rim);
    if (e2 != .none) return e2;
    const v = if (containsComplex(x()) or containsComplex(y()))
        vartype.newComplex(rre, rim)
    else
        vartype.newReal(rre);
    const vv = v orelse return .insufficient_memory;
    return helpers.binaryResult(vv);
}

// ---------------------------------------------------------------------------
// CROSS — cross product
// ---------------------------------------------------------------------------

/// If `v` is a 1D array of reals, return its length; else null.
fn realVectorLen(v: *const Vartype) ?i32 {
    const a = switch (v.*) {
        .array => |a| a,
        else => return null,
    };
    for (a.data) |item| {
        const p = item orelse return null;
        if (p.* != .real) return null;
    }
    return @intCast(a.data.len);
}

fn realVectorElem(v: *const Vartype, i: i32) phloat.Phloat {
    return v.array.data[@intCast(i)].?.real;
}

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
        .array => switch (y().*) {
            .array => {
                const ls = realVectorLen(y()) orelse return .invalid_type;
                const rs = realVectorLen(x()) orelse return .invalid_type;
                if (ls > 3 or rs > 3) return .dimension_error;
                var xl = phloat.fromInt(0);
                var yl = phloat.fromInt(0);
                var zl = phloat.fromInt(0);
                var xr = phloat.fromInt(0);
                var yr = phloat.fromInt(0);
                var zr = phloat.fromInt(0);
                if (ls >= 1) xl = realVectorElem(y(), 0);
                if (ls >= 2) yl = realVectorElem(y(), 1);
                if (ls >= 3) zl = realVectorElem(y(), 2);
                if (rs >= 1) xr = realVectorElem(x(), 0);
                if (rs >= 2) yr = realVectorElem(x(), 1);
                if (rs >= 3) zr = realVectorElem(x(), 2);
                var xres: phloat.Phloat = undefined;
                var yres: phloat.Phloat = undefined;
                var zres: phloat.Phloat = undefined;
                const e1 = clampInf(phloat.sub(phloat.mul(yl, zr), phloat.mul(zl, yr)), &xres);
                if (e1 != .none) return e1;
                const e2 = clampInf(phloat.sub(phloat.mul(zl, xr), phloat.mul(xl, zr)), &yres);
                if (e2 != .none) return e2;
                const e3 = clampInf(phloat.sub(phloat.mul(xl, yr), phloat.mul(yl, xr)), &zres);
                if (e3 != .none) return e3;
                const res = vartype.newArray(3) orelse return .insufficient_memory;
                errdefer vartype.free(res);
                res.array.data[0] = vartype.newReal(xres) orelse return .insufficient_memory;
                res.array.data[1] = vartype.newReal(yres) orelse return .insufficient_memory;
                res.array.data[2] = vartype.newReal(zres) orelse return .insufficient_memory;
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
    const m = vartype.newArray(yy) orelse return .insufficient_memory;
    errdefer vartype.free(m);
    var i: i32 = 0;
    while (i < yy) : (i += 1) {
        const row = vartype.newArray(xx) orelse return .insufficient_memory;
        m.array.data[@intCast(i)] = row;
        var j: i32 = 0;
        while (j < xx) : (j += 1) {
            row.array.data[@intCast(j)] = vartype.newReal(phloat.fromInt(0)) orelse return .insufficient_memory;
        }
    }
    return helpers.binaryResult(m);
}

// ---------------------------------------------------------------------------
// DIM? — matrix dimensions (Y = rows, X = columns)
// ---------------------------------------------------------------------------

pub fn docmdDimT(arg: ?*const Arg) Err {
    _ = arg;
    const info = vartype.matrixInfo(x()) orelse return .invalid_type;
    const new_y = vartype.newReal(phloat.fromInt(info.rows)) orelse return .insufficient_memory;
    errdefer vartype.free(new_y);
    const new_x = vartype.newReal(phloat.fromInt(info.columns)) orelse return .insufficient_memory;
    return helpers.unaryTwoResults(new_x, new_y);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectPhloat(expected: f64, p: phloat.Phloat) !void {
    try std.testing.expectApproxEqAbs(expected, phloat.toDouble(p), 1e-20);
}

/// Read element (i, j) of a real matrix (array of arrays).
fn matElem(m: *const Vartype, i: i32, j: i32) phloat.Phloat {
    return m.array.data[@intCast(i)].?.array.data[@intCast(j)].?.real;
}

/// Build a real matrix (array of arrays) from row-major values.
fn makeMatrix(rows: i32, cols: i32, values: []const f64) *Vartype {
    const m = vartype.newArray(rows) orelse unreachable;
    var i: i32 = 0;
    while (i < rows) : (i += 1) {
        const row = vartype.newArray(cols) orelse unreachable;
        m.array.data[@intCast(i)] = row;
        var j: i32 = 0;
        while (j < cols) : (j += 1) {
            row.array.data[@intCast(j)] = vartype.newReal(phloat.fromDouble(values[@intCast(i * cols + j)])) orelse unreachable;
        }
    }
    return m;
}

/// Build a real vector (1D array) from values.
fn makeVector(values: []const f64) *Vartype {
    const v = vartype.newArray(@intCast(values.len)) orelse unreachable;
    for (values, 0..) |val, i| {
        v.array.data[i] = vartype.newReal(phloat.fromDouble(val)) orelse unreachable;
    }
    return v;
}

/// Replace the X register with `m`.
fn setX(m: *Vartype) void {
    vartype.freeOpt(globals.stack[helpers.xIndex()]);
    globals.stack[helpers.xIndex()] = m;
}

/// Replace the Y register with `m`.
fn setY(m: *Vartype) void {
    vartype.freeOpt(globals.stack[helpers.xIndex() - 1]);
    globals.stack[helpers.xIndex() - 1] = m;
}

test "NEWMAT creates a zero matrix and DIM? reports its shape" {
    globals.init();
    defer globals.deinit();
    // 2 ENTER 3 NEWMAT → 2×3 zero matrix in X.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("2"));
    try std.testing.expectEqual(Err.none, commands1.docmdEnter(null));
    try std.testing.expectEqual(Err.none, commands1.pushNumber("3"));
    try std.testing.expectEqual(Err.none, docmdNewmat(null));
    try std.testing.expectEqual(vartype.Type.array, std.meta.activeTag(x().*));
    try std.testing.expectEqual(@as(usize, 2), x().array.data.len);
    try std.testing.expectEqual(@as(usize, 3), x().array.data[0].?.array.data.len);

    // DIM? → Y = rows (2), X = columns (3).
    try std.testing.expectEqual(Err.none, docmdDimT(null));
    try std.testing.expectEqualStrings("3", phloat.toString(x().real));
    try std.testing.expectEqualStrings("2", phloat.toString(y().real));
}

test "TRANS transposes a matrix" {
    globals.init();
    defer globals.deinit();
    // [[1,2,3],[4,5,6]] → transpose [[1,4],[2,5],[3,6]].
    setX(makeMatrix(2, 3, &.{ 1, 2, 3, 4, 5, 6 }));
    try std.testing.expectEqual(Err.none, docmdTrans(null));
    try std.testing.expectEqual(@as(usize, 3), x().array.data.len);
    try std.testing.expectEqual(@as(usize, 2), x().array.data[0].?.array.data.len);
    try expectPhloat(1, matElem(x(), 0, 0));
    try expectPhloat(4, matElem(x(), 0, 1));
    try expectPhloat(2, matElem(x(), 1, 0));
    try expectPhloat(5, matElem(x(), 1, 1));
    try expectPhloat(3, matElem(x(), 2, 0));
    try expectPhloat(6, matElem(x(), 2, 1));
}

test "DET computes a determinant" {
    globals.init();
    defer globals.deinit();
    // [[2,0],[0,3]] → det 6.
    setX(makeMatrix(2, 2, &.{ 2, 0, 0, 3 }));
    try std.testing.expectEqual(Err.none, docmdDet(null));
    try expectPhloat(6, x().real);
}

test "INVRT inverts a matrix" {
    globals.init();
    defer globals.deinit();
    // [[2,0],[0,4]] → inverse [[0.5,0],[0,0.25]].
    setX(makeMatrix(2, 2, &.{ 2, 0, 0, 4 }));
    try std.testing.expectEqual(Err.none, docmdInvrt(null));
    try expectPhloat(0.5, matElem(x(), 0, 0));
    try expectPhloat(0, matElem(x(), 0, 1));
    try expectPhloat(0, matElem(x(), 1, 0));
    try expectPhloat(0.25, matElem(x(), 1, 1));
}

test "DOT computes a dot product" {
    globals.init();
    defer globals.deinit();
    // [1,2,3] DOT [4,5,6] = 32.
    setX(makeVector(&.{ 4, 5, 6 }));
    setY(makeVector(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(Err.none, docmdDot(null));
    try expectPhloat(32, x().real);
}

test "CROSS computes a cross product" {
    globals.init();
    defer globals.deinit();
    // [1,0,0] × [0,1,0] = [0,0,1].
    setX(makeVector(&.{ 0, 1, 0 }));
    setY(makeVector(&.{ 1, 0, 0 }));
    try std.testing.expectEqual(Err.none, docmdCross(null));
    try expectPhloat(0, x().array.data[0].?.real);
    try expectPhloat(0, x().array.data[1].?.real);
    try expectPhloat(1, x().array.data[2].?.real);
}
