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

/// Simple glob matching: `*` matches any sequence of characters.
/// No `*` in pattern falls back to substring match (backward compatible).
pub fn matchGlob(text: []const u8, pattern: []const u8) bool {
    // If pattern has no wildcard, fall back to substring match
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return std.mem.indexOf(u8, text, pattern) != null;
    }
    // Split pattern by * and match segments in order
    var ti: usize = 0;
    var parts = std.mem.splitScalar(u8, pattern, '*');
    var first = true;
    while (parts.next()) |part| {
        if (part.len == 0) {
            first = false;
            continue;
        }
        if (first) {
            // First segment must match at start
            if (!std.mem.startsWith(u8, text[ti..], part)) return false;
            ti += part.len;
            first = false;
        } else {
            // Find segment anywhere after current position
            if (std.mem.indexOf(u8, text[ti..], part)) |idx| {
                ti += idx + part.len;
            } else {
                return false;
            }
        }
    }
    // If pattern ends with *, any trailing text is fine
    // If not, text must be consumed
    if (std.mem.endsWith(u8, pattern, "*")) return true;
    return ti == text.len;
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

pub fn walkFileSize(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    max_lines: u32,
    excludes: []const []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
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
                try walkFileSize(allocator, sub, rel, max_lines, excludes, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const excluded = blk: {
                    for (excludes) |pat| {
                        if (matchGlob(rel, pat)) break :blk true;
                    }
                    break :blk false;
                };
                if (excluded) continue;
                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                var lines: u32 = 1;
                for (content) |c| {
                    if (c == '\n') lines += 1;
                }
                if (lines > max_lines) {
                    const msg = try std.fmt.allocPrint(allocator, "{s}: {d} lines (limit: {d})", .{ rel, lines, max_lines });
                    try violations.append(allocator, msg);
                }
            },
            else => {},
        }
    }
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

test "walkFileSize on test-project with high limit finds no violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    defer dir.close();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    try walkFileSize(a, dir, "src", 50, &.{}, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "walkFileSize on test-project with low limit finds violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    defer dir.close();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    try walkFileSize(a, dir, "src", 10, &.{}, &violations);
    // main.zig (34 lines), math.zig (15), strings.zig (11) should all exceed limit 10
    try std.testing.expect(violations.items.len >= 3);
}

test "walkFileSize respects exclude patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    defer dir.close();

    // With limit 10, without excludes we get 3+ violations
    // Exclude "main" should skip main.zig, reducing violations
    var without_exclude: std.ArrayListUnmanaged([]const u8) = .empty;
    try walkFileSize(a, dir, "src", 10, &.{}, &without_exclude);
    const count_without = without_exclude.items.len;

    dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;

    var with_exclude: std.ArrayListUnmanaged([]const u8) = .empty;
    try walkFileSize(a, dir, "src", 10, &.{"main"}, &with_exclude);
    const count_with = with_exclude.items.len;

    // Excluding "main" should result in fewer violations
    try std.testing.expect(count_with < count_without);
    // And main.zig should not appear in violations
    for (with_exclude.items) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v, "main.zig") == null);
    }
}

test "walkBoundaries detects violation in test-project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // test-project has a boundary rule: src/core/* cannot import utils
    // and core/math.zig imports ../utils/helpers.zig
    var dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    defer dir.close();

    const rules = &[_]config_mod.BoundaryRule{
        .{ .module_pattern = "src/core/*", .forbidden_imports = &.{"utils"} },
    };

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    walkBoundaries(a, dir, "src", rules, &violations) catch return;

    // Should find the violation: core/math.zig imports utils/helpers.zig
    try std.testing.expect(violations.items.len > 0);
    // Verify the violation message mentions the right file
    var found_math = false;
    for (violations.items) |v| {
        if (std.mem.indexOf(u8, v, "math.zig") != null) found_math = true;
    }
    try std.testing.expect(found_math);
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

test "matchGlob basic patterns" {
    // Substring fallback (no wildcard)
    try std.testing.expect(matchGlob("src/core/math.zig", "math"));
    try std.testing.expect(!matchGlob("src/core/math.zig", "xyz"));

    // Leading wildcard
    try std.testing.expect(matchGlob("src/generated/output.zig", "*/output.zig"));
    try std.testing.expect(matchGlob("anything/output.zig", "*/output.zig"));

    // Trailing wildcard
    try std.testing.expect(matchGlob("src/generated/foo.zig", "src/generated/*"));
    try std.testing.expect(!matchGlob("src/core/foo.zig", "src/generated/*"));

    // Middle wildcard
    try std.testing.expect(matchGlob("src/core/math.zig", "src/*/math.zig"));
    try std.testing.expect(!matchGlob("src/core/strings.zig", "src/*/math.zig"));

    // Multiple wildcards
    try std.testing.expect(matchGlob("a/b/c/d.zig", "a/*/c/*"));

    // Exact with wildcard (whole thing)
    try std.testing.expect(matchGlob("anything", "*"));
}
