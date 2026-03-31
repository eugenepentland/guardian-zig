const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Guardian check executable — used by dependent projects
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/check.zig"),
        .target = target,
        .optimize = optimize,
    });
    const check_exe = b.addExecutable(.{
        .name = "guardian-check",
        .root_module = check_mod,
    });
    b.installArtifact(check_exe);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/check.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Self-guardian: verify this project with its own steps
    const self_guardian = b.step("guardian", "Run guardian self-verification");

    const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    self_guardian.dependOn(&fmt_check.step);
    self_guardian.dependOn(&run_tests.step);
    self_guardian.dependOn(b.getInstallStep());

    // Spec coverage on self
    const spec_run = b.addRunArtifact(check_exe);
    spec_run.addArgs(&.{ "spec", "." });
    spec_run.step.dependOn(b.getInstallStep());
    self_guardian.dependOn(&spec_run.step);

    // File size on self
    const size_run = b.addRunArtifact(check_exe);
    size_run.addArgs(&.{ "file-size", "." });
    size_run.step.dependOn(b.getInstallStep());
    self_guardian.dependOn(&size_run.step);

    // Boundaries on self
    const boundary_run = b.addRunArtifact(check_exe);
    boundary_run.addArgs(&.{ "boundaries", "." });
    boundary_run.step.dependOn(b.getInstallStep());
    self_guardian.dependOn(&boundary_run.step);
}
