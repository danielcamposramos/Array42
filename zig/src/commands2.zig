//! commands2 — the transcendental HP-42S built-in functions.
//!
//! Zig port of the transcendental commands from Free42's `core_commands6.cc`
//! (SIN/COS/TAN/ASIN/ACOS/ATAN/LOG/LN/10^X/E^X/SQRT/X^2/1/X/Y^X),
//! `core_commands1.cc` (→REC/→POL/RND), `core_commands2.cc` (N!), and the
//! hyperbolic commands from `core_commands3.cc`/`core_commands4.cc`
//! (SINH/COSH/TANH/ASINH/ACOSH/ATANH/LN1+X), plus the complex-math helpers
//! from `core_math2.cc` and the angle helpers from `core_helpers.cc`.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const helpers = @import("helpers.zig");

const Err = globals.Err;
const Vartype = vartype.Vartype;

fn x() *Vartype {
    return globals.stack[helpers.xIndex()].?;
}
fn y() *Vartype {
    return globals.stack[helpers.xIndex() - 1].?;
}

/// The RND multiplier (10^digits), set by docmdRnd before mapping (matches
/// Free42's file-scoped `rnd_multiplier`).
var rnd_multiplier: phloat.Phloat = undefined;

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
// Angle helpers (matches core_helpers.cc sin_or_cos_deg / sin_or_cos_grad)
// ---------------------------------------------------------------------------

fn sinOrCosDeg(x0: phloat.Phloat, do_sin: bool) phloat.Phloat {
    var xv = x0;
    var neg = false;
    var ds = do_sin;
    if (phloat.lt(xv, phloat.fromInt(0))) {
        xv = phloat.neg(xv);
        if (ds) neg = true;
    }
    xv = phloat.fmod(xv, phloat.fromInt(360));
    if (phloat.ge(xv, phloat.fromInt(180))) {
        xv = phloat.sub(xv, phloat.fromInt(180));
        neg = !neg;
    }
    if (phloat.ge(xv, phloat.fromInt(90))) {
        xv = phloat.sub(xv, phloat.fromInt(90));
        ds = !ds;
        if (ds) neg = !neg;
    }
    var r: phloat.Phloat = undefined;
    if (phloat.eq(xv, phloat.fromInt(45))) {
        r = phloat.sqrt(phloat.fromString("0.5"));
    } else {
        if (phloat.gt(xv, phloat.fromInt(45))) {
            xv = phloat.sub(phloat.fromInt(90), xv);
            ds = !ds;
        }
        xv = phloat.div(xv, phloat.div(phloat.fromInt(180), phloat.PI));
        r = if (ds) phloat.sin(xv) else phloat.cos(xv);
    }
    return if (neg) phloat.neg(r) else r;
}

fn sinDeg(x0: phloat.Phloat) phloat.Phloat {
    return sinOrCosDeg(x0, true);
}
fn cosDeg(x0: phloat.Phloat) phloat.Phloat {
    return sinOrCosDeg(x0, false);
}

fn sinOrCosGrad(x0: phloat.Phloat, do_sin: bool) phloat.Phloat {
    var xv = x0;
    var neg = false;
    var ds = do_sin;
    if (phloat.lt(xv, phloat.fromInt(0))) {
        xv = phloat.neg(xv);
        if (ds) neg = true;
    }
    xv = phloat.fmod(xv, phloat.fromInt(400));
    if (phloat.ge(xv, phloat.fromInt(200))) {
        xv = phloat.sub(xv, phloat.fromInt(200));
        neg = !neg;
    }
    if (phloat.ge(xv, phloat.fromInt(100))) {
        xv = phloat.sub(xv, phloat.fromInt(100));
        ds = !ds;
        if (ds) neg = !neg;
    }
    var r: phloat.Phloat = undefined;
    if (phloat.eq(xv, phloat.fromInt(50))) {
        r = phloat.sqrt(phloat.fromString("0.5"));
    } else {
        if (phloat.gt(xv, phloat.fromInt(50))) {
            xv = phloat.sub(phloat.fromInt(100), xv);
            ds = !ds;
        }
        xv = phloat.div(xv, phloat.div(phloat.fromInt(200), phloat.PI));
        r = if (ds) phloat.sin(xv) else phloat.cos(xv);
    }
    return if (neg) phloat.neg(r) else r;
}

fn sinGrad(x0: phloat.Phloat) phloat.Phloat {
    return sinOrCosGrad(x0, true);
}
fn cosGrad(x0: phloat.Phloat) phloat.Phloat {
    return sinOrCosGrad(x0, false);
}

/// TAN with DEG/RAD/GRAD handling (matches core_math2.cc math_tan).
fn mathTan(x0: phloat.Phloat, out: *phloat.Phloat, rad: bool) Err {
    var xv = x0;
    var neg = false;
    var yv: phloat.Phloat = undefined;
    if (rad or globals.flags.rad) {
        yv = phloat.tan(xv);
    } else if (globals.flags.grad) {
        if (phloat.lt(xv, phloat.fromInt(0))) {
            xv = phloat.neg(xv);
            neg = true;
        }
        xv = phloat.fmod(xv, phloat.fromInt(200));
        if (phloat.eq(xv, phloat.fromInt(100))) {
            if (globals.flags.range_error_ignore) {
                out.* = phloat.POS_HUGE;
                return .none;
            }
            return .out_of_range;
        }
        if (phloat.gt(xv, phloat.fromInt(100))) {
            xv = phloat.sub(phloat.fromInt(200), xv);
            neg = !neg;
        }
        if (phloat.gt(xv, phloat.fromInt(89))) {
            yv = phloat.div(phloat.fromInt(1), phloat.tan(phloat.div(phloat.sub(phloat.fromInt(100), xv), phloat.div(phloat.fromInt(200), phloat.PI))));
        } else {
            yv = phloat.tan(phloat.div(xv, phloat.div(phloat.fromInt(200), phloat.PI)));
        }
        if (neg) yv = phloat.neg(yv);
    } else {
        if (phloat.lt(xv, phloat.fromInt(0))) {
            xv = phloat.neg(xv);
            neg = true;
        }
        xv = phloat.fmod(xv, phloat.fromInt(180));
        if (phloat.eq(xv, phloat.fromInt(90))) {
            if (globals.flags.range_error_ignore) {
                out.* = phloat.POS_HUGE;
                return .none;
            }
            return .out_of_range;
        }
        if (phloat.gt(xv, phloat.fromInt(90))) {
            xv = phloat.sub(phloat.fromInt(180), xv);
            neg = !neg;
        }
        if (phloat.gt(xv, phloat.fromInt(80))) {
            yv = phloat.div(phloat.fromInt(1), phloat.tan(phloat.div(phloat.sub(phloat.fromInt(90), xv), phloat.div(phloat.fromInt(180), phloat.PI))));
        } else {
            yv = phloat.tan(phloat.div(xv, phloat.div(phloat.fromInt(180), phloat.PI)));
        }
        if (neg) yv = phloat.neg(yv);
    }
    if (phloat.isNaN(yv) or phloat.isInf(yv)) {
        if (globals.flags.range_error_ignore) {
            out.* = phloat.POS_HUGE;
            return .none;
        }
        return .out_of_range;
    }
    out.* = yv;
    return .none;
}

// ---------------------------------------------------------------------------
// Complex math helpers (matches core_math2.cc)
// ---------------------------------------------------------------------------

