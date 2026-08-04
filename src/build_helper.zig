//! Downstream integration surface: `addAllChecks` wires every registered gate
//! (and the mutate steps) into a consumer's build in one call, and
//! `all_check_names` is derived from the registry at comptime so a newly
//! registered check is gated automatically with no edit here.
//!
//! It also owns the two pieces that make a *filtered* test loop honest:
//! `testRunner` points a consumer's test binary at Guardian's counting runner,
//! and `addTestCompileProbe` registers the compile-only whole-suite tier that a
//! filtered run can never provide.

const std = @import("std");
const registry = @import("cli/registry.zig");

const generator_name = "spec-init"; // generator, not a gate
const mutate_name = "mutate"; // explicit step, not a gate
const debt_name = "debt"; // non-gating debt report, invoked directly
const doctor_name = "doctor";
const spec_sync_name = "spec-sync";
const accept_name = "accept";
const nightly_name = "nightly"; // composed scheduled tier, dispatched specially
const commit_name = "commit"; // gate + auto-commit, dispatched specially
const run_all_name = "all";
const guardian_run_step = "guardian";
const guardian_explain_step = "guardian-explain";

// Comptime branch budget for the registry-iteration loop in
// all_check_names. Bumped manually if the registry grows enough to
// exhaust it.
const registry_eval_quota: u32 = 20000;

/// Registered gates that should run on every build. Derived from
/// `cli/registry.zig::all` at comptime — adding a new check there wires it
/// here automatically. The generator (`spec-init`), the explicit `mutate`
/// step, the non-gating `debt` report, and the composed `nightly`/`commit`/
/// `all` commands are never gates and are excluded (the last three defensively —
/// they are dispatched specially and don't appear in the registry, mirroring
/// the existing `all` exclusion).
pub const all_check_names: []const []const u8 = blk: {
    @setEvalBranchQuota(registry_eval_quota);
    var names: []const []const u8 = &.{};
    for (registry.all) |cmd| {
        if (std.mem.eql(u8, cmd.name, generator_name)) continue;
        if (std.mem.eql(u8, cmd.name, mutate_name)) continue;
        if (std.mem.eql(u8, cmd.name, debt_name)) continue;
        if (std.mem.eql(u8, cmd.name, nightly_name)) continue;
        if (std.mem.eql(u8, cmd.name, commit_name)) continue;
        if (std.mem.eql(u8, cmd.name, run_all_name)) continue;
        names = names ++ [_][]const u8{cmd.name};
    }
    break :blk names;
};

/// Tunables for addAllChecks.
pub const Options = struct {
    quiet: bool = true,
    /// Optional working directory for each check invocation. Null means
    /// the build's current working directory.
    cwd: ?std.Build.LazyPath = null,
    /// When true (default), every registered gate runs sequentially in
    /// one `guardian-check all` invocation — eliminates 20+ process
    /// spawns per build. When false, each check is its own RunArtifact
    /// (the legacy mode; lets the build graph parallelize across checks).
    single_process: bool = true,
    /// When true (default), also register the top-level `mutate` and
    /// `mutate-full` steps so consumers get the mutation tier for free the
    /// day they upgrade — no hand-wiring. Registration is idempotent (see
    /// `registerMutateSteps`), so calling addAllChecks more than once (a
    /// consumer typically wires both the install and test steps) is safe.
    mutate_steps: bool = true,
    /// Register the canonical current-binary `guardian` runner plus namespaced maintenance steps (`guardian-doctor`,
    /// `guardian-debt`, `guardian-spec-sync`, `guardian-accept`, and
    /// `guardian-explain`) in the consumer build.
    maintenance_steps: bool = true,
    /// When true (default) and `target_step` is the build's install step,
    /// every artifact install already attached to it is re-ordered to run
    /// AFTER the gate. Other install dependencies (generators, formatters, and
    /// validation steps) retain their declared ordering and may prepare inputs
    /// Guardian scans. Without the artifact ordering, a red gate can leave the
    /// previous green build's binaries sitting in zig-out looking current — the
    /// classic "verified a stale binary" trap. Ordering costs ~nothing in
    /// wall-clock (only the final cheap copy waits). Call addAllChecks AFTER
    /// your installArtifact calls so every artifact install is seen.
    gate_install: bool = true,
};

