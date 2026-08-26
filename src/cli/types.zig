//! Core types shared across the CLI: `RunCtx` (the per-invocation context handed
//! to every check) and `RunError` (the one precise, named error set every
//! command's `run` shares — not `anyerror`, so each failure space stays
//! compile-time-exhaustive), plus the `Command` registry-entry shape.

const std = @import("std");
const config_mod = @import("../config.zig");
const ast_index = @import("../ast/index.zig");
const test_reach_mod = @import("../ast/test_reach.zig");
const walk = @import("../walk.zig");
const snapshot = @import("../snapshot.zig");
const git = @import("../git.zig");
const mutation_runner = @import("../mutation/runner.zig");
const benchmark = @import("../benchmark.zig");

/// Errors any registered command's `run` function may propagate. Every command
/// shares this one function-pointer type, so the set is the union of what they
/// all raise: `error.CheckFailed` (a check failed after printing its own
/// diagnostic), the walker's filesystem/OOM/visitor errors, the snapshot
/// read/write errors the budget checks surface, the git shell-out errors the
/// diff-scoped checks surface, and the mutation runner's process/fs errors the
/// `mutate` command surfaces. A precise named set (not `anyerror`) makes every
/// `run`'s failure space compile-time-exhaustive.
pub const RunError = error{CheckFailed} ||
    walk.WalkError ||
    snapshot.ReadError ||
    snapshot.WriteError ||
    git.GitError ||
    mutation_runner.RunError;

