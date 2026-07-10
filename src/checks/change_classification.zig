//! change-classification: behavioral source changes must come with a test
//! or spec change. The AI-agent failure this targets is the "quick fix"
//! that patches production code and ships no regression test — on a real
//! guardian-gated codebase most bug fixes landed test-less. The check
//! diffs the working tree against a git ref (--against / GUARDIAN_AGAINST
//! / config, default HEAD), classifies every added line as behavioral,
//! test, or ignorable, and fails when behavioral lines arrive with no test
//! lines and no spec change. Outside a git repo it skips silently:
//! diff-scoped gates degrade, they don't block.
//!
//! Two escape hatches are closed. (1) A spec change waives the test only
//! when the SPEC.md diff adds/modifies a behavior *bullet* (`- ` outside a
//! fenced block) — a prose/typo/header edit no longer counts. (2) When the
//! effective base is HEAD and the working tree is clean, the last commit
//! (HEAD~1..HEAD) is gated instead of vacuously passing an empty diff —
//! unless HEAD is a merge or the root, which are skipped. The clean-tree
//! fallback is toggled by `[change_classification] gate_last_commit`.

const std = @import("std");
const git = @import("../git.zig");
const text = @import("../text.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const SPEC_TAG_PREFIX = "// spec:";
const COMMENT_PREFIX = "//";
const SRC_PREFIX = "src/";
const ZIG_EXT = ".zig";
/// How many offending files are listed before the report truncates.
const MAX_REPORTED_FILES = 10;
/// Read cap for SPEC.md when checking for added behavior bullets.
const MAX_SPEC_BYTES: usize = 1024 * 1024;
/// Fenced-code delimiters (mirrors src/spec/parser.zig): a `- `/`## ` line
/// inside a fence is illustrative markdown, never spec content.
const FENCE_BACKTICKS = "```";
const FENCE_TILDES = "~~~";
/// The last-commit fallback diffs this committed range when the tree is clean.
const LAST_COMMIT_RANGE = "HEAD~1..HEAD";

/// Added-line tallies for one file (or summed across files).
pub const LineCounts = struct {
    behavioral: u32 = 0,
    test_lines: u32 = 0,
};

/// Everything the verdict depends on: summed line tallies plus whether the
/// spec file itself changed.
pub const Totals = struct {
    counts: LineCounts = .{},
    spec_changed: bool = false,
};

/// The check's decision for one run.
pub const Verdict = enum { pass, fail };

/// Pure decision rule: behavioral changes with neither a test change nor a
/// spec change fail; everything else passes.
pub fn verdictFor(t: Totals) Verdict {
    const uncovered = t.counts.behavioral > 0 and t.counts.test_lines == 0 and !t.spec_changed;
    return if (uncovered) .fail else .pass;
}

/// Pure classifier: tallies the added lines described by `spans` over the
/// file's current content. Lines inside `test { ... }` blocks (including the
/// `test` header line) and added `// spec:` tags count as test changes;
/// blank and comment-only lines are ignored; everything else is behavioral.
pub fn classifyAdded(
    allocator: Allocator,
    content: []const u8,
    spans: []const git.LineSpan,
) Allocator.Error!LineCounts {
    const lines = try splitLines(allocator, content);
    const z = try allocator.dupeZ(u8, content);
    const ranges = try testLineRanges(allocator, z, @intCast(lines.len));

    var counts: LineCounts = .{};
    for (spans) |span| {
        const last = @min(span.start +| span.len -| 1, @as(u32, @intCast(lines.len)));
        var ln: u32 = span.start;
        while (ln <= last) : (ln += 1) {
            tallyLine(&counts, lines[ln - 1], ranges, ln);
        }
    }
    return counts;
}

/// Classifies a single added line into the running tallies.
fn tallyLine(counts: *LineCounts, raw: []const u8, ranges: []const TestRange, ln: u32) void {
    if (inTestRange(ranges, ln)) {
        counts.test_lines += 1;
        return;
    }
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (std.mem.startsWith(u8, trimmed, SPEC_TAG_PREFIX)) {
        counts.test_lines += 1;
        return;
    }
    if (std.mem.startsWith(u8, trimmed, COMMENT_PREFIX)) return;
    counts.behavioral += 1;
}

fn splitLines(allocator: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

/// Inclusive 1-indexed line range covered by one `test { ... }` block,
/// from its `test` keyword line through its closing brace line.
const TestRange = struct { start: u32, end: u32 };

fn inTestRange(ranges: []const TestRange, ln: u32) bool {
    for (ranges) |r| {
        if (ln >= r.start and ln <= r.end) return true;
    }
    return false;
}

/// Tokenizes `z` and records the line range of every test block, so added
/// lines can be attributed to test code without a full AST walk.
fn testLineRanges(allocator: Allocator, z: [:0]const u8, line_count: u32) Allocator.Error![]const TestRange {
    var ranges: std.ArrayListUnmanaged(TestRange) = .empty;
    var tok = std.zig.Tokenizer.init(z);
    var scope = text.TestScope{};
    var line: u32 = 1;
    var cursor: usize = 0;
    var pending_start: u32 = 1;
    var open_start: u32 = 1;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        line = advanceLine(z, &cursor, t.loc.start, line);
        if (t.tag == .keyword_test) pending_start = line;
        const was_in = scope.in_test;
        scope.update(t.tag);
        if (!was_in and scope.in_test) open_start = pending_start;
        if (was_in and !scope.in_test) {
            try ranges.append(allocator, .{ .start = open_start, .end = line });
        }
    }
    // Unterminated block (unparseable source): close it at EOF.
    if (scope.in_test) try ranges.append(allocator, .{ .start = open_start, .end = line_count });
    return ranges.toOwnedSlice(allocator);
}

/// Advances a monotone byte cursor to `target`, counting newlines into the
/// running 1-indexed line number (tokens arrive in source order).
fn advanceLine(z: []const u8, cursor: *usize, target: usize, line: u32) u32 {
    var ln = line;
    while (cursor.* < target and cursor.* < z.len) : (cursor.* += 1) {
        if (z[cursor.*] == '\n') ln += 1;
    }
    return ln;
}

// ── Run entry ──────────────────────────────────────────────────────────

/// A whole-file span for untracked (brand new) files: every line is added.
const WHOLE_FILE = [_]git.LineSpan{.{ .start = 1, .len = std.math.maxInt(u32) }};

/// Entry point for the change-classification check. Diffs the working tree
/// against the effective ref; when that base is HEAD and the tree is clean,
/// falls back to gating the last commit (see fallbackDecision).
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const a = ctx.allocator;
    if (!ctx.cfg.change_classification.enabled) {
        reporter.ok("change-classification: disabled in guardian.toml", .{});
        return;
    }
    const effective = ctx.against orelse ctx.cfg.change_classification.against;
    const wt = switch (try git.diffAgainst(a, ctx.project_dir, effective)) {
        .unavailable => |reason| {
            reporter.ok("change-classification: skipped — {s}", .{reason});
            return;
        },
        .ok => |fds| fds,
    };
    const untracked = try git.untrackedFiles(a, ctx.project_dir);

    const ref_is_head = std.mem.eql(u8, effective, "HEAD");
    const tree_clean = wt.len == 0 and untracked.len == 0;
    const gate_last = ctx.cfg.change_classification.gate_last_commit;
    const parents = git.parentCount(a, ctx.project_dir, "HEAD");
    switch (fallbackDecision(ref_is_head, tree_clean, gate_last, parents)) {
        .working_tree => return classifyAndReport(ctx, effective, wt, untracked),
        .last_commit => return gateLastCommit(ctx),
        .skip_merge_or_root => {
            reporter.ok("change-classification: clean tree at a merge/root commit — nothing to gate", .{});
            return;
        },
    }
}

