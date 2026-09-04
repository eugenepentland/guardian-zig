//! Git diff helpers shared by the change-classification check and the
//! mutate command's fast tier. The parsers are pure functions over diff
//! text; the process shell-outs wrap the `git` binary. A run outside a git
//! repository is a documented skip (the diff-scoped feature degrades), but a
//! git that can't be spawned or that fails for any other reason is a hard error
//! surfacing git's stderr — a silent skip on a broken git would let a real
//! change slip past change-classification unnoticed. The commit/telemetry paths
//! stay best-effort (they degrade quietly) via `runGit`.

const std = @import("std");
const wiring = @import("wiring.zig");
const Allocator = std.mem.Allocator;
const reporter = @import("reporter.zig");

/// Output cap for a captured `git` invocation (diffs on large repos).
const max_git_output_bytes: usize = 64 * 1024 * 1024;

/// `git rev-parse` subcommand — shared so the several rev-parse call sites don't
/// each repeat the literal (repeated-string-literal).
const rev_parse = "rev-parse";
/// `git worktree` subcommand — shared so the add/remove/prune call sites do not
/// each repeat the literal (repeated-string-literal).
const worktree_cmd = "worktree";

/// Flags every diff invocation here shares, hoisted so the several call sites
/// don't each repeat the literal (repeated-string-literal): raw (unquoted)
/// paths, no colour, and paths relative to the directory the diff ran in — the
/// same spelling a ratchet key is built from.
const quote_path_off = "core.quotepath=false";
const no_color = "--no-color";
const relative = "--relative";

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

/// Result of asking git for a diff: parsed per-file spans, or a short reason it
/// was skipped. `.unavailable` now means only "not a git repository"; a bad ref
/// or an unspawnable git is a hard `GitError`, not a silent skip.
pub const DiffResult = union(enum) {
    ok: []const FileDiff,
    unavailable: []const u8,
};

/// Result of asking git for every changed path, including deleted files.
pub const PathDiffResult = union(enum) {
    ok: []const []const u8,
    unavailable: []const u8,
};

/// Parses `git diff -U0` output into per-file added-line spans. Files whose
/// new side is /dev/null (deletions) are dropped; deletion-only hunks
/// contribute no spans.
pub fn parseUnifiedDiff(allocator: Allocator, text: []const u8) Allocator.Error![]const FileDiff {
    var files: std.ArrayList(FileDiff) = .empty;
    var cur_path: ?[]const u8 = null;
    var cur_spans: std.ArrayList(LineSpan) = .empty;

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
    files: *std.ArrayList(FileDiff),
    path: ?[]const u8,
    spans: *std.ArrayList(LineSpan),
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

/// Runs `git diff -U0 --relative <ref>` in `project_dir` and parses it. Outside
/// a git repository the result is `.unavailable` (a skip); a bad ref or an
/// unspawnable git is a hard `GitError` with git's stderr surfaced.
pub fn diffAgainst(allocator: Allocator, project_dir: []const u8, ref: []const u8) GitError!DiffResult {
    const argv = [_][]const u8{
        "git",    "-c",  quote_path_off, "diff",
        no_color, "-U0", relative,       ref,
        "--",
    };
    const out = (try checkedOutput(allocator, project_dir, &argv)) orelse
        return .{ .unavailable = "not a git repository — diff-scoped checks skipped" };
    return .{ .ok = try parseUnifiedDiff(allocator, out) };
}

/// Lists paths changed against `ref`, retaining deletions and disabling rename
/// detection so a move exposes both its old and new path to policy checks.
pub fn diffPathNamesAgainst(
    allocator: Allocator,
    project_dir: []const u8,
    ref: []const u8,
) GitError!PathDiffResult {
    const argv = [_][]const u8{
        "git",    "-c",          quote_path_off, "diff",
        no_color, "--name-only", "-z",           "--no-renames",
        relative, ref,           "--",
    };
    const out = (try checkedOutput(allocator, project_dir, &argv)) orelse
        return .{ .unavailable = "not a git repository — diff-scoped checks skipped" };
    return .{ .ok = try parseNulPaths(allocator, out) };
}

/// One whole-file rename git detected: the path `ref` recorded, and the path
/// the same content lives at now. Both are relative to the directory the diff
/// ran in, so they compare directly against a ratchet key's file part.
pub const Rename = struct { from: []const u8, to: []const u8 };

/// Whole-file renames between `ref` and this working tree, taken from both the
/// unstaged and the staged view (a rename staged and then edited can score as a
/// rename in only one of them). Pairs are deduplicated by their new path.
///
/// Only renames git can *see* are reported: a `git mv`, or a move whose new
/// path was `git add`ed. A brand-new untracked file appears in no diff at all —
/// which is precisely the case the ratchet's content-matched tier covers.
///
/// Best-effort by design: no repository, no git binary, or any git failure
/// yields an empty slice, so relocation-aware ratcheting degrades to its
/// pre-rename behaviour instead of failing a gate over a missing tool.
pub fn renamesAgainst(
    allocator: Allocator,
    project_dir: []const u8,
    ref: []const u8,
) Allocator.Error![]const Rename {
    var out: std.ArrayList(Rename) = .empty;
    try appendRenames(allocator, project_dir, try renameArgv(allocator, ref, false), &out);
    try appendRenames(allocator, project_dir, try renameArgv(allocator, ref, true), &out);
    return out.toOwnedSlice(allocator);
}

/// The rename-detecting `--name-status` argv for one view: the working tree, or
/// (`cached`) the index. One builder so the two views cannot drift apart.
fn renameArgv(allocator: Allocator, ref: []const u8, cached: bool) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{
        "git", "-c", quote_path_off, "diff", no_color, "--find-renames", "--name-status", "-z", relative,
    });
    if (cached) try argv.append(allocator, "--cached");
    try argv.appendSlice(allocator, &.{ ref, "--" });
    return argv.toOwnedSlice(allocator);
}

