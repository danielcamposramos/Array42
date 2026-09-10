//! display — number formatting for the HP-42S display.
//!
//! Zig port of the display-relevant part of Free42's `phloat2string`
//! (FIX/SCI/ENG/ALL modes). This is a first cut: it handles the four display
//! modes and rounds to the display precision, but does not yet implement
//! thousands separators or the full Free42 edge-case behavior.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");

pub const Mode = enum {
    all,
    fix,
    sci,
    eng,
};

/// Thread-local scratch for `format` — valid until the next call.
threadlocal var buf: [64]u8 = undefined;

/// Format a phloat for display. `digits` is the FIX/SCI/ENG digit count
/// (0..11); ignored in ALL mode.
pub fn format(p: phloat.Phloat, mode: Mode, digits: u8) []const u8 {
    // Special values.
    if (phloat.isNaN(p)) return "NaN";
    if (phloat.isInf(p)) return if (phloat.isNegative(p)) "-Infinity" else "Infinity";

    // Parse the raw decimal string into sign + digits + exponent.
    const raw = phloat.toString(p);
    var neg = false;
    var s = raw;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }

    // Split off the exponent ("E±n").
    var mant = s;
    var exp: i32 = 0;
    if (std.mem.indexOfAny(u8, s, "eE")) |ei| {
        mant = s[0..ei];
        const es = s[ei + 1 ..];
        exp = std.fmt.parseInt(i32, es, 10) catch 0;
    }

    // Split mantissa into integer and fraction parts around the '.'.
    var int_part = mant;
    var frac_part: []const u8 = &.{};
    if (std.mem.indexOfScalar(u8, mant, '.')) |di| {
        int_part = mant[0..di];
        frac_part = mant[di + 1 ..];
    }

    // digits = int_part ++ frac_part, exponent = exp + int_part.len - 1.
    var digits_buf: [40]u8 = undefined;
    var dlen: usize = 0;
    for (int_part) |c| {
        digits_buf[dlen] = c;
        dlen += 1;
    }
    for (frac_part) |c| {
        digits_buf[dlen] = c;
        dlen += 1;
    }
    const e = exp + @as(i32, @intCast(int_part.len)) - 1;

    // Determine significant digits and round.
    const sig: usize = switch (mode) {
        .all => 12,
        .fix => @as(usize, digits) + 1 + @as(usize, @intCast(@max(e, 0))),
        .sci => @as(usize, digits) + 1,
        .eng => @as(usize, @intCast(@mod(e, 3) + 1)) + @as(usize, digits),
    };

    var d = digits_buf[0..dlen];
    var carry = false;
    if (d.len > sig) {
        const r = roundDigits(d, sig);
        d = d[0..r.len];
        carry = r.carry;
    }
    var ee = e;
    if (carry) {
        // 999… → 1000…: prepend a 1 and bump the exponent.
        var tmp: [40]u8 = undefined;
        tmp[0] = '1';
        @memcpy(tmp[1 .. 1 + d.len], d);
        d = tmp[0 .. 1 + d.len];
        ee += 1;
    }

    // Strip leading zeros (e.g. "0.001" → digits "1").
    while (d.len > 1 and d[0] == '0') {
        d = d[1..];
        ee -= 1;
    }

    return switch (mode) {
        .all => formatAll(neg, d, ee),
        .fix => formatFix(neg, d, ee, digits),
        .sci => formatSci(neg, d, ee, digits),
        .eng => formatEng(neg, d, ee, digits),
    };
}

/// Round a digit string to `sig` significant digits (round half up).
fn roundDigits(d: []u8, sig: usize) struct { len: usize, carry: bool } {
    if (d.len <= sig) return .{ .len = d.len, .carry = false };
    const keep = d[0..sig];
    const drop = d[sig..];
    // Round up if the first dropped digit is >= 5.
    const round_up = drop[0] >= '5';
    if (!round_up) return .{ .len = sig, .carry = false };
    // Increment the kept digits.
    var i: usize = sig;
    while (i > 0) {
        i -= 1;
        if (keep[i] == '9') {
            keep[i] = '0';
        } else {
            keep[i] += 1;
            return .{ .len = sig, .carry = false };
        }
    }
    // All 9s: carry.
    return .{ .len = sig, .carry = true };
}

fn writeDigits(out: []u8, d: []const u8) usize {
    @memcpy(out[0..d.len], d);
    return d.len;
}

