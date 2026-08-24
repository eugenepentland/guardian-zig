//! `mutate` command — mutation-tests the project's suite. Static checks
//! prove tests *exist*; this proves they *bite*: each mutant is a small
//! deliberate bug, and a test suite that lets it pass unnoticed wasn't
//! constraining that behavior. Two tiers, mirroring the sibling guardians:
//!
//!   guardian-check mutate .            # fast: mutate only lines changed
//!                                      # vs --against/GUARDIAN_AGAINST/HEAD
//!   guardian-check mutate . --full     # nightly: mutate the whole tree and
//!                                      # ratchet the score in .guardian/
//!
//! Not part of `all` — it rebuilds and re-tests the project per mutant, so
//! it's an explicitly-invoked step (`zig build mutate`), not a build gate.
//!
//! Hardening (audit #9): a small-diff gating *floor* (`min_mutants`) so a
//! 1-of-2 survivor isn't a meaningless 50% red; a per-mutant result *cache*
//! (mutation/cache.zig) so unchanged mutants skip the build+test cycle and an
//! interrupted run resumes; a machine-readable *survivor report*
//! (mutation/report.zig) with the exact context an agent needs; and a
//! `// mutate-ok` *waiver* for known equivalent mutants.

const std = @import("std");
const fs = @import("../fs.zig");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const ast_index = @import("../ast/index.zig");
const git = @import("../git.zig");
const gen = @import("../mutation/gen.zig");
const runner = @import("../mutation/runner.zig");
const journal = @import("../mutation/journal.zig");
const mut_cache = @import("../mutation/cache.zig");
const report_mod = @import("../mutation/report.zig");
const cache = @import("../cache.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const dora = @import("../dora.zig");
const writer_lock = @import("../writer_lock.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

pub const command_name = "mutate";

const snapshot_leaf = "mutation.txt";
const snapshot_version: u32 = 2;
const score_key = "score_pct=";
const cohort_key = "cohort=";
/// How many surviving mutants are listed before the report truncates.
const max_reported_survivors = 20;

/// Pure gate: a run passes when its kill percentage meets the configured
/// minimum score.
pub fn gatePasses(score_pct: u32, min_pct: u32) bool {
    return score_pct >= min_pct;
}

/// Whether a run has enough viable mutants to gate on the kill percentage.
/// Below the floor a single survivor skews the percentage meaninglessly
/// (1 survivor of 2 = 50%), so the run reports informationally and passes and
/// the score ratchet is left untouched.
pub fn gatedByPercentage(viable: u32, min_mutants: u32) bool {
    return viable >= min_mutants;
}

/// Progress heartbeat cadence for a running mutant (so a stalled run is
/// distinguishable from a merely slow one).
const heartbeat_secs: u64 = 15;
const heartbeat_ns: u64 = std.time.ns_per_s * heartbeat_secs;

/// Entry point for the mutate command.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    var lock = writer_lock.acquire(a, ctx.project_dir) catch |err| {
        reporter.fail("mutate FAILED: cannot acquire {s}/{s} ({s}) — wait for the current writer; a crashed process releases the kernel lock automatically", .{
            ctx.project_dir, writer_lock.leaf, @errorName(err),
        });
        return error.CheckFailed;
    };
    defer lock.deinit();
    // Crash safety first: revert any mutant a dead run left applied on disk,
    // then arm the SIGINT/SIGTERM revert for this run.
    journal.recover(a, ctx.project_dir);
    journal.install();
    const build_cache_dir = (try runner.prepareCache(a, ctx.project_dir)) orelse {
        reporter.fail("mutate FAILED: cannot prepare isolated Zig cache", .{});
        return error.CheckFailed;
    };
    defer runner.cleanupCache(build_cache_dir);
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, a, ctx.project_dir, &storage);

    const cand = try collectCandidates(ctx, idx) orelse return;
    const budget = if (ctx.full) ctx.cfg.mutation.max_mutants else ctx.cfg.mutation.fast_max_mutants;
    const picked = try gen.sample(a, cand.mutants, budget);
    const cohort = gen.cohortHash(picked);
    report_mod.writeCohort(
        a,
        ctx.project_dir,
        if (ctx.full) "full" else "fast",
        cand.mutants.len,
        picked,
        cohort,
    );
    if (picked.len == 0) {
        reporter.ok("mutate: no mutants to run ({s})", .{
            if (ctx.full) "no mutation sites found" else "no changed production lines",
        });
        if (cand.waived > 0) reporter.ok("mutate: {d} site(s) waived via mutate-ok", .{cand.waived});
        return;
    }
    if (picked.len < cand.mutants.len) {
        reporter.ok("mutate: sampled {d} of {d} candidate mutants (max_mutants = {d})", .{
            picked.len, cand.mutants.len, budget,
        });
    }
    if (cand.waived > 0) reporter.ok("mutate: {d} site(s) waived via mutate-ok", .{cand.waived});

    const scored = try execute(ctx, picked, suiteHex(ctx), build_cache_dir);
    try report(ctx, scored, cand.waived, cohort);
}

