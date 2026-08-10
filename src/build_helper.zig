//! Downstream integration surface: `addAllChecks` wires every registered gate
//! (and the mutate steps) into a consumer's build in one call, and
//! `all_check_names` is derived from the registry at comptime so a newly
//! registered check is gated automatically with no edit here.
//!
//! It also owns the two pieces that make a *filtered* test loop honest:
//! `testRunner` points a consumer's test binary at Guardian's counting runner,
//! and `addTestCompileProbe` registers the compile-only whole-suite tier that a
//! filtered run can never provide.
//!
//! Finally it decides HOW guardian-check is reached — compiled from the
//! dependency's source, or reused from the binary already sitting in that
//! dependency's `zig-out/` (see `chooseSource` and the `selfcheck` guard).

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
const selfcheck_name = "selfcheck"; // staleness guard in front of a prebuilt binary
const guardian_run_step = "guardian";
const guardian_explain_step = "guardian-explain";
const guardian_selfcheck_step = "guardian-selfcheck";

/// Env var selecting how guardian-check is reached: `off`/`0` always compiles,
/// any other value is the path of a binary to run, unset auto-detects.
const prebuilt_env = "GUARDIAN_PREBUILT";

/// Where a `zig build` in the Guardian checkout leaves its ReleaseSafe binary —
/// the artifact auto-detection reuses.
const prebuilt_rel_path = "zig-out/bin/guardian-check";

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
    /// Input-producing steps that must finish before Guardian scans the tree.
    /// Consumers with generated source use this to keep a fresh worktree from
    /// racing code generation against the gate.
    prerequisites: []const *std.Build.Step = &.{},
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

/// Adds guardian-check step(s) for the registered gates as dependencies of
/// `target_step`. By default emits one combined step (`all`); set
/// `opts.single_process = false` to emit one step per check. Unless
/// `opts.mutate_steps = false`, also registers the top-level `mutate` /
/// `mutate-full` steps once.
///
/// Whether those steps run a freshly compiled guardian-check or the one already
/// built in the dependency's `zig-out/` is decided here — see `chooseSource`.
pub fn addAllChecks(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    target_step: *std.Build.Step,
    opts: Options,
) void {
    const wiring = resolve(b, check_exe, opts);
    if (opts.mutate_steps) registerMutateSteps(wiring);
    if (opts.maintenance_steps) registerMaintenanceSteps(wiring);

    if (opts.single_process) {
        const run = wiring.invoke(checkArgs(wiring, run_all_name));
        target_step.dependOn(&run.step);
        maybeGateInstall(b, target_step, opts, &.{&run.step});
        return;
    }

    var gates: [all_check_names.len]*std.Build.Step = undefined;
    for (all_check_names, 0..) |name, i| {
        const run = wiring.invoke(checkArgs(wiring, name));
        target_step.dependOn(&run.step);
        gates[i] = &run.step;
    }
    maybeGateInstall(b, target_step, opts, &gates);
}

/// Argv for one gate invocation: the command, the project dir, and `--quiet`
/// when the caller asked for it.
fn checkArgs(w: Wiring, name: []const u8) []const []const u8 {
    if (!w.opts.quiet) return w.b.dupeStrings(&.{ name, "." });
    return w.b.dupeStrings(&.{ name, ".", "--quiet" });
}

// ── Reaching guardian-check ────────────────────────────────────────────

/// How this build reaches guardian-check.
const Source = union(enum) {
    /// Compile it from the dependency's source. What every build did before
    /// prebuilt reuse existed, and still the answer for Guardian's own build.
    compile,
    /// Run this already-built binary. A fresh consumer worktree with its own
    /// Zig cache otherwise pays the full cold ReleaseSafe compile of an
    /// unchanged tool (measured 49 s of a 53 s first build in one consumer);
    /// reusing the artifact turns that into a directory walk.
    prebuilt: []const u8,
};

/// The three resolved facts `chooseSource` decides from, split out so the
/// decision is a pure function instead of a tangle of build-graph and
/// filesystem lookups.
const Choice = struct {
    /// `GUARDIAN_PREBUILT`, or null when unset.
    override: ?[]const u8 = null,
    /// True when the Guardian dependency IS the project being gated.
    self_hosting: bool = false,
    /// Path of the dependency's already-installed binary; null when absent.
    installed: ?[]const u8 = null,
};

