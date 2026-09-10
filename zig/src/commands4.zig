//! commands4 — the HP-42S variable commands (STO/RCL/SIZE/DIM/CLV/CLRG).
//!
//! Zig port of Free42's `common/core_sto_rcl.cc` (generic_sto/generic_rcl)
//! and the variable commands scattered across `core_commands1.cc` (STO, RCL,
//! SIZE, CLV, CLRG) and `core_commands3.cc` (DIM). These are the "addressable
//! arrays" commands: they give a value on the stack a stable name (STO) and
//! bring it back by name (RCL), backed by `variables.zig`.
//!
//! The numbered-register file (STO 05 / RCL 05) is the special variable
//! "REGS", represented as a 1D array (vector) — the DB48X-grade register file.
//! Indirect addressing (STO IND …) is deferred with the program system.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const helpers = @import("helpers.zig");
const variables = @import("variables.zig");
const commands1 = @import("commands1.zig");

const Err = globals.Err;
const Vartype = vartype.Vartype;
const Arg = commands1.Arg;
const ArgType = commands1.ArgType;

fn x() *Vartype {
    return globals.stack[helpers.xIndex()].?;
}
fn y() *Vartype {
    return globals.stack[helpers.xIndex() - 1].?;
}

/// Map a stack-level letter to an offset from X (0=X, 1=Y, 2=Z, 3=T, -1=L).
fn stkIndex(c: u8) i32 {
    return switch (c) {
        'X' => 0,
        'Y' => 1,
        'Z' => 2,
        'T' => 3,
        'L' => -1,
        else => -2,
    };
}

// ---------------------------------------------------------------------------
// RCL — recall a value onto the stack
// ---------------------------------------------------------------------------

/// Recall a value into `dst` (a fresh copy) based on the argument type:
/// NUM → REGS[index], STK → stack level, STR → named variable.
pub fn genericRcl(arg: *const Arg, dst: *?*Vartype) Err {
    switch (arg.type) {
        .num => {
            const regs = variables.recallVar("REGS") orelse return .size_error;
            const a = switch (regs.*) {
                .array => |a| a,
                else => return .internal_error,
            };
            const index: usize = @intCast(arg.num);
            if (index >= a.data.len) return .size_error;
            const elem = a.data[index] orelse return .internal_error;
            dst.* = vartype.dup(elem) orelse return .insufficient_memory;
            return .none;
        },
        .stk => {
            const idx = stkIndex(arg.stk);
            if (idx == -2) return .invalid_type;
            if (idx == -1) {
                dst.* = vartype.dup(globals.lastx.?) orelse return .insufficient_memory;
            } else {
                if (idx > globals.sp) return .stack_depth_error;
                dst.* = vartype.dup(globals.stack[@intCast(globals.sp - idx)].?) orelse return .insufficient_memory;
            }
            return .none;
        },
        .str => {
            const name = arg.text[0..arg.length];
            const v = variables.recallVar(name) orelse return .nonexistent;
            dst.* = vartype.dup(v) orelse return .insufficient_memory;
            return .none;
        },
        else => return .invalid_type,
    }
}

pub fn docmdRcl(arg: ?*const Arg) Err {
    var v: ?*Vartype = null;
    const e = genericRcl(arg.?, &v);
    if (e != .none) return e;
    globals.mode_disable_stack_lift = true;
    return helpers.recallResult(v.?);
}

/// RCL arithmetic: X = X OP recalled. Shared by RCL÷/RCL×/RCL−/RCL+.
fn rclArithmetic(arg: *const Arg, op: enum { div, mul, sub, add }) Err {
    var v: ?*Vartype = null;
    const e = genericRcl(arg, &v);
    if (e != .none) return e;
    const e2 = helpers.assertNumeric(v.?);
    if (e2 != .none) {
        vartype.free(v.?);
        return e2;
    }
    var w: ?*Vartype = null;
    const e3 = switch (op) {
        .div => helpers.genericDiv(v.?, x(), &w),
        .mul => helpers.genericMul(v.?, x(), &w),
        .sub => helpers.genericSub(v.?, x(), &w),
        .add => helpers.genericAdd(v.?, x(), &w),
    };
    vartype.free(v.?);
    if (e3 != .none) return e3;
    helpers.unaryResult(w.?);
    globals.mode_disable_stack_lift = true;
    return .none;
}

pub fn docmdRclDiv(arg: ?*const Arg) Err {
    return rclArithmetic(arg.?, .div);
}
pub fn docmdRclMul(arg: ?*const Arg) Err {
    return rclArithmetic(arg.?, .mul);
}
pub fn docmdRclSub(arg: ?*const Arg) Err {
    return rclArithmetic(arg.?, .sub);
}
pub fn docmdRclAdd(arg: ?*const Arg) Err {
    return rclArithmetic(arg.?, .add);
}

