const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const snapshot = @import("../snapshot.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Pub Api Surface - Snapshots every public declaration
// spec: Pub Api Surface - Diff fails on unexpected pub additions or removals

const SNAPSHOT_PATH = ".guardian/pub-api.txt";
const SNAPSHOT_VERSION: u32 = 1;
const UPDATE_ENV = "GUARDIAN_UPDATE_SNAPSHOT";

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    lines: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = ast.pubFns(a, entry.content) catch return;
    for (fns) |f| {
        const line = std.fmt.allocPrint(a, "{s}::{s} fn", .{ entry.rel_path, f.name }) catch continue;
        ctx.lines.append(a, line) catch {};
    }
    const consts = ast.pubConsts(a, entry.content) catch return;
    for (consts) |c| {
        const line = std.fmt.allocPrint(a, "{s}::{s} {s}", .{ entry.rel_path, c.name, @tagName(c.kind) }) catch continue;
        ctx.lines.append(a, line) catch {};
    }
}

fn collectLines(allocator: std.mem.Allocator, project_dir: []const u8) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: CollectCtx = .{ .allocator = allocator, .lines = &lines };
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit }) catch {};
    return lines.toOwnedSlice(allocator);
}

fn updateRequested() bool {
    const v = std.process.getEnvVarOwned(std.heap.page_allocator, UPDATE_ENV) catch return false;
    defer std.heap.page_allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Entry point for the pub-api-surface check.
pub fn run(ctx_param: *registry.RunCtx) !void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    const snap_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, SNAPSHOT_PATH });
    const lines = try collectLines(allocator, project_dir);

    if (updateRequested()) {
        try snapshot.write(snap_path, SNAPSHOT_VERSION, lines);
        ok("pub-api snapshot updated ({d} entries)", .{lines.len});
        return;
    }

    const old = snapshot.read(allocator, snap_path, SNAPSHOT_VERSION) catch |e| switch (e) {
        error.Missing => {
            try snapshot.write(snap_path, SNAPSHOT_VERSION, lines);
            ok("pub-api snapshot created ({d} entries)", .{lines.len});
            return;
        },
        error.VersionMismatch => {
            fail("pub-api snapshot version mismatch — re-run with {s}=1 to migrate", .{UPDATE_ENV});
            std.process.exit(1);
        },
        else => return e,
    };

    std.mem.sort([]const u8, lines, {}, lessThan);
    const diff = try snapshot.diff(allocator, old, lines);
    if (diff.isEmpty()) {
        ok("pub-api unchanged ({d} entries)", .{lines.len});
        return;
    }

    fail("pub-api FAILED — surface changed", .{});
    for (diff.removed) |line| print("  - {s}\n", .{line});
    for (diff.added) |line| print("  + {s}\n", .{line});
    print("  fix: if intentional, re-run with {s}=1 and commit {s}\n", .{ UPDATE_ENV, SNAPSHOT_PATH });
    std.process.exit(1);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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
    visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("src/x.zig::run fn", lines.items[0]);
    try std.testing.expectEqualStrings("src/x.zig::X struct_", lines.items[1]);
    try std.testing.expectEqualStrings("src/x.zig::Y value", lines.items[2]);
}
