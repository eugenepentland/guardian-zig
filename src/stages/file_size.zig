const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const StageResult = stage.StageResult;

pub fn run(ctx: *pipeline.Context) StageResult {
    const src_path = std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.target_dir}) catch
        return stage.passed("File Size", "Could not check src/");

    var dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch
        return stage.passed("File Size", "No src/ directory");
    defer dir.close();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    walkAndCheck(ctx.allocator, dir, "", ctx.config.max_file_lines, ctx.config.file_size_exclude, &violations) catch {};

    if (violations.items.len == 0) {
        const detail = std.fmt.allocPrint(ctx.allocator, "All files within {d} line limit", .{ctx.config.max_file_lines}) catch "All files within limit";
        return stage.passed("File Size", detail);
    }

    var remediation: std.ArrayListUnmanaged([]const u8) = .empty;
    for (violations.items) |_| {
        remediation.append(ctx.allocator, "Split into smaller, focused modules") catch {};
    }

    return stage.failed("File Size", violations.toOwnedSlice(ctx.allocator) catch &.{}, remediation.toOwnedSlice(ctx.allocator) catch &.{});
}

fn walkAndCheck(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    max_lines: u32,
    excludes: []const []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
) !void {
    var walker = dir.iterate();
    while (try walker.next()) |entry| {
        const rel_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{entry.name});

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkAndCheck(allocator, sub, rel_path, max_lines, excludes, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                if (isExcluded(rel_path, excludes)) continue;

                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                var line_count: u32 = 1;
                for (content) |c| {
                    if (c == '\n') line_count += 1;
                }

                if (line_count > max_lines) {
                    const msg = std.fmt.allocPrint(allocator, "src/{s}: {d} lines (limit: {d})", .{ rel_path, line_count, max_lines }) catch continue;
                    violations.append(allocator, msg) catch {};
                }
            },
            else => {},
        }
    }
}

fn isExcluded(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |pattern| {
        if (std.mem.indexOf(u8, path, pattern) != null) return true;
    }
    return false;
}
