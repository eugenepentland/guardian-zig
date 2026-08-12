const std = @import("std");
const guardian_helper = @import("src/build_helper.zig");
const source_digest = @import("src/source_digest.zig");

// Re-exported so dependents can `const guardian = @import("guardian");`
// in their own build.zig and call guardian.addAllChecks(...).
pub const addAllChecks = guardian_helper.addAllChecks;
pub const all_check_names = guardian_helper.all_check_names;
pub const Options = guardian_helper.Options;
pub const testRunner = guardian_helper.testRunner;
pub const enableTestDiagnostics = guardian_helper.enableTestDiagnostics;
pub const announceFilters = guardian_helper.announceFilters;
pub const addTestCompileProbe = guardian_helper.addTestCompileProbe;
pub const CompileProbeOptions = guardian_helper.CompileProbeOptions;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The INSTALLED guardian-check defaults to safe even when no
    // -Doptimize is given. This binary runs a 67-check gate over whole
    // consumer trees on every agent commit, and a debug build of it turns
    // that gate from ~1.1 s into ~42 s (measured on eda's 234-file tree,
    // 2026-07-26) — a 40x tax silently paid per commit whenever someone
    // refreshes zig-out with a plain `zig build`. An explicit -Doptimize
    // still wins (dependents like eda pass safe already; a debugger
    // session can ask for -Doptimize=debug). Tests keep the plain default
    // below so the local dev loop keeps its fast compile.
    const exe_optimize: std.builtin.OptimizeMode =
        if (b.user_input_options.contains("optimize")) optimize else .safe;

    // Identity of the source this build is about to compile. A consumer that
    // reuses zig-out/bin/guardian-check instead of paying the ~49 s cold
    // compile proves the binary current by re-running this same walk through
    // `guardian-check selfcheck` and comparing against the value embedded here
    // (src/source_digest.zig; both sides import it so they cannot drift).
    // Reading our own source root is a precondition of building at all, so a
    // failure here is fatal rather than a silently unverifiable binary.
    var source_root = b.root.openDir(b.graph.io, ".", .{}) catch |err|
        std.debug.panic("guardian: cannot open own source root: {s}", .{@errorName(err)});
    defer source_root.close(b.graph.io);
    const digest = source_digest.compute(b.graph.io, b.allocator, source_root) catch |err|
        std.debug.panic("guardian: cannot digest own source root: {s}", .{@errorName(err)});
    const guardian_options = b.addOptions();
    guardian_options.addOption([]const u8, "source_digest", &digest);

    // Guardian check executable — used by this project and dependents
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/check.zig"),
        .target = target,
        .optimize = exe_optimize,
        .single_threaded = false,
    });
    check_mod.addOptions("build_options", guardian_options);
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
        .single_threaded = false,
    });
    test_mod.addOptions("build_options", guardian_options);
    const fuzz_filter = b.option(
        []const u8,
        "fuzz-filter",
        "Select one fuzz test by name for `zig build test --fuzz`",
    );
    // Local iteration aid, NOT a gate. `guardian-check test-filter . --args`
    // derives this list from the current diff, so an edit/verify loop can run
    // its own file's tests instead of the suite:
    //
    //   eval "zig build test $(guardian-check test-filter . --args)"
    //
    // (`eval` because command substitution word-splits without processing
    // quotes — a bare $(...) would tear a test name containing spaces apart.)
    //
    // Zig hands --test-filter to the *compiler*, so unmatched tests are never
    // analyzed — a filtered run cannot prove the test binary compiles. The
    // gate (`guardian-check commit`, the pre-commit hook, CI) therefore always
    // runs the unfiltered `zig build test`.
    const name_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose name contains one of these (repeatable). Local aid only — never a gate.",
    ) orelse &.{};
    var test_filters: std.ArrayList([]const u8) = .empty;
    test_filters.appendSlice(b.allocator, name_filters) catch @panic("out of memory");
    if (fuzz_filter) |filter| test_filters.append(b.allocator, filter) catch @panic("out of memory");
    // Dogfooding: guardian's own suite runs on guardian's counting test runner,
    // so `zig build test` states how many tests it selected and a zero-match
    // filter fails loudly instead of exiting 0 (`.mode = .server` keeps the
    // build system's progress, failure attribution, and --fuzz support).
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = test_filters.items,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .server },
    });
    // Zig 0.17.0-dev.1683's self-hosted backend emits a zero-PC coverage map
    // under --fuzz. Guardian requires a fuzz filter, so use that explicit fuzz
    // configuration to select LLVM without taxing ordinary test builds.
    if (fuzz_filter != null) unit_tests.use_llvm = true;
    const run_tests = b.addRunArtifact(unit_tests);
    guardian_helper.announceFilters(run_tests, test_filters.items);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // The runner's own tests need their own binary: a custom test runner is
    // never part of the module it runs (Zig: "file exists in modules 'root' and
    // 'root'"), so its test decls are invisible to the suite above. This second
    // compilation makes them run, on the stock runner.
    //
    // Consequence of the split, only in this repo: filtering for a test that
    // lives in src/test_runner.zig makes the *main* binary report zero matches
    // and fail, because nothing the filter named ran there. That verdict is
    // correct; run the filter without expecting the main suite to be happy.
    const runner_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runner_tests = b.addTest(.{ .root_module = runner_test_mod, .filters = test_filters.items });
    test_step.dependOn(&b.addRunArtifact(runner_tests).step);

    // test-compile: the middle tier between a filtered run and the gate.
    // Compiles every test (no filter, ever) and runs none of them, so a
    // filtered loop can still prove the whole suite type-checks in seconds.
    // Deliberately NOT a dependency of `test`: making it one would re-compile
    // the whole suite on every filtered run and erase the reason to filter.
    const probe_step = guardian_helper.addTestCompileProbe(b, .{
        .root_module = test_mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .server },
    });
    // The suite lives in two binaries here, so the probe covers both.
    probe_step.dependOn(&b.addTest(.{ .root_module = runner_test_mod }).step);

    // Format check
    const fmt_check = b.addFmt(.{ .paths = &.{b.path("src")}, .check = true });
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
