//! `nightly` command — the scheduled/CI tier. Runs the full `all` suite, then
//! whole-tree mutation with the score ratchet (`mutate --full`), failing if
//! either fails. `mutate-full` on its own is a step nobody schedules; nightly
//! gives it an obvious cron/CI home.
//!
//! It is dispatched specially by check.zig (like `all`) rather than sitting in
//! the registry: its run function composes `run_all.run`, and run_all imports
//! the registry — so a registry entry whose `.run` pointed back here would
//! close an @import cycle, which guardian's own `imports` check forbids. The
//! run_all `SKIP` list and build_helper still name it defensively (mirroring
//! their existing `all` exclusion) so it can never be treated as a gate.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const run_all = @import("run_all.zig");
const mutate = @import("mutate.zig");

/// CLI name that check.zig dispatches to this command.
pub const COMMAND_NAME = "nightly";

/// Pure decision: a nightly run fails when the `all` suite failed or the
/// whole-tree mutation ratchet failed. Separated from `run` so the
/// compose-and-fail rule is unit-testable without spawning child builds.
/// Private (two bool params) so it isn't a public boolean-param API.
fn failed(all_failed: bool, mutate_failed: bool) bool {
    return all_failed or mutate_failed;
}

/// Returns a copy of `ctx` switched to the whole-tree mutation tier (`full`),
/// with `source_index` cleared so `mutate` builds its own fresh index. The
/// shared index `all` built is stack-scoped (it dies when run_all.run returns)
/// and describes the pre-mutation tree, so it must not be reused here.
pub fn mutateContext(ctx: *const types.RunCtx) types.RunCtx {
    var next = ctx.*;
    next.full = true;
    next.source_index = null;
    return next;
}

/// Entry point for the nightly command: runs the full `all` suite, then
/// `mutate --full` on the same tree, and fails if either failed. Both stages
/// run even when the first fails (a style/structure violation doesn't stop the
/// test suite from compiling), so a scheduled run surfaces every signal at
/// once; a non-CheckFailed error (e.g. I/O) still propagates immediately.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    reporter.ok("nightly: running the full check suite ...", .{});
    var all_failed = false;
    run_all.run(ctx) catch |e| switch (e) {
        error.CheckFailed => all_failed = true,
        else => return e,
    };

    reporter.ok("nightly: running the whole-tree mutation ratchet ...", .{});
    var mctx = mutateContext(ctx);
    var mutate_failed = false;
    mutate.run(&mctx) catch |e| switch (e) {
        error.CheckFailed => mutate_failed = true,
        else => return e,
    };

    if (failed(all_failed, mutate_failed)) {
        reporter.fail("nightly FAILED: the check suite and/or the mutation ratchet did not pass", .{});
        return error.CheckFailed;
    }
    reporter.ok("nightly: check suite green and mutation ratchet satisfied", .{});
}

// spec: Nightly - Fails when either the suite or the whole-tree mutation ratchet fails
// spec: Nightly - Runs the whole-tree mutation tier by setting the full flag

test "failed is the OR of the suite and mutation outcomes" {
    try std.testing.expect(!failed(false, false));
    try std.testing.expect(failed(true, false));
    try std.testing.expect(failed(false, true));
    try std.testing.expect(failed(true, true));
}

test "mutateContext selects the whole-tree tier and preserves the rest" {
    const cfg: @import("../config.zig").Config = .{};
    var base: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = "somedir",
        .cfg = &cfg,
        .quiet = true,
        .full = false,
    };
    const next = mutateContext(&base);
    try std.testing.expect(next.full);
    try std.testing.expect(!base.full); // original untouched
    try std.testing.expect(next.source_index == null); // no dangling shared index
    try std.testing.expectEqualStrings("somedir", next.project_dir);
    try std.testing.expect(next.quiet);
}
