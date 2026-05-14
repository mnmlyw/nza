const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("SDL2", .{});

    const exe = b.addExecutable(.{
        .name = "nza",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run nza");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // -Dintegration adds the ROM-driven harness in tests/integration.zig.
    // Stays opt-in so the default `zig build test` cycle stays fast.
    const integration = b.option(bool, "integration", "Run ROM-driven integration tests") orelse false;
    if (integration) {
        // The harness lives outside src/, so it can't directly @import
        // files there. Expose Core via a named module so tests/ can pull
        // it in as `@import("nza")`.
        const nza_mod = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const integration_mod = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        integration_mod.addImport("nza", nza_mod);
        const integration_tests = b.addTest(.{ .root_module = integration_mod });
        const run_integration = b.addRunArtifact(integration_tests);
        // Tests run from a build-cache scratch dir; pass the ROM dir
        // as an absolute path so the harness can find them.
        run_integration.setEnvironmentVariable("NZA_ROM_DIR", b.path("tests/roms").getPath3(b, null).toStringZ(b.allocator) catch unreachable);
        test_step.dependOn(&run_integration.step);
    }
}
