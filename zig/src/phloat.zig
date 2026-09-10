//! phloat — the HP-42S floating-point type.
//!
//! Zig port of Free42's `common/core_phloat.cc` (BCD_MATH path). Backed by
//! decNumber's `decQuad` (34-digit IEEE 754 decimal128), matching Free42
//! Decimal's bid128 precision exactly.
//!
//! The transcendental functions (sin, cos, tan, exp, ln, gamma, …) are
//! deferred to step 3 — decNumber provides only the core arithmetic here, and
//! those stubs panic loudly rather than return a wrong answer.

const std = @import("std");

// Hand-written extern declarations for the decNumber decQuad subset we use.
// Replaces @cImport so the Zig frontend never parses the C headers (faster
// compile, and a step toward a full native port). Signatures mirror
// vendor/decNumber/decQuad.h + decContext.h exactly.
const c = struct {
    // --- types ---------------------------------------------------------------
    /// The decQuad decimal128 datum: a 16-byte union (DPD-encoded).
    /// DECUSE64 is not defined when decQuad.h is compiled (decNumberLocal.h
    /// is included after it), so the C union has no `longs` member — align 4.
    pub const decQuad = extern union {
        bytes: [16]u8,
        shorts: [8]u16,
        words: [4]u32,
    };

    /// The decimal context (DECSUBSET=0, so no `extended` field).
    pub const decContext = extern struct {
        digits: i32,
        emax: i32,
        emin: i32,
        round: c_int, // enum rounding (C `int`)
        traps: u32,
        status: u32,
        clamp: u8,
    };

    // --- rounding modes (enum rounding) --------------------------------------
    pub const DEC_ROUND_CEILING: c_int = 0;
    pub const DEC_ROUND_UP: c_int = 1;
    pub const DEC_ROUND_HALF_UP: c_int = 2;
    pub const DEC_ROUND_HALF_EVEN: c_int = 3;
    pub const DEC_ROUND_HALF_DOWN: c_int = 4;
    pub const DEC_ROUND_DOWN: c_int = 5;
    pub const DEC_ROUND_FLOOR: c_int = 6;
    pub const DEC_ROUND_05UP: c_int = 7;

    // --- init descriptor -----------------------------------------------------
    pub const DEC_INIT_DECQUAD: i32 = 128; // DEC_INIT_DECIMAL128

    // --- decContext routines -------------------------------------------------
    pub extern fn decContextDefault(*decContext, i32) *decContext;

    // --- decQuad conversions -------------------------------------------------
    pub extern fn decQuadFromString(*decQuad, [*c]const u8, *decContext) *decQuad;
    pub extern fn decQuadFromInt32(*decQuad, i32) *decQuad;
    pub extern fn decQuadFromUInt32(*decQuad, u32) *decQuad;
    pub extern fn decQuadToString(*const decQuad, [*c]u8) [*c]u8;
    pub extern fn decQuadToInt32(*const decQuad, *decContext, c_int) i32;

    // --- decQuad arithmetic --------------------------------------------------
    pub extern fn decQuadAdd(*decQuad, *const decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadSubtract(*decQuad, *const decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadMultiply(*decQuad, *const decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadDivide(*decQuad, *const decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadMinus(*decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadAbs(*decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadFMA(*decQuad, *const decQuad, *const decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadToIntegralValue(*decQuad, *const decQuad, *decContext, c_int) *decQuad;
    pub extern fn decQuadLogB(*decQuad, *const decQuad, *decContext) *decQuad;
    pub extern fn decQuadScaleB(*decQuad, *const decQuad, *const decQuad, *decContext) *decQuad;

    // --- decQuad comparisons -------------------------------------------------
    pub extern fn decQuadCompare(*decQuad, *const decQuad, *const decQuad, *decContext) *decQuad;

    // --- decQuad predicates --------------------------------------------------
    pub extern fn decQuadIsNaN(*const decQuad) u32;
    pub extern fn decQuadIsInfinite(*const decQuad) u32;
    pub extern fn decQuadIsZero(*const decQuad) u32;
    pub extern fn decQuadIsNegative(*const decQuad) u32;
    pub extern fn decQuadIsFinite(*const decQuad) u32;
    pub extern fn decQuadIsInteger(*const decQuad) u32;
};

/// The phloat type: a 34-digit decimal128 value (16 bytes).
pub const Phloat = c.decQuad;

/// Maximum mantissa digits (matches Free42's `MAX_MANT_DIGITS` in BCD mode).
pub const max_mant_digits = 34;

/// The decimal context (rounding mode, precision, status flags).
var ctx: c.decContext = undefined;

/// Thread-local scratch for `toString` — the returned slice is only valid
/// until the next `toString` call on this thread.
threadlocal var str_buf: [43]u8 = undefined;

/// Initialize the decimal context and the shared constants.
/// Must be called once before any arithmetic.
pub fn init() void {
    _ = c.decContextDefault(&ctx, c.DEC_INIT_DECQUAD);
    PI = fromString("3.141592653589793238462643383279503");
    PI_2 = div(PI, fromInt(2));
    PI_4 = div(PI, fromInt(4));
    TWO_PI = mul(PI, fromInt(2));
    LN2 = fromString("0.6931471805599453094172321214581766");
    LN10 = fromString("2.302585092994045684017991454684364");
    E = fromString("2.718281828459045235360287471352662");
    POS_HUGE = fromString("9.999999999999999999999999999999999E+6144");
    NEG_HUGE = fromString("-9.999999999999999999999999999999999E+6144");
    POS_TINY = fromString("1E-6143");
    NEG_TINY = fromString("-1E-6143");
    NAN = fromString("NaN");
    NAN_1 = fromString("NaN");
    NAN_2 = fromString("NaN");
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Parse a decimal string ("1.23", "-4.5E+10", "Infinity", "NaN", …).
pub fn fromString(s: []const u8) Phloat {
    var buf: [64]u8 = undefined;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    var p: Phloat = undefined;
    _ = c.decQuadFromString(&p, &buf, &ctx);
    return p;
}

pub fn fromInt(i: i32) Phloat {
    var p: Phloat = undefined;
    _ = c.decQuadFromInt32(&p, i);
    return p;
}

pub fn fromUint(u: u32) Phloat {
    var p: Phloat = undefined;
    _ = c.decQuadFromUInt32(&p, u);
    return p;
}

pub fn fromInt64(i: i64) Phloat {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    return fromString(s);
}

pub fn fromUint64(u: u64) Phloat {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{u}) catch unreachable;
    return fromString(s);
}

pub fn fromDouble(d: f64) Phloat {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{d}) catch unreachable;
    return fromString(s);
}

// ---------------------------------------------------------------------------
// Conversion
// ---------------------------------------------------------------------------

/// Format as a decimal string. The returned slice is valid until the next
/// `toString` call on this thread.
pub fn toString(p: Phloat) []const u8 {
    _ = c.decQuadToString(&p, &str_buf);
    return std.mem.sliceTo(&str_buf, 0);
}

/// Truncate toward zero and convert to i32 (undefined if out of range).
pub fn toInt(p: Phloat) i32 {
    return c.decQuadToInt32(&p, &ctx, c.DEC_ROUND_DOWN);
}

pub fn toInt64(p: Phloat) i64 {
    const s = toString(p);
    return std.fmt.parseInt(i64, s, 10) catch 0;
}

pub fn toDouble(p: Phloat) f64 {
    const s = toString(p);
    return std.fmt.parseFloat(f64, s) catch 0;
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

/// Three-way comparison: -1, 0, or 1 (NaN compares unordered → returns 0).
fn compare(a: Phloat, b: Phloat) i32 {
    var r: Phloat = undefined;
    _ = c.decQuadCompare(&r, &a, &b, &ctx);
    return c.decQuadToInt32(&r, &ctx, c.DEC_ROUND_DOWN);
}

pub fn eq(a: Phloat, b: Phloat) bool {
    return compare(a, b) == 0;
}
pub fn ne(a: Phloat, b: Phloat) bool {
    return compare(a, b) != 0;
}
pub fn lt(a: Phloat, b: Phloat) bool {
    return compare(a, b) < 0;
}
pub fn le(a: Phloat, b: Phloat) bool {
    return compare(a, b) <= 0;
}
pub fn gt(a: Phloat, b: Phloat) bool {
    return compare(a, b) > 0;
}
pub fn ge(a: Phloat, b: Phloat) bool {
    return compare(a, b) >= 0;
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

pub fn add(a: Phloat, b: Phloat) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadAdd(&r, &a, &b, &ctx);
    return r;
}
pub fn sub(a: Phloat, b: Phloat) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadSubtract(&r, &a, &b, &ctx);
    return r;
}
pub fn mul(a: Phloat, b: Phloat) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadMultiply(&r, &a, &b, &ctx);
    return r;
}
pub fn div(a: Phloat, b: Phloat) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadDivide(&r, &a, &b, &ctx);
    return r;
}
pub fn neg(a: Phloat) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadMinus(&r, &a, &ctx);
    return r;
}
pub fn abs(a: Phloat) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadAbs(&r, &a, &ctx);
    return r;
}
pub fn fma(x: Phloat, y: Phloat, z: Phloat) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadFMA(&r, &x, &y, &z, &ctx);
    return r;
}

/// Floating-point remainder: `x - trunc(x/y) * y`, with the sign of `x`.
/// (decNumber has no fmod, so this is built from the primitives.)
pub fn fmod(x: Phloat, y: Phloat) Phloat {
    if (isZero(y)) return NAN;
    const q = trunc(div(x, y));
    return sub(x, mul(q, y));
}

/// 10^n for integer n (used by RND and the display formatter).
pub fn pow10(n: i32) Phloat {
    if (n == 0) return fromInt(1);
    var r = fromInt(1);
    const base = fromInt(10);
    var e = if (n < 0) -n else n;
    while (e > 0) : (e -= 1) {
        r = if (n < 0) div(r, base) else mul(r, base);
    }
    return r;
}

fn toIntegral(p: Phloat, rounding: c_int) Phloat {
    var r: Phloat = undefined;
    _ = c.decQuadToIntegralValue(&r, &p, &ctx, rounding);
    return r;
}

pub fn floor(p: Phloat) Phloat {
    return toIntegral(p, c.DEC_ROUND_FLOOR);
}
pub fn ceil(p: Phloat) Phloat {
    return toIntegral(p, c.DEC_ROUND_CEILING);
}
pub fn trunc(p: Phloat) Phloat {
    return toIntegral(p, c.DEC_ROUND_DOWN);
}
pub fn round(p: Phloat) Phloat {
    return toIntegral(p, c.DEC_ROUND_HALF_EVEN);
}

// ---------------------------------------------------------------------------
// Predicates
// ---------------------------------------------------------------------------

pub fn isNaN(p: Phloat) bool {
    return c.decQuadIsNaN(&p) != 0;
}
pub fn isInf(p: Phloat) bool {
    return c.decQuadIsInfinite(&p) != 0;
}
pub fn isZero(p: Phloat) bool {
    return c.decQuadIsZero(&p) != 0;
}
pub fn isNegative(p: Phloat) bool {
    return c.decQuadIsNegative(&p) != 0;
}
pub fn isFinite(p: Phloat) bool {
    return c.decQuadIsFinite(&p) != 0;
}
pub fn isInteger(p: Phloat) bool {
    return c.decQuadIsInteger(&p) != 0;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub var PI: Phloat = undefined;
pub var PI_2: Phloat = undefined;
pub var PI_4: Phloat = undefined;
pub var TWO_PI: Phloat = undefined;
pub var LN2: Phloat = undefined;
pub var LN10: Phloat = undefined;
pub var E: Phloat = undefined;
pub var POS_HUGE: Phloat = undefined;
pub var NEG_HUGE: Phloat = undefined;
pub var POS_TINY: Phloat = undefined;
pub var NEG_TINY: Phloat = undefined;
pub var NAN: Phloat = undefined;
pub var NAN_1: Phloat = undefined;
pub var NAN_2: Phloat = undefined;

// ---------------------------------------------------------------------------
// Transcendentals — built on decNumber's core arithmetic.
//
// decNumber provides only add/sub/mul/div, so these are implemented from
// argument reduction + Taylor series, computed to the full 34-digit decQuad
// precision. Each series runs until the running sum stops changing (i.e. the
// next term is below the last representable digit), with a safety cap.
// ---------------------------------------------------------------------------

const MAX_ITER: usize = 200;

/// Round to the nearest integer and convert to i32.
fn roundToInt(p: Phloat) i32 {
    return toInt(round(p));
}

// --- series kernels ---------------------------------------------------------

fn expSeries(r: Phloat) Phloat {
    // exp(r) = 1 + r + r^2/2! + r^3/3! + ...  (|r| <= ln(2)/2)
    var sum = fromInt(1);
    var term = fromInt(1);
    var n: i32 = 1;
    while (n <= MAX_ITER) : (n += 1) {
        term = div(mul(term, r), fromInt(n));
        const next = add(sum, term);
        if (eq(next, sum)) break;
        sum = next;
    }
    return sum;
}

fn logSeries(z: Phloat) Phloat {
    // log((1+z)/(1-z)) = 2*(z + z^3/3 + z^5/5 + ...)  (|z| < 1)
    const z2 = mul(z, z);
    var term = z;
    var sum = z;
    var n: i32 = 1;
    while (n <= MAX_ITER) : (n += 1) {
        term = mul(term, z2);
        const next = div(term, fromInt(2 * n + 1));
        const s2 = add(sum, next);
        if (eq(s2, sum)) break;
        sum = s2;
    }
    return mul(sum, fromInt(2));
}

fn sinSeries(r: Phloat) Phloat {
    // sin(r) = r - r^3/3! + r^5/5! - ...  (|r| <= pi/4)
    const r2 = mul(r, r);
    var term = r;
    var sum = r;
    var n: i32 = 1;
    while (n <= MAX_ITER) : (n += 1) {
        term = neg(div(mul(term, r2), fromInt((2 * n) * (2 * n + 1))));
        const next = add(sum, term);
        if (eq(next, sum)) break;
        sum = next;
    }
    return sum;
}

fn cosSeries(r: Phloat) Phloat {
    // cos(r) = 1 - r^2/2! + r^4/4! - ...  (|r| <= pi/4)
    const r2 = mul(r, r);
    var term = fromInt(1);
    var sum = fromInt(1);
    var n: i32 = 1;
    while (n <= MAX_ITER) : (n += 1) {
        term = neg(div(mul(term, r2), fromInt((2 * n - 1) * (2 * n))));
        const next = add(sum, term);
        if (eq(next, sum)) break;
        sum = next;
    }
    return sum;
}

fn atanSeries(x: Phloat) Phloat {
    // atan(x) = x - x^3/3 + x^5/5 - ...  (|x| <= 1)
    const x2 = mul(x, x);
    var term = x;
    var sum = x;
    var n: i32 = 1;
    while (n <= MAX_ITER) : (n += 1) {
        term = neg(mul(term, x2));
        const next = div(term, fromInt(2 * n + 1));
        const s2 = add(sum, next);
        if (eq(s2, sum)) break;
        sum = s2;
    }
    return sum;
}

// --- public functions -------------------------------------------------------

pub fn sqrt(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isZero(p)) return p;
    if (isNegative(p)) return NAN;
    if (isInf(p)) return POS_HUGE;
    // Newton's method, seeded from a double-precision estimate.
    var x = fromDouble(std.math.sqrt(toDouble(p)));
    var n: usize = 0;
    while (n < MAX_ITER) : (n += 1) {
        const nx = div(add(x, div(p, x)), fromInt(2));
        if (eq(nx, x)) break;
        x = nx;
    }
    return x;
}

pub fn exp(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isInf(p)) return if (isNegative(p)) fromInt(0) else POS_HUGE;
    // Reduce: p = n*ln(10) + r, r in [-ln(10)/2, ln(10)/2]; exp(p) = 10^n * exp(r).
    const n = roundToInt(div(p, LN10));
    const r = sub(p, mul(fromInt(n), LN10));
    return scaleb(expSeries(r), n);
}