/// Which side the check classifies once the fallback decision is made. Private
/// (with fallbackDecision) so its bool parameters don't trip boolean-param-ban;
/// both are exercised by same-file tests.
const FallbackDecision = enum { working_tree, last_commit, skip_merge_or_root };

/// Pure fallback decision. When the effective diff base is HEAD, the working
/// tree is clean, and the gate is enabled, gate the last commit instead of
/// passing on an empty diff — unless HEAD is a merge (>1 parent) or the root
/// (0 parents, or an unresolvable count), which are skipped. Any other case
/// (base overridden, dirty tree, gate disabled) classifies the working tree.
fn fallbackDecision(ref_is_head: bool, tree_clean: bool, gate_last_commit: bool, parent_count: ?u32) FallbackDecision {
    const fallback_eligible = ref_is_head and tree_clean and gate_last_commit;
    if (!fallback_eligible) return .working_tree;
    const pc = parent_count orelse return .skip_merge_or_root;
    return if (pc == 1) .last_commit else .skip_merge_or_root;
}

/// Clean-tree fallback: diff and classify the last commit (HEAD~1..HEAD). The
/// tree is clean here, so there are no untracked files to consider.
fn gateLastCommit(ctx: *registry.RunCtx) registry.RunError!void {
    const a = ctx.allocator;
    const rd = switch (try git.diffAgainst(a, ctx.project_dir, LAST_COMMIT_RANGE)) {
        .unavailable => |reason| {
            reporter.ok("change-classification: skipped — {s}", .{reason});
            return;
        },
        .ok => |fds| fds,
    };
    return classifyAndReport(ctx, LAST_COMMIT_RANGE, rd, &.{});
}