/// Runs one rename-detecting diff and appends its pairs, skipping any whose new
/// path another view already reported.
fn appendRenames(
    allocator: Allocator,
    project_dir: []const u8,
    argv: []const []const u8,
    out: *std.ArrayList(Rename),
) Allocator.Error!void {
    const text = runGit(allocator, project_dir, argv) orelse return;
    for (try parseRenamesZ(allocator, text)) |r| {
        if (renameTo(out.items, r.to) != null) continue;
        try out.append(allocator, r);
    }
}

/// The pair in `renames` whose new path is `to`, or null. Also the caller-facing
/// lookup for "did this path arrive by rename?".
pub fn renameTo(renames: []const Rename, to: []const u8) ?Rename {
    for (renames) |r| {
        if (std.mem.eql(u8, r.to, to)) return r;
    }
    return null;
}

/// Parses `git diff --name-status -z` records into rename pairs. Each record is
/// a status token followed by its path — except a rename or copy (`R100`,
/// `C75`), which carries the old path AND the new one. Only renames are
/// returned: a copy leaves the original in place, so re-keying its recorded
/// debt would move debt off a file that still holds it. Pure, so the record
/// framing is unit-tested without git.
fn parseRenamesZ(allocator: Allocator, text: []const u8) Allocator.Error![]const Rename {
    var out: std.ArrayList(Rename) = .empty;
    var it = std.mem.splitScalar(u8, text, 0);
    while (it.next()) |status| {
        if (status.len == 0) continue;
        if (status[0] != 'R' and status[0] != 'C') {
            _ = it.next(); // an ordinary record's single path
            continue;
        }
        const from = it.next() orelse break;
        const to = it.next() orelse break;
        if (status[0] != 'R' or from.len == 0 or to.len == 0) continue;
        try out.append(allocator, .{ .from = from, .to = to });
    }
    return out.toOwnedSlice(allocator);
}

fn parseNulPaths(allocator: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, 0);
    while (it.next()) |path| if (path.len > 0) try paths.append(allocator, path);
    return paths.toOwnedSlice(allocator);
}