pub fn log(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isZero(p)) return NEG_HUGE;
    if (isNegative(p)) return NAN;
    if (isInf(p)) return POS_HUGE;
    // Reduce: p = m * 10^e, m in [1, 10); then halve m to [1, 2) so the
    // atanh series converges quickly. log(p) = log(m) + k*ln(2) + e*ln(10).
    const e = logb(p);
    var m = scaleb(p, -e);
    var k: i32 = 0;
    while (ge(m, fromInt(2))) {
        m = div(m, fromInt(2));
        k += 1;
    }
    const z = div(sub(m, fromInt(1)), add(m, fromInt(1)));
    return add(add(logSeries(z), mul(fromInt(k), LN2)), mul(fromInt(e), LN10));
}

pub fn log10(p: Phloat) Phloat {
    return div(log(p), LN10);
}

pub fn log1p(p: Phloat) Phloat {
    if (isZero(p)) return fromInt(0);
    if (lt(abs(p), fromString("0.01"))) {
        // log(1+p) = p - p^2/2 + p^3/3 - ...  (accurate for small p)
        var term = p;
        var sum = p;
        var n: i32 = 2;
        while (n <= MAX_ITER) : (n += 1) {
            term = neg(mul(term, p));
            const next = div(term, fromInt(n));
            const s2 = add(sum, next);
            if (eq(s2, sum)) break;
            sum = s2;
        }
        return sum;
    }
    return log(add(fromInt(1), p));
}