/// The candidate mutant list plus the count of `// mutate-ok` sites suppressed
/// for this tier (whole-file in `--full` / untracked files, diff-scoped for
/// diffed files).
const Candidates = struct {
    mutants: []const gen.Mutant,
    waived: u32 = 0,
};

/// The suite digest (hex) that keys the per-mutant result cache, or null when it
/// can't be computed (no git/fs) — in which case the run proceeds without cache
/// reuse. Best-effort: caching is an accelerator, never a correctness input.
fn suiteHex(ctx: *types.RunCtx) ?[]const u8 {
    const digest = cache.suiteDigest(ctx.allocator, ctx.project_dir) catch return null;
    const hex = std.fmt.bytesToHex(digest, .lower);
    return ctx.allocator.dupe(u8, &hex) catch null;
}

/// Generates the candidate mutant list for this tier: every indexed file in
/// --full mode, only diff-touched lines otherwise. Null means the run was
/// skipped (fast tier without usable git state) and a note was printed.
fn collectCandidates(ctx: *types.RunCtx, idx: *const ast_index.Index) types.RunError!?Candidates {
    const a = ctx.allocator;
    if (ctx.full) {
        var all: std.ArrayList(gen.Mutant) = .empty;
        var waived: u32 = 0;
        for (idx.files) |f| {
            const gr = try gen.generate(a, f.rel_path, f.content);
            try all.appendSlice(a, gr.mutants);
            waived += @intCast(gr.waived_lines.len);
        }
        return .{ .mutants = try all.toOwnedSlice(a), .waived = waived };
    }

    const against = ctx.against orelse ctx.cfg.change_classification.against;
    const res = try git.diffAgainst(a, ctx.project_dir, against);
    if (res == .unavailable) {
        reporter.ok("mutate: skipped — {s}", .{res.unavailable});
        return null;
    }
    return try diffCandidates(ctx, idx, res.ok);
}

/// Fast-tier candidates: mutants on added lines of diffed files, plus every
/// mutant in untracked (brand new) source files. Waivers are counted with the
/// same diff scoping the mutants get, so an unchanged waived line elsewhere in a
/// touched file doesn't inflate the tally.
fn diffCandidates(
    ctx: *types.RunCtx,
    idx: *const ast_index.Index,
    file_diffs: []const git.FileDiff,
) types.RunError!Candidates {
    const a = ctx.allocator;
    var span_map: std.StringHashMapUnmanaged([]const git.LineSpan) = .empty;
    for (file_diffs) |fd| try span_map.put(a, fd.path, fd.spans);
    const untracked = try git.untrackedFiles(a, ctx.project_dir);

    var out: std.ArrayList(gen.Mutant) = .empty;
    var waived: u32 = 0;
    for (idx.files) |f| {
        if (span_map.get(f.rel_path)) |spans| {
            const gr = try gen.generate(a, f.rel_path, f.content);
            try out.appendSlice(a, try gen.filterToSpans(a, gr.mutants, spans));
            waived += gen.waivedInSpans(gr.waived_lines, spans);
        } else if (contains(untracked, f.rel_path)) {
            const gr = try gen.generate(a, f.rel_path, f.content);
            try out.appendSlice(a, gr.mutants);
            waived += @intCast(gr.waived_lines.len);
        }
    }
    return .{ .mutants = try out.toOwnedSlice(a), .waived = waived };
}

