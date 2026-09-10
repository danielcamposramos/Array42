//! helpers — stack-result plumbing and generic arithmetic.
//!
//! Zig port of the relevant parts of Free42's `common/core_helpers.cc` and
//! `common/core_sto_rcl.cc`: the `*_result` functions that move values on and
//! off the RPN stack, the `map_unary`/`map_binary` type dispatchers, and the
//! `generic_add`/`sub`/`mul`/`div` entry points with their per-type mappables.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const linalg = @import("linalg.zig");

const Err = globals.Err;
const Vartype = vartype.Vartype;

// ---------------------------------------------------------------------------
// Mappable function types (matches core_sto_rcl.h)
// ---------------------------------------------------------------------------

const MappableR = *const fn (x: phloat.Phloat, y: *phloat.Phloat) Err;
const MappableC = *const fn (xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err;
const MappableRR = *const fn (x: phloat.Phloat, y: phloat.Phloat, z: *phloat.Phloat) Err;
const MappableRC = *const fn (x: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err;
const MappableCR = *const fn (xre: phloat.Phloat, xim: phloat.Phloat, y: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err;
const MappableCC = *const fn (xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err;

/// `p_isinf`: -1 for -Inf, 0 for finite, +1 for +Inf.
fn pIsinf(p: phloat.Phloat) i32 {
    if (!phloat.isInf(p)) return 0;
    return if (phloat.isNegative(p)) -1 else 1;
}

/// Clamp an infinite result to ±huge, or report out-of-range.
fn checkRange(r: phloat.Phloat, out: *phloat.Phloat) Err {
    const inf = pIsinf(r);
    if (inf == 0) {
        out.* = r;
        return .none;
    }
    if (globals.flags.range_error_ignore) {
        out.* = if (inf == 1) phloat.POS_HUGE else phloat.NEG_HUGE;
        return .none;
    }
    return .out_of_range;
}

// ---------------------------------------------------------------------------
// Per-type arithmetic mappables (matches core_sto_rcl.cc)
// ---------------------------------------------------------------------------

fn addRR(x: phloat.Phloat, y: phloat.Phloat, z: *phloat.Phloat) Err {
    return checkRange(phloat.add(y, x), z);
}
fn addRC(x: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.add(yre, x), zre);
    if (e != .none) return e;
    zim.* = yim;
    return .none;
}
fn addCR(xre: phloat.Phloat, xim: phloat.Phloat, y: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.add(y, xre), zre);
    if (e != .none) return e;
    zim.* = xim;
    return .none;
}
fn addCC(xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.add(yre, xre), zre);
    if (e != .none) return e;
    return checkRange(phloat.add(yim, xim), zim);
}

fn subRR(x: phloat.Phloat, y: phloat.Phloat, z: *phloat.Phloat) Err {
    return checkRange(phloat.sub(y, x), z);
}
fn subRC(x: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.sub(yre, x), zre);
    if (e != .none) return e;
    zim.* = yim;
    return .none;
}
fn subCR(xre: phloat.Phloat, xim: phloat.Phloat, y: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.sub(y, xre), zre);
    if (e != .none) return e;
    zim.* = phloat.neg(xim);
    return .none;
}
fn subCC(xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.sub(yre, xre), zre);
    if (e != .none) return e;
    return checkRange(phloat.sub(yim, xim), zim);
}

fn mulRR(x: phloat.Phloat, y: phloat.Phloat, z: *phloat.Phloat) Err {
    return checkRange(phloat.mul(y, x), z);
}
fn mulRC(x: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.mul(yre, x), zre);
    if (e != .none) return e;
    return checkRange(phloat.mul(yim, x), zim);
}
fn mulCR(xre: phloat.Phloat, xim: phloat.Phloat, y: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    const e = checkRange(phloat.mul(y, xre), zre);
    if (e != .none) return e;
    return checkRange(phloat.mul(y, xim), zim);
}
fn mulCC(xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    // (xre + i·xim)(yre + i·yim) = (xre·yre − xim·yim) + i(xre·yim + yre·xim)
    const e = checkRange(phloat.sub(phloat.mul(xre, yre), phloat.mul(xim, yim)), zre);
    if (e != .none) return e;
    return checkRange(phloat.add(phloat.mul(xre, yim), phloat.mul(yre, xim)), zim);
}