pub fn expm1(p: Phloat) Phloat {
    if (isZero(p)) return fromInt(0);
    if (lt(abs(p), fromString("0.01"))) {
        // exp(p)-1 = p + p^2/2! + p^3/3! + ...  (accurate for small p)
        var term = p;
        var sum = p;
        var n: i32 = 2;
        while (n <= MAX_ITER) : (n += 1) {
            term = div(mul(term, p), fromInt(n));
            const next = add(sum, term);
            if (eq(next, sum)) break;
            sum = next;
        }
        return sum;
    }
    return sub(exp(p), fromInt(1));
}

pub fn sin(p: Phloat) Phloat {
    var s: Phloat = undefined;
    var c_: Phloat = undefined;
    sincos(p, &s, &c_);
    return s;
}

pub fn cos(p: Phloat) Phloat {
    var s: Phloat = undefined;
    var c_: Phloat = undefined;
    sincos(p, &s, &c_);
    return c_;
}

pub fn tan(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    var s: Phloat = undefined;
    var c_: Phloat = undefined;
    sincos(p, &s, &c_);
    if (isZero(c_)) return if (isNegative(s)) NEG_HUGE else POS_HUGE;
    return div(s, c_);
}

pub fn sincos(phi: Phloat, s: *Phloat, c_: *Phloat) void {
    if (isNaN(phi) or isInf(phi)) {
        s.* = NAN;
        c_.* = NAN;
        return;
    }
    // Reduce: phi = q*(pi/2) + r, r in [-pi/4, pi/4]; use the quadrant q mod 4.
    const q = round(div(phi, PI_2));
    const r = sub(phi, mul(q, PI_2));
    const qi = @mod(toInt(q), 4);
    const sr = sinSeries(r);
    const cr = cosSeries(r);
    switch (qi) {
        0 => {
            s.* = sr;
            c_.* = cr;
        },
        1 => {
            s.* = cr;
            c_.* = neg(sr);
        },
        2 => {
            s.* = neg(sr);
            c_.* = neg(cr);
        },
        3 => {
            s.* = neg(cr);
            c_.* = sr;
        },
        else => unreachable,
    }
}

