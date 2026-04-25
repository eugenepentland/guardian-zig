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

/// Parses SPEC.md text into sections + behaviors. Skips Overview/Planned.
pub fn parseContent(allocator: Allocator, content: []const u8) ParseError![]const Section {
    var sections: std.ArrayListUnmanaged(Section) = .empty;
    var current_section: ?[]const u8 = null;
    var current_behaviors: std.ArrayListUnmanaged(Behavior) = .empty;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);

        if (std.mem.startsWith(u8, line, "## ")) {
            const name = std.mem.trim(u8, line[3..], &std.ascii.whitespace);

            // Skip "Overview" and "Planned" sections
            if (std.ascii.eqlIgnoreCase(name, "overview") or std.ascii.eqlIgnoreCase(name, "planned")) continue;

            // Flush previous section
            if (current_section) |sec| {
                sections.append(allocator, .{
                    .name = sec,
                    .behaviors = current_behaviors.toOwnedSlice(allocator) catch &.{},
                }) catch {};
            }
            current_section = name;
            current_behaviors = .empty;
        } else if (std.mem.startsWith(u8, line, "### ")) {
            const sub = std.mem.trim(u8, line[4..], &std.ascii.whitespace);
            // Flush current section if it has behaviors
            if (current_section) |sec| {
                if (current_behaviors.items.len > 0) {
                    sections.append(allocator, .{
                        .name = sec,
                        .behaviors = current_behaviors.toOwnedSlice(allocator) catch &.{},
                    }) catch {};
                }
            }
            // Compound name
            if (current_section) |sec| {
                const base = if (std.mem.indexOf(u8, sec, " - ")) |idx| sec[0..idx] else sec;
                current_section = std.fmt.allocPrint(allocator, "{s} - {s}", .{ base, sub }) catch sub;
            } else {
                current_section = sub;
            }
            current_behaviors = .empty;
        } else if (std.mem.startsWith(u8, line, "- ")) {
            if (current_section) |sec| {
                const statement = std.mem.trim(u8, line[2..], &std.ascii.whitespace);
                const raw_key = std.fmt.allocPrint(allocator, "{s} - {s}", .{ sec, statement }) catch continue;
                const key = normalizeKey(allocator, raw_key) catch continue;
                current_behaviors.append(allocator, .{
                    .section = sec,
                    .statement = statement,
                    .key = key,
                }) catch {};
            }
        }
    }

    // Flush last section
    if (current_section) |sec| {
        sections.append(allocator, .{
            .name = sec,
            .behaviors = current_behaviors.toOwnedSlice(allocator) catch &.{},
        }) catch {};
    }

    return sections.toOwnedSlice(allocator);
}

// spec: Spec Lifecycle - Normalizes spec keys for whitespace-insensitive comparison
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
    const slice = result.toOwnedSlice(allocator) catch return "";
    return std.mem.trim(u8, slice, &std.ascii.whitespace);
}

// spec: Spec Coverage - Parses SPEC.md for section headers and behavior bullets
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

// spec: Spec Coverage - Reports unverified behaviors and unlinked tags
test "normalize key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try normalizeKey(allocator, "  Compilation  -  Runs  Zig  Build  ");
    try std.testing.expectEqualStrings("compilation - runs zig build", result);
}
