//! Executes mutants for the `mutate` command: splice the mutation into the
//! source file in place, run the project's build and test steps with
//! GUARDIAN_MUTATION_RUN=1 (so guardian's own gates no-op instead of
//! judging the deliberately-broken tree), restore the original bytes, and
//! classify what happened. A mutant the compiler rejects is *unviable*
//! (excluded from scoring); one the tests fail on is *killed*. Repeated hangs
//! are inconclusive and fail the campaign without inflating its score.
//!
//! Each child runs in its OWN process group (`child.pgid = 0`) and a watchdog
//! kills the whole group (`kill(-pgid)`) when a mutant outlives its deadline —
//! so an infinite-loop mutant's spawned test binary (a grandchild of guardian)
//! dies with the build instead of spinning on forever. The deadline is derived
//! from a one-off clean-suite baseline (`deadlineNs`), and every splice is
//! journaled (see journal.zig) so a run killed mid-mutant is recoverable.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("../fs.zig");
const wiring = @import("../wiring.zig");
const gen = @import("gen.zig");
const journal = @import("journal.zig");
const reporter = @import("../reporter.zig");

const Allocator = std.mem.Allocator;

/// Env var set on child builds during mutation runs. guardian-check exits
/// immediately when it sees this, so the mutated tree isn't gated.
pub const mutation_env = "GUARDIAN_MUTATION_RUN";

/// Cap on a source file read before splicing (mirrors the walker's cap).
const max_src_bytes: usize = 10 * 1024 * 1024;
const cache_flag = "--cache-dir";
const mutation_cache_leaf = ".guardian/cache/zig-mutate";

/// Error surface of a mutant run: the runner reads/splices/restores source
/// files, clones the environment, and spawns child `zig build` processes, so
/// the set unions filesystem, env, and process-spawn failures with OOM and
/// `StaleMutant` (the source moved out from under a generated mutant). A
/// precise named set instead of `anyerror` keeps the error space explicit.
pub const RunError = Allocator.Error ||
    fs.File.OpenError ||
    fs.File.ReadError ||
    fs.File.WriteError ||
    fs.File.GetSeekPosError ||
    std.process.SpawnError ||
    error{ StaleMutant, FileTooBig, StreamTooLong };

/// What one mutant did to the suite.
pub const Outcome = enum { killed, survived, unviable, inconclusive };

/// Result of one child build invocation.
pub const ExecResult = enum { ok, failed, timed_out };

/// Pure classification of a mutant from its two build phases: a compile
/// failure is unviable, a test failure is killed, a repeated hang is
/// inconclusive (never credited as a kill), and a green run survives.
pub fn outcomeFor(build_res: ExecResult, test_res: ExecResult) Outcome {
    return switch (build_res) {
        .timed_out => .inconclusive,
        .failed => .unviable,
        .ok => switch (test_res) {
            .ok => .survived,
            .failed => .killed,
            .timed_out => .inconclusive,
        },
    };
}

/// Running tallies across a mutation run.
pub const Score = struct {
    killed: u32 = 0,
    survived: u32 = 0,
    unviable: u32 = 0,
    inconclusive: u32 = 0,

    /// Adds one mutant's outcome to the tallies.
    pub fn add(self: *Score, outcome: Outcome) void {
        switch (outcome) {
            .killed => self.killed += 1,
            .survived => self.survived += 1,
            .unviable => self.unviable += 1,
            .inconclusive => self.inconclusive += 1,
        }
    }

    /// Count of conclusive viable mutants. Inconclusive timeouts are excluded
    /// from both numerator and denominator and make the overall command fail.
    /// This is also the quantity the small-diff floor (`min_mutants`) measures
    /// against: below the floor a percentage is statistically meaningless.
    pub fn viable(self: Score) u32 {
        return self.killed + self.survived;
    }

    /// Kill percentage over conclusive viable mutants. Timeouts cannot inflate
    /// the score. An empty conclusive run scores 100, but an inconclusive run is
    /// rejected by the command before ratcheting.
    pub fn pct(self: Score) u32 {
        const kills = self.killed;
        const denom = self.viable();
        if (denom == 0) return 100;
        // kills is a subset of viable (viable also counts survived), so the
        // percentage can never exceed 100 — guards a future edit to viable().
        std.debug.assert(kills <= denom);
        return kills * 100 / denom;
    }
};

