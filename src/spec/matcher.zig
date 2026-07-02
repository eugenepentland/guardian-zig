const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const walk = @import("../walk.zig");

// spec: Spec Coverage - Scans test and source files for // spec: tags

const SPEC_PREFIX = "// spec: ";

/// One `// spec:` tag found in source.
pub const SpecTag = struct {
    file: []const u8,
    tag: []const u8,
    key: []const u8,
};

/// A comment that was clearly meant to be a `// spec:` tag but doesn't match
/// the exact prefix (e.g. `//spec:`, `// Spec:`, `// spec :`, missing space
/// after the colon). Reported so a typo'd tag isn't silently ignored.
pub const MalformedTag = struct {
    file: []const u8,
    line: u32,
    text: []const u8,
};

/// Tags and near-miss tags collected from one directory scan.
pub const ScanResult = struct {
    tags: []const SpecTag,
    malformed: []const MalformedTag,
};

// spec: Spec Coverage - Enforces 1:1 mapping between spec behaviors and test tags
// spec: Spec Coverage - Reports near-miss spec tags that miss the exact prefix
// spec: Spec Coverage - Reports duplicate spec behavior bullets

/// A spec key found on more than one tag — a 1:1 mapping violation.
pub const DuplicateTag = struct {
    key: []const u8,
    files: []const []const u8,
};

/// A behavior key that appears on more than one SPEC.md bullet. Two identical
/// bullets would both count as covered by a single tag, so 1:1 must be
/// enforced on the behavior side too, not just the tag side.
pub const DuplicateBehavior = struct {
    key: []const u8,
    count: usize,
};

/// Errors that scanDir may propagate (visitor-induced).
pub const ScanError = anyerror;

/// Coverage analysis result reported by `analyze`.
pub const CoverageResult = struct {
    total_behaviors: usize,
    covered_behaviors: usize,
    unverified_behaviors: []const parser.Behavior,
    unlinked_tags: []const SpecTag,
    duplicate_tags: []const DuplicateTag,
    duplicate_behaviors: []const DuplicateBehavior,
};

const ScanCtx = struct {
    allocator: Allocator,
    tags: *std.ArrayListUnmanaged(SpecTag),
    malformed: *std.ArrayListUnmanaged(MalformedTag),
};

fn scanVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try extractTags(ctx.allocator, entry.rel_path, entry.content, ctx.tags, ctx.malformed);
}

/// Recursively scans a directory for `// spec:` tags (and near-miss tags).
pub fn scanDir(allocator: Allocator, dir_path: []const u8) ScanError!ScanResult {
    var tags: std.ArrayListUnmanaged(SpecTag) = .empty;
    var malformed: std.ArrayListUnmanaged(MalformedTag) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .tags = &tags, .malformed = &malformed };
    try walk.walkZigFiles(allocator, dir_path, dir_path, .{}, .{ .ctx = &ctx, .visit = scanVisit });
    return .{
        .tags = try tags.toOwnedSlice(allocator),
        .malformed = try malformed.toOwnedSlice(allocator),
    };
}

/// True when a comment was clearly meant to be a `// spec:` tag but doesn't
/// match the exact `// spec: ` prefix. Requires the comment's first word to be
/// "spec" (case-insensitive) directly followed by `:` (with optional spaces),
/// so prose like `// species: ...` or `// the spec: prefix` is not flagged.
fn looksLikeSpecTag(line: []const u8) bool {
    const kw = "spec";
    if (!std.mem.startsWith(u8, line, "//")) return false;
    const rest = std.mem.trimLeft(u8, line[2..], " ");
    if (rest.len <= kw.len or !std.ascii.eqlIgnoreCase(rest[0..kw.len], kw)) return false;
    const after = std.mem.trimLeft(u8, rest[kw.len..], " ");
    return after.len > 0 and after[0] == ':';
}

fn extractTags(
    allocator: Allocator,
    path: []const u8,
    content: []const u8,
    tags: *std.ArrayListUnmanaged(SpecTag),
    malformed: *std.ArrayListUnmanaged(MalformedTag),
) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, line, SPEC_PREFIX)) {
            const tag_text = line[SPEC_PREFIX.len..];
            const key = try parser.normalizeKey(allocator, tag_text);
            try tags.append(allocator, .{
                .file = path,
                .tag = tag_text,
                .key = key,
            });
        } else if (looksLikeSpecTag(line)) {
            try malformed.append(allocator, .{
                .file = path,
                .line = line_no,
                .text = try allocator.dupe(u8, line),
            });
        }
    }
}

