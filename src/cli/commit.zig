//! `commit` command — intent-driven auto-commit, bringing guardian-zig into
//! the sibling guardians' workflow. `guardian-check commit --intent "<msg>"
//! [dir]` runs the full `all` gate; on green it stages the working-tree change
//! set and commits it with the intent as the subject. On red it prints the
//! violations and leaves git untouched.
//!
//! Staging is safety-railed (modelled on guardian-sveltekit/src/commit.ts):
//! never `git add -A` / `.`; the path list comes from `git status --porcelain`
//! (modified + untracked); *untracked* secret/build-artifact paths are skipped
//! with a loud always-shown warning — never a tracked path, and never a `.zig`
//! source, so a legitimate `credentials.zig` module can't be silently dropped
//! and leave the commit desynced from the gated tree; pre-existing `.guardian/`
//! metadata edits and SPEC.md are always included. The gate itself is read-only
//! on metadata — acceptance and migration are the explicit write boundaries —
//! so an interrupted commit audit cannot create unrelated baseline churn. A
//! path git already records as deleted is
//! kept out of the argv entirely (see `stagingDecision`) — it matches no
//! pathspec, and one such path used to fail `git add` for the whole change set.
//!
//! Because it gates the exact working-tree diff it is about to commit,
//! change-classification's diff-timing hole is structurally closed for this
//! flow. Dispatched specially by check.zig (like nightly): its run composes
//! run_all.run, and run_all imports the registry, so a registry entry would
//! close an @import cycle. The run_all SKIP list and build_helper name it
//! defensively so it can never be treated as a gate.

const std = @import("std");
const builtin = @import("builtin");
const wiring = @import("../wiring.zig");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const run_all = @import("run_all.zig");
const install_hook = @import("install_hook.zig");
const git = @import("../git.zig");
const dora = @import("../dora.zig");
const check_roi = @import("../check_roi.zig");
const config = @import("../config.zig");
const external_inputs = @import("../external_inputs.zig");
const test_count = @import("../test_count.zig");
const journal = @import("../mutation/journal.zig");
const fs = @import("../fs.zig");
const source_digest = @import("../source_digest.zig");
const build_helper = @import("../build_helper.zig");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

/// CLI name that check.zig dispatches to this command.
pub const command_name = "commit";

/// Env var set on the `zig build test` child so its wired guardian gate no-ops
/// (see check.zig) while the tests still compile and run — the commit already
/// gated this exact tree in-process. Read by check.zig's main() short-circuit.
pub const child_skip_env = "GUARDIAN_SKIP_CHECKS";

/// Output cap for the captured child test run (a full suite's log).
const max_test_output_bytes: usize = 16 * 1024 * 1024;
const commit_metadata_writable = false;

/// Entry point for the commit command. Requires a non-empty `--intent`, runs
/// the full gate, and on green stages + commits the eligible change set. On a
/// red gate (or a missing intent) it returns error.CheckFailed with git
/// untouched.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const intent = validIntent(ctx.intent) orelse {
        reporter.fail("commit: --intent \"<message>\" is required (missing or empty)", .{});
        return error.CheckFailed;
    };
    var operation_sw = dora.startStopwatch();

    // commit always BLOCKS, regardless of [gate] on_build: nothing enters
    // history unverified even when a dev build only reports.
    ctx.gate = true;
    ctx.roi_origin = command_name;
    ctx.roi_phase = "gate";
    // A commit audits and records the tree; it does not ACCEPT metadata drift.
    // Keeping this read-only matters most on interruption: a killed test phase
    // must not leave unrelated auto-pruned ratchets in the worktree. Explicit
    // `accept` / `migrate` commands remain the only metadata write boundaries.
    ctx.metadata_writable = commit_metadata_writable;

    // Self-hosting staleness guard: when this project dir IS the guardian
    // checkout, a `zig build test` can go green on a freshly compiled suite
    // while the installed `guardian-check` binary acting here predates it
    // (test builds never refresh zig-out). Acting on stale logic sweeps the
    // wrong files into the commit. Refuse before gating anything.
    refuseStaleSelfBuild(ctx) catch |err| {
        recordCommitEvent(ctx, "red", "preflight", operation_sw.elapsedMs(), null, null);
        return err;
    };

    // Say up front when nothing in the change set is an input any check reads:
    // every finding below then describes pre-existing state, not this change —
    // the difference between "my commit broke 49 things" and "this worktree
    // never built its generated files". The gate still runs; nothing is skipped.
    const changed = git.changedPaths(ctx.allocator, ctx.project_dir) catch null;
    noticeNoGateInputs(ctx, changed);

    // Phase markers + a per-phase timing split turn a long commit from a silent
    // wait into a visibly-progressing gate → tests → stage → commit sequence.
    // Both timers run through the dora clock seam (std.time lives in dora only).
    reporter.ok("commit: phase 1/4 — gate (full suite)", .{});
    var gate_sw = dora.startStopwatch();
    // Gate the exact working tree we're about to commit. On red the check output
    // was already printed by run_all; git state is left untouched.
    run_all.run(ctx) catch |e| {
        const failed_gate_ms = gate_sw.elapsedMs();
        recordCommitEvent(ctx, "red", "gate", operation_sw.elapsedMs(), failed_gate_ms, null);
        switch (e) {
            error.CheckFailed => {
                reporter.fail("commit: gate failed — nothing committed", .{});
                return error.CheckFailed;
            },
            else => return e,
        }
    };
    const gate_ms = gate_sw.elapsedMs();

    // The static gate is green; the project's own tests must also pass before
    // anything enters history — unless the change set contains no path the
    // tests could read (embedded assets, SPEC.md, scripts, .guardian metadata):
    // then the whole-suite test step would be pure cost, and the gate — which
    // DOES read some of those paths — already ran in full.
    reporter.ok("commit: phase 2/4 — tests", .{});
    var tests_sw = dora.startStopwatch();
    if (testsSkippable(changed)) {
        reporter.ok("commit: tests skipped — no changed path is a test input (.zig/.zon/guardian.toml)", .{});
    } else {
        runTests(ctx) catch |err| {
            const failed_tests_ms = tests_sw.elapsedMs();
            recordCommitEvent(ctx, "red", "tests", operation_sw.elapsedMs(), gate_ms, failed_tests_ms);
            return err;
        };
    }
    const tests_ms = tests_sw.elapsedMs();
    reporter.ok("commit: timing — {s}", .{try formatTimingSplit(ctx.allocator, gate_ms, tests_ms)});

    // A raw `git commit` must not be able to bypass the gate now that a dev
    // build only reports, so ensure a blocking pre-commit hook exists (best
    // effort; a hook problem never blocks a commit whose gate + tests passed).
    reporter.ok("commit: phase 3/4 — stage", .{});
    if (ctx.cfg.gate.install_hook) install_hook.ensure(ctx);

    reporter.ok("commit: phase 4/4 — commit", .{});
    stageAndCommit(ctx, intent) catch |err| {
        recordCommitEvent(ctx, "red", "commit", operation_sw.elapsedMs(), gate_ms, tests_ms);
        return err;
    };
    recordCommitEvent(ctx, "green", "complete", operation_sw.elapsedMs(), gate_ms, tests_ms);
}

/// Persists the gate/test split for one commit attempt. This is an operational
/// fact only: a red attempt is not automatically a false positive, and a green
/// one is not automatically a defect catch.
fn recordCommitEvent(
    ctx: *types.RunCtx,
    outcome: []const u8,
    phase: []const u8,
    duration_ms: u64,
    gate_duration_ms: ?u64,
    test_duration_ms: ?u64,
) void {
    if (!ctx.cfg.dora.enabled) return;
    check_roi.recordEvent(ctx.allocator, ctx.project_dir, .{
        .action = command_name,
        .identity = .{
            .timestamp_ms = dora.unixMs(),
            .commit = git.headHash(ctx.allocator, ctx.project_dir),
            .guardian_digest = build_options.source_digest,
        },
        .context = .{ .origin = command_name, .phase = phase, .outcome = outcome },
        .timing = .{
            .duration_ms = duration_ms,
            .gate_duration_ms = gate_duration_ms,
            .test_duration_ms = test_duration_ms,
        },
    });
}

/// Prints the up-front notice when no path in the change set is something a
/// check reads. Best-effort: no git, no notice (the gate is unaffected either
/// way — this only tells the reader where the findings came from).
fn noticeNoGateInputs(ctx: *types.RunCtx, changed: ?[]const git.ChangedPath) void {
    const list = changed orelse return;
    if (list.len == 0) return;
    if (anyGateInput(list, ctx.cfg.spec_file, ctx.cfg.external_gates)) return;
    reporter.ok(
        "commit: staged diff contains no gate inputs ({d} path(s), none of them .zig/SPEC/guardian config) " ++
            "— any findings below are pre-existing state, not this change",
        .{list.len},
    );
}

