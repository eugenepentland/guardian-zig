const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");
const baseline = @import("../baseline.zig");
const ast_index = @import("../ast/index.zig");
const cache = @import("../cache.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

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

    // Validate the disabled list up front: a typo like "magic-numbers" would
    // otherwise silently disable nothing while the user believes it's off.
    for (ctx.cfg.disabled) |name| {
        if (registry.find(name) == null) {
            fail("unknown check name in `disabled`: {s}", .{name});
            return error.CheckFailed;
        }
    }

    // Skip the whole run when guardian's hashed input set is unchanged since
    // the last all-green run. GUARDIAN_UPDATE_SNAPSHOT forces a full run.
    const force_update = snapshot_helper.shouldUpdate(ctx.allocator);
    var digest: ?cache.Digest = null;
    if (ctx.cfg.cache_enabled and !force_update) {
        if (cache.inputDigest(ctx.allocator, ctx.project_dir, ctx.cfg.spec_file)) |d| {
            digest = d;
            if (cache.readStored(ctx.allocator, ctx.project_dir)) |stored| {
                if (cache.eql(stored, d)) {
                    reporter.ok("run-all: inputs unchanged since last green run — checks skipped", .{});
                    return;
                }
            }
        } else |_| {}
    }

    // Build the shared parsed-source index once if any check needs it, so
    // the ~17 AST checks read and parse each file once instead of per check.
    var index_storage: ast_index.Index = undefined;
    if (anyNeedsAst(ctx.cfg.disabled)) {
        index_storage = try ast_index.build(ctx.allocator, ctx.project_dir);
        ctx.source_index = &index_storage;
    }

    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name, ctx.cfg.disabled)) continue;
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
        // Record this green input state so an unchanged re-run can skip.
        if (digest) |d| cache.writeStored(ctx.allocator, ctx.project_dir, d);
        return;
    }

    fail("run-all: {d}/{d} check(s) failed", .{ failed, ran });
    return error.CheckFailed;
}

fn shouldSkip(name: []const u8, disabled: []const []const u8) bool {
    for (SKIP) |s| if (std.mem.eql(u8, name, s)) return true;
    for (disabled) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// True when at least one non-skipped check declares `needs_ast = .yes`,
/// meaning the shared parsed-source index is worth building for this run.
fn anyNeedsAst(disabled: []const []const u8) bool {
    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name, disabled)) continue;
        if (cmd.needs_ast == .yes) return true;
    }
    return false;
}

// spec: Run All - Skips checks whose name appears in the disabled config list
// spec: Run All - Rejects unknown check names in the disabled list

test "shouldSkip honors the disabled list and built-in skips" {
    try std.testing.expect(shouldSkip("magic-number", &.{"magic-number"}));
    try std.testing.expect(shouldSkip("spec-init", &.{}));
    try std.testing.expect(!shouldSkip("spec", &.{"magic-number"}));
}

test "disabled list entries must be real check names" {
    // A real check resolves; a typo does not.
    try std.testing.expect(registry.find("magic-number") != null);
    try std.testing.expect(registry.find("magic-numbers") == null);
}
