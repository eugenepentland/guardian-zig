//! test-reachability — a `.zig` file whose `test` blocks never compile.
//!
//! Zig compiles the tests it can *reach*: a file's `test` decls join the test
//! binary only when the file's namespace is REFERENCED from something the test
//! build analyzes. A new module that nobody added to the aggregator therefore
//! ships green — its tests are neither compiled nor run, and its `// spec:` tags
//! were still counted as satisfied by the spec check, so the 1:1 map read
//! covered while nothing verified the behavior.
//!
//! This is not hypothetical: in eda six files' inline tests silently never
//! compiled (29 dead tests, found by accident during a mutation campaign), and
//! a later agent lost a bisect to a new module whose tests were excluded the
//! same way. Both are invisible to every other gate — orphan-files reasons only
//! about `src/` reachability from *production* roots, so a file that main.zig
//! legitimately imports but the test root does not is orphan-clean and
//! test-dead at once.
//!
//! The check flags a file only when unreachability actually costs coverage: it
//! must declare at least one `test` block. A file with no tests that nothing
//! imports is orphan-files' business, not this check's.
//!
//! **Two independent verdicts, and the split is the point.**
//!
//! 1. The MODEL (`ast/test_reach.zig`): reachability over the imports a file
//!    references (`ast/test_refs.zig`), not over every textual `@import`. An
//!    import bound to an alias nobody mentions references nothing, so it keeps
//!    no tests alive — walking it, as this check used to, made an aggregator out
//!    of every file that merely names another.
//! 2. The MEASUREMENT (`test_count.zig`): what the suite actually ran, recorded
//!    from the runner's own `guardian/test: N test(s) selected` line by the
//!    commit gate. The model cannot see a reference that sits in a function no
//!    test ever reaches, so it errs towards calling files reachable; the
//!    measurement closes exactly that gap by naming the count the model
//!    over-promised. Ground truth, not a second opinion — when the two
//!    disagree, the runner is right.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const config = @import("../config.zig");
const import_graph = @import("../ast/import_graph.zig");
const test_reach = @import("../ast/test_reach.zig");
const test_count = @import("../test_count.zig");
const fs = @import("../fs.zig");
const snapshot = @import("../snapshot.zig");

const detail = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const check_name = "test-reachability";

/// Prints the skip line naming exactly which roots were looked for, so an
/// unconfigured project can see why the check found nothing to measure.
fn reportNoRoots(configured: []const []const u8) void {
    if (configured.len > 0) {
        ok(check_name ++ ": skipped — no configured root names a file in the graph", .{});
    } else {
        ok(check_name ++ ": skipped — no test root found (src/main.zig, src/root.zig, " ++
            "src/test_root.zig, src/tests.zig, test/*.zig)", .{});
    }
    // `note:` is one of the labels the violation scraper stops at (see
    // baseline.extract): unlabeled prose from a PASSING check was scraped into
    // last-run.jsonl as a phantom violation.
    detail("  note: set [test_reachability] roots = [\"src/your_test_root.zig\"] to enable the scan.\n", .{});
}

fn reportDead(allocator: Allocator, dead: []const import_graph.Node) Allocator.Error!void {
    fail(check_name ++ " FAILED ({d} file(s) whose tests never compile)", .{dead.len});
    for (dead) |n| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{d} test block(s) never compile — no test root references this file",
            .{n.test_count},
        );
        // The file IS the subject, and a tier-1 identity is the whole baseline
        // key, so it must carry the path itself or every file would collide on
        // one key (see violation_key.zig).
        reporter.emit(.{
            .check = check_name,
            .file = n.path,
            .message = msg,
            .identity = n.path,
            .metric = n.test_count,
        });
    }
    detail("  fix: reference the file from a test root's module graph " ++
        "(e.g. `_ = @import(\"path/to/file.zig\");` in the root's test block).\n", .{});
    detail("  exempt: name the real roots in [test_reachability] roots, " ++
        "or set [test_reachability] enabled = false.\n", .{});
}

/// Baseline identity of the count-gap finding. One per project (there is only
/// one suite), so it is a fixed string rather than a path.
const shortfall_identity = "recorded-test-count";

/// A measured gap: the model says the roots reach `expected` tests, the last
/// recorded run selected `selected`, and the difference never compiled.
const Shortfall = struct { selected: u32, expected: u32 };

/// Holds the model against the last recorded run.
///
/// Null in three cases, all of them "nothing was measured": no record (the
/// commit gate has not run the suite here yet), a record taken when the tree
/// held a different number of `test` blocks (it predates today's tests and says
/// nothing about them), and a run that selected at least as many tests as the
/// model expects.
fn shortfallOf(a: Allocator, project_dir: []const u8, analysis: *const test_reach.Analysis) ?Shortfall {
    const rec = test_count.read(a, project_dir) orelse return null;
    if (rec.tests_in_tree != analysis.tests_in_tree) return null;
    if (rec.selected >= analysis.expected) return null;
    return .{ .selected = rec.selected, .expected = analysis.expected };
}

