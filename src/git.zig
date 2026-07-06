//! Git diff helpers shared by the change-classification check and the
//! mutate command's fast tier. The parsers are pure functions over diff
//! text; the process shell-outs are thin wrappers around the `git` binary
//! that degrade to an `unavailable` result, so a non-git checkout skips
//! diff-scoped features instead of failing the build.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Output cap for a captured `git` invocation (diffs on large repos).
const MAX_GIT_OUTPUT_BYTES: usize = 64 * 1024 * 1024;

/// A run of added lines in the new side of a diff: 1-indexed `start`,
/// `len` lines long. A pure deletion has no span.
pub const LineSpan = struct {
    start: u32,
    len: u32,

    /// True when 1-indexed `line` falls inside this span. Saturating so a
    /// whole-file span of `{1, maxInt}` (untracked files) can't overflow.
    pub fn contains(self: LineSpan, line: u32) bool {
        return line >= self.start and line < self.start +| self.len;
    }
};

/// Added-line spans for one file in a unified diff, keyed by the
/// new-side path (relative, forward slashes).
pub const FileDiff = struct {
    path: []const u8,
    spans: []const LineSpan,
};

/// Result of asking git for a diff: parsed per-file spans, or a short
/// reason the diff could not be produced (not a repo, bad ref, no git).
pub const DiffResult = union(enum) {
    ok: []const FileDiff,
    unavailable: []const u8,
};

/// Parses `git diff -U0` output into per-file added-line spans. Files whose
/// new side is /dev/null (deletions) are dropped; deletion-only hunks
/// contribute no spans.
pub fn parseUnifiedDiff(allocator: Allocator, text: []const u8) Allocator.Error![]const FileDiff {
    var files: std.ArrayListUnmanaged(FileDiff) = .empty;
    var cur_path: ?[]const u8 = null;
    var cur_spans: std.ArrayListUnmanaged(LineSpan) = .empty;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (newFilePathLine(line)) |path| {
            try flushFile(allocator, &files, cur_path, &cur_spans);
            cur_path = if (path.len > 0) path else null;
            cur_spans = .empty;
        } else if (std.mem.startsWith(u8, line, "@@")) {
            const span = parseHunkHeader(line) orelse continue;
            if (span.len > 0) try cur_spans.append(allocator, span);
        }
    }
    try flushFile(allocator, &files, cur_path, &cur_spans);
    return files.toOwnedSlice(allocator);
}

/// Returns the new-side path for a `+++ b/<path>` header line, "" for a
/// `+++ /dev/null` deletion header, or null for any non-header line.
fn newFilePathLine(line: []const u8) ?[]const u8 {
    const dev_null = "+++ /dev/null";
    if (std.mem.startsWith(u8, line, dev_null)) return "";
    const prefix = "+++ b/";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    // git appends a tab before mode/quoting metadata on some paths.
    const end = std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len;
    return rest[0..end];
}

fn flushFile(
    allocator: Allocator,
    files: *std.ArrayListUnmanaged(FileDiff),
    path: ?[]const u8,
    spans: *std.ArrayListUnmanaged(LineSpan),
) Allocator.Error!void {
    const p = path orelse return;
    if (p.len == 0) return; // deletion (/dev/null new side)
    try files.append(allocator, .{
        .path = p,
        .spans = try spans.toOwnedSlice(allocator),
    });
}

/// Parses the new-side range out of a `@@ -a,b +c,d @@` hunk header into a
/// LineSpan{c, d}. A missing `,d` means one line; `d = 0` is a pure
/// deletion (empty span). Returns null on malformed headers.
pub fn parseHunkHeader(line: []const u8) ?LineSpan {
    const plus = std.mem.indexOfScalar(u8, line, '+') orelse return null;
    var i = plus + 1;
    const start = parseDigits(line, &i) orelse return null;
    var len: u32 = 1;
    if (i < line.len and line[i] == ',') {
        i += 1;
        len = parseDigits(line, &i) orelse return null;
    }
    return .{ .start = start, .len = len };
}

