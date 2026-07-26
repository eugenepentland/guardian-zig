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

    // The INSTALLED guardian-check defaults to ReleaseSafe even when no
    // -Doptimize is given. This binary runs a 67-check gate over whole
    // consumer trees on every agent commit, and a Debug build of it turns
    // that gate from ~1.1 s into ~42 s (measured on eda's 234-file tree,
    // 2026-07-26) — a 40x tax silently paid per commit whenever someone
    // refreshes zig-out with a plain `zig build`. An explicit -Doptimize
    // still wins (dependents like eda pass ReleaseSafe already; a debugger
    // session can ask for -Doptimize=Debug). Tests keep the plain default
    // below so the local dev loop keeps its fast compile.
    const exe_optimize: std.builtin.OptimizeMode =
        if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;

    // Guardian check executable — used by this project and dependents
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/check.zig"),
        .target = target,
        .optimize = exe_optimize,
    });
    const check_exe = b.addExecutable(.{
        .name = "guardian-check",
        .root_module = check_mod,
    });
    b.installArtifact(check_exe);

    // Deterministic fakes: a standalone, dependency-free module consumers
    // import in their TESTS to put behind the ports the ban-* checks force
    // (Clock/Random/Fs/Env). Exposed as a named module so a dependent does
    // `guardian_dep.module("guardian-fakes")` — see README's fakes section.
    _ = b.addModule("guardian-fakes", .{
        .root_source_file = b.path("src/fakes/fakes.zig"),
    });

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/check.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Select one fuzz test by name for `zig build test --fuzz`",
    );
    const test_filters: []const []const u8 = if (fuzz_filter) |filter| filters: {
        const one = b.allocator.alloc([]const u8, 1) catch @panic("out of memory");
        one[0] = filter;
        break :filters one;
    } else &.{};
    const unit_tests = b.addTest(.{ .root_module = test_mod, .filters = test_filters });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Format check
    const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    b.getInstallStep().dependOn(&fmt_check.step);
    test_step.dependOn(&fmt_check.step);

    // Self-hosting: run all hard-block checks on Guardian's own source.
    // addAllChecks also registers the top-level `mutate` / `mutate-full`
    // steps (opts.mutate_steps defaults true); the registration is idempotent,
    // so the second call below (and any consumer's hand-rolled step) is safe.
    guardian_helper.addAllChecks(b, check_exe, b.getInstallStep(), .{});
    guardian_helper.addAllChecks(b, check_exe, test_step, .{});

    // spec-init: generate starter SPEC.md (separate step, not a gate)
    const spec_init_run = b.addRunArtifact(check_exe);
    spec_init_run.addArgs(&.{ "spec-init", "." });
    const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
    spec_init_step.dependOn(&spec_init_run.step);

    // debt: non-gating report of baseline/snapshot debt totals (separate step)
    const debt_run = b.addRunArtifact(check_exe);
    debt_run.addArgs(&.{ "debt", "." });
    const debt_step = b.step("debt", "Report baseline/snapshot debt totals with deltas");
    debt_step.dependOn(&debt_run.step);
}
