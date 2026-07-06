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

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const ast_index = @import("../ast/index.zig");
const git = @import("../git.zig");
const gen = @import("../mutation/gen.zig");
const runner = @import("../mutation/runner.zig");
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

/// Entry point for the mutate command.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, a, ctx.project_dir, &storage);

    const candidates = try collectCandidates(ctx, idx) orelse return;
    const picked = try gen.sample(a, candidates, ctx.cfg.mutation.max_mutants);
    if (picked.len == 0) {
        reporter.ok("mutate: no mutants to run ({s})", .{
            if (ctx.full) "no mutation sites found" else "no changed production lines",
        });
        return;
    }
    if (picked.len < candidates.len) {
        reporter.ok("mutate: sampled {d} of {d} candidate mutants (max_mutants = {d})", .{
            picked.len, candidates.len, ctx.cfg.mutation.max_mutants,
        });
    }

    const score = try execute(ctx, picked);
    try report(ctx, score);
}

/// Generates the candidate mutant list for this tier: every indexed file in
/// --full mode, only diff-touched lines otherwise. Null means the run was
/// skipped (fast tier without usable git state) and a note was printed.
fn collectCandidates(ctx: *types.RunCtx, idx: *const ast_index.Index) types.RunError!?[]const gen.Mutant {
    const a = ctx.allocator;
    if (ctx.full) {
        var all: std.ArrayListUnmanaged(gen.Mutant) = .empty;
        for (idx.files) |f| {
            try all.appendSlice(a, try gen.generate(a, f.rel_path, f.content));
        }
        return try all.toOwnedSlice(a);
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
/// mutant in untracked (brand new) source files.
fn diffCandidates(
    ctx: *types.RunCtx,
    idx: *const ast_index.Index,
    file_diffs: []const git.FileDiff,
) types.RunError![]const gen.Mutant {
    const a = ctx.allocator;
    var span_map: std.StringHashMapUnmanaged([]const git.LineSpan) = .empty;
    for (file_diffs) |fd| try span_map.put(a, fd.path, fd.spans);
    const untracked = try git.untrackedFiles(a, ctx.project_dir);

    var out: std.ArrayListUnmanaged(gen.Mutant) = .empty;
    for (idx.files) |f| {
        if (span_map.get(f.rel_path)) |spans| {
            const all = try gen.generate(a, f.rel_path, f.content);
            try out.appendSlice(a, try gen.filterToSpans(a, all, spans));
        } else if (contains(untracked, f.rel_path)) {
            try out.appendSlice(a, try gen.generate(a, f.rel_path, f.content));
        }
    }
    return out.toOwnedSlice(a);
}

fn contains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

/// Runs every picked mutant, printing a progress line per mutant and
/// tallying outcomes. Stale mutants (file changed mid-run) are skipped.
fn execute(ctx: *types.RunCtx, picked: []const gen.Mutant) types.RunError!ScoredRun {
    const a = ctx.allocator;
    const ns_per_sec: u64 = std.time.ns_per_s;
    const opts: runner.RunOpts = .{
        .project_dir = ctx.project_dir,
        .timeout_ns = @as(u64, ctx.cfg.mutation.timeout_secs) * ns_per_sec,
    };
    var scored: ScoredRun = .{};
    for (picked, 1..) |m, i| {
        const outcome = runner.runOne(a, opts, m) catch |e| switch (e) {
            error.StaleMutant => {
                detail("  [{d}/{d}] {s}:{d} skipped (file changed mid-run)\n", .{ i, picked.len, m.path, m.line });
                continue;
            },
            else => return e,
        };
        scored.score.add(outcome);
        detail("  [{d}/{d}] {s}:{d} `{s}` -> `{s}` ... {s}\n", .{
            i, picked.len, m.path, m.line, m.original, m.replacement, @tagName(outcome),
        });
        if (outcome == .survived) {
            const desc = try std.fmt.allocPrint(a, "{s}:{d}: `{s}` -> `{s}` passed the whole suite", .{
                m.path, m.line, m.original, m.replacement,
            });
            try scored.survivors.append(a, desc);
        }
    }
    return scored;
}

/// A finished run: outcome tallies plus the surviving mutants' descriptions.
const ScoredRun = struct {
    score: runner.Score = .{},
    survivors: std.ArrayListUnmanaged([]const u8) = .empty,
};

/// Applies the min-score gate (both tiers) and the snapshot ratchet
/// (--full only), then prints the verdict.
fn report(ctx: *types.RunCtx, scored: ScoredRun) types.RunError!void {
    const s = scored.score;
    const pct = s.pct();
    reporter.ok("mutate: score {d}% — {d} killed, {d} timed out, {d} survived, {d} unviable", .{
        pct, s.killed, s.timed_out, s.survived, s.unviable,
    });

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

/// Full-tier score ratchet against .guardian/mutation.txt. Returns false
/// (and reports) on an unforced regression; creates/raises/holds otherwise.
fn ratchet(ctx: *types.RunCtx, pct: u32) types.RunError!bool {
    const a = ctx.allocator;
    const path = try snapshot_helper.snapshotPath(a, ctx.project_dir, SNAPSHOT_LEAF);
    const old = readScore(a, path);
    const force = snapshot_helper.shouldUpdate(a);
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

fn listSurvivors(survivors: []const []const u8) void {
    for (survivors, 0..) |s, i| {
        if (i >= MAX_REPORTED_SURVIVORS) {
            detail("  ... and {d} more survivor(s)\n", .{survivors.len - MAX_REPORTED_SURVIVORS});
            return;
        }
        detail("  {s}\n", .{s});
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
