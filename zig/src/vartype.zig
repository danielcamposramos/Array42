//! vartype — the HP-42S variable data type.
//!
//! Zig port of Free42's `common/core_variables.h`, extended to the DB48X-grade
//! array model. A `Vartype` is a tagged union over the object types: real,
//! complex, string, and array. An array is a vector of vartype pointers, so a
//! matrix is an array of arrays (rows), and arrays nest to arbitrary depth.
//!
//! The C++ original uses a common leading `int type` field plus downcasts, and
//! keeps three separate container types (real matrix, complex matrix, list).
//! The Zig port unifies those into one recursive `array` type, which is the
//! DB48X model: a matrix is a vector of vectors, and element-wise vs matrix
//! semantics are chosen by the operation, not the type.
//!
//! Memory model: the C++ original uses malloc/free with reference-counted
//! matrix data. This slice keeps arrays *owned* (no sharing), so `disentangle`
//! is a no-op that always succeeds. Reference-counted sharing is reintroduced
//! when the matrix editor and STO/RCL land.

const std = @import("std");
const phloat = @import("phloat.zig");

const alloc = std.heap.c_allocator;

/// The HP-42S object types (matches `TYPE_*` in core_variables.h, with the
/// three container types folded into one `array`).
pub const Type = enum(u8) {
    empty = 0,
    real = 1,
    complex = 2,
    string = 3,
    array = 4,
};

/// An array: an owned vector of pointers to other vartypes. A matrix is an
/// array whose elements are all arrays (rows) of the same length; a vector is
/// an array of scalars; deeper nesting gives higher-rank arrays.
pub const Array = struct {
    data: []?*Vartype,
};

/// A string value (owned buffer).
pub const String = struct {
    text: []u8,
};

pub const Vartype = union(Type) {
    empty: void,
    real: phloat.Phloat,
    complex: struct { re: phloat.Phloat, im: phloat.Phloat },
    string: String,
    array: Array,
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

/// Create an array of `size` null slots.
pub fn newArray(size: i32) ?*Vartype {
    const n: usize = @intCast(size);
    const data = alloc.alloc(?*Vartype, n) catch return null;
    @memset(data, null);
    const v = alloc.create(Vartype) catch {
        alloc.free(data);
        return null;
    };
    v.* = .{ .array = .{ .data = data } };
    return v;
}

// ---------------------------------------------------------------------------
// Destruction
// ---------------------------------------------------------------------------

/// Free a vartype and everything it owns.
pub fn free(v: *Vartype) void {
    switch (v.*) {
        .array => |a| {
            for (a.data) |item| {
                if (item) |p| free(p);
            }
            alloc.free(a.data);
        },
        .string => |s| alloc.free(s.text),
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
        .string => |s| return newString(s.text),
        .array => |a| {
            const nv = newArray(@intCast(a.data.len)) orelse return null;
            for (a.data, 0..) |item, i| {
                if (item) |p| {
                    nv.array.data[i] = dup(p) orelse {
                        free(nv);
                        return null;
                    };
                }
            }
            return nv;
        },
    }
}

/// Make an array's data private. In this slice arrays are always owned, so
/// this always succeeds. (The C++ original shares matrix data via refcounts;
/// that sharing is reintroduced with the matrix editor.)
pub fn disentangle(v: *Vartype) bool {
    _ = v;
    return true;
}

// ---------------------------------------------------------------------------
// Array classification
// ---------------------------------------------------------------------------

/// True if a value is numeric: a real, a complex, or an array whose elements
/// are all numeric (recursively). An empty array is vacuously numeric.
pub fn isNumeric(v: *const Vartype) bool {
    return switch (v.*) {
        .real, .complex => true,
        .array => |a| {
            for (a.data) |item| {
                const p = item orelse return false;
                if (!isNumeric(p)) return false;
            }
            return true;
        },
        else => false,
    };
}

/// True if a value contains a string at any depth.
pub fn containsStrings(v: *const Vartype) bool {
    return switch (v.*) {
        .string => true,
        .array => |a| {
            for (a.data) |item| {
                if (item) |p| {
                    if (containsStrings(p)) return true;
                }
            }
            return false;
        },
        else => false,
    };
}

/// The shape of a 2D numeric array (a matrix): an array whose elements are all
/// arrays (rows) of the same length, each holding only reals and complexes.
pub const MatrixInfo = struct {
    rows: i32,
    columns: i32,
    is_complex: bool,
};

/// If `v` is a matrix (2D numeric array), return its shape; else null.
pub fn matrixInfo(v: *const Vartype) ?MatrixInfo {
    const a = switch (v.*) {
        .array => |a| a,
        else => return null,
    };
    if (a.data.len == 0) return null;
    var columns: i32 = -1;
    var is_complex = false;
    for (a.data) |row_opt| {
        const row = row_opt orelse return null;
        const ra = switch (row.*) {
            .array => |ra| ra,
            else => return null,
        };
        if (columns == -1) columns = @intCast(ra.data.len);
        if (ra.data.len != columns) return null;
        for (ra.data) |elem_opt| {
            const elem = elem_opt orelse return null;
            switch (elem.*) {
                .real => {},
                .complex => is_complex = true,
                else => return null,
            }
        }
    }
    return .{ .rows = @intCast(a.data.len), .columns = columns, .is_complex = is_complex };
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

test "complex and array construction" {
    phloat.init();
    const c = newComplex(phloat.fromInt(1), phloat.fromInt(2)) orelse return error.OOM;
    defer free(c);
    try std.testing.expectEqualStrings("1", phloat.toString(c.complex.re));
    try std.testing.expectEqualStrings("2", phloat.toString(c.complex.im));

    const a = newArray(3) orelse return error.OOM;
    defer free(a);
    try std.testing.expectEqual(@as(usize, 3), a.array.data.len);
    try std.testing.expect(!containsStrings(a));
}

test "matrixInfo classifies a 2D numeric array" {
    phloat.init();
    // [[1,2,3],[4,5,6]] — 2×3 real matrix.
    const m = newArray(2) orelse return error.OOM;
    defer free(m);
    const r0 = newArray(3) orelse return error.OOM;
    const r1 = newArray(3) orelse return error.OOM;
    m.array.data[0] = r0;
    m.array.data[1] = r1;
    r0.array.data[0] = newReal(phloat.fromInt(1)) orelse return error.OOM;
    r0.array.data[1] = newReal(phloat.fromInt(2)) orelse return error.OOM;
    r0.array.data[2] = newReal(phloat.fromInt(3)) orelse return error.OOM;
    r1.array.data[0] = newReal(phloat.fromInt(4)) orelse return error.OOM;
    r1.array.data[1] = newReal(phloat.fromInt(5)) orelse return error.OOM;
    r1.array.data[2] = newReal(phloat.fromInt(6)) orelse return error.OOM;

    const info = matrixInfo(m) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 2), info.rows);
    try std.testing.expectEqual(@as(i32, 3), info.columns);
    try std.testing.expect(!info.is_complex);
    try std.testing.expect(isNumeric(m));
    try std.testing.expect(!containsStrings(m));
}
