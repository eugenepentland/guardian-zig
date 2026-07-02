const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const walk = @import("../walk.zig");

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

/// Tags and near-miss tags collected from one directory scan. `unattached`
/// holds well-formed `// spec:` tags that are NOT directly above a test decl —
/// a tag must sit on the test that verifies its behavior, or the "coverage"
/// is just a comment with no running test behind it.
pub const ScanResult = struct {
    tags: []const SpecTag,
    malformed: []const MalformedTag,
    unattached: []const MalformedTag,
};

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
    unattached: *std.ArrayListUnmanaged(MalformedTag),
};

fn scanVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try extractTags(ctx, entry.rel_path, entry.content);
}

/// Recursively scans a directory for `// spec:` tags (and near-miss/unattached).
pub fn scanDir(allocator: Allocator, dir_path: []const u8) ScanError!ScanResult {
    var tags: std.ArrayListUnmanaged(SpecTag) = .empty;
    var malformed: std.ArrayListUnmanaged(MalformedTag) = .empty;
    var unattached: std.ArrayListUnmanaged(MalformedTag) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .tags = &tags, .malformed = &malformed, .unattached = &unattached };
    try walk.walkZigFiles(allocator, dir_path, dir_path, .{}, .{ .ctx = &ctx, .visit = scanVisit });
    return .{
        .tags = try tags.toOwnedSlice(allocator),
        .malformed = try malformed.toOwnedSlice(allocator),
        .unattached = try unattached.toOwnedSlice(allocator),
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

fn extractTags(ctx: *ScanCtx, path: []const u8, content: []const u8) !void {
    const allocator = ctx.allocator;
    // Collect lines so we can look ahead from a tag to the next code line.
    var line_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| try line_list.append(allocator, std.mem.trim(u8, raw, &std.ascii.whitespace));
    const lines = line_list.items;

    for (lines, 0..) |line, i| {
        if (std.mem.startsWith(u8, line, SPEC_PREFIX)) {
            const tag_text = line[SPEC_PREFIX.len..];
            if (tagPrecedesTest(lines, i)) {
                try ctx.tags.append(allocator, .{
                    .file = path,
                    .tag = tag_text,
                    .key = try parser.normalizeKey(allocator, tag_text),
                });
            } else {
                try ctx.unattached.append(allocator, .{
                    .file = path,
                    .line = @intCast(i + 1),
                    .text = try allocator.dupe(u8, line),
                });
            }
        } else if (looksLikeSpecTag(line)) {
            try ctx.malformed.append(allocator, .{
                .file = path,
                .line = @intCast(i + 1),
                .text = try allocator.dupe(u8, line),
            });
        }
    }
}

/// True when the tag at `lines[i]` sits directly on a test — i.e. the next
/// line that isn't blank, another `// spec:` tag, or a `///` doc comment
/// begins a `test` declaration. Stacked tags above one test are allowed.
fn tagPrecedesTest(lines: []const []const u8, i: usize) bool {
    var j = i + 1;
    while (j < lines.len) : (j += 1) {
        const s = lines[j];
        if (s.len == 0) continue;
        if (std.mem.startsWith(u8, s, SPEC_PREFIX)) continue;
        if (std.mem.startsWith(u8, s, "///")) continue;
        return std.mem.startsWith(u8, s, "test ") or std.mem.startsWith(u8, s, "test{");
    }
    return false;
}

/// Flattens every behavior across all sections into one owned slice.
fn flattenBehaviors(
    allocator: Allocator,
    sections: []const parser.Section,
) Allocator.Error![]parser.Behavior {
    var all_behaviors: std.ArrayListUnmanaged(parser.Behavior) = .empty;
    for (sections) |s| {
        for (s.behaviors) |b| {
            try all_behaviors.append(allocator, b);
        }
    }
    return all_behaviors.toOwnedSlice(allocator);
}

/// True when some tag's key equals `key` — i.e. the behavior is verified.
fn tagCoversKey(tags: []const SpecTag, key: []const u8) bool {
    for (tags) |t| {
        if (std.mem.eql(u8, key, t.key)) return true;
    }
    return false;
}

/// Behaviors with no matching tag — the unverified set.
fn collectUnverified(
    allocator: Allocator,
    behaviors: []const parser.Behavior,
    tags: []const SpecTag,
) Allocator.Error![]parser.Behavior {
    var unverified: std.ArrayListUnmanaged(parser.Behavior) = .empty;
    for (behaviors) |b| {
        if (!tagCoversKey(tags, b.key)) try unverified.append(allocator, b);
    }
    return unverified.toOwnedSlice(allocator);
}

/// True when some behavior's key equals `key` — i.e. the tag is linked.
fn behaviorHasKey(behaviors: []const parser.Behavior, key: []const u8) bool {
    for (behaviors) |b| {
        if (std.mem.eql(u8, key, b.key)) return true;
    }
    return false;
}

/// Tags with no matching behavior — the unlinked set.
fn collectUnlinked(
    allocator: Allocator,
    behaviors: []const parser.Behavior,
    tags: []const SpecTag,
) Allocator.Error![]SpecTag {
    var unlinked: std.ArrayListUnmanaged(SpecTag) = .empty;
    for (tags) |t| {
        if (!behaviorHasKey(behaviors, t.key)) try unlinked.append(allocator, t);
    }
    return unlinked.toOwnedSlice(allocator);
}

/// Keys carried by more than one tag. Groups tags by key in one pass so
/// detection is O(n) instead of O(n²); insertion order is preserved.
fn collectDuplicateTags(
    allocator: Allocator,
    tags: []const SpecTag,
) Allocator.Error![]DuplicateTag {
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
    return duplicates.toOwnedSlice(allocator);
}

/// Behavior keys appearing on more than one bullet. Two identical bullets
/// would both be "covered" by one tag, silently breaking the 1:1 guarantee.
fn collectDuplicateBehaviors(
    allocator: Allocator,
    behaviors: []const parser.Behavior,
) Allocator.Error![]DuplicateBehavior {
    var counts = std.StringArrayHashMap(usize).init(allocator);
    for (behaviors) |b| {
        const gop = try counts.getOrPut(b.key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var dup_behaviors: std.ArrayListUnmanaged(DuplicateBehavior) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* <= 1) continue;
        try dup_behaviors.append(allocator, .{ .key = e.key_ptr.*, .count = e.value_ptr.* });
    }
    return dup_behaviors.toOwnedSlice(allocator);
}

/// Cross-references behaviors and tags; returns covered count plus
/// unverified behaviors, unlinked tags, and duplicate tags.
pub fn analyze(
    allocator: Allocator,
    sections: []const parser.Section,
    tags: []const SpecTag,
) std.mem.Allocator.Error!CoverageResult {
    const behaviors = try flattenBehaviors(allocator, sections);
    const unverified = try collectUnverified(allocator, behaviors, tags);
    return .{
        .total_behaviors = behaviors.len,
        .covered_behaviors = behaviors.len - unverified.len,
        .unverified_behaviors = unverified,
        .unlinked_tags = try collectUnlinked(allocator, behaviors, tags),
        .duplicate_tags = try collectDuplicateTags(allocator, tags),
        .duplicate_behaviors = try collectDuplicateBehaviors(allocator, behaviors),
    };
}

// spec: Spec Coverage - Scans test and source files for // spec: tags
// spec: Spec Coverage - Enforces 1:1 mapping between spec behaviors and test tags
// spec: Spec Coverage - Reports near-miss spec tags that miss the exact prefix
// spec: Spec Coverage - Reports duplicate spec behavior bullets

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

// spec: Spec Coverage - Requires each spec tag to sit directly on a test
test "extractTags classifies tags by attachment, near-miss, and prose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        "// spec: Math - adds\n" ++ // attached — a test follows
        "test \"adds\" {}\n" ++
        "// spec: Math - subs\n" ++ // unattached — no test follows
        "const x = 1;\n" ++
        "//spec: Math - muls\n" ++ // malformed: no space after //
        "// species of birds: many\n"; // prose, not a tag
    var tags: std.ArrayListUnmanaged(SpecTag) = .empty;
    var malformed: std.ArrayListUnmanaged(MalformedTag) = .empty;
    var unattached: std.ArrayListUnmanaged(MalformedTag) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .tags = &tags, .malformed = &malformed, .unattached = &unattached };
    try extractTags(&ctx, "x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), tags.items.len);
    try std.testing.expectEqual(@as(usize, 1), unattached.items.len);
    try std.testing.expectEqual(@as(usize, 1), malformed.items.len);
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