fn formatAll(neg: bool, d: []const u8, e: i32) []const u8 {
    var n: usize = 0;
    if (neg) {
        buf[n] = '-';
        n += 1;
    }
    // Fixed notation when the exponent is in a "reasonable" range.
    if (e >= -3 and e < 12) {
        if (e < 0) {
            buf[n] = '0';
            n += 1;
            buf[n] = '.';
            n += 1;
            var i: i32 = e + 1;
            while (i < 0) : (i += 1) {
                buf[n] = '0';
                n += 1;
            }
            n += writeDigits(buf[n..], d);
        } else {
            const ip: usize = @intCast(e + 1);
            if (ip >= d.len) {
                n += writeDigits(buf[n..], d);
                var i: usize = d.len;
                while (i < ip) : (i += 1) {
                    buf[n] = '0';
                    n += 1;
                }
            } else {
                n += writeDigits(buf[n..], d[0..ip]);
                buf[n] = '.';
                n += 1;
                n += writeDigits(buf[n..], d[ip..]);
            }
        }
        // Strip trailing zeros after the decimal point.
        return trimZeros(buf[0..n]);
    }
    // Scientific notation.
    n += writeDigits(buf[n..], d[0..1]);
    if (d.len > 1) {
        buf[n] = '.';
        n += 1;
        n += writeDigits(buf[n..], d[1..]);
    }
    n += writeExp(buf[n..], e);
    return buf[0..n];
}

fn formatFix(neg: bool, d: []const u8, e: i32, digits: u8) []const u8 {
    var n: usize = 0;
    if (neg) {
        buf[n] = '-';
        n += 1;
    }
    const dp: i32 = e + 1; // position of the decimal point (digits before it)
    if (dp <= 0) {
        buf[n] = '0';
        n += 1;
        buf[n] = '.';
        n += 1;
        var i: i32 = 0;
        while (i < -dp) : (i += 1) {
            buf[n] = '0';
            n += 1;
        }
        n += writeDigits(buf[n..], d);
    } else {
        const ip: usize = @intCast(dp);
        if (ip >= d.len) {
            n += writeDigits(buf[n..], d);
            var i: usize = d.len;
            while (i < ip) : (i += 1) {
                buf[n] = '0';
                n += 1;
            }
        } else {
            n += writeDigits(buf[n..], d[0..ip]);
            buf[n] = '.';
            n += 1;
            n += writeDigits(buf[n..], d[ip..]);
        }
    }
    // Pad or truncate to exactly `digits` places after the decimal point.
    return padFix(buf[0..n], digits);
}

fn formatSci(neg: bool, d: []const u8, e: i32, digits: u8) []const u8 {
    var n: usize = 0;
    if (neg) {
        buf[n] = '-';
        n += 1;
    }
    n += writeDigits(buf[n..], d[0..1]);
    if (digits > 0) {
        buf[n] = '.';
        n += 1;
        var i: u8 = 0;
        while (i < digits) : (i += 1) {
            const idx: usize = 1 + @as(usize, i);
            buf[n] = if (idx < d.len) d[idx] else '0';
            n += 1;
        }
    }
    n += writeExp(buf[n..], e);
    return buf[0..n];
}

fn formatEng(neg: bool, d: []const u8, e: i32, digits: u8) []const u8 {
    // Engineering: exponent is a multiple of 3, mantissa in [1, 1000).
    var n: usize = 0;
    if (neg) {
        buf[n] = '-';
        n += 1;
    }
    const rem = @mod(e, 3);
    const eng_e = e - rem;
    const lead: usize = @intCast(rem + 1); // digits before the decimal point
    var i: usize = 0;
    while (i < lead) : (i += 1) {
        buf[n] = if (i < d.len) d[i] else '0';
        n += 1;
    }
    if (digits > 0) {
        buf[n] = '.';
        n += 1;
        var j: u8 = 0;
        while (j < digits) : (j += 1) {
            const idx: usize = lead + @as(usize, j);
            buf[n] = if (idx < d.len) d[idx] else '0';
            n += 1;
        }
    }
    n += writeExp(buf[n..], eng_e);
    return buf[0..n];
}

fn writeExp(out: []u8, e: i32) usize {
    var n: usize = 0;
    out[n] = 'E';
    n += 1;
    if (e < 0) {
        out[n] = '-';
        n += 1;
    } else {
        out[n] = '+';
        n += 1;
    }
    const a = @abs(e);
    const s = std.fmt.bufPrint(out[n..], "{d}", .{a}) catch unreachable;
    return n + s.len;
}