/// True when the change set contains no path the test suite could read, so
/// phase 2's whole-suite run would be pure cost. Test-relevant means a Zig or
/// Zon source (build.zig, build.zig.zon, any src/test .zig) or guardian.toml
/// (which can change `[gate] test_command` itself). A change confined to
/// embedded assets, SPEC.md, scripts, or .guardian metadata cannot alter what
/// the tests compile or assert — the marker/asset tests and shape checks that
/// DO see some of those paths ran in the gate, which still runs in full.
/// Null or empty change sets still run the tests: that is the "re-verify this
/// tree" case, where the commit is the whole point.
fn testsSkippable(changed: ?[]const git.ChangedPath) bool {
    const list = changed orelse return false;
    if (list.len == 0) return false;
    for (list) |c| if (isTestRelevantPath(c.path)) return false;
    return true;
}

/// True when `path` is a file the test suite could read: a Zig or Zon source,
/// or the guardian config that selects the test command itself.
fn isTestRelevantPath(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon")) return true;
    return std.mem.eql(u8, path, "guardian.toml");
}

/// True when at least one changed path is an input some check consumes.
fn anyGateInput(
    changed: []const git.ChangedPath,
    spec_file: []const u8,
    externals: []const config.ExternalGate,
) bool {
    for (changed) |c| if (isGateInput(c.path, spec_file, externals)) return true;
    return false;
}

/// True when `path` is a file the suite actually reads: a `.zig` source, the
/// spec file, guardian.toml, the build files, guardian metadata (excluding its
/// operational cache), or a declared `[[external]]` gate input. Mirrors the
/// input set the green-run digest hashes (see cache.inputDigest) — conservative
/// on purpose: anything under src/ counts, so the notice can never claim
/// "nothing to check" for a change a check might read.
fn isGateInput(path: []const u8, spec_file: []const u8, externals: []const config.ExternalGate) bool {
    if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon")) return true;
    if (std.mem.eql(u8, path, spec_file) or std.mem.eql(u8, path, "guardian.toml")) return true;
    if (std.mem.startsWith(u8, path, "src/") or std.mem.startsWith(u8, path, "test/")) return true;
    if (underDir(path, ".guardian") and !isGuardianCache(path)) return true;
    for (externals) |gate| {
        for (gate.inputs) |input| if (external_inputs.matches(path, input)) return true;
    }
    return false;
}

/// Renders the gate/test wall-clock split as `gate <s>.<t>s · tests <s>.<t>s`
/// (one decimal, floored) for the commit timing line. Pure over its ms inputs,
/// so it is unit-tested without a clock.
fn formatTimingSplit(a: Allocator, gate_ms: u64, tests_ms: u64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "gate {d}.{d}s \u{00B7} tests {d}.{d}s", .{
        gate_ms / std.time.ms_per_s,
        (gate_ms % std.time.ms_per_s) / 100,
        tests_ms / std.time.ms_per_s,
        (tests_ms % std.time.ms_per_s) / 100,
    });
}

/// Runs the configured test suite (`[gate] test_command`, default `zig build
/// test`) before committing. The child build runs with `child_skip_env` set so
/// its own wired guardian gate no-ops while the real tests still compile and run
/// (the commit already gated this tree in-process). A non-zero exit prints the
/// captured output and hard-fails with nothing committed.
fn runTests(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    const argv = try gateTestArgv(a, ctx.cfg);
    if (argv.len == 0) {
        reporter.fail("commit: [gate] test_command is empty — nothing to run", .{});
        return error.CheckFailed;
    }
    reporter.ok("commit: running tests (`{s}`) before committing ...", .{ctx.cfg.gate.test_command});
    try adviseTestTier(ctx);
    const outcome = spawnTests(a, ctx.project_dir, argv) catch |e| {
        reporter.fail("commit: could not run tests ({s}) — nothing committed", .{@errorName(e)});
        return error.CheckFailed;
    };
    if (!outcome.passed) {
        reporter.fail("commit: tests failed — nothing committed", .{});
        reporter.detail("{s}\n", .{outcome.output});
        return error.CheckFailed;
    }
    recordTestCount(ctx, outcome.output);
    reporter.ok("commit: tests passed", .{});
    reportTestTotal(outcome.output);
}

/// Records how many tests the run just executed, from the runner's own
/// `guardian/test: N test(s) selected` line in the captured output.
///
/// This is the one place in Guardian that watches a real test run, so it is the
/// only place that can turn reachability from a model into a measurement: the
/// `test-reachability` check later holds its import-graph closure against this
/// number and reports the tests the model promised that nothing compiled. Fully
/// best-effort — a project not wired to Guardian's runner prints no count and
/// records nothing, and a walk failure leaves the record untouched rather than
/// failing a commit whose gate and tests are green.
fn recordTestCount(ctx: *types.RunCtx, output: []const u8) void {
    const analysis = ctx.testReach() catch return;
    test_count.record(ctx.allocator, ctx.project_dir, output, analysis.tests_in_tree);
}

/// The default whole-suite command `commit` assumes when nothing overrides it.
const default_test_command = "zig build test";

/// Tokens that mark a test command as a deliberately narrowed tier: Zig's own
/// filter flag, and the conventional names for a fast/smoke subset.
const narrowing_tokens = [_][]const u8{ "-Dtest-filter", "--test-filter", "fast", "smoke", "quick" };

/// How much of the suite the configured `[gate] test_command` covers, as far as
/// guardian can tell from the string: the default whole-suite command, a
/// recognisably narrowed tier, or something guardian cannot classify.
const TestTier = enum { whole_suite, filtered, custom };

/// Pure classifier for `[gate] test_command`. Anything token-equal to the
/// default is the whole suite; a filter flag or a fast/smoke/quick token marks a
/// narrowed tier; every other command is unclassifiable (`custom`).
fn testTier(cmd: []const u8) TestTier {
    const effective = withoutEnvPrefix(cmd);
    if (tokensEqual(effective, default_test_command)) return .whole_suite;
    var it = std.mem.tokenizeAny(u8, effective, " \t\r\n");
    while (it.next()) |tok| {
        for (narrowing_tokens) |n| {
            if (std.ascii.findIgnoreCase(tok, n) != null) return .filtered;
        }
    }
    return .custom;
}

/// The command with a leading `env NAME=VALUE …` prefix stripped, so the tier
/// is judged on what `env` actually execs.
///
/// This argv never reaches a shell (see `splitCommand`), so `env(1)` is the way
/// a project sets a variable for the gate's own test run — eda's gate uses it
/// for the runner's `GUARDIAN_TEST_MAX_WALL_SECS` cap. The variables say
/// nothing about how much of the suite runs, so without this every such gate
/// would be advised as `custom` — a permanent false "this is not the whole
/// suite" on a command that is exactly the whole suite.
fn withoutEnvPrefix(cmd: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    const first = it.next() orelse return cmd;
    if (!std.mem.eql(u8, first, "env")) return cmd;
    // Only leading NAME=VALUE tokens belong to env; the first token without an
    // `=` starts the real command. Anything else (a flag like `-u`) is left in
    // place, so an unrecognized env invocation stays conservatively advised.
    var rest = it.rest();
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '=') == null) return rest;
        rest = it.rest();
    }
    return rest;
}

