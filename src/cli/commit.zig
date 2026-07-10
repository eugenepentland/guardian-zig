//! `commit` command — intent-driven auto-commit, bringing guardian-zig into
//! the sibling guardians' workflow. `guardian-check commit --intent "<msg>"
//! [dir]` runs the full `all` gate; on green it stages the working-tree change
//! set and commits it with the intent as the subject. On red it prints the
//! violations and leaves git untouched.
//!
//! Staging is safety-railed (modelled on guardian-sveltekit/src/commit.ts):
//! never `git add -A` / `.`; the path list comes from `git status --porcelain`
//! (modified + untracked); a forbidden secret/build-artifact list is skipped
//! (and reported); `.guardian/` metadata and SPEC.md are always included so the
//! baseline/snapshot churn a run produced rides the commit that caused it.
//!
//! Because it gates the exact working-tree diff it is about to commit,
//! change-classification's diff-timing hole is structurally closed for this
//! flow. Dispatched specially by check.zig (like nightly): its run composes
//! run_all.run, and run_all imports the registry, so a registry entry would
//! close an @import cycle. The run_all SKIP list and build_helper name it
//! defensively so it can never be treated as a gate.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const run_all = @import("run_all.zig");
const git = @import("../git.zig");

const Allocator = std.mem.Allocator;

/// CLI name that check.zig dispatches to this command.
pub const command_name = "commit";

/// Entry point for the commit command. Requires a non-empty `--intent`, runs
/// the full gate, and on green stages + commits the eligible change set. On a
/// red gate (or a missing intent) it returns error.CheckFailed with git
/// untouched.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const intent = validIntent(ctx.intent) orelse {
        reporter.fail("commit: --intent \"<message>\" is required (missing or empty)", .{});
        return error.CheckFailed;
    };

    // Gate the exact working tree we're about to commit. On red the check output
    // was already printed by run_all; git state is left untouched.
    run_all.run(ctx) catch |e| switch (e) {
        error.CheckFailed => {
            reporter.fail("commit: gate failed — nothing committed", .{});
            return error.CheckFailed;
        },
        else => return e,
    };

    return stageAndCommit(ctx, intent);
}

