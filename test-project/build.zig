const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "test-project",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Guardian
    const guardian_dep = b.dependency("guardian", .{
        .target = target,
        .optimize = optimize,
    });
    const check_exe = guardian_dep.artifact("guardian-check");

    const guardian_step = b.step("guardian", "Run guardian verification pipeline");
    guardian_step.dependOn(b.getInstallStep());
    guardian_step.dependOn(&run_tests.step);
    guardian_step.dependOn(&b.addFmt(.{ .paths = &.{"src"}, .check = true }).step);

    for ([_][]const u8{ "spec", "file-size", "boundaries" }) |cmd| {
        const run = b.addRunArtifact(check_exe);
        run.addArgs(&.{ cmd, "." });
        run.setCwd(b.path("."));
        guardian_step.dependOn(&run.step);
    }
}