pub fn asin(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (gt(abs(p), fromInt(1))) return NAN;
    if (eq(abs(p), fromInt(1))) return if (isNegative(p)) neg(PI_2) else PI_2;
    // asin(x) = atan(x / sqrt(1 - x^2))
    return atan(div(p, sqrt(sub(fromInt(1), mul(p, p)))));
}

pub fn acos(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (gt(abs(p), fromInt(1))) return NAN;
    if (eq(p, fromInt(1))) return fromInt(0);
    if (eq(p, fromInt(-1))) return PI;
    // acos(x) = pi/2 - asin(x)
    return sub(PI_2, asin(p));
}

pub fn atan(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isZero(p)) return fromInt(0);
    if (isInf(p)) return if (isNegative(p)) neg(PI_2) else PI_2;
    if (isNegative(p)) return neg(atan(neg(p)));
    // Halve the angle until the argument is small enough for the series.
    var x = p;
    var k: i32 = 0;
    while (gt(x, fromString("0.1"))) {
        x = div(x, add(fromInt(1), sqrt(add(fromInt(1), mul(x, x)))));
        k += 1;
    }
    var r = atanSeries(x);
    while (k > 0) : (k -= 1) r = mul(r, fromInt(2));
    return r;
}

pub fn atan2(x: Phloat, y: Phloat) Phloat {
    // atan2(x, y) = angle whose tangent is x/y (x = sine component, y = cosine).
    if (isZero(y)) {
        if (isZero(x)) return fromInt(0);
        return if (isNegative(x)) neg(PI_2) else PI_2;
    }
    const a = atan(div(x, y));
    if (isNegative(y)) return if (isNegative(x)) sub(a, PI) else add(a, PI);
    return a;
}