fn divRR(x: phloat.Phloat, y: phloat.Phloat, z: *phloat.Phloat) Err {
    if (phloat.isZero(x)) return .divide_by_0;
    return checkRange(phloat.div(y, x), z);
}
fn divRC(x: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    if (phloat.isZero(x)) return .divide_by_0;
    const e = checkRange(phloat.div(yre, x), zre);
    if (e != .none) return e;
    return checkRange(phloat.div(yim, x), zim);
}
fn divCR(xre: phloat.Phloat, xim: phloat.Phloat, y: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    // Complex division, Smith's algorithm (see core_sto_rcl.cc).
    if (phloat.isZero(xre) and phloat.isZero(xim)) return .divide_by_0;
    var r: phloat.Phloat = undefined;
    var t: phloat.Phloat = undefined;
    var rre: phloat.Phloat = undefined;
    var rim: phloat.Phloat = undefined;
    if (phloat.le(phloat.abs(xim), phloat.abs(xre))) {
        r = phloat.div(xim, xre);
        t = phloat.div(phloat.fromInt(1), phloat.add(xre, phloat.mul(xim, r)));
        if (phloat.isZero(r)) {
            rre = phloat.mul(y, t);
            rim = phloat.neg(phloat.mul(phloat.mul(xim, phloat.div(y, xre)), t));
        } else {
            rre = phloat.mul(y, t);
            rim = phloat.neg(phloat.mul(phloat.mul(y, r), t));
        }
    } else {
        r = phloat.div(xre, xim);
        t = phloat.div(phloat.fromInt(1), phloat.add(phloat.mul(xre, r), xim));
        if (phloat.isZero(r)) {
            rre = phloat.mul(phloat.mul(xre, phloat.div(y, xim)), t);
            rim = phloat.neg(phloat.mul(y, t));
        } else {
            rre = phloat.mul(phloat.mul(y, r), t);
            rim = phloat.neg(phloat.mul(y, t));
        }
    }
    const e = checkRange(rre, zre);
    if (e != .none) return e;
    return checkRange(rim, zim);
}
fn divCC(xre: phloat.Phloat, xim: phloat.Phloat, yre: phloat.Phloat, yim: phloat.Phloat, zre: *phloat.Phloat, zim: *phloat.Phloat) Err {
    if (phloat.isZero(xre) and phloat.isZero(xim)) return .divide_by_0;
    var r: phloat.Phloat = undefined;
    var t: phloat.Phloat = undefined;
    var rre: phloat.Phloat = undefined;
    var rim: phloat.Phloat = undefined;
    if (phloat.le(phloat.abs(xim), phloat.abs(xre))) {
        r = phloat.div(xim, xre);
        t = phloat.div(phloat.fromInt(1), phloat.add(xre, phloat.mul(xim, r)));
        if (phloat.isZero(r)) {
            rre = phloat.mul(phloat.add(yre, phloat.mul(xim, phloat.div(yim, xre))), t);
            rim = phloat.mul(phloat.sub(yim, phloat.mul(xim, phloat.div(yre, xre))), t);
        } else {
            rre = phloat.mul(phloat.add(yre, phloat.mul(yim, r)), t);
            rim = phloat.mul(phloat.sub(yim, phloat.mul(yre, r)), t);
        }
    } else {
        r = phloat.div(xre, xim);
        t = phloat.div(phloat.fromInt(1), phloat.add(phloat.mul(xre, r), xim));
        if (phloat.isZero(r)) {
            rre = phloat.mul(phloat.add(phloat.mul(xre, phloat.div(yre, xim)), yim), t);
            rim = phloat.mul(phloat.sub(phloat.mul(xre, phloat.div(yim, xim)), yre), t);
        } else {
            rre = phloat.mul(phloat.add(phloat.mul(yre, r), yim), t);
            rim = phloat.mul(phloat.sub(phloat.mul(yim, r), yre), t);
        }
    }
    const e = checkRange(rre, zre);
    if (e != .none) return e;
    return checkRange(rim, zim);
}