/// Per-invocation context handed to every check's `run` function.
pub const RunCtx = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    cfg: *const config_mod.Config,
    quiet: bool,
    /// Shared parsed-source index, built once per `all` run when any
    /// to-run check declares `needs_ast = .yes`. Null for standalone
    /// single-check runs, which build a private index on demand.
    source_index: ?*const ast_index.Index = null,
    /// Git ref for diff-scoped checks (--against flag or GUARDIAN_AGAINST
    /// env var). Null falls back to config, then HEAD.
    against: ?[]const u8 = null,
    /// Non-null when this run is diff-scoped: the base ref, the number of
    /// source files in scope, and the narrowed index every `per_file` check
    /// receives instead of the whole-tree one. Null means a whole-tree run.
    scoped: ?ScopedRun = null,
    /// Whole-file renames git reports against HEAD, resolved ONCE per `all` run
    /// (before the parallel check pass) and read by every ratchet's relocation
    /// plan. Null means unresolved: a single-check run asks git on demand
    /// instead. Workers copy this context, so nothing may memoize into it here.
    renames: ?[]const git.Rename = null,
    /// True when `--full` was passed: `mutate` covers the whole tree
    /// (nightly tier) instead of only diff-touched lines.
    full: bool = false,
    /// Forces `all` to BLOCK on violations regardless of `[gate] on_build`.
    /// Set by `--gate` (for hooks/CI) and by the always-blocking commit/nightly/
    /// accept paths. Default false: a plain build reports without refusing.
    gate: bool = false,
    /// `--only a,b`: when non-empty, `all` runs exactly these check names and
    /// nothing else. Mutually exclusive with `skip`. A filtered run never
    /// writes the green skip-cache stamp (it isn't the full suite).
    only: []const []const u8 = &.{},
    /// `--skip a,b`: when non-empty, `all` runs every check except these.
    /// Mutually exclusive with `only`; same skip-cache suppression applies.
    skip: []const []const u8 = &.{},
    /// `--intent "<message>"`: the commit subject for the `commit` command.
    /// Null for every other command; `commit` errors when it is null or blank.
    intent: ?[]const u8 = null,
    /// User-facing command that caused an `all` pass. Composed commands replace
    /// the direct `all` default (`commit`, `accept`, `nightly`, `migrate`) so
    /// ROI analysis does not mistake their internal passes for manual retries.
    roi_origin: []const u8 = "all",
    /// Optional phase inside a composed command (`preview`, `update`, `verify`,
    /// `gate`). Null for an ordinary direct `all` invocation.
    roi_phase: ?[]const u8 = null,
    /// Consumer HEAD resolved once per `all` invocation for observation IDs.
    /// Internal telemetry seam: checks never inspect it.
    roi_commit: ?[]const u8 = null,
    /// Concise mode (the default, and the explicit `--summary` spelling): `all`
    /// hides passes, collapses advisory checks to counts, and groups a bounded
    /// sample of each blocking check. `--verbose` restores every captured line.
    summary: bool = true,
    /// `--verbose`: `all` replays every check's output in full, opting out of
    /// the scope-collapse (and of `--summary`, which it overrides). The escape
    /// hatch when a collapsed count is the thing you need to expand.
    verbose: bool = false,
    /// Machine-readable maintenance-command output.
    json: bool = false,
    /// `--list`: on a single-check run, report that check's rows against its
    /// stored baseline as NEW / LIVE / RESOLVED instead of the pass/fail
    /// summary. Strictly read-only (see cli/introspect.zig).
    list: bool = false,
    /// `--dry-run`: on a single-check run, print every current finding in the
    /// check's own rendering with no baseline filtering, and write nothing —
    /// including no first-run baseline for a rule being tuned.
    dry_run: bool = false,
    /// `--args`: the read-only `test-filter` report also writes its derived
    /// argument string to stdout, so a caller can interpolate it into its own
    /// command. The report's caveats still go to stderr; no gate reads it.
    args_only: bool = false,
    /// Explicit refresh set supplied by the `accept` command. Environment-based
    /// GUARDIAN_UPDATE_SNAPSHOT remains supported for backwards compatibility.
    refresh: []const []const u8 = &.{},
    /// True only for runs allowed to PERSIST `.guardian/` metadata: `accept`
    /// and `migrate`. `commit` and ordinary `all` / single-check / report runs
    /// leaves it false, so baseline pruning, first-record creation, v1→v3
    /// re-keying, and snapshot creation are computed in memory but never written
    /// — the read-only-on-metadata contract that keeps a plain build's
    /// `git status` clean. The write-enabled paths flip it before invoking a
    /// gate run (see cli/accept and cli/migrate).
    metadata_writable: bool = false,
    /// True while a composed command (`accept`) already holds the project-wide
    /// writer lock across several nested `all` passes.
    writer_lock_held: bool = false,
    /// Optional check-name filter used by `debt`.
    check_filter: ?[]const u8 = null,
    /// The file `size` measures: the first positional after the command name.
    /// Null for every other command; `size` errors when it is null.
    target_path: ?[]const u8 = null,
    /// Measure each ratcheted item's CURRENT value in `debt` (`--current`).
    /// Off by default: the measurement pass re-reads and re-parses the tree,
    /// which a plain metadata-only debt report should not pay for.
    current: bool = false,
    /// Identify obsolete baseline files; dry-run unless `confirm` is true.
    prune_stale: bool = false,
    /// Explicit confirmation for a mutating maintenance operation (`--yes`).
    confirm: bool = false,
    /// Include the assert-density appendix in `debt`; off by default so a
    /// filtered debt query stays short and directly actionable.
    assert_density: bool = false,
    /// Trusted CI approval bit read once by main; checks receive plain data
    /// rather than acquiring environment dependencies themselves.
    policy_approved: bool = false,
    /// Registry membership callback for maintenance commands that must detect
    /// stale check-owned files without importing registry.zig (which imports
    /// those commands).
    command_exists: ?*const fn ([]const u8) bool = null,
    /// Parsed argv for the `bench` command (subcommand, metric name/value, and
    /// its flags). Empty for every other command.
    bench: benchmark.Args = .{},
    /// Parsed argv for the `merge-file` command (the three files git hands a
    /// merge driver, plus its pathname hint). Empty for every other command.
    merge: MergeInputs = .{},
    /// Run-scoped test-reachability analysis, built on first use by
    /// `testReach`. Two checks read it — `test-reachability` reports the files
    /// whose tests never compile, `spec` refuses to count a `// spec:` tag in
    /// one — and sharing it here keeps them independent of each other while the
    /// src+test walk behind it is paid once per run.
    test_reach: ?*const test_reach_mod.Analysis = null,

    /// True when the explicit `accept` refresh set contains `check_name`.
    pub fn refreshes(self: RunCtx, check_name: []const u8) bool {
        for (self.refresh) |name| if (std.mem.eql(u8, name, check_name)) return true;
        return false;
    }

    /// The shared test-reachability analysis, walking the tree the first time it
    /// is asked for. Always whole-tree: reachability is a property of the whole
    /// module graph, so a diff-scoped run may not narrow it.
    pub fn testReach(self: *RunCtx) walk.WalkError!*const test_reach_mod.Analysis {
        if (self.test_reach) |built| return built;
        const built = try self.allocator.create(test_reach_mod.Analysis);
        built.* = try test_reach_mod.analyze(
            self.allocator,
            self.project_dir,
            self.cfg.test_reachability.roots,
            self.cfg.exclude,
        );
        self.test_reach = built;
        return built;
    }
};

