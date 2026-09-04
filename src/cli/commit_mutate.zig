//! The commit gate's opt-in fast mutation tier.
//!
//! Static checks prove a behavior is *described*; the suite proves it *runs*.
//! Neither proves a test would notice the line being wrong — and that is the
//! defect class Guardian Arena kept scoring zero on: across 36 seeded historical
//! defects with correct-implementation controls, the only mechanism that reached
//! one was `mutate`'s fast tier, whose first mutant on the changed lines was
//! byte-identical to the sealed reference fix and survived the whole suite. It
//! scored nothing because `mutate` is not part of the gate. This module is that
//! tier, wired into `commit` behind `[mutation] on_commit` (default false).
//!
//! The tier runs AFTER `[gate] test_command` passes (a red suite is a cheaper,
//! clearer answer) and BEFORE the commit is created, and a failing verdict
//! refuses the commit.
//!
//! **It never mutates the user's working tree.** `mutate` splices each mutant
//! into the source file in place and restores it afterwards; under `commit` the
//! working tree holds uncommitted work, and a failed restore (`NoSpaceLeft` has
//! been seen) would destroy it. So the candidate tree is materialised as a
//! throwaway detached worktree — `git stash create` records the tracked changes
//! without touching the tree, the index, or the stash reflog, and the untracked
//! files are copied in after checkout — and every splice lands there. The
//! worktree is removed on every exit path (see `withScratch`), and a leftover
//! from a killed run is cleared before the next one starts.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const config = @import("../config.zig");
const git = @import("../git.zig");
const fs = @import("../fs.zig");
const wiring = @import("../wiring.zig");
const mutate = @import("mutate.zig");
const report_mod = @import("../mutation/report.zig");

const Allocator = std.mem.Allocator;

/// Project-relative home of the scratch worktree. Under `.guardian/cache/`
/// because that tree is git-ignored and excluded from the green-cache digest,
/// so a campaign in flight can neither be staged nor invalidate the skip cache.
pub const scratch_leaf = ".guardian/cache/commit-mutate";

/// KiB in a GiB — `df -Pk` reports 1024-byte blocks and the floor is configured
/// in GiB.
const kib_per_gib: u64 = 1024 * 1024;
/// Zero-based field index of `Available` on a `df -P` row.
const df_avail_field: usize = 3;
/// Output cap for the `df` probe: a two-line table needs nothing more.
const max_probe_bytes: u64 = 64 * 1024;
/// Per-file cap when copying an untracked file into the scratch worktree.
const max_copy_bytes: usize = 16 * 1024 * 1024;

/// True when the project has opted the fast mutation tier into `commit`.
/// Off unless `[mutation] on_commit` says otherwise: the tier rebuilds and
/// re-tests the project once per mutant, so nobody inherits that latency by
/// upgrading Guardian.
pub fn enabled(cfg: *const config.Config) bool {
    return cfg.mutation.on_commit;
}

/// True when `avail_kib` of free space satisfies a floor of `min_free_gib`.
/// A floor of 0 opts out. Pure, so the refusal boundary is tested without a
/// filesystem.
pub fn floorMet(avail_kib: u64, min_free_gib: u32) bool {
    return avail_kib >= @as(u64, min_free_gib) * kib_per_gib;
}

/// The `Available` KiB column of `df -Pk` output, or null when the text is not
/// a POSIX df table. `-P` guarantees one physical line per filesystem, so the
/// second line is the row and its fourth field is the answer.
pub fn parseAvailKib(df_output: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, df_output, '\n');
    _ = lines.next() orelse return null; // header
    const row = lines.next() orelse return null;
    var fields = std.mem.tokenizeAny(u8, row, " \t\r");
    var i: usize = 0;
    while (fields.next()) |field| : (i += 1) {
        if (i == df_avail_field) return std.fmt.parseInt(u64, field, 10) catch null;
    }
    return null;
}

/// True when `err` is the tier's own verdict — the mutation score failed its
/// gate — rather than an infrastructure failure (OOM, git, the filesystem).
/// A verdict refuses the commit with an explanation; anything else propagates
/// unchanged, because "the disk went away" must not read as "your tests are weak".
pub fn isVerdictFailure(err: types.RunError) bool {
    return err == error.CheckFailed;
}

