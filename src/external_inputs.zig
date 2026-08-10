//! Expansion and command substitution for `[[external]]` input declarations.
//! Input patterns are project-relative and use Guardian's existing `*` glob
//! semantics. The exact `{input}` argv token is replaced per matched file; no
//! shell is involved and no other interpolation is performed.

const std = @import("std");
const walk = @import("walk.zig");

const Allocator = std.mem.Allocator;

pub const placeholder = "{input}";

pub const ExpandError = Allocator.Error || std.fs.Dir.OpenError || std.fs.Dir.Iterator.Error;

/// Existing regular files beneath `project_dir` matched by any pattern, sorted
/// and deduplicated. Exact paths and `*` globs use exact and wildcard matching
/// respectively; an exact path is never treated as a substring.
pub fn expand(
    arena: Allocator,
    project_dir: []const u8,
    patterns: []const []const u8,
) ExpandError![]const []const u8 {
    if (patterns.len == 0) return &.{};
    var root = try std.fs.cwd().openDir(project_dir, .{ .iterate = true });
    defer root.close();
    var walker = try root.walk(arena);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = try portablePath(arena, entry.path);
        if (!matchesAny(path, patterns) or inList(paths.items, path)) continue;
        try paths.append(arena, path);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    return paths.toOwnedSlice(arena);
}

/// Every declaration that matched no expanded path. A non-empty result is a
/// configuration/input failure: silently running zero per-file commands would
/// turn a typoed glob into a false-green gate.
pub fn unmatched(
    arena: Allocator,
    patterns: []const []const u8,
    paths: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (patterns) |pattern| {
        var found = false;
        for (paths) |path| {
            if (matches(path, pattern)) {
                found = true;
                break;
            }
        }
        if (!found) try out.append(arena, pattern);
    }
    return out.toOwnedSlice(arena);
}

/// True when a project-relative path matches one exact or `*`-glob pattern.
pub fn matches(path: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') != null) return walk.matchGlob(path, pattern);
    return std.mem.eql(u8, path, pattern);
}

/// True when an argv array contains the exact per-input placeholder token.
pub fn usesPlaceholder(command: []const []const u8) bool {
    for (command) |arg| if (std.mem.eql(u8, arg, placeholder)) return true;
    return false;
}

/// Copies the argv slice and replaces only exact `{input}` tokens. Treating the
/// token as data rather than doing string/shell interpolation keeps the same
/// command-injection boundary as existing external gates.
pub fn argvForInput(
    arena: Allocator,
    command: []const []const u8,
    input: []const u8,
) Allocator.Error![]const []const u8 {
    const argv = try arena.alloc([]const u8, command.len);
    for (command, 0..) |arg, i| {
        argv[i] = if (std.mem.eql(u8, arg, placeholder)) input else arg;
    }
    return argv;
}

fn matchesAny(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| if (matches(path, pattern)) return true;
    return false;
}

fn inList(paths: []const []const u8, path: []const u8) bool {
    for (paths) |candidate| if (std.mem.eql(u8, candidate, path)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn portablePath(arena: Allocator, native: []const u8) Allocator.Error![]const u8 {
    const path = try arena.dupe(u8, native);
    if (std.fs.path.sep != '/') {
        for (path) |*c| if (c.* == std.fs.path.sep) {
            c.* = '/';
        };
    }
    return path;
}

test "external input matching keeps exact paths exact and expands stars" {
    try std.testing.expect(matches("assets/app.js", "assets/*.js"));
    try std.testing.expect(!matches("assets/app.js.map", "assets/*.js"));
    try std.testing.expect(matches("assets/app.js", "assets/app.js"));
    try std.testing.expect(!matches("nested/assets/app.js", "assets/app.js"));
}

test "external input argv substitution replaces only the exact placeholder token" {
    try std.testing.expect(usesPlaceholder(&.{ "node", placeholder }));
    try std.testing.expect(!usesPlaceholder(&.{ "node", "prefix-{input}" }));
    const argv = try argvForInput(
        std.testing.allocator,
        &.{ "node", "--check", placeholder, "prefix-{input}" },
        "assets/app.js",
    );
    defer std.testing.allocator.free(argv);
    try std.testing.expectEqualStrings("assets/app.js", argv[2]);
    try std.testing.expectEqualStrings("prefix-{input}", argv[3]);
}

test "external input expansion reports unmatched exact paths and globs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/external-input-expansion";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir ++ "/assets");
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/assets/app.js", .data = "ok" });

    const patterns = &.{ "assets/*.js", "assets/missing.css" };
    const paths = try expand(a, dir, patterns);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("assets/app.js", paths[0]);
    const missing = try unmatched(a, patterns, paths);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("assets/missing.css", missing[0]);
}
