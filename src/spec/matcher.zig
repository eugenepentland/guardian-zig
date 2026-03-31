const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");

pub const SpecTag = struct {
    file: []const u8,
    tag: []const u8,
    key: []const u8,
};

pub const CoverageResult = struct {
    total_behaviors: usize,
    covered_behaviors: usize,
    unverified_behaviors: []const parser.Behavior,
    unlinked_tags: []const SpecTag,
};

pub fn scanDir(allocator: Allocator, dir_path: []const u8) []const SpecTag {
    var tags: std.ArrayListUnmanaged(SpecTag) = .empty;
    scanDirRecursive(allocator, dir_path, &tags) catch {};
    return tags.toOwnedSlice(allocator) catch &.{};
}

fn scanDirRecursive(allocator: Allocator, dir_path: []const u8, tags: *std.ArrayListUnmanaged(SpecTag)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try scanDirRecursive(allocator, full_path, tags),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                    extractTags(allocator, full_path, content, tags);
                }
            },
            else => {},
        }
    }
}

fn extractTags(allocator: Allocator, path: []const u8, content: []const u8, tags: *std.ArrayListUnmanaged(SpecTag)) void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, line, "// spec: ")) {
            const tag_text = line[9..];
            const key = parser.normalizeKey(allocator, tag_text) catch continue;
            tags.append(allocator, .{
                .file = path,
                .tag = tag_text,
                .key = key,
            }) catch {};
        }
    }
}

pub fn analyze(allocator: Allocator, sections: []const parser.Section, tags: []const SpecTag) CoverageResult {
    var all_behaviors: std.ArrayListUnmanaged(parser.Behavior) = .empty;
    for (sections) |s| {
        for (s.behaviors) |b| {
            all_behaviors.append(allocator, b) catch {};
        }
    }
    const behaviors = all_behaviors.items;

    // Find unverified behaviors (no matching tag)
    var unverified: std.ArrayListUnmanaged(parser.Behavior) = .empty;
    for (behaviors) |b| {
        var found = false;
        for (tags) |t| {
            if (std.mem.eql(u8, b.key, t.key)) {
                found = true;
                break;
            }
        }
        if (!found) unverified.append(allocator, b) catch {};
    }

    // Find unlinked tags (no matching behavior)
    var unlinked: std.ArrayListUnmanaged(SpecTag) = .empty;
    for (tags) |t| {
        var found = false;
        for (behaviors) |b| {
            if (std.mem.eql(u8, t.key, b.key)) {
                found = true;
                break;
            }
        }
        if (!found) unlinked.append(allocator, t) catch {};
    }

    return .{
        .total_behaviors = behaviors.len,
        .covered_behaviors = behaviors.len - unverified.items.len,
        .unverified_behaviors = unverified.toOwnedSlice(allocator) catch &.{},
        .unlinked_tags = unlinked.toOwnedSlice(allocator) catch &.{},
    };
}
