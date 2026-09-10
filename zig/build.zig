const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // decNumber — the decimal arithmetic core (vendored C, ICU license).
    // decQuad.c textually includes decCommon.c + decBasic.c; decimal64.c is
    // pulled in for the shared tables decNumber/decimal128 need.
    const decnumber = b.addLibrary(.{
        .name = "decnumber",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    decnumber.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/decNumber/decQuad.c",
            "vendor/decNumber/decContext.c",
            "vendor/decNumber/decNumber.c",
            "vendor/decNumber/decimal128.c",
            "vendor/decNumber/decimal64.c",
        },
        .flags = &.{"-std=c99"},
    });
    decnumber.root_module.addIncludePath(b.path("vendor/decNumber"));

    // array42 — the calculator core (Zig port of Free42's common/).
    const exe = b.addExecutable(.{
        .name = "array42",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addIncludePath(b.path("vendor/decNumber"));
    exe.root_module.linkLibrary(decnumber);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run array42");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addIncludePath(b.path("vendor/decNumber"));
    unit_tests.root_module.linkLibrary(decnumber);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