/// Adds RunArtifact step(s) for the registered gates as dependencies of
/// `target_step`. By default emits one combined step (`all`); set
/// `opts.single_process = false` to emit one step per check. Unless
/// `opts.mutate_steps = false`, also registers the top-level `mutate` /
/// `mutate-full` steps once.
pub fn addAllChecks(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    target_step: *std.Build.Step,
    opts: Options,
) void {
    if (opts.mutate_steps) registerMutateSteps(b, check_exe, opts);
    if (opts.maintenance_steps) registerMaintenanceSteps(b, check_exe, opts);

    if (opts.single_process) {
        const run = b.addRunArtifact(check_exe);
        if (opts.quiet) {
            run.addArgs(&.{ run_all_name, ".", "--quiet" });
        } else {
            run.addArgs(&.{ run_all_name, "." });
        }
        if (opts.cwd) |cwd| run.setCwd(cwd);
        target_step.dependOn(&run.step);
        maybeGateInstall(b, target_step, opts, &.{&run.step});
        return;
    }

    var gates: [all_check_names.len]*std.Build.Step = undefined;
    for (all_check_names, 0..) |name, i| {
        const run = b.addRunArtifact(check_exe);
        if (opts.quiet) {
            run.addArgs(&.{ name, ".", "--quiet" });
        } else {
            run.addArgs(&.{ name, "." });
        }
        if (opts.cwd) |cwd| run.setCwd(cwd);
        target_step.dependOn(&run.step);
        gates[i] = &run.step;
    }
    maybeGateInstall(b, target_step, opts, &gates);
}

/// Re-orders every artifact install already attached to the consumer's
/// install step to depend on the gate step(s), so a red gate withholds the
/// install and zig-out never silently holds a stale last-green binary. Other
/// dependencies must remain independent: a generator or formatter may produce
/// inputs that Guardian is expected to scan. Only applies when the caller wired
/// the gate onto the install step itself (a test-step wiring must not schedule
/// extra gate runs into plain `zig build`). No cycle risk: a gate run depends
/// only on compiling guardian-check, never on an install.
fn maybeGateInstall(
    b: *std.Build,
    target_step: *std.Build.Step,
    opts: Options,
    gates: []const *std.Build.Step,
) void {
    if (!opts.gate_install) return;
    const install = b.getInstallStep();
    if (target_step != install) return;
    for (install.dependencies.items) |dep| {
        if (!isArtifactInstall(dep.id)) continue;
        if (containsStep(gates, dep)) continue;
        for (gates) |gate| dep.dependOn(gate);
    }
}

fn isArtifactInstall(id: std.Build.Step.Id) bool {
    return id == .install_artifact;
}

fn containsStep(steps: []const *std.Build.Step, step: *std.Build.Step) bool {
    for (steps) |s| if (s == step) return true;
    return false;
}

fn registerMaintenanceSteps(b: *std.Build, check_exe: *std.Build.Step.Compile, opts: Options) void {
    ensureForwardingStep(b, check_exe, opts);
    ensureToolStep(
        b,
        check_exe,
        opts,
        "guardian-doctor",
        "Audit Guardian metadata and integration",
        &.{ doctor_name, "." },
    );
    ensureToolStep(b, check_exe, opts, "guardian-debt", "Report accepted Guardian debt", &.{ debt_name, "." });
    ensureToolStep(
        b,
        check_exe,
        opts,
        "guardian-spec-sync",
        "Suggest missing SPEC.md bullets",
        &.{ spec_sync_name, "." },
    );

    if (!b.top_level_steps.contains("guardian-accept")) {
        const checks = b.option(
            []const u8,
            "guardian-checks",
            "Comma-separated checks accepted by guardian-accept",
        ) orelse "";
        ensureToolStep(
            b,
            check_exe,
            opts,
            "guardian-accept",
            "Accept named Guardian metadata drift (-Dguardian-checks=a,b)",
            &.{ accept_name, checks, "." },
        );
    }
    if (!b.top_level_steps.contains(guardian_explain_step)) {
        const check = b.option([]const u8, guardian_explain_step, "Check explained by guardian-explain") orelse "";
        ensureToolStep(
            b,
            check_exe,
            opts,
            guardian_explain_step,
            "Explain one Guardian check (-Dguardian-explain=name)",
            &.{ "explain", check },
        );
    }
}