/// The run context the tier executes under: the scratch worktree as the project
/// dir, the resolved base sha as the diff ref, and the FAST tier.
///
/// Every whole-run memo of the parent is cleared: the parsed source index, the
/// diff scope, the renames and the reachability analysis all describe the user's
/// tree, and reusing one here would mutate one tree while reading another.
pub fn scratchCtx(parent: *const types.RunCtx, scratch_dir: []const u8, base: []const u8) types.RunCtx {
    var child = parent.*;
    child.project_dir = scratch_dir;
    child.against = base;
    child.full = false; // the commit tier is the diff tier, never the whole tree
    child.source_index = null;
    child.scoped = null;
    child.renames = null;
    child.test_reach = null;
    child.writer_lock_held = false;
    child.only = &.{};
    child.skip = &.{};
    child.roi_phase = "mutate";
    return child;
}

/// Runs the tier when it is enabled, and returns `error.CheckFailed` when its
/// verdict refuses the commit. A disabled tier is silent; every other exit path
/// says what happened and why.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    if (!enabled(ctx.cfg)) return;
    reporter.ok("commit: mutation tier — fast (changed lines only), opt-in via [mutation] on_commit", .{});
    try requireFreeDisk(ctx);
    const base = git.resolveRef(ctx.allocator, ctx.project_dir, againstRef(ctx)) orelse {
        reporter.ok("commit: mutation tier skipped — base ref `{s}` resolves to no commit", .{againstRef(ctx)});
        return;
    };
    try withScratch(ctx, base, runTier);
}

/// The base ref the tier diffs against — the same resolution order `commit`
/// already uses for change-classification (`--against`, `GUARDIAN_AGAINST`,
/// `[change_classification] against`, then HEAD), so both gates judge one diff.
fn againstRef(ctx: *const types.RunCtx) []const u8 {
    return ctx.against orelse ctx.cfg.change_classification.against;
}

/// Refuses to start when free disk is under `[mutation] min_free_gib`. Fails
/// CLOSED: a campaign writes a whole checkout plus a per-campaign Zig cache, and
/// a commit gate that cannot run its tier has not verified the commit. An
/// unmeasurable filesystem is not a refusal — the scratch tree is disposable, so
/// the floor is a courtesy, not the safety property.
fn requireFreeDisk(ctx: *types.RunCtx) types.RunError!void {
    const floor = ctx.cfg.mutation.min_free_gib;
    const avail = availKib(ctx.allocator, ctx.project_dir) orelse {
        reporter.ok("commit: mutation tier — free disk could not be measured; proceeding", .{});
        return;
    };
    if (floorMet(avail, floor)) return;
    reporter.fail(
        "commit: mutation tier refused to start — {d} GiB free, below [mutation] min_free_gib = {d}",
        .{ avail / kib_per_gib, floor },
    );
    reporter.detail(
        "  free space and re-run, lower [mutation] min_free_gib, or set [mutation] on_commit = false.\n",
        .{},
    );
    return error.CheckFailed;
}

/// Free KiB on the filesystem holding `project_dir`, via `df -Pk`. Null when df
/// is absent or its output is unrecognised — the caller treats that as
/// "unmeasured", never as "full".
fn availKib(allocator: Allocator, project_dir: []const u8) ?u64 {
    const res = std.process.run(allocator, wiring.io(), .{
        .argv = &.{ "df", "-Pk", "." },
        .cwd = .{ .path = project_dir },
        .stdout_limit = .limited64(max_probe_bytes),
        .stderr_limit = .limited64(max_probe_bytes),
    }) catch return null;
    if (!res.term.success()) return null;
    return parseAvailKib(res.stdout);
}

/// What `withScratch` invokes once the candidate tree exists on disk.
const ScratchBody = *const fn (parent: *types.RunCtx, scratch_dir: []const u8, base: []const u8) types.RunError!void;

/// Materialises the candidate tree as a scratch worktree, runs `body` against
/// it, and removes the worktree on EVERY exit path — success, a refused
/// verdict, or an infrastructure error. Nothing under this function touches the
/// user's working tree.
fn withScratch(ctx: *types.RunCtx, base: []const u8, body: ScratchBody) types.RunError!void {
    const scratch_dir = try fs.path.join(ctx.allocator, &.{ ctx.project_dir, scratch_leaf });
    try createScratch(ctx, scratch_dir);
    defer removeScratch(ctx, scratch_dir);
    defer salvageReport(ctx, scratch_dir);
    try copyUntracked(ctx, scratch_dir);
    return body(ctx, scratch_dir, base);
}

