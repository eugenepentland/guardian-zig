//! The `all` command — the whole-suite runner. Loads config, honors the skip-
//! cache and `--only`/`--skip` filters, builds the shared AST index once when
//! any to-run check needs it, invokes each check, and aggregates pass/fail plus
//! the machine-readable JSONL sinks. A filtered run never writes the green
//! skip-cache stamp (it isn't the full suite).

const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");
const baseline = @import("../baseline.zig");
const ast_index = @import("../ast/index.zig");
const cache = @import("../cache.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const sink = @import("../sink.zig");
const dora = @import("../dora.zig");

const print = std.debug.print;
const fail = reporter.fail;

pub const command_name = "all";
// spec-init is a generator; mutate rebuilds and re-tests the project per
// mutant; debt is a non-gating report; nightly composes `all` + `mutate --full`;
// commit gates then auto-commits. None is a build gate. (nightly and commit are
// dispatched specially and never appear in the registry, so their entries here
// are defensive — mirroring the long-standing `all` exclusion in build_helper —
// and guarantee they can never be run as a check.)
const non_gate_commands = [_][]const u8{ "spec-init", "mutate", "debt", "nightly", "commit" };

/// Runs every registered hard-block check in this process (in parallel across
/// worker threads by default; see `runChecks`). Continues past failures so the
/// user sees every failing check at once; returns error.CheckFailed if any
/// check failed. Output is replayed in registry order, so a parallel run is
/// byte-for-byte deterministic.
///
/// When `cfg.baseline.enabled = true`, each check is run with output
/// captured: the first run records current violations into
/// `.guardian/baselines/<check>.txt` and reports success; subsequent
/// runs only fail when new violations appear above the baseline.
///
/// Skips `spec-init` (a generator, not a gate). The `all` command itself
/// is dispatched outside the registry, so it never recurses.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    // Validate the disabled list up front: a typo like "magic-numbers" would
    // otherwise silently disable nothing while the user believes it's off.
    try validateDisabled(ctx.cfg.disabled);
    // Validate --only / --skip the same way: an unknown or non-gate name must
    // hard-fail rather than silently narrow the run to nothing.
    try validateFilter(ctx);
    // Validate GUARDIAN_UPDATE_SNAPSHOT targets + [baseline] deny_growth names,
    // so a typo can't silently refresh nothing / guard nothing.
    try validateSelectiveConfig(ctx);

    // A filtered run (--only/--skip) is a subset, not the full suite, so it
    // must neither trust nor write the green skip-cache — recording green from
    // a partial run would mask a failure in the checks it didn't run.
    const filtered = isFiltered(ctx);
    if (!filtered and shouldSkipRun(ctx)) {
        reporter.ok("run-all: inputs unchanged since last green run — checks skipped", .{});
        return;
    }

    // Build the shared parsed-source index once if any check needs it, so
    // the ~17 AST checks read and parse each file once instead of per check.
    var index_storage: ast_index.Index = undefined;
    if (anyNeedsAst(ctx)) {
        index_storage = try ast_index.build(ctx.allocator, ctx.project_dir, ctx.cfg.exclude);
        ctx.source_index = &index_storage;
    }
    // index_storage is stack-scoped; clear the ctx pointer on return so a caller
    // that reuses ctx afterward (nightly → mutate) can't dereference a dangling
    // index. Workers copy ctx before this fires, so the current run is unaffected.
    defer ctx.source_index = null;

    // Time the run for the DORA sink. Started here (after the cache-skip guard)
    // so a cache-skipped run — which returns above — records nothing.
    var stopwatch = dora.startStopwatch();
    var ran: u32 = 0;
    var acc: Sink = .{};
    const failed = try runChecks(ctx, &ran, &acc);

    // Write the machine-readable last-run log on every real run (green or red),
    // before the green/red branch. A skipped run (early return above) leaves the
    // last real run's log in place.
    writeSink(ctx, acc.records.items, ran, failed, filtered);
    // Append the DORA delivery-metrics record for this run (non-gating,
    // best-effort; a nightly run records once via this nested `all` pass).
    // Skipped for a filtered (--only/--skip) run: a partial dev iteration is
    // not a delivery event, and its outcome would misrepresent the stream —
    // the same reason a filtered run never stamps the green cache.
    if (!filtered) recordDora(ctx, &stopwatch, failed, acc.failed_checks.items);

    if (failed == 0) {
        reporter.ok("run-all: {d} check(s) passed", .{ran});
        // Stamp the POST-write tree so an unchanged next run can skip. Never for
        // a filtered run — a partial suite must not claim the full suite green.
        if (!filtered) stampGreen(ctx);
        return;
    }

    fail("run-all: {d}/{d} check(s) failed", .{ failed, ran });
    return error.CheckFailed;
}