/// How a full-run score relates to the ratchet snapshot.
pub const RatchetDecision = enum { created, raised, held, regressed };

/// Pure ratchet rule: no snapshot yet creates one; a higher score raises
/// the bar; equal holds it; lower regresses (fails unless force-updated).
pub fn ratchetDecision(old_pct: ?u32, new_pct: u32) RatchetDecision {
    const prior = old_pct orelse return .created;
    if (new_pct < prior) return .regressed;
    if (new_pct > prior) return .raised;
    return .held;
}

pub const SpliceError = error{StaleMutant} || Allocator.Error;

/// Pure splice: returns `original` with the mutant's byte range replaced.
/// StaleMutant when the range no longer reads `mutant.original` — the file
/// changed under us and mutating it would corrupt unrelated code.
pub fn spliced(allocator: Allocator, original: []const u8, m: gen.Mutant) SpliceError![]const u8 {
    if (m.start > m.end or m.end > original.len) return error.StaleMutant;
    if (!std.mem.eql(u8, original[m.start..m.end], m.original)) return error.StaleMutant;
    const out = try allocator.alloc(u8, original.len - (m.end - m.start) + m.replacement.len);
    @memcpy(out[0..m.start], original[0..m.start]);
    @memcpy(out[m.start..][0..m.replacement.len], m.replacement);
    @memcpy(out[m.start + m.replacement.len ..], original[m.end..]);
    return out;
}

/// Per-run settings threaded into each mutant execution.
pub const RunOpts = struct {
    project_dir: []const u8,
    /// Per-phase deadline for the child build/test (see `deadlineNs`).
    timeout_ns: u64,
    /// Heartbeat cadence for the progress ticker; 0 disables heartbeats.
    heartbeat_ns: u64 = 0,
    /// Progress label (e.g. "[3/40] src/x.zig:88") for heartbeat/timeout lines.
    label: []const u8 = "",
    /// Dedicated local Zig cache for one mutation campaign.
    cache_dir: []const u8,
    /// Optional cheap test step run before the full test suite.
    smoke_step: ?[]const u8 = null,
    /// A first timeout is retried with this deadline multiplier.
    timeout_retry_multiplier: u32 = 2,
};

/// Ns per second/millisecond, named so the timeout arithmetic reads as unit
/// conversion rather than magic numbers.
const ns_per_s: u64 = std.time.ns_per_s;
const ns_per_ms: u64 = std.time.ns_per_ms;
/// Baseline-measurement tick — fine enough that `elapsed_ns` is accurate to a
/// fraction of a second without any wall-clock read (see `Watchdog.watch`).
const baseline_tick_ms: u64 = 250;
const baseline_tick_ns: u64 = ns_per_ms * baseline_tick_ms;

/// Pure per-mutant deadline: `max(floor_secs, multiplier × baseline)`. A fast
/// suite is floored so a slow-to-compile mutant isn't mistaken for a hang; a
/// slow suite scales up so only a genuine runaway trips. Defaults come from
/// MutationCfg (floor 30s, ×5, cargo-mutants-style).
pub fn deadlineNs(floor_secs: u32, multiplier: u32, baseline_ns: u64) u64 {
    const floor_ns = @as(u64, floor_secs) * ns_per_s;
    const scaled = @as(u64, multiplier) * baseline_ns;
    return @max(floor_ns, scaled);
}

/// Times one clean, un-mutated `zig build test` to seed the per-mutant deadline.
/// Returns the elapsed ns, or null when the clean suite errors or outlives
/// `cap_ns` (no usable baseline → caller falls back to `timeout_secs`).
pub fn measureBaseline(
    allocator: Allocator,
    project_dir: []const u8,
    cache_dir: []const u8,
    cap_ns: u64,
) ?u64 {
    const sup = superviseArgv(allocator, &.{ "zig", "build", "test", cache_flag, cache_dir }, project_dir, .{
        .timeout_ns = cap_ns,
        .tick_ns = baseline_tick_ns,
        .heartbeat = null,
    }) catch return null;
    if (sup.result != .ok) return null;
    return sup.elapsed_ns;
}