/// Builds the per-file span map, resolves whether the spec changed, tallies the
/// indexed source files, and reports — shared by the working-tree and
/// last-commit paths (`label` names the diff base in the report).
fn classifyAndReport(
    ctx: *registry.RunCtx,
    label: []const u8,
    file_diffs: []const git.FileDiff,
    untracked: []const []const u8,
) registry.RunError!void {
    const a = ctx.allocator;
    var span_map: std.StringHashMapUnmanaged([]const git.LineSpan) = .empty;
    for (file_diffs) |fd| {
        if (isSrcZig(fd.path)) try span_map.put(a, fd.path, fd.spans);
    }
    for (untracked) |p| {
        if (isSrcZig(p)) try span_map.put(a, p, &WHOLE_FILE);
    }

    var totals: Totals = .{ .spec_changed = try specChanged(ctx, file_diffs, untracked) };
    var offenders: std.ArrayListUnmanaged([]const u8) = .empty;
    try tallyIndexedFiles(ctx, &span_map, &totals, &offenders);

    try report(label, totals, offenders.items);
}

/// Classifies every indexed source file that the diff touched, summing
/// tallies and collecting per-file offender lines for the failure report.
fn tallyIndexedFiles(
    ctx: *registry.RunCtx,
    span_map: *const std.StringHashMapUnmanaged([]const git.LineSpan),
    totals: *Totals,
    offenders: *std.ArrayListUnmanaged([]const u8),
) registry.RunError!void {
    const a = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, a, ctx.project_dir, &storage);
    for (idx.files) |entry| {
        const spans = span_map.get(entry.rel_path) orelse continue;
        const c = try classifyAdded(a, entry.content, spans);
        totals.counts.behavioral += c.behavioral;
        totals.counts.test_lines += c.test_lines;
        if (c.behavioral > 0) {
            const msg = try std.fmt.allocPrint(a, "{s}: {d} behavioral line(s) added", .{
                entry.rel_path, c.behavioral,
            });
            try offenders.append(a, msg);
        }
    }
}

/// Prints the pass/fail outcome; fails the build on an uncovered change.
fn report(against: []const u8, totals: Totals, offenders: []const []const u8) registry.RunError!void {
    if (verdictFor(totals) == .pass) {
        reporter.ok(
            "change-classification: OK vs {s} ({d} behavioral, {d} test line(s) added)",
            .{ against, totals.counts.behavioral, totals.counts.test_lines },
        );
        return;
    }
    reporter.fail(
        "change-classification FAILED: {d} behavioral line(s) changed vs {s} with no test or spec change",
        .{ totals.counts.behavioral, against },
    );
    for (offenders, 0..) |o, i| {
        if (i >= MAX_REPORTED_FILES) break;
        detail("  {s}\n", .{o});
    }
    if (offenders.len > MAX_REPORTED_FILES) {
        detail("  ... and {d} more file(s)\n", .{offenders.len - MAX_REPORTED_FILES});
    }
    detail("  fix: add or update a `// spec:`-tagged test covering the change (or update SPEC.md).\n", .{});
    detail("       a genuinely behavior-free refactor can disable via " ++
        "`disabled = [\"change-classification\"]`.\n", .{});
    return error.CheckFailed;
}

fn isSrcZig(path: []const u8) bool {
    return std.mem.startsWith(u8, path, SRC_PREFIX) and std.mem.endsWith(u8, path, ZIG_EXT);
}

