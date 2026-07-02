const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

const rules = [_]helper.Rule{
    .{ .chain = &.{ "std", "crypto", "random" }, .display = "std.crypto.random" },
    .{ .chain = &.{ "std", "Random", "DefaultPrng", "init" }, .display = "std.Random.DefaultPrng.init" },
    .{ .chain = &.{ "std", "Random", "Xoshiro256", "init" }, .display = "std.Random.Xoshiro256.init" },
    .{ .chain = &.{ "std", "Random", "Pcg", "init" }, .display = "std.Random.Pcg.init" },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    .allowed_paths = &.{ "src/infra/random*", "infra/random*" },
    .fix_hint = "inject a Random port from infra/random and call its next() method.",
};

/// Pure-function entry: scans `content` for banned RNG construction.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the ban-rng check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx, "ban-rng", opts);
}

// spec: Hidden Dependency Bans - Rejects RNG construction outside infra/random

test "analyzeContent flags std.crypto.random outside infra" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/domain/foo.zig",
        \\fn r() u32 { return std.crypto.random.int(u32); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows DefaultPrng.init inside infra/random" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/infra/random.zig",
        \\pub fn make() void { _ = std.Random.DefaultPrng.init(0); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