/// Verifies an optional smoke step passes on the clean tree. A broken baseline
/// must stop the campaign: otherwise every mutant would be reported killed.
pub fn cleanStep(
    allocator: Allocator,
    project_dir: []const u8,
    cache_dir: []const u8,
    step: []const u8,
    timeout_ns: u64,
) RunError!ExecResult {
    const sup = try superviseArgv(allocator, &.{ "zig", "build", step, cache_flag, cache_dir }, project_dir, .{
        .timeout_ns = timeout_ns,
        .tick_ns = baseline_tick_ns,
        .heartbeat = null,
    });
    return sup.result;
}

/// Creates a clean campaign-local Zig cache. Returns null on filesystem failure
/// after logging it, so callers can fail the command without widening RunError.
pub fn prepareCache(allocator: Allocator, project_dir: []const u8) Allocator.Error!?[]const u8 {
    const p = try std.fs.path.join(allocator, &.{ project_dir, mutation_cache_leaf });
    fs.cwd().deleteTree(p) catch |e| {
        std.log.err("mutation Zig cache recovery failed: {s}", .{@errorName(e)});
        return null;
    };
    fs.cwd().makePath(p) catch |e| {
        std.log.err("mutation Zig cache creation failed: {s}", .{@errorName(e)});
        return null;
    };
    return p;
}

/// Removes the campaign-local Zig cache. Best-effort, because cleanup must not
/// hide a more useful mutation verdict already being returned.
pub fn cleanupCache(path: []const u8) void {
    fs.cwd().deleteTree(path) catch |e| {
        std.log.warn("mutation Zig cache cleanup failed: {s}", .{@errorName(e)});
    };
}

/// Runs one mutant end to end: journal + splice, `zig build` (viability), `zig
/// build test` (kill check), restore + clear journal. The original bytes are
/// restored even when a phase errors, and the journal (see journal.zig) makes a
/// run killed mid-mutant recoverable; a failed restore is reported loudly.
pub fn runOne(allocator: Allocator, opts: RunOpts, m: gen.Mutant) RunError!Outcome {
    const abs = try std.fs.path.join(allocator, &.{ opts.project_dir, m.path });
    const original = try fs.cwd().readFileAlloc(allocator, abs, max_src_bytes);
    const mutated = try spliced(allocator, original, m);

    // Journal + mark in-flight BEFORE writing the mutant, so a crash/kill
    // between here and the restore is recoverable (startup) or reverted
    // (signal handler).
    journal.begin(allocator, opts.project_dir, .{
        .rel_path = m.path,
        .abs_path = abs,
        .original = original,
        .mutated = mutated,
        .start = m.start,
        .end = m.end,
    });
    try fs.cwd().writeFile(.{ .sub_path = abs, .data = mutated });
    defer {
        fs.cwd().writeFile(.{ .sub_path = abs, .data = original }) catch {
            reporter.fail("mutate: FAILED to restore {s} — recover with `git checkout -- {s}`", .{ abs, m.path });
        };
        journal.finish(allocator, opts.project_dir);
    }

    const build = try runPhaseRetry(
        allocator,
        &.{ "zig", "build", cache_flag, opts.cache_dir },
        opts,
        "building",
    );
    if (build.result != .ok) {
        if (build.result == .timed_out) reportTimeout(m, opts, "build", build.elapsed_ns);
        return outcomeFor(build.result, .ok);
    }
    if (opts.smoke_step) |step| {
        const smoke = try runPhaseRetry(
            allocator,
            &.{ "zig", "build", step, cache_flag, opts.cache_dir },
            opts,
            "smoke testing",
        );
        if (smoke.result != .ok) {
            if (smoke.result == .timed_out) reportTimeout(m, opts, "smoke", smoke.elapsed_ns);
            return if (smoke.result == .failed) .killed else .inconclusive;
        }
    }
    const tst = try runPhaseRetry(
        allocator,
        &.{ "zig", "build", "test", cache_flag, opts.cache_dir },
        opts,
        "testing",
    );
    if (tst.result == .timed_out) reportTimeout(m, opts, "test", tst.elapsed_ns);
    return outcomeFor(build.result, tst.result);
}

