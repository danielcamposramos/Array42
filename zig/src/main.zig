//! array42 — minimal vertical slice.
//!
//! Proves the phloat + decNumber foundation: parse, add, and format, the way
//! the eventual RPN core will. The full shell (display, keyboard, MCP) comes
//! in later steps.

const std = @import("std");
const phloat = @import("phloat.zig");

pub fn main() !void {
    phloat.init();

    // The canonical Free42 smoke test: 1 ENTER 2 + → 3.
    const a = phloat.fromString("1");
    const b = phloat.fromString("2");
    const sum = phloat.add(a, b);
    std.debug.print("1 ENTER 2 +  =>  {s}\n", .{phloat.toString(sum)});

    // A few more probes of the decimal core.
    std.debug.print("0.1 + 0.2    =>  {s}\n", .{phloat.toString(phloat.add(phloat.fromString("0.1"), phloat.fromString("0.2")))});
    std.debug.print("1 / 3        =>  {s}\n", .{phloat.toString(phloat.div(phloat.fromString("1"), phloat.fromString("3")))});
    std.debug.print("2 * 3        =>  {s}\n", .{phloat.toString(phloat.mul(phloat.fromString("2"), phloat.fromString("3")))});
    std.debug.print("7 - 10       =>  {s}\n", .{phloat.toString(phloat.sub(phloat.fromString("7"), phloat.fromString("10")))});
    std.debug.print("pi           =>  {s}\n", .{phloat.toString(phloat.PI)});
}