fn mathAsinh(xre0: phloat.Phloat, xim0: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    var xre = xre0;
    var xim = xim0;
    if (phloat.isZero(xim)) {
        yre.* = phloat.asinh(xre);
        yim.* = phloat.fromInt(0);
        return .none;
    } else if (phloat.isZero(xre)) {
        if (phloat.gt(xim, phloat.fromInt(1))) {
            yre.* = phloat.acosh(xim);
            yim.* = phloat.PI_2;
        } else if (phloat.lt(xim, phloat.fromInt(-1))) {
            yre.* = phloat.neg(phloat.acosh(phloat.neg(xim)));
            yim.* = phloat.neg(phloat.PI_2);
        } else {
            yre.* = phloat.fromInt(0);
            yim.* = phloat.asin(xim);
        }
        return .none;
    }

    const neg = phloat.lt(xre, phloat.fromInt(0));
    if (neg) {
        xre = phloat.neg(xre);
        xim = phloat.neg(xim);
    }

    // a = x^2 + 1
    const are = phloat.add(phloat.sub(phloat.mul(xre, xre), phloat.mul(xim, xim)), phloat.fromInt(1));
    const aim = phloat.mul(phloat.mul(phloat.fromInt(2), xre), xim);

    // b = sqrt(a)
    const br = phloat.sqrt(phloat.hypot(are, aim));
    const bphi = phloat.div(phloat.atan2(aim, are), phloat.fromInt(2));

    // a = b + x
    var sre: phloat.Phloat = undefined;
    var sim: phloat.Phloat = undefined;
    phloat.sincos(bphi, &sim, &sre);
    const are2 = phloat.add(phloat.mul(sre, br), xre);
    const aim2 = phloat.add(phloat.mul(sim, br), xim);

    // y = log(a)
    yre.* = phloat.log(phloat.hypot(are2, aim2));
    yim.* = phloat.atan2(aim2, are2);
    if (neg) {
        yre.* = phloat.neg(yre.*);
        yim.* = phloat.neg(yim.*);
    }
    return .none;
}

fn mathAcosh(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        if (phloat.ge(xre, phloat.fromInt(1))) {
            yre.* = phloat.acosh(xre);
            yim.* = phloat.fromInt(0);
        } else if (phloat.le(xre, phloat.fromInt(-1))) {
            yre.* = phloat.acosh(phloat.neg(xre));
            yim.* = phloat.PI;
        } else {
            yre.* = phloat.fromInt(0);
            yim.* = phloat.acos(xre);
        }
        return .none;
    } else if (phloat.isZero(xre)) {
        if (phloat.gt(xim, phloat.fromInt(0))) {
            yre.* = phloat.asinh(xim);
            yim.* = phloat.PI_2;
        } else {
            yre.* = phloat.neg(phloat.asinh(xim));
            yim.* = phloat.neg(phloat.PI_2);
        }
        return .none;
    }

    // a = sqrt(x - 1)
    var are: phloat.Phloat = undefined;
    var aim: phloat.Phloat = undefined;
    _ = mathSqrt(phloat.sub(xre, phloat.fromInt(1)), xim, &are, &aim);
    // b = sqrt(x + 1)
    var bre: phloat.Phloat = undefined;
    var bim: phloat.Phloat = undefined;
    _ = mathSqrt(phloat.add(xre, phloat.fromInt(1)), xim, &bre, &bim);

    yre.* = phloat.asinh(phloat.add(phloat.mul(are, bre), phloat.mul(aim, bim)));
    yim.* = phloat.mul(phloat.atan(phloat.div(aim, bre)), phloat.fromInt(2));
    return .none;
}

fn mathAtanh(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        if (phloat.eq(xre, phloat.fromInt(1)) or phloat.eq(xre, phloat.fromInt(-1)))
            return .invalid_data
        else if (phloat.gt(xre, phloat.fromInt(-1)) and phloat.lt(xre, phloat.fromInt(1))) {
            yre.* = phloat.atanh(xre);
            yim.* = phloat.fromInt(0);
            return .none;
        } else {
            yre.* = phloat.atanh(phloat.div(phloat.fromInt(1), xre));
            if (phloat.gt(xre, phloat.fromInt(1)))
                yim.* = phloat.neg(phloat.PI_2)
            else
                yim.* = phloat.PI_2;
            return .none;
        }
    } else if (phloat.isZero(xre)) {
        yre.* = phloat.fromInt(0);
        yim.* = phloat.atan(xim);
        return .none;
    }

    // a = 1 + x
    const are = phloat.add(phloat.fromInt(1), xre);
    const aim = xim;
    // b = 1 - x
    const bre = phloat.sub(phloat.fromInt(1), xre);
    const bim = phloat.neg(xim);
    // c = a / b
    const h = phloat.hypot(bre, bim);
    const cre = phloat.div(phloat.add(phloat.mul(are, bre), phloat.mul(aim, bim)), phloat.mul(h, h));
    const cim = phloat.div(phloat.sub(phloat.mul(aim, bre), phloat.mul(are, bim)), phloat.mul(h, h));
    // y = log(c) / 2
    yre.* = phloat.div(phloat.log(phloat.hypot(cre, cim)), phloat.fromInt(2));
    yim.* = phloat.div(phloat.atan2(cim, cre), phloat.fromInt(2));
    return .none;
}

fn mathSqrt(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xre)) {
        if (phloat.isZero(xim)) {
            yre.* = phloat.fromInt(0);
            yim.* = phloat.fromInt(0);
        } else {
            const neg = phloat.lt(xim, phloat.fromInt(0));
            const xim2 = if (neg) phloat.neg(xim) else xim;
            const r = if (phloat.gt(xim2, phloat.fromInt(1))) phloat.sqrt(phloat.div(xim2, phloat.fromInt(2))) else phloat.div(phloat.sqrt(phloat.mul(xim2, phloat.fromInt(2))), phloat.fromInt(2));
            yre.* = r;
            yim.* = if (neg) phloat.neg(r) else r;
        }
        return .none;
    } else if (phloat.isZero(xim)) {
        if (phloat.gt(xre, phloat.fromInt(0))) {
            yre.* = phloat.sqrt(xre);
            yim.* = phloat.fromInt(0);
        } else {
            yre.* = phloat.fromInt(0);
            yim.* = phloat.sqrt(phloat.neg(xre));
        }
        return .none;
    }

    var xre2 = xre;
    var xim2 = xim;
    var r = phloat.hypot(xre2, xim2);
    var a = phloat.sqrt(phloat.div(phloat.add(r, phloat.abs(xre2)), phloat.fromInt(2)));
    var b = phloat.div(xim2, phloat.mul(a, phloat.fromInt(2)));

    if (phloat.isInf(a)) {
        xre2 = phloat.div(xre2, phloat.fromInt(100));
        xim2 = phloat.div(xim2, phloat.fromInt(100));
        r = phloat.hypot(xre2, xim2);
        a = phloat.sqrt(phloat.div(phloat.add(r, phloat.abs(xre2)), phloat.fromInt(2)));
        b = phloat.div(xim2, phloat.mul(a, phloat.fromInt(2)));
        a = phloat.mul(a, phloat.fromInt(10));
        b = phloat.mul(b, phloat.fromInt(10));
    }

    if (phloat.ge(xre, phloat.fromInt(0))) {
        yre.* = a;
        yim.* = b;
    } else if (phloat.ge(xim, phloat.fromInt(0))) {
        yre.* = b;
        yim.* = a;
    } else {
        yre.* = phloat.neg(b);
        yim.* = phloat.neg(a);
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Coordinate conversions (matches core_helpers.cc generic_r2p / generic_p2r)
// ---------------------------------------------------------------------------

fn genericR2p(re: phloat.Phloat, im: phloat.Phloat, r: *phloat.Phloat, phi: *phloat.Phloat) void {
    if (phloat.isZero(im)) {
        if (phloat.ge(re, phloat.fromInt(0))) {
            r.* = re;
            phi.* = phloat.fromInt(0);
        } else {
            r.* = phloat.neg(re);
            phi.* = if (globals.flags.rad) phloat.PI else if (globals.flags.grad) phloat.fromInt(200) else phloat.fromInt(180);
        }
    } else if (phloat.isZero(re)) {
        if (phloat.gt(im, phloat.fromInt(0))) {
            r.* = im;
            phi.* = if (globals.flags.rad) phloat.PI_2 else if (globals.flags.grad) phloat.fromInt(100) else phloat.fromInt(90);
        } else {
            r.* = phloat.neg(im);
            phi.* = if (globals.flags.rad) phloat.neg(phloat.PI_2) else if (globals.flags.grad) phloat.fromInt(-100) else phloat.fromInt(-90);
        }
    } else {
        r.* = phloat.hypot(re, im);
        phi.* = helpers.radToAngle(phloat.atan2(im, re));
    }
}

fn genericP2r(r: phloat.Phloat, phi0: phloat.Phloat, re: *phloat.Phloat, im: *phloat.Phloat) void {
    var phi = phi0;
    var tre: phloat.Phloat = undefined;
    var tim: phloat.Phloat = undefined;
    if (globals.flags.rad) {
        phloat.sincos(phi, &tim, &tre);
    } else if (globals.flags.grad) {
        phi = phloat.fmod(phi, phloat.fromInt(400));
        if (phloat.lt(phi, phloat.fromInt(0))) phi = phloat.add(phi, phloat.fromInt(400));
        if (phloat.eq(phi, phloat.fromInt(0))) {
            tre = phloat.fromInt(1);
            tim = phloat.fromInt(0);
        } else if (phloat.eq(phi, phloat.fromInt(100))) {
            tre = phloat.fromInt(0);
            tim = phloat.fromInt(1);
        } else if (phloat.eq(phi, phloat.fromInt(200))) {
            tre = phloat.fromInt(-1);
            tim = phloat.fromInt(0);
        } else if (phloat.eq(phi, phloat.fromInt(300))) {
            tre = phloat.fromInt(0);
            tim = phloat.fromInt(-1);
        } else {
            tre = cosGrad(phi);
            tim = sinGrad(phi);
        }
    } else {
        phi = phloat.fmod(phi, phloat.fromInt(360));
        if (phloat.lt(phi, phloat.fromInt(0))) phi = phloat.add(phi, phloat.fromInt(360));
        if (phloat.eq(phi, phloat.fromInt(0))) {
            tre = phloat.fromInt(1);
            tim = phloat.fromInt(0);
        } else if (phloat.eq(phi, phloat.fromInt(90))) {
            tre = phloat.fromInt(0);
            tim = phloat.fromInt(1);
        } else if (phloat.eq(phi, phloat.fromInt(180))) {
            tre = phloat.fromInt(-1);
            tim = phloat.fromInt(0);
        } else if (phloat.eq(phi, phloat.fromInt(270))) {
            tre = phloat.fromInt(0);
            tim = phloat.fromInt(-1);
        } else {
            tre = cosDeg(phi);
            tim = sinDeg(phi);
        }
    }
    re.* = phloat.mul(r, tre);
    im.* = phloat.mul(r, tim);
}

// ---------------------------------------------------------------------------
// Trig commands
// ---------------------------------------------------------------------------

fn mappableSinR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (globals.flags.rad)
        out.* = phloat.sin(xv)
    else if (globals.flags.grad)
        out.* = sinGrad(xv)
    else
        out.* = sinDeg(xv);
    return .none;
}

