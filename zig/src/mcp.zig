//! mcp — Model Context Protocol server exposing Array42 as a calculator tool.
//!
//! This is the Step 6 deliverable: the "shell" seam from Free42's architecture,
//! realized as a JSON-RPC 2.0 server over stdio. An AI partner (Claude Code,
//! or any MCP client) connects to this process and calls the calculator as a
//! set of tools:
//!
//!   eval(expression)   — evaluate an algebraic expression (Equation Writer)
//!   stack()            — read the current RPN stack
//!   store(name, expr)  — evaluate + store under a name (addressable array)
//!   recall(name)       — recall a named variable
//!   vars()             — list all named variables
//!   clear()            — clear the stack (CLST)
//!   mode(angle)        — set the angle mode (deg/rad/grad)
//!
//! The server is a *calculator*, not a tutor: it evaluates and returns exact
//! decimal results. It does not explain, derive, or show steps — that is
//! knowledge work for the AI and human to do on top of the answers.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const helpers = @import("helpers.zig");
const commands1 = @import("commands1.zig");
const variables = @import("variables.zig");
const equation = @import("equation.zig");

const alloc = std.heap.c_allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

const SERVER_NAME = "array42";
const SERVER_VERSION = "0.1.0";
const PROTOCOL_VERSION = "2024-11-05";

// ---------------------------------------------------------------------------
// Value formatting (exact decimal, not display-rounded)
// ---------------------------------------------------------------------------

/// Format a vartype into `out` at full precision. Arrays nest recursively;
/// complex values use the `re+imi` convention.
fn formatValue(v: *const vartype.Vartype, out: *std.ArrayList(u8), a: std.mem.Allocator) void {
    switch (v.*) {
        .real => |r| out.appendSlice(a, phloat.toString(r)) catch {},
        .complex => |c| {
            out.appendSlice(a, phloat.toString(c.re)) catch {};
            if (phloat.isNegative(c.im)) {
                out.appendSlice(a, phloat.toString(c.im)) catch {};
            } else {
                out.append(a, '+') catch {};
                out.appendSlice(a, phloat.toString(c.im)) catch {};
            }
            out.append(a, 'i') catch {};
        },
        .string => |s| {
            out.append(a, '"') catch {};
            out.appendSlice(a, s.text) catch {};
            out.append(a, '"') catch {};
        },
        .array => |arr| {
            out.append(a, '[') catch {};
            for (arr.data, 0..) |item, i| {
                if (i > 0) out.appendSlice(a, ", ") catch {};
                if (item) |p| formatValue(p, out, a) else out.appendSlice(a, "null") catch {};
            }
            out.append(a, ']') catch {};
        },
        .empty => out.appendSlice(a, "<empty>") catch {},
    }
}

/// Format a vartype to an owned string (arena-allocated).
fn formatValueString(v: *const vartype.Vartype, a: std.mem.Allocator) []u8 {
    var out = std.ArrayList(u8).empty;
    formatValue(v, &out, a);
    return out.toOwnedSlice(a) catch &.{};
}

/// Format the current stack as a multi-line string, X first.
fn formatStack(a: std.mem.Allocator) []u8 {
    var out = std.ArrayList(u8).empty;
    if (globals.flags.big_stack) {
        var i: i32 = globals.sp;
        while (i >= 0) : (i -= 1) {
            const idx: usize = @intCast(i);
            const label = if (i == globals.sp)
                "X"
            else
                std.fmt.allocPrint(a, "S{d}", .{i}) catch "?";
            out.appendSlice(a, label) catch {};
            out.appendSlice(a, ": ") catch {};
            if (globals.stack[idx]) |v| formatValue(v, &out, a) else out.appendSlice(a, "<empty>") catch {};
            out.append(a, '\n') catch {};
        }
    } else {
        const labels = [_][]const u8{ "T", "Z", "Y", "X" };
        for (labels, 0..) |label, i| {
            out.appendSlice(a, label) catch {};
            out.appendSlice(a, ": ") catch {};
            if (globals.stack[i]) |v| formatValue(v, &out, a) else out.appendSlice(a, "<empty>") catch {};
            out.append(a, '\n') catch {};
        }
    }
    return out.toOwnedSlice(a) catch &.{};
}