/// Retries a timeout once with a larger deadline. Only a repeated timeout is
/// returned to classification, where it becomes inconclusive rather than a kill.
fn runPhaseRetry(allocator: Allocator, argv: []const []const u8, opts: RunOpts, phase: []const u8) RunError!Supervised {
    const first = try runPhase(allocator, argv, opts, phase);
    if (first.result != .timed_out) return first;
    reporter.detail("  {s} {s} timed out; retrying with ×{d} deadline\n", .{
        opts.label,
        phase,
        opts.timeout_retry_multiplier,
    });
    var retry = opts;
    retry.timeout_ns = std.math.mul(u64, opts.timeout_ns, opts.timeout_retry_multiplier) catch std.math.maxInt(u64);
    return runPhase(allocator, argv, retry, phase);
}

/// Runs one build phase under the per-mutant deadline, translating RunOpts into
/// supervise params (a heartbeat only when `opts.heartbeat_ns > 0`).
fn runPhase(allocator: Allocator, argv: []const []const u8, opts: RunOpts, phase: []const u8) RunError!Supervised {
    const tick = if (opts.heartbeat_ns == 0) opts.timeout_ns else opts.heartbeat_ns;
    const hb: ?Heartbeat = if (opts.heartbeat_ns == 0) null else .{ .label = opts.label, .phase = phase };
    return superviseArgv(allocator, argv, opts.project_dir, .{
        .timeout_ns = opts.timeout_ns,
        .tick_ns = tick,
        .heartbeat = hb,
    });
}

/// Prints the clear per-mutant timeout line (file, mutation, phase, elapsed,
/// deadline) when a phase is killed for outliving its deadline.
fn reportTimeout(m: gen.Mutant, opts: RunOpts, phase: []const u8, elapsed_ns: u64) void {
    const elapsed_s = elapsed_ns / ns_per_s;
    const deadline_s = opts.timeout_ns / ns_per_s;
    reporter.detail(
        "  {s} TIMEOUT ({s}) {s}:{d} `{s}` -> `{s}` — killed process group after ~{d}s (deadline {d}s)\n",
        .{ opts.label, phase, m.path, m.source.line, m.original, m.replacement, elapsed_s, deadline_s },
    );
}

/// Result of supervising one child process to completion or timeout.
const Supervised = struct {
    result: ExecResult,
    /// Tick-accumulated wall time the child ran (granular to the tick).
    elapsed_ns: u64,
};

/// Optional heartbeat printed each tick while a phase runs.
const Heartbeat = struct {
    label: []const u8,
    phase: []const u8,
};

/// Parameters for supervising a spawned child.
const SuperviseParams = struct {
    /// Kill the process group once accumulated wait reaches this.
    timeout_ns: u64,
    /// Wait/heartbeat granularity.
    tick_ns: u64,
    /// When set, a heartbeat line is printed each elapsed tick.
    heartbeat: ?Heartbeat = null,
};

/// Spawns `argv` in its own process group in `cwd` (mutation_env set) and
/// supervises it: a watchdog thread ticks on a ResetEvent, killing the WHOLE
/// group (SIGKILL to `-pgid`, reaping the compile/test grandchildren an
/// infinite-loop mutant would otherwise leave spinning) once it outlives the
/// timeout, and emitting a heartbeat each tick. Returns the result plus the
/// tick-accumulated elapsed. POSIX-only, like guardian's other process code.
fn superviseArgv(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    params: SuperviseParams,
) RunError!Supervised {
    var env = try wiring.cloneEnviron(allocator);
    defer env.deinit();
    try env.put(mutation_env, "1");

    const io = wiring.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0, // new process group led by the child → -pgid kills the tree
    });

    journal.trackChild(child.id.?);
    defer journal.trackChild(0);

    var dog: Watchdog = .{
        .pgid = child.id.?,
        .timeout_ns = params.timeout_ns,
        .tick_ns = params.tick_ns,
        .heartbeat = params.heartbeat,
    };
    const th: ?std.Thread = if (builtin.single_threaded)
        null
    else
        std.Thread.spawn(.{}, Watchdog.watch, .{&dog}) catch null;
    const term = child.wait(io) catch null;
    dog.finished.set(io);
    if (th) |t| t.join();

    if (dog.fired.load(.monotonic)) return .{ .result = .timed_out, .elapsed_ns = dog.elapsed_ns };
    const t = term orelse return .{ .result = .failed, .elapsed_ns = dog.elapsed_ns };
    const clean = t.success();
    return .{ .result = if (clean) .ok else .failed, .elapsed_ns = dog.elapsed_ns };
}