/// Contents of `rel_path` (cwd-relative, forward slashes) as committed at HEAD,
/// or null when git is unavailable, the path is untracked at HEAD, or the read
/// fails. The `:./` spec resolves the path relative to `project_dir` rather than
/// the repo root. Used by the `debt` report to show a delta vs the committed
/// `.guardian/` state; callers omit the delta on null.
pub fn fileAtHead(allocator: Allocator, project_dir: []const u8, rel_path: []const u8) Allocator.Error!?[]const u8 {
    // OOM building the rev spec propagates; git-unavailable stays null (the
    // debt caller omits the delta either way, but OOM must not masquerade as it).
    const spec = try std.fmt.allocPrint(allocator, "HEAD:./{s}", .{rel_path});
    const argv = [_][]const u8{ "git", "show", spec };
    return runGit(allocator, project_dir, &argv);
}

/// Lists untracked (not ignored) files via `git ls-files`. An empty slice when
/// there is no git repository (a skip); a hard `GitError` on any other failure.
pub fn untrackedFiles(allocator: Allocator, project_dir: []const u8) GitError![]const []const u8 {
    const argv = [_][]const u8{ "git", "ls-files", "--others", "--exclude-standard" };
    const out = (try checkedOutput(allocator, project_dir, &argv)) orelse return &.{};
    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len > 0) try paths.append(allocator, line);
    }
    return paths.toOwnedSlice(allocator);
}

/// How many paths one `git check-ignore` invocation carries. Bounded so a
/// check with thousands of findings can't build an argv past the OS limit.
const check_ignore_chunk: usize = 128;

/// The subset of `paths` git reports as ignored (`git check-ignore`), used to
/// tell a missing *generated* input apart from a genuinely deleted tracked one.
///
/// `--no-index` is deliberately NOT passed: git then consults the index, so a
/// path it still tracks is never reported ignored even when a `.gitignore`
/// pattern matches it. That is the property the callers rely on — a deleted
/// tracked file keeps counting as a real violation, and only build output
/// nobody committed is treated as missing-and-skippable.
///
/// Best-effort: `git check-ignore` exits 1 when nothing matches, and any git
/// failure (no repo, no git) yields the empty set — i.e. "nothing is ignored",
/// the fail-closed direction in which every finding still counts.
pub fn ignoredPaths(
    allocator: Allocator,
    project_dir: []const u8,
    paths: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < paths.len) : (start += check_ignore_chunk) {
        const end = @min(start + check_ignore_chunk, paths.len);
        try appendIgnoredChunk(allocator, project_dir, paths[start..end], &out);
    }
    return out.toOwnedSlice(allocator);
}

/// Runs one bounded `git check-ignore` batch, appending each reported path.
fn appendIgnoredChunk(
    allocator: Allocator,
    project_dir: []const u8,
    chunk: []const []const u8,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "git", "check-ignore", "--" });
    try argv.appendSlice(allocator, chunk);
    const stdout = runGit(allocator, project_dir, argv.items) orelse return;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len > 0) try out.append(allocator, trimmed);
    }
}

