const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const snapshot = @import("../snapshot.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Spec Drift - Snapshots pub fn prototypes
// spec: Spec Drift - Diff fails when an existing pub fn signature changes

const SNAPSHOT_PATH = ".guardian/spec-drift.txt";
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
        const line = std.fmt.allocPrint(a, "{s}::{s} | {s}", .{ entry.rel_path, f.name, f.proto_span }) catch continue;
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

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Entry point for the spec-drift check.
pub fn run(ctx_param: *registry.RunCtx) !void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    const snap_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, SNAPSHOT_PATH });
    const lines = try collectLines(allocator, project_dir);

    if (updateRequested()) {
        try snapshot.write(snap_path, SNAPSHOT_VERSION, lines);
        ok("spec-drift snapshot updated ({d} prototypes)", .{lines.len});
        return;
    }

    const old = snapshot.read(allocator, snap_path, SNAPSHOT_VERSION) catch |e| switch (e) {
        error.Missing => {
            try snapshot.write(snap_path, SNAPSHOT_VERSION, lines);
            ok("spec-drift snapshot created ({d} prototypes)", .{lines.len});
            return;
        },
        error.VersionMismatch => {
            fail("spec-drift snapshot version mismatch — re-run with {s}=1 to migrate", .{UPDATE_ENV});
            std.process.exit(1);
        },
        else => return e,
    };

    std.mem.sort([]const u8, lines, {}, lessThan);
    const diff = try snapshot.diff(allocator, old, lines);
    if (diff.isEmpty()) {
        ok("spec-drift unchanged ({d} prototypes)", .{lines.len});
        return;
    }

    fail("spec-drift FAILED — pub fn signature changed", .{});
    for (diff.removed) |line| print("  - {s}\n", .{line});
    for (diff.added) |line| print("  + {s}\n", .{line});
    print("  fix: update SPEC.md if intentional, then re-run with {s}=1 and commit {s}\n", .{ UPDATE_ENV, SNAPSHOT_PATH });
    std.process.exit(1);
}

test "visit emits one line per pub fn with prototype" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: CollectCtx = .{ .allocator = a, .lines = &lines };
    const content =
        \\pub fn run() void {}
        \\fn private() void {}
        \\pub fn parse(input: []const u8) !u32 { return 0; }
    ;
    visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("src/x.zig::run | fn run() void", lines.items[0]);
    try std.testing.expectEqualStrings("src/x.zig::parse | fn parse(input: []const u8) !u32", lines.items[1]);
}
