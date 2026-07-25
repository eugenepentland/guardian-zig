//! Diff scoping: how much of the tree one gate run actually has to read.
//!
//! A local edit/verify loop re-runs the whole suite over every file, which on a
//! real consumer tree costs tens of seconds per keystroke-sized change. Scoping
//! narrows the *per-file* checks (shape, naming, per-file style — anything whose
//! verdict depends on one file alone) to the files that changed since a base
//! ref, while every inherently whole-tree check (import cycles, cross-file
//! duplicates, reachability, coverage maps, tree-wide snapshots) keeps reading
//! everything. The per-check capability lives on the registry entry
//! (`cli/types.zig` `CheckScope`), so scoping can never silently widen to a
//! check it would be unsound for.
//!
//! The default base is the merge base with the repository's main line — the
//! "everything this branch changed" boundary. It is deliberately wider than
//! `HEAD` (a rebase or an amend cannot hide work from the gate) and narrower
//! than the whole tree.
//!
//! Scoping is a *local* accelerator, never a weakening of the guarantee:
//! `--full`, any blocking gate run (`--gate`, the pre-commit hook, `commit`,
//! `nightly`, `accept`, `migrate`), and any run that may rewrite `.guardian/`
//! metadata all fall back to the whole tree — as does any run where the base or
//! the diff cannot be resolved, or where the caps/debt the checks are judged
//! against themselves changed. Every fallback is fail-safe: the whole tree is
//! always a correct answer, so an unknown is never scoped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("git.zig");
const ast_index = @import("ast/index.zig");
const reporter = @import("reporter.zig");

/// Branch names tried, in order, when resolving the default diff base.
const default_base_branches = [_][]const u8{ "main", "master" };

/// Paths whose change invalidates diff scoping outright: the caps, policy, and
/// recorded debt every per-file verdict is measured against. When one of these
/// moves, an *unchanged* file can start violating, so the run must read the
/// whole tree even though no source file outside the scope was touched.
const scope_invalidating_paths = [_][]const u8{ "guardian.toml", ".guardian/" };

const reason_full = "--full was requested";
const reason_gate = "blocking gate run (commit/CI enforces the whole-tree guarantee)";
const reason_metadata_write = "run may rewrite .guardian metadata, which needs the whole tree";
const reason_no_base = "no diff base could be resolved (no main/master, or no commits yet)";
const reason_no_git = "git could not report the changed files";
const reason_config_changed = "guardian.toml or .guardian/ changed, so every file must be re-judged";

/// Run properties that force a whole-tree pass regardless of what the diff says.
/// Grouped into one value so the decision below is a pure function of the run's
/// posture and can be exercised without a repository.
pub const Posture = struct {
    /// `--full`: the caller explicitly asked for the whole tree.
    full: bool = false,
    /// A blocking gate run — `--gate` (the pre-commit hook and CI), `commit`,
    /// `nightly`, `accept`, `migrate`. This is the boundary at which the
    /// whole-tree guarantee is enforced, so it is never scoped.
    gate: bool = false,
    /// The run may write `.guardian/` metadata. Reconciling a baseline or a
    /// ratchet from a partial view would prune entries that are merely out of
    /// scope rather than resolved, so metadata writes are always whole-tree.
    writes_metadata: bool = false,
};

/// Why this run must read the whole tree, or null when it may be diff-scoped.
/// Pure — the git-facing work in `resolve` only runs once this returns null.
pub fn wholeTreeReason(posture: Posture) ?[]const u8 {
    if (posture.full) return reason_full;
    if (posture.gate) return reason_gate;
    if (posture.writes_metadata) return reason_metadata_write;
    return null;
}

/// A resolved diff scope: the base ref the per-file checks are scoped against,
/// and every project-relative path that changed since it (including untracked
/// files — a brand-new file is always in scope).
pub const Plan = struct {
    base: []const u8,
    files: []const []const u8,

    /// True when `rel_path` (walker-relative, e.g. `src/foo.zig`) is one of the
    /// paths that changed since the base.
    pub fn covers(self: Plan, rel_path: []const u8) bool {
        for (self.files) |p| {
            if (std.mem.eql(u8, p, rel_path)) return true;
        }
        return false;
    }

    /// The parsed-source view a per-file check sees under this plan: `full`
    /// filtered to the covered files. Entries are shared with `full`, so
    /// nothing is re-read or re-parsed and a scoped run still pays exactly one
    /// parse per file.
    pub fn indexSubset(
        self: Plan,
        arena: Allocator,
        full: *const ast_index.Index,
    ) Allocator.Error!ast_index.Index {
        var files: std.ArrayList(ast_index.Entry) = .empty;
        for (full.files) |entry| {
            if (!self.covers(entry.rel_path)) continue;
            try files.append(arena, entry);
        }
        return .{ .files = try files.toOwnedSlice(arena) };
    }
};

/// The scoping decision for one run.
pub const Decision = union(enum) {
    /// Per-file checks see only the plan's files; whole-tree checks see all.
    scoped: Plan,
    /// Every check reads the whole tree; the payload is the human-facing reason.
    whole_tree: []const u8,
};

/// True when a changed path invalidates diff scoping (see
/// `scope_invalidating_paths`): the thresholds, policy, or recorded debt moved,
/// so files outside the diff may have changed verdict without changing content.
pub fn invalidatedBy(paths: []const []const u8) bool {
    for (paths) |p| {
        for (scope_invalidating_paths) |marker| {
            if (std.mem.startsWith(u8, p, marker)) return true;
        }
    }
    return false;
}

