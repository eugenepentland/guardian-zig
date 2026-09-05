//! test-erosion: report a change whose TEST side went backwards. Diff-scoped
//! sibling of `change-classification` — same base-ref plumbing (`--against` /
//! `GUARDIAN_AGAINST` / `[change_classification] against`, default HEAD) and the
//! same skip-outside-a-git-repository degradation.
//!
//! **Not a duplicate of change-classification — the opposite reading of the same
//! diff.** That check sees "NO test change": behavioral source lines arriving
//! with nothing on the test side. It is satisfied the moment any test line
//! moves. This one reads the sign of that movement: a change can touch tests
//! heavily and still leave the suite weaker than it found it, and
//! change-classification passes it green. The seam is "absent" versus
//! "NEGATIVE", and neither check can see the other's case.
//!
//! **Two independent signals**, both advisory:
//!
//!   * **(a) Net test count fell.** More `test "…"` declarations were removed
//!     than added across the diff.
//!   * **(b) In-place body rewrite with no new assertions.** The change touches
//!     production code AND test code, no added line declares a new `test`, and
//!     the assertion count did not go up.
//!
//! **Evidence**, from "Test Coverage Analysis of Agentic Pull Requests"
//! (Dipongkor, Baral, Lam, Moran; arXiv:2607.18057; accepted at ICSME 2026):
//! "In Java, 42.2% already reach 100% diff coverage from the existing tests.
//! Among the rest, agents delete more tests than they add (82 deleted vs. 31
//! added, a 2.6x ratio), with another 51.2% editing only the bodies of existing
//! tests."
//!
//! **The qualifications are serious and travel with the number.** This was the
//! weakest-supported item in the research behind the check (a 2–1 verification
//! vote), and the check is shaped around that, not despite it:
//!
//!   1. **The sample is tiny and Java-only.** 64 Java "Code + Tests" PRs, and
//!      the 82-vs-31 figure comes from the coverage-non-improving remainder —
//!      roughly 41 PRs. Python, at 605 PRs the bulk of the corpus, gets no
//!      comparable ratio reported at all.
//!   2. **The paper makes NO causal attribution.** It reports counts. It never
//!      claims agents delete tests *in order to* make a change pass, and neither
//!      this module nor any message it prints may say so.
//!   3. **"Deleted" means deleted test METHODS**, not deleted files.
//!
//! What is safely supported, and all this check asserts: in PRs where the agent
//! touched tests and coverage did not improve, net test count went down and half
//! the test edits were in-place body rewrites — a diff signature a gate can see,
//! regardless of motive.
//!
//! **Therefore advisory, and never a hard block.** Signal (a)'s false-positive
//! rate is HIGH: consolidating four near-identical tests into one table-driven
//! test is a net decrease and is *better* code, as is deleting a test for
//! deleted behavior. `run` never returns `error.CheckFailed`; every finding
//! rides `reporter.warn`, the channel baselines and ratchets exclude by
//! construction. There is deliberately no ratchet on net test count either: this
//! check's `subject` is `.change`, so nothing it sees may be frozen into
//! `.guardian/` — a recorded row would describe a diff that no longer exists.
//!
//! **Measurement limits, stated.**
//!
//!   * Assertions are counted over every added and removed line of the diff, not
//!     only over test bodies (a diff cannot say which side of a removed line's
//!     file was a test block). `try` counts as an assertion, so a production
//!     line adding one raises the added count and signal (b) stays silent. That
//!     is a FALSE NEGATIVE by choice — for an advisory signal on a tiny,
//!     non-causal sample, under-firing is the right direction.
//!   * A test moved between files reads as one removal and one addition, so it
//!     nets to zero, as it should.
//!   * A test renamed reads the same way. A test whose declaration line is
//!     merely reformatted reads as removal + addition too.