/// True when two commands tokenize to the same argv (whitespace-insensitive).
fn tokensEqual(a_cmd: []const u8, b_cmd: []const u8) bool {
    var ita = std.mem.tokenizeAny(u8, a_cmd, " \t\r\n");
    var itb = std.mem.tokenizeAny(u8, b_cmd, " \t\r\n");
    while (true) {
        const x = ita.next();
        const y = itb.next();
        if (x == null or y == null) return x == null and y == null;
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}

/// Advisory (never blocking) printed before a non-default test command runs: a
/// green filtered/smoke tier does not prove the whole suite compiles, because
/// Zig hands `--test-filter` to the *compiler* — the tests it skipped are never
/// analyzed. Two commits once landed on top of an uncompilable suite this way.
/// Routed through the always-visible detail channel so `--quiet` can't eat it.
fn adviseTestTier(ctx: *types.RunCtx) Allocator.Error!void {
    const cmd = ctx.cfg.gate.test_command;
    const why = switch (testTier(cmd)) {
        .whole_suite => return,
        .filtered => "a narrowed tier",
        .custom => "not the default `" ++ default_test_command ++ "`",
    };
    reporter.detail(
        reporter.prefix ++ "commit: note — [gate] test_command (`{s}`) is {s}: a green run here does " ++
            "NOT prove the whole test suite still compiles (Zig applies --test-filter at COMPILE time, " ++
            "so skipped tests are never analyzed).\n",
        .{ cmd, why },
    );
    const wired = try testCompileProbeWired(ctx.allocator, ctx.project_dir);
    reporter.detail("  {s}\n", .{compileProbeFix(wired)});
}

/// The step name the whole-suite compile tier registers, taken from the helper
/// that registers it so the advisory can never name a step Guardian no longer
/// wires, and the name of that helper call as a consumer's build.zig spells it.
const compile_probe_step = build_helper.compile_probe_step;
const compile_probe_helper = "addTestCompileProbe";

/// Read ceiling for a project's build.zig. Generous: this is one hand-written
/// build script, and a truncated read could only make the advisory wrong.
const max_build_zig_bytes = 1024 * 1024;

/// The remedy under the tier advisory, split on whether the project already
/// exposes `zig build test-compile`.
///
/// Telling a project to wire a step it has ALREADY wired — and had just run
/// green — is the shape that gets an advisory ignored wholesale: six eda
/// commits printed the wiring instruction at a build.zig that registers the
/// probe. What is still true there is only the second half, so that is all it
/// says.
fn compileProbeFix(wired: bool) []const u8 {
    if (wired) return "fix: build.zig already registers `zig build " ++ compile_probe_step ++
        "` — make [gate] test_command run it too, so the gate type-checks every test as well.";
    return "fix: wire the whole-suite compile tier — `_ = guardian." ++ compile_probe_helper ++
        "(b, .{ .root_module = test_mod });` in build.zig registers `zig build " ++ compile_probe_step ++
        "`, which type-checks every test (no filter, -fno-emit-bin) and runs none. " ++
        "Then make test_command run it too.";
}

/// True when the project's own build.zig already registers the compile-only
/// whole-suite tier. Read off the file rather than by asking `zig build --help`
/// for its steps: this advisory sits in front of the test phase of every
/// commit, and it must not spawn a configure of the project's build graph to
/// decide whether to print one sentence. An absent or unreadable build.zig keeps
/// the wiring instruction, which is the harmless direction; OOM propagates
/// rather than posing as "not wired".
fn testCompileProbeWired(a: Allocator, project_dir: []const u8) Allocator.Error!bool {
    const path = try std.fmt.allocPrint(a, "{s}/build.zig", .{project_dir});
    const src = fs.cwd().readFileAlloc(a, path, max_build_zig_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return declaresCompileProbe(src);
}

/// Pure core of `testCompileProbeWired`: does this build.zig text register the
/// compile probe, through the helper or by declaring the step by hand?
fn declaresCompileProbe(build_src: []const u8) bool {
    if (std.mem.indexOf(u8, build_src, compile_probe_helper) != null) return true;
    return std.mem.indexOf(u8, build_src, "\"" ++ compile_probe_step ++ "\"") != null;
}

/// The argv the commit gate runs: exactly the configured `[gate] test_command`.
/// This is the whole-suite guarantee's single seam, and nothing narrows it — in
/// particular the diff-derived filter behind `[test_filter] flag` is never
/// appended. Zig's test filter is a *compiler* flag, so a filtered build never
/// analyzes the tests it skipped and cannot prove the test binary compiles;
/// the gate has to.
fn gateTestArgv(a: Allocator, cfg: *const config.Config) Allocator.Error![]const []const u8 {
    return splitCommand(a, cfg.gate.test_command);
}

/// Splits a `test_command` string into an argv vector on ASCII whitespace
/// (`zig build test` → {zig, build, test}). Pure, so the split is tested without
/// spawning a build. No shell semantics — the argv runs directly.
fn splitCommand(a: Allocator, cmd: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    while (it.next()) |tok| try list.append(a, tok);
    return list.toOwnedSlice(a);
}

/// Result of the child test run: whether it exited 0, and its captured output
/// (stderr preferred — where a Zig test failure report lands — else stdout).
const TestOutcome = struct { passed: bool, output: []const u8 };

/// Interval between heartbeat lines while the test child runs. A commit's test
/// phase is the project's whole test binary — minutes on a real project, silent
/// for all of it — so a tick keeps a slow-but-healthy run readable as progress
/// instead of a hang (agents have killed commits reading as hung, orphaning the
/// test child; the heartbeat exists alongside the kill-on-signal fix below).
/// Named for the commit command (unlike mutate's own same-constant), because
/// the two tick cadences are deliberately different.
const commit_heartbeat_secs: u64 = 10;
const commit_heartbeat_ns: u64 = std.time.ns_per_s * commit_heartbeat_secs;

/// Shared state for the heartbeat thread: when the child started, and an event
/// the main thread SETS once the child is reaped. Setting the event wakes the
/// ticker out of its timed wait immediately, so a fast suite's join returns
/// without waiting out a full tick.
const Heartbeat = struct {
    start_ns: u64,
    done: std.Io.Event = .unset,
};

/// Renders one heartbeat line for an elapsed second count — pure so the
/// wording is testable without waiting a real tick of a live suite.
fn heartbeatLine(buf: []u8, secs: u64) []const u8 {
    return std.fmt.bufPrint(buf, "commit: tests running — {d}s elapsed (still compiling/running)", .{secs}) catch
        "commit: tests running ...";
}

/// Ticks every `commit_heartbeat_secs` while the test child runs, printing
/// elapsed wall time. The wait is on the stop event with the tick as its
/// timeout: a timed-out wait IS the tick, a set event is the stop signal, and
/// any other error ends the thread. Runs on its own thread with a fresh
/// thread-local reporter (no capture), so the line lands on stderr like every
/// other commit line.
fn heartbeatThread(hb: *Heartbeat) void {
    var line_buf: [160]u8 = undefined;
    while (true) {
        var ticked = false;
        hb.done.waitTimeout(wiring.io(), .{ .duration = .{
            .clock = .awake,
            .raw = .fromNanoseconds(@intCast(commit_heartbeat_ns)),
        } }) catch |e| switch (e) {
            error.Timeout => ticked = true, // the tick: the stop event is never set during a live run
            else => return, // cancel/broken pipe: the run is going away
        };
        if (!ticked) return; // the stop event was set: the child was reaped
        const secs = (dora.nowNs() - hb.start_ns) / std.time.ns_per_s;
        reporter.ok("{s}", .{heartbeatLine(&line_buf, secs)});
    }
}

/// One exclusive operational log used to capture a commit's test output.
/// A regular file is deliberate: waiting on pipe EOF before calling `wait`
/// left exited children as zombies on large sharded builds. With a file the
/// parent can reap the child immediately, then read the bounded transcript.
const TestCapture = struct {
    file: fs.File,
    path: []const u8,
};

const max_capture_slots: usize = 100;

fn createTestCapture(a: Allocator, project_dir: []const u8) !TestCapture {
    const cache_dir = try std.fmt.allocPrint(a, "{s}/.guardian/cache", .{project_dir});
    defer a.free(cache_dir);
    try fs.cwd().makePath(cache_dir);
    for (0..max_capture_slots) |slot| {
        const path = try std.fmt.allocPrint(a, "{s}/commit-tests-{d}.log", .{ cache_dir, slot });
        const file = fs.cwd().createFile(path, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
        }) catch |e| switch (e) {
            error.PathAlreadyExists => {
                if (!try reclaimAbandonedCapture(path)) {
                    a.free(path);
                    continue;
                }
                return createCaptureAt(path) catch |retry_err| switch (retry_err) {
                    error.PathAlreadyExists => {
                        a.free(path);
                        continue;
                    },
                    else => return retry_err,
                };
            },
            else => {
                a.free(path);
                return e;
            },
        };
        return .{ .file = file, .path = path };
    }
    return error.SystemResources;
}

fn createCaptureAt(path: []const u8) fs.File.OpenError!TestCapture {
    const file = try fs.cwd().createFile(path, .{
        .read = true,
        .exclusive = true,
        .lock = .exclusive,
    });
    return .{ .file = file, .path = path };
}

/// Claims and removes a transcript whose process died before its defers ran.
/// A live capture holds the same kernel lock and returns false, so concurrent
/// commits never delete one another's output.
fn reclaimAbandonedCapture(path: []const u8) !bool {
    const file = fs.cwd().openFile(path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return false,
        error.FileNotFound => return true,
        else => return err,
    };
    defer file.close();
    fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return true;
}

fn readTestCapture(a: Allocator, capture: TestCapture) ![]const u8 {
    const size = (try capture.file.stat()).size;
    if (size > max_test_output_bytes) return error.StreamTooLong;
    const output = try a.alloc(u8, @intCast(size));
    errdefer a.free(output);
    const read = try capture.file.preadAll(output, 0);
    return output[0..read];
}

test "createTestCapture reclaims an unlocked transcript left by an interrupted commit" {
    const dir = "zig-cache/commit-capture-reclaim";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir ++ "/.guardian/cache");
    try fs.cwd().writeFile(.{
        .sub_path = dir ++ "/.guardian/cache/commit-tests-0.log",
        .data = "abandoned",
    });
    var capture = try createTestCapture(std.testing.allocator, dir);
    defer std.testing.allocator.free(capture.path);
    defer capture.file.close();
    try std.testing.expect(std.mem.endsWith(u8, capture.path, "commit-tests-0.log"));
}

