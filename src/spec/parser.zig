const std = @import("std");
const Allocator = std.mem.Allocator;

/// One bullet under a SPEC.md section: the section name, the bullet text,
/// and the normalized lookup key.
pub const Behavior = struct {
    section: []const u8,
    statement: []const u8,
    key: []const u8,
};

/// One ## section in SPEC.md and its behaviors.
pub const Section = struct {
    name: []const u8,
    behaviors: []const Behavior,
};

/// Errors propagated by parser fns.
pub const ParseError = std.mem.Allocator.Error || error{CouldNotReadSpec};

/// Reads `path` and parses it as SPEC.md.
pub fn parseFile(allocator: Allocator, path: []const u8) ParseError![]const Section {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return error.CouldNotReadSpec;
    return parseContent(allocator, content);
}

/// Mutable state threaded through parseContent while it walks SPEC.md lines.
const ParseState = struct {
    allocator: Allocator,
    sections: std.ArrayListUnmanaged(Section) = .empty,
    current_section: ?[]const u8 = null,
    current_behaviors: std.ArrayListUnmanaged(Behavior) = .empty,
    skipping: bool = false, // inside a skipped ## Overview / ## Planned section

    // Flush the section we were building so its bullets can't leak into a
    // later section.
    fn flushSection(self: *ParseState) ParseError!void {
        if (self.current_section) |sec| {
            try self.sections.append(self.allocator, .{
                .name = sec,
                .behaviors = try self.current_behaviors.toOwnedSlice(self.allocator),
            });
        }
    }

    fn handleHeading(self: *ParseState, line: []const u8) ParseError!void {
        const name = std.mem.trim(u8, line[3..], &std.ascii.whitespace);
        try self.flushSection();
        self.current_section = null;
        self.current_behaviors = .empty;

        if (std.ascii.eqlIgnoreCase(name, "overview") or std.ascii.eqlIgnoreCase(name, "planned")) {
            self.skipping = true;
            return;
        }
        self.skipping = false;
        self.current_section = name;
    }

    fn handleSubheading(self: *ParseState, line: []const u8) ParseError!void {
        const sub = std.mem.trim(u8, line[4..], &std.ascii.whitespace);
        if (self.current_section) |sec| {
            if (self.current_behaviors.items.len > 0) {
                try self.sections.append(self.allocator, .{
                    .name = sec,
                    .behaviors = try self.current_behaviors.toOwnedSlice(self.allocator),
                });
            }
            const base = if (std.mem.indexOf(u8, sec, " - ")) |idx| sec[0..idx] else sec;
            self.current_section = try std.fmt.allocPrint(self.allocator, "{s} - {s}", .{ base, sub });
        } else {
            self.current_section = sub;
        }
        self.current_behaviors = .empty;
    }

    fn handleBullet(self: *ParseState, line: []const u8) ParseError!void {
        const sec = self.current_section orelse return;
        const statement = std.mem.trim(u8, line[2..], &std.ascii.whitespace);
        const raw_key = try std.fmt.allocPrint(self.allocator, "{s} - {s}", .{ sec, statement });
        const key = try normalizeKey(self.allocator, raw_key);
        try self.current_behaviors.append(self.allocator, .{
            .section = sec,
            .statement = statement,
            .key = key,
        });
    }
};

/// Parses SPEC.md text into sections + behaviors. Skips Overview/Planned.
pub fn parseContent(allocator: Allocator, content: []const u8) ParseError![]const Section {
    var state: ParseState = .{ .allocator = allocator };

    var in_fence = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);

        // A fenced code block is illustrative markdown, not spec content — its
        // `- `/`## ` lines must not mint phantom behaviors or sections.
        if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        if (std.mem.startsWith(u8, line, "## ")) {
            try state.handleHeading(line);
        } else if (std.mem.startsWith(u8, line, "### ")) {
            if (state.skipping) continue;
            try state.handleSubheading(line);
        } else if (std.mem.startsWith(u8, line, "- ")) {
            if (state.skipping) continue;
            try state.handleBullet(line);
        }
    }

    try state.flushSection();
    return state.sections.toOwnedSlice(allocator);
}

/// Lowercases and collapses whitespace for whitespace-insensitive comparison.
pub fn normalizeKey(allocator: Allocator, text: []const u8) ParseError![]const u8 {
    // Lowercase and collapse whitespace
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var prev_space = false;
    for (text) |c| {
        const lower = std.ascii.toLower(c);
        if (lower == ' ' or lower == '\t') {
            if (!prev_space) {
                try result.append(allocator, ' ');
                prev_space = true;
            }
        } else {
            try result.append(allocator, lower);
            prev_space = false;
        }
    }
    // Propagate OOM rather than returning "" — an empty key would spuriously
    // match another empty key and report false coverage.
    const slice = try result.toOwnedSlice(allocator);
    return std.mem.trim(u8, slice, &std.ascii.whitespace);
}

// spec: Spec Lifecycle - Normalizes spec keys for whitespace-insensitive comparison
// spec: Spec Coverage - Parses SPEC.md for section headers and behavior bullets
// spec: Spec Coverage - Reports unverified behaviors and unlinked tags

test "parse spec content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content =
        \\# My Project
        \\
        \\## Overview
        \\This is an overview.
        \\
        \\## Compilation
        \\- Runs zig build successfully
        \\- Reports errors on failure
        \\
        \\## Format
        \\- Checks formatting with zig fmt
    ;
    const sections = try parseContent(allocator, content);

    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("Compilation", sections[0].name);
    try std.testing.expectEqual(@as(usize, 2), sections[0].behaviors.len);
    try std.testing.expectEqualStrings("Runs zig build successfully", sections[0].behaviors[0].statement);
}

test "parse ignores fenced code and trailing Planned section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\# Proj
        \\
        \\## Real
        \\- does a thing
        \\
        \\```zig
        \\## NotASection
        \\- not a behavior
        \\```
        \\
        \\## Planned
        \\- future idea one
        \\- future idea two
    ;
    const sections = try parseContent(a, content);
    // Only "Real" with its single behavior — the fenced ## / - lines and the
    // trailing Planned bullets are excluded.
    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqualStrings("Real", sections[0].name);
    try std.testing.expectEqual(@as(usize, 1), sections[0].behaviors.len);
}

// spec: Spec Coverage - Fails with clear error when SPEC.md is missing
test "parseFile errors when the spec file is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CouldNotReadSpec, parseFile(arena.allocator(), "definitely/not/a/spec.md"));
}

// spec: Spec Coverage - Fails when SPEC.md defines no behaviors
test "parseContent yields no behaviors for a headings-only spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sections = try parseContent(arena.allocator(), "# Title\n## Section\n");
    var total: usize = 0;
    for (sections) |s| total += s.behaviors.len;
    try std.testing.expectEqual(@as(usize, 0), total);
}

test "normalize key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try normalizeKey(allocator, "  Compilation  -  Runs  Zig  Build  ");
    try std.testing.expectEqualStrings("compilation - runs zig build", result);
}