/// Number of parents of `rev` — 0 for the root commit, 1 for a normal commit,
/// ≥2 for a merge — null outside a git repository (a skip), a hard `GitError`
/// on any other failure. Drives the change-classification merge/root skip.
pub fn parentCount(allocator: Allocator, project_dir: []const u8, rev: []const u8) GitError!?u32 {
    const argv = [_][]const u8{ "git", "rev-list", "--parents", "-n", "1", rev };
    const out = (try checkedOutput(allocator, project_dir, &argv)) orelse return null;
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

/// One `git status` candidate for the `commit` auto-commit: the path plus
/// whether git already tracks it (any porcelain status except `??`). The
/// commit rails apply the secret/artifact skip only to untracked paths — a
/// tracked path was deliberately added to the repo, and dropping it would
/// desync the commit from the gated tree.
pub const ChangedPath = struct {
    path: []const u8,
    tracked: bool,
    /// True when git's INDEX side already records this path as deleted (`D` in
    /// the first porcelain column) — the file is gone from both the worktree and
    /// the index. Such a path matches no pathspec, so `git add` on it is a fatal
    /// `pathspec … did not match any files` that aborts the whole staging batch;
    /// the deletion is already staged, so there is nothing left to add.
    staged_deletion: bool = false,
};

/// Working-tree changed + untracked paths (`git status --porcelain -z`) — the
/// candidate set for the `commit` auto-commit. Rename/copy entries yield the new
/// path. Null when git is unavailable, so the caller can refuse to commit.
pub fn changedPaths(allocator: Allocator, project_dir: []const u8) Allocator.Error!?[]const ChangedPath {
    const argv = [_][]const u8{ "git", "status", "--porcelain", "-z" };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    return try parsePorcelainZ(allocator, out);
}

/// Parses `git status --porcelain -z` output into its changed/untracked path
/// list. Each record is `XY <path>\0`; a rename/copy adds a trailing
/// `<origpath>\0` token, so the new path is kept and the origin consumed; an
/// `??` status marks the entry untracked. The NUL delimiter means paths with
/// spaces or quotes need no unquoting. Pure.
fn parsePorcelainZ(allocator: Allocator, out: []const u8) Allocator.Error![]const ChangedPath {
    var paths: std.ArrayList(ChangedPath) = .empty;
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |entry| {
        if (entry.len < 4) continue; // "XY p" is the shortest real record
        const xy = entry[0..2];
        const path = entry[3..];
        if (isRenameStatus(xy)) _ = it.next(); // consume the paired origin path
        try paths.append(allocator, .{
            .path = path,
            .tracked = !std.mem.eql(u8, xy, "??"),
            .staged_deletion = isStagedDeletion(xy),
        });
    }
    return paths.toOwnedSlice(allocator);
}

/// True when a porcelain XY status code is a rename or copy — its record
/// carries a second, origin-path token that must be consumed.
fn isRenameStatus(xy: []const u8) bool {
    return xy[0] == 'R' or xy[0] == 'C' or xy[1] == 'R' or xy[1] == 'C';
}

/// True when the INDEX column already records a deletion (`D `, `DD`): the path
/// is in neither the worktree nor the index, so no `git add` can name it. A
/// worktree-only deletion (` D`, `AD`, `MD`) is NOT one of these — its index
/// entry still exists, and a plain `git add -- <path>` stages the removal.
fn isStagedDeletion(xy: []const u8) bool {
    return xy[0] == 'D';
}

/// Stages exactly `paths` via `git add -- <paths…>` (never `-A` / `.`); true on
/// success. The `--` guards a path that happens to look like a flag. Mutates the
/// index — used only by the `commit` command after a green gate.
pub fn addPaths(allocator: Allocator, project_dir: []const u8, paths: []const []const u8) Allocator.Error!bool {
    var argv: std.ArrayList([]const u8) = .empty;
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
    const argv = [_][]const u8{ "git", rev_parse, "HEAD" };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    return std.mem.trim(u8, out, &std.ascii.whitespace);
}

/// Resolves `ref` (a branch, tag, or `HEAD`) to its commit hash, or null when
/// it names nothing — an empty repository has no `HEAD`, and a typo'd base ref
/// resolves to nothing at all. Best-effort like the rest of the commit-path
/// helpers: the caller decides whether an unresolvable base is a skip or a stop.
pub fn resolveRef(allocator: Allocator, project_dir: []const u8, ref: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", rev_parse, "--verify", "--quiet", ref };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    const sha = std.mem.trim(u8, out, &std.ascii.whitespace);
    return if (sha.len == 0) null else sha;
}

/// Records the working tree as a dangling commit WITHOUT touching the working
/// tree, the index, or the stash reflog (`git stash create`), and returns its
/// hash. Null when there is nothing to record — a clean tree, or no git — in
/// which case the candidate tree IS `HEAD` and the caller uses that instead.
///
/// This is how a candidate tree becomes checkoutable somewhere else: only
/// TRACKED modifications and deletions are captured, so a caller that needs the
/// brand-new files too must copy `untrackedFiles` in after the checkout.
pub fn stashCreate(allocator: Allocator, project_dir: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", "stash", "create" };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    const sha = std.mem.trim(u8, out, &std.ascii.whitespace);
    return if (sha.len == 0) null else sha;
}

/// Checks `commitish` out into a new detached linked worktree at `path` (which
/// must not already exist); true on success. The worktree shares this
/// repository's object store, so a commit only reachable from a dangling
/// `stashCreate` hash resolves there normally.
pub fn worktreeAdd(
    allocator: Allocator,
    project_dir: []const u8,
    path: []const u8,
    commitish: []const u8,
) bool {
    const argv = [_][]const u8{ "git", worktree_cmd, "add", "--detach", path, commitish };
    return runGit(allocator, project_dir, &argv) != null;
}

/// Removes the linked worktree at `path` and prunes its administrative record.
/// `--force` because a mutation campaign leaves modified and untracked files
/// behind and the scratch tree is disposable by construction; the prune runs
/// unconditionally so a worktree whose directory is already gone still stops
/// being registered. True when git removed the directory.
pub fn worktreeRemove(allocator: Allocator, project_dir: []const u8, path: []const u8) bool {
    const remove = [_][]const u8{ "git", worktree_cmd, "remove", "--force", path };
    const removed = runGit(allocator, project_dir, &remove) != null;
    const prune = [_][]const u8{ "git", worktree_cmd, "prune" };
    _ = runGit(allocator, project_dir, &prune);
    return removed;
}

/// How far back `rev` sits from HEAD: 0 when it IS HEAD, N when it is an
/// ancestor N commits back. Null when `rev` is not an ancestor of HEAD — an
/// unknown sha, a commit on another branch, a rewritten history — or when git
/// is unavailable. Best-effort by design: `doctor` uses it to age a recorded
/// session note, where "cannot tell" is itself a reportable answer.
pub fn commitsBehindHead(allocator: Allocator, project_dir: []const u8, rev: []const u8) ?u32 {
    const ancestry = [_][]const u8{ "git", "merge-base", "--is-ancestor", rev, "HEAD" };
    if (runGit(allocator, project_dir, &ancestry) == null) return null;
    // `HEAD --not <rev>` is `<rev>..HEAD` without composing a string, so this
    // best-effort path has no allocation whose failure it would have to drop.
    const argv = [_][]const u8{ "git", "rev-list", "--count", "HEAD", "--not", rev };
    return parseCount(runGit(allocator, project_dir, &argv) orelse return null);
}

/// The single decimal count on a `git rev-list --count` line, or null when the
/// output is not one. Pure, so the parse is unit-tested without git.
fn parseCount(output: []const u8) ?u32 {
    const text = std.mem.trim(u8, output, &std.ascii.whitespace);
    return std.fmt.parseInt(u32, text, 10) catch null;
}

/// The merge base of HEAD and `ref` — the commit this branch diverged from —
/// or null when it cannot be resolved (no such branch, an empty repository, a
/// detached history with no common ancestor, or no git at all). Best-effort by
/// design: the diff-scoping caller falls back to a whole-tree run whenever the
/// base is unknown, so an unresolvable ref degrades quietly instead of failing
/// a gate that would otherwise pass.
pub fn mergeBase(allocator: Allocator, project_dir: []const u8, ref: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", "merge-base", "HEAD", ref };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    const sha = std.mem.trim(u8, out, &std.ascii.whitespace);
    return if (sha.len == 0) null else sha;
}

/// The current branch name (trimmed), or null when git is unavailable or HEAD
/// is detached (`--abbrev-ref` yields "HEAD", reported as null). Used by the
/// DORA sink to tag each recorded run.
pub fn currentBranch(allocator: Allocator, project_dir: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", rev_parse, "--abbrev-ref", "HEAD" };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    const name = std.mem.trim(u8, out, &std.ascii.whitespace);
    if (name.len == 0 or std.mem.eql(u8, name, "HEAD")) return null;
    return name;
}

/// The repo's hooks directory for `project_dir` via `git rev-parse --git-path
/// hooks` — correct even in a linked worktree, where `.git` is a file and the
/// hooks live in the common dir. May be absolute or project-relative; null when
/// git is unavailable (best-effort, so install-hook degrades to a clear error).
pub fn hooksDir(allocator: Allocator, project_dir: []const u8) ?[]const u8 {
    return gitPath(allocator, project_dir, "hooks");
}

/// Resolves `leaf` inside this working tree's git directory via `git rev-parse
/// --git-path <leaf>` — the worktree-correct way to reach `hooks`,
/// `info/attributes`, and friends. May be absolute or project-relative; null
/// when git is unavailable or there is no repository.
pub fn gitPath(allocator: Allocator, project_dir: []const u8, leaf: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", rev_parse, "--git-path", leaf };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    const trimmed = std.mem.trim(u8, out, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// The local value of git config `key`, or null when it is unset (or git is
/// unavailable). Read-only: `--local` so a user's global setting is never
/// mistaken for this repository's.
pub fn configValue(allocator: Allocator, project_dir: []const u8, key: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", "config", "--local", "--get", key };
    const out = runGit(allocator, project_dir, &argv) orelse return null;
    const trimmed = std.mem.trim(u8, out, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// Sets git config `key` to `value` in this repository's own config; true on
/// success. Writes `.git/config` only — never the user's global file.
pub fn setConfig(allocator: Allocator, project_dir: []const u8, key: []const u8, value: []const u8) bool {
    const argv = [_][]const u8{ "git", "config", "--local", key, value };
    return runGit(allocator, project_dir, &argv) != null;
}

/// Errors from a *checked* git run: git could not be spawned, or it ran and
/// failed for a reason other than "not a git repository". A no-repo failure is
/// a documented skip (null), never one of these.
pub const GitError = error{ GitSpawnFailed, GitCommandFailed } || Allocator.Error;

/// Classified outcome of one git invocation.
const GitOutcome = union(enum) {
    /// Exit 0; stdout.
    ok: []const u8,
    /// Non-zero exit whose stderr names a missing repository — a documented skip.
    no_repo,
    /// Non-zero exit for any other reason; the trimmed stderr for the diagnostic.
    failed: []const u8,
    /// git could not be spawned at all (missing binary, etc.); the error name.
    spawn_error: []const u8,
};

/// True when `stderr` is git's "not a git repository" fatal — the one failure
/// diff-scoped checks treat as a skip rather than a hard error. Pure, so the
/// skip-vs-fail partition is unit-tested without git.
fn isNotARepo(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "not a git repository") != null;
}

/// Spawns git with `argv` in `project_dir` and classifies the result: stdout on
/// exit 0; a no-repo fatal is `.no_repo`; any other non-zero exit is `.failed`
/// (with trimmed stderr); an unspawnable git is `.spawn_error`.
fn spawnGit(allocator: Allocator, project_dir: []const u8, argv: []const []const u8) Allocator.Error!GitOutcome {
    var env = wiring.cloneEnviron(allocator) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .spawn_error = @errorName(e) },
    };
    defer env.deinit();
    // Diagnostics and classification are parsed by Guardian. Pinning the
    // locale keeps "not a git repository" stable on every workstation;
    // disabling optional locks avoids read-only diff/status operations
    // contending with another process updating the index.
    env.put("LC_ALL", "C") catch return error.OutOfMemory;
    env.put("GIT_OPTIONAL_LOCKS", "0") catch return error.OutOfMemory;
    const res = std.process.run(allocator, wiring.io(), .{
        .argv = argv,
        .cwd = .{ .path = project_dir },
        .environ_map = &env,
        .stdout_limit = .limited64(max_git_output_bytes),
        .stderr_limit = .limited64(max_git_output_bytes),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .spawn_error = @errorName(e) },
    };
    if (res.term.success()) return .{ .ok = res.stdout };
    if (isNotARepo(res.stderr)) return .no_repo;
    return .{ .failed = std.mem.trim(u8, res.stderr, &std.ascii.whitespace) };
}

// spec: Git Diff - Pins Git diagnostics to the C locale and disables optional locks

test "spawnGit recognizes no-repo output under the pinned child environment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const outcome = try spawnGit(arena.allocator(), "zig-cache/path-that-is-not-a-repository", &.{ "git", "status" });
    try testing.expect(outcome == .no_repo or outcome == .spawn_error);
}

