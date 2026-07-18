//! Optional CI protection for Guardian's own policy and accepted-debt files.
//! A trusted review environment grants a one-run approval through
//! GUARDIAN_POLICY_APPROVED; the check itself can never be demoted by a profile.

const std = @import("std");
const git = @import("../git.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const approval_env = "GUARDIAN_POLICY_APPROVED";
const max_paths: usize = 20;

/// Blocks protected metadata changes unless trusted CI explicitly approves.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    if (!ctx.cfg.policy.lock_enabled) {
        reporter.ok("policy-drift: lock disabled", .{});
        return;
    }
    if (ctx.policy_approved) {
        reporter.ok("policy-drift: protected changes approved by {s}", .{approval_env});
        return;
    }

    const against = ctx.against orelse ctx.cfg.policy.lock_against;
    const diffs = switch (try git.diffPathNamesAgainst(ctx.allocator, ctx.project_dir, against)) {
        .unavailable => |reason| {
            reporter.ok("policy-drift: skipped — {s}", .{reason});
            return;
        },
        .ok => |items| items,
    };
    const untracked = try git.untrackedFiles(ctx.allocator, ctx.project_dir);
    var paths: std.ArrayList([]const u8) = .empty;
    for (diffs) |path| {
        if (protected(path, ctx.cfg.policy.protected_paths)) try appendUnique(ctx.allocator, &paths, path);
    }
    for (untracked) |path| {
        if (protected(path, ctx.cfg.policy.protected_paths)) try appendUnique(ctx.allocator, &paths, path);
    }
    if (paths.items.len == 0) {
        reporter.ok("policy-drift: no protected changes vs {s}", .{against});
        return;
    }
    reporter.fail("policy-drift FAILED: {d} protected path(s) changed vs {s}", .{ paths.items.len, against });
    for (paths.items[0..@min(paths.items.len, max_paths)]) |path| reporter.detail("  {s}\n", .{path});
    if (paths.items.len > max_paths) reporter.detail("  ... and {d} more\n", .{paths.items.len - max_paths});
    reporter.detail("  fix: require policy review, then set {s}=1 in the trusted CI job\n", .{approval_env});
    return error.CheckFailed;
}

fn protected(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (std.mem.endsWith(u8, pattern, "/") and std.mem.startsWith(u8, path, pattern)) return true;
        if (std.mem.indexOfScalar(u8, pattern, '*') != null and walk.matchGlob(path, pattern)) return true;
        if (std.mem.eql(u8, path, pattern)) return true;
    }
    return false;
}

fn appendUnique(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    for (paths.items) |existing| if (std.mem.eql(u8, existing, path)) return;
    try paths.append(allocator, path);
}

// spec: Policy Protection - Blocks protected Guardian metadata drift unless trusted CI approves it

test "protected paths use exact files, directory prefixes, and explicit globs" {
    const patterns = &[_][]const u8{ "guardian.toml", ".guardian/", "ci/*.policy" };
    try std.testing.expect(protected("guardian.toml", patterns));
    try std.testing.expect(protected(".guardian/baselines/spec.txt", patterns));
    try std.testing.expect(protected("ci/release.policy", patterns));
    try std.testing.expect(!protected("docs/guardian.toml.md", patterns));
}
