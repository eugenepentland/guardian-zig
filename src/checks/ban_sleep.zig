const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

const rules = [_]helper.Rule{
    .{ .chain = &.{ "std", "Thread", "sleep" }, .display = "std.Thread.sleep" },
    .{ .chain = &.{ "std", "time", "sleep" }, .display = "std.time.sleep" },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    .allow_in_main = false,
    .fix_hint = "use a Clock port's wait() method (testable) instead of a real sleep.",
};

/// Pure-function entry: scans `content` for banned sleep calls.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the ban-sleep check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx, "ban-sleep", opts);
}

// spec: Hidden Dependency Bans - Rejects sleep calls outside test infrastructure

test "analyzeContent flags Thread.sleep in production" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn wait() void { std.Thread.sleep(1000); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags Thread.sleep in main (sleep is not allowed there)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/main.zig",
        \\pub fn main() !void { std.Thread.sleep(1000); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows Thread.sleep in test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "wait" { std.Thread.sleep(1000); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