const std = @import("std");
const git = @import("../git.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const assertions = @import("test_has_assertion.zig");
const change_classification = @import("change_classification.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const check_name = "test-erosion";
const src_prefix = "src/";
const zig_ext = ".zig";

/// A whole-file span for untracked (brand new) files: every line is added.
const whole_file_span = [_]git.LineSpan{.{ .start = 1, .len = std.math.maxInt(u32) }};

// ── Pure core: what the diff did to the tests ──────────────────────────

/// How a diff moved the test suite: declarations each way, and assertions each
/// way. Counts, not judgements — `signals` turns them into findings.
pub const TestDelta = struct {
    declarations_added: u32 = 0,
    declarations_removed: u32 = 0,
    assertions_added: u32 = 0,
    assertions_removed: u32 = 0,

    /// Net change in test declarations; negative means the suite shrank.
    pub fn netDeclarations(self: TestDelta) i64 {
        return @as(i64, self.declarations_added) - @as(i64, self.declarations_removed);
    }
};

/// The two things this check reports, either, both, or neither.
pub const Signals = struct {
    /// (a) More test declarations left than arrived.
    net_decrease: bool = false,
    /// (b) Production and test code both changed, no new test was declared, and
    /// the assertion count did not rise.
    body_rewrite_only: bool = false,

    /// True when neither signal fired — the green path.
    pub fn quiet(self: Signals) bool {
        return !self.net_decrease and !self.body_rewrite_only;
    }
};

/// The change-side facts signal (b) needs beyond the diff text: whether
/// production code and test code both moved. Supplied by
/// `change_classification.classifyAdded`, so both checks agree on what a test
/// line is and neither can drift into its own definition.
pub const Touched = struct {
    behavioral: u32 = 0,
    test_lines: u32 = 0,
};

/// Pure decision rule over the measured counts.
///
/// (a) fires on a net decrease. (b) fires only when production AND test lines
/// both moved, nothing added declares a test, and assertions did not increase —
/// the "edited the body, changed nothing it proves" shape. A change that adds a
/// test declaration cannot be a pure body rewrite, so (b) is silent for it
/// however the assertions move.
pub fn signals(delta: TestDelta, touched: Touched) Signals {
    const rewrote_bodies = touched.behavioral > 0 and touched.test_lines > 0 and
        delta.declarations_added == 0 and
        delta.assertions_added <= delta.assertions_removed;
    return .{
        .net_decrease = delta.netDeclarations() < 0,
        .body_rewrite_only = rewrote_bodies,
    };
}

/// Measures `diff_text` — raw `git diff -U0` output — into a `TestDelta`.
///
/// Only lines inside a hunk body count, so the `--- a/x` / `+++ b/x` file
/// headers are never mistaken for a removal and an addition. `-U0` means there
/// are no context lines, so every `+`/`-` inside a hunk is a real change.
pub fn measureDiff(allocator: Allocator, diff_text: []const u8) Allocator.Error!TestDelta {
    var delta: TestDelta = .{};
    var added: std.ArrayList(u8) = .empty;
    var removed: std.ArrayList(u8) = .empty;
    var in_hunk = false;
    var it = std.mem.splitScalar(u8, diff_text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git")) {
            in_hunk = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            continue;
        }
        if (!in_hunk or line.len == 0) continue;
        try tallyLine(allocator, line, &delta, &added, &removed);
    }
    delta.assertions_added = assertions.assertionCount(try added.toOwnedSliceSentinel(allocator, 0));
    delta.assertions_removed = assertions.assertionCount(try removed.toOwnedSliceSentinel(allocator, 0));
    return delta;
}

/// Attributes one hunk-body line to the added or removed side.
fn tallyLine(
    allocator: Allocator,
    line: []const u8,
    delta: *TestDelta,
    added: *std.ArrayList(u8),
    removed: *std.ArrayList(u8),
) Allocator.Error!void {
    const payload = line[1..];
    switch (line[0]) {
        '+' => {
            if (isTestDecl(payload)) delta.declarations_added += 1;
            try appendLine(allocator, added, payload);
        },
        '-' => {
            if (isTestDecl(payload)) delta.declarations_removed += 1;
            try appendLine(allocator, removed, payload);
        },
        else => {},
    }
}

fn appendLine(allocator: Allocator, out: *std.ArrayList(u8), payload: []const u8) Allocator.Error!void {
    try out.appendSlice(allocator, payload);
    try out.append(allocator, '\n');
}

/// True when a line declares a test: `test "name" {` or a decltest
/// `test someDecl {`. The opening brace is required, so a `test` mentioned in
/// prose or a doc comment is not a declaration.
pub fn isTestDecl(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    const keyword = "test ";
    if (!std.mem.startsWith(u8, trimmed, keyword)) return false;
    if (!std.mem.endsWith(u8, trimmed, "{")) return false;
    const rest = std.mem.trimStart(u8, trimmed[keyword.len..], &std.ascii.whitespace);
    if (rest.len == 0) return false;
    return rest[0] == '"' or std.ascii.isAlphabetic(rest[0]) or rest[0] == '_';
}

// ── Run entry ──────────────────────────────────────────────────────────

/// Entry point for the test-erosion check. Advisory on every path: it reports
/// through `reporter.warn` and never returns `error.CheckFailed`.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const a = ctx.allocator;
    const effective = ctx.against orelse ctx.cfg.change_classification.against;
    const diff_text = switch (try git.diffTextAgainst(a, ctx.project_dir, effective)) {
        .unavailable => |reason| {
            reporter.ok("{s}: skipped — {s}", .{ check_name, reason });
            return;
        },
        .ok => |txt| txt,
    };
    var delta = try measureDiff(a, diff_text);
    const change = try changeShape(ctx, effective);
    // `git diff` never shows an untracked file, so a change that MOVES tests
    // into a brand-new module would otherwise read as pure deletion — exactly
    // the false positive signal (a) must not produce.
    delta.declarations_added += change.new_file_declarations;
    try report(a, effective, delta, signals(delta, change.touched));
}