fn mappableSinC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    // NOTE: DEG/RAD/GRAD mode does not apply here.
    if (phloat.isZero(xim)) {
        yre.* = phloat.sin(xre);
        yim.* = phloat.fromInt(0);
        return .none;
    } else if (phloat.isZero(xre)) {
        yre.* = phloat.fromInt(0);
        yim.* = phloat.sinh(xim);
        return .none;
    }
    var sinxre: phloat.Phloat = undefined;
    var cosxre: phloat.Phloat = undefined;
    phloat.sincos(xre, &sinxre, &cosxre);
    const sinhxim = phloat.sinh(xim);
    const coshxim = phloat.cosh(xim);
    const e1 = checkRange(phloat.mul(sinxre, coshxim), yre);
    if (e1 != .none) return e1;
    return checkRange(phloat.mul(cosxre, sinhxim), yim);
}

pub fn docmdSin(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableSinR, mappableSinC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableCosR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (globals.flags.rad)
        out.* = phloat.cos(xv)
    else if (globals.flags.grad)
        out.* = cosGrad(xv)
    else
        out.* = cosDeg(xv);
    return .none;
}

fn mappableCosC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        yre.* = phloat.cos(xre);
        yim.* = phloat.fromInt(0);
        return .none;
    } else if (phloat.isZero(xre)) {
        const e = checkRange(phloat.cosh(xim), yre);
        if (e != .none) return e;
        yim.* = phloat.fromInt(0);
        return .none;
    }
    var sinxre: phloat.Phloat = undefined;
    var cosxre: phloat.Phloat = undefined;
    phloat.sincos(xre, &sinxre, &cosxre);
    const sinhxim = phloat.sinh(xim);
    const coshxim = phloat.cosh(xim);
    const e1 = checkRange(phloat.mul(cosxre, coshxim), yre);
    if (e1 != .none) return e1;
    return checkRange(phloat.neg(phloat.mul(sinxre, sinhxim)), yim);
}

pub fn docmdCos(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableCosR, mappableCosC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableTanR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    return mathTan(xv, out, false);
}

fn mappableTanC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        yim.* = phloat.fromInt(0);
        return mathTan(xre, yre, true);
    } else if (phloat.isZero(xre)) {
        yre.* = phloat.fromInt(0);
        yim.* = phloat.tanh(xim);
        return .none;
    }
    if (phloat.isNaN(xre) or phloat.isNaN(xim)) {
        yre.* = phloat.NAN;
        yim.* = phloat.NAN;
        return .none;
    }
    var sinxre: phloat.Phloat = undefined;
    var cosxre: phloat.Phloat = undefined;
    phloat.sincos(xre, &sinxre, &cosxre);
    const sinhxim = phloat.sinh(xim);
    const coshxim = phloat.cosh(xim);
    const d = phloat.add(phloat.mul(cosxre, cosxre), phloat.mul(sinhxim, sinhxim));
    if (phloat.isZero(d)) {
        if (globals.flags.range_error_ignore) {
            yre.* = phloat.POS_HUGE;
            yim.* = phloat.POS_HUGE;
            return .none;
        }
        return .out_of_range;
    }
    if (phloat.isInf(d)) {
        yre.* = phloat.fromInt(0);
        yim.* = if (phloat.lt(xim, phloat.fromInt(0))) phloat.fromInt(-1) else phloat.fromInt(1);
        return .none;
    }
    yre.* = phloat.div(phloat.mul(sinxre, cosxre), d);
    yim.* = phloat.div(phloat.mul(sinhxim, coshxim), d);
    return .none;
}

pub fn docmdTan(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableTanR, mappableTanC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableAsinR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(xv, phloat.fromInt(-1)) or phloat.gt(xv, phloat.fromInt(1)))
        return .invalid_data;
    if (!globals.flags.rad) {
        if (phloat.eq(xv, phloat.fromInt(1))) {
            out.* = if (globals.flags.grad) phloat.fromInt(100) else phloat.fromInt(90);
            return .none;
        } else if (phloat.eq(xv, phloat.fromInt(-1))) {
            out.* = if (globals.flags.grad) phloat.fromInt(-100) else phloat.fromInt(-90);
            return .none;
        }
    }
    out.* = helpers.radToAngle(phloat.asin(xv));
    return .none;
}

fn mappableAsinC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    var tre: phloat.Phloat = undefined;
    var tim: phloat.Phloat = undefined;
    const e = mathAsinh(phloat.neg(xim), xre, &tre, &tim);
    yre.* = tim;
    yim.* = phloat.neg(tre);
    return e;
}