pub fn hypot(x: Phloat, y: Phloat) Phloat {
    const ax = abs(x);
    const ay = abs(y);
    if (isZero(ax)) return ay;
    if (isZero(ay)) return ax;
    if (gt(ax, ay)) {
        const r = div(ay, ax);
        return mul(ax, sqrt(add(fromInt(1), mul(r, r))));
    }
    const r = div(ax, ay);
    return mul(ay, sqrt(add(fromInt(1), mul(r, r))));
}

pub fn sinh(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isInf(p)) return p;
    const ep = exp(p);
    return div(sub(ep, div(fromInt(1), ep)), fromInt(2));
}

pub fn cosh(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isInf(p)) return POS_HUGE;
    const ep = exp(p);
    return div(add(ep, div(fromInt(1), ep)), fromInt(2));
}

pub fn tanh(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isInf(p)) return if (isNegative(p)) fromInt(-1) else fromInt(1);
    const ep = exp(p);
    const em = div(fromInt(1), ep);
    return div(sub(ep, em), add(ep, em));
}

pub fn asinh(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (isInf(p)) return p;
    return log(add(p, sqrt(add(mul(p, p), fromInt(1)))));
}

pub fn acosh(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (lt(p, fromInt(1))) return NAN;
    return log(add(p, sqrt(sub(mul(p, p), fromInt(1)))));
}