// ---------------------------------------------------------------------------
// STO — store X into a variable / register / stack level
// ---------------------------------------------------------------------------

/// Compute `oldval OP X` (the STO+/STO−/STO×/STO÷ semantics), returning a
/// fresh value. `oldval` must be numeric.
fn applyStoOperation(operation: u8, oldval: *const Vartype, res: *?*Vartype) Err {
    const e = helpers.assertNumeric(oldval);
    if (e != .none) return e;
    return switch (operation) {
        '/' => helpers.genericDiv(x(), oldval, res),
        '*' => helpers.genericMul(x(), oldval, res),
        '-' => helpers.genericSub(x(), oldval, res),
        '+' => helpers.genericAdd(x(), oldval, res),
        else => .internal_error,
    };
}

/// Store X into a destination based on the argument type, with an optional
/// arithmetic operation (0 = plain STO, else '+', '-', '*', '/').
pub fn genericSto(arg: *const Arg, operation: u8) Err {
    if (operation != 0 and x().* == .string) return .alpha_data_is_invalid;

    switch (arg.type) {
        .num => {
            const regs = variables.recallVar("REGS") orelse return .size_error;
            const a = switch (regs.*) {
                .array => |a| a,
                else => return .internal_error,
            };
            const index: usize = @intCast(arg.num);
            if (index >= a.data.len) return .size_error;
            if (operation == 0) {
                vartype.freeOpt(a.data[index]);
                a.data[index] = vartype.dup(x()) orelse return .insufficient_memory;
            } else {
                const oldval = a.data[index] orelse return .invalid_type;
                var res: ?*Vartype = null;
                const e = applyStoOperation(operation, oldval, &res);
                if (e != .none) return e;
                vartype.freeOpt(a.data[index]);
                a.data[index] = res;
            }
            globals.mode_disable_stack_lift = true;
            return .none;
        },
        .stk => {
            const idx = stkIndex(arg.stk);
            if (idx == -2) return .invalid_type;
            if (operation == 0) {
                if (idx == 0) return .none; // STO ST X is a no-op
                const newval = vartype.dup(x()) orelse return .insufficient_memory;
                if (idx == -1) {
                    vartype.freeOpt(globals.lastx);
                    globals.lastx = newval;
                } else {
                    if (idx > globals.sp) return .stack_depth_error;
                    const dst = &globals.stack[@intCast(globals.sp - idx)];
                    vartype.freeOpt(dst.*);
                    dst.* = newval;
                }
            } else {
                const oldval: ?*Vartype = if (idx == -1)
                    globals.lastx
                else if (idx > globals.sp)
                    return .stack_depth_error
                else
                    globals.stack[@intCast(globals.sp - idx)];
                const ov = oldval orelse return .invalid_type;
                var res: ?*Vartype = null;
                const e = applyStoOperation(operation, ov, &res);
                if (e != .none) return e;
                if (idx == -1) {
                    vartype.freeOpt(globals.lastx);
                    globals.lastx = res;
                } else {
                    const dst = &globals.stack[@intCast(globals.sp - idx)];
                    vartype.freeOpt(dst.*);
                    dst.* = res;
                }
            }
            globals.mode_disable_stack_lift = true;
            return .none;
        },
        .str => {
            const name = arg.text[0..arg.length];
            if (operation == 0) {
                const newval = vartype.dup(x()) orelse return .insufficient_memory;
                const e = variables.storeVar(name, newval);
                if (e != .none) vartype.free(newval);
                globals.mode_disable_stack_lift = true;
                return e;
            } else {
                const oldval = variables.recallVar(name) orelse return .nonexistent;
                var res: ?*Vartype = null;
                const e = applyStoOperation(operation, oldval, &res);
                if (e != .none) return e;
                globals.mode_disable_stack_lift = true;
                return variables.storeVar(name, res.?);
            }
        },
        else => return .invalid_type,
    }
}

pub fn docmdSto(arg: ?*const Arg) Err {
    return genericSto(arg.?, 0);
}
pub fn docmdStoDiv(arg: ?*const Arg) Err {
    return genericSto(arg.?, '/');
}
pub fn docmdStoMul(arg: ?*const Arg) Err {
    return genericSto(arg.?, '*');
}
pub fn docmdStoSub(arg: ?*const Arg) Err {
    return genericSto(arg.?, '-');
}
pub fn docmdStoAdd(arg: ?*const Arg) Err {
    return genericSto(arg.?, '+');
}

