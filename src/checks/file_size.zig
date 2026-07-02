const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const FileSizeCtx = struct {
    allocator: std.mem.Allocator,
    max_lines: u32,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileSizeVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileSizeCtx = @ptrCast(@alignCast(raw_ctx));
    // Count newlines, then add 1 only for a final unterminated line. `zig fmt`
    // always emits a trailing newline, so counting 1 + newlines would report
    // an off-by-one (an N-line file as N+1) and fail files exactly at the cap.
    var newlines: u32 = 0;
    for (entry.content) |c| {
        if (c == '\n') newlines += 1;
    }
    const lines: u32 = if (entry.content.len > 0 and entry.content[entry.content.len - 1] != '\n')
        newlines + 1
    else
        newlines;
    if (lines > ctx.max_lines) {
        const msg = try std.fmt.allocPrint(
            ctx.allocator,
            "{s}: {d} lines (limit: {d})",
            .{ entry.rel_path, lines, ctx.max_lines },
        );
        try ctx.violations.append(ctx.allocator, msg);
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
        try walk.walkZigFiles(
            allocator,
            dir_path,
            dir_name,
            .{ .excludes = cfg.file_size_exclude },
            .{ .ctx = &ctx, .visit = fileSizeVisit },
        );
    }

    if (violations.items.len == 0) {
        ok("all files within {d} line limit", .{cfg.max_file_lines});
        return;
    }

    fail("file size FAILED ({d} file(s) over {d} line limit)", .{ violations.items.len, cfg.max_file_lines });
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    return error.CheckFailed;
}

// spec: File Size - Checks source files against configurable line limit
// spec: File Size - Respects file_size_exclude patterns

test "fileSizeVisit is not off-by-one on the trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: FileSizeCtx = .{ .allocator = a, .max_lines = 2, .violations = &violations };
    // Exactly 2 lines with the fmt-mandated trailing newline: at the cap, ok.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "x.zig", .content = "a\nb\n" });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    // 3 lines: over the cap.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "y.zig", .content = "a\nb\nc\n" });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
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
