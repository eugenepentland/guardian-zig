const std = @import("std");
const guardian_helper = @import("src/build_helper.zig");

// Re-exported so dependents can `const guardian = @import("guardian");`
// in their own build.zig and call guardian.addAllChecks(...).
pub const addAllChecks = guardian_helper.addAllChecks;
pub const all_check_names = guardian_helper.all_check_names;
pub const Options = guardian_helper.Options;

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

    // Format check
    const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    b.getInstallStep().dependOn(&fmt_check.step);
    test_step.dependOn(&fmt_check.step);

    // Self-hosting: run all hard-block checks on Guardian's own source.
    guardian_helper.addAllChecks(b, check_exe, b.getInstallStep(), .{});
    guardian_helper.addAllChecks(b, check_exe, test_step, .{});

    // spec-init: generate starter SPEC.md (separate step, not a gate)
    const spec_init_run = b.addRunArtifact(check_exe);
    spec_init_run.addArgs(&.{ "spec-init", "." });
    const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
    spec_init_step.dependOn(&spec_init_run.step);
}