pub fn atanh(p: Phloat) Phloat {
    if (isNaN(p)) return NAN;
    if (eq(abs(p), fromInt(1))) return if (isNegative(p)) NEG_HUGE else POS_HUGE;
    if (gt(abs(p), fromInt(1))) return NAN;
    return div(log(div(add(fromInt(1), p), sub(fromInt(1), p))), fromInt(2));
}

pub fn pow(x: Phloat, y: Phloat) Phloat {
    if (isNaN(x) or isNaN(y)) return NAN;
    if (isZero(x)) {
        if (isZero(y)) return fromInt(1);
        if (isNegative(y)) return POS_HUGE;
        return fromInt(0);
    }
    if (isNegative(x)) {
        if (!isInteger(y)) return NAN;
        const r = exp(mul(y, log(neg(x))));
        return if (@mod(toInt(y), 2) == 0) r else neg(r);
    }
    return exp(mul(y, log(x)));
}

pub fn tgamma(p: Phloat) Phloat {
    // Lanczos approximation (g=7, n=9), with reflection for x < 0.5. The
    // coefficients are double-precision, so this is ~15 digits — enough for
    // the 12-digit display, but not full decQuad precision.
    if (isNaN(p)) return NAN;
    if (isInf(p)) return if (isNegative(p)) NAN else POS_HUGE;
    if (isInteger(p) and le(p, fromInt(0))) return NAN;
    if (lt(p, fromString("0.5"))) {
        const g = tgamma(sub(fromInt(1), p));
        return div(PI, mul(sin(mul(PI, p)), g));
    }
    const g = fromString("7");
    const coeff = [_]Phloat{
        fromString("0.99999999999980993"),
        fromString("676.5203681218851"),
        fromString("-1259.1392167224028"),
        fromString("771.32342877765313"),
        fromString("-176.61502916214059"),
        fromString("12.507343278686905"),
        fromString("-0.13857109526572012"),
        fromString("9.9843695780195716E-6"),
        fromString("1.5056327351493116E-7"),
    };
    var a = coeff[0];
    var k: i32 = 1;
    while (k <= 8) : (k += 1) {
        a = add(a, div(coeff[@intCast(k)], add(p, fromInt(k - 1))));
    }
    const t = add(p, sub(g, fromString("0.5")));
    const sqrt2pi = sqrt(mul(fromInt(2), PI));
    const term1 = pow(t, sub(p, fromString("0.5")));
    const term2 = exp(neg(t));
    return mul(mul(mul(sqrt2pi, term1), term2), a);
}