fn contains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

/// Runs every picked mutant, printing a progress line per mutant and tallying
/// outcomes. A mutant whose (suite, identity) key is already in the result cache
/// reuses that outcome and skips the build+test cycle (marked "(cached)"); each
/// freshly-run outcome is flushed to the cache immediately so an interrupted run
/// resumes. Stale mutants (file changed mid-run) are skipped.
fn execute(
    ctx: *types.RunCtx,
    picked: []const gen.Mutant,
    suite_hex: ?[]const u8,
    build_cache_dir: []const u8,
) types.RunError!ScoredRun {
    const a = ctx.allocator;
    // A refresh (GUARDIAN_UPDATE_SNAPSHOT covering mutate) bypasses cache reads:
    // a fresh ratchet must be a fresh measurement, not a replay.
    const mode: mut_cache.Reuse = if (snapshot_helper.shouldUpdateForCtx(ctx, "mutate")) .fresh else .reuse;
    const cache_map: mut_cache.Map = if (suite_hex) |h| mut_cache.load(
        a,
        ctx.project_dir,
        h,
        mode,
        ctx.cfg.mutation.retained_cache_suites,
    ) else .{};

    if (ctx.cfg.mutation.smoke_step) |step| {
        const cap = @as(u64, ctx.cfg.mutation.timeout_secs) * std.time.ns_per_s;
        if (try runner.cleanStep(a, ctx.project_dir, build_cache_dir, step, cap) != .ok) {
            reporter.fail("mutate FAILED: clean smoke step `{s}` does not pass; no mutants were scored", .{step});
            return error.CheckFailed;
        }
        reporter.ok("mutate: clean smoke step `{s}` passed", .{step});
    }

    var deadline_ns: ?u64 = null; // measured lazily on the first non-cached mutant
    var scored: ScoredRun = .{};
    // Whole-run stopwatch (dora clock seam) so each mutant line carries elapsed
    // wall time and the running survivor count — a stalled campaign is then
    // distinguishable from a merely long one.
    var run_sw = dora.startStopwatch();
    for (picked, 1..) |m, i| {
        const key = try mut_cache.keyFor(a, m);
        const label = try std.fmt.allocPrint(a, "[{d}/{d}] {s}:{d}", .{
            i, picked.len, m.path, m.source.line,
        });
        if (cache_map.get(key)) |cached_outcome| {
            scored.score.add(cached_outcome);
            scored.cached += 1;
            if (cached_outcome == .survived) try scored.addSurvivor(a, m);
            detail("  {s} `{s}` -> `{s}` ... {s} (cached){s}\n", .{
                label,                                                               m.original, m.replacement, @tagName(cached_outcome),
                try progressTail(a, run_sw.elapsedMs(), scored.survivors.items.len),
            });
            continue;
        }
        if (deadline_ns == null) deadline_ns = computeDeadline(ctx, build_cache_dir);
        const timeout_ns = deadline_ns orelse return error.CheckFailed;
        const opts: runner.RunOpts = .{
            .project_dir = ctx.project_dir,
            .timeout_ns = timeout_ns,
            .heartbeat_ns = heartbeat_ns,
            .label = label,
            .cache_dir = build_cache_dir,
            .smoke_step = ctx.cfg.mutation.smoke_step,
            .timeout_retry_multiplier = ctx.cfg.mutation.timeout_retry_multiplier,
        };
        detail("  {s} `{s}` -> `{s}` running...\n", .{ label, m.original, m.replacement });
        const outcome = runner.runOne(a, opts, m) catch |e| switch (e) {
            error.StaleMutant => {
                detail("  {s} skipped (file changed mid-run)\n", .{label});
                continue;
            },
            else => return e,
        };
        scored.score.add(outcome);
        // A timeout can be transient infrastructure slowness. Never cache an
        // inconclusive result: the next exact-suite run must retry it.
        if (outcome != .inconclusive) {
            if (suite_hex) |h| mut_cache.append(a, ctx.project_dir, h, m, outcome);
        }
        if (outcome == .survived) try scored.addSurvivor(a, m);
        detail("  {s} ... {s}{s}\n", .{
            label,                                                               @tagName(outcome),
            try progressTail(a, run_sw.elapsedMs(), scored.survivors.items.len),
        });
    }
    return scored;
}