/// Emits the count-gap finding. The measurement outranks the model, so the
/// message leads with the tests that never compiled and then names both numbers
/// it was derived from.
fn emitShortfall(a: Allocator, gap: Shortfall) Allocator.Error!void {
    reporter.emit(.{
        .check = check_name,
        .message = try std.fmt.allocPrint(
            a,
            "{d} reachable test(s) never compiled — the last recorded run selected {d}, " ++
                "but the test roots reach {d}",
            .{ gap.expected - gap.selected, gap.selected, gap.expected },
        ),
        .identity = shortfall_identity,
        .metric = gap.expected - gap.selected,
    });
}

/// Entry point for the test-reachability check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const cfg: config.TestReachabilityCfg = ctx_param.cfg.test_reachability;

    if (!cfg.enabled) {
        ok(check_name ++ " disabled by config", .{});
        return;
    }

    const analysis = try ctx_param.testReach();
    if (analysis.nodes.len == 0) {
        ok(check_name ++ ": no source files to scan", .{});
        return;
    }

    const dead = analysis.dead orelse {
        reportNoRoots(cfg.roots);
        return;
    };
    const gap = shortfallOf(ctx_param.allocator, ctx_param.project_dir, analysis);
    if (dead.len == 0 and gap == null) {
        ok(check_name ++ ": all {d} test-bearing file(s) reachable from {d} root(s)", .{
            test_reach.testBearingCount(analysis.nodes),
            analysis.roots.len,
        });
        return;
    }
    if (dead.len > 0) try reportDead(ctx_param.allocator, dead);
    if (gap) |g| {
        if (dead.len == 0)
            fail(check_name ++ " FAILED (the recorded test run ran fewer tests than the roots reach)", .{});
        try emitShortfall(ctx_param.allocator, g);
        detail("  fix: the reachability model is optimistic here — a file it calls reachable " ++
            "is referenced only from code no test analyzes. Aggregate it explicitly " ++
            "(`_ = @import(\"...\");` in a test root's test block).\n", .{});
    }
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Test Reachability - Labels the unconfigured-roots notice so it is not scraped as a violation

test "the skip notice is trailing prose, not a finding" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    reportNoRoots(&.{});
    // The violation scraper reads every indented line as a finding unless it
    // opens with a known prose label, and this check PASSES while printing the
    // notice — unlabeled, it reached last-run.jsonl as a phantom violation.
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "\n  note: set [test_reachability] roots") != null);
    try std.testing.expectEqual(@as(usize, 0), cap.records.items.len);
}

/// Writes one recorded measurement into `dir`, for the shortfall tests.
fn withRecord(a: Allocator, dir: []const u8, selected: u32, tree: u32) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, test_count.leaf });
    var lines = [_][]const u8{
        try std.fmt.allocPrint(a, "selected {d}", .{selected}),
        try std.fmt.allocPrint(a, "tree {d}", .{tree}),
    };
    try snapshot.write(path, test_count.version, &lines);
}

/// An analysis carrying no files, so the shortfall tests exercise the recorded
/// comparison without walking a tree.
fn analysisOf(expected: u32, tests_in_tree: u32) test_reach.Analysis {
    return .{
        .nodes = &.{},
        .roots = &.{"src/check.zig"},
        .dead = &.{},
        .expected = expected,
        .tests_in_tree = tests_in_tree,
    };
}

// spec: Test Reachability - Reports how many reachable tests the recorded run never compiled

test "the count gap names the roots' reach and the run that fell short of it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-reach-shortfall";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try withRecord(a, dir, 800, 967);

    var cap: reporter.Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const analysis = analysisOf(950, 967);
    const gap = shortfallOf(a, dir, &analysis) orelse return error.TestUnexpectedResult;
    try emitShortfall(a, gap);
    // The measurement outranks the model: 150 tests the model calls reachable
    // were never compiled, and the finding says so with both numbers.
    try testing.expectEqual(@as(usize, 1), cap.records.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.records.items[0].message, "150 reachable test(s)") != null);
    try testing.expectEqualStrings(shortfall_identity, cap.records.items[0].identity.?);
}

// spec: Test Reachability - Ignores a recorded run taken when the tree held a different test count

test "the count gap stays silent for a stale record, a matching run, and no record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-reach-stale";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try withRecord(a, dir, 800, 900);

    // The record was taken when the tree held 900 tests; today it holds 967, so
    // it predates these tests and cannot say anything about them.
    const stale = analysisOf(950, 967);
    try testing.expectEqual(@as(?Shortfall, null), shortfallOf(a, dir, &stale));
    // A run that selected everything the roots reach is exactly the green case.
    const matched = analysisOf(800, 900);
    try testing.expectEqual(@as(?Shortfall, null), shortfallOf(a, dir, &matched));
    // And a project with no record at all has measured nothing.
    try testing.expectEqual(@as(?Shortfall, null), shortfallOf(a, "zig-cache/test-reach-none", &stale));
}