/// True when the SPEC.md side of the diff adds or modifies a behavior bullet
/// (see specBulletsAdded). An untracked spec is all-new; a tracked one uses its
/// added spans. A spec that only had prose/headers/fenced lines edited — or was
/// only deleted from — returns false and no longer waives the test requirement.
fn specChanged(
    ctx: *registry.RunCtx,
    file_diffs: []const git.FileDiff,
    untracked: []const []const u8,
) registry.RunError!bool {
    const a = ctx.allocator;
    const spec_file = ctx.cfg.spec_file;
    for (untracked) |p| {
        if (std.mem.eql(u8, p, spec_file)) {
            const content = (try readSpec(a, ctx.project_dir, spec_file)) orelse return false;
            return specBulletsAdded(content, &WHOLE_FILE);
        }
    }
    for (file_diffs) |fd| {
        if (std.mem.eql(u8, fd.path, spec_file)) {
            const content = (try readSpec(a, ctx.project_dir, spec_file)) orelse return false;
            return specBulletsAdded(content, fd.spans);
        }
    }
    return false;
}

/// Reads the working-tree SPEC.md at `<project_dir>/<spec_file>`; null when it
/// can't be read. The new (working-tree) side may be unstaged, so it isn't in
/// git's object store — this reads it from disk directly. ban-fs is granted for
/// this check in guardian.toml. In the clean-tree fallback the tree equals HEAD,
/// so the disk read still matches the diffed content.
fn readSpec(a: Allocator, project_dir: []const u8, spec_file: []const u8) Allocator.Error!?[]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ project_dir, spec_file });
    // A missing/unreadable spec is "no spec change" (fail closed for the test
    // requirement); only OOM building the path propagates.
    return std.fs.cwd().readFileAlloc(a, path, MAX_SPEC_BYTES) catch null;
}

/// True when any line covered by `spans` in SPEC.md `content` is a behavior
/// bullet — a `- ` line (after trimming) sitting outside a fenced code block.
/// Mirrors the spec parser's fence/bullet rules so a fenced `- ` example, a
/// header, prose, or a blank line covered by an added span does not count.
pub fn specBulletsAdded(content: []const u8, spans: []const git.LineSpan) bool {
    var in_fence = false;
    var ln: u32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        ln += 1;
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (isFence(line)) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (!std.mem.startsWith(u8, line, "- ")) continue;
        if (spanCovers(spans, ln)) return true;
    }
    return false;
}

/// A fenced-code delimiter line (``` or ~~~), which toggles fence state.
fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, FENCE_BACKTICKS) or std.mem.startsWith(u8, line, FENCE_TILDES);
}

/// True when 1-indexed `ln` falls inside any added-line span.
fn spanCovers(spans: []const git.LineSpan, ln: u32) bool {
    for (spans) |s| if (s.contains(ln)) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const SAMPLE =
    \\const std = @import("std");
    \\
    \\pub fn add(a: u32, b: u32) u32 {
    \\    // implementation note
    \\    return a + b;
    \\}
    \\
    \\// spec: Math - Adds two numbers
    \\test "add" {
    \\    try std.testing.expectEqual(@as(u32, 3), add(1, 2));
    \\}
;

// spec: Change Classification - Counts added lines inside test blocks as test changes

test "classifyAdded attributes lines inside a test block to test changes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Lines 9-11 are the test block (header through closing brace).
    const c = try classifyAdded(arena.allocator(), SAMPLE, &.{.{ .start = 9, .len = 3 }});
    try testing.expectEqual(@as(u32, 3), c.test_lines);
    try testing.expectEqual(@as(u32, 0), c.behavioral);
}

// spec: Change Classification - Counts added spec-tag comment lines as test changes

test "classifyAdded counts an added // spec: tag as a test change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Line 8 is the `// spec:` tag above the test block.
    const c = try classifyAdded(arena.allocator(), SAMPLE, &.{.{ .start = 8, .len = 1 }});
    try testing.expectEqual(@as(u32, 1), c.test_lines);
    try testing.expectEqual(@as(u32, 0), c.behavioral);
}

// spec: Change Classification - Ignores added blank and comment-only lines

test "classifyAdded ignores blank and comment-only lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Line 2 is blank; line 4 is a comment inside the function body.
    const c = try classifyAdded(arena.allocator(), SAMPLE, &.{ .{ .start = 2, .len = 1 }, .{ .start = 4, .len = 1 } });
    try testing.expectEqual(@as(u32, 0), c.test_lines);
    try testing.expectEqual(@as(u32, 0), c.behavioral);
}

