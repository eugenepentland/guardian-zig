//! Executes mutants for the `mutate` command: splice the mutation into the
//! source file in place, run the project's build and test steps with
//! GUARDIAN_MUTATION_RUN=1 (so guardian's own gates no-op instead of
//! judging the deliberately-broken tree), restore the original bytes, and
//! classify what happened. A mutant the compiler rejects is *unviable*
//! (excluded from scoring); one the tests fail or hang on is *killed* —
//! only a mutant the whole suite quietly accepts counts against the score.

const std = @import("std");
const gen = @import("gen.zig");
const reporter = @import("../reporter.zig");

const Allocator = std.mem.Allocator;

/// Env var set on child builds during mutation runs. guardian-check exits
/// immediately when it sees this, so the mutated tree isn't gated.
pub const MUTATION_ENV = "GUARDIAN_MUTATION_RUN";

/// Cap on a source file read before splicing (mirrors the walker's cap).
const MAX_SRC_BYTES: usize = 10 * 1024 * 1024;

/// Error surface of a mutant run: the runner reads/splices/restores source
/// files, clones the environment, and spawns child `zig build` processes, so
/// the set unions filesystem, env, and process-spawn failures with OOM and
/// `StaleMutant` (the source moved out from under a generated mutant). A
/// precise named set instead of `anyerror` keeps the error space explicit.
pub const RunError = Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.fs.File.GetSeekPosError ||
    std.process.Child.SpawnError ||
    error{ StaleMutant, FileTooBig, StreamTooLong };

/// What one mutant did to the suite.
pub const Outcome = enum { killed, survived, unviable, timed_out };

/// Result of one child build invocation.
pub const ExecResult = enum { ok, failed, timed_out };

/// Pure classification of a mutant from its two build phases: a compile
/// failure is unviable, a test failure is killed, a hang in either phase is
/// timed out (still caught), and a fully green run means the mutant survived.
pub fn outcomeFor(build_res: ExecResult, test_res: ExecResult) Outcome {
    return switch (build_res) {
        .timed_out => .timed_out,
        .failed => .unviable,
        .ok => switch (test_res) {
            .ok => .survived,
            .failed => .killed,
            .timed_out => .timed_out,
        },
    };
}