pub fn docmdAsin(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    if (x().* == .real) {
        const xv = x().real;
        if (phloat.lt(xv, phloat.fromInt(-1)) or phloat.gt(xv, phloat.fromInt(1))) {
            if (globals.flags.real_result_only) return .invalid_data;
            v = if (phloat.gt(xv, phloat.fromInt(0)))
                vartype.newComplex(phloat.PI_2, phloat.neg(phloat.acosh(xv)))
            else
                vartype.newComplex(phloat.neg(phloat.PI_2), phloat.acosh(phloat.neg(xv)));
        } else {
            v = vartype.newReal(phloat.fromInt(0));
            if (v != null) _ = mappableAsinR(xv, &v.?.real);
        }
        if (v == null) return .insufficient_memory;
    } else {
        const e = helpers.mapUnary(x(), &v, mappableAsinR, mappableAsinC);
        if (e != .none) return e;
    }
    helpers.unaryResult(v.?);
    return .none;
}

fn mappableAcosR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(xv, phloat.fromInt(-1)) or phloat.gt(xv, phloat.fromInt(1)))
        return .invalid_data;
    if (!globals.flags.rad) {
        if (phloat.eq(xv, phloat.fromInt(0))) {
            out.* = if (globals.flags.grad) phloat.fromInt(100) else phloat.fromInt(90);
            return .none;
        } else if (phloat.eq(xv, phloat.fromInt(-1))) {
            out.* = if (globals.flags.grad) phloat.fromInt(200) else phloat.fromInt(180);
            return .none;
        }
    }
    out.* = helpers.radToAngle(phloat.acos(xv));
    return .none;
}

fn mappableAcosC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    var tre: phloat.Phloat = undefined;
    var tim: phloat.Phloat = undefined;
    const e = mathAcosh(xre, xim, &tre, &tim);
    if (phloat.lt(xim, phloat.fromInt(0)) or (phloat.isZero(xim) and phloat.gt(xre, phloat.fromInt(1)))) {
        yre.* = phloat.neg(tim);
        yim.* = tre;
    } else {
        yre.* = tim;
        yim.* = phloat.neg(tre);
    }
    return e;
}

pub fn docmdAcos(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    if (x().* == .real) {
        const xv = x().real;
        if (phloat.lt(xv, phloat.fromInt(-1)) or phloat.gt(xv, phloat.fromInt(1))) {
            if (globals.flags.real_result_only) return .invalid_data;
            v = if (phloat.gt(xv, phloat.fromInt(0)))
                vartype.newComplex(phloat.fromInt(0), phloat.acosh(xv))
            else
                vartype.newComplex(phloat.PI, phloat.neg(phloat.acosh(phloat.neg(xv))));
        } else {
            v = vartype.newReal(phloat.fromInt(0));
            if (v != null) _ = mappableAcosR(xv, &v.?.real);
        }
        if (v == null) return .insufficient_memory;
    } else {
        const e = helpers.mapUnary(x(), &v, mappableAcosR, mappableAcosC);
        if (e != .none) return e;
    }
    helpers.unaryResult(v.?);
    return .none;
}

fn mappableAtanR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (!globals.flags.rad) {
        if (phloat.isInf(xv)) {
            out.* = if (globals.flags.grad) phloat.fromInt(100) else phloat.fromInt(90);
            return .none;
        } else if (phloat.eq(xv, phloat.fromInt(1))) {
            out.* = if (globals.flags.grad) phloat.fromInt(50) else phloat.fromInt(45);
            return .none;
        } else if (phloat.eq(xv, phloat.fromInt(-1))) {
            out.* = if (globals.flags.grad) phloat.fromInt(-50) else phloat.fromInt(-45);
            return .none;
        }
    }
    out.* = helpers.radToAngle(phloat.atan(xv));
    return .none;
}

fn mappableAtanC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    var tre: phloat.Phloat = undefined;
    var tim: phloat.Phloat = undefined;
    const e = mathAtanh(xim, phloat.neg(xre), &tre, &tim);
    yre.* = phloat.neg(tim);
    yim.* = tre;
    return e;
}

pub fn docmdAtan(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableAtanR, mappableAtanC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

// ---------------------------------------------------------------------------
// Log / exp commands
// ---------------------------------------------------------------------------

fn mappableLogR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.le(xv, phloat.fromInt(0))) return .invalid_data;
    out.* = phloat.log10(xv);
    return .none;
}

fn mappableLogC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        if (phloat.isZero(xre)) return .invalid_data;
        if (phloat.gt(xre, phloat.fromInt(0))) {
            yre.* = phloat.log10(xre);
            yim.* = phloat.fromInt(0);
        } else {
            yre.* = phloat.log10(phloat.neg(xre));
            yim.* = phloat.div(phloat.PI, phloat.log(phloat.fromInt(10)));
        }
        return .none;
    } else if (phloat.isZero(xre)) {
        if (phloat.gt(xim, phloat.fromInt(0))) {
            yre.* = phloat.log10(xim);
            yim.* = phloat.div(phloat.PI, phloat.log(phloat.fromInt(100)));
        } else {
            yre.* = phloat.log10(phloat.neg(xim));
            yim.* = phloat.neg(phloat.div(phloat.PI, phloat.log(phloat.fromInt(100))));
        }
        return .none;
    } else {
        var h = phloat.hypot(xre, xim);
        if (phloat.isInf(h)) {
            const s = phloat.fromInt(10000);
            h = phloat.hypot(phloat.div(xre, s), phloat.div(xim, s));
            yre.* = phloat.add(phloat.log10(h), phloat.fromInt(4));
        } else {
            yre.* = phloat.log10(h);
        }
        yim.* = phloat.div(phloat.atan2(xim, xre), phloat.log(phloat.fromInt(10)));
        return .none;
    }
}

pub fn docmdLog(arg: ?*const commands1.Arg) Err {
    _ = arg;
    if (x().* == .real) {
        const xv = x().real;
        if (phloat.isZero(xv)) return .invalid_data;
        if (phloat.lt(xv, phloat.fromInt(0))) {
            if (globals.flags.real_result_only) return .invalid_data;
            const v = vartype.newComplex(phloat.log10(phloat.neg(xv)), phloat.div(phloat.PI, phloat.log(phloat.fromInt(10)))) orelse return .insufficient_memory;
            helpers.unaryResult(v);
            return .none;
        }
        const v = vartype.newReal(phloat.log10(xv)) orelse return .insufficient_memory;
        helpers.unaryResult(v);
        return .none;
    }
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableLogR, mappableLogC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableLnR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.le(xv, phloat.fromInt(0))) return .invalid_data;
    out.* = phloat.log(xv);
    return .none;
}

fn mappableLnC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        if (phloat.isZero(xre)) return .invalid_data;
        if (phloat.gt(xre, phloat.fromInt(0))) {
            yre.* = phloat.log(xre);
            yim.* = phloat.fromInt(0);
        } else {
            yre.* = phloat.log(phloat.neg(xre));
            yim.* = phloat.PI;
        }
        return .none;
    } else if (phloat.isZero(xre)) {
        if (phloat.gt(xim, phloat.fromInt(0))) {
            yre.* = phloat.log(xim);
            yim.* = phloat.PI_2;
        } else {
            yre.* = phloat.log(phloat.neg(xim));
            yim.* = phloat.neg(phloat.PI_2);
        }
        return .none;
    } else {
        var h = phloat.hypot(xre, xim);
        if (phloat.isInf(h)) {
            const s = phloat.fromInt(10000);
            h = phloat.hypot(phloat.div(xre, s), phloat.div(xim, s));
            yre.* = phloat.add(phloat.log(h), phloat.log(s));
        } else {
            yre.* = phloat.log(h);
        }
        yim.* = phloat.atan2(xim, xre);
        return .none;
    }
}