/// The per-mutant progress tail: running elapsed seconds and survivor count so
/// far, appended to each mutant's outcome line. Pure over its inputs, so it is
/// unit-tested without a clock.
fn progressTail(a: Allocator, elapsed_ms: u64, survivors: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, " [{d}s, {d} survived]", .{ elapsed_ms / std.time.ms_per_s, survivors });
}

/// Measures the clean-suite baseline once and derives the per-mutant deadline
/// (`max(floor, ×multiplier)`), falling back to `timeout_secs` when the baseline
/// can't be measured (clean suite errored/hung). Announces the chosen timeout.
fn computeDeadline(ctx: *types.RunCtx, cache_dir: []const u8) u64 {
    const mc = ctx.cfg.mutation;
    const sec = std.time.ns_per_s;
    const cap_ns = @as(u64, mc.timeout_secs) * sec;
    if (runner.measureBaseline(ctx.allocator, ctx.project_dir, cache_dir, cap_ns)) |baseline| {
        const d = runner.deadlineNs(mc.timeout_floor_secs, mc.timeout_multiplier, baseline);
        reporter.ok("mutate: clean-suite baseline ~{d}s → per-mutant timeout {d}s (floor {d}s, ×{d})", .{
            baseline / sec, d / sec, mc.timeout_floor_secs, mc.timeout_multiplier,
        });
        return d;
    }
    reporter.ok(
        "mutate: clean-suite baseline unavailable → per-mutant timeout {d}s (timeout_secs fallback)",
        .{mc.timeout_secs},
    );
    return cap_ns;
}

/// A finished run: outcome tallies, the surviving mutants, and how many outcomes
/// were reused from the result cache.
const ScoredRun = struct {
    score: runner.Score = .{},
    survivors: std.ArrayList(report_mod.Survivor) = .empty,
    cached: u32 = 0,

    /// Records a surviving mutant with the context the survivor report needs.
    fn addSurvivor(self: *ScoredRun, a: Allocator, m: gen.Mutant) Allocator.Error!void {
        try self.survivors.append(a, .{
            .file = m.path,
            .line = m.source.line,
            .original = m.original,
            .replacement = m.replacement,
            .src_line = m.source.text,
        });
    }
};

/// Applies the small-diff floor, the min-score gate (both tiers), and the
/// snapshot ratchet (--full only), then prints the verdict. Always writes the
/// machine-readable survivor report. Below the `min_mutants` floor the run
/// reports its survivors informationally and passes without touching the ratchet.
fn report(ctx: *types.RunCtx, scored: ScoredRun, waived: u32, cohort: u64) types.RunError!void {
    const s = scored.score;
    const pct = s.pct();
    const viable = s.viable();
    const min_mutants = ctx.cfg.mutation.min_mutants;
    const gated = gatedByPercentage(viable, min_mutants);

    reporter.ok("mutate: score {d}% — {d} killed, {d} survived, {d} unviable, {d} inconclusive", .{
        pct, s.killed, s.survived, s.unviable, s.inconclusive,
    });
    if (scored.cached > 0) reporter.ok("mutate: reused {d} cached outcome(s)", .{scored.cached});

    writeMachineReport(ctx, scored, waived, gated, pct);

    if (s.inconclusive > 0) {
        reporter.fail(
            "mutate FAILED: {d} mutant(s) remained inconclusive after timeout retry; score/ratchet not accepted",
            .{s.inconclusive},
        );
        return error.CheckFailed;
    }

    if (!gated) {
        reporter.ok("mutate: {d} viable mutant(s) below min_mutants={d} — informational, not gated", .{
            viable, min_mutants,
        });
        listSurvivors(scored.survivors.items);
        return;
    }

    var failed = false;
    if (!gatePasses(pct, ctx.cfg.mutation.min_score_pct)) {
        reporter.fail("mutate FAILED: score {d}% is below min_score_pct {d}%", .{
            pct, ctx.cfg.mutation.min_score_pct,
        });
        failed = true;
    }
    if (ctx.full and !try ratchet(ctx, pct, cohort)) failed = true;

    if (!failed) return;
    listSurvivors(scored.survivors.items);
    detail("  fix: strengthen the tests these mutants slipped past — " ++
        "assert the exact values, not just success.\n", .{});
    return error.CheckFailed;
}