/// Trims `intent`; null when absent or blank — so a missing/empty `--intent`
/// is a clean error with no side effects.
fn validIntent(intent: ?[]const u8) ?[]const u8 {
    const s = intent orelse return null;
    const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// Stages the eligible change set (skipping/reporting forbidden paths) and
/// commits it with `intent`. A green gate with an empty stage set is a no-op.
fn stageAndCommit(ctx: *types.RunCtx, intent: []const u8) types.RunError!void {
    const a = ctx.allocator;
    const changed = (try git.changedPaths(a, ctx.project_dir)) orelse {
        reporter.fail("commit: `git status` failed — not a git repo, or git unavailable", .{});
        return error.CheckFailed;
    };
    const plan = try planStaging(a, changed, ctx.cfg.spec_file);

    if (plan.skipped.len > 0) {
        reporter.ok("commit: skipped {d} forbidden path(s) — NOT staged (fix .gitignore):", .{plan.skipped.len});
        for (plan.skipped) |p| reporter.detail("  skipped: {s}\n", .{p});
    }
    if (plan.stage.len == 0) {
        reporter.ok("commit: nothing to commit", .{});
        return;
    }
    if (!try git.addPaths(a, ctx.project_dir, plan.stage)) {
        reporter.fail("commit: `git add` failed — nothing committed", .{});
        return error.CheckFailed;
    }
    if (!git.commit(a, ctx.project_dir, intent)) {
        reporter.fail("commit: `git commit` failed", .{});
        return error.CheckFailed;
    }
    const hash = git.headHash(a, ctx.project_dir) orelse "(unknown)";
    reporter.ok("commit: {s} — \"{s}\" ({d} path(s) staged)", .{ hash, intent, plan.stage.len });
}

/// The staging split: paths to stage vs the forbidden paths that were skipped.
const StagePlan = struct {
    stage: []const []const u8,
    skipped: []const []const u8,
};

/// Partitions `changed` into the stage set and the skipped-forbidden set. Pure
/// over its inputs so the rails are unit-tested without touching git.
fn planStaging(a: Allocator, changed: []const []const u8, spec_file: []const u8) Allocator.Error!StagePlan {
    var stage: std.ArrayList([]const u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (changed) |p| {
        switch (stagingDecision(p, spec_file)) {
            .stage => try stage.append(a, p),
            .skip_forbidden => try skipped.append(a, p),
        }
    }
    return .{ .stage = try stage.toOwnedSlice(a), .skipped = try skipped.toOwnedSlice(a) };
}

/// What to do with one changed path.
const StageAction = enum { stage, skip_forbidden };

/// Per-path staging decision: the always-include set (guardian metadata + the
/// spec file) wins over the forbidden filter, which wins over the default of
/// staging the path.
fn stagingDecision(path: []const u8, spec_file: []const u8) StageAction {
    if (alwaysInclude(path, spec_file)) return .stage;
    if (isForbidden(path)) return .skip_forbidden;
    return .stage;
}

/// True for paths always carried by the commit: `.guardian/` metadata (so
/// baseline/snapshot churn rides the commit that caused it) and the spec file.
fn alwaysInclude(path: []const u8, spec_file: []const u8) bool {
    if (underDir(path, ".guardian")) return true;
    if (std.mem.eql(u8, path, spec_file)) return true;
    return false;
}

/// True for a secret or build-artifact path that must never be staged — the
/// safety rail against committing a credential the project's .gitignore missed.
/// Mirrors guardian-sveltekit's forbidden list, Zig-flavored.
fn isForbidden(path: []const u8) bool {
    const base = baseName(path);
    if (underDir(path, "zig-out") or underDir(path, ".zig-cache") or underDir(path, "zig-cache")) return true;
    if (std.mem.eql(u8, base, ".env") or std.mem.startsWith(u8, base, ".env.")) return true;
    if (std.mem.startsWith(u8, base, "id_rsa")) return true;
    if (endsWithAny(base, &.{ ".pem", ".key", ".p12" })) return true;
    if (containsAny(path, &.{ "credentials", "secret" })) return true;
    return false;
}

/// True when `path` sits inside the directory `dir` (`<dir>/…`).
fn underDir(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
}

/// The final path segment after the last `/` (the whole string if none).
fn baseName(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

/// True when `s` ends with any of `suffixes`.
fn endsWithAny(s: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suf| if (std.mem.endsWith(u8, s, suf)) return true;
    return false;
}

/// True when `s` contains any of `needles`.
fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.mem.indexOf(u8, s, n) != null) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Commit - Requires a non-empty intent message

test "validIntent rejects null and blank, trims otherwise" {
    try testing.expect(validIntent(null) == null);
    try testing.expect(validIntent("") == null);
    try testing.expect(validIntent("   ") == null);
    try testing.expectEqualStrings("fix bug", validIntent("  fix bug  ").?);
}

// spec: Commit - Excludes forbidden secret and build-artifact paths from staging

test "planStaging skips secrets and build artifacts, keeps ordinary source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_][]const u8{
        ".env",                 "config/.env.local", "certs/server.pem", "deploy/id_rsa",
        "aws_credentials.json", "zig-out/bin/app",   ".zig-cache/x.o",   "src/keep.zig",
    };
    const plan = try planStaging(a, &changed, "SPEC.md");
    // Only the ordinary source file is staged; the seven risky paths are skipped.
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 7), plan.skipped.len);
}

// spec: Commit - Always stages guardian metadata and the spec file

test "planStaging always includes guardian and spec even against the forbidden filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_][]const u8{
        ".guardian/baselines/spec.txt", "SPEC.md",
        "src/x.zig", ".guardian/secret-notes.txt", // 'secret' but under .guardian → still staged
    };
    const plan = try planStaging(a, &changed, "SPEC.md");
    try testing.expectEqual(@as(usize, 4), plan.stage.len);
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
}

// spec: Commit - Reports nothing to commit when no eligible paths remain

test "planStaging yields an empty stage set when every change is forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_][]const u8{ ".env", "zig-out/bin/app" };
    const plan = try planStaging(a, &changed, "SPEC.md");
    try testing.expectEqual(@as(usize, 0), plan.stage.len);
    try testing.expectEqual(@as(usize, 2), plan.skipped.len);
}