/// Collects every check's findings across the run for the JSONL sink. Owned by
/// the run allocator so records outlive the per-worker arenas that produced them.
/// `failed_checks` is the distinct registry names that failed, for the DORA
/// telemetry record (names are static registry literals — no copy needed).
const Sink = struct {
    records: std.ArrayList(reporter.Violation) = .empty,
    failed_checks: std.ArrayList([]const u8) = .empty,
};

/// Writes the machine-readable last-run log for a real (non-skipped) run.
/// `skipped` is the registry entries that didn't execute this pass (built-in
/// non-gates, disabled, and filtered-out checks). Best-effort (never fails the
/// build) and always written — a green run yields a summary-only log.
fn writeSink(ctx: *types.RunCtx, records: []const reporter.Violation, ran: u32, failed: u32, filtered: bool) void {
    const total_checks: u32 = @intCast(registry.all.len);
    sink.write(ctx.allocator, ctx.project_dir, records, .{
        .passed = ran - failed,
        .failed = failed,
        .skipped = total_checks - ran,
        .filtered = filtered,
    });
}

/// Appends the DORA delivery-metrics record for a real (non-skipped) run:
/// outcome, the failed-check names, and wall-clock duration. Non-gating and
/// best-effort — `dora.recordRun` swallows a disabled sink or an I/O failure.
fn recordDora(ctx: *types.RunCtx, stopwatch: *dora.Stopwatch, failed: u32, failed_checks: []const []const u8) void {
    const outcome: dora.Outcome = if (failed == 0) .green else .red;
    dora.recordRun(ctx.allocator, ctx.project_dir, ctx.cfg.dora, outcome, failed_checks, stopwatch.elapsedMs());
}

/// True when an --only / --skip selection is active for this run.
fn isFiltered(ctx: *const types.RunCtx) bool {
    return ctx.only.len > 0 or ctx.skip.len > 0;
}

/// True when `name` is a check that `all` actually runs: a registered command
/// that isn't a built-in non-gate (spec-init / mutate / nightly). Used to
/// validate --only / --skip names before running.
pub fn isAllCheck(name: []const u8) bool {
    if (registry.find(name) == null) return false;
    for (non_gate_commands) |s| if (std.mem.eql(u8, name, s)) return false;
    return true;
}

/// Fails the run when --only or --skip names a check that `all` does not run
/// (unknown, or a non-gate like `mutate`). Mirrors validateDisabled so a typo
/// can't silently narrow the suite to nothing.
fn validateFilter(ctx: *const types.RunCtx) types.RunError!void {
    for (ctx.only) |name| try requireAllCheck(name, "--only");
    for (ctx.skip) |name| try requireAllCheck(name, "--skip");
}

fn requireAllCheck(name: []const u8, flag: []const u8) types.RunError!void {
    if (isAllCheck(name)) return;
    fail("unknown check name in {s}: {s}", .{ flag, name });
    fail("  run `guardian-check explain` to list valid check names", .{});
    return error.CheckFailed;
}

