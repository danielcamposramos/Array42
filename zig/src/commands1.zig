//! commands1 — the basic HP-42S built-in functions.
//!
//! Zig port of Free42's `common/core_commands1.cc`: the stack commands
//! (CLX, ENTER, x↔y, R↓, CHS, LASTx), the four arithmetic operators, and the
//! simple unary functions (ABS, SIGN, MOD, IP, FP, %, π, COMPLEX), plus the
//! display-mode and angle-mode commands.
//!
//! Commands that need transcendentals (→REC, →POL, trig) are deferred to
//! step 3, as are RND's SCI/ENG paths (which need log10).

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const helpers = @import("helpers.zig");

const Err = globals.Err;
const Vartype = vartype.Vartype;

/// A minimal command argument. Only the numeric field is used by the commands
/// ported so far (FIX/SCI/ENG digit counts).
pub const Arg = struct {
    num: i32 = 0,
};

fn x() *Vartype {
    return globals.stack[helpers.xIndex()].?;
}
fn y() *Vartype {
    return globals.stack[helpers.xIndex() - 1].?;
}

// ---------------------------------------------------------------------------
// Stack commands
// ---------------------------------------------------------------------------

pub fn docmdClx(arg: ?*const Arg) Err {
    _ = arg;
    vartype.free(x());
    globals.stack[helpers.xIndex()] = vartype.newReal(phloat.fromInt(0)) orelse return .insufficient_memory;
    globals.mode_disable_stack_lift = true;
    return .none;
}

pub fn docmdEnter(arg: ?*const Arg) Err {
    _ = arg;
    const v = vartype.dup(x()) orelse return .insufficient_memory;
    const prev = globals.flags.stack_lift_disable;
    globals.flags.stack_lift_disable = false;
    if (helpers.recallResultSilently(v) != .none) {
        globals.flags.stack_lift_disable = prev;
        return .insufficient_memory;
    }
    globals.mode_disable_stack_lift = true;
    helpers.printStackTrace();
    return .none;
}

pub fn docmdSwap(arg: ?*const Arg) Err {
    _ = arg;
    const xi = helpers.xIndex();
    const temp = globals.stack[xi];
    globals.stack[xi] = globals.stack[xi - 1];
    globals.stack[xi - 1] = temp;
    helpers.printTrace();
    return .none;
}

pub fn docmdRdn(arg: ?*const Arg) Err {
    _ = arg;
    if (globals.sp > 0) {
        const temp = globals.stack[0];
        var i: usize = 0;
        while (i < helpers.xIndex()) : (i += 1) {
            globals.stack[i] = globals.stack[i + 1];
        }
        globals.stack[helpers.xIndex()] = temp;
    }
    helpers.printTrace();
    return .none;
}

pub fn docmdChs(arg: ?*const Arg) Err {
    _ = arg;
    switch (x().*) {
        .real, .complex => negateInPlace(x()),
        .array => {
            if (vartype.containsStrings(x())) return .alpha_data_is_invalid;
            if (!vartype.disentangle(x())) return .insufficient_memory;
            negateInPlace(x());
        },
        else => return .internal_error,
    }
    helpers.printTrace();
    return .none;
}

/// Negate every numeric element of a value in place (recurses into arrays).
fn negateInPlace(v: *Vartype) void {
    switch (v.*) {
        .real => |*r| r.* = phloat.neg(r.*),
        .complex => |*c| {
            c.re = phloat.neg(c.re);
            c.im = phloat.neg(c.im);
        },
        .array => |*a| {
            for (a.data) |item| {
                if (item) |p| negateInPlace(p);
            }
        },
        else => {},
    }
}