/// What the on-disk side of the change looks like: how many behavioral and test
/// lines it added (via change-classification's own classifier, so both checks
/// agree on what a test line is), and how many test declarations arrived in
/// files git has never seen.
const ChangeShape = struct {
    touched: Touched = .{},
    new_file_declarations: u32 = 0,
};

fn changeShape(ctx: *registry.RunCtx, ref: []const u8) registry.RunError!ChangeShape {
    const a = ctx.allocator;
    const wt = switch (try git.diffAgainst(a, ctx.project_dir, ref)) {
        .unavailable => return .{},
        .ok => |fds| fds,
    };
    var span_map: std.StringHashMapUnmanaged([]const git.LineSpan) = .empty;
    for (wt) |fd| {
        if (isSrcZig(fd.path)) try span_map.put(a, fd.path, fd.spans);
    }
    var untracked: std.StringHashMapUnmanaged(void) = .empty;
    for (try git.untrackedFiles(a, ctx.project_dir)) |p| {
        if (!isSrcZig(p)) continue;
        try span_map.put(a, p, &whole_file_span);
        try untracked.put(a, p, {});
    }
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, a, ctx.project_dir, &storage);
    var out: ChangeShape = .{};
    for (idx.files) |entry| {
        const spans = span_map.get(entry.rel_path) orelse continue;
        const c = try change_classification.classifyAdded(a, entry.content, spans);
        out.touched.behavioral += c.behavioral;
        out.touched.test_lines += c.test_lines;
        if (untracked.contains(entry.rel_path)) out.new_file_declarations += countDeclarations(entry.content);
    }
    return out;
}

/// Test declarations in a whole file, by the same line predicate the diff
/// counter uses.
pub fn countDeclarations(content: []const u8) u32 {
    var count: u32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (isTestDecl(line)) count += 1;
    }
    return count;
}