/// Consumes a base-10 digit run at `i`, advancing it; null if none.
fn parseDigits(line: []const u8, i: *usize) ?u32 {
    const begin = i.*;
    var value: u32 = 0;
    while (i.* < line.len and std.ascii.isDigit(line[i.*])) : (i.* += 1) {
        value = value *| 10 +| (line[i.*] - '0');
    }
    if (i.* == begin) return null;
    return value;
}

/// Runs `git diff -U0 --relative <ref>` in `project_dir` and parses it.
/// Any git failure (not a repo, unknown ref, git missing) is returned as
/// `.unavailable` with a short reason — callers skip, never fail.
pub fn diffAgainst(allocator: Allocator, project_dir: []const u8, ref: []const u8) Allocator.Error!DiffResult {
    const argv = [_][]const u8{
        "git",        "-c",  "core.quotepath=false", "diff",
        "--no-color", "-U0", "--relative",           ref,
        "--",
    };
    const out = runGit(allocator, project_dir, &argv) orelse
        return .{ .unavailable = "git diff unavailable (not a git repo, unknown ref, or git missing)" };
    return .{ .ok = try parseUnifiedDiff(allocator, out) };
}

/// Lists untracked (not ignored) files via `git ls-files`. Best-effort:
/// returns an empty slice when git is unavailable.
pub fn untrackedFiles(allocator: Allocator, project_dir: []const u8) Allocator.Error![]const []const u8 {
    const argv = [_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" };
    const out = runGit(allocator, project_dir, &argv) orelse return &.{};
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len > 0) try paths.append(allocator, line);
    }
    return paths.toOwnedSlice(allocator);
}

/// Spawns git with `argv` in `project_dir`, returning trimmed stdout on
/// exit 0 and null on any spawn failure or non-zero exit.
fn runGit(allocator: Allocator, project_dir: []const u8, argv: []const []const u8) ?[]const u8 {
    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = project_dir,
        .max_output_bytes = MAX_GIT_OUTPUT_BYTES,
    }) catch return null;
    allocator.free(res.stderr);
    const exited_clean = res.term == .Exited and res.term.Exited == 0;
    if (!exited_clean) {
        allocator.free(res.stdout);
        return null;
    }
    return res.stdout;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Git Diff - Parses unified diff hunk headers into added line spans

test "parseHunkHeader reads start and length from the new-side range" {
    const span = parseHunkHeader("@@ -10,2 +12,4 @@ fn foo()").?;
    try testing.expectEqual(@as(u32, 12), span.start);
    try testing.expectEqual(@as(u32, 4), span.len);
    // Missing `,d` means a single added line.
    const one = parseHunkHeader("@@ -3 +7 @@").?;
    try testing.expectEqual(@as(u32, 7), one.start);
    try testing.expectEqual(@as(u32, 1), one.len);
    try testing.expect(parseHunkHeader("@@ nonsense @@") == null);
}

// spec: Git Diff - Groups unified diff output into per-file added spans

test "parseUnifiedDiff groups hunks under their new-side file path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parseUnifiedDiff(arena.allocator(),
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,0 +2,3 @@
        \\+x
        \\@@ -9,1 +12,1 @@
        \\+y
        \\diff --git a/src/b.zig b/src/b.zig
        \\--- a/src/b.zig
        \\+++ b/src/b.zig
        \\@@ -4,0 +5,2 @@
        \\+z
    );
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("src/a.zig", out[0].path);
    try testing.expectEqual(@as(usize, 2), out[0].spans.len);
    try testing.expectEqual(@as(u32, 2), out[0].spans[0].start);
    try testing.expectEqual(@as(u32, 3), out[0].spans[0].len);
    try testing.expectEqualStrings("src/b.zig", out[1].path);
    try testing.expect(out[1].spans[0].contains(5));
    try testing.expect(!out[1].spans[0].contains(7));
}

// spec: Git Diff - Returns no spans for deletion-only hunks and deleted files

test "parseUnifiedDiff drops deleted files and deletion-only hunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parseUnifiedDiff(arena.allocator(),
        \\--- a/src/gone.zig
        \\+++ /dev/null
        \\@@ -1,10 +0,0 @@
        \\--- a/src/kept.zig
        \\+++ b/src/kept.zig
        \\@@ -5,2 +5,0 @@
        \\-removed
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/kept.zig", out[0].path);
    try testing.expectEqual(@as(usize, 0), out[0].spans.len);
}
