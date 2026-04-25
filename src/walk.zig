const std = @import("std");
const Allocator = std.mem.Allocator;

/// One file yielded by the walker: its display path and full content.
pub const FileEntry = struct {
    rel_path: []const u8,
    content: []const u8,
};

/// Options controlling which files the walker yields.
pub const WalkOpts = struct {
    excludes: []const []const u8 = &.{},
    max_file_bytes: usize = 10 * 1024 * 1024,
    extension: []const u8 = ".zig",
};

/// Function signature of a walker visitor callback.
pub const VisitFn = *const fn (ctx: *anyopaque, entry: FileEntry) void;

/// Bundle of (context pointer, callback) supplied to walkZigFiles.
pub const Visitor = struct {
    ctx: *anyopaque,
    visit: VisitFn,
};

/// Recursively walks `fs_root`, invoking `visitor` for every matching file.
/// `display_root` is prepended to each file's relative path in the entry.
pub fn walkZigFiles(
    allocator: Allocator,
    fs_root: []const u8,
    display_root: []const u8,
    opts: WalkOpts,
    visitor: Visitor,
) !void {
    var dir = std.fs.cwd().openDir(fs_root, .{ .iterate = true }) catch return;
    defer dir.close();
    try walkRecursive(allocator, dir, display_root, opts, visitor);
}

fn walkRecursive(
    allocator: Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    opts: WalkOpts,
    visitor: Visitor,
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{entry.name});

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkRecursive(allocator, sub, rel, opts, visitor);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, opts.extension)) continue;
                const excluded = blk: {
                    for (opts.excludes) |pat| {
                        if (matchGlob(rel, pat)) break :blk true;
                    }
                    break :blk false;
                };
                if (excluded) continue;
                const content = dir.readFileAlloc(allocator, entry.name, opts.max_file_bytes) catch continue;
                visitor.visit(visitor.ctx, .{ .rel_path = rel, .content = content });
            },
            else => {},
        }
    }
}

/// Returns true if `text` matches `pattern`. `*` is a wildcard matching any
/// substring; a pattern containing no `*` is treated as a substring match.
pub fn matchGlob(text: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return std.mem.indexOf(u8, text, pattern) != null;
    }
    var ti: usize = 0;
    var parts = std.mem.splitScalar(u8, pattern, '*');
    var first = true;
    while (parts.next()) |part| {
        if (part.len == 0) {
            first = false;
            continue;
        }
        if (first) {
            if (!std.mem.startsWith(u8, text[ti..], part)) return false;
            ti += part.len;
            first = false;
        } else {
            if (std.mem.indexOf(u8, text[ti..], part)) |idx| {
                ti += idx + part.len;
            } else {
                return false;
            }
        }
    }
    if (std.mem.endsWith(u8, pattern, "*")) return true;
    return ti == text.len;
}

/// Resolves `..` and `.` segments in a forward-slash path.
pub fn normalizePath(allocator: Allocator, path: []const u8) []const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
        } else {
            parts.append(allocator, seg) catch {};
        }
    }
    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) result.append(allocator, '/') catch {};
        result.appendSlice(allocator, part) catch {};
    }
    return result.toOwnedSlice(allocator) catch path;
}

test "matchGlob boundary patterns" {
    try std.testing.expect(matchGlob("src/stages/foo.zig", "src/stages/*"));
    try std.testing.expect(matchGlob("src/stages/sub/bar.zig", "src/stages/*"));
    try std.testing.expect(!matchGlob("src/other/foo.zig", "src/stages/*"));
    try std.testing.expect(!matchGlob("src/stages.zig", "src/stages/*"));
    try std.testing.expect(matchGlob("src/stages/foo.zig", "src/stages/"));
    try std.testing.expect(!matchGlob("src/other.zig", "src/stages/"));
    try std.testing.expect(matchGlob("src/main.zig", "src/main.zig"));
    try std.testing.expect(!matchGlob("src/main.zig", "src/other.zig"));
    try std.testing.expect(matchGlob("src/foo/bar.zig", "src/foo"));
}

test "matchGlob wildcards" {
    try std.testing.expect(matchGlob("src/core/math.zig", "math"));
    try std.testing.expect(!matchGlob("src/core/math.zig", "xyz"));
    try std.testing.expect(matchGlob("src/generated/output.zig", "*/output.zig"));
    try std.testing.expect(matchGlob("src/generated/foo.zig", "src/generated/*"));
    try std.testing.expect(!matchGlob("src/core/foo.zig", "src/generated/*"));
    try std.testing.expect(matchGlob("src/core/math.zig", "src/*/math.zig"));
    try std.testing.expect(matchGlob("a/b/c/d.zig", "a/*/c/*"));
    try std.testing.expect(matchGlob("anything", "*"));
}

test "normalizePath resolves parent refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/utils/foo.zig", normalizePath(a, "src/core/../utils/foo.zig"));
    try std.testing.expectEqualStrings("src/main.zig", normalizePath(a, "src/./main.zig"));
    try std.testing.expectEqualStrings("foo.zig", normalizePath(a, "a/b/../../foo.zig"));
}
