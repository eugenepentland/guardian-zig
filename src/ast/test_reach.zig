//! Which files' `test` blocks a project's test roots actually compile.
//!
//! Two checks read this analysis and neither may depend on the other, so the
//! walk lives here in the AST layer. `checks/test_reachability` reports the
//! files whose tests never compile; `checks/spec` refuses to count a `// spec:`
//! tag sitting in one of them, because a tag on a test that never runs satisfies
//! its SPEC bullet with nothing.
//!
//! Reachability is walked over `Node.test_edges` — the imports a file actually
//! references (`test_refs.zig`) — not over every textual `@import`, which
//! over-states what a test binary contains.

const std = @import("std");
const Allocator = std.mem.Allocator;
const walk = @import("../walk.zig");
const import_graph = @import("import_graph.zig");

/// Trees walked into the reachability graph. `test/` joins `src/` because a
/// project's test root commonly lives outside `src/` — leaving it out would
/// make every file reachable only from `test/` look dead.
pub const graph_dirs = [_][]const u8{ "src", "test" };

/// Root files tried when `[test_reachability] roots` is unset, in addition to
/// every `.zig` directly under `test/`. These are Zig's conventional module
/// roots plus the two conventional names for a dedicated unit-test root; a
/// project whose test root is none of them (Guardian's own is `src/check.zig`)
/// names it in config.
pub const default_root_files = [_][]const u8{
    "src/main.zig",
    "src/root.zig",
    "src/test_root.zig",
    "src/tests.zig",
};

/// One project's test-reachability picture.
pub const Analysis = struct {
    /// Every graphed file, with both edge sets and its `test` block count.
    nodes: []const import_graph.Node,
    /// The roots reachability was measured from (see `resolveRoots`).
    roots: []const []const u8,
    /// Test-bearing files outside the reachable set — the ones whose tests never
    /// compile. Null when no root resolved, in which case NOTHING was measured
    /// and no consumer may draw a conclusion.
    dead: ?[]const import_graph.Node,
    /// How many tests the largest single root's closure holds.
    ///
    /// The largest, not the sum: a project may split its suite across several
    /// test binaries (Guardian itself compiles its runner separately), and a
    /// recorded run only reports the binaries whose runner prints a count. The
    /// biggest closure is the strongest claim that comparison can support
    /// without knowing which binary did the reporting.
    expected: u32,
    /// Every `test` block in the walked trees, reachable or not.
    tests_in_tree: u32,
};

