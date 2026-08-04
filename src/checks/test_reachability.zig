//! test-reachability — a `.zig` file whose `test` blocks never compile.
//!
//! Zig compiles the tests it can *reach*: only files transitively `@import`ed
//! from the test root's module graph contribute `test` blocks to the test
//! binary. A new module that nobody added to the aggregator therefore ships
//! green — its tests are neither compiled nor run, and its `// spec:` tags are
//! still counted as satisfied by the spec check, so the 1:1 map reads covered
//! while nothing verifies the behavior.
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const config = @import("../config.zig");
const import_graph = @import("../ast/import_graph.zig");

const detail = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const check_name = "test-reachability";

/// Trees walked into the reachability graph. `test/` joins `src/` because a
/// project's test root commonly lives outside `src/` — leaving it out would
/// make every file reachable only from `test/` look dead.
const graph_dirs = [_][]const u8{ "src", "test" };

/// Root files tried when `[test_reachability] roots` is unset, in addition to
/// every `.zig` directly under `test/`. These are Zig's two conventional module
/// roots; a project whose test root is neither (Guardian's own is
/// `src/check.zig`) names it in config.
const default_root_files = [_][]const u8{ "src/main.zig", "src/root.zig" };

/// True when `path` is a `.zig` file sitting directly under `test/` — a test
/// root by convention, since `zig build test` roots there need no aggregator.
fn isTopLevelTestFile(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "test/")) return false;
    return std.mem.indexOfScalar(u8, path["test/".len..], '/') == null;
}

/// True when some node in the graph has exactly this path.
fn isGraphed(nodes: []const import_graph.Node, path: []const u8) bool {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.path, path)) return true;
    }
    return false;
}

/// The test roots reachability is measured from, keeping only roots that name a
/// file actually in the graph — a configured root that names nothing (a moved
/// or deleted file) would silently shrink the reachable set and flag half the
/// tree, so it is dropped and, when nothing survives, the caller skips instead.
///
/// Configured roots win outright. Otherwise the default heuristic applies:
/// `src/main.zig`, `src/root.zig`, and every `.zig` directly under `test/`.
fn resolveRoots(
    allocator: Allocator,
    configured: []const []const u8,
    nodes: []const import_graph.Node,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (configured.len > 0) {
        for (configured) |r| {
            if (isGraphed(nodes, r)) try out.append(allocator, r);
        }
        return out.toOwnedSlice(allocator);
    }
    for (default_root_files) |r| {
        if (isGraphed(nodes, r)) try out.append(allocator, r);
    }
    for (nodes) |n| {
        if (isTopLevelTestFile(n.path)) try out.append(allocator, n.path);
    }
    return out.toOwnedSlice(allocator);
}

/// Every graphed file that declares at least one `test` block yet sits outside
/// the set reachable from `roots` — the files whose tests never compile.
/// Sorted by path for stable output.
///
/// Null when `roots` is empty: with no root, *nothing* is reachable, so every
/// test-bearing file in the project would be flagged. That is a configuration
/// gap, not a finding, so the check skips rather than false-blocking.
fn scan(
    allocator: Allocator,
    nodes: []const import_graph.Node,
    roots: []const []const u8,
) Allocator.Error!?[]const import_graph.Node {
    if (roots.len == 0) return null;

    const reached = try import_graph.reachableFrom(allocator, nodes, roots);
    var dead: std.ArrayList(import_graph.Node) = .empty;
    for (nodes) |n| {
        if (n.test_count == 0) continue;
        if (containsPath(reached, n.path)) continue;
        try dead.append(allocator, n);
    }
    const slice = try dead.toOwnedSlice(allocator);
    std.mem.sort(import_graph.Node, slice, {}, byPath);
    return slice;
}

fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

fn byPath(_: void, a: import_graph.Node, b: import_graph.Node) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// How many of the graphed files declare tests — reported on the green line so
/// a passing run states what it actually verified.
fn testBearingCount(nodes: []const import_graph.Node) usize {
    var count: usize = 0;
    for (nodes) |n| {
        if (n.test_count > 0) count += 1;
    }
    return count;
}

/// Prints the skip line naming exactly which roots were looked for, so an
/// unconfigured project can see why the check found nothing to measure.
fn reportNoRoots(configured: []const []const u8) void {
    if (configured.len > 0) {
        ok(check_name ++ ": skipped — no configured root names a file in the graph", .{});
    } else {
        ok(check_name ++ ": skipped — no test root found (src/main.zig, src/root.zig, test/*.zig)", .{});
    }
    detail("  set [test_reachability] roots = [\"src/your_test_root.zig\"] to enable the scan.\n", .{});
}

fn reportDead(allocator: Allocator, dead: []const import_graph.Node) Allocator.Error!void {
    fail(check_name ++ " FAILED ({d} file(s) whose tests never compile)", .{dead.len});
    for (dead) |n| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{d} test block(s) never compile — no test root imports this file",
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
    detail("  fix: add the file to a test root's @import chain " ++
        "(e.g. `_ = @import(\"path/to/file.zig\");` in the root's test block).\n", .{});
    detail("  exempt: name the real roots in [test_reachability] roots, " ++
        "or set [test_reachability] enabled = false.\n", .{});
}

