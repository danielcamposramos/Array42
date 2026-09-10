//! array42 — RPN calculator core demo.
//!
//! Exercises the step-2 vertical slice: a real 4-level RPN stack with number
//! entry, ENTER, the four arithmetic operators, and the basic unary functions,
//! all on top of the decNumber-backed phloat seam.

const std = @import("std");
const phloat = @import("phloat.zig");
const vartype = @import("vartype.zig");
const globals = @import("globals.zig");
const helpers = @import("helpers.zig");
const display = @import("display.zig");
const commands1 = @import("commands1.zig");

const Err = globals.Err;

fn printStack() void {
    const labels = [_][]const u8{ "T", "Z", "Y", "X" };
    for (labels, 0..) |label, i| {
        const slot = globals.stack[i];
        if (slot) |v| {
            std.debug.print("  {s}: {s}\n", .{ label, display.formatVartype(v) });
        }
    }
    std.debug.print("\n", .{});
}

fn step(desc: []const u8) void {
    std.debug.print("-- {s}\n", .{desc});
    printStack();
}

pub fn main() !void {
    globals.init();
    defer {
        for (globals.stack) |s| vartype.freeOpt(s);
        std.heap.c_allocator.free(globals.stack);
        vartype.freeOpt(globals.lastx);
    }

    std.debug.print("array42 — RPN core (step 2 vertical slice)\n\n", .{});

    // The canonical Free42 smoke test: 1 ENTER 2 + → 3.
    _ = commands1.pushNumber("1");
    _ = commands1.docmdEnter(null);
    _ = commands1.pushNumber("2");
    _ = commands1.docmdAdd(null);
    step("1 ENTER 2 +");

    // Exact decimal arithmetic.
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("0.1");
    _ = commands1.docmdEnter(null);
    _ = commands1.pushNumber("0.2");
    _ = commands1.docmdAdd(null);
    step("0.1 ENTER 0.2 +  (exact decimal)");

    // Division: 1 ENTER 3 ÷.
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("1");
    _ = commands1.docmdEnter(null);
    _ = commands1.pushNumber("3");
    _ = commands1.docmdDiv(null);
    step("1 ENTER 3 ÷");

    // π, then CHS, ABS, SIGN.
    _ = commands1.docmdClst(null);
    _ = commands1.docmdPi(null);
    step("π");
    _ = commands1.docmdChs(null);
    step("CHS");
    _ = commands1.docmdAbs(null);
    step("ABS");
    _ = commands1.docmdSign(null);
    step("SIGN");

    // MOD: 7 ENTER 3 MOD → 1.
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("7");
    _ = commands1.docmdEnter(null);
    _ = commands1.pushNumber("3");
    _ = commands1.docmdMod(null);
    step("7 ENTER 3 MOD");

    // IP and FP.
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("-3.7");
    _ = commands1.docmdIp(null);
    step("IP(-3.7)");
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("-3.7");
    _ = commands1.docmdFp(null);
    step("FP(-3.7)");

    // Complex: 1 ENTER 2 COMPLEX → (1,2).
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("1");
    _ = commands1.docmdEnter(null);
    _ = commands1.pushNumber("2");
    _ = commands1.docmdComplex(null);
    step("1 ENTER 2 COMPLEX");

    // Display modes: FIX 2, SCI 3, ENG 2, ALL.
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("3.14159265358979");
    _ = commands1.docmdFix(&.{ .num = 2 });
    step("FIX 2");
    _ = commands1.docmdSci(&.{ .num = 3 });
    step("SCI 3");
    _ = commands1.docmdEng(&.{ .num = 2 });
    step("ENG 2");
    _ = commands1.docmdAll(null);
    step("ALL");

    // Angle conversions: 180 →RAD, then →DEG.
    _ = commands1.docmdClst(null);
    _ = commands1.pushNumber("180");
    _ = commands1.docmdToRad(null);
    step("180 →RAD");
    _ = commands1.docmdToDeg(null);
    step("→DEG");

    std.debug.print("done.\n", .{});
}