pub fn docmdLn(arg: ?*const commands1.Arg) Err {
    _ = arg;
    if (x().* == .real) {
        const xv = x().real;
        if (phloat.isZero(xv)) return .invalid_data;
        if (phloat.lt(xv, phloat.fromInt(0))) {
            if (globals.flags.real_result_only) return .invalid_data;
            const v = vartype.newComplex(phloat.log(phloat.neg(xv)), phloat.PI) orelse return .insufficient_memory;
            helpers.unaryResult(v);
            return .none;
        }
        const v = vartype.newReal(phloat.log(xv)) orelse return .insufficient_memory;
        helpers.unaryResult(v);
        return .none;
    }
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableLnR, mappableLnC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableTenPowXR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    const r = phloat.pow(phloat.fromInt(10), xv);
    if (phloat.isInf(r)) {
        if (!globals.flags.range_error_ignore) return .out_of_range;
        out.* = phloat.POS_HUGE;
        return .none;
    }
    out.* = r;
    return .none;
}

fn mappableTenPowXC(xre: phloat.Phloat, xim0: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    var xim = phloat.mul(xim0, phloat.log(phloat.fromInt(10)));
    const inf0 = pIsinf(xim);
    if (inf0 != 0) xim = if (inf0 < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
    const h = phloat.pow(phloat.fromInt(10), xre);
    const inf = pIsinf(h);
    if (inf == 0) {
        yre.* = phloat.mul(phloat.cos(xim), h);
        yim.* = phloat.mul(phloat.sin(xim), h);
        return .none;
    } else if (globals.flags.range_error_ignore) {
        var t = phloat.cos(xim);
        if (phloat.isZero(t))
            yre.* = phloat.fromInt(0)
        else if (phloat.lt(t, phloat.fromInt(0)))
            yre.* = if (inf < 0) phloat.POS_HUGE else phloat.NEG_HUGE
        else
            yre.* = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
        t = phloat.sin(xim);
        if (phloat.isZero(t))
            yim.* = phloat.fromInt(0)
        else if (phloat.lt(t, phloat.fromInt(0)))
            yim.* = if (inf < 0) phloat.POS_HUGE else phloat.NEG_HUGE
        else
            yim.* = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
        return .none;
    }
    return .out_of_range;
}

pub fn docmdTenPowX(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableTenPowXR, mappableTenPowXC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableEPowXR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    const r = phloat.exp(xv);
    if (phloat.isInf(r)) {
        if (!globals.flags.range_error_ignore) return .out_of_range;
        out.* = phloat.POS_HUGE;
        return .none;
    }
    out.* = r;
    return .none;
}

fn mappableEPowXC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    const h = phloat.exp(xre);
    const inf = pIsinf(h);
    if (inf == 0) {
        yre.* = phloat.mul(phloat.cos(xim), h);
        yim.* = phloat.mul(phloat.sin(xim), h);
        return .none;
    } else if (globals.flags.range_error_ignore) {
        var t = phloat.cos(xim);
        if (phloat.isZero(t))
            yre.* = phloat.fromInt(0)
        else if (phloat.lt(t, phloat.fromInt(0)))
            yre.* = if (inf < 0) phloat.POS_HUGE else phloat.NEG_HUGE
        else
            yre.* = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
        t = phloat.sin(xim);
        if (phloat.isZero(t))
            yim.* = phloat.fromInt(0)
        else if (phloat.lt(t, phloat.fromInt(0)))
            yim.* = if (inf < 0) phloat.POS_HUGE else phloat.NEG_HUGE
        else
            yim.* = if (inf < 0) phloat.NEG_HUGE else phloat.POS_HUGE;
        return .none;
    }
    return .out_of_range;
}

pub fn docmdEPowX(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableEPowXR, mappableEPowXC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

// ---------------------------------------------------------------------------
// SQRT / X^2 / 1/X
// ---------------------------------------------------------------------------

fn mappableSqrtR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.lt(xv, phloat.fromInt(0))) return .invalid_data;
    out.* = phloat.sqrt(xv);
    return .none;
}

pub fn docmdSqrt(arg: ?*const commands1.Arg) Err {
    _ = arg;
    if (x().* == .real) {
        const xv = x().real;
        var v: ?*Vartype = null;
        if (phloat.lt(xv, phloat.fromInt(0))) {
            if (globals.flags.real_result_only) return .invalid_data;
            v = vartype.newComplex(phloat.fromInt(0), phloat.sqrt(phloat.neg(xv)));
        } else {
            v = vartype.newReal(phloat.sqrt(xv));
        }
        if (v == null) return .insufficient_memory;
        helpers.unaryResult(v.?);
        return .none;
    }
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableSqrtR, mathSqrt);
    if (e != .none) return e;
    helpers.unaryResult(v.?);
    return .none;
}

fn mappableSquareR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    return checkRange(phloat.mul(xv, xv), out);
}

fn mappableSquareC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    const e1 = checkRange(phloat.sub(phloat.mul(xre, xre), phloat.mul(xim, xim)), yre);
    if (e1 != .none) return e1;
    return checkRange(phloat.mul(phloat.mul(phloat.fromInt(2), xre), xim), yim);
}

pub fn docmdSquare(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableSquareR, mappableSquareC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableInvR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.isZero(xv)) return .divide_by_0;
    return checkRange(phloat.div(phloat.fromInt(1), xv), out);
}

fn mappableInvC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xre) and phloat.isZero(xim)) return .divide_by_0;
    var r: phloat.Phloat = undefined;
    var t: phloat.Phloat = undefined;
    var rre: phloat.Phloat = undefined;
    var rim: phloat.Phloat = undefined;
    if (phloat.le(phloat.abs(xim), phloat.abs(xre))) {
        r = phloat.div(xim, xre);
        t = phloat.div(phloat.fromInt(1), phloat.add(xre, phloat.mul(xim, r)));
        if (phloat.isZero(r)) {
            rre = t;
            rim = phloat.neg(phloat.mul(phloat.mul(xim, phloat.div(phloat.fromInt(1), xre)), t));
        } else {
            rre = t;
            rim = phloat.neg(phloat.mul(r, t));
        }
    } else {
        r = phloat.div(xre, xim);
        t = phloat.div(phloat.fromInt(1), phloat.add(phloat.mul(xre, r), xim));
        if (phloat.isZero(r)) {
            rre = phloat.mul(phloat.mul(xre, phloat.div(phloat.fromInt(1), xim)), t);
            rim = phloat.neg(t);
        } else {
            rre = phloat.mul(r, t);
            rim = phloat.neg(t);
        }
    }
    const e1 = checkRange(rre, yre);
    if (e1 != .none) return e1;
    return checkRange(rim, yim);
}