/// Writes `.guardian/cache/last-mutate.jsonl`: one survivor record per survivor,
/// then a summary. Best-effort (see mutation/report.zig).
fn writeMachineReport(ctx: *types.RunCtx, scored: ScoredRun, waived: u32, gated: bool, pct: u32) void {
    report_mod.write(ctx.allocator, ctx.project_dir, scored.survivors.items, .{
        .tier = if (ctx.full) "full" else "fast",
        .score = pct,
        .counts = scored.score,
        .waived = waived,
        .cached = scored.cached,
        .gated = gated,
    });
}

/// Full-tier score ratchet against .guardian/mutation.txt. Returns false
/// (and reports) on an unforced regression; creates/raises/holds otherwise.
/// Only reached when the run is gated (at or above the min_mutants floor), so a
/// below-floor run never records a meaningless score.
fn ratchet(ctx: *types.RunCtx, pct: u32, cohort: u64) types.RunError!bool {
    const a = ctx.allocator;
    const path = try snapshot_helper.snapshotPath(a, ctx.project_dir, snapshot_leaf);
    const old = readRatchet(a, path) catch |e| switch (e) {
        error.Missing => null,
        else => {
            reporter.fail(
                "mutate FAILED: mutation ratchet is unreadable or malformed ({s}); refusing to recreate it",
                .{@errorName(e)},
            );
            return e;
        },
    };
    const force = snapshot_helper.shouldUpdateForCtx(ctx, "mutate");
    const old_pct: ?u32 = if (old) |prior| prior.pct else null;
    if (old) |prior| {
        if (!cohortMatches(prior.cohort, cohort)) {
            reporter.ok(
                "mutate: cohort turnover detected; prior score is not compared to incompatible sample (new {x})",
                .{cohort},
            );
            try writeRatchet(a, path, pct, cohort);
            return true;
        }
    }
    const decision = runner.ratchetDecision(old_pct, pct);
    if (decision == .regressed and !force) {
        reporter.fail("mutate FAILED: score {d}% regressed below the snapshot ratchet {d}%", .{
            pct,
            old_pct orelse 0,
        });
        detail("  accept deliberately with {s}=mutate, or strengthen the tests.\n", .{snapshot_helper.update_env});
        return false;
    }
    try writeRatchet(a, path, pct, cohort);
    reporter.ok("mutate: score ratchet {s} at {d}% ({s})", .{ @tagName(decision), pct, snapshot_leaf });
    return true;
}

fn cohortMatches(old: ?u64, current: u64) bool {
    const value = old orelse return false;
    return value == current;
}

const Ratchet = struct { pct: u32, cohort: ?u64 };

/// Reads and strictly validates the prior score. Only Missing is creation;
/// corruption, duplicate fields, invalid percentages, and I/O errors fail closed.
fn readRatchet(a: Allocator, path: []const u8) snapshot.ReadError!Ratchet {
    const snap = snapshot.read(a, path, snapshot_version) catch |e| switch (e) {
        // Version 1 was a valid score-only format. Migrate it as an
        // incompatible cohort rather than weakening fail-closed parsing.
        error.VersionMismatch => return readLegacyRatchet(a, path),
        else => return e,
    };
    var pct: ?u32 = null;
    var cohort: ?u64 = null;
    for (snap.lines) |line| {
        if (std.mem.startsWith(u8, line, score_key)) {
            if (pct != null) return error.BadFormat;
            pct = std.fmt.parseInt(u32, line[score_key.len..], 10) catch return error.BadFormat;
        } else if (std.mem.startsWith(u8, line, cohort_key)) {
            if (cohort != null) return error.BadFormat;
            cohort = std.fmt.parseInt(u64, line[cohort_key.len..], 16) catch return error.BadFormat;
        } else {
            return error.BadFormat;
        }
    }
    const valid_pct = pct orelse return error.BadFormat;
    const valid_cohort = cohort orelse return error.BadFormat;
    if (valid_pct > 100) return error.BadFormat;
    return .{ .pct = valid_pct, .cohort = valid_cohort };
}

