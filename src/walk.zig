const std = @import("std");
const Allocator = std.mem.Allocator;

/// One file yielded by the walker: its display path and full content.
/// `tree` is set only when the entry originates from a prebuilt AST index
/// (see ast/index.zig) and points at the file's already-parsed syntax tree
/// so AST checks can reuse a shared parse; it is null for a bare walk.
pub const FileEntry = struct {
    rel_path: []const u8,
    /// Null-terminated so std.zig.Ast.parse (and any tokenizer) can consume it
    /// directly — no per-check dupeZ. Coerces to []const u8 where a plain slice
    /// is wanted.
    content: [:0]const u8,
    tree: ?*const std.zig.Ast = null,
};

/// Options controlling which files the walker yields.
pub const WalkOpts = struct {
    /// Prefix prepended to each yielded file's relative path (e.g. "src").
    display_root: []const u8 = "",
    excludes: []const []const u8 = &.{},
    max_file_bytes: usize = 10 * 1024 * 1024,
    extension: []const u8 = ".zig",
};

/// Function signature of a walker visitor callback. Errors propagate
/// up through walkZigFiles so checks see real I/O / OOM failures.
pub const VisitFn = *const fn (ctx: *anyopaque, entry: FileEntry) anyerror!void;

/// Bundle of (context pointer, callback) supplied to walkZigFiles.
pub const Visitor = struct {
    ctx: *anyopaque,
    visit: VisitFn,
};

/// Errors propagated by walkZigFiles. `anyerror` because the visitor
/// callback may itself fail with arbitrary errors (OOM, format errors, etc.).
pub const WalkError = anyerror;

/// Immutable state threaded through the recursive walk (everything except the
/// current directory + path prefix, which change per level).
const WalkState = struct {
    allocator: Allocator,
    opts: WalkOpts,
    visitor: Visitor,
};

/// Recursively walks `fs_root`, invoking `visitor` for every matching file.
/// `opts.display_root` is prepended to each file's relative path in the entry.
pub fn walkZigFiles(
    allocator: Allocator,
    fs_root: []const u8,
    opts: WalkOpts,
    visitor: Visitor,
) WalkError!void {
    var dir = std.fs.cwd().openDir(fs_root, .{ .iterate = true }) catch |e| switch (e) {
        // A missing root (e.g. an optional test/ dir) is simply nothing to
        // scan. Any other failure (permissions, etc.) is a real error — a hard
        // gate must never silently pass because it couldn't read the sources.
        error.FileNotFound => return,
        else => |err| return err,
    };
    defer dir.close();
    const state: WalkState = .{ .allocator = allocator, .opts = opts, .visitor = visitor };
    try walkRecursive(state, dir, opts.display_root);
}

fn walkRecursive(state: WalkState, dir: std.fs.Dir, prefix: []const u8) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(state.allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(state.allocator, "{s}", .{entry.name});

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkRecursive(state, sub, rel);
            },
            .file => try maybeVisitFile(state, dir, entry.name, rel),
            else => {},
        }
    }
}

/// Reads and yields one file to the visitor if it matches the configured
/// extension and isn't excluded. Fails loud on read errors (permissions,
/// > max_file_bytes): a silently skipped file would be exempt from every check.
fn maybeVisitFile(state: WalkState, dir: std.fs.Dir, name: []const u8, rel: []const u8) !void {
    const opts = state.opts;
    if (!std.mem.endsWith(u8, name, opts.extension)) return;
    if (isExcluded(rel, opts.excludes)) return;
    const content = try dir.readFileAllocOptions(
        state.allocator,
        name,
        opts.max_file_bytes,
        null,
        .of(u8),
        0,
    );
    try state.visitor.visit(state.visitor.ctx, .{ .rel_path = rel, .content = content });
}

fn isExcluded(rel: []const u8, excludes: []const []const u8) bool {
    for (excludes) |pat| {
        if (matchGlob(rel, pat)) return true;
    }
    return false;
}

/// Returns true if `text` matches `pattern`. `*` is a wildcard matching any
/// substring; a pattern containing no `*` is treated as a substring match.
pub fn matchGlob(text: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return std.mem.indexOf(u8, text, pattern) != null;
    }
    return matchWildcard(text, pattern);
}

/// How a literal segment between `*`s must line up with the text.
const Anchor = enum { start, end, any };

fn matchWildcard(text: []const u8, pattern: []const u8) bool {
    var ti: usize = 0;
    var parts = std.mem.splitScalar(u8, pattern, '*');
    var first = true;
    const ends_with_star = std.mem.endsWith(u8, pattern, "*");
    while (parts.next()) |part| {
        if (part.len == 0) {
            first = false;
            continue;
        }
        const is_last = parts.peek() == null;
        const anchor: Anchor = if (first) .start else if (is_last and !ends_with_star) .end else .any;
        ti = matchSegment(text, ti, part, anchor) orelse return false;
        first = false;
    }
    return ends_with_star or ti == text.len;
}

/// Advances the match cursor past `part` from `ti`, honoring `anchor`, or
/// returns null when `part` doesn't match. `.end` anchors the final literal
/// to the end of the text so a repeated substring can't consume it early
/// (e.g. "*.zig" must match "a.zig.zig", not stop at the first ".zig").
fn matchSegment(text: []const u8, ti: usize, part: []const u8, anchor: Anchor) ?usize {
    return switch (anchor) {
        .start => if (std.mem.startsWith(u8, text[ti..], part)) ti + part.len else null,
        .end => if (std.mem.endsWith(u8, text[ti..], part)) text.len else null,
        .any => if (std.mem.indexOf(u8, text[ti..], part)) |idx| ti + idx + part.len else null,
    };
}

/// Resolves `..` and `.` segments in a forward-slash path.
pub fn normalizePath(allocator: Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
        } else {
            try parts.append(allocator, seg);
        }
    }
    var result: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }
    return result.toOwnedSlice(allocator);
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
    // Trailing literal must anchor to the end even when it repeats earlier.
    try std.testing.expect(matchGlob("a.zig.zig", "*.zig"));
    try std.testing.expect(!matchGlob("a.zig.txt", "*.zig"));
    try std.testing.expect(matchGlob("src/vendor_foo.zig", "*/vendor_*.zig"));
}

test "normalizePath resolves parent refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/utils/foo.zig", try normalizePath(a, "src/core/../utils/foo.zig"));
    try std.testing.expectEqualStrings("src/main.zig", try normalizePath(a, "src/./main.zig"));
    try std.testing.expectEqualStrings("foo.zig", try normalizePath(a, "a/b/../../foo.zig"));
}
