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

/// Contents of `rel_path` (cwd-relative, forward slashes) as committed at HEAD,
/// or null when git is unavailable, the path is untracked at HEAD, or the read
/// fails. The `:./` spec resolves the path relative to `project_dir` rather than
/// the repo root. Used by the `debt` report to show a delta vs the committed
/// `.guardian/` state; callers omit the delta on null.
pub fn fileAtHead(allocator: Allocator, project_dir: []const u8, rel_path: []const u8) ?[]const u8 {
    const spec = std.fmt.allocPrint(allocator, "HEAD:./{s}", .{rel_path}) catch return null;
    const argv = [_][]const u8{ "git", "show", spec };
    return runGit(allocator, project_dir, &argv);
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

/// Number of parents of `rev` — 0 for the root commit, 1 for a normal commit,
/// ≥2 for a merge — or null when git is unavailable or `rev` doesn't resolve.
/// Drives the change-classification last-commit fallback's merge/root skip.
pub fn parentCount(allocator: Allocator, project_dir: []const u8, rev: []const u8) ?u32 {
    const argv = [_][]const u8{ "git", "rev-list", "--parents", "-n", "1", rev };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    return countParents(out);
}

/// Parent count from a `git rev-list --parents -n 1` line
/// (`<sha> <parent1> <parent2>…`): space-separated tokens minus one. Null on
/// empty input. Pure, so the merge/root partition is unit-tested without git.
fn countParents(rev_list_output: []const u8) ?u32 {
    const line = std.mem.trim(u8, rev_list_output, &std.ascii.whitespace);
    if (line.len == 0) return null;
    var count: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    while (it.next()) |_| count += 1;
    return if (count == 0) null else count - 1;
}

/// Working-tree changed + untracked paths (`git status --porcelain -z`) — the
/// candidate set for the `commit` auto-commit. Rename/copy entries yield the new
/// path. Null when git is unavailable, so the caller can refuse to commit.
pub fn changedPaths(allocator: Allocator, project_dir: []const u8) Allocator.Error!?[]const []const u8 {
    const argv = [_][]const u8{ "git", "status", "--porcelain", "-z" };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    return try parsePorcelainZ(allocator, out);
}

/// Parses `git status --porcelain -z` output into its changed/untracked path
/// list. Each record is `XY <path>\0`; a rename/copy adds a trailing
/// `<origpath>\0` token, so the new path is kept and the origin consumed. The
/// NUL delimiter means paths with spaces or quotes need no unquoting. Pure.
fn parsePorcelainZ(allocator: Allocator, out: []const u8) Allocator.Error![]const []const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |entry| {
        if (entry.len < 4) continue; // "XY p" is the shortest real record
        const xy = entry[0..2];
        const path = entry[3..];
        if (isRenameStatus(xy)) _ = it.next(); // consume the paired origin path
        try paths.append(allocator, path);
    }
    return paths.toOwnedSlice(allocator);
}

/// True when a porcelain XY status code is a rename or copy — its record
/// carries a second, origin-path token that must be consumed.
fn isRenameStatus(xy: []const u8) bool {
    return xy[0] == 'R' or xy[0] == 'C' or xy[1] == 'R' or xy[1] == 'C';
}

/// Stages exactly `paths` via `git add -- <paths…>` (never `-A` / `.`); true on
/// success. The `--` guards a path that happens to look like a flag. Mutates the
/// index — used only by the `commit` command after a green gate.
pub fn addPaths(allocator: Allocator, project_dir: []const u8, paths: []const []const u8) Allocator.Error!bool {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "git", "add", "--" });
    try argv.appendSlice(allocator, paths);
    return runGit(allocator, project_dir, argv.items) != null;
}

/// Commits the staged tree with `message` as the subject. Never amends, never
/// pushes. True on success (a clean "nothing to commit" exits non-zero → false).
pub fn commit(allocator: Allocator, project_dir: []const u8, message: []const u8) bool {
    const argv = [_][]const u8{ "git", "commit", "-m", message };
    return runGit(allocator, project_dir, &argv) != null;
}

/// The current HEAD commit hash (trimmed), or null when git is unavailable.
pub fn headHash(allocator: Allocator, project_dir: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "HEAD" };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    return std.mem.trim(u8, out, &std.ascii.whitespace);
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

// spec: Git Diff - Counts a commit's parents from a rev-list line

test "countParents is token count minus one, null on empty input" {
    // Root commit: the line is just the sha — zero parents.
    try testing.expectEqual(@as(?u32, 0), countParents("abcdef0"));
    // Normal commit: sha + one parent.
    try testing.expectEqual(@as(?u32, 1), countParents("abc def\n"));
    // Merge commit: sha + two parents.
    try testing.expectEqual(@as(?u32, 2), countParents("abc def ghi"));
    try testing.expectEqual(@as(?u32, null), countParents("   \n"));
}

// spec: Git Diff - Extracts changed and untracked paths from porcelain status resolving renames

test "parsePorcelainZ lists paths and consumes rename origins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Modified, untracked, then a rename: the new path is kept and the trailing
    // origin token (src/old.zig) is consumed, not reported as its own path.
    const out = " M src/a.zig\x00?? new.txt\x00R  src/renamed.zig\x00src/old.zig\x00";
    const paths = try parsePorcelainZ(a, out);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("src/a.zig", paths[0]);
    try testing.expectEqualStrings("new.txt", paths[1]);
    try testing.expectEqualStrings("src/renamed.zig", paths[2]);
}