pub fn docmdInv(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableInvR, mappableInvC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

// ---------------------------------------------------------------------------
// Y^X
// ---------------------------------------------------------------------------

/// Complex (or negative real) base to a real power, via the polar formula
/// (matches the `complex_pow_real_1`/`complex_pow_real_2` labels in Free42).
fn complexPowReal(yre: phloat.Phloat, yim: phloat.Phloat, xv: phloat.Phloat, out: *?*Vartype) Err {
    const yr0 = phloat.hypot(yre, yim);
    const yphi0 = if (phloat.isZero(yim))
        (if (phloat.ge(yre, phloat.fromInt(0))) phloat.fromInt(0) else phloat.PI)
    else
        phloat.atan2(yim, yre);
    const yr = phloat.pow(yr0, xv);
    const yphi = phloat.mul(yphi0, xv);
    var rre: phloat.Phloat = undefined;
    var rim: phloat.Phloat = undefined;
    if (phloat.isInf(yr)) {
        if (!globals.flags.range_error_ignore) return .out_of_range;
        var re: phloat.Phloat = undefined;
        var im: phloat.Phloat = undefined;
        phloat.sincos(yphi, &im, &re);
        rre = if (phloat.isZero(re)) phloat.fromInt(0) else if (phloat.lt(re, phloat.fromInt(0))) phloat.NEG_HUGE else phloat.POS_HUGE;
        rim = if (phloat.isZero(im)) phloat.fromInt(0) else if (phloat.lt(im, phloat.fromInt(0))) phloat.POS_HUGE else phloat.NEG_HUGE;
    } else {
        var re: phloat.Phloat = undefined;
        var im: phloat.Phloat = undefined;
        phloat.sincos(yphi, &im, &re);
        rre = phloat.mul(yr, re);
        rim = phloat.mul(yr, im);
    }
    out.* = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
    return .none;
}

pub fn docmdYPowX(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var res: ?*Vartype = null;
    const xv = x();
    const yv = y();

    if (xv.* == .string or yv.* == .string) return .alpha_data_is_invalid;
    const x_is_num = xv.* == .real or xv.* == .complex;
    const y_is_num = yv.* == .real or yv.* == .complex;
    if (!x_is_num or !y_is_num) return .invalid_type;

    if (xv.* == .real) {
        const xr = xv.real;
        if (phloat.isInteger(xr)) {
            // Integer exponent.
            if (yv.* == .real) {
                const yr = yv.real;
                if (phloat.isZero(xr) and phloat.isZero(yr)) return .invalid_data;
                var r = phloat.pow(yr, xr);
                if (phloat.isNaN(r)) return .invalid_data;
                const e = checkRange(r, &r);
                if (e != .none) return e;
                res = vartype.newReal(r) orelse return .insufficient_memory;
            } else {
                // Complex base to integer power (repeated squaring).
                const yre = yv.complex.re;
                const yim = yv.complex.im;
                if (phloat.lt(xr, phloat.fromInt(-256)) or phloat.gt(xr, phloat.fromInt(256))) {
                    return complexPowReal(yre, yim, xr, &res);
                }
                var rre = phloat.fromInt(1);
                var rim = phloat.fromInt(0);
                var bre = yre;
                var bim = yim;
                var ex = phloat.toInt64(xr);
                if (ex <= 0 and phloat.isZero(yre) and phloat.isZero(yim)) return .invalid_data;
                const invert = ex < 0;
                if (invert) ex = -ex;
                var overflow = false;
                while (true) {
                    if ((ex & 1) != 0) {
                        const tmp = phloat.sub(phloat.mul(rre, bre), phloat.mul(rim, bim));
                        rim = phloat.add(phloat.mul(rre, bim), phloat.mul(rim, bre));
                        rre = tmp;
                        if (phloat.isInf(rre) or phloat.isNaN(rre) or phloat.isInf(rim) or phloat.isNaN(rim)) {
                            overflow = true;
                            break;
                        }
                        if (phloat.isZero(rre) and phloat.isZero(rim)) {
                            if (invert) {
                                overflow = true;
                                break;
                            }
                            break;
                        }
                    }
                    ex >>= 1;
                    if (ex == 0) break;
                    const tmp = phloat.sub(phloat.mul(bre, bre), phloat.mul(bim, bim));
                    bim = phloat.mul(phloat.mul(phloat.fromInt(2), bre), bim);
                    bre = tmp;
                    if (phloat.isInf(bre) or phloat.isNaN(bre) or phloat.isInf(bim) or phloat.isNaN(bim)) {
                        overflow = true;
                        break;
                    }
                }
                if (overflow) {
                    return complexPowReal(yre, yim, xr, &res);
                }
                if (invert) {
                    const h = phloat.hypot(rre, rim);
                    rre = phloat.div(phloat.div(rre, h), h);
                    rim = phloat.div(phloat.neg(rim), phloat.mul(h, h));
                }
                const e1 = checkRange(rre, &rre);
                if (e1 != .none) return e1;
                const e2 = checkRange(rim, &rim);
                if (e2 != .none) return e2;
                res = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
            }
        } else if (yv.* == .real) {
            // Real base to noninteger real power.
            const yr = yv.real;
            if (phloat.lt(yr, phloat.fromInt(0))) {
                if (globals.flags.real_result_only) return .invalid_data;
                return complexPowReal(yr, phloat.fromInt(0), xr, &res);
            }
            var r = phloat.pow(yr, xr);
            const e = checkRange(r, &r);
            if (e != .none) return e;
            res = vartype.newReal(r) orelse return .insufficient_memory;
        } else {
            // Complex (or negative real) base to noninteger real power.
            return complexPowReal(yv.complex.re, yv.complex.im, xr, &res);
        }
    } else {
        // Real or complex base to complex power.
        const xre = xv.complex.re;
        const xim = xv.complex.im;
        const yre = if (yv.* == .real) yv.real else yv.complex.re;
        const yim = if (yv.* == .real) phloat.fromInt(0) else yv.complex.im;
        if (phloat.isZero(yre) and phloat.isZero(yim)) {
            if (phloat.le(xre, phloat.fromInt(0))) return .invalid_data;
            res = vartype.newComplex(phloat.fromInt(0), phloat.fromInt(0)) orelse return .insufficient_memory;
        } else {
            var lre: phloat.Phloat = undefined;
            var lim: phloat.Phloat = undefined;
            const e = mappableLnC(yre, yim, &lre, &lim);
            if (e != .none) return e;
            const tmp = phloat.sub(phloat.mul(lre, xre), phloat.mul(lim, xim));
            lim = phloat.add(phloat.mul(lre, xim), phloat.mul(lim, xre));
            lre = tmp;
            var rre: phloat.Phloat = undefined;
            var rim: phloat.Phloat = undefined;
            const e2 = mappableEPowXC(lre, lim, &rre, &rim);
            if (e2 != .none) return e2;
            res = vartype.newComplex(rre, rim) orelse return .insufficient_memory;
        }
    }
    return helpers.binaryResult(res.?);
}

// ---------------------------------------------------------------------------
// →REC / →POL
// ---------------------------------------------------------------------------

pub fn docmdToRec(arg: ?*const commands1.Arg) Err {
    _ = arg;
    if (x().* == .real) {
        if (y().* == .real) {
            const r = x().real;
            const phi = y().real;
            var rx: phloat.Phloat = undefined;
            var ry: phloat.Phloat = undefined;
            genericP2r(r, phi, &rx, &ry);
            const vx = vartype.newReal(rx) orelse return .insufficient_memory;
            const vy = vartype.newReal(ry) orelse {
                vartype.free(vx);
                return .insufficient_memory;
            };
            helpers.binaryTwoResults(vx, vy);
            return .none;
        } else if (y().* == .string) return .alpha_data_is_invalid;
        return .invalid_type;
    } else if (x().* == .complex) {
        const c = x().complex;
        var rx: phloat.Phloat = undefined;
        var ry: phloat.Phloat = undefined;
        genericP2r(c.re, c.im, &rx, &ry);
        const v = vartype.newComplex(rx, ry) orelse return .insufficient_memory;
        helpers.unaryResult(v);
        return .none;
    } else if (x().* == .string) return .alpha_data_is_invalid;
    return .invalid_type;
}

pub fn docmdToPol(arg: ?*const commands1.Arg) Err {
    _ = arg;
    if (x().* == .real) {
        if (y().* == .real) {
            const xr = x().real;
            const yr = y().real;
            var r: phloat.Phloat = undefined;
            var phi: phloat.Phloat = undefined;
            genericR2p(xr, yr, &r, &phi);
            if (phloat.isInf(r)) {
                if (globals.flags.range_error_ignore)
                    r = phloat.POS_HUGE
                else
                    return .out_of_range;
            }
            const vx = vartype.newReal(r) orelse return .insufficient_memory;
            const vy = vartype.newReal(phi) orelse {
                vartype.free(vx);
                return .insufficient_memory;
            };
            helpers.binaryTwoResults(vx, vy);
            return .none;
        } else if (y().* == .string) return .alpha_data_is_invalid;
        return .invalid_type;
    } else if (x().* == .complex) {
        const c = x().complex;
        var r: phloat.Phloat = undefined;
        var phi: phloat.Phloat = undefined;
        genericR2p(c.re, c.im, &r, &phi);
        if (phloat.isInf(r)) {
            if (globals.flags.range_error_ignore)
                r = phloat.POS_HUGE
            else
                return .out_of_range;
        }
        const v = vartype.newComplex(r, phi) orelse return .insufficient_memory;
        helpers.unaryResult(v);
        return .none;
    } else if (x().* == .string) return .alpha_data_is_invalid;
    return .invalid_type;
}

// ---------------------------------------------------------------------------
// RND
// ---------------------------------------------------------------------------

fn mappableRndR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (globals.flags.fix_or_all and !globals.flags.eng_or_all) {
        var t = xv;
        const neg = phloat.lt(t, phloat.fromInt(0));
        if (neg) t = phloat.neg(t);
        if (phloat.ge(t, phloat.pow10(34))) {
            out.* = xv;
        } else {
            t = phloat.div(phloat.floor(phloat.add(phloat.mul(t, rnd_multiplier), phloat.fromString("0.5"))), rnd_multiplier);
            out.* = if (neg) phloat.neg(t) else t;
        }
        return .none;
    } else {
        var t = xv;
        var neg = false;
        if (phloat.isZero(t)) {
            out.* = phloat.fromInt(0);
        } else {
            if (phloat.lt(t, phloat.fromInt(0))) {
                t = phloat.neg(t);
                neg = true;
            }
            var scale = phloat.pow(phloat.fromInt(10), phloat.floor(phloat.log10(t)));
            if (phloat.gt(scale, t)) scale = phloat.div(scale, phloat.fromInt(10));
            t = phloat.div(phloat.floor(phloat.add(phloat.mul(phloat.div(t, scale), rnd_multiplier), phloat.fromString("0.5"))), phloat.mul(rnd_multiplier, scale));
            if (phloat.isInf(t)) {
                if (globals.flags.range_error_ignore)
                    out.* = if (neg) phloat.NEG_HUGE else phloat.POS_HUGE
                else
                    return .out_of_range;
            } else {
                out.* = if (neg) phloat.neg(t) else t;
            }
        }
        return .none;
    }
}

