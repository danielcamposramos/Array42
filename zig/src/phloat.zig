//! phloat — the HP-42S floating-point type.
//!
//! Native Zig port of Free42's `common/core_phloat.cc` (BCD_MATH path).
//! A 34-digit IEEE 754 decimal128 (decQuad) implemented directly in Zig —
//! no C decNumber dependency. Matches Free42 Decimal's bid128 precision
//! exactly.
//!
//! The transcendental functions (sin, cos, tan, exp, ln, gamma, …) are
//! built on the core arithmetic (add/sub/mul/div) via argument reduction +
//! Taylor series, computed to the full 34-digit precision.

const std = @import("std");

// ---------------------------------------------------------------------------
// Format constants (decQuad = 34-digit decimal128)
// ---------------------------------------------------------------------------

const DECPMAX: i32 = 34; // max coefficient digits
const DECEMAX: i32 = 6144; // max exponent
const DECEMIN: i32 = -6143; // min normal exponent
const DECQTINY: i32 = -6176; // min subnormal exponent (DECEMIN-(DECPMAX-1))

/// Sticky-bit mapping for round-for-reround (d=0→1, d=5→6, else unchanged).
const DECSTICKYTAB = [10]u8{ 1, 1, 2, 3, 4, 6, 6, 7, 8, 9 };

/// Rounding modes (mirrors decNumber's `enum rounding`).
const Rounding = enum {
    ceiling, // 0
    up, // 1
    half_up, // 2
    half_even, // 3
    half_down, // 4
    down, // 5
    floor, // 6
    zero_five_up, // 7 (05UP)
};

const Class = enum { finite, inf, nan };

/// The phloat type: a 34-digit decimal128 value.
pub const Phloat = struct {
    sign: bool = false, // true = negative
    exponent: i32 = 0, // quantum exponent (base-10)
    coeff: u128 = 0, // coefficient, no leading zeros (0 for zero/special)
    class: Class = .finite,
};

/// Maximum mantissa digits (matches Free42's `MAX_MANT_DIGITS` in BCD mode).
pub const max_mant_digits = 34;

/// Thread-local scratch for `toString` — the returned slice is only valid
/// until the next `toString` call on this thread.
threadlocal var str_buf: [43]u8 = undefined;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Powers of ten, 10^0 .. 10^76 (u256 holds up to ~1.16e77, so 10^76 is safe).
const POW10: [77]u256 = blk: {
    var t: [77]u256 = undefined;
    var v: u256 = 1;
    for (0..77) |i| {
        t[i] = v;
        v *= 10;
    }
    break :blk t;
};

fn digitCount(c: u256) i32 {
    var n: i32 = 0;
    var x = c;
    while (x != 0) : (x /= 10) n += 1;
    return n;
}

fn nan() Phloat {
    return .{ .class = .nan };
}

fn inf(sign: bool) Phloat {
    return .{ .sign = sign, .class = .inf };
}

/// Decide whether to bump the kept coefficient, given the reround digit.
fn decideBump(sign: bool, reround: u8, kept: u256, rmode: Rounding) bool {
    return switch (rmode) {
        .half_even => reround > 5 or (reround == 5 and (kept & 1) != 0),
        .down => false,
        .half_down => reround > 5,
        .half_up => reround >= 5,
        .up => reround > 0,
        .ceiling => !sign and reround > 0,
        .floor => sign and reround > 0,
        .zero_five_up => reround > 0 and (kept % 10 == 0 or kept % 10 == 5),
    };
}

const Rounded = struct { coeff: u256, exponent: i32 };

/// Drop `drop` digits from `coeff`, rounding per `rmode`. `sticky` marks
/// discarded digits beyond the coefficient (division remainder).
fn roundDigits(sign: bool, coeff: u256, exponent: i32, drop: i32, sticky: bool, rmode: Rounding) Rounded {
    if (drop <= 0) return .{ .coeff = coeff, .exponent = exponent };
    const length = digitCount(coeff);
    var kept: u256 = 0;
    var reround: u8 = 0;
    var st = sticky;
    if (drop < length) {
        const p = POW10[@intCast(drop)];
        kept = coeff / p;
        const dropped = coeff % p;
        const p1 = POW10[@intCast(drop - 1)];
        reround = @intCast(dropped / p1);
        st = st or (dropped % p1) != 0;
    } else if (drop == length) {
        kept = 0;
        const p1 = POW10[@intCast(length - 1)];
        reround = @intCast(coeff / p1);
        st = st or (coeff % p1) != 0;
    } else {
        kept = 0;
        reround = 0;
        st = st or coeff != 0;
    }
    if (st) reround = DECSTICKYTAB[reround];
    if (decideBump(sign, reround, kept, rmode)) kept += 1;
    return .{ .coeff = kept, .exponent = exponent + drop };
}