/// Spawns `argv` in `project_dir` with `child_skip_env` set, capturing output,
/// and supervises it: the child runs in its OWN process group so a SIGINT/
/// SIGTERM handler can kill the whole tree (`kill(-pgid)`, reaping the
/// compile/test grandchildren a killed commit would otherwise leave spinning on
/// the zig cache), and a heartbeat thread keeps a long suite visibly alive.
fn spawnTests(a: Allocator, project_dir: []const u8, argv: []const []const u8) !TestOutcome {
    // Install the same SIGINT/SIGTERM handler the mutation runner uses: kill
    // the child group on the way out, then re-raise with the default
    // disposition so the exit status still reads as the signal. Idempotent.
    journal.install();

    var env = try wiring.cloneEnviron(a);
    defer env.deinit();
    try env.put(child_skip_env, "1");

    var capture = try createTestCapture(a, project_dir);
    defer a.free(capture.path);
    defer capture.file.close();
    defer fs.cwd().deleteFile(capture.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => reporter.detail("commit: could not remove test transcript {s}: {s}\n", .{
            capture.path,
            @errorName(err),
        }),
    };

    const io = wiring.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = project_dir },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = capture.file.inner },
        .stderr = .{ .file = capture.file.inner },
        .pgid = 0, // own process group → -pgid kills the whole tree
    });
    defer child.kill(io); // no-op after wait
    journal.trackChild(child.id.?);
    defer journal.trackChild(0);

    var hb: Heartbeat = .{ .start_ns = dora.nowNs() };
    const hb_thread: ?std.Thread = if (builtin.single_threaded)
        null
    else
        std.Thread.spawn(.{}, heartbeatThread, .{&hb}) catch null;
    // LIFO: kill, untrack, then set the stop event (wakes the ticker), then
    // join — the event makes the join return immediately for a fast suite.
    defer if (hb_thread) |t| t.join();
    defer hb.done.set(wiring.io());

    const term = try child.wait(io);
    const output = try readTestCapture(a, capture);
    return .{ .passed = term.success(), .output = output };
}

/// Sums the runner's machine-readable `guardian/test: RESULT {...}` lines in
/// `output` into one total. A sharded suite prints one such line per shard, so
/// summing them states the whole-suite number — replacing the awk-sum-the-shards
/// ritual that silently mis-adds when a shard dies before printing its line.
/// `shards` counts the RESULT lines found; zero means the suite isn't wired to
/// Guardian's runner and nothing is reported.
const TestTotal = struct { passed: u64 = 0, failed: u64 = 0, skipped: u64 = 0, shards: u32 = 0 };

const result_marker = "guardian/test: RESULT ";

fn sumTestResults(output: []const u8) TestTotal {
    var total: TestTotal = .{};
    var rest = output;
    while (std.mem.indexOf(u8, rest, result_marker)) |idx| {
        const line_start = idx + result_marker.len;
        const line_end = std.mem.indexOfScalarPos(u8, rest, line_start, '\n') orelse rest.len;
        const line = rest[line_start..line_end];
        total.passed +|= jsonInt(line, "passed");
        total.failed +|= jsonInt(line, "failed");
        total.skipped +|= jsonInt(line, "skipped");
        total.shards +|= 1;
        rest = rest[line_end..];
    }
    return total;
}

/// The integer after `"key":` in one result line; 0 when absent. The needle is
/// comptime (callers pass literals), so it is assembled without allocation.
fn jsonInt(line: []const u8, comptime key: []const u8) u64 {
    const needle = "\"" ++ key ++ "\":";
    const idx = std.mem.indexOf(u8, line, needle) orelse return 0;
    const start = idx + needle.len;
    var end = start;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') end += 1;
    return std.fmt.parseInt(u64, line[start..end], 10) catch 0;
}

/// Prints the summed whole-suite total after a passing test run, when the run
/// emitted any RESULT lines. Silent for a suite not wired to Guardian's runner.
fn reportTestTotal(output: []const u8) void {
    const total = sumTestResults(output);
    if (total.shards == 0) return;
    reporter.ok("guardian/test: SUITE: {d} passed, {d} failed, {d} skipped across {d} shard(s)", .{
        total.passed, total.failed, total.skipped, total.shards,
    });
}

/// Trims `intent`; null when absent or blank — so a missing/empty `--intent`
/// is a clean error with no side effects.
fn validIntent(intent: ?[]const u8) ?[]const u8 {
    const s = intent orelse return null;
    const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// Pure decision behind the self-hosting staleness guard: the running binary
/// is stale exactly when its embedded source digest differs from the digest of
/// the Guardian source tree it is about to gate.
fn staleSelfBuild(embedded: []const u8, actual: []const u8) bool {
    return !std.mem.eql(u8, embedded, actual);
}

/// True when `project_dir` is the guardian checkout itself, not a consumer
/// project. The fingerprint is a file only Guardian's own tree carries — a
/// consumer's `src/` has no such marker, so this never fires on their commits.
fn isGuardianSourceRoot(ctx: *const types.RunCtx) bool {
    var buf: [fs.max_path_bytes]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "{s}/src/source_digest.zig", .{ctx.project_dir}) catch return false;
    fs.cwd().access(marker, .{}) catch return false;
    return true;
}

/// Refuses to gate/commit when the running binary was built from a different
/// Guardian source than the tree it is about to act on. This is the self-
/// hosting trap: `zig build test` compiles the suite from the NEW source but
/// never refreshes the installed `guardian-check`, so the binary that ACTS
/// (sweeps files, writes baselines, commits) predates the source it is gating.
/// Best-effort on the digest read — a consumer project is never fingerprinted
/// as a guardian root, and an unreadable tree falls through to the normal gate.
fn refuseStaleSelfBuild(ctx: *types.RunCtx) types.RunError!void {
    if (!isGuardianSourceRoot(ctx)) return;
    const root = fs.cwd().openDir(ctx.project_dir, .{}) catch return;
    defer root.close();
    const actual = source_digest.compute(wiring.io(), ctx.allocator, root.inner) catch return;
    if (!staleSelfBuild(build_options.source_digest, &actual)) return;
    reporter.fail(
        "commit: this guardian-check binary predates the source it would gate — " ++
            "run `zig build` first, then re-run commit",
        .{},
    );
    return error.CheckFailed;
}

/// Stages the eligible change set (skipping/reporting forbidden paths) and
/// commits it with `intent`. A green gate with an empty stage set is a no-op.
fn stageAndCommit(ctx: *types.RunCtx, intent: []const u8) types.RunError!void {
    const a = ctx.allocator;
    const changed = (try git.changedPaths(a, ctx.project_dir)) orelse {
        reporter.fail("commit: `git status` failed — not a git repo, or git unavailable", .{});
        return error.CheckFailed;
    };
    // Resolved here, not inside the planner, so the staging rails stay pure over
    // their inputs and unit-testable without touching git.
    const hook_path = install_hook.relativeHookPath(a, ctx.project_dir);
    const plan = try planStaging(a, changed, ctx.cfg.spec_file, hook_path);

    warnSkipped(plan.skipped);
    switch (commitAction(plan)) {
        .nothing_to_commit => {
            reporter.ok("commit: nothing to commit", .{});
            return;
        },
        .commit_already_staged => {}, // every change is already in the index
        .stage_then_commit => if (!try git.addPaths(a, ctx.project_dir, plan.stage)) {
            reporter.fail("commit: `git add` failed — nothing committed", .{});
            return error.CheckFailed;
        },
    }
    if (!git.commit(a, ctx.project_dir, intent)) {
        reporter.fail("commit: `git commit` failed", .{});
        return error.CheckFailed;
    }
    const hash = git.headHash(a, ctx.project_dir) orelse "(unknown)";
    reporter.ok("commit: {s} — \"{s}\" ({s})", .{ hash, intent, try stagedSummary(a, plan) });
}