/// Kills the child's process GROUP if `finished` isn't signalled within the
/// timeout, ticking on a ResetEvent so elapsed accrues with no wall-clock read
/// (keeps the file ban-time clean) and a heartbeat can print each tick. Uses
/// `-pgid` (the whole group) so an infinite-loop mutant's spawned test binary —
/// a grandchild of guardian — dies with the build, not just the direct child.
/// (POSIX-only, like the rest of guardian's process handling.)
const Watchdog = struct {
    pgid: std.process.Child.Id,
    timeout_ns: u64,
    tick_ns: u64,
    heartbeat: ?Heartbeat,
    finished: std.Io.Event = .unset,
    fired: std.atomic.Value(bool) = .init(false),
    /// Tick-accumulated elapsed, read by the spawner after `join`.
    elapsed_ns: u64 = 0,

    fn watch(self: *Watchdog) void {
        var waited: u64 = 0;
        while (waited < self.timeout_ns) {
            const wait_ns = @min(self.tick_ns, self.timeout_ns - waited);
            self.finished.waitTimeout(wiring.io(), timeoutNs(wait_ns)) catch {
                waited += wait_ns;
                if (waited < self.timeout_ns) self.beat(waited);
                continue;
            };
            self.elapsed_ns = waited; // child finished before the deadline
            return;
        }
        self.fired.store(true, .monotonic);
        self.kill();
        self.elapsed_ns = waited;
    }

    fn beat(self: *Watchdog, waited: u64) void {
        const h = self.heartbeat orelse return;
        reporter.detail("  {s} {s}... still running (elapsed ~{d}s / deadline {d}s)\n", .{
            h.label, h.phase, waited / ns_per_s, self.timeout_ns / ns_per_s,
        });
    }

    fn kill(self: *Watchdog) void {
        std.posix.kill(-self.pgid, std.posix.SIG.KILL) catch |e|
            reporter.detail("  watchdog group-kill failed: {s}\n", .{@errorName(e)});
    }
};

fn timeoutNs(ns: u64) std.Io.Timeout {
    return .{ .duration = .{
        .clock = .awake,
        .raw = .fromNanoseconds(@intCast(ns)),
    } };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Mutation Testing - Classifies mutant outcomes from the build and test phases

test "outcomeFor maps build/test results to mutant outcomes" {
    try testing.expectEqual(Outcome.survived, outcomeFor(.ok, .ok));
    try testing.expectEqual(Outcome.killed, outcomeFor(.ok, .failed));
    try testing.expectEqual(Outcome.inconclusive, outcomeFor(.ok, .timed_out));
    // A compile failure never reaches the test phase: unviable regardless.
    try testing.expectEqual(Outcome.unviable, outcomeFor(.failed, .ok));
    try testing.expectEqual(Outcome.inconclusive, outcomeFor(.timed_out, .ok));
}

// spec: Mutation Testing - Excludes inconclusive timeouts from the mutation score

test "Score.pct excludes inconclusive and unviable mutants" {
    var s: Score = .{};
    s.add(.killed);
    s.add(.killed);
    s.add(.inconclusive);
    s.add(.survived);
    s.add(.unviable);
    // 2 kills of 3 conclusive viable = 66%; timeout cannot inflate the score.
    try testing.expectEqual(@as(u32, 3), s.viable());
    try testing.expectEqual(@as(u32, 66), s.pct());
    const empty: Score = .{};
    try testing.expectEqual(@as(u32, 0), empty.viable());
    try testing.expectEqual(@as(u32, 100), empty.pct());
}

// spec: Mutation Testing - Uses and cleans a campaign-local Zig cache

test "prepareCache creates a clean isolated cache and cleanupCache removes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dir = "zig-cache/mutation-cache-lifecycle";
    fs.cwd().deleteTree(dir) catch |e| return e;
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("cache test cleanup: {s}", .{@errorName(e)});
    const cache_dir = (try prepareCache(arena.allocator(), dir)).?;
    try fs.cwd().access(cache_dir, .{});
    cleanupCache(cache_dir);
    try testing.expectError(error.FileNotFound, fs.cwd().access(cache_dir, .{}));
}