fn mappableRndC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    const e = mappableRndR(xre, yre);
    if (e != .none) return e;
    return mappableRndR(xim, yim);
}

pub fn docmdRnd(arg: ?*const commands1.Arg) Err {
    _ = arg;
    const digits: i32 = if (globals.flags.fix_or_all and globals.flags.eng_or_all) 11 else @intCast(globals.displayDigits());
    rnd_multiplier = phloat.pow10(digits);
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableRndR, mappableRndC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

// ---------------------------------------------------------------------------
// FACT (N!)
// ---------------------------------------------------------------------------

fn mappableFact(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    var f = phloat.fromInt(1);
    var xr = xv;
    if (phloat.lt(xr, phloat.fromInt(0)) or !phloat.isInteger(xr)) return .invalid_data;
    while (phloat.gt(xr, phloat.fromInt(1))) {
        f = phloat.mul(f, xr);
        xr = phloat.sub(xr, phloat.fromInt(1));
        if (phloat.isInf(f)) {
            if (globals.flags.range_error_ignore) {
                out.* = phloat.POS_HUGE;
                return .none;
            }
            return .out_of_range;
        }
    }
    out.* = f;
    return .none;
}

pub fn docmdFact(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableFact, null);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

// ---------------------------------------------------------------------------
// Hyperbolic commands
// ---------------------------------------------------------------------------

fn mappableSinhR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    return checkRange(phloat.sinh(xv), out);
}

fn mappableSinhC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        yre.* = phloat.sinh(xre);
        yim.* = phloat.fromInt(0);
        return .none;
    } else if (phloat.isZero(xre)) {
        yre.* = phloat.fromInt(0);
        yim.* = phloat.sin(xim);
        return .none;
    }
    const sinhxre = phloat.sinh(xre);
    const coshxre = phloat.cosh(xre);
    var sinxim: phloat.Phloat = undefined;
    var cosxim: phloat.Phloat = undefined;
    phloat.sincos(xim, &sinxim, &cosxim);
    const e1 = checkRange(phloat.mul(sinhxre, cosxim), yre);
    if (e1 != .none) return e1;
    return checkRange(phloat.mul(coshxre, sinxim), yim);
}

pub fn docmdSinh(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableSinhR, mappableSinhC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableCoshR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    return checkRange(phloat.cosh(xv), out);
}

fn mappableCoshC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        yim.* = phloat.fromInt(0);
        return mappableCoshR(xre, yre);
    } else if (phloat.isZero(xre)) {
        yre.* = phloat.cos(xim);
        yim.* = phloat.fromInt(0);
        return .none;
    }
    const sinhxre = phloat.sinh(xre);
    const coshxre = phloat.cosh(xre);
    var sinxim: phloat.Phloat = undefined;
    var cosxim: phloat.Phloat = undefined;
    phloat.sincos(xim, &sinxim, &cosxim);
    const e1 = checkRange(phloat.mul(coshxre, cosxim), yre);
    if (e1 != .none) return e1;
    return checkRange(phloat.mul(sinhxre, sinxim), yim);
}

pub fn docmdCosh(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableCoshR, mappableCoshC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableTanhR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.tanh(xv);
    return .none;
}

fn mappableTanhC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xre)) {
        yre.* = phloat.fromInt(0);
        return mathTan(xim, yim, true);
    } else if (phloat.isZero(xim)) {
        yim.* = phloat.fromInt(0);
        yre.* = phloat.tanh(xre);
        return .none;
    }
    if (phloat.isNaN(xim) or phloat.isNaN(xre)) {
        yim.* = phloat.NAN;
        yre.* = phloat.NAN;
        return .none;
    }
    var sinxim: phloat.Phloat = undefined;
    var cosxim: phloat.Phloat = undefined;
    phloat.sincos(xim, &sinxim, &cosxim);
    const sinhxre = phloat.sinh(xre);
    const coshxre = phloat.cosh(xre);
    const d = phloat.add(phloat.mul(cosxim, cosxim), phloat.mul(sinhxre, sinhxre));
    if (phloat.isZero(d)) {
        if (globals.flags.range_error_ignore) {
            yim.* = phloat.POS_HUGE;
            yre.* = phloat.POS_HUGE;
            return .none;
        }
        return .out_of_range;
    }
    if (phloat.isInf(d)) {
        yim.* = phloat.fromInt(0);
        yre.* = if (phloat.lt(xre, phloat.fromInt(0))) phloat.fromInt(-1) else phloat.fromInt(1);
        return .none;
    }
    yim.* = phloat.div(phloat.mul(sinxim, cosxim), d);
    yre.* = phloat.div(phloat.mul(sinhxre, coshxre), d);
    return .none;
}

pub fn docmdTanh(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableTanhR, mappableTanhC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableAsinhR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.asinh(xv);
    return .none;
}

fn mappableAsinhC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    return mathAsinh(xre, xim, yre, yim);
}

pub fn docmdAsinh(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableAsinhR, mappableAsinhC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

fn mappableAcoshR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    out.* = phloat.acosh(xv);
    return .none;
}

fn mappableAcoshC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    return mathAcosh(xre, xim, yre, yim);
}

pub fn docmdAcosh(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    if (x().* == .real) {
        const xv = x().real;
        if (phloat.lt(xv, phloat.fromInt(1))) {
            if (globals.flags.real_result_only) return .invalid_data;
            var re: phloat.Phloat = undefined;
            var im: phloat.Phloat = undefined;
            const e = mathAcosh(xv, phloat.fromInt(0), &re, &im);
            if (e != .none) return e;
            v = vartype.newComplex(re, im);
        } else {
            v = vartype.newReal(phloat.acosh(xv));
        }
        if (v == null) return .insufficient_memory;
    } else {
        const e = helpers.mapUnary(x(), &v, mappableAcoshR, mappableAcoshC);
        if (e != .none) return e;
    }
    helpers.unaryResult(v.?);
    return .none;
}

fn mappableAtanhR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.eq(xv, phloat.fromInt(1)) or phloat.eq(xv, phloat.fromInt(-1))) return .invalid_data;
    out.* = phloat.atanh(xv);
    return .none;
}

