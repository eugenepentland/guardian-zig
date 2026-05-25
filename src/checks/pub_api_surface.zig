const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Pub Api Surface - Snapshots every public declaration
// spec: Pub Api Surface - Diff fails on unexpected pub additions or removals

const SNAPSHOT_LEAF = "pub-api.txt";
const SNAPSHOT_VERSION: u32 = 1;

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        const line = try std.fmt.allocPrint(a, "{s}::{s} fn", .{ entry.rel_path, f.name });
        try ctx.lines.append(a, line);
    }
    const consts = if (entry.tree) |t| try ast.pubConstsFromTree(a, t) else try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        const line = try std.fmt.allocPrint(a, "{s}::{s} {s}", .{ entry.rel_path, c.name, @tagName(c.kind) });
        try ctx.lines.append(a, line);
    }
}

fn collectLines(allocator: std.mem.Allocator, project_dir: []const u8, source_index: ?*const ast_index.Index) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: CollectCtx = .{ .allocator = allocator, .lines = &lines };
    try ast_index.runSrc(source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });
    return lines.toOwnedSlice(allocator);
}

/// Entry point for the pub-api-surface check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    const snap_path = try snapshot_helper.snapshotPath(allocator, project_dir, SNAPSHOT_LEAF);
    const lines = try collectLines(allocator, project_dir, ctx_param.source_index);

    const force = snapshot_helper.shouldUpdate(allocator);
    const outcome = try snapshot_helper.lifecycle(allocator, snap_path, SNAPSHOT_VERSION, lines, force);
    return reportOutcome(outcome);
}

fn reportOutcome(outcome: snapshot_helper.Outcome) registry.RunError!void {
    switch (outcome) {
        .created => |n| ok("pub-api snapshot created ({d} entries)", .{n}),
        .updated => |n| ok("pub-api snapshot updated ({d} entries)", .{n}),
        .unchanged => |n| ok("pub-api unchanged ({d} entries)", .{n}),
        .version_mismatch => {
            fail("pub-api snapshot version mismatch — re-run with {s}=1 to migrate", .{snapshot_helper.UPDATE_ENV});
            return error.CheckFailed;
        },
        .drift => |d| {
            fail("pub-api FAILED — surface changed", .{});
            for (d.removed) |line| print("  - {s}\n", .{line});
            for (d.added) |line| print("  + {s}\n", .{line});
            print("  fix: if intentional, re-run with {s}=1 and commit .guardian/{s}\n", .{ snapshot_helper.UPDATE_ENV, SNAPSHOT_LEAF });
            return error.CheckFailed;
        },
    }
}

test "visit emits fn and struct entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: CollectCtx = .{ .allocator = a, .lines = &lines };
    const content =
        \\pub fn run() void {}
        \\pub const X = struct { x: i32 };
        \\pub const Y = 42;
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("src/x.zig::run fn", lines.items[0]);
    try std.testing.expectEqualStrings("src/x.zig::X struct_", lines.items[1]);
    try std.testing.expectEqualStrings("src/x.zig::Y value", lines.items[2]);
}