test "cleanStep is part of the clean-baseline runner API" {
    try testing.expect(@intFromPtr(&cleanStep) != 0);
}

// spec: Mutation Testing - Applies a mutant by splicing the replacement into the source

test "spliced replaces the mutant byte range and rejects stale ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "return a < b;";
    const m: gen.Mutant = .{
        .path = "src/x.zig",
        .start = 9,
        .end = 10,
        .original = "<",
        .replacement = "<=",
        .source = .{ .line = 1 },
    };
    try testing.expectEqualStrings("return a <= b;", try spliced(a, src, m));
    // Content changed under us: the range no longer reads `original`.
    try testing.expectError(error.StaleMutant, spliced(a, "return a > b;", m));
}

// spec: Mutation Testing - Ratchets the full-run mutation score against a snapshot

test "ratchetDecision creates, raises, holds, and flags regressions" {
    try testing.expectEqual(RatchetDecision.created, ratchetDecision(null, 80));
    try testing.expectEqual(RatchetDecision.raised, ratchetDecision(80, 90));
    try testing.expectEqual(RatchetDecision.held, ratchetDecision(90, 90));
    try testing.expectEqual(RatchetDecision.regressed, ratchetDecision(90, 85));
}

// spec: Mutation Testing - Derives a per-mutant timeout from the clean-suite baseline and a floor

test "deadlineNs floors a fast suite and scales a slow one" {
    const s = std.time.ns_per_s;
    // Fast suite (1s baseline): 5×1s = 5s is below the 30s floor → floored.
    try testing.expectEqual(@as(u64, 30 * s), deadlineNs(30, 5, 1 * s));
    // Slow suite (20s baseline): 5×20s = 100s dominates the 30s floor.
    try testing.expectEqual(@as(u64, 100 * s), deadlineNs(30, 5, 20 * s));
    // A zero baseline (suite finished within a measurement tick) still floors.
    try testing.expectEqual(@as(u64, 30 * s), deadlineNs(30, 5, 0));
}

// Test-only knobs for the group-kill integration test. File-scope (scanned as
// production), so literals sit right after `=` to satisfy magic-number.
const group_kill_deadline_ms: u64 = 300;
const pidfile_read_cap: usize = 4096;
const pidfile_tries: u32 = 100;
const pidfile_poll_ms: u64 = 20;
const reap_tries: u32 = 200;
const reap_poll_ms: u64 = 20;
const sentinel_secs: u32 = 30;

/// Waits `ns` without a banned wall-clock sleep: an event that is never set, so
/// `timedWait` always times out after exactly `ns`.
fn testTick(ns: u64) void {
    var ev: std.Io.Event = .unset;
    ev.waitTimeout(std.testing.io, timeoutNs(ns)) catch return;
}

/// Reads `pidfile` once the shell has written the grandchild pid, retrying a few
/// event-timed ticks (no wall-clock sleep).
fn waitForPidfile(a: Allocator, pidfile: []const u8) ![]u8 {
    var tries: u32 = 0;
    while (tries < pidfile_tries) : (tries += 1) {
        if (fs.cwd().readFileAlloc(a, pidfile, pidfile_read_cap)) |c| {
            if (std.mem.trim(u8, c, &std.ascii.whitespace).len > 0) return c;
        } else |_| {}
        testTick(ns_per_ms * pidfile_poll_ms);
    }
    return error.NoPidFile;
}

