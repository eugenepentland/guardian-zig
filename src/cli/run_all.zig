const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");
const baseline = @import("../baseline.zig");
const ast_index = @import("../ast/index.zig");

const print = std.debug.print;
const fail = reporter.fail;

pub const COMMAND_NAME = "all";
const SKIP = [_][]const u8{"spec-init"};

/// Runs every registered hard-block check sequentially in this process.
/// Continues past failures so the user sees every failing check at once;
/// returns error.CheckFailed if any check failed.
///
/// When `cfg.baseline.enabled = true`, each check is run with output
/// captured: the first run records current violations into
/// `.guardian/baselines/<check>.txt` and reports success; subsequent
/// runs only fail when new violations appear above the baseline.
///
/// Skips `spec-init` (a generator, not a gate). The `all` command itself
/// is dispatched outside the registry, so it never recurses.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    var failed: u32 = 0;
    var ran: u32 = 0;
    const baseline_on = ctx.cfg.baseline.enabled;

    // Build the shared parsed-source index once if any check needs it, so
    // the ~17 AST checks read and parse each file once instead of per check.
    var index_storage: ast_index.Index = undefined;
    if (anyNeedsAst()) {
        index_storage = try ast_index.build(ctx.allocator, ctx.project_dir);
        ctx.source_index = &index_storage;
    }

    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name)) continue;
        ran += 1;
        const outcome = if (baseline_on)
            baseline.runWithBaseline(ctx, cmd)
        else
            cmd.run(ctx);
        outcome catch |e| switch (e) {
            error.CheckFailed => failed += 1,
            else => return e,
        };
    }

    if (failed == 0) {
        reporter.ok("run-all: {d} check(s) passed", .{ran});
        return;
    }

    fail("run-all: {d}/{d} check(s) failed", .{ failed, ran });
    return error.CheckFailed;
}

fn shouldSkip(name: []const u8) bool {
    for (SKIP) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// True when at least one non-skipped check declares `needs_ast = .yes`,
/// meaning the shared parsed-source index is worth building for this run.
fn anyNeedsAst() bool {
    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name)) continue;
        if (cmd.needs_ast == .yes) return true;
    }
    return false;
}