/// Picks how guardian-check is reached.
///
/// Self-hosting wins over everything, including an explicit override: a binary
/// in `zig-out/` gating the very source it was built from is exactly the
/// stale-binary trap, and `selfcheck` cannot rescue it — the digest it compares
/// against is the one baked into that stale binary. Guardian's own build always
/// compiles.
///
/// Otherwise an explicit override decides (`off`/`0` to compile, any other
/// value read as a binary path), then the dependency's installed binary, then
/// compiling.
fn chooseSource(choice: Choice) Source {
    if (choice.self_hosting) return .compile;
    const override = choice.override orelse return installedOrCompile(choice.installed);
    if (override.len == 0) return installedOrCompile(choice.installed);
    if (isDisabled(override)) return .compile;
    return .{ .prebuilt = override };
}

/// Reuses the dependency's installed binary when it has one, else compiles.
fn installedOrCompile(installed: ?[]const u8) Source {
    const path = installed orelse return .compile;
    return .{ .prebuilt = path };
}

/// The two spellings that turn prebuilt reuse off.
fn isDisabled(value: []const u8) bool {
    return std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "0");
}

/// One build's answer to "how do I run guardian-check?", plus everything a step
/// registration needs. Resolved once per `addAllChecks` call.
const Wiring = struct {
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    opts: Options,
    source: Source,
    /// Absolute path of the Guardian dependency's build root: what `selfcheck`
    /// is pointed at, and what the self-hosting comparison is made against.
    dep_root: []const u8,
    /// The staleness guard every prebuilt invocation depends on; null when this
    /// build compiles guardian-check and the question cannot arise.
    guard: ?*std.Build.Step,

    /// Registers one guardian-check invocation, wired the way this build
    /// resolved the binary.
    fn invoke(w: Wiring, args: []const []const u8) *std.Build.Step.Run {
        const run = switch (w.source) {
            .compile => w.b.addRunArtifact(w.check_exe),
            .prebuilt => |path| w.b.addSystemCommand(&.{path}),
        };
        run.addArgs(args);
        if (w.opts.cwd) |cwd| run.setCwd(cwd);
        for (w.opts.prerequisites) |prerequisite| run.step.dependOn(prerequisite);
        // Fail closed: nothing a prebuilt binary reports counts until it has
        // proved it was built from the source it claims to speak for.
        if (w.guard) |guard| run.step.dependOn(guard);
        return run;
    }
};

/// Resolves how this build reaches guardian-check and, when that is a prebuilt
/// binary, registers the `selfcheck` guard every invocation hangs off.
///
/// The dependency's build root comes from the artifact the caller already
/// passed in — `check_exe.step.owner` IS the dependency's `*std.Build` — so
/// consumers need no extra argument and Guardian never guesses at a path.
fn resolve(b: *std.Build, check_exe: *std.Build.Step.Compile, opts: Options) Wiring {
    const dep = check_exe.step.owner;
    const dep_root = buildRoot(b, dep);
    const source = chooseSource(.{
        .override = readEnv(b, prebuilt_env),
        .self_hosting = std.mem.eql(u8, dep_root, buildRoot(b, b)),
        .installed = installedBinary(b, dep, dep_root),
    });
    return .{
        .b = b,
        .check_exe = check_exe,
        .opts = opts,
        .source = source,
        .dep_root = dep_root,
        .guard = switch (source) {
            .compile => null,
            .prebuilt => |path| ensureGuardStep(b, path, dep_root),
        },
    };
}

/// Absolute build root of `owner`, resolved through `b` so both sides of the
/// self-hosting comparison are spelled the same way.
fn buildRoot(b: *std.Build, owner: *std.Build) []const u8 {
    return b.pathResolve(&.{owner.build_root.path orelse "."});
}

/// The dependency's already-built binary, or null when it isn't there. Probed
/// through the dependency's own directory handle, so no path is synthesized
/// before it is known to resolve.
fn installedBinary(b: *std.Build, dep: *std.Build, dep_root: []const u8) ?[]const u8 {
    dep.build_root.handle.access(prebuilt_rel_path, .{}) catch return null;
    return b.pathResolve(&.{ dep_root, prebuilt_rel_path });
}

/// Reads a configure-time environment variable; null when unset or unreadable.
fn readEnv(b: *std.Build, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(b.allocator, name) catch null;
}