pub fn docmdAtanh(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    if (x().* == .real) {
        const xv = x().real;
        if (phloat.eq(xv, phloat.fromInt(1)) or phloat.eq(xv, phloat.fromInt(-1))) return .invalid_data;
        if (phloat.lt(xv, phloat.fromInt(-1)) or phloat.gt(xv, phloat.fromInt(1))) {
            if (globals.flags.real_result_only) return .invalid_data;
            var tre: phloat.Phloat = undefined;
            var tim: phloat.Phloat = undefined;
            const e = mathAtanh(xv, phloat.fromInt(0), &tre, &tim);
            if (e != .none) return e;
            v = vartype.newComplex(tre, tim);
        } else {
            v = vartype.newReal(phloat.atanh(xv));
        }
        if (v == null) return .insufficient_memory;
        helpers.unaryResult(v.?);
        return .none;
    }
    const e = helpers.mapUnary(x(), &v, mappableAtanhR, mathAtanh);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

// ---------------------------------------------------------------------------
// LN1+X
// ---------------------------------------------------------------------------

fn mappableLn1pXR(xv: phloat.Phloat, out: *phloat.Phloat) Err {
    if (phloat.le(xv, phloat.fromInt(-1))) return .invalid_data;
    out.* = phloat.log1p(xv);
    return .none;
}

fn mappableLn1pXC(xre: phloat.Phloat, xim: phloat.Phloat, yre: *phloat.Phloat, yim: *phloat.Phloat) Err {
    if (phloat.isZero(xim)) {
        if (phloat.eq(xre, phloat.fromInt(-1))) return .invalid_data;
        if (phloat.gt(xre, phloat.fromInt(-1))) {
            yre.* = phloat.log1p(xre);
            yim.* = phloat.fromInt(0);
        } else {
            yre.* = phloat.log(phloat.neg(phloat.add(xre, phloat.fromInt(1))));
            yim.* = phloat.PI;
        }
        return .none;
    } else if (phloat.eq(xre, phloat.fromInt(-1))) {
        if (phloat.gt(xim, phloat.fromInt(0))) {
            yre.* = phloat.log(xim);
            yim.* = phloat.PI_2;
        } else {
            yre.* = phloat.log(phloat.neg(xim));
            yim.* = phloat.neg(phloat.PI_2);
        }
        return .none;
    } else {
        const x1re = phloat.add(xre, phloat.fromInt(1));
        var h = phloat.hypot(x1re, xim);
        var bre: phloat.Phloat = undefined;
        var s: phloat.Phloat = undefined;
        if (phloat.isInf(h)) {
            s = phloat.fromInt(10000);
            h = phloat.hypot(phloat.div(x1re, s), phloat.div(xim, s));
            bre = phloat.add(phloat.log(h), phloat.log(s));
        } else {
            s = phloat.fromInt(1);
            bre = phloat.log(h);
        }
        const bim = phloat.atan2(xim, x1re);
        const cre = phloat.sub(phloat.sub(x1re, phloat.fromInt(1)), xre);
        const dre = phloat.mul(phloat.div(phloat.mul(cre, x1re), phloat.mul(h, h)), s);
        const dim = phloat.neg(phloat.mul(phloat.div(phloat.mul(cre, xim), phloat.mul(h, h)), s));
        yre.* = phloat.sub(bre, dre);
        yim.* = phloat.sub(bim, dim);
        return .none;
    }
}

pub fn docmdLn1pX(arg: ?*const commands1.Arg) Err {
    _ = arg;
    var v: ?*Vartype = null;
    const e = helpers.mapUnary(x(), &v, mappableLn1pXR, mappableLn1pXC);
    if (e == .none) helpers.unaryResult(v.?);
    return e;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const commands1 = @import("commands1.zig");

fn expectClose(expected: []const u8, actual: phloat.Phloat) !void {
    const es = phloat.fromString(expected);
    const diff = phloat.abs(phloat.sub(es, actual));
    const tol = phloat.fromString("1E-28");
    try std.testing.expect(phloat.lt(diff, tol));
}

test "SIN/COS/TAN in RAD mode" {
    globals.init();
    defer globals.deinit();
    globals.flags.rad = true;
    try std.testing.expectEqual(Err.none, commands1.pushNumber("1.570796326794896619231321691639751"));
    try std.testing.expectEqual(Err.none, docmdSin(null));
    try expectClose("1", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("0"));
    try std.testing.expectEqual(Err.none, docmdCos(null));
    try expectClose("1", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("0.7853981633974483096156608458198757"));
    try std.testing.expectEqual(Err.none, docmdTan(null));
    try expectClose("1", x().real);
}

test "SIN in DEG mode" {
    globals.init();
    defer globals.deinit();
    try std.testing.expectEqual(Err.none, commands1.pushNumber("90"));
    try std.testing.expectEqual(Err.none, docmdSin(null));
    try expectClose("1", x().real);
}

test "LOG/LN/SQRT/SQUARE/INV" {
    globals.init();
    defer globals.deinit();
    try std.testing.expectEqual(Err.none, commands1.pushNumber("1000"));
    try std.testing.expectEqual(Err.none, docmdLog(null));
    try expectClose("3", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("2.718281828459045235360287471352662"));
    try std.testing.expectEqual(Err.none, docmdLn(null));
    try expectClose("1", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("9"));
    try std.testing.expectEqual(Err.none, docmdSqrt(null));
    try expectClose("3", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("3"));
    try std.testing.expectEqual(Err.none, docmdSquare(null));
    try expectClose("9", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("4"));
    try std.testing.expectEqual(Err.none, docmdInv(null));
    try expectClose("0.25", x().real);
}

test "Y^X integer power" {
    globals.init();
    defer globals.deinit();
    try std.testing.expectEqual(Err.none, commands1.pushNumber("2"));
    try std.testing.expectEqual(Err.none, commands1.docmdEnter(null));
    try std.testing.expectEqual(Err.none, commands1.pushNumber("10"));
    try std.testing.expectEqual(Err.none, docmdYPowX(null));
    try expectClose("1024", x().real);
}

test "FACT" {
    globals.init();
    defer globals.deinit();
    try std.testing.expectEqual(Err.none, commands1.pushNumber("5"));
    try std.testing.expectEqual(Err.none, docmdFact(null));
    try expectClose("120", x().real);
}

test "→REC and →POL" {
    globals.init();
    defer globals.deinit();
    // →REC: r=1, phi=90° → (0, 1)
    try std.testing.expectEqual(Err.none, commands1.pushNumber("90"));
    try std.testing.expectEqual(Err.none, commands1.docmdEnter(null));
    try std.testing.expectEqual(Err.none, commands1.pushNumber("1"));
    try std.testing.expectEqual(Err.none, docmdToRec(null));
    try expectClose("0", x().real);
    try expectClose("1", y().real);
    // →POL: (0, 1) → r=1, phi=90°
    try std.testing.expectEqual(Err.none, docmdToPol(null));
    try expectClose("1", x().real);
    try expectClose("90", y().real);
}

test "hyperbolic" {
    globals.init();
    defer globals.deinit();
    try std.testing.expectEqual(Err.none, commands1.pushNumber("0"));
    try std.testing.expectEqual(Err.none, docmdSinh(null));
    try expectClose("0", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("0"));
    try std.testing.expectEqual(Err.none, docmdCosh(null));
    try expectClose("1", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("0"));
    try std.testing.expectEqual(Err.none, docmdTanh(null));
    try expectClose("0", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("0"));
    try std.testing.expectEqual(Err.none, docmdAsinh(null));
    try expectClose("0", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("1"));
    try std.testing.expectEqual(Err.none, docmdAcosh(null));
    try expectClose("0", x().real);
    try std.testing.expectEqual(Err.none, commands1.pushNumber("0"));
    try std.testing.expectEqual(Err.none, docmdAtanh(null));
    try expectClose("0", x().real);
}