/// Base-10 exponent: returns e such that x = m * 10^e with m in [1, 10).
/// (decNumber's LogB is base-10, unlike C's base-2 `ilogb`.)
pub fn logb(x: Phloat) i32 {
    var r: Phloat = undefined;
    _ = c.decQuadLogB(&r, &x, &ctx);
    return toInt(r);
}

/// Scale by a power of ten: returns x * 10^y. (decNumber's ScaleB is base-10,
/// unlike C's base-2 `scalbn`.)
pub fn scaleb(x: Phloat, y: i32) Phloat {
    var r: Phloat = undefined;
    const n = fromInt(y);
    _ = c.decQuadScaleB(&r, &x, &n, &ctx);
    return r;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "1 + 2 = 3" {
    init();
    const r = add(fromString("1"), fromString("2"));
    try std.testing.expectEqualStrings("3", toString(r));
}

test "0.1 + 0.2 = 0.3 (exact decimal)" {
    init();
    const r = add(fromString("0.1"), fromString("0.2"));
    try std.testing.expectEqualStrings("0.3", toString(r));
}

test "1 / 3 = 34-digit repeating" {
    init();
    const r = div(fromString("1"), fromString("3"));
    try std.testing.expectEqualStrings("0.3333333333333333333333333333333333", toString(r));
}

test "comparison and predicates" {
    init();
    try std.testing.expect(lt(fromString("1"), fromString("2")));
    try std.testing.expect(ge(fromString("2"), fromString("2")));
    try std.testing.expect(isZero(fromString("0")));
    try std.testing.expect(isNegative(fromString("-1")));
    try std.testing.expect(isFinite(fromString("1")));
    try std.testing.expect(isNaN(fromString("NaN")));
}

test "string round-trip" {
    init();
    const s = "12345.6789";
    try std.testing.expectEqualStrings(s, toString(fromString(s)));
}

/// Assert that `actual` matches `expected` to within 1e-28 (transcendentals are
/// irrational, so exact string equality is not expected).
fn expectClose(expected: []const u8, actual: Phloat) !void {
    const es = fromString(expected);
    const diff = abs(sub(es, actual));
    const tol = fromString("1E-28");
    try std.testing.expect(lt(diff, tol));
}

test "sqrt" {
    init();
    try expectClose("1.414213562373095048801688724209698", sqrt(fromInt(2)));
    try expectClose("3", sqrt(fromInt(9)));
    try expectClose("0", sqrt(fromInt(0)));
}

test "exp and log" {
    init();
    try expectClose("2.718281828459045235360287471352662", exp(fromInt(1)));
    try expectClose("1", log(E));
    try expectClose("3", log10(fromInt(1000)));
    try expectClose("0.6931471805599453094172321214581766", log(fromInt(2)));
}

test "sin cos tan" {
    init();
    try expectClose("1", sin(PI_2));
    try expectClose("0", sin(fromInt(0)));
    try expectClose("1", cos(fromInt(0)));
    try expectClose("1", tan(PI_4));
    try expectClose("0", sin(PI));
}

test "inverse trig" {
    init();
    try expectClose("0.7853981633974483096156608458198757", atan(fromInt(1)));
    try expectClose("1.570796326794896619231321691639751", asin(fromInt(1)));
    try expectClose("1.570796326794896619231321691639751", acos(fromInt(0)));
}

test "hyperbolic" {
    init();
    try expectClose("0", sinh(fromInt(0)));
    try expectClose("1", cosh(fromInt(0)));
    try expectClose("0", tanh(fromInt(0)));
    try expectClose("0", asinh(fromInt(0)));
    try expectClose("0", acosh(fromInt(1)));
    try expectClose("0", atanh(fromInt(0)));
}

test "pow" {
    init();
    try expectClose("1024", pow(fromInt(2), fromInt(10)));
    try expectClose("2", pow(fromInt(4), fromString("0.5")));
}