/// The three files a git merge driver is handed, in git's own `%O %A %B`
/// order — BASE, OURS, THEIRS — plus `%P`, the real pathname. Held here rather
/// than in `cli/merge_file.zig` so `RunCtx` can carry it without importing the
/// command that consumes it.
///
/// Empty means "not supplied": every slot holds a path, and a path is never the
/// empty string, so the sentinel needs no optional.
pub const MergeInputs = struct {
    /// `%O` — the merge base's version (empty when both branches added the file).
    base: []const u8 = "",
    /// `%A` — our version, and the file that receives the merged result.
    ours: []const u8 = "",
    /// `%B` — their version.
    theirs: []const u8 = "",
    /// `%P` — the repo-relative pathname, a format-detection hint only.
    path: []const u8 = "",

    /// Fills the next unset positional (base, then ours, then theirs); false
    /// once all three are set, so a fourth positional is the project directory.
    pub fn takePositional(self: *MergeInputs, arg: []const u8) bool {
        const slot = if (self.base.len == 0) &self.base else if (self.ours.len == 0)
            &self.ours
        else if (self.theirs.len == 0) &self.theirs else return false;
        slot.* = arg;
        return true;
    }

    /// True once all three merge inputs have been named.
    pub fn complete(self: MergeInputs) bool {
        return self.base.len > 0 and self.ours.len > 0 and self.theirs.len > 0;
    }

    /// The `%P` pathname hint, or null when git supplied none.
    ///
    /// Two tolerances, both from how git spells that placeholder: it arrives
    /// already single-quoted, and a git too old to know `%P` passes the
    /// placeholder through literally — so surrounding quotes are stripped and a
    /// leading `%` reads as "no hint" rather than as a file named `%P`.
    pub fn hint(self: MergeInputs) ?[]const u8 {
        const raw = std.mem.trim(u8, self.path, "'");
        if (raw.len == 0 or raw[0] == '%') return null;
        return raw;
    }
};

/// Whether a check needs the AST index built before invocation.
pub const NeedsAst = enum { no, yes };

/// Whether a check's verdict is a property of one file at a time — so a
/// diff-scoped run may hand it only the changed files — or an inherently
/// whole-tree one (cross-file graphs, tree-wide snapshots and budgets,
/// coverage maps, spec/tag reconciliation) that must always read everything or
/// it becomes unsound.
pub const CheckScope = enum { per_file, whole_tree };