// ---------------------------------------------------------------------------
// SIZE / DIM — dimension the register file or a named matrix
// ---------------------------------------------------------------------------

/// Create a 1D zero vector of `n` elements.
fn newZeroVector(n: i32) ?*Vartype {
    const v = vartype.newArray(n) orelse return null;
    errdefer vartype.free(v);
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        v.array.data[@intCast(i)] = vartype.newReal(phloat.fromInt(0)) orelse return null;
    }
    return v;
}

/// Create a 2D zero matrix (array of arrays) of rows×columns.
fn newZeroMatrix(rows: i32, columns: i32) ?*Vartype {
    const m = vartype.newArray(rows) orelse return null;
    errdefer vartype.free(m);
    var i: i32 = 0;
    while (i < rows) : (i += 1) {
        const row = vartype.newArray(columns) orelse return null;
        m.array.data[@intCast(i)] = row;
        var j: i32 = 0;
        while (j < columns) : (j += 1) {
            row.array.data[@intCast(j)] = vartype.newReal(phloat.fromInt(0)) orelse return null;
        }
    }
    return m;
}

/// Redimension a 1D vector to `n` elements, preserving the overlapping prefix.
fn redimensionVector(old: *const Vartype, n: i32) ?*Vartype {
    const nv = newZeroVector(n) orelse return null;
    errdefer vartype.free(nv);
    if (old.* == .array) {
        const copy = @min(old.array.data.len, @as(usize, @intCast(n)));
        for (old.array.data[0..copy], 0..) |item, i| {
            if (item) |p| {
                nv.array.data[i] = vartype.dup(p) orelse return null;
            }
        }
    }
    return nv;
}

/// Redimension a 2D matrix to rows×columns, preserving the overlapping region.
fn redimensionMatrix(old: *const Vartype, rows: i32, columns: i32) ?*Vartype {
    const nm = newZeroMatrix(rows, columns) orelse return null;
    errdefer vartype.free(nm);
    if (vartype.matrixInfo(old)) |oi| {
        const cr = @min(oi.rows, rows);
        const cc = @min(oi.columns, columns);
        var i: i32 = 0;
        while (i < cr) : (i += 1) {
            var j: i32 = 0;
            while (j < cc) : (j += 1) {
                const src = old.array.data[@intCast(i)].?.array.data[@intCast(j)].?;
                nm.array.data[@intCast(i)].?.array.data[@intCast(j)] = vartype.dup(src) orelse return null;
            }
        }
    }
    return nm;
}

/// SIZE n — dimension the REGS register file to n elements (0 purges it).
pub fn docmdSize(arg: ?*const Arg) Err {
    if (arg.?.type != .num) return .invalid_type;
    const n = arg.?.num;
    if (n < 0) return .invalid_data;
    if (n == 0) {
        _ = variables.purgeVar("REGS");
        return .none;
    }
    const existing = variables.recallVar("REGS");
    const nv = if (existing) |old|
        redimensionVector(old, n) orelse return .insufficient_memory
    else
        newZeroVector(n) orelse return .insufficient_memory;
    return variables.storeVar("REGS", nv);
}

/// Convert a stack dimension argument to a positive i32, or null if zero or
/// out of range (HP-42S DIM semantics).
fn toDim(p: phloat.Phloat) ?i32 {
    if (phloat.le(p, phloat.fromInt(-2147483648)) or phloat.ge(p, phloat.fromUint(2147483648))) return null;
    var n = phloat.toInt(p);
    if (n == 0) return null;
    if (n < 0) n = -n;
    return n;
}

/// DIM "name" — dimension a named matrix to Y rows × X columns.
pub fn docmdDim(arg: ?*const Arg) Err {
    if (arg.?.type != .str) return .invalid_type;
    const name = arg.?.text[0..arg.?.length];
    const columns = toDim(x().real) orelse return .dimension_error;
    const rows = toDim(y().real) orelse return .dimension_error;
    const existing = variables.recallVar(name);
    const nm = if (existing) |old|
        redimensionMatrix(old, rows, columns) orelse return .insufficient_memory
    else
        newZeroMatrix(rows, columns) orelse return .insufficient_memory;
    return variables.storeVar(name, nm);
}

// ---------------------------------------------------------------------------
// CLV / CLRG — clear variables and registers
// ---------------------------------------------------------------------------

/// CLV "name" — purge a named variable.
pub fn docmdClv(arg: ?*const Arg) Err {
    if (arg.?.type != .str) return .invalid_type;
    const name = arg.?.text[0..arg.?.length];
    _ = variables.purgeVar(name);
    return .none;
}

