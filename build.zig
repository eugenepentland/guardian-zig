const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Guardian executable — exported as a named artifact for dependent projects
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "guardian",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step (standalone usage)
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run guardian");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Self-check: guardian verifies itself
    // Uses the -Dintent option for the commit message
    const intent = b.option([]const u8, "intent", "Guardian intent message (required for guardian step)");

    const self_check = b.addRunArtifact(exe);
    self_check.addArgs(&.{ "check", "--intent", intent orelse "self-check" });
    self_check.step.dependOn(&run_unit_tests.step);
    self_check.step.dependOn(b.getInstallStep());

    const guardian_step = b.step("guardian", "Run guardian self-verification");
    guardian_step.dependOn(&self_check.step);
}

/// Helper for dependent projects to add a guardian step to their build.
/// Call this from your build.zig:
///
///   const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
///   @import("guardian").addGuardianStep(b, guardian_dep, .{
///       .test_step = &run_tests.step,
///       .compile_step = b.getInstallStep(),
///       .source_paths = &.{"src"},
///   });
///
/// Then run: zig build guardian -Dintent="description"
pub fn addGuardianStep(
    b: *std.Build,
    guardian_dep: *std.Build.Dependency,
    options: GuardianStepOptions,
) void {
    const intent = b.option([]const u8, "intent", "Guardian intent message (required for guardian step)");

    // Format check step
    const fmt_check = b.addFmt(.{
        .paths = options.source_paths,
        .check = true,
    });

    // Run guardian analysis (spec coverage, file size, boundaries, change classification, mutation, git)
    const guardian_run = b.addRunArtifact(guardian_dep.artifact("guardian"));
    guardian_run.addArgs(&.{
        "check",
        "--intent",
        intent orelse "(no intent provided)",
        "--build-verified",
    });
    guardian_run.setCwd(b.path("."));

    // Guardian runs after compile + test + fmt all succeed
    if (options.compile_step) |cs| guardian_run.step.dependOn(cs);
    if (options.test_step) |ts| guardian_run.step.dependOn(ts);
    guardian_run.step.dependOn(&fmt_check.step);

    const guardian_step = b.step("guardian", "Run guardian verification pipeline");
    guardian_step.dependOn(&guardian_run.step);
}

pub const GuardianStepOptions = struct {
    /// The project's test step (e.g., &run_tests.step)
    test_step: ?*std.Build.Step = null,
    /// The project's compile/install step (e.g., b.getInstallStep())
    compile_step: ?*std.Build.Step = null,
    /// Paths to check formatting on (e.g., &.{"src"})
    source_paths: []const []const u8 = &.{"src"},
};