/// Runs a *diff-scoped* git command that must fail loud. Returns stdout on
/// success; null when there is no git repository (a documented skip); a hard
/// error surfacing git's stderr on a spawn failure or any other non-zero exit.
fn checkedOutput(allocator: Allocator, project_dir: []const u8, argv: []const []const u8) GitError!?[]const u8 {
    return switch (try spawnGit(allocator, project_dir, argv)) {
        .ok => |o| o,
        .no_repo => null,
        .failed => |stderr| {
            // reporter.fail already prefixes "guardian: " — don't double it.
            reporter.fail("git command failed: {s}", .{stderr});
            return error.GitCommandFailed;
        },
        .spawn_error => |name| {
            reporter.fail("could not run git ({s}) — is it installed and on PATH?", .{name});
            return error.GitSpawnFailed;
        },
    };
}

/// Best-effort git for the commit/telemetry paths: stdout on exit 0, null on any
/// failure (no-repo, command failure, or unspawnable). Used where a git problem
/// should degrade quietly (refuse to commit, omit a metric), not fail the gate —
/// the diff-scoped checks use `checkedOutput` instead.
fn runGit(allocator: Allocator, project_dir: []const u8, argv: []const []const u8) ?[]const u8 {
    return switch (spawnGit(allocator, project_dir, argv) catch return null) {
        .ok => |o| o,
        else => null,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "ignoredPaths reports gitignored build output but never a tracked file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Run against this repo: zig-out/ is gitignored, src/check.zig is tracked.
    // The index-aware form is what keeps a deleted TRACKED file counting as a
    // real violation instead of being skipped as unbuilt output.
    const out = try ignoredPaths(a, ".", &.{ "zig-out/generated/absent.zig", "src/check.zig" });
    var saw_ignored = false;
    for (out) |p| {
        try testing.expect(!std.mem.eql(u8, p, "src/check.zig"));
        if (std.mem.eql(u8, p, "zig-out/generated/absent.zig")) saw_ignored = true;
    }
    try testing.expect(saw_ignored);
}

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

test "parseNulPaths retains deletion paths emitted by name-only diffs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try parseNulPaths(arena.allocator(), "guardian.toml\x00.guardian/old.txt\x00");
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("guardian.toml", out[0]);
    try testing.expectEqualStrings(".guardian/old.txt", out[1]);
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
    try testing.expectEqualStrings("src/a.zig", paths[0].path);
    try testing.expectEqualStrings("new.txt", paths[1].path);
    try testing.expectEqualStrings("src/renamed.zig", paths[2].path);
}

