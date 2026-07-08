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
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const ast_index = @import("../ast/index.zig");
const git = @import("../git.zig");
const gen = @import("../mutation/gen.zig");
const runner = @import("../mutation/runner.zig");
const mut_cache = @import("../mutation/cache.zig");
const report_mod = @import("../mutation/report.zig");
const cache = @import("../cache.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

pub const COMMAND_NAME = "mutate";

const SNAPSHOT_LEAF = "mutation.txt";
const SNAPSHOT_VERSION: u32 = 1;
const SCORE_KEY = "score_pct=";
/// How many surviving mutants are listed before the report truncates.
const MAX_REPORTED_SURVIVORS = 20;

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

/// Entry point for the mutate command.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, a, ctx.project_dir, &storage);

    const cand = try collectCandidates(ctx, idx) orelse return;
    const picked = try gen.sample(a, cand.mutants, ctx.cfg.mutation.max_mutants);
    if (picked.len == 0) {
        reporter.ok("mutate: no mutants to run ({s})", .{
            if (ctx.full) "no mutation sites found" else "no changed production lines",
        });
        if (cand.waived > 0) reporter.ok("mutate: {d} site(s) waived via mutate-ok", .{cand.waived});
        return;
    }
    if (picked.len < cand.mutants.len) {
        reporter.ok("mutate: sampled {d} of {d} candidate mutants (max_mutants = {d})", .{
            picked.len, cand.mutants.len, ctx.cfg.mutation.max_mutants,
        });
    }
    if (cand.waived > 0) reporter.ok("mutate: {d} site(s) waived via mutate-ok", .{cand.waived});

    const scored = try execute(ctx, picked, suiteHex(ctx));
    try report(ctx, scored, cand.waived);
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
        var all: std.ArrayListUnmanaged(gen.Mutant) = .empty;
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

    var out: std.ArrayListUnmanaged(gen.Mutant) = .empty;
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
fn execute(ctx: *types.RunCtx, picked: []const gen.Mutant, suite_hex: ?[]const u8) types.RunError!ScoredRun {
    const a = ctx.allocator;
    const ns_per_sec: u64 = std.time.ns_per_s;
    const opts: runner.RunOpts = .{
        .project_dir = ctx.project_dir,
        .timeout_ns = @as(u64, ctx.cfg.mutation.timeout_secs) * ns_per_sec,
    };
    // A refresh (GUARDIAN_UPDATE_SNAPSHOT covering mutate) bypasses cache reads:
    // a fresh ratchet must be a fresh measurement, not a replay.
    const mode: mut_cache.Reuse = if (snapshot_helper.shouldUpdateFor(a, "mutate")) .fresh else .reuse;
    const cache_map: mut_cache.Map = if (suite_hex) |h| mut_cache.load(a, ctx.project_dir, h, mode) else .{};

    var scored: ScoredRun = .{};
    for (picked, 1..) |m, i| {
        const key = try mut_cache.keyFor(a, m);
        if (cache_map.get(key)) |cached_outcome| {
            scored.score.add(cached_outcome);
            scored.cached += 1;
            detail("  [{d}/{d}] {s}:{d} `{s}` -> `{s}` ... {s} (cached)\n", .{
                i, picked.len, m.path, m.line, m.original, m.replacement, @tagName(cached_outcome),
            });
            if (cached_outcome == .survived) try scored.addSurvivor(a, m);
            continue;
        }
        const outcome = runner.runOne(a, opts, m) catch |e| switch (e) {
            error.StaleMutant => {
                detail("  [{d}/{d}] {s}:{d} skipped (file changed mid-run)\n", .{ i, picked.len, m.path, m.line });
                continue;
            },
            else => return e,
        };
        scored.score.add(outcome);
        if (suite_hex) |h| mut_cache.append(a, ctx.project_dir, h, m, outcome);
        detail("  [{d}/{d}] {s}:{d} `{s}` -> `{s}` ... {s}\n", .{
            i, picked.len, m.path, m.line, m.original, m.replacement, @tagName(outcome),
        });
        if (outcome == .survived) try scored.addSurvivor(a, m);
    }
    return scored;
}

/// A finished run: outcome tallies, the surviving mutants, and how many outcomes
/// were reused from the result cache.
const ScoredRun = struct {
    score: runner.Score = .{},
    survivors: std.ArrayListUnmanaged(report_mod.Survivor) = .empty,
    cached: u32 = 0,

    /// Records a surviving mutant with the context the survivor report needs.
    fn addSurvivor(self: *ScoredRun, a: Allocator, m: gen.Mutant) Allocator.Error!void {
        try self.survivors.append(a, .{
            .file = m.path,
            .line = m.line,
            .original = m.original,
            .replacement = m.replacement,
            .src_line = m.src_line,
        });
    }
};

/// Applies the small-diff floor, the min-score gate (both tiers), and the
/// snapshot ratchet (--full only), then prints the verdict. Always writes the
/// machine-readable survivor report. Below the `min_mutants` floor the run
/// reports its survivors informationally and passes without touching the ratchet.
fn report(ctx: *types.RunCtx, scored: ScoredRun, waived: u32) types.RunError!void {
    const s = scored.score;
    const pct = s.pct();
    const viable = s.viable();
    const min_mutants = ctx.cfg.mutation.min_mutants;
    const gated = gatedByPercentage(viable, min_mutants);

    reporter.ok("mutate: score {d}% — {d} killed, {d} timed out, {d} survived, {d} unviable", .{
        pct, s.killed, s.timed_out, s.survived, s.unviable,
    });
    if (scored.cached > 0) reporter.ok("mutate: reused {d} cached outcome(s)", .{scored.cached});

    writeMachineReport(ctx, scored, waived, gated, pct);

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
    if (ctx.full and !try ratchet(ctx, pct)) failed = true;

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
fn ratchet(ctx: *types.RunCtx, pct: u32) types.RunError!bool {
    const a = ctx.allocator;
    const path = try snapshot_helper.snapshotPath(a, ctx.project_dir, SNAPSHOT_LEAF);
    const old = readScore(a, path);
    const force = snapshot_helper.shouldUpdateFor(a, "mutate");
    const decision = runner.ratchetDecision(old, pct);
    if (decision == .regressed and !force) {
        reporter.fail("mutate FAILED: score {d}% regressed below the snapshot ratchet {d}%", .{ pct, old.? });
        detail("  accept deliberately with {s}=1, or strengthen the tests.\n", .{snapshot_helper.UPDATE_ENV});
        return false;
    }
    try writeScore(a, path, pct);
    reporter.ok("mutate: score ratchet {s} at {d}% ({s})", .{ @tagName(decision), pct, SNAPSHOT_LEAF });
    return true;
}

/// Reads the prior score from the snapshot file; null when absent/unreadable.
fn readScore(a: Allocator, path: []const u8) ?u32 {
    const snap = snapshot.read(a, path, SNAPSHOT_VERSION) catch return null;
    for (snap.lines) |line| {
        if (std.mem.startsWith(u8, line, SCORE_KEY)) {
            return std.fmt.parseInt(u32, line[SCORE_KEY.len..], 10) catch null;
        }
    }
    return null;
}

fn writeScore(a: Allocator, path: []const u8, pct: u32) types.RunError!void {
    var lines = [_][]const u8{try std.fmt.allocPrint(a, "{s}{d}", .{ SCORE_KEY, pct })};
    try snapshot.write(path, SNAPSHOT_VERSION, &lines);
}

/// Prints each survivor: file:line, the operator swap, and the original source
/// line — the exact context an agent needs to write the killing test.
fn listSurvivors(survivors: []const report_mod.Survivor) void {
    for (survivors, 0..) |s, i| {
        if (i >= MAX_REPORTED_SURVIVORS) {
            detail("  ... and {d} more survivor(s)\n", .{survivors.len - MAX_REPORTED_SURVIVORS});
            return;
        }
        detail("  {s}:{d}: `{s}` -> `{s}` survived\n      {s}\n", .{
            s.file, s.line, s.original, s.replacement, std.mem.trim(u8, s.src_line, &std.ascii.whitespace),
        });
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

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