/// Prints the advisory verdict. Never fails the build — see the module header
/// for why signal (a) can never be a hard block.
fn report(a: Allocator, against: []const u8, delta: TestDelta, found: Signals) Allocator.Error!void {
    if (found.quiet()) {
        reporter.ok("{s}: no test erosion vs {s} ({d} test(s) added, {d} removed)", .{
            check_name, against, delta.declarations_added, delta.declarations_removed,
        });
        return;
    }
    if (found.net_decrease) reporter.warn(.{
        .check = check_name,
        .message = try std.fmt.allocPrint(a, "net test count fell vs {s}: {d} declaration(s) removed, {d} added", .{
            against, delta.declarations_removed, delta.declarations_added,
        }),
        .identity = "net-decrease",
    });
    if (found.body_rewrite_only) reporter.warn(.{
        .check = check_name,
        .message = try std.fmt.allocPrint(
            a,
            "test bodies rewritten in place vs {s}: no new test declaration, assertions {d} added / {d} removed",
            .{ against, delta.assertions_added, delta.assertions_removed },
        ),
        .identity = "body-rewrite-only",
    });
    // Led by `fix:` so the violation scraper stops here: these two lines are
    // guidance, and counting them as findings would double the reported number.
    detail("  fix: nothing is required — advisory only, this never blocks. Consolidating tests and " ++
        "deleting tests for deleted behavior are both legitimate.\n", .{});
    detail("       ask instead: does the change still have a test that would fail if the " ++
        "behavior regressed?\n", .{});
}

fn isSrcZig(path: []const u8) bool {
    return std.mem.startsWith(u8, path, src_prefix) and std.mem.endsWith(u8, path, zig_ext);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const shrinking_diff =
    \\diff --git a/src/a.zig b/src/a.zig
    \\--- a/src/a.zig
    \\+++ b/src/a.zig
    \\@@ -10,6 +10,2 @@
    \\-test "parses an empty header" {
    \\-    try expect(parse("") == null);
    \\-}
    \\-test "parses a short header" {
    \\-    try expect(parse("ab") != null);
    \\-}
    \\+test "parses headers" {
    \\+    try expect(parse("") == null);
    \\+}
;

// spec: Test Erosion - Reports a change that removes more test declarations than it adds

test "measureDiff counts declarations each way and signals a net decrease" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const delta = try measureDiff(arena.allocator(), shrinking_diff);
    try testing.expectEqual(@as(u32, 1), delta.declarations_added);
    try testing.expectEqual(@as(u32, 2), delta.declarations_removed);
    try testing.expectEqual(@as(i64, -1), delta.netDeclarations());
    try testing.expect(signals(delta, .{}).net_decrease);
}

// spec: Test Erosion - Ignores diff file headers when counting removed and added lines

test "measureDiff never reads a file header as an added or removed line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `--- a/x` and `+++ b/x` both start with the change markers; counting them
    // would make every touched file look like one removal and one addition.
    const delta = try measureDiff(arena.allocator(),
        \\diff --git a/src/a.zig b/src/a.zig
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,0 +2,1 @@
        \\+const x = 1;
    );
    try testing.expectEqual(@as(u32, 0), delta.declarations_added);
    try testing.expectEqual(@as(u32, 0), delta.declarations_removed);
    try testing.expectEqual(@as(u32, 0), delta.assertions_removed);
}

// spec: Test Erosion - Flags an in-place test body rewrite that adds no test and no assertion