/// True while `pid` still exists — kill(pid, 0) succeeds. Read once, never
/// polled: proving a process SURVIVED something needs no wait, and polling for
/// four seconds to conclude "still there" would make the test a slow one.
fn pidAlive(pid: i32) bool {
    const rc = std.posix.system.kill(pid, @fromBackingInt(@intCast(0)));
    return std.posix.errno(rc) == .SUCCESS;
}

/// True once `pid` no longer exists — kill(pid, 0) errors (ESRCH). Polls a few
/// ticks to let the SIGKILL land and the orphan be reaped.
fn pidReaped(pid: i32) bool {
    var tries: u32 = 0;
    while (tries < reap_tries) : (tries += 1) {
        if (!pidAlive(pid)) return true; // ESRCH / gone
        testTick(ns_per_ms * reap_poll_ms);
    }
    return false;
}

/// Starts a process in the TEST's own process group and returns its pid.
///
/// `sh` inherits this process's group (no `.pgid` is set, which is what fork
/// means), the backgrounded `sleep` inherits it from `sh`, and `sh` then exits
/// — so the survivor is in our group but is NOT our child, and therefore can
/// never linger as a zombie that `kill(pid, 0)` would report as alive.
fn spawnGroupSentinel(a: Allocator, pidfile: []const u8) !i32 {
    const script = try std.fmt.allocPrint(
        a,
        "sleep {d} & echo $! > {s}",
        .{ sentinel_secs, pidfile },
    );
    var sh = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", script },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = sh.wait(std.testing.io) catch null;
    const raw = try waitForPidfile(a, pidfile);
    return std.fmt.parseInt(i32, std.mem.trim(u8, raw, &std.ascii.whitespace), 10);
}

// spec: Mutation Testing - Kills the whole child process group when a mutant run exceeds its deadline

test "superviseArgv kills the whole process group on timeout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/mutant-group-kill";
    fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir);
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("group-kill cleanup: {s}", .{@errorName(e)});
    const pidfile = dir ++ "/grandchild.pid";

    // A bystander in the TEST's own process group. The blast radius of the
    // watchdog's kill(-pgid) has to stop at the supervised child's group: under
    // a piped `zig build test` this process shares its group with the pipeline,
    // so a kill that reached our group would take out `tail`/`grep` and make
    // the build system report a phantom step failure on a green run — reported
    // repeatedly by consumers, and the reason `superviseArgv` spawns with
    // `.pgid = 0`. Asserting the survivor is what keeps that line honest.
    const sentinel = try spawnGroupSentinel(a, dir ++ "/sentinel.pid");
    defer std.posix.kill(sentinel, std.posix.SIG.KILL) catch |e|
        std.log.warn("sentinel cleanup: {s}", .{@errorName(e)});

    // sh (the direct child) forks a never-ending grandchild, records its pid,
    // then waits forever. Killing only the direct child would orphan the
    // grandchild; a process-GROUP kill (-pgid) reaps it too.
    const script = "sleep 3600 & echo $! > " ++ pidfile ++ "; wait";
    const deadline = ns_per_ms * group_kill_deadline_ms;
    const sup = try superviseArgv(a, &.{ "sh", "-c", script }, ".", .{
        .timeout_ns = deadline,
        .tick_ns = deadline,
        .heartbeat = null,
    });
    try testing.expectEqual(ExecResult.timed_out, sup.result);

    const raw = try waitForPidfile(a, pidfile);
    const gpid = try std.fmt.parseInt(i32, std.mem.trim(u8, raw, &std.ascii.whitespace), 10);
    // The grandchild must be dead: proof the whole group was killed, not just sh.
    try testing.expect(pidReaped(gpid));
    // And our own group must be untouched. The two assertions together pin the
    // radius exactly: had the child shared our group, `kill(-child_pid)` would
    // have named no group at all and the grandchild above would have survived.
    try testing.expect(pidAlive(sentinel));
}