/// What the staging phase does with a computed plan. A path git already records
/// as deleted needs no `git add` — and, when it is the *only* change, must not
/// be mistaken for "nothing to commit": the index holds a real deletion.
const CommitAction = enum { nothing_to_commit, stage_then_commit, commit_already_staged };

/// Pure staging decision over a plan. Separated from `stageAndCommit` so the
/// "deletion-only change set still commits" rule is tested without touching git.
fn commitAction(plan: StagePlan) CommitAction {
    if (plan.stage.len > 0) return .stage_then_commit;
    if (plan.staged_deletions.len > 0) return .commit_already_staged;
    return .nothing_to_commit;
}

/// The parenthesised path tally on the success line. Names already-staged
/// deletions separately, because they are in the commit without ever appearing
/// in the `git add` argv — a silent difference otherwise.
fn stagedSummary(a: Allocator, plan: StagePlan) Allocator.Error![]const u8 {
    if (plan.staged_deletions.len == 0) {
        return std.fmt.allocPrint(a, "{d} path(s) staged", .{plan.stage.len});
    }
    return std.fmt.allocPrint(a, "{d} path(s) staged, {d} already-staged deletion(s)", .{
        plan.stage.len,
        plan.staged_deletions.len,
    });
}

/// Prints the loud skip warning through the reporter's failure channel, which
/// is shown even in quiet mode — a silently dropped path leaves the commit not
/// matching the tree the gate just verified, and that must never go unnoticed.
/// The commit itself still proceeds; only the listed paths are left out.
fn warnSkipped(skipped: []const []const u8) void {
    if (skipped.len == 0) return;
    reporter.fail("commit: WARNING — {d} untracked secret-like/build path(s) skipped, NOT committed:", .{skipped.len});
    for (skipped) |p| reporter.detail("  skipped: {s}\n", .{p});
    reporter.detail("  fix: gitignore it, rename it, or `git add` it yourself to include it\n", .{});
}

/// The staging split: paths to stage, the forbidden paths that were skipped,
/// and the deletions git has already recorded (no `git add` possible or needed).
const StagePlan = struct {
    stage: []const []const u8,
    skipped: []const []const u8,
    staged_deletions: []const []const u8 = &.{},
};

/// Partitions `changed` into the stage set, the skipped-forbidden set, and the
/// already-staged deletions. Pure over its inputs so the rails are unit-tested
/// without touching git.
fn planStaging(
    a: Allocator,
    changed: []const git.ChangedPath,
    spec_file: []const u8,
    hook_path: ?[]const u8,
) Allocator.Error!StagePlan {
    var stage: std.ArrayList([]const u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    var deletions: std.ArrayList([]const u8) = .empty;
    for (changed) |c| {
        switch (stagingDecision(c, spec_file, hook_path)) {
            .stage => try stage.append(a, c.path),
            .skip_forbidden => try skipped.append(a, c.path),
            .already_staged => try deletions.append(a, c.path),
            .skip_generated => {},
        }
    }
    return .{
        .stage = try stage.toOwnedSlice(a),
        .skipped = try skipped.toOwnedSlice(a),
        .staged_deletions = try deletions.toOwnedSlice(a),
    };
}

/// What to do with one changed path. `skip_generated` is warning-free — see
/// `stagingDecision` for why that one silent drop is safe. `already_staged` is
/// warning-free for a different reason: the change IS in the commit, just not
/// via `git add`.
const StageAction = enum { stage, skip_forbidden, skip_generated, already_staged };

/// Per-path staging decision: the always-include set (guardian metadata + the
/// spec file) wins; the filters apply only to untracked paths — a tracked path
/// was deliberately added to the repo, and skipping its change would desync the
/// commit from the gated tree; the default is staging.
///
/// The hook check comes first and is the one drop that is *not* warned about:
/// `run` had `install_hook.ensure` write that exact file moments earlier, so
/// warning would fire on every single commit. Silence is safe here in a way it
/// is not for a forbidden path — the hook is Guardian's own machine-local
/// output (it embeds an absolute binary path, so it must never enter history),
/// it is never gated source, and dropping it cannot desync the commit from the
/// tree the gate verified.
fn stagingDecision(c: git.ChangedPath, spec_file: []const u8, hook_path: ?[]const u8) StageAction {
    // A deletion git already recorded comes first, ahead of every other rail:
    // the path is in neither the worktree nor the index, so naming it in the
    // `git add` argv is a fatal `pathspec … did not match any files` that aborts
    // the WHOLE batch — one deleted file used to mean "git add failed — nothing
    // committed" for the entire change set. Deletions are ordinary change-set
    // members; this one is simply already staged, so there is nothing to add.
    if (c.staged_deletion) return .already_staged;
    // Guardian's own operational cache is git-ignored, digest-excluded state that
    // must never enter history — checked BEFORE alwaysInclude, which otherwise
    // carries everything under `.guardian/` wholesale. Silent, like the hook: it
    // is never tracked source and dropping it can't desync the gated tree.
    if (isGuardianCache(c.path)) return .skip_generated;
    if (alwaysInclude(c.path, spec_file)) return .stage;
    if (!c.tracked and isGeneratedHook(c.path, hook_path)) return .skip_generated;
    if (!c.tracked and isForbidden(c.path)) return .skip_forbidden;
    return .stage;
}

/// True when `path` is guardian's operational cache tree — the git-ignored,
/// digest-excluded `.guardian/cache/` (inputs.sha256, last-run.jsonl, …). It is
/// the one cache-pattern hole sitting under an always-include prefix; the
/// zig-out / .zig-cache rail (`isBuildArtifactPath`) never sees it because its
/// first path segment is `.guardian`.
fn isGuardianCache(path: []const u8) bool {
    return underDir(path, ".guardian/cache");
}

/// True when `path` is the pre-commit hook Guardian manages for this project.
/// `hook_path` is null when git couldn't resolve a hooks dir inside the project,
/// in which case there is nothing to exclude.
fn isGeneratedHook(path: []const u8, hook_path: ?[]const u8) bool {
    const hook = hook_path orelse return false;
    return std.mem.eql(u8, path, hook);
}

/// True for paths always carried by the commit: pre-existing `.guardian/`
/// metadata edits (from explicit acceptance/migration) and the spec file.
fn alwaysInclude(path: []const u8, spec_file: []const u8) bool {
    if (underDir(path, ".guardian")) return true;
    if (std.mem.eql(u8, path, spec_file)) return true;
    return false;
}

/// True for an untracked path that looks like a secret or build artifact and
/// must not be silently staged — the safety rail against committing a
/// credential the project's .gitignore missed. Name matching ignores letter
/// case: a capitalized Credentials.json is as much a secret as a lowercase
/// one. The fuzzy name heuristic (`credentials`/`secret` substrings) never
/// fires on a `.zig` source: the gate just compiled and tested it, and a
/// credentials.zig store module is code, not a secret. Mirrors
/// guardian-sveltekit's forbidden list, Zig-flavored.
fn isForbidden(path: []const u8) bool {
    const base = baseName(path);
    if (isBuildArtifactPath(path)) return true;
    if (isSessionStatePath(path)) return true;
    if (std.ascii.eqlIgnoreCase(base, ".env") or std.ascii.startsWithIgnoreCase(base, ".env.")) return true;
    if (std.ascii.startsWithIgnoreCase(base, "id_rsa")) return true;
    if (endsWithAny(base, &.{ ".pem", ".key", ".p12" })) return true;
    if (std.ascii.endsWithIgnoreCase(base, ".zig")) return false;
    if (containsAny(path, &.{ "credentials", "secret" })) return true;
    return false;
}

/// True when `path` sits inside the directory `dir` (`<dir>/…`).
fn underDir(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
}

/// True when `path`'s first segment is a Zig build-output directory. Matches
/// `zig-out/`, `.zig-cache/`, and — critically — the *suffixed* isolated caches
/// the mutation runner creates (`.zig-cache-c/`, `.zig-cache-rfaudit/`, …). The
/// old exact-`.zig-cache` boundary missed those suffixed names, so three
/// separate reports had them swept into a commit (441 binary blobs in one).
fn isBuildArtifactPath(path: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    const seg = path[0..slash];
    return std.mem.eql(u8, seg, "zig-out") or
        std.mem.startsWith(u8, seg, ".zig-cache") or
        std.mem.startsWith(u8, seg, "zig-cache");
}

/// True when `path`'s first segment is a coding-agent session-state directory.
/// These hold another tool's per-session scratch (worktree registries, local
/// settings, transcripts), not project source: one commit swept a stray
/// `.codex/worktrees/…` entry in alongside real code. Untracked only, so a
/// project that deliberately tracks `.claude/settings.json` is unaffected, and
/// the skip warning tells the author how to include it on purpose.
fn isSessionStatePath(path: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    const seg = path[0..slash];
    return std.mem.eql(u8, seg, ".codex") or std.mem.eql(u8, seg, ".claude");
}

/// The final path segment after the last `/` (the whole string if none).
fn baseName(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

/// True when `s` ends with any of `suffixes`, ignoring letter case.
fn endsWithAny(s: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suf| if (std.ascii.endsWithIgnoreCase(s, suf)) return true;
    return false;
}

/// True when `s` contains any of `needles`, ignoring letter case.
fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.ascii.findIgnoreCase(s, n) != null) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Commit - Records the test count its own passing test run reported

test "recordTestCount stores the runner's count from the captured test output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-commit-count";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};

    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &cfg, .quiet = true };
    // This is the only place in Guardian that watches a real test run, so it is
    // where reachability stops being a model and becomes a measurement.
    recordTestCount(&ctx, "guardian/test: 42 test(s) selected\nAll tests passed.\n");
    const rec = test_count.read(a, dir) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 42), rec.selected);
    // The empty fixture directory holds no `test` block at all, and the record
    // says so — that count is what a later run compares against for staleness.
    try testing.expectEqual(@as(u32, 0), rec.tests_in_tree);
}