/// Running tallies across a mutation run.
pub const Score = struct {
    killed: u32 = 0,
    survived: u32 = 0,
    unviable: u32 = 0,
    timed_out: u32 = 0,

    /// Adds one mutant's outcome to the tallies.
    pub fn add(self: *Score, outcome: Outcome) void {
        switch (outcome) {
            .killed => self.killed += 1,
            .survived => self.survived += 1,
            .unviable => self.unviable += 1,
            .timed_out => self.timed_out += 1,
        }
    }

    /// Count of viable mutants — killed + timed-out + survived, excluding
    /// unviable (compile-error) mutants. This is the percentage denominator and
    /// the quantity the small-diff gating floor (`min_mutants`) is measured
    /// against: below the floor a percentage is statistically meaningless.
    pub fn viable(self: Score) u32 {
        return self.killed + self.timed_out + self.survived;
    }

    /// Kill percentage over viable mutants. Timeouts count as kills (an
    /// infinite-loop mutant was still caught); unviable mutants are
    /// excluded. An empty run scores 100 — nothing survived.
    pub fn pct(self: Score) u32 {
        const kills = self.killed + self.timed_out;
        const denom = self.viable();
        if (denom == 0) return 100;
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
    timeout_ns: u64,
};

/// Runs one mutant end to end: splice, `zig build` (viability), `zig build
/// test` (kill check), restore. The original bytes are restored even when a
/// phase errors; a failed restore is reported loudly — the tree is dirty
/// and `git checkout <file>` is the recovery.
pub fn runOne(allocator: Allocator, opts: RunOpts, m: gen.Mutant) RunError!Outcome {
    const abs = try std.fs.path.join(allocator, &.{ opts.project_dir, m.path });
    const original = try std.fs.cwd().readFileAlloc(allocator, abs, MAX_SRC_BYTES);
    const mutated = try spliced(allocator, original, m);

    try std.fs.cwd().writeFile(.{ .sub_path = abs, .data = mutated });
    defer std.fs.cwd().writeFile(.{ .sub_path = abs, .data = original }) catch {
        reporter.fail("mutate: FAILED to restore {s} — recover with `git checkout -- {s}`", .{ abs, m.path });
    };

    const build_res = try execWithTimeout(allocator, &.{ "zig", "build" }, opts);
    if (build_res != .ok) return outcomeFor(build_res, .ok);
    const test_res = try execWithTimeout(allocator, &.{ "zig", "build", "test" }, opts);
    return outcomeFor(build_res, test_res);
}

/// Spawns `argv` in the project dir with MUTATION_ENV set, killing it if it
/// outlives the timeout (a watchdog thread waits on an event the normal
/// path sets — no polling, no sleep).
fn execWithTimeout(allocator: Allocator, argv: []const []const u8, opts: RunOpts) RunError!ExecResult {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put(MUTATION_ENV, "1");

    var child = std.process.Child.init(argv, allocator);
    child.cwd = opts.project_dir;
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var dog: Watchdog = .{ .pid = child.id, .timeout_ns = opts.timeout_ns };
    const th: ?std.Thread = std.Thread.spawn(.{}, Watchdog.watch, .{&dog}) catch null;
    const term = child.wait() catch null;
    dog.finished.set();
    if (th) |t| t.join();

    if (dog.fired.load(.monotonic)) return .timed_out;
    const t = term orelse return .failed;
    return if (t == .Exited and t.Exited == 0) .ok else .failed;
}

/// Kills the child process if `finished` isn't signalled within the
/// timeout. Uses the raw pid rather than Child.kill so it can't race the
/// main thread's wait() on the Child struct. (POSIX-only, like the rest of
/// guardian's process handling.)
const Watchdog = struct {
    pid: std.process.Child.Id,
    timeout_ns: u64,
    finished: std.Thread.ResetEvent = .{},
    fired: std.atomic.Value(bool) = .init(false),

    fn watch(self: *Watchdog) void {
        self.finished.timedWait(self.timeout_ns) catch {
            self.fired.store(true, .monotonic);
            std.posix.kill(self.pid, std.posix.SIG.KILL) catch |e| {
                reporter.detail("  watchdog kill failed: {s}\n", .{@errorName(e)});
            };
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Mutation Testing - Classifies mutant outcomes from the build and test phases

test "outcomeFor maps build/test results to mutant outcomes" {
    try testing.expectEqual(Outcome.survived, outcomeFor(.ok, .ok));
    try testing.expectEqual(Outcome.killed, outcomeFor(.ok, .failed));
    try testing.expectEqual(Outcome.timed_out, outcomeFor(.ok, .timed_out));
    // A compile failure never reaches the test phase: unviable regardless.
    try testing.expectEqual(Outcome.unviable, outcomeFor(.failed, .ok));
    try testing.expectEqual(Outcome.timed_out, outcomeFor(.timed_out, .ok));
}

// spec: Mutation Testing - Scores a run as kills over viable mutants counting timeouts as kills

test "Score.pct counts timeouts as kills and excludes unviable mutants" {
    var s: Score = .{};
    s.add(.killed);
    s.add(.killed);
    s.add(.timed_out);
    s.add(.survived);
    s.add(.unviable);
    // 3 kills (2 killed + 1 timeout) of 4 viable = 75%; unviable excluded.
    try testing.expectEqual(@as(u32, 4), s.viable());
    try testing.expectEqual(@as(u32, 75), s.pct());
    const empty: Score = .{};
    try testing.expectEqual(@as(u32, 0), empty.viable());
    try testing.expectEqual(@as(u32, 100), empty.pct());
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
        .line = 1,
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