/// Strip trailing zeros after the decimal point (and a trailing '.').
fn trimZeros(s: []const u8) []const u8 {
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '.')) |di| {
        while (end > di + 1 and s[end - 1] == '0') end -= 1;
        if (end == di + 1) end = di; // drop the '.' too
    }
    return s[0..end];
}

/// Pad or truncate the fractional part to exactly `digits` places.
fn padFix(s: []const u8, digits: u8) []const u8 {
    const di = std.mem.indexOfScalar(u8, s, '.') orelse {
        // No decimal point yet: append one and pad.
        var n = s.len;
        buf[n] = '.';
        n += 1;
        var i: u8 = 0;
        while (i < digits) : (i += 1) {
            buf[n] = '0';
            n += 1;
        }
        return buf[0..n];
    };
    const frac_len = s.len - di - 1;
    if (frac_len == digits) return s;
    if (frac_len > digits) return s[0 .. di + 1 + digits];
    // Pad with zeros.
    var n = s.len;
    var i: usize = frac_len;
    while (i < digits) : (i += 1) {
        buf[n] = '0';
        n += 1;
    }
    return buf[0..n];
}

/// Format the X register using the current display flags.
pub fn formatX() []const u8 {
    const x = globals.stack[@intCast(globals.sp)] orelse return "";
    return formatVartype(x);
}

/// Format any vartype using the current display flags.
pub fn formatVartype(v: *const vartype.Vartype) []const u8 {
    return switch (v.*) {
        .real => |r| format(r, currentMode(), globals.displayDigits()),
        .complex => |c| formatComplex(c.re, c.im),
        .string => |s| s.text,
        else => "<matrix>",
    };
}

fn currentMode() Mode {
    if (globals.flags.fix_or_all and globals.flags.eng_or_all) return .all;
    if (globals.flags.fix_or_all) return .fix;
    if (globals.flags.eng_or_all) return .eng;
    return .sci;
}

fn formatComplex(re: phloat.Phloat, im: phloat.Phloat) []const u8 {
    const mode = currentMode();
    const digits = globals.displayDigits();
    // `format` returns a slice into the shared threadlocal `buf`, so each piece
    // must be copied out before the next `format` call overwrites it.
    const rs = format(re, mode, digits);
    var rs_buf: [64]u8 = undefined;
    @memcpy(rs_buf[0..rs.len], rs);
    const is = format(phloat.abs(im), mode, digits);
    var is_buf: [64]u8 = undefined;
    @memcpy(is_buf[0..is.len], is);
    const sign = if (phloat.isNegative(im)) "-" else "+";
    return std.fmt.bufPrint(&buf, "{s}{s}i{s}", .{ rs_buf[0..rs.len], sign, is_buf[0..is.len] }) catch "?";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ALL mode formatting" {
    phloat.init();
    try std.testing.expectEqualStrings("123", format(phloat.fromString("123"), .all, 0));
    try std.testing.expectEqualStrings("1.23", format(phloat.fromString("1.23"), .all, 0));
    try std.testing.expectEqualStrings("0.001", format(phloat.fromString("0.001"), .all, 0));
    try std.testing.expectEqualStrings("-4.5", format(phloat.fromString("-4.5"), .all, 0));
    try std.testing.expectEqualStrings("1E+12", format(phloat.fromString("1E12"), .all, 0));
}

test "FIX mode formatting" {
    phloat.init();
    try std.testing.expectEqualStrings("3.14", format(phloat.fromString("3.14159"), .fix, 2));
    try std.testing.expectEqualStrings("3.142", format(phloat.fromString("3.14159"), .fix, 3));
    try std.testing.expectEqualStrings("0.00", format(phloat.fromString("0"), .fix, 2));
}

test "SCI mode formatting" {
    phloat.init();
    try std.testing.expectEqualStrings("1.23E+5", format(phloat.fromString("123000"), .sci, 2));
    try std.testing.expectEqualStrings("1.00E-7", format(phloat.fromString("0.0000001"), .sci, 2));
}

test "ENG mode formatting" {
    phloat.init();
    try std.testing.expectEqualStrings("123E+3", format(phloat.fromString("123000"), .eng, 0));
    try std.testing.expectEqualStrings("1.23E+6", format(phloat.fromString("1230000"), .eng, 2));
}
