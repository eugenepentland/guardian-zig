const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

const rules = [_]helper.Rule{
    .{ .chain = &.{ "std", "net" }, .display = "std.net.*" },
    .{ .chain = &.{ "std", "http" }, .display = "std.http.*" },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    .allowed_paths = &.{
        "src/adapters/http*",
        "adapters/http*",
        "src/infra/net*",
        "infra/net*",
    },
    .fix_hint = "inject a network adapter from adapters/http or infra/net.",
};

/// Pure-function entry: scans `content` for banned `std.net.*` / `std.http.*` use.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the ban-net check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx, "ban-net", opts);
}

// spec: Hidden Dependency Bans - Rejects std.net and std.http use outside adapters/http or infra/net

test "analyzeContent flags std.net.Address outside adapters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/domain/foo.zig",
        \\fn ip() void { _ = std.net.Address.parseIp("1.1.1.1", 80); }
    );
    try std.testing.expect(out.len >= 1);
}

test "analyzeContent allows std.http inside adapters/http" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/adapters/http/client.zig",
        \\pub fn make() void { _ = std.http.Client; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