// spec: Commit - Reports up front when the change set contains no gate inputs

test "anyGateInput separates checkable inputs from a docs-and-scripts change" {
    // The reported case: a change of shell scripts and markdown only. Nothing
    // there is read by any check, so the findings a gate prints come from the
    // working tree — worth saying before a 40s run, not after it.
    const docs_only = [_]git.ChangedPath{
        untracked(".githooks/pre-commit"),
        tracked("README.md"),
        tracked("docs/deploy.md"),
    };
    try std.testing.expect(!anyGateInput(&docs_only, "SPEC.md", &.{}));

    // Anything a check actually reads flips it: Zig source, the spec file,
    // guardian config/metadata, build files, or a declared external input.
    try std.testing.expect(isGateInput("src/router.zig", "SPEC.md", &.{}));
    try std.testing.expect(isGateInput("SPEC.md", "SPEC.md", &.{}));
    try std.testing.expect(isGateInput("guardian.toml", "SPEC.md", &.{}));
    try std.testing.expect(isGateInput("build.zig.zon", "SPEC.md", &.{}));
    try std.testing.expect(isGateInput(".guardian/baselines/spec.txt", "SPEC.md", &.{}));
    // Guardian's own operational cache is not an input to anything.
    try std.testing.expect(!isGateInput(".guardian/cache/last-run.jsonl", "SPEC.md", &.{}));
    // A declared [[external]] gate input counts as a gate input.
    const externals = [_]config.ExternalGate{.{ .name = "js", .command = &.{}, .inputs = &.{"assets/app.js"} }};
    try std.testing.expect(isGateInput("assets/app.js", "SPEC.md", &externals));
}

// spec: Commit - Treats paths matched by external input globs as gate inputs
test "a globbed external input makes its matching changed path checkable" {
    const externals = [_]config.ExternalGate{.{ .name = "js", .command = &.{}, .inputs = &.{"assets/*.js"} }};
    try std.testing.expect(isGateInput("assets/app.js", "SPEC.md", &externals));
    try std.testing.expect(!isGateInput("assets/app.css", "SPEC.md", &externals));
}

// spec: Commit - Skips the test suite when the change set contains no test-relevant path

test "testsSkippable skips only a change set with no test input" {
    // The reported case: an embedded-asset-only change (one JS file under
    // src/serve/assets). Nothing the test suite compiles or asserts changed,
    // so the whole-suite run would be pure cost — the gate still ran in full.
    const assets_only = [_]git.ChangedPath{tracked("src/serve/assets/pcb_board.js")};
    try std.testing.expect(testsSkippable(&assets_only));

    // A SPEC.md-only change is equally invisible to the test binary.
    const spec_only = [_]git.ChangedPath{tracked("SPEC.md")};
    try std.testing.expect(testsSkippable(&spec_only));

    // Any Zig source flips it back on — including a test block in src/.
    const zig_change = [_]git.ChangedPath{ tracked("src/serve/assets/pcb_board.js"), tracked("src/serve.zig") };
    try std.testing.expect(!testsSkippable(&zig_change));

    // build.zig.zon is a Zon source: a dependency change recompiles everything.
    const zon_change = [_]git.ChangedPath{tracked("build.zig.zon")};
    try std.testing.expect(!testsSkippable(&zon_change));

    // guardian.toml can change [gate] test_command itself, so it must run.
    const toml_change = [_]git.ChangedPath{tracked("guardian.toml")};
    try std.testing.expect(!testsSkippable(&toml_change));

    // No change set at all (or no git) still runs the tests: the commit is the
    // "re-verify this tree" case, where skipping would defeat the request.
    try std.testing.expect(!testsSkippable(null));
    try std.testing.expect(!testsSkippable(&[_]git.ChangedPath{}));
}

// spec: Commit - Sums the runner's machine-readable result lines across shards into one total

test "sumTestResults totals the RESULT lines of a sharded run" {
    // Three shards, each printing the runner's machine line; the sum is the
    // whole-suite number the commit reports instead of an awk pipeline.
    const output =
        "guardian/test: 1200 test(s) selected\n" ++
        "guardian/test: PASS — 1200 passed\n" ++
        "guardian/test: RESULT {\"passed\":1200,\"failed\":0,\"skipped\":0}\n" ++
        "guardian/test: PASS — 990 passed\n" ++
        "guardian/test: RESULT {\"passed\":990,\"failed\":0,\"skipped\":2}\n" ++
        "guardian/test: FAIL — 1 failed of 992\n" ++
        "guardian/test: RESULT {\"passed\":991,\"failed\":1,\"skipped\":0,\"aborted\":true}\n";
    const total = sumTestResults(output);
    try std.testing.expectEqual(@as(u64, 3181), total.passed);
    try std.testing.expectEqual(@as(u64, 1), total.failed);
    try std.testing.expectEqual(@as(u64, 2), total.skipped);
    try std.testing.expectEqual(@as(u32, 3), total.shards);

    // A suite not wired to Guardian's runner prints no RESULT lines at all.
    const foreign = "All 42 tests passed.\n";
    try std.testing.expectEqual(@as(u32, 0), sumTestResults(foreign).shards);

    // A test NAME containing the marker must not be mistaken for a result line:
    // the marker is matched, then only the JSON fields on that line are read.
    const tricky = "guardian/test: PASS — 1 passed\n" ++
        "guardian/test: RESULT {\"passed\":7,\"failed\":0,\"skipped\":0}\n";
    try std.testing.expectEqual(@as(u64, 7), sumTestResults(tricky).passed);
    try std.testing.expectEqual(@as(u32, 1), sumTestResults(tricky).shards);
}

// spec: Commit - Heartbeats a long test run so a slow suite reads as progress, not a hang