/// Entry point for the test-reachability check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg: config.TestReachabilityCfg = ctx_param.cfg.test_reachability;

    if (!cfg.enabled) {
        ok(check_name ++ " disabled by config", .{});
        return;
    }

    const nodes = try import_graph.buildDirs(allocator, ctx_param.project_dir, &graph_dirs);
    if (nodes.len == 0) {
        ok(check_name ++ ": no source files to scan", .{});
        return;
    }

    const roots = try resolveRoots(allocator, cfg.roots, nodes);
    const dead = (try scan(allocator, nodes, roots)) orelse {
        reportNoRoots(cfg.roots);
        return;
    };
    if (dead.len == 0) {
        ok(check_name ++ ": all {d} test-bearing file(s) reachable from {d} root(s)", .{
            testBearingCount(nodes),
            roots.len,
        });
        return;
    }
    try reportDead(allocator, dead);
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The graph both reachability fixtures below reason over: a test root that
/// reaches `src/covered.zig` through one hop, a test-bearing file nothing
/// imports, and a test-free file nothing imports.
const fixture_nodes = [_]import_graph.Node{
    .{ .path = "src/check.zig", .edges = &.{"src/covered.zig"}, .test_count = 1 },
    .{ .path = "src/covered.zig", .edges = &.{"src/deep.zig"}, .test_count = 3 },
    .{ .path = "src/deep.zig", .edges = &.{}, .test_count = 2 },
    .{ .path = "src/stranded.zig", .edges = &.{}, .test_count = 5 },
    .{ .path = "src/quiet.zig", .edges = &.{}, .test_count = 0 },
};

const fixture_roots = [_][]const u8{"src/check.zig"};

// spec: Test Reachability - Passes a test-bearing file that a test root transitively imports

test "scan leaves a file the root reaches transitively unflagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dead = (try scan(a, &fixture_nodes, &fixture_roots)) orelse
        return error.TestUnexpectedResult;
    // check.zig -> covered.zig -> deep.zig: two hops from the root, so all
    // three compile and none of them is a finding.
    try testing.expect(!containsNode(dead, "src/check.zig"));
    try testing.expect(!containsNode(dead, "src/covered.zig"));
    try testing.expect(!containsNode(dead, "src/deep.zig"));
}

// spec: Test Reachability - Reports a file with test blocks that no test root transitively imports

test "scan flags an unimported test-bearing file and reports its test count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dead = (try scan(a, &fixture_nodes, &fixture_roots)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), dead.len);
    try testing.expectEqualStrings("src/stranded.zig", dead[0].path);
    // The count is what makes the finding actionable — five tests are dead, not
    // "a file is unreferenced".
    try testing.expectEqual(@as(u32, 5), dead[0].test_count);
}

// spec: Test Reachability - Ignores an unreachable file that declares no test blocks

test "scan ignores an unreachable file with no test blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dead = (try scan(a, &fixture_nodes, &fixture_roots)) orelse
        return error.TestUnexpectedResult;
    // src/quiet.zig is just as unreachable, but it costs no coverage — that is
    // orphan-files' finding, and duplicating it here would be pure noise.
    try testing.expect(!containsNode(dead, "src/quiet.zig"));
}

// spec: Test Reachability - Defaults the roots to src/main.zig, src/root.zig, and each .zig directly under test/

test "resolveRoots falls back to the conventional module and test-dir roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]import_graph.Node{
        .{ .path = "src/main.zig", .edges = &.{} },
        .{ .path = "src/root.zig", .edges = &.{} },
        .{ .path = "src/inner.zig", .edges = &.{} },
        .{ .path = "test/integration.zig", .edges = &.{} },
        .{ .path = "test/deep/helper.zig", .edges = &.{} },
    };
    const roots = try resolveRoots(a, &.{}, &nodes);
    // main + root + the top-level test file; a nested test/ helper is a module
    // the roots import, not a root itself.
    try testing.expectEqual(@as(usize, 3), roots.len);
    try testing.expect(containsPath(roots, "src/main.zig"));
    try testing.expect(containsPath(roots, "src/root.zig"));
    try testing.expect(containsPath(roots, "test/integration.zig"));
    try testing.expect(!containsPath(roots, "test/deep/helper.zig"));
}

// spec: Test Reachability - Uses the configured roots and drops any that name no graphed file

test "resolveRoots prefers configured roots and drops stale ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]import_graph.Node{
        .{ .path = "src/main.zig", .edges = &.{} },
        .{ .path = "src/check.zig", .edges = &.{} },
    };
    const roots = try resolveRoots(a, &.{ "src/check.zig", "src/moved_away.zig" }, &nodes);
    // The configured root replaces the heuristic entirely (main.zig is NOT a
    // root here), and the stale entry is dropped rather than shrinking the
    // reachable set behind the project's back.
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings("src/check.zig", roots[0]);
}

// spec: Test Reachability - Skips the scan when no test root resolves

test "scan skips instead of flagging every file when no root resolves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A project with neither conventional root nor a test/ tree resolves none.
    const nodes = [_]import_graph.Node{
        .{ .path = "src/check.zig", .edges = &.{}, .test_count = 1 },
    };
    const roots = try resolveRoots(a, &.{}, &nodes);
    try testing.expectEqual(@as(usize, 0), roots.len);
    // With no root every test-bearing file would read as dead, so the scan
    // reports "nothing measured" rather than a tree-wide false block.
    try testing.expectEqual(@as(?[]const import_graph.Node, null), try scan(a, &nodes, roots));
}

/// True when `dead` contains a finding for `path` (test-local convenience so
/// the assertions above stay loop-free).
fn containsNode(dead: []const import_graph.Node, path: []const u8) bool {
    for (dead) |n| {
        if (std.mem.eql(u8, n.path, path)) return true;
    }
    return false;
}