// ---------------------------------------------------------------------------
// Type dispatchers (matches core_sto_rcl.cc map_unary / map_binary)
// ---------------------------------------------------------------------------

pub fn mapUnary(src: *const Vartype, dst: *?*Vartype, mr: ?MappableR, mc: ?MappableC) Err {
    switch (src.*) {
        .real => |x| {
            const m = mr orelse return .internal_error;
            var r: phloat.Phloat = undefined;
            const e = m(x, &r);
            if (e != .none) return e;
            dst.* = vartype.newReal(r) orelse return .insufficient_memory;
            return .none;
        },
        .complex => |c| {
            const m = mc orelse return .internal_error;
            var rre: phloat.Phloat = undefined;
            var rim: phloat.Phloat = undefined;
            const e = m(c.re, c.im, &rre, &rim);
            if (e != .none) return e;
            dst.* = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
            return .none;
        },
        .realmatrix => |sm| {
            const m = mr orelse return .internal_error;
            if (vartype.containsStrings(&sm)) return .alpha_data_is_invalid;
            const dm = vartype.newRealMatrix(sm.rows, sm.columns) orelse return .insufficient_memory;
            errdefer vartype.free(dm);
            for (sm.data, 0..) |x, i| {
                const e = m(x, &dm.realmatrix.data[i]);
                if (e != .none) return e;
            }
            dst.* = dm;
            return .none;
        },
        .complexmatrix => |sm| {
            const m = mc orelse return .internal_error;
            const dm = vartype.newComplexMatrix(sm.rows, sm.columns) orelse return .insufficient_memory;
            errdefer vartype.free(dm);
            var i: usize = 0;
            while (i < sm.data.len) : (i += 2) {
                const e = m(sm.data[i], sm.data[i + 1], &dm.complexmatrix.data[i], &dm.complexmatrix.data[i + 1]);
                if (e != .none) return e;
            }
            dst.* = dm;
            return .none;
        },
        else => return .internal_error,
    }
}