// spec: Change Classification - Counts remaining added source lines as behavioral changes

test "classifyAdded counts production code lines as behavioral" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Lines 3 and 5 are the fn header and return statement.
    const c = try classifyAdded(arena.allocator(), SAMPLE, &.{ .{ .start = 3, .len = 1 }, .{ .start = 5, .len = 1 } });
    try testing.expectEqual(@as(u32, 2), c.behavioral);
    try testing.expectEqual(@as(u32, 0), c.test_lines);
}

// spec: Change Classification - Passes when behavioral changes are accompanied by test changes

test "verdictFor passes behavioral changes that come with test or spec changes" {
    try testing.expectEqual(Verdict.pass, verdictFor(.{ .counts = .{ .behavioral = 5, .test_lines = 2 } }));
    try testing.expectEqual(Verdict.pass, verdictFor(.{ .counts = .{ .behavioral = 5 }, .spec_changed = true }));
    // No behavioral change at all always passes (docs, config, test-only).
    try testing.expectEqual(Verdict.pass, verdictFor(.{}));
}

// spec: Change Classification - Fails when behavioral changes have no test or spec change

test "verdictFor fails behavioral changes with no test or spec change" {
    try testing.expectEqual(Verdict.fail, verdictFor(.{ .counts = .{ .behavioral = 1 } }));
}

const SPEC_SAMPLE =
    \\# Title
    \\
    \\## Section
    \\- first behavior
    \\- second behavior
    \\
    \\```md
    \\- fenced example, not a behavior
    \\```
    \\
    \\Prose paragraph, not a bullet.
;

// spec: Change Classification - Treats an added SPEC.md behavior bullet as a spec change

test "specBulletsAdded is true when an added span covers a behavior bullet" {
    // Line 4 is a real `- ` behavior bullet outside any fence.
    try testing.expect(specBulletsAdded(SPEC_SAMPLE, &.{.{ .start = 4, .len = 1 }}));
    // The whole-file span used for a brand-new spec also counts it.
    try testing.expect(specBulletsAdded(SPEC_SAMPLE, &WHOLE_FILE));
}

// spec: Change Classification - Ignores SPEC.md edits confined to prose, headers, or fenced code

test "specBulletsAdded is false for headers, prose, blanks, and fenced bullets" {
    // Header (3), fenced bullet (8), prose (11), blank (2) — none is a behavior bullet.
    try testing.expect(!specBulletsAdded(SPEC_SAMPLE, &.{.{ .start = 3, .len = 1 }}));
    try testing.expect(!specBulletsAdded(SPEC_SAMPLE, &.{.{ .start = 8, .len = 1 }}));
    try testing.expect(!specBulletsAdded(SPEC_SAMPLE, &.{.{ .start = 11, .len = 1 }}));
    try testing.expect(!specBulletsAdded(SPEC_SAMPLE, &.{.{ .start = 2, .len = 1 }}));
}

// spec: Change Classification - Gates the last commit when the working tree is clean against HEAD

test "fallbackDecision gates the last commit on a clean tree at a normal commit" {
    try testing.expectEqual(FallbackDecision.last_commit, fallbackDecision(true, true, true, 1));
}

// spec: Change Classification - Skips the last-commit fallback at a merge or root commit

test "fallbackDecision skips the fallback at merge, root, and unresolvable commits" {
    try testing.expectEqual(FallbackDecision.skip_merge_or_root, fallbackDecision(true, true, true, 0)); // root
    try testing.expectEqual(FallbackDecision.skip_merge_or_root, fallbackDecision(true, true, true, 2)); // merge
    try testing.expectEqual(FallbackDecision.skip_merge_or_root, fallbackDecision(true, true, true, null));
}

// spec: Change Classification - Uses the working tree when the base is overridden or the gate is disabled

test "fallbackDecision uses the working tree unless every fallback condition holds" {
    // Base overridden (not HEAD): always the working tree.
    try testing.expectEqual(FallbackDecision.working_tree, fallbackDecision(false, true, true, 1));
    // Dirty tree: the working-tree diff is non-empty, classify it.
    try testing.expectEqual(FallbackDecision.working_tree, fallbackDecision(true, false, true, 1));
    // Fallback disabled by config: keep the old working-tree-only behavior.
    try testing.expectEqual(FallbackDecision.working_tree, fallbackDecision(true, true, false, 1));
}
