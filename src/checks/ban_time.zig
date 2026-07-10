const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

const rules = [_]helper.Rule{
    .{ .chain = &.{ "std", "time", "timestamp" }, .display = "std.time.timestamp" },
    .{ .chain = &.{ "std", "time", "nanoTimestamp" }, .display = "std.time.nanoTimestamp" },
    .{ .chain = &.{ "std", "time", "milliTimestamp" }, .display = "std.time.milliTimestamp" },
    .{ .chain = &.{ "std", "time", "microTimestamp" }, .display = "std.time.microTimestamp" },
    .{ .chain = &.{ "std", "time", "Instant", "now" }, .display = "std.time.Instant.now" },
    .{ .chain = &.{ "std", "time", "Timer", "start" }, .display = "std.time.Timer.start" },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    .allowed_paths = &.{ "src/infra/clock*", "infra/clock*" },
    .fix_hint = "inject a Clock port from infra/clock and call its now() method.",
};

/// Pure-function entry: scans `content` for banned `std.time.*` chains.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the ban-time check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx, "ban-time", opts);
}

// spec: Hidden Dependency Bans - Rejects std.time wall-clock reads outside infra/clock

test "analyzeContent flags std.time.timestamp outside infra" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/domain/foo.zig",
        \\fn t() i64 { return std.time.timestamp(); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows std.time.timestamp inside infra/clock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/infra/clock.zig",
        \\pub fn now() i64 { return std.time.timestamp(); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags std.time.Instant.now (4-element chain)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn t() void { _ = std.time.Instant.now(); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