/// CLRG — zero the REGS register file.
pub fn docmdClrg(arg: ?*const Arg) Err {
    _ = arg;
    const regs = variables.recallVar("REGS") orelse return .nonexistent;
    const a = switch (regs.*) {
        .array => |a| a,
        else => return .internal_error,
    };
    for (a.data) |*slot| {
        vartype.freeOpt(slot.*);
        slot.* = vartype.newReal(phloat.fromInt(0)) orelse return .insufficient_memory;
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectPhloat(expected: f64, p: phloat.Phloat) !void {
    try std.testing.expectApproxEqAbs(expected, phloat.toDouble(p), 1e-20);
}

test "STO/RCL named variable round-trip" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    // 42 STO "M1" → M1 = 42.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("42"));
    try std.testing.expectEqual(Err.none, docmdSto(&commands1.strArg("M1")));
    try std.testing.expectEqualStrings("42", phloat.toString(variables.recallVar("M1").?.real));

    // CLX, then RCL "M1" → X = 42.
    try std.testing.expectEqual(Err.none, commands1.docmdClx(null));
    try std.testing.expectEqual(Err.none, docmdRcl(&commands1.strArg("M1")));
    try std.testing.expectEqualStrings("42", phloat.toString(x().real));

    // RCL of a nonexistent variable → Nonexistent.
    try std.testing.expectEqual(Err.nonexistent, docmdRcl(&commands1.strArg("NOPE")));
}

test "STO arithmetic on a named variable" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    // M1 = 10; then 3 STO+ "M1" → M1 = 13.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("10"));
    try std.testing.expectEqual(Err.none, docmdSto(&commands1.strArg("M1")));
    try std.testing.expectEqual(Err.none, commands1.pushNumber("3"));
    try std.testing.expectEqual(Err.none, docmdStoAdd(&commands1.strArg("M1")));
    try std.testing.expectEqualStrings("13", phloat.toString(variables.recallVar("M1").?.real));

    // 2 STO× "M1" → M1 = 26.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("2"));
    try std.testing.expectEqual(Err.none, docmdStoMul(&commands1.strArg("M1")));
    try std.testing.expectEqualStrings("26", phloat.toString(variables.recallVar("M1").?.real));
}

test "RCL arithmetic" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    // M1 = 5; X = 20; RCL+ "M1" → X = 25.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("5"));
    try std.testing.expectEqual(Err.none, docmdSto(&commands1.strArg("M1")));
    try std.testing.expectEqual(Err.none, commands1.pushNumber("20"));
    try std.testing.expectEqual(Err.none, docmdRclAdd(&commands1.strArg("M1")));
    try std.testing.expectEqualStrings("25", phloat.toString(x().real));
}

test "SIZE and numbered registers" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    // SIZE 10 → REGS is a 10-element vector.
    try std.testing.expectEqual(Err.none, docmdSize(&commands1.numArg(10)));
    const regs = variables.recallVar("REGS") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 10), regs.array.data.len);

    // 7 STO 05 → REGS[5] = 7.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("7"));
    try std.testing.expectEqual(Err.none, docmdSto(&commands1.numArg(5)));
    try std.testing.expectEqualStrings("7", phloat.toString(regs.array.data[5].?.real));

    // CLX, RCL 05 → X = 7.
    try std.testing.expectEqual(Err.none, commands1.docmdClx(null));
    try std.testing.expectEqual(Err.none, docmdRcl(&commands1.numArg(5)));
    try std.testing.expectEqualStrings("7", phloat.toString(x().real));

    // RCL 99 → Size Error (out of range).
    try std.testing.expectEqual(Err.size_error, docmdRcl(&commands1.numArg(99)));
}

test "DIM creates a named matrix" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    // 2 ENTER 3 DIM "M" → M is a 2×3 zero matrix.
    try std.testing.expectEqual(Err.none, commands1.pushNumber("2"));
    try std.testing.expectEqual(Err.none, commands1.docmdEnter(null));
    try std.testing.expectEqual(Err.none, commands1.pushNumber("3"));
    try std.testing.expectEqual(Err.none, docmdDim(&commands1.strArg("M")));
    const m = variables.recallVar("M") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), m.array.data.len);
    try std.testing.expectEqual(@as(usize, 3), m.array.data[0].?.array.data.len);
    try expectPhloat(0, m.array.data[0].?.array.data[0].?.real);
}

test "CLV purges a variable" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();

    try std.testing.expectEqual(Err.none, commands1.pushNumber("1"));
    try std.testing.expectEqual(Err.none, docmdSto(&commands1.strArg("M1")));
    try std.testing.expect(variables.recallVar("M1") != null);
    try std.testing.expectEqual(Err.none, docmdClv(&commands1.strArg("M1")));
    try std.testing.expect(variables.recallVar("M1") == null);
}