// ---------------------------------------------------------------------------
// Tool results
// ---------------------------------------------------------------------------

const ToolResult = struct {
    text: []const u8,
    is_error: bool,
};

fn ok(text: []const u8) ToolResult {
    return .{ .text = text, .is_error = false };
}

fn err(text: []const u8) ToolResult {
    return .{ .text = text, .is_error = true };
}

/// Extract a string field from a JSON object (the tool `arguments`).
fn getString(args: Value, key: []const u8) ?[]const u8 {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tool implementations
// ---------------------------------------------------------------------------

fn toolEval(args: Value, a: std.mem.Allocator) ToolResult {
    const expr = getString(args, "expression") orelse return err("missing 'expression'");
    const e = equation.evalEquation(expr);
    if (e != .none) return err(globals.errText(e));
    const x = globals.stack[helpers.xIndex()] orelse return err("empty stack");
    return ok(formatValueString(x, a));
}

fn toolStack(args: Value, a: std.mem.Allocator) ToolResult {
    _ = args;
    return ok(formatStack(a));
}

fn toolStore(args: Value, a: std.mem.Allocator) ToolResult {
    const name = getString(args, "name") orelse return err("missing 'name'");
    const expr = getString(args, "expression") orelse return err("missing 'expression'");
    const e = equation.evalEquation(expr);
    if (e != .none) return err(globals.errText(e));
    const x = globals.stack[helpers.xIndex()] orelse return err("empty stack");
    const copy = vartype.dup(x) orelse return err("insufficient memory");
    const se = variables.storeVar(name, copy);
    if (se != .none) {
        vartype.free(copy);
        return err(globals.errText(se));
    }
    const handle = variables.handleOf(name) orelse 0;
    return ok(std.fmt.allocPrint(a, "stored {s} (handle {d}) = {s}", .{
        name, handle, formatValueString(x, a),
    }) catch "stored");
}

fn toolRecall(args: Value, a: std.mem.Allocator) ToolResult {
    const name = getString(args, "name") orelse return err("missing 'name'");
    const v = variables.recallVar(name) orelse return err("Nonexistent");
    const handle = variables.handleOf(name) orelse 0;
    return ok(std.fmt.allocPrint(a, "{s} (handle {d}) = {s}", .{
        name, handle, formatValueString(v, a),
    }) catch "recalled");
}

fn toolVars(args: Value, a: std.mem.Allocator) ToolResult {
    _ = args;
    var out = std.ArrayList(u8).empty;
    var any = false;
    for (variables.vars[0..variables.vars_count]) |*v| {
        if (v.flags.hidden or v.flags.private) continue;
        any = true;
        out.appendSlice(a, v.name[0..v.length]) catch {};
        out.appendSlice(a, " (handle ") catch {};
        out.appendSlice(a, std.fmt.allocPrint(a, "{d}", .{v.handle}) catch "?") catch {};
        out.appendSlice(a, ") = ") catch {};
        if (v.value) |val| formatValue(val, &out, a) else out.appendSlice(a, "<empty>") catch {};
        out.append(a, '\n') catch {};
    }
    if (!any) return ok("no variables");
    return ok(out.toOwnedSlice(a) catch "no variables");
}

fn toolClear(args: Value, a: std.mem.Allocator) ToolResult {
    _ = args;
    _ = a;
    _ = commands1.docmdClst(null);
    return ok("stack cleared");
}

fn toolMode(args: Value, a: std.mem.Allocator) ToolResult {
    const angle = getString(args, "angle") orelse return err("missing 'angle'");
    if (std.mem.eql(u8, angle, "deg")) {
        _ = commands1.docmdDeg(null);
    } else if (std.mem.eql(u8, angle, "rad")) {
        _ = commands1.docmdRad(null);
    } else if (std.mem.eql(u8, angle, "grad")) {
        _ = commands1.docmdGrad(null);
    } else {
        return err("angle must be 'deg', 'rad', or 'grad'");
    }
    return ok(std.fmt.allocPrint(a, "angle mode: {s}", .{angle}) catch "mode set");
}

fn dispatchTool(name: []const u8, args: Value, a: std.mem.Allocator) ToolResult {
    if (std.mem.eql(u8, name, "eval")) return toolEval(args, a);
    if (std.mem.eql(u8, name, "stack")) return toolStack(args, a);
    if (std.mem.eql(u8, name, "store")) return toolStore(args, a);
    if (std.mem.eql(u8, name, "recall")) return toolRecall(args, a);
    if (std.mem.eql(u8, name, "vars")) return toolVars(args, a);
    if (std.mem.eql(u8, name, "clear")) return toolClear(args, a);
    if (std.mem.eql(u8, name, "mode")) return toolMode(args, a);
    return err("unknown tool");
}

// ---------------------------------------------------------------------------
// JSON-RPC response building
// ---------------------------------------------------------------------------

fn jsonString(s: []const u8) Value {
    return .{ .string = s };
}

fn jsonBool(b: bool) Value {
    return .{ .bool = b };
}

fn jsonInt(i: i64) Value {
    return .{ .integer = i };
}

/// Build a `{ name, description, inputSchema }` tool descriptor.
fn toolDescriptor(name: []const u8, description: []const u8, schema: Value, a: std.mem.Allocator) Value {
    var obj = ObjectMap.empty;
    obj.put(a, "name", jsonString(name)) catch {};
    obj.put(a, "description", jsonString(description)) catch {};
    obj.put(a, "inputSchema", schema) catch {};
    return .{ .object = obj };
}

/// A JSON Schema object with a single required string property.
fn stringSchema(prop: []const u8, a: std.mem.Allocator) Value {
    var props = ObjectMap.empty;
    props.put(a, prop, .{ .object = blk: {
        var o = ObjectMap.empty;
        o.put(a, "type", jsonString("string")) catch {};
        break :blk o;
    } }) catch {};
    var required = std.json.Array.init(a);
    required.append(jsonString(prop)) catch {};
    var obj = ObjectMap.empty;
    obj.put(a, "type", jsonString("object")) catch {};
    obj.put(a, "properties", .{ .object = props }) catch {};
    obj.put(a, "required", .{ .array = required }) catch {};
    return .{ .object = obj };
}

/// A JSON Schema object with no properties.
fn emptySchema(a: std.mem.Allocator) Value {
    var obj = ObjectMap.empty;
    obj.put(a, "type", jsonString("object")) catch {};
    obj.put(a, "properties", .{ .object = ObjectMap.empty }) catch {};
    return .{ .object = obj };
}

/// The `tools/list` result: an array of tool descriptors.
fn toolsList(a: std.mem.Allocator) Value {
    var arr = std.json.Array.init(a);

    arr.append(toolDescriptor("eval",
        "Evaluate an algebraic expression and return the exact-decimal result. " ++
            "Supports + - * / ^ !, functions (sin cos tan asin acos atan sinh cosh tanh " ++
            "asinh acosh atanh ln log exp sqrt sq abs sign ip fp fact deg rad), " ++
            "matrix ops (det trans inv), operators (mod dot cross), array literals " ++
            "[...], and named variables. Example: det(inv(A) * B).",
        stringSchema("expression", a), a)) catch {};

    arr.append(toolDescriptor("stack",
        "Read the current RPN stack (X first, then Y, Z, T).",
        emptySchema(a), a)) catch {};

    arr.append(toolDescriptor("store",
        "Evaluate an expression and store the result under a name (an addressable " ++
            "array/variable). Returns the stable handle. Example: store('M1', '[[1,2],[3,4]]').",
        blk: {
            var props = ObjectMap.empty;
            props.put(a, "name", .{ .object = blk2: {
                var o = ObjectMap.empty;
                o.put(a, "type", jsonString("string")) catch {};
                break :blk2 o;
            } }) catch {};
            props.put(a, "expression", .{ .object = blk3: {
                var o = ObjectMap.empty;
                o.put(a, "type", jsonString("string")) catch {};
                break :blk3 o;
            } }) catch {};
            var required = std.json.Array.init(a);
            required.append(jsonString("name")) catch {};
            required.append(jsonString("expression")) catch {};
            var obj = ObjectMap.empty;
            obj.put(a, "type", jsonString("object")) catch {};
            obj.put(a, "properties", .{ .object = props }) catch {};
            obj.put(a, "required", .{ .array = required }) catch {};
            break :blk .{ .object = obj };
        }, a)) catch {};

    arr.append(toolDescriptor("recall",
        "Recall a named variable by name. Returns its value and stable handle.",
        stringSchema("name", a), a)) catch {};

    arr.append(toolDescriptor("vars",
        "List all named variables with their handles and values.",
        emptySchema(a), a)) catch {};

    arr.append(toolDescriptor("clear",
        "Clear the RPN stack (CLST). Named variables are preserved.",
        emptySchema(a), a)) catch {};

    arr.append(toolDescriptor("mode",
        "Set the angle mode for trigonometric functions: 'deg', 'rad', or 'grad'.",
        blk: {
            var props = ObjectMap.empty;
            var enum_arr = std.json.Array.init(a);
            enum_arr.append(jsonString("deg")) catch {};
            enum_arr.append(jsonString("rad")) catch {};
            enum_arr.append(jsonString("grad")) catch {};
            var angle = ObjectMap.empty;
            angle.put(a, "type", jsonString("string")) catch {};
            angle.put(a, "enum", .{ .array = enum_arr }) catch {};
            props.put(a, "angle", .{ .object = angle }) catch {};
            var required = std.json.Array.init(a);
            required.append(jsonString("angle")) catch {};
            var obj = ObjectMap.empty;
            obj.put(a, "type", jsonString("object")) catch {};
            obj.put(a, "properties", .{ .object = props }) catch {};
            obj.put(a, "required", .{ .array = required }) catch {};
            break :blk .{ .object = obj };
        }, a)) catch {};

    return .{ .array = arr };
}

/// The `initialize` result.
fn initResult(a: std.mem.Allocator) Value {
    var capabilities = ObjectMap.empty;
    capabilities.put(a, "tools", .{ .object = ObjectMap.empty }) catch {};

    var server_info = ObjectMap.empty;
    server_info.put(a, "name", jsonString(SERVER_NAME)) catch {};
    server_info.put(a, "version", jsonString(SERVER_VERSION)) catch {};

    var obj = ObjectMap.empty;
    obj.put(a, "protocolVersion", jsonString(PROTOCOL_VERSION)) catch {};
    obj.put(a, "capabilities", .{ .object = capabilities }) catch {};
    obj.put(a, "serverInfo", .{ .object = server_info }) catch {};
    return .{ .object = obj };
}

/// The `tools/call` result: `{ content: [{type:"text",text}], isError }`.
fn callResult(tr: ToolResult, a: std.mem.Allocator) Value {
    var item = ObjectMap.empty;
    item.put(a, "type", jsonString("text")) catch {};
    item.put(a, "text", jsonString(tr.text)) catch {};
    var content = std.json.Array.init(a);
    content.append(.{ .object = item }) catch {};

    var obj = ObjectMap.empty;
    obj.put(a, "content", .{ .array = content }) catch {};
    obj.put(a, "isError", jsonBool(tr.is_error)) catch {};
    return .{ .object = obj };
}

/// Build a JSON-RPC success response string, or null for a notification.
fn respond(id: ?Value, result: Value, a: std.mem.Allocator) ?[]u8 {
    const idv = id orelse return null;
    var obj = ObjectMap.empty;
    obj.put(a, "jsonrpc", jsonString("2.0")) catch {};
    obj.put(a, "id", idv) catch {};
    obj.put(a, "result", result) catch {};
    return std.json.Stringify.valueAlloc(a, Value{ .object = obj }, .{}) catch null;
}

/// Build a JSON-RPC error response string, or null for a notification.
fn respondError(id: ?Value, code: i64, message: []const u8, a: std.mem.Allocator) ?[]u8 {
    const idv = id orelse return null;
    var err_obj = ObjectMap.empty;
    err_obj.put(a, "code", jsonInt(code)) catch {};
    err_obj.put(a, "message", jsonString(message)) catch {};
    var obj = ObjectMap.empty;
    obj.put(a, "jsonrpc", jsonString("2.0")) catch {};
    obj.put(a, "id", idv) catch {};
    obj.put(a, "error", .{ .object = err_obj }) catch {};
    return std.json.Stringify.valueAlloc(a, Value{ .object = obj }, .{}) catch null;
}

// ---------------------------------------------------------------------------
// Message dispatch
// ---------------------------------------------------------------------------

/// Handle one parsed JSON-RPC message. Returns the response string to write
/// (null for notifications / no response).
fn handleMessage(root: Value, a: std.mem.Allocator) ?[]u8 {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const method = switch (obj.get("method") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const id = obj.get("id");

    if (std.mem.eql(u8, method, "initialize")) {
        return respond(id, initResult(a), a);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        return null;
    } else if (std.mem.eql(u8, method, "ping")) {
        return respond(id, .{ .object = ObjectMap.empty }, a);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return respond(id, toolsList(a), a);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = obj.get("params") orelse
            return respondError(id, -32602, "missing params", a);
        const name = getString(params, "name") orelse
            return respondError(id, -32602, "missing tool name", a);
        const args = switch (params) {
            .object => |o| o.get("arguments") orelse .null,
            else => .null,
        };
        const tr = dispatchTool(name, args, a);
        return respond(id, callResult(tr, a), a);
    } else {
        return respondError(id, -32601, "method not found", a);
    }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

/// Run the MCP server: read newline-delimited JSON-RPC from stdin, write
/// responses to stdout, until stdin closes.
pub fn run() !void {
    const io = std.Options.debug_io;
    var in_buf: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &in_buf);
    var out_buf: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &out_buf);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        const line_copy = a.dupe(u8, line) catch continue;
        const parsed = std.json.parseFromSlice(Value, a, line_copy, .{}) catch continue;
        defer parsed.deinit();

        if (handleMessage(parsed.value, a)) |response| {
            writer.interface.writeAll(response) catch {};
            writer.interface.writeByte('\n') catch {};
            writer.interface.flush() catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formatValueString formats real, complex, and array" {
    phloat.init();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const r = vartype.newReal(phloat.fromString("3.14")) orelse return error.OOM;
    defer vartype.free(r);
    try std.testing.expectEqualStrings("3.14", formatValueString(r, a));

    const c = vartype.newComplex(phloat.fromInt(1), phloat.fromInt(-2)) orelse return error.OOM;
    defer vartype.free(c);
    try std.testing.expectEqualStrings("1-2i", formatValueString(c, a));

    const m = vartype.newArray(2) orelse return error.OOM;
    defer vartype.free(m);
    const row0 = vartype.newArray(2) orelse return error.OOM;
    const row1 = vartype.newArray(2) orelse return error.OOM;
    m.array.data[0] = row0;
    m.array.data[1] = row1;
    row0.array.data[0] = vartype.newReal(phloat.fromInt(1)) orelse return error.OOM;
    row0.array.data[1] = vartype.newReal(phloat.fromInt(2)) orelse return error.OOM;
    row1.array.data[0] = vartype.newReal(phloat.fromInt(3)) orelse return error.OOM;
    row1.array.data[1] = vartype.newReal(phloat.fromInt(4)) orelse return error.OOM;
    try std.testing.expectEqualStrings("[[1, 2], [3, 4]]", formatValueString(m, a));
}

test "toolEval evaluates an expression onto the stack" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const args = blk: {
        var o = ObjectMap.empty;
        o.put(a, "expression", jsonString("1 + 2 * 3")) catch {};
        break :blk Value{ .object = o };
    };
    const tr = toolEval(args, a);
    try std.testing.expect(!tr.is_error);
    try std.testing.expectEqualStrings("7", tr.text);
}

test "toolStore and toolRecall round-trip an addressable array" {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const store_args = blk: {
        var o = ObjectMap.empty;
        o.put(a, "name", jsonString("M1")) catch {};
        o.put(a, "expression", jsonString("[[1,2],[3,4]]")) catch {};
        break :blk Value{ .object = o };
    };
    const st = toolStore(store_args, a);
    try std.testing.expect(!st.is_error);

    const recall_args = blk: {
        var o = ObjectMap.empty;
        o.put(a, "name", jsonString("M1")) catch {};
        break :blk Value{ .object = o };
    };
    const rt = toolRecall(recall_args, a);
    try std.testing.expect(!rt.is_error);
    try std.testing.expect(std.mem.indexOf(u8, rt.text, "[[1, 2], [3, 4]]") != null);
}
