//! variables — the HP-42S named-variable store.
//!
//! Zig port of Free42's `common/core_variables.cc` variable table: the `vars`
//! array of `var_struct` entries plus lookup/recall/store/purge. This is the
//! substrate for STO/RCL and the "addressable arrays" feature: every stored
//! value gets a stable `handle` (a monotonically-increasing id) that the MCP
//! layer can use to reference an object by name across stack operations.
//!
//! Local variables (program-scoped, `level != -1`) are deferred until the
//! program/RTN system lands; everything here is global.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");

const alloc = std.heap.c_allocator;
const Err = globals.Err;

/// Maximum variable name length (HP-42S limit).
pub const MAX_NAME_LEN: usize = 7;

/// Variable flags (matches VAR_HIDDEN/VAR_HIDING/VAR_PRIVATE in core_globals.h).
pub const VarFlags = struct {
    hidden: bool = false,
    hiding: bool = false,
    private: bool = false,
};

/// A named variable (matches `var_struct` in core_globals.h, plus a stable
/// `handle` for the MCP layer).
pub const Var = struct {
    name: [MAX_NAME_LEN]u8 = .{0} ** MAX_NAME_LEN,
    length: u8 = 0,
    level: i16 = -1, // -1 = global; local levels deferred
    flags: VarFlags = .{},
    value: ?*vartype.Vartype = null,
    handle: u64 = 0, // stable unique id, assigned at creation
};

/// The variable table.
pub var vars: []Var = &.{};
pub var vars_count: usize = 0;
var vars_capacity: usize = 0;
var next_handle: u64 = 1;

fn nameEquals(v: *const Var, name: []const u8) bool {
    if (v.length != name.len) return false;
    for (name, 0..) |c, i| {
        if (v.name[i] != c) return false;
    }
    return true;
}

/// Find a visible (non-hidden, non-private) variable by name; null if absent.
pub fn lookupVar(name: []const u8) ?usize {
    var i = vars_count;
    while (i > 0) {
        i -= 1;
        const v = &vars[i];
        if (v.flags.hidden or v.flags.private) continue;
        if (nameEquals(v, name)) return i;
    }
    return null;
}

/// Recall a variable's value (borrowed, not copied); null if absent.
pub fn recallVar(name: []const u8) ?*vartype.Vartype {
    const idx = lookupVar(name) orelse return null;
    return vars[idx].value;
}

/// The stable handle of a variable, or null if absent.
pub fn handleOf(name: []const u8) ?u64 {
    const idx = lookupVar(name) orelse return null;
    return vars[idx].handle;
}

/// The name of the visible variable with the given handle, or null.
pub fn nameOfHandle(handle: u64) ?[]const u8 {
    for (vars[0..vars_count]) |*v| {
        if (v.handle == handle and !v.flags.hidden and !v.flags.private) {
            return v.name[0..v.length];
        }
    }
    return null;
}

fn ensureCapacity(n: usize) bool {
    const nc = vars_count + n;
    if (nc <= vars_capacity) return true;
    const new_cap = nc + 25;
    const nv = alloc.realloc(vars, new_cap) catch return false;
    vars = nv;
    vars_capacity = new_cap;
    return true;
}

/// Store a value under a name, creating or replacing the variable. The value
/// is adopted (ownership transfers). Replacing an existing variable keeps its
/// stable handle.
pub fn storeVar(name: []const u8, value: *vartype.Vartype) Err {
    if (name.len > MAX_NAME_LEN) return .name_too_long;
    if (lookupVar(name)) |idx| {
        vartype.freeOpt(vars[idx].value);
        vars[idx].value = value;
        return .none;
    }
    if (!ensureCapacity(1)) return .insufficient_memory;
    const idx = vars_count;
    vars_count += 1;
    var v = Var{};
    v.length = @intCast(name.len);
    for (name, 0..) |c, i| v.name[i] = c;
    v.value = value;
    v.handle = next_handle;
    next_handle += 1;
    vars[idx] = v;
    return .none;
}

/// Purge a variable by name. Returns true (not-found is not an error).
pub fn purgeVar(name: []const u8) bool {
    const idx = lookupVar(name) orelse return true;
    vartype.freeOpt(vars[idx].value);
    var i = idx;
    while (i + 1 < vars_count) : (i += 1) {
        vars[i] = vars[i + 1];
    }
    vars_count -= 1;
    return true;
}

/// Purge all variables.
pub fn purgeAllVars() void {
    for (vars[0..vars_count]) |*v| vartype.freeOpt(v.value);
    vars_count = 0;
}

/// True if any visible variable exists.
pub fn varsExist() bool {
    for (vars[0..vars_count]) |*v| {
        if (!v.flags.hidden and !v.flags.private) return true;
    }
    return false;
}

/// Free all variables and reset the table.
pub fn deinit() void {
    purgeAllVars();
    if (vars.len > 0) alloc.free(vars);
    vars = &.{};
    vars_capacity = 0;
    next_handle = 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "store/recall/purge round-trip" {
    globals.init();
    defer globals.deinit();
    defer deinit();

    const v = vartype.newReal(phloat.fromInt(42)) orelse return error.OOM;
    try std.testing.expectEqual(Err.none, storeVar("M1", v));
    try std.testing.expectEqual(@as(usize, 1), vars_count);

    const r = recallVar("M1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42", phloat.toString(r.real));

    // Replacing keeps the handle stable.
    const h1 = handleOf("M1") orelse return error.TestUnexpectedResult;
    const v2 = vartype.newReal(phloat.fromInt(43)) orelse return error.OOM;
    try std.testing.expectEqual(Err.none, storeVar("M1", v2));
    try std.testing.expectEqual(h1, handleOf("M1"));
    try std.testing.expectEqualStrings("43", phloat.toString(recallVar("M1").?.real));

    try std.testing.expect(purgeVar("M1"));
    try std.testing.expectEqual(@as(usize, 0), vars_count);
    try std.testing.expect(recallVar("M1") == null);
}

test "name length limit" {
    globals.init();
    defer globals.deinit();
    defer deinit();
    const v = vartype.newReal(phloat.fromInt(1)) orelse return error.OOM;
    try std.testing.expectEqual(Err.name_too_long, storeVar("TOOLONGNAME", v));
    vartype.free(v);
}