/// Registers `guardian-selfcheck`: the prebuilt binary proving it matches the
/// source root it is about to gate, before anything else runs. A top-level step
/// so it is also invokable on its own; idempotent on the name, so repeated
/// `addAllChecks` calls share one guard.
fn ensureGuardStep(b: *std.Build, binary: []const u8, dep_root: []const u8) *std.Build.Step {
    if (b.top_level_steps.get(guardian_selfcheck_step)) |existing| return &existing.step;
    const run = b.addSystemCommand(&.{binary});
    run.addArgs(&.{ selfcheck_name, dep_root });
    const step = b.step(guardian_selfcheck_step, "Verify the prebuilt Guardian binary matches its source");
    step.dependOn(&run.step);
    return step;
}

/// Re-orders every artifact install already attached to the consumer's
/// install step to depend on the gate step(s), so a red gate withholds the
/// install and zig-out never silently holds a stale last-green binary. Other
/// dependencies must remain independent: a generator or formatter may produce
/// inputs that Guardian is expected to scan. Only applies when the caller wired
/// the gate onto the install step itself (a test-step wiring must not schedule
/// extra gate runs into plain `zig build`). No cycle risk: a gate run depends
/// only on reaching guardian-check — compiling it, or proving the prebuilt one
/// current — never on an install.
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

fn registerMaintenanceSteps(w: Wiring) void {
    ensureForwardingStep(w);
    ensureToolStep(w, "guardian-doctor", "Audit Guardian metadata and integration", &.{ doctor_name, "." });
    ensureToolStep(w, "guardian-debt", "Report accepted Guardian debt", &.{ debt_name, "." });
    ensureToolStep(w, "guardian-spec-sync", "Suggest missing SPEC.md bullets", &.{ spec_sync_name, "." });

    if (!w.b.top_level_steps.contains("guardian-accept")) {
        const checks = w.b.option(
            []const u8,
            "guardian-checks",
            "Comma-separated checks accepted by guardian-accept",
        ) orelse "";
        ensureToolStep(
            w,
            "guardian-accept",
            "Accept named Guardian metadata drift (-Dguardian-checks=a,b)",
            &.{ accept_name, checks, "." },
        );
    }
    if (!w.b.top_level_steps.contains(guardian_explain_step)) {
        const check = w.b.option([]const u8, guardian_explain_step, "Check explained by guardian-explain") orelse "";
        ensureToolStep(
            w,
            guardian_explain_step,
            "Explain one Guardian check (-Dguardian-explain=name)",
            &.{ "explain", check },
        );
    }
}

/// Registers `zig build guardian -- <guardian-check args>`. It always executes
/// the binary that speaks for the current dependency source rather than an
/// arbitrary cache artifact — either by compiling it, or by running the prebuilt
/// one behind its `selfcheck` guard. With no forwarded args it runs the full
/// suite for the current project.
fn ensureForwardingStep(w: Wiring) void {
    if (w.b.top_level_steps.contains(guardian_run_step)) return;
    const run = w.invoke(w.b.args orelse &.{ run_all_name, "." });
    const step = w.b.step(guardian_run_step, "Run the current Guardian binary; forward args after --");
    step.dependOn(&run.step);
}

/// Creates one top-level step wired to `guardian-check <args>`, but only when no
/// step of that name already exists — `b.step` panics on a duplicate, so the
/// `contains` guard is what makes repeated `addAllChecks` calls (and a
/// consumer's own hand-rolled step of the same name) safe in either order.
fn ensureToolStep(w: Wiring, name: []const u8, description: []const u8, args: []const []const u8) void {
    if (w.b.top_level_steps.contains(name)) return;
    const step = w.b.step(name, description);
    step.dependOn(&w.invoke(args).step);
}