/// A check removed by a merge/fold. Its name is still tolerated in `disabled`
/// (and silently ignored) so a consumer's guardian.toml — and any leftover
/// baseline/snapshot file — doesn't break the build when a check is folded into
/// another. `[[allow]]` entries for a retired name are already inert (nothing
/// looks them up). Guardian emits a one-line migration notice instead.
const RetiredCheck = struct { name: []const u8, folded_into: []const u8 };
const retired = [_]RetiredCheck{
    .{ .name = "spec-drift", .folded_into = "pub-api-surface" },
    .{ .name = "comptime-quota", .folded_into = "panic-budget" },
    .{ .name = "doc-quality", .folded_into = "doc-comments" },
    .{ .name = "vague-name-blacklist", .folded_into = "naming" },
    .{ .name = "dup-const", .folded_into = "repeated-string-literal" },
    // Retired as purely stylistic: it punished idiomatic early-return dispatch
    // and duplicated what cognitive-complexity already scores.
    .{ .name = "returns-per-function", .folded_into = "cognitive-complexity" },
};

fn retiredInfo(name: []const u8) ?RetiredCheck {
    for (retired) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// Fails the run when the `disabled` config names a check that doesn't exist,
/// except for retired names (folded into another check), which are tolerated
/// with a migration notice so folds don't break downstream config.
fn validateDisabled(disabled: []const []const u8) types.RunError!void {
    for (disabled) |name| {
        if (registry.find(name) != null) continue;
        if (retiredInfo(name)) |r| {
            reporter.ok("note: '{s}' is retired (folded into {s})", .{ r.name, r.folded_into });
            continue;
        }
        fail("unknown check name in `disabled`: {s}", .{name});
        return error.CheckFailed;
    }
}

/// Validates GUARDIAN_UPDATE_SNAPSHOT named targets and [baseline] deny_growth
/// names against the registry, hard-failing on a typo (mirrors validateDisabled
/// / validateFilter). Exported so single-check dispatch validates them too.
pub fn validateSelectiveConfig(ctx: *const types.RunCtx) types.RunError!void {
    try validateRefreshTargets(ctx.allocator);
    try validateDenyGrowth(ctx.cfg.baseline.deny_growth);
}

/// Rejects a GUARDIAN_UPDATE_SNAPSHOT check-name list with an unknown name —
/// a typo must hard-fail, not silently refresh nothing. No-op in the none/all
/// modes (refreshTargets returns null).
fn validateRefreshTargets(allocator: std.mem.Allocator) types.RunError!void {
    const names = snapshot_helper.refreshTargets(allocator) orelse return;
    for (names) |name| try requireKnownCheck(name, snapshot_helper.update_env);
}

/// Rejects a [baseline] deny_growth list with an unknown check name.
fn validateDenyGrowth(names: []const []const u8) types.RunError!void {
    for (names) |name| try requireKnownCheck(name, "[baseline] deny_growth");
}

/// Fails the run when `name` is neither a registered check nor a tolerated
/// retired (folded) name; `origin` names the setting for the diagnostic.
fn requireKnownCheck(name: []const u8, origin: []const u8) types.RunError!void {
    if (registry.find(name) != null) return;
    if (retiredInfo(name)) |r| {
        reporter.ok("note: '{s}' is retired (folded into {s})", .{ r.name, r.folded_into });
        return;
    }
    fail("unknown check name in {s}: {s}", .{ origin, name });
    fail("  run `guardian-check explain` to list valid check names", .{});
    return error.CheckFailed;
}

/// Whether an unchanged re-run may skip the whole suite, and — separately —
/// the post-run stamp so a green run records its final input state.
///
/// The stamp is recomputed AFTER checks finish (see `stampGreen`), never reused
/// from the skip check: a green run can rewrite `.guardian/` (auto-pruned
/// baselines, freshly created/refreshed snapshots), so the pre-run digest would
/// describe a tree state that is no longer on disk — storing it would force a
/// spurious re-run next build (and, if that stale state were ever restored,
/// wrongly skip it).
fn shouldSkipRun(ctx: *types.RunCtx) bool {
    const enabled = ctx.cfg.cache_enabled;
    const refresh = snapshot_helper.shouldUpdate(ctx.allocator);
    // Only pay for the digest walk when a skip is still possible (cache on, no
    // refresh) — the `and` short-circuits otherwise.
    const digest_matches = enabled and !refresh and digestMatchesStored(ctx);
    return skipDecision(enabled, refresh, digest_matches);
}

/// True when the current input digest equals the last green run's stored digest.
fn digestMatchesStored(ctx: *types.RunCtx) bool {
    const d = cache.inputDigest(ctx.allocator, ctx.project_dir, ctx.cfg.spec_file) catch return false;
    // Any failure to read the stored digest (OOM or absent) means "can't confirm
    // a match" — run the full suite (fail closed), never skip.
    const stored = (cache.readStored(ctx.allocator, ctx.project_dir) catch return false) orelse return false;
    return cache.eql(stored, d);
}

/// Records the current (post-check) input digest as the last green state, so an
/// unchanged next run can skip. Recomputes the digest now — after checks may
/// have written `.guardian/` — so the stamp always reflects the tree on disk.
/// Best-effort: a disabled cache or a digest/write failure simply skips the
/// stamp (never fails the build).
fn stampGreen(ctx: *types.RunCtx) void {
    if (!ctx.cfg.cache_enabled) return;
    const d = cache.inputDigest(ctx.allocator, ctx.project_dir, ctx.cfg.spec_file) catch return;
    cache.writeStored(ctx.allocator, ctx.project_dir, d);
}

/// Pure skip decision, factored out for testing: a run skips only when the
/// cache is enabled, no refresh was requested, and the input digest matches the
/// stored green digest. A refresh (or a digest mismatch) always executes fully.
fn skipDecision(cache_enabled: bool, refresh_requested: bool, digest_matches: bool) bool {
    return cache_enabled and !refresh_requested and digest_matches;
}

/// One check's outcome + captured output, filled by the worker that ran it.
/// `records` are the structured Violations the check emitted (empty for an
/// unmigrated check, whose findings are scraped from `output` instead).
const CheckResult = struct {
    ran: bool = false,
    failed: bool = false,
    err: ?types.RunError = null,
    output: []const u8 = "",
    records: []const reporter.Violation = &.{},
};

/// Shared handle passed to each worker thread.
const WorkerJob = struct {
    base: *types.RunCtx,
    arena: *std.heap.ArenaAllocator,
    next: *usize,
    results: []CheckResult,
};

/// Runs every non-skipped check into `results` (parallel across worker threads
/// when enabled and multi-core, else sequentially in this thread), then replays
/// captured output in registry order and tallies. Each check's findings are
/// gathered into `acc` for the JSONL sink. Returns how many failed; propagates
/// the first non-CheckFailed error. Output is deterministic (registry order)
/// regardless of the path taken.
fn runChecks(ctx: *types.RunCtx, ran: *u32, acc: *Sink) types.RunError!u32 {
    const results = try ctx.allocator.alloc(CheckResult, registry.all.len);
    for (results) |*r| r.* = .{};

    const workers = if (ctx.cfg.parallel) threadCount() else 1;
    if (workers > 1) {
        const arenas = try ctx.allocator.alloc(std.heap.ArenaAllocator, workers);
        // allocator-ok: page_allocator is thread-safe and each worker owns a private arena
        for (arenas) |*ar| ar.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // Deinit runs after emitAndTally (which copies worker-arena records into
        // the run allocator for `acc`), so the sink never reads freed memory.
        defer for (arenas) |*ar| ar.deinit();
        if (try spawnAndJoin(ctx, arenas, results) > 0)
            return emitAndTally(ctx, results, ran, acc);
        // Threads unsupported: fall through to the sequential fill.
    }
    fillSequential(ctx, results);
    return emitAndTally(ctx, results, ran, acc);
}

/// Usable worker count: one per core, capped at the number of checks.
fn threadCount() usize {
    const cpus = std.Thread.getCpuCount() catch return 1;
    return @max(@min(cpus, registry.all.len), 1);
}

/// Sequential fill: run each non-excluded check in this thread with its own
/// capture (over the run allocator), for replay by emitAndTally. Used when
/// parallelism is off, on a single core, or when thread spawn is unsupported.
fn fillSequential(ctx: *types.RunCtx, results: []CheckResult) void {
    const baseline_on = ctx.cfg.baseline.enabled;
    for (registry.all, 0..) |cmd, i| {
        if (excluded(ctx, cmd.name)) continue;
        results[i] = runCaptured(ctx, ctx.allocator, cmd, baseline_on);
    }
}

/// Spawns one worker per arena (fewer if `spawn` is unsupported), each draining
/// the shared atomic work counter, then joins them. Returns the count spawned.
fn spawnAndJoin(ctx: *types.RunCtx, arenas: []std.heap.ArenaAllocator, results: []CheckResult) !usize {
    const a = ctx.allocator;
    const jobs = try a.alloc(WorkerJob, arenas.len);
    const threads = try a.alloc(std.Thread, arenas.len);
    var next: usize = 0;
    var spawned: usize = 0;
    for (arenas, 0..) |*ar, t| {
        jobs[t] = .{ .base = ctx, .arena = ar, .next = &next, .results = results };
        threads[t] = std.Thread.spawn(.{}, worker, .{&jobs[t]}) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |th| th.join();
    return spawned;
}

/// Worker loop: claim check indices atomically until exhausted, running each
/// into this thread's own arena + capture. Skipped checks leave `ran = false`.
fn worker(job: *WorkerJob) void {
    const a = job.arena.allocator();
    const baseline_on = job.base.cfg.baseline.enabled;
    // This thread's reporter; per-check output is captured, replayed by main.
    reporter.default = .{ .quiet = job.base.quiet, .use_color = false };
    while (true) {
        const i = @atomicRmw(usize, job.next, .Add, 1, .monotonic);
        if (i >= registry.all.len) break;
        const cmd = registry.all[i];
        if (excluded(job.base, cmd.name)) continue;
        job.results[i] = runCaptured(job.base, a, cmd, baseline_on);
    }
}

/// Runs one check into a fresh capture over the worker's allocator, returning
/// its result. A copied RunCtx carries the per-worker allocator so no check
/// allocates through the shared arena.
fn runCaptured(base: *types.RunCtx, a: std.mem.Allocator, cmd: types.Command, baseline_on: bool) CheckResult {
    var cap: reporter.Capture = .{ .allocator = a };
    reporter.default.capture = &cap;
    defer reporter.default.capture = null;

    var wctx = base.*;
    wctx.allocator = a;

    var res: CheckResult = .{ .ran = true };
    const outcome = if (baseline_on) baseline.runWithBaseline(&wctx, cmd) else cmd.run(&wctx);
    outcome catch |e| switch (e) {
        error.CheckFailed => res.failed = true,
        else => {
            res.failed = true;
            res.err = e;
        },
    };
    res.output = cap.buf.items;
    res.records = cap.records.items;
    return res;
}

/// Replays each ran check's captured output in registry order and tallies
/// pass/fail, gathering findings into `acc` for the JSONL sink. Quiet mode
/// prints only failures. The first non-CheckFailed error (if any) is propagated
/// after all output is shown. Single-threaded (main), so the sink append is
/// race-free even though checks ran in parallel.
fn emitAndTally(ctx: *types.RunCtx, results: []CheckResult, ran: *u32, acc: *Sink) types.RunError!u32 {
    var failed: u32 = 0;
    var first_err: ?types.RunError = null;
    for (results, registry.all) |r, cmd| {
        if (!r.ran) continue;
        ran.* += 1;
        if (r.failed) {
            failed += 1;
            // Best-effort: a dropped name only omits one entry from telemetry.
            acc.failed_checks.append(ctx.allocator, cmd.name) catch |e|
                std.log.warn("guardian: dropped a failed-check telemetry note: {s}", .{@errorName(e)});
        }
        if (r.err) |e| {
            if (first_err == null) first_err = e;
        }
        if (shouldEmit(ctx.quiet, r)) print("{s}", .{r.output});
        collectSink(ctx, acc, cmd.name, r);
    }
    if (first_err) |e| return e;
    return failed;
}

/// Adds a check's findings to the JSONL sink accumulator: its structured
/// records when migrated (each string copied into the run allocator so it
/// outlives the worker arena), else the scraped violation lines tagged with the
/// check name. Best-effort — a copy/append OOM drops the record, never fails.
fn collectSink(ctx: *types.RunCtx, acc: *Sink, check_name: []const u8, r: CheckResult) void {
    if (r.records.len > 0) {
        // Best-effort telemetry: a dropped sink record is logged, not swallowed
        // silently, and never fails the gate (the check's own verdict already
        // stands). log is fine here — cli/ is exempt from debug-print-ban.
        for (r.records) |v| acc.records.append(ctx.allocator, dupViolation(ctx.allocator, v)) catch |e|
            std.log.warn("guardian: dropped a sink record: {s}", .{@errorName(e)});
        return;
    }
    // Unmigrated check: scrape indented violation lines (baseline.extract shares
    // the same indentation rules), tagging each with the check name.
    const lines = baseline.extract(ctx.allocator, r.output) catch return;
    for (lines) |line| acc.records.append(ctx.allocator, .{ .check = check_name, .message = line }) catch |e|
        std.log.warn("guardian: dropped a sink record: {s}", .{@errorName(e)});
}

/// Copies a Violation's borrowed string fields into `a` so a record produced in
/// a per-worker arena survives that arena's deinit and can be serialized later.
fn dupViolation(a: std.mem.Allocator, v: reporter.Violation) reporter.Violation {
    return .{
        .check = a.dupe(u8, v.check) catch v.check,
        .file = dupOpt(a, v.file),
        .line = v.line,
        .message = a.dupe(u8, v.message) catch v.message,
        .fix_hint = dupOpt(a, v.fix_hint),
        .ratchet_key = dupOpt(a, v.ratchet_key),
        .metric = v.metric,
    };
}

fn dupOpt(a: std.mem.Allocator, s: ?[]const u8) ?[]const u8 {
    return if (s) |x| (a.dupe(u8, x) catch x) else null;
}

/// A captured check's output is replayed when it has content and either we're
/// not quiet or the check failed (mirrors the live reporter's quiet behavior).
fn shouldEmit(quiet: bool, r: CheckResult) bool {
    return r.output.len > 0 and (!quiet or r.failed);
}

fn shouldSkip(name: []const u8, disabled: []const []const u8) bool {
    for (non_gate_commands) |s| if (std.mem.eql(u8, name, s)) return true;
    for (disabled) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// True when `name` must not run this pass: a built-in non-gate or a disabled
/// check (shouldSkip), or filtered out by an active --only / --skip. With
/// --only, only the listed names run; --skip removes the listed names.
fn excluded(ctx: *const types.RunCtx, name: []const u8) bool {
    if (shouldSkip(name, ctx.cfg.disabled)) return true;
    if (ctx.only.len > 0) return !inList(ctx.only, name);
    return inList(ctx.skip, name);
}

/// True when at least one non-excluded check declares `needs_ast = .yes`,
/// meaning the shared parsed-source index is worth building for this run.
fn anyNeedsAst(ctx: *const types.RunCtx) bool {
    for (registry.all) |cmd| {
        if (excluded(ctx, cmd.name)) continue;
        if (cmd.needs_ast == .yes) return true;
    }
    return false;
}

// spec: Run All - Skips checks whose name appears in the disabled config list
// spec: Run All - Rejects unknown check names in the disabled list
// spec: Run All - Tolerates retired check names in the disabled list
// spec: Run All - Emits a captured check's output only when not quiet or it failed

test "shouldEmit gates captured output by quiet and failure" {
    // Passing check: shown live, suppressed under --quiet.
    try std.testing.expect(shouldEmit(false, .{ .ran = true, .output = "ok" }));
    try std.testing.expect(!shouldEmit(true, .{ .ran = true, .output = "ok" }));
    // Failing check: always shown, even under --quiet.
    try std.testing.expect(shouldEmit(true, .{ .ran = true, .failed = true, .output = "bad" }));
    // No captured output: nothing to replay.
    try std.testing.expect(!shouldEmit(false, .{ .ran = true, .output = "" }));
}

test "threadCount is at least one" {
    try std.testing.expect(threadCount() >= 1);
}

test "shouldSkip honors the disabled list and built-in skips" {
    try std.testing.expect(shouldSkip("magic-number", &.{"magic-number"}));
    try std.testing.expect(shouldSkip("spec-init", &.{}));
    try std.testing.expect(!shouldSkip("spec", &.{"magic-number"}));
}

test "disabled list entries must be real check names" {
    // A real check resolves; a typo does not.
    try std.testing.expect(registry.find("magic-number") != null);
    try std.testing.expect(registry.find("magic-numbers") == null);
}

test "retired check names are recognized (tolerated in disabled)" {
    // A retired name resolves via retiredInfo (so validate won't reject it),
    // and reports where it was folded; a genuine typo does not.
    try std.testing.expect(retiredInfo("spec-drift") != null);
    try std.testing.expectEqualStrings("pub-api-surface", retiredInfo("spec-drift").?.folded_into);
    try std.testing.expect(retiredInfo("not-a-real-check") == null);
}

const test_config = @import("../config.zig");

// spec: Run All - Runs only the checks named by an only filter
// spec: Run All - Excludes the checks named by a skip filter
// spec: Run All - Rejects an only or skip name that is not a runnable check
// spec: Run All - Detects a filtered run so the green cache stamp is suppressed

test "excluded runs only the names listed by an only filter" {
    const cfg: test_config.Config = .{};
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .only = &[_][]const u8{"spec"},
    };
    try std.testing.expect(!excluded(&ctx, "spec"));
    try std.testing.expect(excluded(&ctx, "file-size"));
    // built-in non-gates stay excluded regardless of the filter
    try std.testing.expect(excluded(&ctx, "mutate"));
}

test "excluded removes the names listed by a skip filter" {
    const cfg: test_config.Config = .{};
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .skip = &[_][]const u8{"file-size"},
    };
    try std.testing.expect(excluded(&ctx, "file-size"));
    try std.testing.expect(!excluded(&ctx, "spec"));
}

test "isAllCheck accepts gates and rejects non-gates and typos" {
    try std.testing.expect(isAllCheck("spec"));
    try std.testing.expect(isAllCheck("file-size"));
    try std.testing.expect(!isAllCheck("mutate")); // non-gate step
    try std.testing.expect(!isAllCheck("nightly")); // composed, not in registry
    try std.testing.expect(!isAllCheck("commit")); // gate+commit, not in registry
    try std.testing.expect(!isAllCheck("spec-init")); // generator
    try std.testing.expect(!isAllCheck("bogus")); // typo
}

test "isFiltered is true exactly when an only or skip selection is active" {
    const cfg: test_config.Config = .{};
    const base: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    try std.testing.expect(!isFiltered(&base));
    var only_ctx = base;
    only_ctx.only = &[_][]const u8{"spec"};
    try std.testing.expect(isFiltered(&only_ctx));
    var skip_ctx = base;
    skip_ctx.skip = &[_][]const u8{"spec"};
    try std.testing.expect(isFiltered(&skip_ctx));
}

// spec: Run All - Skips a full run only when the cache is on, unchanged, and no refresh is pending

test "skipDecision requires cache on, a digest match, and no pending refresh" {
    // The only skip case: cache enabled, no refresh, digest matches.
    try std.testing.expect(skipDecision(true, false, true));
    // A pending refresh always executes fully — it exists to rewrite snapshots,
    // and its post-write tree must be re-stamped, never skipped.
    try std.testing.expect(!skipDecision(true, true, true));
    // A changed source or .guardian/ tree (digest mismatch) re-runs — this is
    // what makes an auto-pruned baseline re-run instead of being masked.
    try std.testing.expect(!skipDecision(true, false, false));
    // A disabled cache never skips.
    try std.testing.expect(!skipDecision(false, false, true));
}

// spec: Run All - Rejects an unknown refresh target or deny_growth check name

test "validateDenyGrowth accepts real checks and rejects a typo" {
    // Capture so the expected failure diagnostics don't leak to the test log.
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    try validateDenyGrowth(&.{"spec"});
    try std.testing.expectError(error.CheckFailed, validateDenyGrowth(&.{"nonsense-check"}));
}