/// The tier itself: `mutate`'s fast tier, run in the scratch worktree against
/// the candidate tree's base. Its own output (score line, survivors, the
/// strengthen-the-tests hint) is already the report we want; this adds only the
/// commit-level verdict.
fn runTier(parent: *types.RunCtx, scratch_dir: []const u8, base: []const u8) types.RunError!void {
    var child = scratchCtx(parent, scratch_dir, base);
    mutate.run(&child) catch |err| {
        if (!isVerdictFailure(err)) return err;
        reporter.fail("commit: mutation tier refused the commit — nothing committed", .{});
        reporter.detail(
            "  each survivor above is a line this change touched that no test constrains.\n" ++
                "  investigate with `zig build mutate` (or `guardian-check mutate . --against {s}`);\n" ++
                "  opt out with [mutation] on_commit = false.\n",
            .{base},
        );
        return error.CheckFailed;
    };
    reporter.ok("commit: mutation tier passed", .{});
}

/// Checks the candidate tree out into a fresh detached worktree. A leftover from
/// a killed run is cleared first — the removal is a `defer`, and a signal
/// handler's re-raise skips those.
fn createScratch(ctx: *types.RunCtx, scratch_dir: []const u8) types.RunError!void {
    removeScratch(ctx, scratch_dir);
    // `git stash create` returns nothing for a clean tree: then HEAD already IS
    // the candidate tree (any change must be untracked, and those are copied in).
    const commitish = git.stashCreate(ctx.allocator, ctx.project_dir) orelse "HEAD";
    if (git.worktreeAdd(ctx.allocator, ctx.project_dir, scratch_leaf, commitish)) return;
    reporter.fail("commit: mutation tier could not create its scratch worktree at {s}", .{scratch_leaf});
    return error.CheckFailed;
}

/// Removes the scratch worktree and its git administrative record. Best-effort
/// and never fatal: it runs on the failure path too, where a more useful verdict
/// is already on its way out.
fn removeScratch(ctx: *types.RunCtx, scratch_dir: []const u8) void {
    _ = git.worktreeRemove(ctx.allocator, ctx.project_dir, scratch_leaf);
    fs.cwd().deleteTree(scratch_dir) catch |err| {
        reporter.detail("  commit: could not remove {s}: {s}\n", .{ scratch_dir, @errorName(err) });
    };
}

/// Copies every untracked, non-ignored file into the scratch worktree.
///
/// `git stash create` captures tracked changes only, so without this a brand-new
/// module would be missing from the candidate tree — and a tree that no longer
/// compiles scores every mutant `unviable`, which is a vacuous 100% green, not a
/// smaller sample. Ignored paths (build output, the cache) are excluded by
/// `--exclude-standard`, so this copies sources, not artifacts — and the scratch
/// worktree excludes itself, which matters in a project that does not gitignore
/// `.guardian/cache/`.
fn copyUntracked(ctx: *types.RunCtx, scratch_dir: []const u8) types.RunError!void {
    const a = ctx.allocator;
    for (try git.untrackedFiles(a, ctx.project_dir)) |rel| {
        // The scratch worktree is itself untracked (and, being a nested
        // repository, git reports it as one entry): copying it into itself is
        // the one path here that recurses.
        if (std.mem.startsWith(u8, rel, scratch_leaf)) continue;
        const src = try fs.path.join(a, &.{ ctx.project_dir, rel });
        const dest = try fs.path.join(a, &.{ scratch_dir, rel });
        const bytes = fs.cwd().readFileAlloc(a, src, max_copy_bytes) catch |err| {
            reporter.detail("  commit: mutation tier skipped untracked {s}: {s}\n", .{ rel, @errorName(err) });
            continue;
        };
        if (fs.path.dirname(dest)) |parent| try fs.cwd().makePath(parent);
        fs.cwd().writeFile(.{ .sub_path = dest, .data = bytes }) catch |err| {
            reporter.detail("  commit: mutation tier could not stage {s}: {s}\n", .{ rel, @errorName(err) });
        };
    }
}