test "the heartbeat line names the elapsed seconds" {
    var buf: [160]u8 = undefined;
    const line = heartbeatLine(&buf, 42);
    try std.testing.expect(std.mem.indexOf(u8, line, "42s elapsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "still compiling/running") != null);
}

// spec: Commit - Kills the whole test process group when the commit is interrupted

test "spawnTests puts the test child in its own process group" {
    // `kill -0 -$$` succeeds only when the shell's pid names its own process
    // group — i.e. the child was spawned as a group leader (pgid 0). That is
    // the property the SIGINT/SIGTERM handler relies on to kill the whole tree
    // (`kill(-pgid)`) instead of leaving an orphaned `zig build test` spinning
    // on the zig cache. POSIX-only, like the rest of the process supervision.
    const argv = [_][]const u8{ "sh", "-c", "kill -0 -$$ 2>/dev/null && echo GROUPED || echo NOT-GROUPED" };
    const outcome = try spawnTests(std.testing.allocator, ".", &argv);
    defer std.testing.allocator.free(outcome.output);
    try std.testing.expect(outcome.passed);
    try std.testing.expect(std.mem.indexOf(u8, outcome.output, "GROUPED") != null);
}

// spec: Commit - Reaps the test child before reading its bounded captured transcript

test "spawnTests returns the complete transcript after the child exits" {
    const argv = [_][]const u8{ "sh", "-c", "printf start; sleep 0.01; printf -- '-done'" };
    const outcome = try spawnTests(std.testing.allocator, ".", &argv);
    defer std.testing.allocator.free(outcome.output);
    try std.testing.expect(outcome.passed);
    try std.testing.expectEqualStrings("start-done", outcome.output);
}

// spec: Commit - Leaves guardian metadata unchanged while auditing a commit

test "commit explicitly disables metadata writes" {
    try std.testing.expect(!commit_metadata_writable);
}

// spec: Commit - Requires a non-empty intent message

test "validIntent rejects null and blank, trims otherwise" {
    try testing.expect(validIntent(null) == null);
    try testing.expect(validIntent("") == null);
    try testing.expect(validIntent("   ") == null);
    try testing.expectEqualStrings("fix bug", validIntent("  fix bug  ").?);
}

// spec: Commit - Refuses a stale self-hosted binary before it can act on newer source

test "staleSelfBuild is true only when the embedded digest differs from the tree's" {
    // A binary whose embedded digest matches the source it gates is current.
    try testing.expect(!staleSelfBuild("0123abcd", "0123abcd"));
    // Any difference — even a later prefix — means the binary predates source.
    try testing.expect(staleSelfBuild("0123abcd", "0123abce"));
    try testing.expect(staleSelfBuild("0123abcd", ""));
    try testing.expect(staleSelfBuild("", "anything"));
}

/// Test shorthand for an untracked porcelain entry (`??`).
fn untracked(path: []const u8) git.ChangedPath {
    return .{ .path = path, .tracked = false };
}

/// Test shorthand for a tracked porcelain entry (anything but `??`).
fn tracked(path: []const u8) git.ChangedPath {
    return .{ .path = path, .tracked = true };
}

/// Test shorthand for a path git already records as deleted (`D ` porcelain).
fn deleted(path: []const u8) git.ChangedPath {
    return .{ .path = path, .tracked = true, .staged_deletion = true };
}

// spec: Commit Hygiene - Leaves an already-staged deletion out of the git add path list

test "planStaging keeps a deleted path out of the add list without warning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The reported bug: one `D ` path (gone from worktree AND index) in the
    // change set made `git add -- <paths…>` exit 128 with `pathspec … did not
    // match any files`, so a whole green gate ended in "nothing committed".
    const changed = [_]git.ChangedPath{
        deleted("src/removed.zig"),
        tracked("src/keep.zig"),
        // A deletion under an always-include prefix is still un-addable.
        deleted(".guardian/baselines/gone.txt"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 2), plan.staged_deletions.len);
    // Not a skip: the deletion IS in the commit, so the loud warning stays quiet.
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
    // The success line names them, since they never appear in the add argv.
    try testing.expectEqualStrings(
        "1 path(s) staged, 2 already-staged deletion(s)",
        try stagedSummary(a, plan),
    );
}

// spec: Commit Hygiene - Commits an already-staged deletion when no path needs staging

test "commitAction commits a deletion-only change set and stops on an empty one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Deleting a file and nothing else is a real commit — "nothing to commit"
    // would silently drop the change the gate just verified.
    const only_deletion = try planStaging(a, &[_]git.ChangedPath{deleted("src/gone.zig")}, "SPEC.md", null);
    try testing.expectEqual(CommitAction.commit_already_staged, commitAction(only_deletion));
    // With something to add, the add step runs as before.
    const both = [_]git.ChangedPath{ deleted("src/gone.zig"), tracked("src/keep.zig") };
    const mixed = try planStaging(a, &both, "SPEC.md", null);
    try testing.expectEqual(CommitAction.stage_then_commit, commitAction(mixed));
    // Everything filtered out: still a no-op, and the tally omits deletions.
    const empty = try planStaging(a, &[_]git.ChangedPath{untracked(".env")}, "SPEC.md", null);
    try testing.expectEqual(CommitAction.nothing_to_commit, commitAction(empty));
    try testing.expectEqualStrings("0 path(s) staged", try stagedSummary(a, empty));
}

// spec: Commit Hygiene - Advises when the configured test command is not the whole default suite

test "testTier classifies the default suite, filtered tiers, and custom commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The default is the whole suite: no advisory, no noise on every commit.
    try testing.expectEqual(TestTier.whole_suite, testTier("zig build test"));
    try testing.expectEqual(TestTier.whole_suite, testTier("  zig   build\ttest "));
    // The reported case: `zig build test-fast` let two commits land on top of a
    // suite that no longer compiled, because a filtered build never analyzes the
    // tests it skipped.
    try testing.expectEqual(TestTier.filtered, testTier("zig build test-fast"));
    try testing.expectEqual(TestTier.filtered, testTier("zig build test -Dtest-filter=commit"));
    try testing.expectEqual(TestTier.filtered, testTier("zig build smoke"));
    // Anything else is unclassifiable — still advised, since guardian cannot
    // tell whether it covers the suite.
    try testing.expectEqual(TestTier.custom, testTier("make check"));
    // An `env NAME=VALUE …` prefix is how a project sets a variable for the
    // gate's run (this argv never reaches a shell), so it must not turn the
    // default suite into a `custom` command advised on every commit.
    try testing.expectEqual(TestTier.whole_suite, testTier("env GUARDIAN_TEST_MAX_WALL_SECS=120 zig build test"));
    try testing.expectEqual(TestTier.whole_suite, testTier("env A=1 B=2 zig build test"));
    // What env execs is still classified on its own merits.
    try testing.expectEqual(TestTier.filtered, testTier("env A=1 zig build test-fast"));
    try testing.expectEqual(TestTier.custom, testTier("env A=1 make check"));
    // A variable whose NAME contains a narrowing word is not a narrowed tier.
    try testing.expectEqual(TestTier.whole_suite, testTier("env RUN_FAST=1 zig build test"));
    // Only a leading literal `env` is a prefix, and only NAME=VALUE tokens
    // belong to it — anything else stays conservatively unclassifiable.
    try testing.expectEqual(TestTier.custom, testTier("envy zig build test"));
    try testing.expectEqual(TestTier.custom, testTier("env -u HOME zig build test"));
    try testing.expectEqual(TestTier.custom, testTier("env"));
    // The advisory names the command and the probe that closes the gap.
    const a = arena.allocator();
    const dir = "zig-cache/test-commit-tier";
    fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir);
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().writeFile(.{ .sub_path = dir ++ "/build.zig", .data = "pub fn build(b: *std.Build) void {}\n" });

    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const narrowed: config.Config = .{ .gate = .{ .test_command = "zig build test-fast" } };
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &narrowed, .quiet = true };
    try adviseTestTier(&ctx);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "test-fast") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, compile_probe_helper) != null);

    // The default tier says nothing at all.
    cap.buf.clearRetainingCapacity();
    const whole: config.Config = .{};
    ctx.cfg = &whole;
    try adviseTestTier(&ctx);
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

// spec: Commit Hygiene - Drops the compile-probe wiring instruction when build.zig already registers the step

test "the tier advisory stops telling a wired project to wire the probe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-commit-probe-wired";
    fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir);
    defer fs.cwd().deleteTree(dir) catch {};
    // The reported case: six commits in a worktree whose `zig build
    // test-compile` was wired AND had just passed were told to wire it.
    try fs.cwd().writeFile(.{
        .sub_path = dir ++ "/build.zig",
        .data = "    _ = guardian.addTestCompileProbe(b, .{ .root_module = test_mod });\n",
    });

    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const narrowed: config.Config = .{ .gate = .{ .test_command = "zig build test-fast" } };
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &narrowed, .quiet = true };
    try adviseTestTier(&ctx);
    // The note is still true — this tier does not prove the suite compiles —
    // so only the half that is false about this project is dropped.
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "test-fast") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "already registers") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, compile_probe_helper) == null);

    // A hand-declared step counts as wired; a build.zig that names neither does
    // not, and an unreadable one keeps the wiring instruction (the harmless
    // direction: advice a project may not need, never advice withheld).
    try testing.expect(declaresCompileProbe("const s = b.step(\"test-compile\", \"compile every test\");"));
    try testing.expect(!declaresCompileProbe("const s = b.step(\"test\", \"run tests\");"));
    try testing.expect(!try testCompileProbeWired(a, "zig-cache/no-such-project"));
    try testing.expect(std.mem.indexOf(u8, compileProbeFix(false), compile_probe_helper) != null);
}

// spec: Commit - Reports a gate and test timing split

test "formatTimingSplit renders one-decimal seconds for each phase" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1100 ms → 1.1s, 2300 ms → 2.3s (floored tenths).
    try testing.expectEqualStrings("gate 1.1s \u{00B7} tests 2.3s", try formatTimingSplit(a, 1100, 2300));
    // Sub-second and multi-second phases both render.
    try testing.expectEqualStrings("gate 0.7s \u{00B7} tests 32.0s", try formatTimingSplit(a, 770, 32_000));
}