fn readLegacyRatchet(a: Allocator, path: []const u8) snapshot.ReadError!Ratchet {
    const snap = try snapshot.read(a, path, 1);
    if (snap.lines.len != 1 or !std.mem.startsWith(u8, snap.lines[0], score_key)) return error.BadFormat;
    const pct = std.fmt.parseInt(u32, snap.lines[0][score_key.len..], 10) catch return error.BadFormat;
    if (pct > 100) return error.BadFormat;
    return .{ .pct = pct, .cohort = null };
}

fn writeRatchet(a: Allocator, path: []const u8, pct: u32, cohort: u64) types.RunError!void {
    var lines = [_][]const u8{
        try std.fmt.allocPrint(a, "{s}{d}", .{ score_key, pct }),
        try std.fmt.allocPrint(a, "{s}{x}", .{ cohort_key, cohort }),
    };
    try snapshot.write(path, snapshot_version, &lines);
}

/// Prints each survivor: file:line, the operator swap, and the original source
/// line — the exact context an agent needs to write the killing test.
fn listSurvivors(survivors: []const report_mod.Survivor) void {
    for (survivors, 0..) |s, i| {
        if (i >= max_reported_survivors) {
            detail("  ... and {d} more survivor(s)\n", .{survivors.len - max_reported_survivors});
            return;
        }
        detail("  {s}:{d}: `{s}` -> `{s}` survived\n      {s}\n", .{
            s.file, s.line, s.original, s.replacement, std.mem.trim(u8, s.src_line, &std.ascii.whitespace),
        });
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Mutation Testing - Reports running elapsed and survivor count per mutant

test "progressTail renders elapsed seconds and the running survivor count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 12_500 ms → 12s (floored), 3 survivors so far.
    try testing.expectEqualStrings(" [12s, 3 survived]", try progressTail(a, 12_500, 3));
    // Fresh run, none survived yet.
    try testing.expectEqualStrings(" [0s, 0 survived]", try progressTail(a, 200, 0));
}

// spec: Mutation Testing - Fails a run whose score drops below the configured minimum

test "gatePasses compares the kill score against the configured minimum" {
    try testing.expect(gatePasses(80, 80));
    try testing.expect(gatePasses(100, 80));
    try testing.expect(!gatePasses(79, 80));
    // A 0-minimum project (opting out of the gate) always passes.
    try testing.expect(gatePasses(0, 0));
}

// spec: Mutation Testing - Gates on the kill percentage only at or above the min_mutants floor

test "gatedByPercentage requires the viable count to reach the floor" {
    // Below the floor: report informationally, don't gate on the percentage.
    try testing.expect(!gatedByPercentage(1, 4));
    try testing.expect(!gatedByPercentage(3, 4));
    // At or above the floor: percentage gating applies.
    try testing.expect(gatedByPercentage(4, 4));
    try testing.expect(gatedByPercentage(100, 4));
    // A 0 floor always gates (opting out of the floor).
    try testing.expect(gatedByPercentage(0, 0));
}

// spec: Mutation Testing - Rejects malformed mutation ratchets instead of recreating them

test "readRatchet validates score and cohort and fails closed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/mutation-ratchet-test.txt";
    defer fs.cwd().deleteFile(path) catch |e| std.log.warn("ratchet cleanup: {s}", .{@errorName(e)});

    var valid = [_][]const u8{ "score_pct=88", "cohort=abc" };
    try snapshot.write(path, snapshot_version, &valid);
    const parsed = try readRatchet(a, path);
    try testing.expectEqual(@as(u32, 88), parsed.pct);
    try testing.expectEqual(@as(u64, 0xabc), parsed.cohort.?);

    var invalid = [_][]const u8{ "score_pct=101", "cohort=abc" };
    try snapshot.write(path, snapshot_version, &invalid);
    try testing.expectError(error.BadFormat, readRatchet(a, path));
}