/// Registers `zig build guardian -- <guardian-check args>`. Because the run
/// artifact depends on `check_exe`, it always executes the binary built from
/// the current dependency source rather than an arbitrary cache artifact.
/// With no forwarded args it runs the full suite for the current project.
fn ensureForwardingStep(b: *std.Build, check_exe: *std.Build.Step.Compile, opts: Options) void {
    if (b.top_level_steps.contains(guardian_run_step)) return;
    const run = b.addRunArtifact(check_exe);
    run.addArgs(b.args orelse &.{ run_all_name, "." });
    if (opts.cwd) |cwd| run.setCwd(cwd);
    const step = b.step(guardian_run_step, "Run the freshly built Guardian binary; forward args after --");
    step.dependOn(&run.step);
}

fn ensureToolStep(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    opts: Options,
    name: []const u8,
    description: []const u8,
    args: []const []const u8,
) void {
    if (b.top_level_steps.contains(name)) return;
    const run = b.addRunArtifact(check_exe);
    run.addArgs(args);
    if (opts.cwd) |cwd| run.setCwd(cwd);
    const step = b.step(name, description);
    step.dependOn(&run.step);
}

/// Registers the `mutate` (fast tier) and `mutate-full` (whole-tree ratchet)
/// top-level steps. Each is a standalone user-invoked step, never a dependency
/// of the build (a mutant costs a build + test cycle, so mutation is not a
/// gate). Idempotent so it survives multiple addAllChecks calls and a
/// consumer's own hand-rolled steps.
fn registerMutateSteps(b: *std.Build, check_exe: *std.Build.Step.Compile, opts: Options) void {
    ensureMutateStep(b, check_exe, opts, mutate_name, "Mutation-test changed lines (fast tier)", &.{
        mutate_name, ".",
    });
    ensureMutateStep(b, check_exe, opts, "mutate-full", "Mutation-test whole tree + score ratchet", &.{
        mutate_name, ".", "--full",
    });
}

/// Creates one mutate step wired to `guardian-check <args>`, but only when no
/// top-level step of that name already exists — `b.step` panics on a duplicate,
/// so the `contains` guard is what makes repeated calls (and a consumer's own
/// hand-rolled `mutate` step) safe in either order.
fn ensureMutateStep(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    opts: Options,
    name: []const u8,
    description: []const u8,
    args: []const []const u8,
) void {
    if (b.top_level_steps.contains(name)) return;
    const run = b.addRunArtifact(check_exe);
    run.addArgs(args);
    if (opts.cwd) |cwd| run.setCwd(cwd);
    const step = b.step(name, description);
    step.dependOn(&run.step);
}

// ── The honest filtered-test loop ──────────────────────────────────────

/// The counting test runner, as it is spelled from the package root.
const test_runner_rel_path = "src/test_runner.zig";

/// Default step name for the compile-only whole-suite probe.
const compile_probe_step = "test-compile";

const compile_probe_desc = "Compile the whole test suite without running it";

/// Guardian's test runner, ready for `b.addTest(.{ .test_runner = ... })`.
/// A consumer wires it in one line:
///
///     .test_runner = guardian.testRunner(guardian_dep),
///
/// It prints `guardian/test: N test(s) selected` before the first test and
/// fails a run that selected none — the signal a filtered `zig build test`
/// otherwise cannot give, because Zig applies `--test-filter` in the compiler
/// and a zero-match filter simply produces an empty, silently green binary.
/// `.server` mode keeps the build system's own progress, per-test failure
/// attribution, and `--fuzz` support intact.
pub fn testRunner(dep: *std.Build.Dependency) std.Build.Step.Compile.TestRunner {
    return .{ .path = dep.path(test_runner_rel_path), .mode = .server };
}

