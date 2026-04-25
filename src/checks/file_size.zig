const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: File Size - Checks source files against configurable line limit
// spec: File Size - Respects file_size_exclude patterns

const FileSizeCtx = struct {
    allocator: std.mem.Allocator,
    max_lines: u32,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileSizeVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *FileSizeCtx = @ptrCast(@alignCast(raw_ctx));
    var lines: u32 = 1;
    for (entry.content) |c| {
        if (c == '\n') lines += 1;
    }
    if (lines > ctx.max_lines) {
        const msg = std.fmt.allocPrint(ctx.allocator, "{s}: {d} lines (limit: {d})", .{ entry.rel_path, lines, ctx.max_lines }) catch return;
        ctx.violations.append(ctx.allocator, msg) catch {};
    }
}

/// Entry point for the file-size check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: FileSizeCtx = .{
        .allocator = allocator,
        .max_lines = cfg.max_file_lines,
        .violations = &violations,
    };

    const dirs_to_check = [_][]const u8{ "src", "test" };
    for (&dirs_to_check) |dir_name| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir_name });
        walk.walkZigFiles(allocator, dir_path, dir_name, .{ .excludes = cfg.file_size_exclude }, .{ .ctx = &ctx, .visit = fileSizeVisit }) catch {};
    }

    if (violations.items.len == 0) {
        ok("all files within {d} line limit", .{cfg.max_file_lines});
        return;
    }

    fail("file size FAILED ({d} file(s) over {d} line limit)", .{ violations.items.len, cfg.max_file_lines });
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    std.process.exit(1);
}

test "fileSizeVisit accumulates violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: FileSizeCtx = .{ .allocator = a, .max_lines = 10, .violations = &violations };
    try walk.walkZigFiles(a, "test-project/src", "src", .{}, .{ .ctx = &ctx, .visit = fileSizeVisit });
    try std.testing.expect(violations.items.len >= 3);
}
