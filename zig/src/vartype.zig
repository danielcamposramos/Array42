//! vartype — the HP-42S variable data type.
//!
//! Zig port of Free42's `common/core_variables.h`. A `Vartype` is a tagged
//! union over the six HP-42S object types: real, complex, real matrix,
//! complex matrix, string, and list.
//!
//! The C++ original uses a common leading `int type` field plus downcasts; the
//! Zig port uses a native tagged union, which is the same shape with the tag
//! checked by the compiler instead of by hand.
//!
//! Memory model: the C++ original uses malloc/free with reference-counted
//! matrix data (`realmatrix_data` / `complexmatrix_data`). This slice keeps
//! matrices *owned* (no sharing), so `disentangle` is a no-op that always
//! succeeds. Reference-counted sharing is reintroduced when the matrix editor
//! and STO/RCL land.

const std = @import("std");
const phloat = @import("phloat.zig");

const alloc = std.heap.c_allocator;

/// The six HP-42S object types (matches `TYPE_*` in core_variables.h).
pub const Type = enum(u8) {
    empty = 0,
    real = 1,
    complex = 2,
    realmatrix = 3,
    complexmatrix = 4,
    string = 5,
    list = 6,
};

/// A real matrix: `rows` × `columns` of phloat, with a parallel `is_string`
/// array (0 = number, 1 = short string, 2 = long string) for the HP-42S
/// "matrix of strings" feature.
pub const RealMatrix = struct {
    rows: i32,
    columns: i32,
    data: []phloat.Phloat,
    is_string: []u8,
};

/// A complex matrix: `rows` × `columns` of complex values, stored as
/// interleaved (re, im) pairs.
pub const ComplexMatrix = struct {
    rows: i32,
    columns: i32,
    data: []phloat.Phloat,
};

/// A string value (owned buffer).
pub const String = struct {
    text: []u8,
};

/// A list value: an owned array of pointers to other vartypes.
pub const List = struct {
    data: []?*Vartype,
};

pub const Vartype = union(Type) {
    empty: void,
    real: phloat.Phloat,
    complex: struct { re: phloat.Phloat, im: phloat.Phloat },
    realmatrix: RealMatrix,
    complexmatrix: ComplexMatrix,
    string: String,
    list: List,
};

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

pub fn newReal(value: phloat.Phloat) ?*Vartype {
    const v = alloc.create(Vartype) catch return null;
    v.* = .{ .real = value };
    return v;
}

pub fn newComplex(re: phloat.Phloat, im: phloat.Phloat) ?*Vartype {
    const v = alloc.create(Vartype) catch return null;
    v.* = .{ .complex = .{ .re = re, .im = im } };
    return v;
}

pub fn newString(s: []const u8) ?*Vartype {
    const text = alloc.dupe(u8, s) catch return null;
    const v = alloc.create(Vartype) catch {
        alloc.free(text);
        return null;
    };
    v.* = .{ .string = .{ .text = text } };
    return v;
}

pub fn newRealMatrix(rows: i32, columns: i32) ?*Vartype {
    const n: usize = @intCast(rows * columns);
    const data = alloc.alloc(phloat.Phloat, n) catch return null;
    const is_string = alloc.alloc(u8, n) catch {
        alloc.free(data);
        return null;
    };
    @memset(data, phloat.fromInt(0));
    @memset(is_string, 0);
    const v = alloc.create(Vartype) catch {
        alloc.free(data);
        alloc.free(is_string);
        return null;
    };
    v.* = .{ .realmatrix = .{ .rows = rows, .columns = columns, .data = data, .is_string = is_string } };
    return v;
}

pub fn newComplexMatrix(rows: i32, columns: i32) ?*Vartype {
    const n: usize = @intCast(2 * rows * columns);
    const data = alloc.alloc(phloat.Phloat, n) catch return null;
    @memset(data, phloat.fromInt(0));
    const v = alloc.create(Vartype) catch {
        alloc.free(data);
        return null;
    };
    v.* = .{ .complexmatrix = .{ .rows = rows, .columns = columns, .data = data } };
    return v;
}

