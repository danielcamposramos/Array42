//! Test root — imports every module so `zig build test` runs all unit tests.

comptime {
    _ = @import("phloat.zig");
    _ = @import("vartype.zig");
    _ = @import("globals.zig");
    _ = @import("helpers.zig");
    _ = @import("display.zig");
    _ = @import("commands1.zig");
    _ = @import("commands2.zig");
    _ = @import("commands3.zig");
    _ = @import("commands4.zig");
    _ = @import("variables.zig");
    _ = @import("linalg.zig");
}
