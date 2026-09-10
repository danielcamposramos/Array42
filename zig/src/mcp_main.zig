//! array42-mcp — the Array42 calculator exposed as an MCP server.
//!
//! Entry point for the Step 6 deliverable. Initializes the calculator core and
//! runs the JSON-RPC-over-stdio loop in `mcp.zig`.

const std = @import("std");
const globals = @import("globals.zig");
const variables = @import("variables.zig");
const mcp = @import("mcp.zig");

pub fn main() !void {
    globals.init();
    defer globals.deinit();
    defer variables.deinit();
    try mcp.run();
}