/// Resolves the diff scope for a run. `against` is the caller's explicit base
/// (`--against` / `GUARDIAN_AGAINST`); when null the default merge base with
/// the repository's main line is used. Any unknown — no base, no git, a
/// metadata change — yields a whole-tree decision, so the fallback is always
/// the safe answer. Only allocation failure propagates: swallowing OOM here
/// would silently widen or narrow the run.
pub fn resolve(
    allocator: Allocator,
    project_dir: []const u8,
    against: ?[]const u8,
    posture: Posture,
) Allocator.Error!Decision {
    if (wholeTreeReason(posture)) |reason| return .{ .whole_tree = reason };
    const base = against orelse defaultBase(allocator, project_dir) orelse
        return .{ .whole_tree = reason_no_base };
    const changed = changedPaths(allocator, project_dir, base) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // A bad ref or an unspawnable git is not worth failing a run that would
        // otherwise pass: read everything instead.
        else => return .{ .whole_tree = reason_no_git },
    };
    const paths = changed orelse return .{ .whole_tree = reason_no_git };
    if (invalidatedBy(paths)) return .{ .whole_tree = reason_config_changed };
    return .{ .scoped = .{ .base = base, .files = paths } };
}

/// First resolvable merge base among the default main-line branch names, or
/// null when none of them exists in this repository.
fn defaultBase(allocator: Allocator, project_dir: []const u8) ?[]const u8 {
    for (default_base_branches) |branch| {
        if (git.mergeBase(allocator, project_dir, branch)) |sha| return sha;
    }
    return null;
}

/// Every project-relative path that differs from `base`, plus the untracked
/// files (a brand-new file has no diff entry but is certainly in scope). Null
/// when this is not a git repository.
fn changedPaths(
    allocator: Allocator,
    project_dir: []const u8,
    base: []const u8,
) git.GitError!?[]const []const u8 {
    const diffed = switch (try git.diffPathNamesAgainst(allocator, project_dir, base)) {
        .unavailable => return null,
        .ok => |p| p,
    };
    const untracked = try git.untrackedFiles(allocator, project_dir);
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(allocator, diffed);
    try out.appendSlice(allocator, untracked);
    return try out.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Diff Scoping - Falls back to the whole tree for full, gate, and metadata-writing runs

test "wholeTreeReason names the posture that forces a whole-tree run" {
    // The ordinary local build: nothing forces the whole tree, so it may scope.
    try testing.expectEqual(@as(?[]const u8, null), wholeTreeReason(.{}));
    // --full is the explicit opt-out.
    try testing.expect(wholeTreeReason(.{ .full = true }) != null);
    // The commit/CI boundary always reads everything.
    try testing.expect(wholeTreeReason(.{ .gate = true }) != null);
    // So does any run that could rewrite baselines/ratchets from its view.
    try testing.expect(wholeTreeReason(.{ .writes_metadata = true }) != null);
}

// spec: Diff Scoping - Falls back to the whole tree when guardian config or recorded debt changed

test "invalidatedBy fires on guardian.toml and .guardian changes only" {
    try testing.expect(invalidatedBy(&.{ "src/a.zig", "guardian.toml" }));
    try testing.expect(invalidatedBy(&.{".guardian/baselines/file-size.txt"}));
    // Ordinary source and spec edits leave the caps intact, so scoping holds.
    try testing.expect(!invalidatedBy(&.{ "src/a.zig", "SPEC.md", "README.md" }));
    try testing.expect(!invalidatedBy(&.{}));
}

// spec: Diff Scoping - Reports whether a changed-file plan covers a given path

test "covers matches exactly the changed paths" {
    const plan: Plan = .{ .base = "abc123", .files = &.{ "src/a.zig", "src/sub/b.zig" } };
    try testing.expect(plan.covers("src/a.zig"));
    try testing.expect(plan.covers("src/sub/b.zig"));
    try testing.expect(!plan.covers("src/c.zig"));
    // Not a prefix match: a longer path that merely starts with a covered one
    // is a different file and stays out of scope.
    try testing.expect(!plan.covers("src/a.zig.bak"));
}

// spec: Diff Scoping - Narrows the shared parsed-source index to the changed files

test "indexSubset keeps only covered files and shares their parsed trees" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const full = try ast_index.build(a, "test-project", &.{});
    try testing.expect(full.files.len > 1);
    const plan: Plan = .{ .base = "abc123", .files = &.{full.files[0].rel_path} };
    const subset = try plan.indexSubset(a, &full);
    try testing.expectEqual(@as(usize, 1), subset.files.len);
    try testing.expectEqualStrings(full.files[0].rel_path, subset.files[0].rel_path);
    // The entry is shared, not re-read: same content bytes, no second parse.
    try testing.expectEqual(full.files[0].content.ptr, subset.files[0].content.ptr);
}

// spec: Diff Scoping - Resolves a whole-tree decision when the base or the diff cannot be read

test "resolve reports whole tree for a forced posture and an unusable base" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Capture git's failure diagnostic so the expected bad-ref run stays quiet.
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // A forced posture short-circuits before any git work.
    const forced = try resolve(a, ".", null, .{ .gate = true });
    try testing.expect(forced == .whole_tree);
    // An explicit base git cannot resolve degrades to the whole tree instead of
    // failing a run that would otherwise pass.
    const bad_ref = try resolve(a, ".", "guardian-no-such-ref-zzz", .{});
    try testing.expect(bad_ref == .whole_tree);
}