pub fn newList(size: i32) ?*Vartype {
    const n: usize = @intCast(size);
    const data = alloc.alloc(?*Vartype, n) catch return null;
    @memset(data, null);
    const v = alloc.create(Vartype) catch {
        alloc.free(data);
        return null;
    };
    v.* = .{ .list = .{ .data = data } };
    return v;
}

// ---------------------------------------------------------------------------
// Destruction
// ---------------------------------------------------------------------------

/// Free a vartype and everything it owns.
pub fn free(v: *Vartype) void {
    switch (v.*) {
        .realmatrix => |m| {
            alloc.free(m.data);
            alloc.free(m.is_string);
        },
        .complexmatrix => |m| alloc.free(m.data),
        .string => |s| alloc.free(s.text),
        .list => |l| {
            for (l.data) |item| {
                if (item) |p| free(p);
            }
            alloc.free(l.data);
        },
        else => {},
    }
    alloc.destroy(v);
}

/// Free a nullable vartype pointer (no-op on null).
pub fn freeOpt(v: ?*Vartype) void {
    if (v) |p| free(p);
}

// ---------------------------------------------------------------------------
// Copying
// ---------------------------------------------------------------------------

/// Deep-copy a vartype. Returns null on allocation failure.
pub fn dup(v: *const Vartype) ?*Vartype {
    switch (v.*) {
        .empty => return alloc.create(Vartype) catch null,
        .real => |x| return newReal(x),
        .complex => |c| return newComplex(c.re, c.im),
        .realmatrix => |m| {
            const nv = newRealMatrix(m.rows, m.columns) orelse return null;
            @memcpy(nv.realmatrix.data, m.data);
            @memcpy(nv.realmatrix.is_string, m.is_string);
            return nv;
        },
        .complexmatrix => |m| {
            const nv = newComplexMatrix(m.rows, m.columns) orelse return null;
            @memcpy(nv.complexmatrix.data, m.data);
            return nv;
        },
        .string => |s| return newString(s.text),
        .list => |l| {
            const nv = newList(@intCast(l.data.len)) orelse return null;
            for (l.data, 0..) |item, i| {
                if (item) |p| {
                    nv.list.data[i] = dup(p) orelse {
                        free(nv);
                        return null;
                    };
                }
            }
            return nv;
        },
    }
}

/// Make a matrix's data private. In this slice matrices are always owned, so
/// this always succeeds. (The C++ original shares matrix data via refcounts;
/// that sharing is reintroduced with the matrix editor.)
pub fn disentangle(v: *Vartype) bool {
    _ = v;
    return true;
}

/// True if a real matrix contains any string elements.
pub fn containsStrings(rm: *const RealMatrix) bool {
    for (rm.is_string) |s| {
        if (s != 0) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "newReal / dup / free round-trip" {
    phloat.init();
    const v = newReal(phloat.fromString("3.14")) orelse return error.OOM;
    defer free(v);
    try std.testing.expectEqual(Type.real, std.meta.activeTag(v.*));
    try std.testing.expectEqualStrings("3.14", phloat.toString(v.real));

    const d = dup(v) orelse return error.OOM;
    defer free(d);
    try std.testing.expectEqualStrings("3.14", phloat.toString(d.real));
}

test "complex and matrix construction" {
    phloat.init();
    const c = newComplex(phloat.fromInt(1), phloat.fromInt(2)) orelse return error.OOM;
    defer free(c);
    try std.testing.expectEqualStrings("1", phloat.toString(c.complex.re));
    try std.testing.expectEqualStrings("2", phloat.toString(c.complex.im));

    const m = newRealMatrix(2, 3) orelse return error.OOM;
    defer free(m);
    try std.testing.expectEqual(@as(i32, 2), m.realmatrix.rows);
    try std.testing.expectEqual(@as(i32, 3), m.realmatrix.columns);
    try std.testing.expectEqual(@as(usize, 6), m.realmatrix.data.len);
    try std.testing.expect(!containsStrings(&m.realmatrix));
}