/// Registers the `mutate` (fast tier) and `mutate-full` (whole-tree ratchet)
/// top-level steps. Each is a standalone user-invoked step, never a dependency
/// of the build (a mutant costs a build + test cycle, so mutation is not a
/// gate). Idempotent so it survives multiple addAllChecks calls and a
/// consumer's own hand-rolled steps.
fn registerMutateSteps(w: Wiring) void {
    ensureToolStep(w, mutate_name, "Mutation-test changed lines (fast tier)", &.{ mutate_name, "." });
    ensureToolStep(w, "mutate-full", "Mutation-test whole tree + score ratchet", &.{
        mutate_name, ".", "--full",
    });
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

/// Keeps source locations in assertion failures even when a consumer compiles
/// its tests in ReleaseSafe/ReleaseFast. Without Zig's `-ferror-tracing`, a
/// plain `testing.expect` failure contains only `TestUnexpectedResult`; the
/// custom runner cannot reconstruct a call site the compiler discarded.
pub fn enableTestDiagnostics(test_module: *std.Build.Module) void {
    enableErrorTracing(&test_module.error_tracing);
}

fn enableErrorTracing(flag: *?bool) void {
    flag.* = true;
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
    // The probe is always handed the consumer's test module. Configure that
    // shared module once so the real test artifact retains assertion locations
    // too, even when it was declared before this helper is called.
    enableTestDiagnostics(opts.root_module);
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

/// The binary a `Source` names, or null when the build will compile one — the
/// shape the selection tests assert against.
fn chosenPath(source: Source) ?[]const u8 {
    return switch (source) {
        .compile => null,
        .prebuilt => |path| path,
    };
}

// spec: Prebuilt Binary - Compiles from source when Guardian is gating its own tree

test "self-hosting outranks both an installed binary and an explicit override" {
    // The trap this guard exists for: a zig-out binary gating the very source it
    // was built from. selfcheck cannot catch it — the digest it compares against
    // is the stale one baked into that binary — so the choice must never arise.
    try std.testing.expect(chosenPath(chooseSource(.{
        .self_hosting = true,
        .installed = "/g/zig-out/bin/guardian-check",
    })) == null);
    try std.testing.expect(chosenPath(chooseSource(.{
        .self_hosting = true,
        .override = "/elsewhere/guardian-check",
    })) == null);
}

// spec: Prebuilt Binary - Compiles from source when the prebuilt override is switched off

test "the off and zero spellings of the override force a compile" {
    try std.testing.expect(chosenPath(chooseSource(.{
        .override = "off",
        .installed = "/g/zig-out/bin/guardian-check",
    })) == null);
    try std.testing.expect(chosenPath(chooseSource(.{
        .override = "0",
        .installed = "/g/zig-out/bin/guardian-check",
    })) == null);
    // An empty value is an unset variable, not an opt-out: auto-detection wins.
    try std.testing.expectEqualStrings("/g/zig-out/bin/guardian-check", chosenPath(chooseSource(.{
        .override = "",
        .installed = "/g/zig-out/bin/guardian-check",
    })).?);
}

// spec: Prebuilt Binary - Runs the binary named by the prebuilt override

test "a non-empty override names the binary, outranking auto-detection" {
    try std.testing.expectEqualStrings("/opt/bin/guardian-check", chosenPath(chooseSource(.{
        .override = "/opt/bin/guardian-check",
        .installed = "/g/zig-out/bin/guardian-check",
    })).?);
}

// spec: Prebuilt Binary - Reuses the dependency's installed binary when auto-detection finds one

test "an installed dependency binary is used when nothing overrides it" {
    try std.testing.expectEqualStrings("/g/zig-out/bin/guardian-check", chosenPath(chooseSource(.{
        .installed = "/g/zig-out/bin/guardian-check",
    })).?);
}

// spec: Prebuilt Binary - Compiles from source when the dependency has no installed binary

test "no installed binary falls back to compiling, as builds always did" {
    try std.testing.expect(chosenPath(chooseSource(.{})) == null);
    // The probed location is API: it is where a plain `zig build` in the
    // Guardian checkout leaves the ReleaseSafe binary consumers reuse.
    try std.testing.expectEqualStrings("zig-out/bin/guardian-check", prebuilt_rel_path);
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

// spec: Build Helper - Enables error-return tracing on optimized consumer test modules
test "test diagnostics force error tracing on" {
    // The public build-module wrapper is the consumer API; the pure helper is
    // what this unit test can exercise without constructing std.Build.
    _ = &enableTestDiagnostics;
    var flag: ?bool = null;
    enableErrorTracing(&flag);
    try std.testing.expectEqual(true, flag.?);
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

// spec: Build Helper - Orders caller prerequisites before every gate invocation

test "gate prerequisites are explicit and empty by default" {
    const opts: Options = .{};
    try std.testing.expectEqual(@as(usize, 0), opts.prerequisites.len);
    try std.testing.expect(@hasField(Options, "prerequisites"));
}

// spec: Maintenance - Gates artifact copies without delaying generators that prepare analysis inputs

test "install gating selects artifact copies but not input producers" {
    try std.testing.expect(isArtifactInstall(.install_artifact));
    try std.testing.expect(!isArtifactInstall(.run));
    try std.testing.expect(!isArtifactInstall(.update_source_files));
    try std.testing.expect(!isArtifactInstall(.fmt));
}
