//! Core types shared across the CLI: `RunCtx` (the per-invocation context handed
//! to every check) and `RunError` (the one precise, named error set every
//! command's `run` shares — not `anyerror`, so each failure space stays
//! compile-time-exhaustive), plus the `Command` registry-entry shape.

const std = @import("std");
const config_mod = @import("../config.zig");
const ast_index = @import("../ast/index.zig");
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
    /// Machine-readable maintenance-command output.
    json: bool = false,
    /// `--args`: the read-only `test-filter` report also writes its derived
    /// argument string to stdout, so a caller can interpolate it into its own
    /// command. The report's caveats still go to stderr; no gate reads it.
    args_only: bool = false,
    /// Explicit refresh set supplied by the `accept` command. Environment-based
    /// GUARDIAN_UPDATE_SNAPSHOT remains supported for backwards compatibility.
    refresh: []const []const u8 = &.{},
    /// True only for runs allowed to PERSIST `.guardian/` metadata: `accept`,
    /// `commit`, and `migrate`. An ordinary `all` / single-check / report run
    /// leaves it false, so baseline pruning, first-record creation, v1→v3
    /// re-keying, and snapshot creation are computed in memory but never written
    /// — the read-only-on-metadata contract that keeps a plain build's
    /// `git status` clean. The write-enabled paths flip it before invoking a
    /// gate run (see cli/accept, cli/commit, cli/migrate).
    metadata_writable: bool = false,
    /// Optional check-name filter used by `debt`.
    check_filter: ?[]const u8 = null,
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

    /// True when the explicit `accept` refresh set contains `check_name`.
    pub fn refreshes(self: RunCtx, check_name: []const u8) bool {
        for (self.refresh) |name| if (std.mem.eql(u8, name, check_name)) return true;
        return false;
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

// spec: Maintenance - Run context recognizes only explicitly named accept refreshes

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
