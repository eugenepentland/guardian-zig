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
    // Validate the disabled list up front: a typo like "magic-numbers" would
    // otherwise silently disable nothing while the user believes it's off.
    try validateDisabled(ctx.cfg.disabled);

    // Skip the whole run when guardian's hashed input set is unchanged since
    // the last all-green run. GUARDIAN_UPDATE_SNAPSHOT forces a full run.
    const cache_state = cacheState(ctx);
    if (cache_state.skip) {
        reporter.ok("run-all: inputs unchanged since last green run — checks skipped", .{});
        return;
    }

    // Build the shared parsed-source index once if any check needs it, so
    // the ~17 AST checks read and parse each file once instead of per check.
    var index_storage: ast_index.Index = undefined;
    if (anyNeedsAst(ctx.cfg.disabled)) {
        index_storage = try ast_index.build(ctx.allocator, ctx.project_dir);
        ctx.source_index = &index_storage;
    }

    var ran: u32 = 0;
    const failed = try runChecks(ctx, &ran);

    if (failed == 0) {
        reporter.ok("run-all: {d} check(s) passed", .{ran});
        // Record this green input state so an unchanged re-run can skip.
        if (cache_state.digest) |d| cache.writeStored(ctx.allocator, ctx.project_dir, d);
        return;
    }

    fail("run-all: {d}/{d} check(s) failed", .{ failed, ran });
    return error.CheckFailed;
}

/// A check removed by a merge/fold. Its name is still tolerated in `disabled`
/// (and silently ignored) so a consumer's guardian.toml — and any leftover
/// baseline/snapshot file — doesn't break the build when a check is folded into
/// another. `[[allow]]` entries for a retired name are already inert (nothing
/// looks them up). Guardian emits a one-line migration notice instead.
const RetiredCheck = struct { name: []const u8, folded_into: []const u8 };
const retired = [_]RetiredCheck{
    .{ .name = "spec-drift", .folded_into = "pub-api-surface" },
    .{ .name = "comptime-quota", .folded_into = "panic-budget" },
    .{ .name = "doc-quality", .folded_into = "doc-comments" },
    .{ .name = "vague-name-blacklist", .folded_into = "naming" },
    .{ .name = "dup-const", .folded_into = "repeated-string-literal" },
};

fn retiredInfo(name: []const u8) ?RetiredCheck {
    for (retired) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// Fails the run when the `disabled` config names a check that doesn't exist,
/// except for retired names (folded into another check), which are tolerated
/// with a migration notice so folds don't break downstream config.
fn validateDisabled(disabled: []const []const u8) types.RunError!void {
    for (disabled) |name| {
        if (registry.find(name) != null) continue;
        if (retiredInfo(name)) |r| {
            reporter.ok("note: '{s}' is retired (folded into {s})", .{ r.name, r.folded_into });
            continue;
        }
        fail("unknown check name in `disabled`: {s}", .{name});
        return error.CheckFailed;
    }
}

/// Digest for the current input set plus whether an unchanged re-run may skip.
const CacheState = struct { digest: ?cache.Digest = null, skip: bool = false };

/// Computes this run's input digest and whether it matches the last green run.
fn cacheState(ctx: *types.RunCtx) CacheState {
    const force_update = snapshot_helper.shouldUpdate(ctx.allocator);
    if (!ctx.cfg.cache_enabled or force_update) return .{};
    const d = cache.inputDigest(ctx.allocator, ctx.project_dir, ctx.cfg.spec_file) catch {
        return .{};
    };
    const stored = cache.readStored(ctx.allocator, ctx.project_dir);
    const skip = if (stored) |s| cache.eql(s, d) else false;
    return .{ .digest = d, .skip = skip };
}

/// Runs every non-skipped check, tallying how many ran (into `ran`) and
/// returning how many failed. Propagates any non-CheckFailed error.
fn runChecks(ctx: *types.RunCtx, ran: *u32) types.RunError!u32 {
    const baseline_on = ctx.cfg.baseline.enabled;
    var failed: u32 = 0;
    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name, ctx.cfg.disabled)) continue;
        ran.* += 1;
        const outcome = if (baseline_on)
            baseline.runWithBaseline(ctx, cmd)
        else
            cmd.run(ctx);
        outcome catch |e| switch (e) {
            error.CheckFailed => failed += 1,
            else => return e,
        };
    }
    return failed;
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
// spec: Run All - Tolerates retired check names in the disabled list

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

test "retired check names are recognized (tolerated in disabled)" {
    // A retired name resolves via retiredInfo (so validate won't reject it),
    // and reports where it was folded; a genuine typo does not.
    try std.testing.expect(retiredInfo("spec-drift") != null);
    try std.testing.expectEqualStrings("pub-api-surface", retiredInfo("spec-drift").?.folded_into);
    try std.testing.expect(retiredInfo("not-a-real-check") == null);
}