test "signals fires the body-rewrite signal only for a src plus test change with no new test" {
    const rewrite: TestDelta = .{ .assertions_added = 2, .assertions_removed = 2 };
    const both_touched: Touched = .{ .behavioral = 4, .test_lines = 6 };
    try testing.expect(signals(rewrite, both_touched).body_rewrite_only);
    // A test-only change is not the shape: nothing in production moved.
    try testing.expect(!signals(rewrite, .{ .test_lines = 6 }).body_rewrite_only);
    // A src-only change is change-classification's case, not this one.
    try testing.expect(!signals(rewrite, .{ .behavioral = 4 }).body_rewrite_only);
    // Adding a test declaration cannot be a pure body rewrite.
    const with_new_test: TestDelta = .{ .declarations_added = 1, .assertions_added = 1 };
    try testing.expect(!signals(with_new_test, both_touched).body_rewrite_only);
    // Assertions actually went up: the body rewrite proved more than before.
    const strengthened: TestDelta = .{ .assertions_added = 3, .assertions_removed = 1 };
    try testing.expect(!signals(strengthened, both_touched).body_rewrite_only);
    try testing.expect(signals(.{}, .{}).quiet());
}

// spec: Test Erosion - Counts only a real test declaration line as a test declaration

test "isTestDecl accepts named and decl tests and rejects prose mentioning test" {
    try testing.expect(isTestDecl("test \"parses headers\" {"));
    try testing.expect(isTestDecl("    test decltestName {"));
    // No opening brace: a mention, not a declaration.
    try testing.expect(!isTestDecl("// test \"parses headers\" is below"));
    try testing.expect(!isTestDecl("const testing = std.testing;"));
    try testing.expect(!isTestDecl("test {"));
    try testing.expect(!isTestDecl(""));
}

// spec: Test Erosion - Counts tests arriving in a brand-new untracked file as additions

test "countDeclarations counts a whole new file's tests so a moved test is not a deletion" {
    // git diff never shows an untracked file, so tests moved INTO a new module
    // are invisible on the added side unless the file is counted whole.
    try testing.expectEqual(@as(u32, 2), countDeclarations(
        \\const std = @import("std");
        \\test "first" {
        \\    try std.testing.expect(true);
        \\}
        \\// test "commented out" {
        \\test decltestSecond {
        \\    try std.testing.expect(true);
        \\}
    ));
    try testing.expectEqual(@as(u32, 0), countDeclarations(""));
}

// spec: Test Erosion - Measures assertion movement over both sides of the diff

test "measureDiff counts assertions on the added and removed sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const delta = try measureDiff(arena.allocator(), shrinking_diff);
    // Two `try expect(...)` lines left, one arrived — the rewrite proves less.
    try testing.expectEqual(@as(u32, 4), delta.assertions_removed);
    try testing.expectEqual(@as(u32, 2), delta.assertions_added);
}

// spec: Test Erosion - Reports every finding as advisory and never fails the build

test "report warns on both signals and stays green" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cap: reporter.Capture = .{ .allocator = arena.allocator() };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // `report` returns void: there is no failure path to take, which is the
    // whole point — signal (a) has a HIGH false-positive rate and legitimate
    // test consolidation must never red a build.
    try report(arena.allocator(), "HEAD", .{ .declarations_removed = 2 }, .{ .net_decrease = true, .body_rewrite_only = true });
    try testing.expectEqual(@as(usize, 2), cap.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "advisory only") != null);
    // Nothing here may assert motive: the paper reports counts and makes no
    // causal claim, so neither may the message.
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "in order to") == null);

    try report(arena.allocator(), "HEAD", .{}, .{});
    try testing.expectEqual(@as(usize, 2), cap.warnings.items.len);
}

test "isSrcZig admits only src Zig files" {
    try testing.expect(isSrcZig("src/checks/test_erosion.zig"));
    try testing.expect(!isSrcZig("README.md"));
    try testing.expect(!isSrcZig("test/golden.zig"));
}

fn fuzzDiffText(backing: Allocator, smith: *std.testing.Smith) anyerror!void {
    var bytes: [32 * 1024]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    _ = try measureDiff(arena.allocator(), input);
}

test "fuzz: the diff measurer tolerates arbitrary bytes" {
    try testing.fuzz(testing.allocator, fuzzDiffText, .{
        .corpus = &.{ "", "@@ -1 +1 @@\n-test \"a\" {\n", "diff --git a/x b/x\n" },
    });
}