/// The changed-file view handed to `per_file` checks on a diff-scoped run
/// (see scope.zig). Absent on a whole-tree run, which is the only kind
/// `commit` and CI ever perform.
pub const ScopedRun = struct {
    /// Git ref the file set was diffed against (a merge-base sha by default).
    base: []const u8,
    /// How many indexed source files are in scope — reported alongside every
    /// verdict so a scoped green is never mistaken for a full-tree green.
    file_count: usize,
    /// Every project-relative path that changed since `base`, including the
    /// non-Zig ones the parsed index cannot hold (SPEC.md, assets). The printer
    /// places each finding against this set to decide whether a whole-tree
    /// check's advisory output is relevant to the diff (see cli/run_view.zig).
    changed_paths: []const []const u8 = &.{},
    /// The shared parsed-source index narrowed to those files.
    index: *const ast_index.Index,
};

/// Entry in the subcommand registry.
pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    needs_ast: NeedsAst = .no,
    /// Whether a diff-scoped run may narrow this check to the changed files.
    /// Deliberately has NO default: a newly registered check must classify
    /// itself, so scoping can never silently widen to a check it is unsound
    /// for as the registry grows.
    scope: CheckScope,
    run: *const fn (ctx: *RunCtx) RunError!void,
};

// spec: Merge - Takes the three merge inputs in git's base, ours, theirs order

test "MergeInputs fills the positionals in git placeholder order" {
    var inputs: MergeInputs = .{};
    try std.testing.expect(!inputs.complete());
    try std.testing.expect(inputs.takePositional("/tmp/base"));
    try std.testing.expect(inputs.takePositional("/tmp/ours"));
    try std.testing.expect(inputs.takePositional("/tmp/theirs"));
    // `%O %A %B`: the SECOND path is ours, and ours is what receives the merged
    // result — reading this order backwards would write theirs over the tree.
    try std.testing.expectEqualStrings("/tmp/base", inputs.base);
    try std.testing.expectEqualStrings("/tmp/ours", inputs.ours);
    try std.testing.expectEqualStrings("/tmp/theirs", inputs.theirs);
    try std.testing.expect(inputs.complete());
    // A fourth positional belongs to the project dir, and an unset `%P` is a
    // missing hint rather than an empty path.
    try std.testing.expect(!inputs.takePositional("."));
    try std.testing.expect(inputs.hint() == null);
    // A git that does not know `%P` leaves the placeholder verbatim; that is
    // still "no hint", not a file named `%P`.
    inputs.path = "%P";
    try std.testing.expect(inputs.hint() == null);
    inputs.path = ".guardian/pub-api.txt";
    try std.testing.expectEqualStrings(".guardian/pub-api.txt", inputs.hint().?);
    // git hands `%P` over already single-quoted; the quotes are not part of the
    // path, and keeping them costs the format hint silently.
    inputs.path = "'.guardian/baselines/spec.txt'";
    try std.testing.expectEqualStrings(".guardian/baselines/spec.txt", inputs.hint().?);
}

// spec: Maintenance - Run context recognizes only explicitly named accept refreshes

// spec: Test Reachability - Builds the shared reachability analysis once per run and hands out the same one

test "testReach walks the tree once and returns the cached analysis after that" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: config_mod.Config = .{};
    var ctx: RunCtx = .{
        .allocator = arena.allocator(),
        .project_dir = "test-project",
        .cfg = &cfg,
        .quiet = true,
    };
    const first = try ctx.testReach();
    try std.testing.expect(first.nodes.len > 0);
    // Two checks read this analysis; rebuilding it per check would pay the
    // src+test walk twice for one answer.
    try std.testing.expectEqual(first, try ctx.testReach());
}

test "refreshes matches the explicit command-local refresh set" {
    const cfg: config_mod.Config = .{};
    const ctx: RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .refresh = &.{ "file-size", "line-length" },
    };
    try std.testing.expect(ctx.refreshes("file-size"));
    try std.testing.expect(!ctx.refreshes("spec"));
}
