const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const walk = @import("../walk.zig");

// spec: Spec Coverage - Scans test and source files for // spec: tags

/// One `// spec:` tag found in source.
pub const SpecTag = struct {
    file: []const u8,
    tag: []const u8,
    key: []const u8,
};

// spec: Spec Coverage - Enforces 1:1 mapping between spec behaviors and test tags

/// A spec key found on more than one tag — a 1:1 mapping violation.
pub const DuplicateTag = struct {
    key: []const u8,
    files: []const []const u8,
};

/// Coverage analysis result reported by `analyze`.
pub const CoverageResult = struct {
    total_behaviors: usize,
    covered_behaviors: usize,
    unverified_behaviors: []const parser.Behavior,
    unlinked_tags: []const SpecTag,
    duplicate_tags: []const DuplicateTag,
};

const ScanCtx = struct {
    allocator: Allocator,
    tags: *std.ArrayListUnmanaged(SpecTag),
};

fn scanVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    extractTags(ctx.allocator, entry.rel_path, entry.content, ctx.tags);
}

/// Recursively scans a directory for `// spec:` tags and returns the list.
pub fn scanDir(allocator: Allocator, dir_path: []const u8) []const SpecTag {
    var tags: std.ArrayListUnmanaged(SpecTag) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .tags = &tags };
    walk.walkZigFiles(allocator, dir_path, dir_path, .{}, .{ .ctx = &ctx, .visit = scanVisit }) catch {};
    return tags.toOwnedSlice(allocator) catch &.{};
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

/// Cross-references behaviors and tags; returns covered count plus
/// unverified behaviors, unlinked tags, and duplicate tags.
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

    // Find duplicate tags (1:1 mapping enforcement)
    var duplicates: std.ArrayListUnmanaged(DuplicateTag) = .empty;
    for (tags, 0..) |t, i| {
        // Check if we already reported this key
        var already_reported = false;
        for (duplicates.items) |d| {
            if (std.mem.eql(u8, d.key, t.key)) {
                already_reported = true;
                break;
            }
        }
        if (already_reported) continue;

        // Find all tags with this key
        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        files.append(allocator, t.file) catch {};
        for (tags[i + 1 ..]) |t2| {
            if (std.mem.eql(u8, t.key, t2.key)) {
                files.append(allocator, t2.file) catch {};
            }
        }
        if (files.items.len > 1) {
            duplicates.append(allocator, .{
                .key = t.key,
                .files = files.toOwnedSlice(allocator) catch &.{},
            }) catch {};
        }
    }

    return .{
        .total_behaviors = behaviors.len,
        .covered_behaviors = behaviors.len - unverified.items.len,
        .unverified_behaviors = unverified.toOwnedSlice(allocator) catch &.{},
        .unlinked_tags = unlinked.toOwnedSlice(allocator) catch &.{},
        .duplicate_tags = duplicates.toOwnedSlice(allocator) catch &.{},
    };
}

test "analyze full coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sections = &[_]parser.Section{
        .{ .name = "Math", .behaviors = &.{
            .{ .section = "Math", .statement = "adds numbers", .key = "math - adds numbers" },
        } },
    };
    const tags = &[_]SpecTag{
        .{ .file = "test.zig", .tag = "Math - adds numbers", .key = "math - adds numbers" },
    };
    const result = analyze(a, sections, tags);

    try std.testing.expectEqual(@as(usize, 1), result.total_behaviors);
    try std.testing.expectEqual(@as(usize, 1), result.covered_behaviors);
    try std.testing.expectEqual(@as(usize, 0), result.unverified_behaviors.len);
    try std.testing.expectEqual(@as(usize, 0), result.unlinked_tags.len);
    try std.testing.expectEqual(@as(usize, 0), result.duplicate_tags.len);
}

test "analyze unverified behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sections = &[_]parser.Section{
        .{ .name = "Math", .behaviors = &.{
            .{ .section = "Math", .statement = "adds", .key = "math - adds" },
            .{ .section = "Math", .statement = "multiplies", .key = "math - multiplies" },
        } },
    };
    const tags = &[_]SpecTag{
        .{ .file = "test.zig", .tag = "Math - adds", .key = "math - adds" },
    };
    const result = analyze(a, sections, tags);

    try std.testing.expectEqual(@as(usize, 2), result.total_behaviors);
    try std.testing.expectEqual(@as(usize, 1), result.covered_behaviors);
    try std.testing.expectEqual(@as(usize, 1), result.unverified_behaviors.len);
    try std.testing.expectEqualStrings("multiplies", result.unverified_behaviors[0].statement);
}

test "analyze duplicate tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sections = &[_]parser.Section{
        .{ .name = "Math", .behaviors = &.{
            .{ .section = "Math", .statement = "adds", .key = "math - adds" },
        } },
    };
    const tags = &[_]SpecTag{
        .{ .file = "a.zig", .tag = "Math - adds", .key = "math - adds" },
        .{ .file = "b.zig", .tag = "Math - adds", .key = "math - adds" },
    };
    const result = analyze(a, sections, tags);

    try std.testing.expectEqual(@as(usize, 1), result.duplicate_tags.len);
    try std.testing.expectEqualStrings("math - adds", result.duplicate_tags[0].key);
    try std.testing.expectEqual(@as(usize, 2), result.duplicate_tags[0].files.len);
}

test "analyze unlinked tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sections = &[_]parser.Section{};
    const tags = &[_]SpecTag{
        .{ .file = "test.zig", .tag = "Nonexistent - behavior", .key = "nonexistent - behavior" },
    };
    const result = analyze(a, sections, tags);

    try std.testing.expectEqual(@as(usize, 0), result.total_behaviors);
    try std.testing.expectEqual(@as(usize, 1), result.unlinked_tags.len);
}