pub fn mapBinary(src1: *const Vartype, src2: *const Vartype, dst: *?*Vartype, mrr: MappableRR, mrc: MappableRC, mcr: MappableCR, mcc: MappableCC) Err {
    switch (src1.*) {
        .real => |x| switch (src2.*) {
            .real => |y| {
                var r: phloat.Phloat = undefined;
                const e = mrr(x, y, &r);
                if (e != .none) return e;
                dst.* = vartype.newReal(r) orelse return .insufficient_memory;
                return .none;
            },
            .complex => |c| {
                var rre: phloat.Phloat = undefined;
                var rim: phloat.Phloat = undefined;
                const e = mrc(x, c.re, c.im, &rre, &rim);
                if (e != .none) return e;
                dst.* = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
                return .none;
            },
            .realmatrix => |sm| {
                if (vartype.containsStrings(&sm)) return .alpha_data_is_invalid;
                const dm = vartype.newRealMatrix(sm.rows, sm.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                for (sm.data, 0..) |y, i| {
                    const e = mrr(x, y, &dm.realmatrix.data[i]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .complexmatrix => |sm| {
                const dm = vartype.newComplexMatrix(sm.rows, sm.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                var i: usize = 0;
                while (i < sm.data.len) : (i += 2) {
                    const e = mrc(x, sm.data[i], sm.data[i + 1], &dm.complexmatrix.data[i], &dm.complexmatrix.data[i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            else => return .internal_error,
        },
        .complex => |c| switch (src2.*) {
            .real => |y| {
                var rre: phloat.Phloat = undefined;
                var rim: phloat.Phloat = undefined;
                const e = mcr(c.re, c.im, y, &rre, &rim);
                if (e != .none) return e;
                dst.* = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
                return .none;
            },
            .complex => |c2| {
                var rre: phloat.Phloat = undefined;
                var rim: phloat.Phloat = undefined;
                const e = mcc(c.re, c.im, c2.re, c2.im, &rre, &rim);
                if (e != .none) return e;
                dst.* = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
                return .none;
            },
            .realmatrix => |sm| {
                if (vartype.containsStrings(&sm)) return .alpha_data_is_invalid;
                const dm = vartype.newComplexMatrix(sm.rows, sm.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                for (sm.data, 0..) |y, i| {
                    const e = mcr(c.re, c.im, y, &dm.complexmatrix.data[2 * i], &dm.complexmatrix.data[2 * i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .complexmatrix => |sm| {
                const dm = vartype.newComplexMatrix(sm.rows, sm.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                var i: usize = 0;
                while (i < sm.data.len) : (i += 2) {
                    const e = mcc(c.re, c.im, sm.data[i], sm.data[i + 1], &dm.complexmatrix.data[i], &dm.complexmatrix.data[i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            else => return .internal_error,
        },
        .realmatrix => |sm1| switch (src2.*) {
            .real => |y| {
                if (vartype.containsStrings(&sm1)) return .alpha_data_is_invalid;
                const dm = vartype.newRealMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                for (sm1.data, 0..) |x, i| {
                    const e = mrr(x, y, &dm.realmatrix.data[i]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .complex => |c| {
                if (vartype.containsStrings(&sm1)) return .alpha_data_is_invalid;
                const dm = vartype.newComplexMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                for (sm1.data, 0..) |x, i| {
                    const e = mrc(x, c.re, c.im, &dm.complexmatrix.data[2 * i], &dm.complexmatrix.data[2 * i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .realmatrix => |sm2| {
                if (sm1.rows != sm2.rows or sm1.columns != sm2.columns) return .dimension_error;
                if (vartype.containsStrings(&sm1) or vartype.containsStrings(&sm2)) return .alpha_data_is_invalid;
                const dm = vartype.newRealMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                for (sm1.data, 0..) |x, i| {
                    const e = mrr(x, sm2.data[i], &dm.realmatrix.data[i]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .complexmatrix => |sm2| {
                if (sm1.rows != sm2.rows or sm1.columns != sm2.columns) return .dimension_error;
                if (vartype.containsStrings(&sm1)) return .alpha_data_is_invalid;
                const dm = vartype.newComplexMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                for (sm1.data, 0..) |x, i| {
                    const e = mrc(x, sm2.data[2 * i], sm2.data[2 * i + 1], &dm.complexmatrix.data[2 * i], &dm.complexmatrix.data[2 * i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            else => return .internal_error,
        },
        .complexmatrix => |sm1| switch (src2.*) {
            .real => |y| {
                const dm = vartype.newComplexMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                var i: usize = 0;
                while (i < sm1.data.len) : (i += 2) {
                    const e = mcr(sm1.data[i], sm1.data[i + 1], y, &dm.complexmatrix.data[i], &dm.complexmatrix.data[i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .complex => |c| {
                const dm = vartype.newComplexMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                var i: usize = 0;
                while (i < sm1.data.len) : (i += 2) {
                    const e = mcc(sm1.data[i], sm1.data[i + 1], c.re, c.im, &dm.complexmatrix.data[i], &dm.complexmatrix.data[i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .realmatrix => |sm2| {
                if (sm1.rows != sm2.rows or sm1.columns != sm2.columns) return .dimension_error;
                if (vartype.containsStrings(&sm2)) return .alpha_data_is_invalid;
                const dm = vartype.newComplexMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                for (sm2.data, 0..) |y, i| {
                    const e = mcr(sm1.data[2 * i], sm1.data[2 * i + 1], y, &dm.complexmatrix.data[2 * i], &dm.complexmatrix.data[2 * i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            .complexmatrix => |sm2| {
                if (sm1.rows != sm2.rows or sm1.columns != sm2.columns) return .dimension_error;
                const dm = vartype.newComplexMatrix(sm1.rows, sm1.columns) orelse return .insufficient_memory;
                errdefer vartype.free(dm);
                var i: usize = 0;
                while (i < sm1.data.len) : (i += 2) {
                    const e = mcc(sm1.data[i], sm1.data[i + 1], sm2.data[i], sm2.data[i + 1], &dm.complexmatrix.data[i], &dm.complexmatrix.data[i + 1]);
                    if (e != .none) return e;
                }
                dst.* = dm;
                return .none;
            },
            else => return .internal_error,
        },
        else => return .internal_error,
    }
}

// ---------------------------------------------------------------------------
// Generic arithmetic entry points (matches core_sto_rcl.cc)
// ---------------------------------------------------------------------------

pub fn genericAdd(px: *const Vartype, py: *const Vartype, dst: *?*Vartype) Err {
    return mapBinary(px, py, dst, addRR, addRC, addCR, addCC);
}
pub fn genericSub(px: *const Vartype, py: *const Vartype, dst: *?*Vartype) Err {
    return mapBinary(px, py, dst, subRR, subRC, subCR, subCC);
}
pub fn genericMul(px: *const Vartype, py: *const Vartype, dst: *?*Vartype) Err {
    // Matrix × matrix is the linear-algebra product, not element-wise.
    if (isMatrix(px) and isMatrix(py)) return linalg.linalgMul(py, px, dst);
    return mapBinary(px, py, dst, mulRR, mulRC, mulCR, mulCC);
}
pub fn genericDiv(px: *const Vartype, py: *const Vartype, dst: *?*Vartype) Err {
    // Matrix ÷ matrix is the linear-algebra solve, not element-wise.
    if (isMatrix(px) and isMatrix(py)) return linalg.linalgDiv(py, px, dst);
    return mapBinary(px, py, dst, divRR, divRC, divCR, divCC);
}

fn isMatrix(v: *const Vartype) bool {
    return switch (v.*) {
        .realmatrix, .complexmatrix => true,
        else => false,
    };
}

/// True if a vartype is a numeric type (real/complex/matrix).
pub fn assertNumeric(v: *const Vartype) Err {
    return switch (v.*) {
        .real, .complex, .realmatrix, .complexmatrix => .none,
        .string => .alpha_data_is_invalid,
        else => .invalid_type,
    };
}

// ---------------------------------------------------------------------------
// Stack-result functions (matches core_helpers.cc)
// ---------------------------------------------------------------------------

pub fn xIndex() usize {
    return @intCast(globals.sp);
}

pub fn recallResultSilently(v: *Vartype) Err {
    if (globals.flags.stack_lift_disable) {
        if (globals.sp == -1) {
            globals.sp = 0;
        } else {
            vartype.freeOpt(globals.stack[xIndex()]);
        }
    } else if (globals.flags.big_stack) {
        if (!globals.ensureStackCapacity(1)) {
            vartype.free(v);
            return .insufficient_memory;
        }
        globals.sp += 1;
    } else {
        vartype.freeOpt(globals.stack[globals.REG_T]);
        globals.stack[globals.REG_T] = globals.stack[globals.REG_Z];
        globals.stack[globals.REG_Z] = globals.stack[globals.REG_Y];
        globals.stack[globals.REG_Y] = globals.stack[globals.REG_X];
    }
    globals.stack[xIndex()] = v;
    return .none;
}

pub fn recallResult(v: *Vartype) Err {
    const e = recallResultSilently(v);
    if (e == .none) printTrace();
    return e;
}

pub fn recallTwoResults(x: *Vartype, y: *Vartype) Err {
    if (globals.flags.big_stack) {
        const sld = globals.flags.stack_lift_disable and globals.sp != -1;
        const off: i32 = if (sld) 1 else 2;
        if (!globals.ensureStackCapacity(off)) {
            vartype.free(x);
            vartype.free(y);
            return .insufficient_memory;
        }
        if (sld) vartype.freeOpt(globals.stack[xIndex()]);
        globals.sp += off;
    } else {
        if (globals.flags.stack_lift_disable) {
            vartype.freeOpt(globals.stack[globals.REG_T]);
            vartype.freeOpt(globals.stack[globals.REG_X]);
            globals.stack[globals.REG_T] = globals.stack[globals.REG_Z];
            globals.stack[globals.REG_Z] = globals.stack[globals.REG_Y];
        } else {
            vartype.freeOpt(globals.stack[globals.REG_T]);
            vartype.freeOpt(globals.stack[globals.REG_Z]);
            globals.stack[globals.REG_T] = globals.stack[globals.REG_Y];
            globals.stack[globals.REG_Z] = globals.stack[globals.REG_X];
        }
    }
    globals.stack[xIndex() - 1] = y;
    globals.stack[xIndex()] = x;
    printTrace();
    return .none;
}

pub fn unaryResult(x: *Vartype) void {
    vartype.freeOpt(globals.lastx);
    globals.lastx = globals.stack[xIndex()];
    globals.stack[xIndex()] = x;
    printTrace();
}

pub fn unaryTwoResults(x: *Vartype, y: *Vartype) Err {
    if (globals.flags.big_stack) {
        if (!globals.ensureStackCapacity(1)) {
            vartype.free(x);
            vartype.free(y);
            return .insufficient_memory;
        }
        vartype.freeOpt(globals.lastx);
        globals.lastx = globals.stack[xIndex()];
        globals.sp += 1;
    } else {
        vartype.freeOpt(globals.stack[globals.REG_T]);
        globals.stack[globals.REG_T] = globals.stack[globals.REG_Z];
        globals.stack[globals.REG_Z] = globals.stack[globals.REG_Y];
        vartype.freeOpt(globals.lastx);
        globals.lastx = globals.stack[globals.REG_X];
    }
    globals.stack[xIndex() - 1] = y;
    globals.stack[xIndex()] = x;
    printTrace();
    return .none;
}

pub fn binaryResult(x: *Vartype) Err {
    var t: ?*Vartype = null;
    if (!globals.flags.big_stack) {
        t = vartype.dup(globals.stack[globals.REG_T].?) orelse {
            vartype.free(x);
            return .insufficient_memory;
        };
    }
    vartype.freeOpt(globals.lastx);
    globals.lastx = globals.stack[xIndex()];
    vartype.freeOpt(globals.stack[xIndex() - 1]);
    if (globals.flags.big_stack) {
        globals.sp -= 1;
    } else {
        globals.stack[globals.REG_Y] = globals.stack[globals.REG_Z];
        globals.stack[globals.REG_Z] = t;
    }
    globals.stack[xIndex()] = x;
    printTrace();
    return .none;
}

pub fn binaryTwoResults(x: *Vartype, y: *Vartype) void {
    if (globals.flags.big_stack) {
        while (globals.sp < 1) {
            globals.sp += 1;
            globals.stack[xIndex()] = null;
        }
    }
    if (globals.stack[xIndex()] != null) {
        vartype.freeOpt(globals.lastx);
        globals.lastx = globals.stack[xIndex()];
    }
    vartype.freeOpt(globals.stack[xIndex() - 1]);
    globals.stack[xIndex() - 1] = y;
    globals.stack[xIndex()] = x;
    printTrace();
}

// ---------------------------------------------------------------------------
// Angle helpers (matches core_helpers.cc)
// ---------------------------------------------------------------------------

pub fn radToDeg(x: phloat.Phloat) phloat.Phloat {
    return phloat.mul(x, phloat.div(phloat.fromInt(180), phloat.PI));
}
pub fn degToRad(x: phloat.Phloat) phloat.Phloat {
    return phloat.mul(x, phloat.div(phloat.PI, phloat.fromInt(180)));
}
pub fn radToAngle(x: phloat.Phloat) phloat.Phloat {
    if (globals.flags.rad) return x;
    if (globals.flags.grad) return phloat.mul(x, phloat.div(phloat.fromInt(200), phloat.PI));
    return radToDeg(x);
}

/// Fix a HMS value whose minutes/seconds rounded up to 60.
pub fn fixHms(x: phloat.Phloat) phloat.Phloat {
    const sec_corr = phloat.fromString("0.004");
    const min_corr = phloat.fromString("0.4");
    const neg = phloat.lt(x, phloat.fromInt(0));
    var v = if (neg) phloat.neg(x) else x;
    if (phloat.eq(v, phloat.add(v, phloat.fromInt(1)))) return if (neg) phloat.neg(v) else v;
    if (phloat.lt(v, phloat.fromString("0.0059"))) return if (neg) phloat.neg(v) else v;
    if (phloat.eq(phloat.floor(phloat.fmod(phloat.mul(v, phloat.fromInt(10000)), phloat.fromInt(100))), phloat.fromInt(60)))
        v = phloat.add(v, sec_corr);
    if (phloat.eq(phloat.floor(phloat.fmod(phloat.mul(v, phloat.fromInt(100)), phloat.fromInt(100))), phloat.fromInt(60))) {
        v = phloat.add(v, min_corr);
        if (phloat.eq(phloat.floor(phloat.fmod(phloat.mul(v, phloat.fromInt(10000)), phloat.fromInt(100))), phloat.fromInt(60)))
            v = phloat.add(v, sec_corr);
    }
    return if (neg) phloat.neg(v) else v;
}

// ---------------------------------------------------------------------------
// Printing (stubs — the printer is a later step)
// ---------------------------------------------------------------------------

pub fn printTrace() void {}
pub fn printStackTrace() void {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "generic add/sub/mul/div on reals" {
    globals.init();
    defer globals.deinit();
    const a = vartype.newReal(phloat.fromString("2")) orelse return error.OOM;
    const b = vartype.newReal(phloat.fromString("3")) orelse return error.OOM;
    defer vartype.free(a);
    defer vartype.free(b);

    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.none, genericAdd(a, b, &r));
    defer vartype.freeOpt(r);
    try std.testing.expectEqualStrings("5", phloat.toString(r.?.real));

    try std.testing.expectEqual(Err.none, genericSub(a, b, &r));
    try std.testing.expectEqualStrings("1", phloat.toString(r.?.real));

    try std.testing.expectEqual(Err.none, genericMul(a, b, &r));
    try std.testing.expectEqualStrings("6", phloat.toString(r.?.real));

    try std.testing.expectEqual(Err.none, genericDiv(a, b, &r));
    try std.testing.expectEqualStrings("1.5", phloat.toString(r.?.real));
}

test "complex multiplication" {
    globals.init();
    defer globals.deinit();
    // (1+2i)(3+4i) = -5 + 10i
    const a = vartype.newComplex(phloat.fromInt(1), phloat.fromInt(2)) orelse return error.OOM;
    const b = vartype.newComplex(phloat.fromInt(3), phloat.fromInt(4)) orelse return error.OOM;
    defer vartype.free(a);
    defer vartype.free(b);
    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.none, genericMul(a, b, &r));
    defer vartype.freeOpt(r);
    try std.testing.expectEqualStrings("-5", phloat.toString(r.?.complex.re));
    try std.testing.expectEqualStrings("10", phloat.toString(r.?.complex.im));
}

test "divide by zero" {
    globals.init();
    defer globals.deinit();
    const zero = vartype.newReal(phloat.fromInt(0)) orelse return error.OOM;
    const one = vartype.newReal(phloat.fromInt(1)) orelse return error.OOM;
    defer vartype.free(zero);
    defer vartype.free(one);
    var r: ?*Vartype = null;
    try std.testing.expectEqual(Err.divide_by_0, genericDiv(zero, one, &r));
}
