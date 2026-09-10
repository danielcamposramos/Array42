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

const c = @cImport({
    @cInclude("decQuad.h");
    @cInclude("decContext.h");
});

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

fn toIntegral(p: Phloat, rounding: c_uint) Phloat {
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
pub var POS_HUGE: Phloat = undefined;
pub var NEG_HUGE: Phloat = undefined;
pub var POS_TINY: Phloat = undefined;
pub var NEG_TINY: Phloat = undefined;
pub var NAN: Phloat = undefined;
pub var NAN_1: Phloat = undefined;
pub var NAN_2: Phloat = undefined;

// ---------------------------------------------------------------------------
// Transcendentals — deferred to step 3 (decNumber lacks trig/gamma).
// ---------------------------------------------------------------------------

fn notYet(comptime name: []const u8) noreturn {
    @panic(std.fmt.comptimePrint("phloat.{s}: not yet implemented (step 3)", .{name}));
}

pub fn sin(p: Phloat) Phloat {
    _ = p;
    notYet("sin");
}
pub fn cos(p: Phloat) Phloat {
    _ = p;
    notYet("cos");
}
pub fn tan(p: Phloat) Phloat {
    _ = p;
    notYet("tan");
}
pub fn asin(p: Phloat) Phloat {
    _ = p;
    notYet("asin");
}
pub fn acos(p: Phloat) Phloat {
    _ = p;
    notYet("acos");
}
pub fn atan(p: Phloat) Phloat {
    _ = p;
    notYet("atan");
}
pub fn sincos(phi: Phloat, s: *Phloat, c_: *Phloat) void {
    _ = phi;
    _ = s;
    _ = c_;
    notYet("sincos");
}
pub fn hypot(x: Phloat, y: Phloat) Phloat {
    _ = x;
    _ = y;
    notYet("hypot");
}
pub fn atan2(x: Phloat, y: Phloat) Phloat {
    _ = x;
    _ = y;
    notYet("atan2");
}
pub fn sinh(p: Phloat) Phloat {
    _ = p;
    notYet("sinh");
}
pub fn cosh(p: Phloat) Phloat {
    _ = p;
    notYet("cosh");
}
pub fn tanh(p: Phloat) Phloat {
    _ = p;
    notYet("tanh");
}
pub fn asinh(p: Phloat) Phloat {
    _ = p;
    notYet("asinh");
}
pub fn acosh(p: Phloat) Phloat {
    _ = p;
    notYet("acosh");
}
pub fn atanh(p: Phloat) Phloat {
    _ = p;
    notYet("atanh");
}
pub fn log(p: Phloat) Phloat {
    _ = p;
    notYet("log");
}
pub fn log1p(p: Phloat) Phloat {
    _ = p;
    notYet("log1p");
}
pub fn log10(p: Phloat) Phloat {
    _ = p;
    notYet("log10");
}
pub fn exp(p: Phloat) Phloat {
    _ = p;
    notYet("exp");
}
pub fn expm1(p: Phloat) Phloat {
    _ = p;
    notYet("expm1");
}
pub fn tgamma(p: Phloat) Phloat {
    _ = p;
    notYet("tgamma");
}
pub fn sqrt(p: Phloat) Phloat {
    _ = p;
    notYet("sqrt");
}
pub fn pow(x: Phloat, y: Phloat) Phloat {
    _ = x;
    _ = y;
    notYet("pow");
}
pub fn ilogb(x: Phloat) i32 {
    _ = x;
    notYet("ilogb");
}
pub fn scalbn(x: Phloat, y: i32) Phloat {
    _ = x;
    _ = y;
    notYet("scalbn");
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
