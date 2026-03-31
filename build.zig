const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Guardian check executable — used by this project and dependents
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

    // Guardian checks run on every build and test (self-hosting)
    // Format check
    const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    b.getInstallStep().dependOn(&fmt_check.step);

    // Spec coverage
    const spec_run = b.addRunArtifact(check_exe);
    spec_run.addArgs(&.{ "spec", "." });
    b.getInstallStep().dependOn(&spec_run.step);

    // File size
    const size_run = b.addRunArtifact(check_exe);
    size_run.addArgs(&.{ "file-size", "." });
    b.getInstallStep().dependOn(&size_run.step);

    // Boundaries
    const boundary_run = b.addRunArtifact(check_exe);
    boundary_run.addArgs(&.{ "boundaries", "." });
    b.getInstallStep().dependOn(&boundary_run.step);

    // Test step also gates on guardian checks
    test_step.dependOn(&fmt_check.step);
    test_step.dependOn(&spec_run.step);
    test_step.dependOn(&size_run.step);
    test_step.dependOn(&boundary_run.step);

    // spec-init: generate starter SPEC.md
    const spec_init_run = b.addRunArtifact(check_exe);
    spec_init_run.addArgs(&.{ "spec-init", "." });
    const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
    spec_init_step.dependOn(&spec_init_run.step);

    // spec-suggest: find pub fns not covered in SPEC.md
    const spec_suggest_run = b.addRunArtifact(check_exe);
    spec_suggest_run.addArgs(&.{ "spec-suggest", "." });
    const spec_suggest_step = b.step("spec-suggest", "Suggest SPEC.md additions for uncovered pub fns");
    spec_suggest_step.dependOn(&spec_suggest_run.step);
}
