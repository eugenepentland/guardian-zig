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
    /// True when `--full` was passed: `mutate` covers the whole tree
    /// (nightly tier) instead of only diff-touched lines.
    full: bool = false,
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
};

/// Whether a check needs the AST index built before invocation.
pub const NeedsAst = enum { no, yes };

/// Entry in the subcommand registry.
pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    needs_ast: NeedsAst = .no,
    run: *const fn (ctx: *RunCtx) RunError!void,
};
