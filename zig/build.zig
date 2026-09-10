const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // array42 — the calculator core (Zig port of Free42's common/).
    // The decimal core is now native Zig (src/phloat.zig); no C dependency.
    const exe = b.addExecutable(.{
        .name = "array42",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run array42");
    run_step.dependOn(&run_cmd.step);

    // array42-mcp — the calculator exposed as an MCP server (stdio JSON-RPC).
    const mcp_exe = b.addExecutable(.{
        .name = "array42-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(mcp_exe);

    const mcp_run_cmd = b.addRunArtifact(mcp_exe);
    mcp_run_cmd.step.dependOn(b.getInstallStep());
    const mcp_run_step = b.step("mcp", "Run the array42 MCP server");
    mcp_run_step.dependOn(&mcp_run_cmd.step);

    // hrmr — the HR/MR compiler (SOURCE/MR/HR doctrine). Generates the
    // comment-stripped MR sources (zig-out/mr/) and the doc-comment HR
    // projection (zig-out/hr/) from src/. It runs on the host during the
    // build, so it must be compiled for the host target, not the cross target.
    const hrmr_exe = b.addExecutable(.{
        .name = "hrmr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/hrmr.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const hrmr_run = b.addRunArtifact(hrmr_exe);
    hrmr_run.addArgs(&.{ "src", "zig-out/mr", "zig-out/hr" });
    const gen_step = b.step("gen", "Generate MR (comment-stripped) + HR (docs) from src/");
    gen_step.dependOn(&hrmr_run.step);

    // mr-build — compile the MCP server from the MR (comment-stripped) sources,
    // the "final runtime shape" per the SOURCE/MR/HR doctrine.
    const mr_mcp = b.addExecutable(.{
        .name = "array42-mcp-mr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig-out/mr/mcp_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mr_mcp.step.dependOn(&hrmr_run.step);
    b.installArtifact(mr_mcp);
    const mr_build_step = b.step("mr-build", "Compile array42-mcp from the MR (comment-stripped) sources");
    mr_build_step.dependOn(b.getInstallStep());

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