// spec: Commit - Splits the configured test command into an argv vector

test "splitCommand tokenizes the configured test command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try splitCommand(a, "zig build test");
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("zig", argv[0]);
    try testing.expectEqualStrings("build", argv[1]);
    try testing.expectEqualStrings("test", argv[2]);
    // Extra whitespace collapses; a blank command yields an empty argv.
    const spaced = try splitCommand(a, "  zig   build\ttest  ");
    try testing.expectEqual(@as(usize, 3), spaced.len);
    try testing.expectEqual(@as(usize, 0), (try splitCommand(a, "   ")).len);
}

// spec: Test Filter - Leaves the commit gate running the whole configured test command

test "gateTestArgv runs the configured suite even when a test filter is configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A project that has configured the local `test-filter` report's flag.
    var cfg: config.Config = .{};
    cfg.test_filter.flag = "-Dtest-filter=";
    const argv = try gateTestArgv(a, &cfg);
    // The commit gate still spawns the whole suite: three tokens, none of them
    // a filter. There is no code path that appends one.
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("zig", argv[0]);
    try testing.expectEqualStrings("build", argv[1]);
    try testing.expectEqualStrings("test", argv[2]);

    // A project that narrows its own test_command gets exactly what it asked
    // for — guardian neither widens nor narrows the configured command.
    cfg.gate.test_command = "make check";
    const custom = try gateTestArgv(a, &cfg);
    try testing.expectEqual(@as(usize, 2), custom.len);
    try testing.expectEqualStrings("make", custom[0]);
    try testing.expectEqualStrings("check", custom[1]);
}

// spec: Commit - Excludes suffixed zig build cache directories from staging

test "planStaging skips suffixed zig cache dirs the exact-prefix rail missed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The mutation runner's isolated caches (.zig-cache-c, .zig-cache-rfaudit)
    // and zig-out are all build artifacts, never committed — only real source is.
    const changed = [_]git.ChangedPath{
        untracked(".zig-cache-c/o/deadbeef/app.o"),
        untracked(".zig-cache-rfaudit/h/xyz.bin"),
        untracked("zig-out/bin/app"),
        untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 3), plan.skipped.len);
}

// spec: Commit - Excludes untracked agent session-state directories from staging

test "planStaging skips agent session dirs but stages a tracked one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        // The exact entry a real commit swept in, plus its sibling agent dir.
        untracked(".codex/worktrees/embed-cache-integrity"),
        untracked(".claude/settings.local.json"),
        // A project that deliberately tracks its agent config keeps it: the
        // rail only ever drops UNtracked paths.
        tracked(".claude/settings.json"),
        untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 2), plan.stage.len);
    try testing.expectEqualStrings(".claude/settings.json", plan.stage[0]);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[1]);
    // Both untracked session paths are reported, never silently dropped.
    try testing.expectEqual(@as(usize, 2), plan.skipped.len);
    // A same-named file outside a session dir is ordinary source, not scratch.
    try testing.expect(!isSessionStatePath("src/.codex/x"));
    try testing.expect(!isSessionStatePath(".codexrc/x"));
}

// spec: Commit - Excludes its own generated pre-commit hook from staging

test "planStaging drops the managed hook silently and warns for everything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        // ensure() wrote this moments earlier; it embeds a machine-specific
        // absolute binary path, so it must never enter history.
        untracked(".githooks/pre-commit"),
        untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", ".githooks/pre-commit");
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    // Silent: warning on the file guardian itself writes would fire every commit.
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
    // A tracked hook is the author's deliberate choice — dropping it would
    // desync the commit from the gated tree, so the rail leaves it alone.
    const tracked_hook = [_]git.ChangedPath{tracked(".githooks/pre-commit")};
    const kept = try planStaging(a, &tracked_hook, "SPEC.md", ".githooks/pre-commit");
    try testing.expectEqual(@as(usize, 1), kept.stage.len);
    // With no resolvable hook path there is nothing to exclude.
    try testing.expect(!isGeneratedHook(".githooks/pre-commit", null));
    // Only the exact hook file is dropped, not its neighbors in the same dir.
    try testing.expect(!isGeneratedHook(".githooks/post-checkout", ".githooks/pre-commit"));
}

// spec: Commit - Excludes untracked secret and build-artifact paths from staging

test "planStaging skips untracked secrets and build artifacts, keeps ordinary source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        untracked(".env"),                 untracked("config/.env.local"),
        untracked("certs/server.pem"),     untracked("deploy/id_rsa"),
        untracked("aws_credentials.json"), untracked("zig-out/bin/app"),
        untracked(".zig-cache/x.o"),       untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    // Only the ordinary source file is staged; the seven risky paths are skipped.
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 7), plan.skipped.len);
}

// spec: Commit - Never skips an already-tracked path

test "planStaging stages every tracked path even with a secret-like name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Tracked paths were deliberately added to the repo; skipping their changes
    // would produce a commit that doesn't match the tree the gate verified.
    const changed = [_]git.ChangedPath{
        tracked("src/server/store/credentials.zig"),
        tracked("certs/server.pem"),
        tracked(".env"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 3), plan.stage.len);
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
}

// spec: Commit - Never skips a Zig source file for a secret-like name

test "planStaging keeps an untracked credentials.zig but skips credentials.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The fuzzy name heuristic must not eat source modules the gate just
    // compiled and tested — only data-shaped files stay behind the rail.
    const changed = [_]git.ChangedPath{
        untracked("src/server/store/credentials.zig"),
        untracked("src/auth/secret_box.zig"),
        untracked("credentials.json"),
        untracked("notes/secret-plan.md"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 2), plan.stage.len);
    try testing.expectEqualStrings("src/server/store/credentials.zig", plan.stage[0]);
    try testing.expectEqualStrings("src/auth/secret_box.zig", plan.stage[1]);
    try testing.expectEqual(@as(usize, 2), plan.skipped.len);
}

// spec: Commit - Skips secret-like names regardless of letter case

test "planStaging skips capitalized secret names like Credentials.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The forbidden filter compares names case-insensitively: a capitalized
    // Credentials.json is as much a secret as a lowercase one, and the .zig
    // source exemption holds for a capitalized module name too.
    const changed = [_]git.ChangedPath{
        untracked("Credentials.json"), untracked("notes/Secret.txt"),
        untracked(".ENV"),             untracked("certs/Server.PEM"),
        untracked("deploy/ID_RSA"),    untracked("src/Credentials.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/Credentials.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 5), plan.skipped.len);
}

// spec: Commit - Warns loudly listing every skipped path

test "warnSkipped names every skipped path and stays silent on none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cap: reporter.Capture = .{ .allocator = arena.allocator() };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    warnSkipped(&.{ "credentials.json", ".env" });
    // The header goes through the failure channel (shown even in quiet mode)
    // and every skipped path is listed by name.
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "WARNING") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "credentials.json") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, ".env") != null);

    cap.buf.clearRetainingCapacity();
    warnSkipped(&.{});
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

// spec: Commit - Always stages guardian metadata and the spec file

test "planStaging always includes guardian and spec even against the forbidden filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        untracked(".guardian/baselines/spec.txt"), tracked("SPEC.md"),
        tracked("src/x.zig"), untracked(".guardian/secret-notes.txt"), // 'secret' but under .guardian → still staged
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 4), plan.stage.len);
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
}

// spec: Commit - Never stages the git-ignored guardian cache directory

test "planStaging skips the guardian cache tree while keeping real metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // .guardian/cache/ is git-ignored operational state (a swept-in cache dir is
    // the 4.5 bug); it must be dropped silently even though it sits under the
    // always-include `.guardian/` prefix — while a real baseline still stages.
    const changed = [_]git.ChangedPath{
        untracked(".guardian/cache/inputs.sha256"),
        untracked(".guardian/cache/last-run.jsonl"),
        untracked(".guardian/baselines/spec.txt"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings(".guardian/baselines/spec.txt", plan.stage[0]);
    // Silent drop (git-ignored guardian output), so no skip warning fires.
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
    // A file literally named "cache" one level up is ordinary source, not the tree.
    try testing.expect(!isGuardianCache(".guardian/cache-notes.txt"));
    try testing.expect(isGuardianCache(".guardian/cache/x"));
}

// spec: Commit - Reports nothing to commit when no eligible paths remain

test "planStaging yields an empty stage set when every change is forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{ untracked(".env"), untracked("zig-out/bin/app") };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 0), plan.stage.len);
    try testing.expectEqual(@as(usize, 2), plan.skipped.len);
}
