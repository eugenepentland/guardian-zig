const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");
const baseline = @import("../baseline.zig");
const ast_index = @import("../ast/index.zig");
const cache = @import("../cache.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const print = std.debug.print;
const fail = reporter.fail;

pub const COMMAND_NAME = "all";
const SKIP = [_][]const u8{"spec-init"};

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

    // Skip the whole run when guardian's hashed input set is unchanged since
    // the last all-green run. GUARDIAN_UPDATE_SNAPSHOT forces a full run.
    const cache_state = cacheState(ctx);
    if (cache_state.skip) {
        reporter.ok("run-all: inputs unchanged since last green run — checks skipped", .{});
        return;
    }

    // Build the shared parsed-source index once if any check needs it, so
    // the ~17 AST checks read and parse each file once instead of per check.
    var index_storage: ast_index.Index = undefined;
    if (anyNeedsAst(ctx.cfg.disabled)) {
        index_storage = try ast_index.build(ctx.allocator, ctx.project_dir, ctx.cfg.exclude);
        ctx.source_index = &index_storage;
    }

    var ran: u32 = 0;
    const failed = try runChecks(ctx, &ran);

    if (failed == 0) {
        reporter.ok("run-all: {d} check(s) passed", .{ran});
        // Record this green input state so an unchanged re-run can skip.
        if (cache_state.digest) |d| cache.writeStored(ctx.allocator, ctx.project_dir, d);
        return;
    }

    fail("run-all: {d}/{d} check(s) failed", .{ failed, ran });
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

/// Digest for the current input set plus whether an unchanged re-run may skip.
const CacheState = struct { digest: ?cache.Digest = null, skip: bool = false };

/// Computes this run's input digest and whether it matches the last green run.
fn cacheState(ctx: *types.RunCtx) CacheState {
    const force_update = snapshot_helper.shouldUpdate(ctx.allocator);
    if (!ctx.cfg.cache_enabled or force_update) return .{};
    const d = cache.inputDigest(ctx.allocator, ctx.project_dir, ctx.cfg.spec_file) catch {
        return .{};
    };
    const stored = cache.readStored(ctx.allocator, ctx.project_dir);
    const skip = if (stored) |s| cache.eql(s, d) else false;
    return .{ .digest = d, .skip = skip };
}

/// One check's outcome + captured output, filled by the worker that ran it.
const CheckResult = struct {
    ran: bool = false,
    failed: bool = false,
    err: ?anyerror = null,
    output: []const u8 = "",
};

/// Shared handle passed to each worker thread.
const WorkerJob = struct {
    base: *types.RunCtx,
    arena: *std.heap.ArenaAllocator,
    next: *usize,
    results: []CheckResult,
};

/// Runs every non-skipped check, tallying how many ran (into `ran`) and
/// returning how many failed. Parallel across worker threads when enabled and
/// multiple cores exist; a single core (or `parallel = false`) runs sequentially.
/// Propagates the first non-CheckFailed error.
fn runChecks(ctx: *types.RunCtx, ran: *u32) types.RunError!u32 {
    const workers = if (ctx.cfg.parallel) threadCount() else 1;
    if (workers <= 1) return runChecksSequential(ctx, ran);
    return runChecksParallel(ctx, ran, workers);
}

/// Usable worker count: one per core, capped at the number of checks.
fn threadCount() usize {
    const cpus = std.Thread.getCpuCount() catch return 1;
    return @max(@min(cpus, registry.all.len), 1);
}

/// Sequential fallback: run each check in this thread with live output.
fn runChecksSequential(ctx: *types.RunCtx, ran: *u32) types.RunError!u32 {
    const baseline_on = ctx.cfg.baseline.enabled;
    var failed: u32 = 0;
    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name, ctx.cfg.disabled)) continue;
        ran.* += 1;
        const outcome = if (baseline_on)
            baseline.runWithBaseline(ctx, cmd)
        else
            cmd.run(ctx);
        outcome catch |e| switch (e) {
            error.CheckFailed => failed += 1,
            else => return e,
        };
    }
    return failed;
}

/// Parallel path: each check is claimed via an atomic counter and run into a
/// per-worker arena with a per-check output capture. The main thread replays
/// output in registry order afterward — deterministic despite concurrency.
fn runChecksParallel(ctx: *types.RunCtx, ran: *u32, workers: usize) types.RunError!u32 {
    const a = ctx.allocator;
    const results = try a.alloc(CheckResult, registry.all.len);
    for (results) |*r| r.* = .{};

    const arenas = try a.alloc(std.heap.ArenaAllocator, workers);
    // allocator-ok: page_allocator is thread-safe and each worker owns a private arena
    for (arenas) |*ar| ar.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer for (arenas) |*ar| ar.deinit();

    const spawned = try spawnAndJoin(ctx, arenas, results);
    if (spawned == 0) return runChecksSequential(ctx, ran); // threads unsupported
    return emitAndTally(ctx, results, ran);
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
        if (shouldSkip(cmd.name, job.base.cfg.disabled)) continue;
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
    return res;
}

/// Replays each ran check's captured output in registry order and tallies
/// pass/fail. Quiet mode prints only failures. The first non-CheckFailed error
/// (if any) is propagated after all output is shown.
fn emitAndTally(ctx: *types.RunCtx, results: []CheckResult, ran: *u32) types.RunError!u32 {
    var failed: u32 = 0;
    var first_err: ?anyerror = null;
    for (results) |r| {
        if (!r.ran) continue;
        ran.* += 1;
        if (r.failed) failed += 1;
        if (r.err) |e| {
            if (first_err == null) first_err = e;
        }
        if (shouldEmit(ctx.quiet, r)) print("{s}", .{r.output});
    }
    if (first_err) |e| return e;
    return failed;
}

/// A captured check's output is replayed when it has content and either we're
/// not quiet or the check failed (mirrors the live reporter's quiet behavior).
fn shouldEmit(quiet: bool, r: CheckResult) bool {
    return r.output.len > 0 and (!quiet or r.failed);
}

fn shouldSkip(name: []const u8, disabled: []const []const u8) bool {
    for (SKIP) |s| if (std.mem.eql(u8, name, s)) return true;
    for (disabled) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// True when at least one non-skipped check declares `needs_ast = .yes`,
/// meaning the shared parsed-source index is worth building for this run.
fn anyNeedsAst(disabled: []const []const u8) bool {
    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name, disabled)) continue;
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