/// Copies the scratch run's `last-mutate.jsonl` back into the real project, so
/// the machine-readable survivor report outlives the worktree it was produced
/// in. Best-effort: a missing report is the ordinary case for a run that never
/// reached scoring.
fn salvageReport(ctx: *types.RunCtx, scratch_dir: []const u8) void {
    const a = ctx.allocator;
    const from = report_mod.pathFor(a, scratch_dir) catch return;
    const to = report_mod.pathFor(a, ctx.project_dir) catch return;
    const bytes = fs.cwd().readFileAlloc(a, from, max_copy_bytes) catch return;
    if (fs.path.dirname(to)) |parent| fs.cwd().makePath(parent) catch return;
    fs.cwd().writeFile(.{ .sub_path = to, .data = bytes }) catch |err| {
        reporter.detail("  commit: could not save the mutation report: {s}\n", .{@errorName(err)});
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const ast_index = @import("../ast/index.zig");

// spec: Commit Mutation Tier - Leaves the commit mutation tier off until on_commit enables it

test "the commit mutation tier is opt-in and off by default" {
    const defaults: config.Config = .{};
    try testing.expect(!defaults.mutation.on_commit);
    try testing.expect(!enabled(&defaults));
    var opted: config.Config = .{};
    opted.mutation.on_commit = true;
    try testing.expect(enabled(&opted));
}

// spec: Commit Mutation Tier - Refuses to start when free disk is below the configured floor

test "the disk floor reads df output and refuses below the configured GiB" {
    const table =
        "Filesystem     1024-blocks      Used Available Capacity Mounted on\n" ++
        "/dev/mapper/vg   488510864 329461152 138087920      71% /\n";
    try testing.expectEqual(@as(u64, 138_087_920), parseAvailKib(table).?);
    // Unparseable output is "unmeasured", never "full" — a df that printed a
    // header and nothing else must not refuse a commit.
    try testing.expect(parseAvailKib("Filesystem 1024-blocks\n") == null);
    try testing.expect(parseAvailKib("") == null);
    // 5 GiB floor: 5 GiB exactly clears it, one KiB short does not.
    try testing.expect(floorMet(5 * kib_per_gib, 5));
    try testing.expect(!floorMet(5 * kib_per_gib - 1, 5));
    // A zero floor opts out.
    try testing.expect(floorMet(0, 0));
}

// spec: Commit Mutation Tier - Runs the fast diff tier against the resolved base ref

test "scratchCtx retargets the run at the scratch tree and clears the parent's memos" {
    const cfg: config.Config = .{};
    var index: ast_index.Index = undefined;
    const parent: types.RunCtx = .{
        .allocator = testing.allocator,
        .project_dir = "/work/project",
        .cfg = &cfg,
        .quiet = true,
        // A whole-tree mutate and a parsed index of the USER's tree: reusing
        // either would mutate one tree while reading another.
        .full = true,
        .source_index = &index,
        .against = null,
        .roi_phase = "gate",
    };
    const child = scratchCtx(&parent, "/work/project/" ++ scratch_leaf, "abc123");
    try testing.expectEqualStrings("/work/project/" ++ scratch_leaf, child.project_dir);
    try testing.expectEqualStrings("abc123", child.against.?);
    try testing.expect(!child.full);
    try testing.expect(child.source_index == null);
    try testing.expect(child.scoped == null);
    try testing.expect(child.test_reach == null);
    try testing.expectEqualStrings("mutate", child.roi_phase.?);
}

// spec: Commit Mutation Tier - Refuses the commit on a failing verdict and propagates other errors

test "only a failing mutation verdict is treated as a refusal" {
    try testing.expect(isVerdictFailure(error.CheckFailed));
    // Infrastructure failures must reach the caller as themselves: reporting
    // "your tests are weak" because git or the disk broke is a lie.
    try testing.expect(!isVerdictFailure(error.OutOfMemory));
    try testing.expect(!isVerdictFailure(error.GitCommandFailed));
    try testing.expect(!isVerdictFailure(error.StaleMutant));
}

/// Fixture file names: one tracked-and-edited path, one brand-new untracked one.
const fixture_tracked = "kept.txt";
const fixture_untracked = "added.txt";
const fixture_committed = "committed\n";
const fixture_edited = "edited\n";
const fixture_new = "brand new\n";

/// Builds a one-commit repository whose working tree holds an edited tracked
/// file and a new untracked one — the shape a `commit` gate sees. Returns
/// `error.SkipZigTest` when git cannot be spawned at all.
fn scratchFixture(a: Allocator, dir: []const u8) !void {
    fs.cwd().deleteTree(dir) catch |err| std.log.warn("fixture reset: {s}", .{@errorName(err)});
    try fs.cwd().makePath(dir);
    try runFixtureGit(a, dir, &.{ "git", "init", "-q", "." });
    try runFixtureGit(a, dir, &.{ "git", "config", "user.email", "guardian@example.invalid" });
    try runFixtureGit(a, dir, &.{ "git", "config", "user.name", "guardian" });
    try writeFixture(a, dir, fixture_tracked, fixture_committed);
    try runFixtureGit(a, dir, &.{ "git", "add", fixture_tracked });
    try runFixtureGit(a, dir, &.{ "git", "commit", "-qm", "base" });
    try writeFixture(a, dir, fixture_tracked, fixture_edited);
    try writeFixture(a, dir, fixture_untracked, fixture_new);
}

fn writeFixture(a: Allocator, dir: []const u8, leaf: []const u8, data: []const u8) !void {
    try fs.cwd().writeFile(.{ .sub_path = try fs.path.join(a, &.{ dir, leaf }), .data = data });
}

fn runFixtureGit(a: Allocator, dir: []const u8, argv: []const []const u8) !void {
    const res = std.process.run(a, wiring.io(), .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .stdout_limit = .limited64(max_probe_bytes),
        .stderr_limit = .limited64(max_probe_bytes),
    }) catch return error.SkipZigTest; // no git on this box
    if (!res.term.success()) return error.FixtureGitFailed;
}

fn fixtureRead(a: Allocator, dir: []const u8, leaf: []const u8) ![]u8 {
    return fs.cwd().readFileAlloc(a, try fs.path.join(a, &.{ dir, leaf }), max_copy_bytes);
}

/// A `withScratch` body that inspects the materialised candidate tree and then
/// fails the way a refused mutation verdict does. It reports the verdict error
/// ONLY when the candidate tree is exactly right, so one `expectError` proves
/// both the materialisation and the cleanup that follows it.
fn verdictProbeBody(parent: *types.RunCtx, scratch_dir: []const u8, base: []const u8) types.RunError!void {
    _ = base;
    const a = parent.allocator;
    const kept = fixtureRead(a, scratch_dir, fixture_tracked) catch return error.FileTooBig;
    const added = fixtureRead(a, scratch_dir, fixture_untracked) catch return error.FileTooBig;
    const faithful = std.mem.eql(u8, kept, fixture_edited) and std.mem.eql(u8, added, fixture_new);
    return if (faithful) error.CheckFailed else error.FileTooBig;
}

// spec: Commit Mutation Tier - Mutates a scratch worktree and removes it even when the tier fails

test "withScratch materialises the candidate tree, spares the working tree, and always cleans up" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/commit-mutate-scratch";
    try scratchFixture(a, dir);
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("fixture cleanup: {s}", .{@errorName(e)});

    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &cfg, .quiet = true };
    const base = git.resolveRef(a, dir, "HEAD").?;
    // error.CheckFailed is reported by the probe only when the scratch tree
    // carried BOTH the tracked edit and the brand-new untracked file — a
    // candidate tree missing either is not the tree about to be committed.
    try testing.expectError(error.CheckFailed, withScratch(&ctx, base, verdictProbeBody));
    // Removed on the FAILURE path: the mutation runner splices source in place,
    // so a worktree left behind is a half-mutated checkout on the user's disk.
    const scratch_dir = try fs.path.join(a, &.{ dir, scratch_leaf });
    try testing.expectError(error.FileNotFound, fs.cwd().access(scratch_dir, .{}));
    // And the user's own working tree is byte-identical to before the run.
    try testing.expectEqualStrings(fixture_edited, try fixtureRead(a, dir, fixture_tracked));
}

test "the candidate tree is recorded and checked out through the three git primitives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/commit-mutate-primitives";
    try scratchFixture(a, dir);
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("fixture cleanup: {s}", .{@errorName(e)});

    // A dirty tree records as a dangling commit, and recording it leaves the
    // working tree exactly as it was (no stash push, no index write).
    const candidate = git.stashCreate(a, dir).?;
    try testing.expectEqualStrings(fixture_edited, try fixtureRead(a, dir, fixture_tracked));
    try testing.expect(git.worktreeAdd(a, dir, scratch_leaf, candidate));
    const scratch_dir = try fs.path.join(a, &.{ dir, scratch_leaf });
    try testing.expectEqualStrings(fixture_edited, try fixtureRead(a, scratch_dir, fixture_tracked));
    try testing.expect(git.worktreeRemove(a, dir, scratch_leaf));
    try testing.expectError(error.FileNotFound, fs.cwd().access(scratch_dir, .{}));
}