/// Round a full-precision result to 34 digits, handling overflow/underflow.
fn finalize(sign: bool, coeff: u256, exponent: i32, sticky: bool, rmode: Rounding) Phloat {
    const length = digitCount(coeff);
    var drop = length - DECPMAX;
    const td = DECQTINY - exponent;
    if (td > drop) drop = td;
    var c = coeff;
    var e = exponent;
    if (drop > 0) {
        const r = roundDigits(sign, c, e, drop, sticky, rmode);
        c = r.coeff;
        e = r.exponent;
    }
    // all-nines carry: 34 nines + 1 → 10^33 with exponent+1
    if (c >= POW10[34]) {
        c /= 10;
        e += 1;
    }
    // overflow / fold-down
    if (e > DECEMAX - (DECPMAX - 1)) {
        if (c == 0) {
            e = DECEMAX - (DECPMAX - 1);
        } else {
            const l2 = digitCount(c);
            if (e + l2 - 1 > DECEMAX) {
                const needmax = switch (rmode) {
                    .down, .zero_five_up => true,
                    .ceiling => sign,
                    .floor => !sign,
                    else => false,
                };
                if (needmax) {
                    return .{ .sign = sign, .exponent = DECEMAX - (DECPMAX - 1), .coeff = POW10[34] - 1, .class = .finite };
                }
                return inf(sign);
            }
            const shift = e - (DECEMAX - (DECPMAX - 1));
            c *= POW10[@intCast(shift)];
            e -= shift;
        }
    }
    return .{ .sign = sign, .exponent = e, .coeff = @intCast(c), .class = .finite };
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Parse a decimal string ("1.23", "-4.5E+10", "Infinity", "NaN", …).
pub fn fromString(s: []const u8) Phloat {
    var i: usize = 0;
    var sign = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        sign = s[i] == '-';
        i += 1;
    }
    // specials
    if (i < s.len and (s[i] == 'i' or s[i] == 'I')) {
        // "inf" or "infinity"
        const rest = s[i..];
        if (std.ascii.eqlIgnoreCase(rest, "inf") or std.ascii.eqlIgnoreCase(rest, "infinity")) {
            return inf(sign);
        }
    }
    if (i < s.len and (s[i] == 'n' or s[i] == 'N')) {
        const rest = s[i..];
        if (std.ascii.eqlIgnoreCase(rest, "nan") or std.ascii.eqlIgnoreCase(rest, "snan")) {
            return nan();
        }
    }
    // finite: parse digits, dot, exponent
    var coeff: u256 = 0;
    var sig_total: i32 = 0; // significant digits (after leading zeros)
    var frac_digits: i32 = 0; // digits after the decimal point
    var seen_dot = false;
    var seen_digit = false;
    var leading = true;
    var kept: i32 = 0; // digits kept in coeff (<= 35)
    var sticky = false;
    while (i < s.len) {
        const ch = s[i];
        if (ch >= '0' and ch <= '9') {
            seen_digit = true;
            const d: u8 = ch - '0';
            if (leading and d == 0) {
                if (seen_dot) frac_digits += 1;
                i += 1;
                continue;
            }
            leading = false;
            if (kept < 35) {
                coeff = coeff * 10 + d;
                kept += 1;
            } else if (d != 0) {
                sticky = true;
            }
            sig_total += 1;
            if (seen_dot) frac_digits += 1;
            i += 1;
            continue;
        }
        if (ch == '.' and !seen_dot) {
            seen_dot = true;
            i += 1;
            continue;
        }
        break;
    }
    if (!seen_digit) return nan(); // bad syntax
    var expo: i32 = 0;
    if (i < s.len and (s[i] == 'E' or s[i] == 'e')) {
        i += 1;
        var esign = false;
        if (i < s.len and (s[i] == '-' or s[i] == '+')) {
            esign = s[i] == '-';
            i += 1;
        }
        var edigits: i32 = 0;
        var eval: i64 = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') {
            eval = eval * 10 + (s[i] - '0');
            edigits += 1;
            i += 1;
        }
        if (edigits > 4) {
            expo = if (esign) -12288 else 12288;
        } else {
            expo = @intCast(if (esign) -eval else eval);
        }
    }
    const exponent = expo - frac_digits + (sig_total - kept);
    return finalize(sign, coeff, exponent, sticky, .half_even);
}