/// Builds the graph and measures reachability from the resolved roots.
/// `excludes` are the config `exclude` globs, so a file no check may see is not
/// judged here either.
pub fn analyze(
    allocator: Allocator,
    project_dir: []const u8,
    configured_roots: []const []const u8,
    excludes: []const []const u8,
) walk.WalkError!Analysis {
    const nodes = try import_graph.buildDirsExcluding(allocator, project_dir, &graph_dirs, excludes);
    const roots = try resolveRoots(allocator, configured_roots, nodes);
    return .{
        .nodes = nodes,
        .roots = roots,
        .dead = try scanDead(allocator, nodes, roots),
        .expected = try largestClosure(allocator, nodes, roots),
        .tests_in_tree = totalTests(nodes),
    };
}

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
/// `default_root_files` and every `.zig` directly under `test/`.
pub fn resolveRoots(
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
/// gap, not a finding, so the caller skips rather than false-blocking.
pub fn scanDead(
    allocator: Allocator,
    nodes: []const import_graph.Node,
    roots: []const []const u8,
) Allocator.Error!?[]const import_graph.Node {
    if (roots.len == 0) return null;

    const reached = try import_graph.reachableVia(allocator, nodes, roots, .test_compiling);
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

/// The test count of the largest single root closure (see `Analysis.expected`).
fn largestClosure(
    allocator: Allocator,
    nodes: []const import_graph.Node,
    roots: []const []const u8,
) Allocator.Error!u32 {
    var largest: u32 = 0;
    for (roots) |root| {
        const reached = try import_graph.reachableVia(allocator, nodes, &.{root}, .test_compiling);
        var count: u32 = 0;
        for (nodes) |n| {
            if (containsPath(reached, n.path)) count += n.test_count;
        }
        if (count > largest) largest = count;
    }
    return largest;
}

/// Every `test` block in the graph, reachable or not — the model-free number a
/// recorded test run is checked for staleness against.
fn totalTests(nodes: []const import_graph.Node) u32 {
    var count: u32 = 0;
    for (nodes) |n| count += n.test_count;
    return count;
}

/// True when `paths` holds `needle`.
fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

fn byPath(_: void, a: import_graph.Node, b: import_graph.Node) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// How many of the graphed files declare tests — reported on a passing run so a
/// green line states what it actually verified.
pub fn testBearingCount(nodes: []const import_graph.Node) usize {
    var count: usize = 0;
    for (nodes) |n| {
        if (n.test_count > 0) count += 1;
    }
    return count;
}

/// True when `path` is one of the files the analysis found dead. False whenever
/// nothing was measured, so a caller can never mistake "no roots" for "clean".
pub fn isDead(analysis: *const Analysis, path: []const u8) bool {
    const dead = analysis.dead orelse return false;
    for (dead) |n| {
        if (std.mem.eql(u8, n.path, path)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The graph both reachability fixtures below reason over: a test root that
/// reaches `src/covered.zig` through one hop, a test-bearing file nothing
/// references, and a test-free file nothing references.
/// Fixture paths, spelled once: the reachability fixtures name each of them
/// from several nodes and assertions.
const covered_path = "src/covered.zig";
const deep_path = "src/deep.zig";

const fixture_nodes = [_]import_graph.Node{
    .{
        .path = "src/check.zig",
        .edges = &.{covered_path},
        .test_edges = &.{covered_path},
        .test_count = 1,
    },
    .{
        .path = covered_path,
        .edges = &.{deep_path},
        .test_edges = &.{deep_path},
        .test_count = 3,
    },
    .{ .path = deep_path, .edges = &.{}, .test_edges = &.{}, .test_count = 2 },
    .{ .path = "src/stranded.zig", .edges = &.{}, .test_edges = &.{}, .test_count = 5 },
    .{ .path = "src/quiet.zig", .edges = &.{}, .test_edges = &.{}, .test_count = 0 },
};

const fixture_roots = [_][]const u8{"src/check.zig"};

// spec: Test Reachability - Passes a test-bearing file that a test root transitively imports

test "scanDead leaves a file the root reaches transitively unflagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dead = (try scanDead(a, &fixture_nodes, &fixture_roots)) orelse
        return error.TestUnexpectedResult;
    // check.zig -> covered.zig -> deep.zig: two hops from the root, so all
    // three compile and none of them is a finding.
    try testing.expect(!containsNode(dead, "src/check.zig"));
    try testing.expect(!containsNode(dead, covered_path));
    try testing.expect(!containsNode(dead, deep_path));
}

// spec: Test Reachability - Reports a file with test blocks that no test root transitively imports

test "scanDead flags an unreferenced test-bearing file and reports its test count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dead = (try scanDead(a, &fixture_nodes, &fixture_roots)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), dead.len);
    try testing.expectEqualStrings("src/stranded.zig", dead[0].path);
    // The count is what makes the finding actionable — five tests are dead, not
    // "a file is unreferenced".
    try testing.expectEqual(@as(u32, 5), dead[0].test_count);
}

// spec: Test Reachability - Ignores an unreachable file that declares no test blocks

test "scanDead ignores an unreachable file with no test blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dead = (try scanDead(a, &fixture_nodes, &fixture_roots)) orelse
        return error.TestUnexpectedResult;
    // src/quiet.zig is just as unreachable, but it costs no coverage — that is
    // orphan-files' finding, and duplicating it here would be pure noise.
    try testing.expect(!containsNode(dead, "src/quiet.zig"));
}

// spec: Test Reachability - Defaults the roots to the conventional module and test-root names plus test/*.zig

test "resolveRoots falls back to the conventional module and test-dir roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]import_graph.Node{
        .{ .path = "src/main.zig", .edges = &.{} },
        .{ .path = "src/root.zig", .edges = &.{} },
        .{ .path = "src/test_root.zig", .edges = &.{} },
        .{ .path = "src/inner.zig", .edges = &.{} },
        .{ .path = "test/integration.zig", .edges = &.{} },
        .{ .path = "test/deep/helper.zig", .edges = &.{} },
    };
    const roots = try resolveRoots(a, &.{}, &nodes);
    // main + root + the dedicated unit-test root + the top-level test file; a
    // nested test/ helper is a module the roots import, not a root itself.
    try testing.expectEqual(@as(usize, 4), roots.len);
    try testing.expect(containsPath(roots, "src/main.zig"));
    try testing.expect(containsPath(roots, "src/root.zig"));
    // A project that roots its suite separately from its executable (eda's
    // `src/test_root.zig`) is the common case the old two-name list missed: its
    // real root then read as an unreachable file, and every file only it
    // reaches read as dead.
    try testing.expect(containsPath(roots, "src/test_root.zig"));
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

test "scanDead skips instead of flagging every file when no root resolves" {
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
    try testing.expectEqual(@as(?[]const import_graph.Node, null), try scanDead(a, &nodes, roots));
}

// spec: Test Reachability - Measures the tests the largest single root closure holds

test "largestClosure measures the biggest root closure, not their sum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two independent roots, as a project with two test binaries has.
    const roots = [_][]const u8{ "src/check.zig", "src/stranded.zig" };
    // 1 + 3 + 2 from the check.zig closure beats stranded.zig's own 5, and the
    // sum (11) is not claimed: only some binaries report a count, so the
    // strongest supportable claim is the largest single closure.
    try testing.expectEqual(@as(u32, 6), try largestClosure(a, &fixture_nodes, &roots));
    try testing.expectEqual(@as(u32, 11), totalTests(&fixture_nodes));
    // Files, not tests: four of the five fixture nodes declare a test block, and
    // that count is what a passing run states it verified.
    try testing.expectEqual(@as(usize, 4), testBearingCount(&fixture_nodes));
}

// spec: Test Reachability - Answers dead-file membership as false whenever nothing was measured

test "isDead names a dead file and stays false when no root resolved" {
    const dead_nodes = [_]import_graph.Node{fixture_nodes[3]};
    const measured: Analysis = .{
        .nodes = &fixture_nodes,
        .roots = &fixture_roots,
        .dead = &dead_nodes,
        .expected = 6,
        .tests_in_tree = 11,
    };
    try testing.expect(isDead(&measured, "src/stranded.zig"));
    try testing.expect(!isDead(&measured, covered_path));
    // Nothing measured: every consumer must read "not dead", never "dead by
    // default" — an unmeasured project would otherwise have every tag refused.
    const unmeasured: Analysis = .{
        .nodes = &fixture_nodes,
        .roots = &.{},
        .dead = null,
        .expected = 0,
        .tests_in_tree = 11,
    };
    try testing.expect(!isDead(&unmeasured, "src/stranded.zig"));
}

/// True when `dead` contains a finding for `path` (test-local convenience so
/// the assertions above stay loop-free).
fn containsNode(dead: []const import_graph.Node, path: []const u8) bool {
    for (dead) |n| {
        if (std.mem.eql(u8, n.path, path)) return true;
    }
    return false;
}
