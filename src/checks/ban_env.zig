const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

const rules = [_]helper.Rule{
    .{ .chain = &.{ "std", "process", "getEnvVarOwned" }, .display = "std.process.getEnvVarOwned" },
    .{ .chain = &.{ "std", "process", "getEnvMap" }, .display = "std.process.getEnvMap" },
    .{ .chain = &.{ "std", "posix", "getenv" }, .display = "std.posix.getenv" },
    .{ .chain = &.{ "std", "os", "getenv" }, .display = "std.os.getenv" },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    .allowed_paths = &.{
        "src/config*",
        "config/*",
        "src/snapshot_helper*",
        // Guardian-internal: golden test runner reads GUARDIAN_UPDATE_GOLDEN.
        "src/testing/*",
    },
    .fix_hint = "read env vars in config/ or main, then pass values down as plain parameters.",
};

/// Pure-function entry: scans `content` for banned env-var reads.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the ban-env check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx, "ban-env", opts);
}

// spec: Hidden Dependency Bans - Rejects environment-variable reads outside config or main

test "analyzeContent flags getEnvVarOwned outside config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/domain/foo.zig",
        \\fn home(a: anytype) ![]u8 { return std.process.getEnvVarOwned(a, "HOME"); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows getEnvVarOwned inside config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/config.zig",
        \\fn home(a: anytype) ![]u8 { return std.process.getEnvVarOwned(a, "HOME"); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