/// Cross-references behaviors and tags; returns covered count plus
/// unverified behaviors, unlinked tags, and duplicate tags.
pub fn analyze(allocator: Allocator, sections: []const parser.Section, tags: []const SpecTag) std.mem.Allocator.Error!CoverageResult {
    var all_behaviors: std.ArrayListUnmanaged(parser.Behavior) = .empty;
    for (sections) |s| {
        for (s.behaviors) |b| {
            try all_behaviors.append(allocator, b);
        }
    }
    const behaviors = all_behaviors.items;

    var unverified: std.ArrayListUnmanaged(parser.Behavior) = .empty;
    for (behaviors) |b| {
        var found = false;
        for (tags) |t| {
            if (std.mem.eql(u8, b.key, t.key)) {
                found = true;
                break;
            }
        }
        if (!found) try unverified.append(allocator, b);
    }

    var unlinked: std.ArrayListUnmanaged(SpecTag) = .empty;
    for (tags) |t| {
        var found = false;
        for (behaviors) |b| {
            if (std.mem.eql(u8, t.key, b.key)) {
                found = true;
                break;
            }
        }
        if (!found) try unlinked.append(allocator, t);
    }

    // Group tags by key in one pass so duplicate detection is O(n) instead
    // of O(n²). Insertion order of keys is preserved for stable output.
    var by_key = std.StringArrayHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);
    for (tags) |t| {
        const gop = try by_key.getOrPut(t.key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, t.file);
    }

    var duplicates: std.ArrayListUnmanaged(DuplicateTag) = .empty;
    var it = by_key.iterator();
    while (it.next()) |e| {
        const files = e.value_ptr.items;
        if (files.len <= 1) continue;
        try duplicates.append(allocator, .{
            .key = e.key_ptr.*,
            .files = try allocator.dupe([]const u8, files),
        });
    }

    // Duplicate detection on the behavior side: two identical bullets would
    // both be "covered" by one tag, silently breaking the 1:1 guarantee.
    var behavior_counts = std.StringArrayHashMap(usize).init(allocator);
    for (behaviors) |b| {
        const gop = try behavior_counts.getOrPut(b.key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var dup_behaviors: std.ArrayListUnmanaged(DuplicateBehavior) = .empty;
    var bit = behavior_counts.iterator();
    while (bit.next()) |e| {
        if (e.value_ptr.* <= 1) continue;
        try dup_behaviors.append(allocator, .{ .key = e.key_ptr.*, .count = e.value_ptr.* });
    }

    return .{
        .total_behaviors = behaviors.len,
        .covered_behaviors = behaviors.len - unverified.items.len,
        .unverified_behaviors = try unverified.toOwnedSlice(allocator),
        .unlinked_tags = try unlinked.toOwnedSlice(allocator),
        .duplicate_tags = try duplicates.toOwnedSlice(allocator),
        .duplicate_behaviors = try dup_behaviors.toOwnedSlice(allocator),
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
    const result = try analyze(a, sections, tags);

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
    const result = try analyze(a, sections, tags);

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
    const result = try analyze(a, sections, tags);

    try std.testing.expectEqual(@as(usize, 1), result.duplicate_tags.len);
    try std.testing.expectEqualStrings("math - adds", result.duplicate_tags[0].key);
    try std.testing.expectEqual(@as(usize, 2), result.duplicate_tags[0].files.len);
}

test "analyze detects duplicate behavior bullets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sections = &[_]parser.Section{
        .{ .name = "Math", .behaviors = &.{
            .{ .section = "Math", .statement = "adds", .key = "math - adds" },
            .{ .section = "Math", .statement = "adds", .key = "math - adds" },
        } },
    };
    const tags = &[_]SpecTag{
        .{ .file = "a.zig", .tag = "Math - adds", .key = "math - adds" },
    };
    const result = try analyze(a, sections, tags);
    try std.testing.expectEqual(@as(usize, 1), result.duplicate_behaviors.len);
    try std.testing.expectEqual(@as(usize, 2), result.duplicate_behaviors[0].count);
}

test "extractTags flags near-miss tags but not prose or valid tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        "// spec: Math - adds\n" ++ // valid
        "//spec: Math - subs\n" ++ // malformed: no space after //
        "// Spec: Math - muls\n" ++ // malformed: capital S
        "// spec : Math - divs\n" ++ // malformed: space before colon
        "// species of birds: many\n" ++ // prose, not a tag
        "// the spec: prefix is exact\n"; // prose, not a tag
    var tags: std.ArrayListUnmanaged(SpecTag) = .empty;
    var malformed: std.ArrayListUnmanaged(MalformedTag) = .empty;
    try extractTags(a, "x.zig", content, &tags, &malformed);
    try std.testing.expectEqual(@as(usize, 1), tags.items.len);
    try std.testing.expectEqual(@as(usize, 3), malformed.items.len);
}

test "analyze unlinked tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sections = &[_]parser.Section{};
    const tags = &[_]SpecTag{
        .{ .file = "test.zig", .tag = "Nonexistent - behavior", .key = "nonexistent - behavior" },
    };
    const result = try analyze(a, sections, tags);

    try std.testing.expectEqual(@as(usize, 0), result.total_behaviors);
    try std.testing.expectEqual(@as(usize, 1), result.unlinked_tags.len);
}