// spec: Git Diff - Distinguishes untracked entries from tracked ones in porcelain status

test "parsePorcelainZ marks only ?? entries as untracked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A worktree modification, an untracked file, and an index-added new file:
    // only the `??` entry is untracked — `git add`ing a file is a deliberate
    // decision the commit rails must respect.
    const out = " M src/a.zig\x00?? new.txt\x00A  src/added.zig\x00";
    const paths = try parsePorcelainZ(a, out);
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expect(paths[0].tracked);
    try testing.expect(!paths[1].tracked);
    try testing.expect(paths[2].tracked);
}

// spec: Git Diff - Marks an index-side deletion so no pathspec is built for it

test "parsePorcelainZ flags index deletions and leaves worktree deletions addable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `D ` (git rm'd) and `DD` (both-deleted conflict) name nothing git can add:
    // the file is gone from the worktree AND the index. ` D`/`AD`/`MD` still have
    // an index entry, so `git add -- <path>` stages the removal normally.
    const out = "D  src/gone.zig\x00DD src/conflict.zig\x00 D src/removed.zig\x00" ++
        "AD src/staged_then_removed.zig\x00 M src/live.zig\x00";
    const paths = try parsePorcelainZ(a, out);
    try testing.expectEqual(@as(usize, 5), paths.len);
    try testing.expect(paths[0].staged_deletion);
    try testing.expect(paths[1].staged_deletion);
    try testing.expect(!paths[2].staged_deletion);
    try testing.expect(!paths[3].staged_deletion);
    try testing.expect(!paths[4].staged_deletion);
}