pub fn fromInt(i: i32) Phloat {
    if (i == 0) return .{ .coeff = 0, .exponent = 0, .class = .finite };
    const is_neg = i < 0;
    const u: u32 = if (is_neg) @intCast(-@as(i64, i)) else @intCast(i);
    return .{ .sign = is_neg, .exponent = 0, .coeff = u, .class = .finite };
}

pub fn fromUint(u: u32) Phloat {
    return .{ .exponent = 0, .coeff = u, .class = .finite };
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

fn writeUint(buf: []u8, start: usize, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        while (x != 0) : (x /= 10) {
            tmp[n] = @intCast('0' + (x % 10));
            n += 1;
        }
    }
    var j = start;
    var k = n;
    while (k > 0) {
        k -= 1;
        buf[j] = tmp[k];
        j += 1;
    }
    return n;
}

/// Format as a decimal string. The returned slice is valid until the next
/// `toString` call on this thread.
pub fn toString(p: Phloat) []const u8 {
    var i: usize = 0;
    if (p.sign) {
        str_buf[i] = '-';
        i += 1;
    }
    switch (p.class) {
        .nan => {
            @memcpy(str_buf[i..][0..3], "NaN");
            i += 3;
        },
        .inf => {
            @memcpy(str_buf[i..][0..8], "Infinity");
            i += 8;
        },
        .finite => {
            var digits: [34]u8 = undefined;
            var nd: usize = 0;
            var c = p.coeff;
            if (c == 0) {
                digits[0] = '0';
                nd = 1;
            } else {
                var tmp: [34]u8 = undefined;
                var n: usize = 0;
                while (c != 0) : (c /= 10) {
                    tmp[n] = @intCast('0' + (c % 10));
                    n += 1;
                }
                for (0..n) |k| digits[k] = tmp[n - 1 - k];
                nd = n;
            }
            const expo = p.exponent;
            const pre: i32 = @as(i32, @intCast(nd)) + expo;
            if (expo > 0 or pre < -5) {
                const e = pre - 1;
                str_buf[i] = digits[0];
                i += 1;
                if (nd > 1) {
                    str_buf[i] = '.';
                    i += 1;
                    for (digits[1..nd]) |d| {
                        str_buf[i] = d;
                        i += 1;
                    }
                }
                str_buf[i] = 'E';
                i += 1;
                if (e < 0) {
                    str_buf[i] = '-';
                    i += 1;
                } else {
                    str_buf[i] = '+';
                    i += 1;
                }
                i += writeUint(&str_buf, i, @intCast(@abs(e)));
            } else if (pre > 0) {
                const pu: usize = @intCast(pre);
                if (pu >= nd) {
                    for (digits[0..nd]) |d| {
                        str_buf[i] = d;
                        i += 1;
                    }
                    for (0..(pu - nd)) |_| {
                        str_buf[i] = '0';
                        i += 1;
                    }
                } else {
                    for (digits[0..pu]) |d| {
                        str_buf[i] = d;
                        i += 1;
                    }
                    str_buf[i] = '.';
                    i += 1;
                    for (digits[pu..nd]) |d| {
                        str_buf[i] = d;
                        i += 1;
                    }
                }
            } else {
                str_buf[i] = '0';
                i += 1;
                str_buf[i] = '.';
                i += 1;
                const zeros: usize = @intCast(-pre);
                for (0..zeros) |_| {
                    str_buf[i] = '0';
                    i += 1;
                }
                for (digits[0..nd]) |d| {
                    str_buf[i] = d;
                    i += 1;
                }
            }
        },
    }
    str_buf[i] = 0;
    return std.mem.sliceTo(&str_buf, 0);
}