/// Forwards the active `--test-filter` texts to the runner so its count line
/// can name them. Zig never tells a test runner what the filter was, so this is
/// the only way the report can say more than the bare number. Optional: without
/// it the count alone is still the signal.
pub fn announceFilters(run: *std.Build.Step.Run, filters: []const []const u8) void {
    const b = run.step.owner;
    for (filters) |filter| run.addArg(b.fmt("--guardian-filter={s}", .{filter}));
}

/// Tunables for `addTestCompileProbe`.
pub const CompileProbeOptions = struct {
    /// The consumer's test module — the same root module its `test` step uses.
    root_module: *std.Build.Module,
    /// Compile the same runner the real test step runs, so the probe covers the
    /// runner too. Null uses the default runner.
    test_runner: ?std.Build.Step.Compile.TestRunner = null,
    /// Top-level step name.
    name: []const u8 = compile_probe_step,
    description: []const u8 = compile_probe_desc,
};

/// Registers the `test-compile` step: analyze the whole test suite, run none of
/// it. One line for a consumer:
///
///     _ = guardian.addTestCompileProbe(b, .{ .root_module = test_mod });
///
/// This is the missing middle tier. A filtered `zig build test` does not
/// type-check the tests it skipped, so it can go green against a suite that no
/// longer compiles; the whole gate is minutes away. The probe declares no
/// filters and never asks for the binary, so the build system passes
/// `-fno-emit-bin` and the compiler stops after semantic analysis — every test
/// is type-checked, nothing is linked or executed. Returns the step so a caller
/// can attach it elsewhere; idempotent on the step name.
pub fn addTestCompileProbe(b: *std.Build, opts: CompileProbeOptions) *std.Build.Step {
    if (b.top_level_steps.get(opts.name)) |existing| return &existing.step;
    // No `.filters`: the probe is whole-suite by construction, so a
    // `-Dtest-filter` narrowing the run can never narrow the probe with it.
    const probe = b.addTest(.{
        .root_module = opts.root_module,
        .test_runner = opts.test_runner,
    });
    const step = b.step(opts.name, opts.description);
    // Depend on the compile itself. Nothing here calls getEmittedBin /
    // installArtifact / addRunArtifact — that is what keeps `generated_bin`
    // null and earns the `-fno-emit-bin` fast path.
    step.dependOn(&probe.step);
    return step;
}

// spec: Maintenance - Registers a canonical build runner for the current Guardian binary

test "canonical Guardian runner step name stays stable" {
    try std.testing.expectEqualStrings("guardian", guardian_run_step);
}

// spec: Build Helper - Points a consumer test binary at the runner file that ships with Guardian

test "the packaged runner path names a file that ships with guardian" {
    // @embedFile is comptime proof the runner sits next to this file; the
    // constant is that same file spelled from the package root, which is how a
    // dependent resolves it (`dep.path(...)`). If either moves, this fails.
    const runner_src = @embedFile("test_runner.zig");
    try std.testing.expect(runner_src.len > 0);
    try std.testing.expectEqualStrings("src/test_runner.zig", test_runner_rel_path);
    // The runner is only worth pointing at because it prints the count.
    try std.testing.expect(std.mem.indexOf(u8, runner_src, "test(s) selected") != null);
}

// spec: Build Helper - Registers the compile-only whole-suite probe under a stable step name

test "compile probe step name and description stay stable" {
    // Consumers put this step name in their docs and CI; it is API.
    try std.testing.expectEqualStrings("test-compile", compile_probe_step);
    try std.testing.expect(std.mem.indexOf(u8, compile_probe_desc, "without running") != null);
    // The probe takes a module and nothing that could narrow it: a filtered
    // probe would answer a question nobody asked.
    try std.testing.expect(@hasField(CompileProbeOptions, "root_module"));
    try std.testing.expect(!@hasField(CompileProbeOptions, "filters"));
}

// spec: Maintenance - Gates artifact copies without delaying generators that prepare analysis inputs

test "install gating selects artifact copies but not input producers" {
    try std.testing.expect(isArtifactInstall(.install_artifact));
    try std.testing.expect(!isArtifactInstall(.run));
    try std.testing.expect(!isArtifactInstall(.update_source_files));
    try std.testing.expect(!isArtifactInstall(.fmt));
}