fn fuzzGitText(backing: Allocator, smith: *std.testing.Smith) anyerror!void {
    var bytes: [64 * 1024]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    _ = try parseUnifiedDiff(arena.allocator(), input);
    _ = try parsePorcelainZ(arena.allocator(), input);
}

test "fuzz: git diff and porcelain parsers tolerate arbitrary bytes" {
    try testing.fuzz(testing.allocator, fuzzGitText, .{ .corpus = &.{ "", "diff --git a/x b/x\n@@ -1 +1 @@\n+x", "?? x.zig\x00" } });
}

// spec: Git Diff - Classifies a not-a-git-repository failure as a skip, not a hard error

test "isNotARepo matches only git's no-repository fatal" {
    try testing.expect(isNotARepo("fatal: not a git repository (or any of the parent directories): .git"));
    // A bad ref, a spawn error name, or empty stderr are all hard failures.
    try testing.expect(!isNotARepo("fatal: bad revision 'nope'"));
    try testing.expect(!isNotARepo(""));
}

// spec: Git Diff - Hard-fails a diff-scoped git command that fails for any other reason

test "diffAgainst hard-fails on a bad ref inside a real repository" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Capture the stderr diagnostic so the failing git run doesn't spam the log.
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    // Tests run at the guardian repo root; a nonexistent ref is a command
    // failure (not a missing repository), so it must surface as a hard error
    // rather than a silent `.unavailable` skip.
    try testing.expectError(error.GitCommandFailed, diffAgainst(a, ".", "guardian-no-such-ref-zzz"));
}