pub fn docmdLastx(arg: ?*const Arg) Err {
    _ = arg;
    const v = vartype.dup(globals.lastx.?) orelse return .insufficient_memory;
    return helpers.recallResult(v);
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

pub fn docmdAdd(arg: ?*const Arg) Err {
    _ = arg;
    var res: ?*Vartype = null;
    const e = helpers.genericAdd(x(), y(), &res);
    if (e != .none) return e;
    return helpers.binaryResult(res.?);
}

pub fn docmdSub(arg: ?*const Arg) Err {
    _ = arg;
    var res: ?*Vartype = null;
    const e = helpers.genericSub(x(), y(), &res);
    if (e != .none) return e;
    return helpers.binaryResult(res.?);
}

pub fn docmdMul(arg: ?*const Arg) Err {
    _ = arg;
    var res: ?*Vartype = null;
    const e = helpers.genericMul(x(), y(), &res);
    if (e != .none) return e;
    return helpers.binaryResult(res.?);
}

pub fn docmdDiv(arg: ?*const Arg) Err {
    _ = arg;
    var res: ?*Vartype = null;
    const e = helpers.genericDiv(x(), y(), &res);
    if (e != .none) return e;
    return helpers.binaryResult(res.?);
}

// ---------------------------------------------------------------------------
// Unary functions
// ---------------------------------------------------------------------------

pub fn docmdPi(arg: ?*const Arg) Err {
    _ = arg;
    const v = vartype.newReal(phloat.PI) orelse return .insufficient_memory;
    return helpers.recallResult(v);
}

pub fn docmdPercent(arg: ?*const Arg) Err {
    _ = arg;
    const xv = x().real;
    const yv = y().real;
    var res = phloat.mul(xv, yv);
    if (phloat.isInf(res)) {
        res = phloat.mul(phloat.div(xv, phloat.fromInt(100)), yv);
        if (phloat.isInf(res)) return .out_of_range;
    } else {
        res = phloat.div(res, phloat.fromInt(100));
    }
    const v = vartype.newReal(res) orelse return .insufficient_memory;
    helpers.unaryResult(v);
    return .none;
}

pub fn docmdAbs(arg: ?*const Arg) Err {
    _ = arg;
    switch (x().*) {
        .real => |xv| {
            const r = if (phloat.lt(xv, phloat.fromInt(0))) phloat.neg(xv) else xv;
            const v = vartype.newReal(r) orelse return .insufficient_memory;
            helpers.unaryResult(v);
            return .none;
        },
        .complex => |c| {
            // |a+bi| = sqrt(a²+b²); hypot is deferred, so use the naive form
            // and clamp on overflow.
            const a = phloat.abs(c.re);
            const b = phloat.abs(c.im);
            const h = phloat.add(phloat.mul(a, a), phloat.mul(b, b));
            const r = if (phloat.isInf(h)) phloat.POS_HUGE else phloat.sqrt(h);
            const v = vartype.newReal(r) orelse return .insufficient_memory;
            helpers.unaryResult(v);
            return .none;
        },
        .array => {
            var v: ?*Vartype = null;
            const e = helpers.mapUnary(x(), &v, mappableAbs, null);
            if (e != .none) return e;
            helpers.unaryResult(v.?);
            return .none;
        },
        else => return .internal_error,
    }
}

fn mappableAbs(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = if (phloat.lt(xv, phloat.fromInt(0))) phloat.neg(xv) else xv;
    return .none;
}

pub fn docmdSign(arg: ?*const Arg) Err {
    _ = arg;
    switch (x().*) {
        .real => |xv| {
            // HP-41C compatibility: SIGN(0) = 1.
            const r = if (phloat.lt(xv, phloat.fromInt(0))) phloat.fromInt(-1) else phloat.fromInt(1);
            const v = vartype.newReal(r) orelse return .insufficient_memory;
            helpers.unaryResult(v);
            return .none;
        },
        .string => {
            const v = vartype.newReal(phloat.fromInt(0)) orelse return .insufficient_memory;
            helpers.unaryResult(v);
            return .none;
        },
        .complex => |c| {
            const v = signComplex(c.re, c.im) orelse return .insufficient_memory;
            helpers.unaryResult(v);
            return .none;
        },
        .array => {
            var v: ?*Vartype = null;
            const e = helpers.mapUnary(x(), &v, mappableSign, mappableSignC);
            if (e != .none) return e;
            helpers.unaryResult(v.?);
            return .none;
        },
        else => return .internal_error,
    }
}

fn mappableSign(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = if (phloat.lt(xv, phloat.fromInt(0))) phloat.fromInt(-1) else phloat.fromInt(1);
    return .none;
}

fn mappableSignC(xre: phloat.Phloat, xim: phloat.Phloat, ore: *phloat.Phloat, oim: *phloat.Phloat) Err {
    const v = signComplex(xre, xim) orelse return .insufficient_memory;
    defer vartype.free(v);
    ore.* = v.complex.re;
    oim.* = v.complex.im;
    return .none;
}

fn signComplex(xre: phloat.Phloat, xim: phloat.Phloat) ?*Vartype {
    // z/|z|, with overflow protection.
    var h = phloat.add(phloat.mul(xre, xre), phloat.mul(xim, xim));
    if (phloat.isZero(h)) return vartype.newComplex(phloat.fromInt(0), phloat.fromInt(0));
    if (phloat.isInf(h)) {
        h = phloat.add(phloat.mul(phloat.div(xre, phloat.fromInt(10000)), phloat.div(xre, phloat.fromInt(10000))), phloat.mul(phloat.div(xim, phloat.fromInt(10000)), phloat.div(xim, phloat.fromInt(10000))));
        const s = phloat.sqrt(h);
        return vartype.newComplex(phloat.div(phloat.div(xre, phloat.fromInt(10000)), s), phloat.div(phloat.div(xim, phloat.fromInt(10000)), s));
    }
    const s = phloat.sqrt(h);
    return vartype.newComplex(phloat.div(xre, s), phloat.div(xim, s));
}

pub fn docmdMod(arg: ?*const Arg) Err {
    _ = arg;
    const xv = x().real;
    const yv = y().real;
    var res: phloat.Phloat = undefined;
    if (phloat.isZero(xv)) {
        res = yv;
    } else if (phloat.isZero(yv)) {
        res = phloat.fromInt(0);
    } else {
        res = phloat.fmod(yv, xv);
        if (!phloat.isZero(res) and ((phloat.gt(xv, phloat.fromInt(0)) and phloat.lt(yv, phloat.fromInt(0))) or (phloat.lt(xv, phloat.fromInt(0)) and phloat.gt(yv, phloat.fromInt(0)))))
            res = phloat.add(res, xv);
    }
    const v = vartype.newReal(res) orelse return .insufficient_memory;
    return helpers.binaryResult(v);
}

pub fn docmdIp(arg: ?*const Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableIp, null);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableIp(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = if (phloat.lt(xv, phloat.fromInt(0))) phloat.neg(phloat.floor(phloat.neg(xv))) else phloat.floor(xv);
    return .none;
}

pub fn docmdFp(arg: ?*const Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableFp, null);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableFp(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = if (phloat.lt(xv, phloat.fromInt(0))) phloat.add(xv, phloat.floor(phloat.neg(xv))) else phloat.sub(xv, phloat.floor(xv));
    return .none;
}

pub fn docmdComplex(arg: ?*const Arg) Err {
    _ = arg;
    switch (x().*) {
        .real => {
            if (y().* == .string) return .alpha_data_is_invalid;
            if (y().* != .real) return .invalid_type;
            if (globals.flags.polar) return .not_yet_implemented; // needs →REC
            const v = vartype.newComplex(y().real, x().real) orelse return .insufficient_memory;
            return helpers.binaryResult(v);
        },
        .complex => |c| {
            if (globals.flags.polar) return .not_yet_implemented; // needs →POL
            const nx = vartype.newReal(c.im) orelse return .insufficient_memory;
            const ny = vartype.newReal(c.re) orelse return .insufficient_memory;
            return helpers.unaryTwoResults(nx, ny);
        },
        .string => return .alpha_data_is_invalid,
        else => return .invalid_type,
    }
}

// ---------------------------------------------------------------------------
// Angle conversions
// ---------------------------------------------------------------------------

pub fn docmdToDeg(arg: ?*const Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableToDeg, null);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableToDeg(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    const r = helpers.radToDeg(xv);
    const inf: i32 = if (phloat.isInf(r)) (if (phloat.isNegative(r)) -1 else 1) else 0;
    if (inf != 0) {
        if (globals.flags.range_error_ignore) {
            out.* = if (inf == 1) phloat.POS_HUGE else phloat.NEG_HUGE;
        } else return .out_of_range;
    } else out.* = r;
    return .none;
}

pub fn docmdToRad(arg: ?*const Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableToRad, null);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableToRad(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = helpers.degToRad(xv);
    return .none;
}

pub fn docmdToHr(arg: ?*const Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableToHr, null);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableToHr(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    const neg = phloat.lt(xv, phloat.fromInt(0));
    const x2 = if (neg) phloat.neg(xv) else xv;
    var res: phloat.Phloat = undefined;
    if (phloat.eq(x2, phloat.add(x2, phloat.fromInt(1)))) {
        res = x2;
    } else {
        const point01 = phloat.fromString("0.01");
        const point36 = phloat.fromString("0.36");
        if (phloat.lt(x2, point01)) {
            res = phloat.div(x2, point36);
        } else {
            const xh = phloat.floor(x2);
            const t = phloat.mul(phloat.sub(x2, xh), phloat.fromInt(100));
            const xm = phloat.floor(t);
            const xs = phloat.mul(phloat.sub(t, xm), phloat.fromInt(100));
            res = phloat.add(phloat.add(xh, phloat.div(xm, phloat.fromInt(60))), phloat.div(xs, phloat.fromInt(3600)));
        }
    }
    out.* = if (neg) phloat.neg(res) else res;
    return .none;
}

pub fn docmdToHms(arg: ?*const Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableToHms, null);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableToHms(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    const neg = phloat.lt(xv, phloat.fromInt(0));
    const x2 = if (neg) phloat.neg(xv) else xv;
    var r = phloat.floor(x2);
    x2 = phloat.mul(phloat.sub(x2, r), phloat.fromInt(60));
    const t = phloat.floor(x2);
    r = phloat.add(phloat.add(r, phloat.div(t, phloat.fromInt(100))), phloat.mul(phloat.sub(x2, t), phloat.fromString("0.006")));
    r = helpers.fixHms(r);
    out.* = if (neg) phloat.neg(r) else r;
    return .none;
}

// ---------------------------------------------------------------------------
// Display modes
// ---------------------------------------------------------------------------

fn setDigits(num: i32) Err {
    if (num > 11) return .invalid_data;
    globals.flags.digits_bit3 = (num & 8) != 0;
    globals.flags.digits_bit2 = (num & 4) != 0;
    globals.flags.digits_bit1 = (num & 2) != 0;
    globals.flags.digits_bit0 = (num & 1) != 0;
    return .none;
}

pub fn docmdFix(arg: ?*const Arg) Err {
    const e = setDigits(arg.?.num);
    if (e != .none) return e;
    globals.flags.fix_or_all = true;
    globals.flags.eng_or_all = false;
    helpers.printTrace();
    return .none;
}

pub fn docmdSci(arg: ?*const Arg) Err {
    const e = setDigits(arg.?.num);
    if (e != .none) return e;
    globals.flags.fix_or_all = false;
    globals.flags.eng_or_all = false;
    helpers.printTrace();
    return .none;
}

pub fn docmdEng(arg: ?*const Arg) Err {
    const e = setDigits(arg.?.num);
    if (e != .none) return e;
    globals.flags.fix_or_all = false;
    globals.flags.eng_or_all = true;
    helpers.printTrace();
    return .none;
}

pub fn docmdAll(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.digits_bit3 = false;
    globals.flags.digits_bit2 = false;
    globals.flags.digits_bit1 = false;
    globals.flags.digits_bit0 = false;
    globals.flags.fix_or_all = true;
    globals.flags.eng_or_all = true;
    helpers.printTrace();
    return .none;
}

// ---------------------------------------------------------------------------
// Angle / coordinate modes
// ---------------------------------------------------------------------------

pub fn docmdDeg(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.grad = false;
    globals.flags.rad = false;
    return .none;
}
pub fn docmdRad(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.grad = false;
    globals.flags.rad = true;
    return .none;
}
pub fn docmdGrad(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.grad = true;
    globals.flags.rad = false;
    return .none;
}
pub fn docmdRect(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.polar = false;
    helpers.printTrace();
    return .none;
}
pub fn docmdPolar(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.polar = true;
    helpers.printTrace();
    return .none;
}
pub fn docmdCpxres(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.real_result_only = false;
    return .none;
}
pub fn docmdRealres(arg: ?*const Arg) Err {
    _ = arg;
    globals.flags.real_result_only = true;
    return .none;
}

// ---------------------------------------------------------------------------
// Clear commands
// ---------------------------------------------------------------------------

pub fn docmdClst(arg: ?*const Arg) Err {
    _ = arg;
    for (globals.stack) |slot| vartype.freeOpt(slot);
    if (globals.flags.big_stack) {
        globals.sp = -1;
        globals.shrinkStack();
    } else {
        for (globals.stack) |*slot| {
            slot.* = vartype.newReal(phloat.fromInt(0)) orelse return .insufficient_memory;
        }
    }
    return .none;
}

pub fn docmdClall(arg: ?*const Arg) Err {
    _ = arg;
    _ = docmdClst(null);
    vartype.freeOpt(globals.lastx);
    globals.lastx = vartype.newReal(phloat.fromInt(0)) orelse return .insufficient_memory;
    globals.flags.prgm_mode = false;
    return .none;
}

// ---------------------------------------------------------------------------
// Number entry
// ---------------------------------------------------------------------------

/// Push a real number onto the stack with proper stack-lift semantics.
pub fn pushNumber(s: []const u8) Err {
    return pushReal(phloat.fromString(s));
}

/// Push an already-constructed real onto the stack.
pub fn pushReal(p: phloat.Phloat) Err {
    const v = vartype.newReal(p) orelse return .insufficient_memory;
    // Number entry lifts the stack unless the previous command disabled the
    // lift (ENTER, CLX, STO, …). The mode flag is consumed here.
    if (globals.mode_disable_stack_lift) {
        globals.flags.stack_lift_disable = true;
        globals.mode_disable_stack_lift = false;
    } else {
        globals.flags.stack_lift_disable = false;
    }
    return helpers.recallResult(v);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "1 ENTER 2 + = 3" {
    globals.init();
    defer globals.deinit();
    // 1 ENTER 2 +
    try std.testing.expectEqual(Err.none, pushNumber("1"));
    try std.testing.expectEqual(Err.none, docmdEnter(null));
    try std.testing.expectEqual(Err.none, pushNumber("2"));
    try std.testing.expectEqual(Err.none, docmdAdd(null));
    try std.testing.expectEqualStrings("3", phloat.toString(x().real));
    // LASTx should be 2.
    try std.testing.expectEqualStrings("2", phloat.toString(globals.lastx.?.real));
}

test "stack lift semantics: 1 ENTER 2 ENTER 3 +" {
    globals.init();
    defer globals.deinit();
    try std.testing.expectEqual(Err.none, pushNumber("1"));
    try std.testing.expectEqual(Err.none, docmdEnter(null));
    try std.testing.expectEqual(Err.none, pushNumber("2"));
    try std.testing.expectEqual(Err.none, docmdEnter(null));
    try std.testing.expectEqual(Err.none, pushNumber("3"));
    try std.testing.expectEqual(Err.none, docmdAdd(null));
    // X = 5, Y = 1 (2 ENTER 3 + → 5, and 1 stays in Y).
    try std.testing.expectEqualStrings("5", phloat.toString(x().real));
    try std.testing.expectEqualStrings("1", phloat.toString(y().real));
}

test "divide by zero reports error" {
    globals.init();
    defer globals.deinit();
    try std.testing.expectEqual(Err.none, pushNumber("1"));
    try std.testing.expectEqual(Err.none, docmdEnter(null));
    try std.testing.expectEqual(Err.none, pushNumber("0"));
    try std.testing.expectEqual(Err.divide_by_0, docmdDiv(null));
}
