const std = @import("std");
const config_mod = @import("config.zig");

pub fn extractImports(allocator: std.mem.Allocator, content: []const u8, file_path: []const u8) []const []const u8 {
    var imports: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.indexOf(u8, trimmed, "@import(\"")) |idx| {
            const start = idx + 9;
            if (std.mem.indexOfScalarPos(u8, trimmed, start, '"')) |end| {
                const import_path = trimmed[start..end];
                if (std.mem.eql(u8, import_path, "std")) continue;
                if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |dir_end| {
                    const raw = std.fmt.allocPrint(allocator, "{s}/{s}", .{ file_path[0..dir_end], import_path }) catch continue;
                    const resolved = normalizePath(allocator, raw);
                    imports.append(allocator, resolved) catch {};
                } else {
                    imports.append(allocator, import_path) catch {};
                }
            }
        }
    }
    return imports.toOwnedSlice(allocator) catch &.{};
}

pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) []const u8 {
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

pub fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 1]; // keep trailing /
        return std.mem.startsWith(u8, path, prefix);
    }
    if (std.mem.endsWith(u8, pattern, "/")) {
        return std.mem.startsWith(u8, path, pattern);
    }
    if (std.mem.eql(u8, path, pattern)) return true;
    if (std.mem.startsWith(u8, path, pattern) and path.len > pattern.len and path[pattern.len] == '/') return true;
    return false;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub fn walkBoundaries(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    rules: []const config_mod.BoundaryRule,
    violations: *std.ArrayListUnmanaged([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkBoundaries(allocator, sub, rel, rules, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                const imports = extractImports(allocator, content, rel);
                for (rules) |rule| {
                    if (!matchesPattern(rel, rule.module_pattern)) continue;
                    for (imports) |imp| {
                        for (rule.forbidden_imports) |f| {
                            if (std.mem.indexOf(u8, imp, f) != null) {
                                const msg = std.fmt.allocPrint(allocator, "{s}: forbidden import '{s}' (rule: {s})", .{ rel, imp, rule.module_pattern }) catch continue;
                                violations.append(allocator, msg) catch {};
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "matchesPattern glob" {
    try std.testing.expect(matchesPattern("src/stages/foo.zig", "src/stages/*"));
    try std.testing.expect(matchesPattern("src/stages/sub/bar.zig", "src/stages/*"));
    try std.testing.expect(!matchesPattern("src/other/foo.zig", "src/stages/*"));
    try std.testing.expect(!matchesPattern("src/stages.zig", "src/stages/*"));
}

test "matchesPattern prefix" {
    try std.testing.expect(matchesPattern("src/stages/foo.zig", "src/stages/"));
    try std.testing.expect(!matchesPattern("src/other.zig", "src/stages/"));
}

test "matchesPattern exact" {
    try std.testing.expect(matchesPattern("src/main.zig", "src/main.zig"));
    try std.testing.expect(!matchesPattern("src/main.zig", "src/other.zig"));
    try std.testing.expect(matchesPattern("src/foo/bar.zig", "src/foo"));
    try std.testing.expect(!matchesPattern("src/foobar.zig", "src/foo"));
}

test "extractImports resolves paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content =
        \\const std = @import("std");
        \\const shell = @import("shell.zig");
        \\const parser = @import("../spec/parser.zig");
    ;

    const imports = extractImports(allocator, content, "src/stages/foo.zig");
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    try std.testing.expectEqualStrings("src/stages/shell.zig", imports[0]);
    try std.testing.expectEqualStrings("src/spec/parser.zig", imports[1]);
}

test "normalizePath resolves parent refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("src/utils/foo.zig", normalizePath(a, "src/core/../utils/foo.zig"));
    try std.testing.expectEqualStrings("src/main.zig", normalizePath(a, "src/./main.zig"));
    try std.testing.expectEqualStrings("foo.zig", normalizePath(a, "a/b/../../foo.zig"));
    try std.testing.expectEqualStrings("src/bar.zig", normalizePath(a, "src/bar.zig"));
}

test "containsIgnoreCase matches" {
    try std.testing.expect(containsIgnoreCase("Adds two numbers correctly", "add"));
    try std.testing.expect(containsIgnoreCase("Validates JWT tokens", "validates"));
    try std.testing.expect(containsIgnoreCase("UPPERCASE text", "uppercase"));
    try std.testing.expect(containsIgnoreCase("exact", "exact"));
    try std.testing.expect(!containsIgnoreCase("Multiplies numbers", "multiply"));
    try std.testing.expect(!containsIgnoreCase("short", "longer_needle"));
    try std.testing.expect(!containsIgnoreCase("abc", "xyz"));
    try std.testing.expect(!containsIgnoreCase("anything", ""));
}