// spec: Git Diff - Resolves the merge base with a branch and reports null when it cannot

test "mergeBase degrades to null for an unresolvable branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A branch that cannot exist: merge-base exits non-zero, and the diff-scoping
    // caller must see a quiet null (→ whole-tree fallback), never a hard error.
    try testing.expectEqual(@as(?[]const u8, null), mergeBase(a, ".", "guardian-no-such-branch-zzz"));
    // The current HEAD is always its own merge base with itself, so a resolvable
    // ref yields a non-empty sha.
    const self_base = mergeBase(a, ".", "HEAD");
    try testing.expect(self_base == null or self_base.?.len > 0);
}

// spec: Git Diff - Ages a commit as its distance behind HEAD and reports null when it is not an ancestor

test "commitsBehindHead is zero for HEAD and null for a commit it cannot reach" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pure half first, so the parse is covered with or without a repository.
    try testing.expectEqual(@as(?u32, 0), parseCount("0\n"));
    try testing.expectEqual(@as(?u32, 12), parseCount(" 12 "));
    try testing.expect(parseCount("") == null);
    try testing.expect(parseCount("not-a-count") == null);
    // A sha that cannot exist is never an ancestor, in a repo or out of one.
    try testing.expect(commitsBehindHead(a, ".", "0000000000000000000000000000000000000000") == null);
    // HEAD is zero commits behind itself; outside a repo git answers nothing.
    const self_distance = commitsBehindHead(a, ".", "HEAD");
    try testing.expect(self_distance == null or self_distance.? == 0);
}

// spec: Ratchet Relocation - Reads rename pairs from git's name-status records

test "parseRenamesZ pairs rename records and skips ordinary and copy ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A modification (one path), a rename (two paths), a copy (two paths — the
    // original stays, so its debt must NOT be re-keyed), then another rename.
    const out = "M\x00src/a.zig\x00R100\x00src/old.zig\x00src/new.zig\x00" ++
        "C75\x00src/src.zig\x00src/copy.zig\x00R087\x00src/big.zig\x00sub/big.zig\x00";
    const renames = try parseRenamesZ(a, out);
    try testing.expectEqual(@as(usize, 2), renames.len);
    try testing.expectEqualStrings("src/old.zig", renames[0].from);
    try testing.expectEqualStrings("src/new.zig", renames[0].to);
    try testing.expectEqualStrings("sub/big.zig", renames[1].to);
    // Lookup is by the NEW path — the side a current violation names.
    try testing.expectEqualStrings("src/old.zig", renameTo(renames, "src/new.zig").?.from);
    try testing.expect(renameTo(renames, "src/copy.zig") == null);
    // The process shell degrades quietly: this repo has no staged rename, and
    // outside a repository (or with no git at all) the answer is the empty set.
    const live = try renamesAgainst(a, ".", "HEAD");
    for (live) |r| try testing.expect(r.from.len > 0 and r.to.len > 0);
}

// spec-case: Policy Protection - Blocks protected Guardian metadata drift unless trusted CI approves it

test "diffPathNamesAgainst hard-fails on a bad policy base ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    try testing.expectError(error.GitCommandFailed, diffPathNamesAgainst(a, ".", "guardian-no-such-ref-zzz"));
}