/// Truncate toward zero and convert to i32 (0 if out of range or special).
pub fn toInt(p: Phloat) i32 {
    if (p.class != .finite) return 0;
    var coeff = p.coeff;
    var expo = p.exponent;
    if (expo < 0) {
        const drop = -expo;
        if (drop >= 34) return 0;
        coeff = @intCast(@as(u256, coeff) / POW10[@intCast(drop)]);
        expo = 0;
    }
    if (coeff == 0) return 0;
    if (expo >= 10) return 0;
    const v: u256 = if (expo == 0) coeff else @as(u256, coeff) * POW10[@intCast(expo)];
    if (v > 2147483647) return 0;
    const iv: i32 = @intCast(v);
    return if (p.sign) -iv else iv;
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

fn compareMagnitude(ca: u128, ea: i32, cb: u128, eb: i32) i32 {
    if (ca == 0 and cb == 0) return 0;
    if (ca == 0) return -1;
    if (cb == 0) return 1;
    const shift = ea - eb;
    if (shift == 0) {
        return if (ca < cb) -1 else if (ca > cb) 1 else 0;
    }
    if (shift > 0) {
        if (shift >= 34) return 1;
        const scaled = @as(u256, ca) * POW10[@intCast(shift)];
        return if (scaled < cb) -1 else if (scaled > cb) 1 else 0;
    }
    const s = -shift;
    if (s >= 34) return -1;
    const scaled = @as(u256, cb) * POW10[@intCast(s)];
    return if (ca < scaled) -1 else if (ca > scaled) 1 else 0;
}

/// Three-way comparison: -1, 0, or 1 (NaN compares unordered → returns 0).
fn compare(a: Phloat, b: Phloat) i32 {
    if (a.class == .nan or b.class == .nan) return 0;
    if (a.class == .inf or b.class == .inf) {
        if (a.class == .inf and b.class == .inf) {
            if (a.sign == b.sign) return 0;
            return if (a.sign) -1 else 1;
        }
        if (a.class == .inf) return if (a.sign) -1 else 1;
        return if (b.sign) 1 else -1;
    }
    if (a.sign != b.sign) return if (a.sign) -1 else 1;
    const c = compareMagnitude(a.coeff, a.exponent, b.coeff, b.exponent);
    return if (a.sign) -c else c;
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

fn addFinite(a: Phloat, b: Phloat) Phloat {
    if (a.coeff == 0) return b;
    if (b.coeff == 0) return a;
    const e = @min(a.exponent, b.exponent);
    const sa = a.exponent - e;
    const sb = b.exponent - e;
    const da = digitCount(@as(u256, a.coeff));
    const db = digitCount(@as(u256, b.coeff));
    // If the larger operand's shifted coefficient would overflow u256, the
    // smaller operand is entirely below the 34-digit precision: it contributes
    // only a sticky bit (and, for opposite signs, a borrow that rounds back up).
    if (sa > 0 and da + sa > 76) {
        return finalize(a.sign, a.coeff, a.exponent, b.coeff != 0, .half_even);
    }
    if (sb > 0 and db + sb > 76) {
        return finalize(b.sign, b.coeff, b.exponent, a.coeff != 0, .half_even);
    }
    const ca = @as(u256, a.coeff) * POW10[@intCast(sa)];
    const cb = @as(u256, b.coeff) * POW10[@intCast(sb)];
    var sign: bool = undefined;
    var coeff: u256 = undefined;
    if (a.sign == b.sign) {
        sign = a.sign;
        coeff = ca + cb;
    } else if (ca >= cb) {
        sign = a.sign;
        coeff = ca - cb;
    } else {
        sign = b.sign;
        coeff = cb - ca;
    }
    if (coeff == 0 and a.sign != b.sign) {
        // exact zero: +0 except FLOOR → -0 (context is HALF_EVEN, so +0)
        sign = false;
    }
    return finalize(sign, coeff, e, false, .half_even);
}

pub fn add(a: Phloat, b: Phloat) Phloat {
    if (a.class == .nan or b.class == .nan) return nan();
    if (a.class == .inf or b.class == .inf) {
        if (a.class == .inf and b.class == .inf) {
            if (a.sign != b.sign) return nan();
            return inf(a.sign);
        }
        if (a.class == .inf) return inf(a.sign);
        return inf(b.sign);
    }
    return addFinite(a, b);
}

pub fn sub(a: Phloat, b: Phloat) Phloat {
    if (b.class == .nan) return nan();
    return add(a, neg(b));
}

pub fn mul(a: Phloat, b: Phloat) Phloat {
    if (a.class == .nan or b.class == .nan) return nan();
    if (a.class == .inf or b.class == .inf) {
        if ((a.class == .inf and b.coeff == 0 and b.class == .finite) or
            (b.class == .inf and a.coeff == 0 and a.class == .finite)) return nan();
        return inf(a.sign != b.sign);
    }
    const sign = a.sign != b.sign;
    const coeff = @as(u256, a.coeff) * @as(u256, b.coeff);
    const exponent = a.exponent + b.exponent;
    return finalize(sign, coeff, exponent, false, .half_even);
}

pub fn div(a: Phloat, b: Phloat) Phloat {
    if (a.class == .nan or b.class == .nan) return nan();
    if (a.class == .inf or b.class == .inf) {
        if (a.class == .inf and b.class == .inf) return nan();
        if (a.class == .inf) return inf(a.sign != b.sign);
        // finite / inf = 0
        return .{ .sign = a.sign != b.sign, .exponent = 0, .coeff = 0, .class = .finite };
    }
    if (b.coeff == 0) {
        if (a.coeff == 0) return nan();
        return inf(a.sign != b.sign);
    }
    if (a.coeff == 0) {
        return .{ .sign = a.sign != b.sign, .exponent = a.exponent - b.exponent, .coeff = 0, .class = .finite };
    }
    // finite / finite: quotient to 35 digits (one guard digit for rounding).
    const sign = a.sign != b.sign;
    const da = digitCount(@as(u256, a.coeff));
    const db = digitCount(@as(u256, b.coeff));
    const scale = 35 - da + db;
    const num = @as(u256, a.coeff) * POW10[@intCast(scale)];
    const q = num / @as(u256, b.coeff);
    const rem = num % @as(u256, b.coeff);
    const sticky = rem != 0;
    var exponent = a.exponent - b.exponent - scale;
    var coeff = q;
    // drop trailing zeros for exact results
    if (!sticky) {
        while (coeff % 10 == 0) {
            coeff /= 10;
            exponent += 1;
        }
    }
    return finalize(sign, coeff, exponent, sticky, .half_even);
}

pub fn neg(a: Phloat) Phloat {
    if (a.class == .nan) return nan();
    if (a.class == .inf) return inf(!a.sign);
    if (a.coeff == 0) return .{ .sign = false, .exponent = a.exponent, .coeff = 0, .class = .finite };
    return .{ .sign = !a.sign, .exponent = a.exponent, .coeff = a.coeff, .class = .finite };
}

pub fn abs(a: Phloat) Phloat {
    if (a.class == .nan) return nan();
    return .{ .sign = false, .exponent = a.exponent, .coeff = a.coeff, .class = a.class };
}

pub fn fma(x: Phloat, y: Phloat, z: Phloat) Phloat {
    return add(mul(x, y), z);
}

/// Floating-point remainder: `x - trunc(x/y) * y`, with the sign of `x`.
pub fn fmod(x: Phloat, y: Phloat) Phloat {
    if (isZero(y)) return nan();
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

fn toIntegral(p: Phloat, rmode: Rounding) Phloat {
    if (p.class == .nan) return nan();
    if (p.class == .inf) return p;
    if (p.exponent >= 0) return p;
    const drop = -p.exponent;
    const r = roundDigits(p.sign, p.coeff, p.exponent, drop, false, rmode);
    return .{ .sign = p.sign, .exponent = r.exponent, .coeff = @intCast(r.coeff), .class = .finite };
}

pub fn floor(p: Phloat) Phloat {
    return toIntegral(p, .floor);
}
pub fn ceil(p: Phloat) Phloat {
    return toIntegral(p, .ceiling);
}
pub fn trunc(p: Phloat) Phloat {
    return toIntegral(p, .down);
}
pub fn round(p: Phloat) Phloat {
    return toIntegral(p, .half_even);
}

// ---------------------------------------------------------------------------
// Predicates
// ---------------------------------------------------------------------------

pub fn isNaN(p: Phloat) bool {
    return p.class == .nan;
}
pub fn isInf(p: Phloat) bool {
    return p.class == .inf;
}
pub fn isZero(p: Phloat) bool {
    return p.class == .finite and p.coeff == 0;
}
pub fn isNegative(p: Phloat) bool {
    return switch (p.class) {
        .nan => false,
        .inf => p.sign,
        .finite => p.sign and p.coeff != 0,
    };
}
pub fn isFinite(p: Phloat) bool {
    return p.class == .finite;
}
pub fn isInteger(p: Phloat) bool {
    return p.class == .finite and p.exponent >= 0;
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

/// Initialize the shared constants. Must be called once before any arithmetic.
pub fn init() void {
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
// Transcendentals — built on the core arithmetic.
//
// add/sub/mul/div are the only primitives, so these are implemented from
// argument reduction + Taylor series, computed to the full 34-digit
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
pub fn logb(x: Phloat) i32 {
    if (x.class != .finite or x.coeff == 0) return 0;
    return x.exponent + digitCount(@as(u256, x.coeff)) - 1;
}

/// Scale by a power of ten: returns x * 10^y.
pub fn scaleb(x: Phloat, y: i32) Phloat {
    if (x.class == .nan) return nan();
    if (x.class == .inf) return x;
    return finalize(x.sign, x.coeff, x.exponent + y, false, .half_even);
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
