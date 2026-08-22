//! Builds the project's `@import` graph: one node per walked file with edges to
//! the importable `.zig` files it pulls in (std/builtin/root and off-tree paths
//! filtered out). Backs the import-cycle, orphan-file, and test-reachability
//! checks.
//!
//! Two edge sets per node, because "A mentions B" and "A makes B's tests
//! compile" are different relations. `edges` is every textual `@import` — what
//! the cycle and orphan checks reason over. `test_edges` is the subset that
//! actually REFERENCES the imported file (see `test_refs.zig`), which is the
//! relation Zig compiles tests by.

const std = @import("std");
const Allocator = std.mem.Allocator;
const walk = @import("../walk.zig");
const ast = @import("parser.zig");
const test_refs = @import("test_refs.zig");

/// One node in the import graph: a source file's outgoing edges (each edge is
/// a normalized rel_path of an importable .zig under one of the walked trees),
/// the subset of those edges that reference the imported file (`test_edges`),
/// plus how many `test` blocks the file declares.
/// Edges to "std", "builtin", "root", or any path not in the walk set are
/// already filtered out by the builder.
///
/// `test_count` rides along with the graph on purpose: the builder already
/// reads and tokenizes every file, so counting the `test` keyword here costs
/// one extra token scan instead of a second whole-tree read for the check that
/// asks whether a file's tests are reachable at all (checks/test_reachability).
pub const Node = struct {
    path: []const u8,
    edges: []const []const u8,
    test_edges: []const []const u8 = &.{},
    test_count: u32 = 0,
};

/// Which edge set a traversal follows.
pub const EdgeKind = enum {
    /// Every textual `@import` — "this file mentions that one".
    textual,
    /// Only the imports the file references, so the imported file's `test`
    /// blocks are compiled (`test_refs.referenced`).
    test_compiling,
};

const CollectCtx = struct {
    allocator: Allocator,
    nodes: *std.ArrayList(Node),
};

fn collectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const raw = ast.imports(a, entry.content);
    var edges: std.ArrayList([]const u8) = .empty;
    for (raw) |imp| {
        const resolved = try resolveImport(a, entry.rel_path, imp.path) orelse continue;
        try edges.append(a, resolved);
    }
    var test_edges: std.ArrayList([]const u8) = .empty;
    for (try test_refs.referenced(a, entry.content)) |path| {
        const resolved = try resolveImport(a, entry.rel_path, path) orelse continue;
        try test_edges.append(a, resolved);
    }

    try ctx.nodes.append(a, .{
        .path = entry.rel_path,
        .edges = try edges.toOwnedSlice(a),
        .test_edges = try test_edges.toOwnedSlice(a),
        .test_count = countTestBlocks(entry.content),
    });
}

/// Normalizes one import path against the importing file's directory, or null
/// for the module names that are never files in the walk set.
fn resolveImport(
    a: Allocator,
    rel_path: []const u8,
    imp_path: []const u8,
) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, imp_path, "std")) return null;
    if (std.mem.eql(u8, imp_path, "builtin")) return null;
    if (std.mem.eql(u8, imp_path, "root")) return null;
    const slash = std.mem.lastIndexOfScalar(u8, rel_path, '/') orelse return imp_path;
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_path[0..slash], imp_path });
    return try walk.normalizePath(a, joined);
}

/// How many `test` blocks `z` declares. Token-based, so a `test` inside a
/// string literal, a comment, or a doc comment never counts.
fn countTestBlocks(z: [:0]const u8) u32 {
    var tok = std.zig.Tokenizer.init(z);
    var count: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .keyword_test) count += 1;
    }
    return count;
}

/// Errors propagated out of `build`: it walks the source trees and appends one
/// Node per file, so its failure surface is exactly the walker's (fs + OOM).
pub const BuildError = walk.WalkError;

/// The tree `build` walks — the historical src-only graph the cycle and
/// orphan checks reason over.
const src_only_dirs = [_][]const u8{"src"};

/// Walks `<project_dir>/src/`, parses every .zig file's @import paths, and
/// returns one Node per file. Edges are normalized rel_paths suitable for
/// matching against other Node.path values. Edges that don't resolve to a
/// node in the walk set are still kept (callers filter them).
pub fn build(allocator: Allocator, project_dir: []const u8) BuildError![]const Node {
    return buildDirs(allocator, project_dir, &src_only_dirs);
}

/// Same as `build`, but graphs every tree in `dirs` (each a `project_dir`-
/// relative directory that doubles as its own display root, e.g. "src",
/// "test"). A missing directory is simply nothing to walk.
///
/// Edges are normalized across the trees, so `test/x.zig` importing
/// `../src/a.zig` resolves to the `src/a.zig` node — which is what lets a
/// caller follow reachability from a test root that lives outside `src/`.
pub fn buildDirs(
    allocator: Allocator,
    project_dir: []const u8,
    dirs: []const []const u8,
) BuildError![]const Node {
    return buildDirsExcluding(allocator, project_dir, dirs, &.{});
}

/// Same as `buildDirs`, but drops every file a config `exclude` glob names, so
/// a graph-based verdict never reasons about a file no other check may see.
pub fn buildDirsExcluding(
    allocator: Allocator,
    project_dir: []const u8,
    dirs: []const []const u8,
    excludes: []const []const u8,
) BuildError![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    var ctx: CollectCtx = .{ .allocator = allocator, .nodes = &nodes };

    for (dirs) |dir| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir });
        const opts: walk.WalkOpts = .{ .display_root = dir, .excludes = excludes };
        try walk.walkZigFiles(allocator, path, opts, .{ .ctx = &ctx, .visit = collectVisit });
    }
    return nodes.toOwnedSlice(allocator);
}

const Color = enum { white, gray, black };

const CycleFinder = struct {
    allocator: Allocator,
    nodes: []const Node,
    colors: []Color,
    stack: std.ArrayList(usize),
    cycle: ?[]const usize,

    fn nodeIndex(self: *CycleFinder, path: []const u8) ?usize {
        for (self.nodes, 0..) |n, i| {
            if (std.mem.eql(u8, n.path, path)) return i;
        }
        return null;
    }

    /// Records the cycle that closes at `target`. Asserts `target` is gray —
    /// dfs only reaches here on a gray back-edge, so `target` must be somewhere
    /// on the current DFS stack for the loop-slice below to find its start.
    /// OOM propagates: silently dropping the recorded cycle would let the
    /// imports check pass on a graph that actually has one (fail open).
    fn recordCycle(self: *CycleFinder, target: usize) Allocator.Error!void {
        std.debug.assert(self.colors[target] == .gray);
        var loop: std.ArrayList(usize) = .empty;
        var found_start = false;
        for (self.stack.items) |s| {
            if (s == target) found_start = true;
            if (found_start) try loop.append(self.allocator, s);
        }
        try loop.append(self.allocator, target);
        self.cycle = try loop.toOwnedSlice(self.allocator);
    }

    /// Asserts `idx` is unvisited (white) on entry: findCycle seeds only white
    /// roots and dfs recurses only into white children, so a 3-color DFS never
    /// re-enters a gray/black node — re-entry would double-push the stack.
    fn dfs(self: *CycleFinder, idx: usize) Allocator.Error!void {
        if (self.cycle != null) return;
        std.debug.assert(self.colors[idx] == .white);
        self.colors[idx] = .gray;
        try self.stack.append(self.allocator, idx);
        for (self.nodes[idx].edges) |edge| {
            const target = self.nodeIndex(edge) orelse continue;
            switch (self.colors[target]) {
                .white => try self.dfs(target),
                .gray => try self.recordCycle(target),
                .black => {},
            }
            if (self.cycle != null) return;
        }
        _ = self.stack.pop();
        self.colors[idx] = .black;
    }
};

/// Returns the first cycle found in the graph, as an ordered list of node
/// paths (start == end). Null if the graph is acyclic. OOM propagates so the
/// imports check can never pass by silently failing to detect a cycle.
pub fn findCycle(allocator: Allocator, nodes: []const Node) Allocator.Error!?[]const []const u8 {
    const colors = try allocator.alloc(Color, nodes.len);
    @memset(colors, .white);
    const root_order = try allocator.alloc(usize, nodes.len);
    for (root_order, 0..) |*root, i| root.* = i;
    std.mem.sort(usize, root_order, nodes, nodeIndexLessThan);
    var finder: CycleFinder = .{
        .allocator = allocator,
        .nodes = nodes,
        .colors = colors,
        .stack = .empty,
        .cycle = null,
    };
    for (root_order) |i| {
        if (finder.colors[i] == .white) try finder.dfs(i);
        if (finder.cycle != null) break;
    }
    const indices = finder.cycle orelse return null;
    return try indicesToPaths(allocator, nodes, indices);
}

// Filesystem walkers do not promise directory-entry order. Sort DFS roots by
// path so two hosts select the same representative when a graph has multiple
// cycles and the imports snapshot therefore remains portable.
fn nodeIndexLessThan(nodes: []const Node, a: usize, b: usize) bool {
    return std.mem.order(u8, nodes[a].path, nodes[b].path) == .lt;
}

// Maps a list of node indices to their paths. OOM propagates.
fn indicesToPaths(
    allocator: Allocator,
    nodes: []const Node,
    indices: []const usize,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (indices) |idx| try out.append(allocator, nodes[idx].path);
    return out.toOwnedSlice(allocator);
}

/// Returns the set of node paths reachable from any of `roots` via BFS over
/// every textual `@import`. Roots that don't exist in the node set are silently
/// skipped. The returned slice is sorted for stable output.
pub fn reachableFrom(
    allocator: Allocator,
    nodes: []const Node,
    roots: []const []const u8,
) Allocator.Error![]const []const u8 {
    return reachableVia(allocator, nodes, roots, .textual);
}

/// Same BFS over the chosen edge set. `.test_compiling` answers the question the
/// test-reachability check asks — whose `test` blocks does a test root's module
/// graph actually compile — which a textual walk over-states.
pub fn reachableVia(
    allocator: Allocator,
    nodes: []const Node,
    roots: []const []const u8,
    kind: EdgeKind,
) Allocator.Error![]const []const u8 {
    const visited = try allocator.alloc(bool, nodes.len);
    @memset(visited, false);

    var bfs: Bfs = .{
        .allocator = allocator,
        .nodes = nodes,
        .visited = visited,
        .queue = .empty,
        .kind = kind,
    };
    for (roots) |r| try bfs.enqueueByPath(r);

    while (bfs.queue.items.len > 0) {
        const idx = bfs.queue.orderedRemove(0);
        for (bfs.edgesOf(idx)) |edge| try bfs.enqueueByPath(edge);
    }

    var out: std.ArrayList([]const u8) = .empty;
    for (nodes, 0..) |n, i| {
        if (visited[i]) try out.append(allocator, n.path);
    }
    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, lessThan);
    return slice;
}

// Mutable BFS traversal state for reachableVia.
const Bfs = struct {
    allocator: Allocator,
    nodes: []const Node,
    visited: []bool,
    queue: std.ArrayList(usize),
    kind: EdgeKind = .textual,

    /// The outgoing edges this traversal follows for node `idx`.
    fn edgesOf(self: *const Bfs, idx: usize) []const []const u8 {
        return switch (self.kind) {
            .textual => self.nodes[idx].edges,
            .test_compiling => self.nodes[idx].test_edges,
        };
    }

    // Marks and enqueues the first unvisited node whose path equals `path`.
    fn enqueueByPath(self: *Bfs, path: []const u8) Allocator.Error!void {
        for (self.nodes, 0..) |n, i| {
            if (!std.mem.eql(u8, n.path, path) or self.visited[i]) continue;
            self.visited[i] = true;
            try self.queue.append(self.allocator, i);
            return;
        }
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The node whose path is `path`, or null when the graph has no such file.
/// Used by the tests below to assert on one file without looping in a test body.
fn nodeAt(nodes: []const Node, path: []const u8) ?Node {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.path, path)) return n;
    }
    return null;
}

// spec: Test Reachability - Counts each graphed file's test blocks while building the import graph

test "buildDirs graphs the named trees and counts every file's test blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The fixture project's root declares four `test` blocks; a missing tree
    // (it has no test/ directory) is simply nothing to walk, not an error.
    const nodes = try buildDirs(a, "test-project", &.{ "src", "test" });
    const root = nodeAt(nodes, "src/main.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 4), root.test_count);
    // A file with no test block counts zero — the signal the reachability check
    // reads to decide whether unreachability costs anything.
    const helpers = nodeAt(nodes, "src/utils/helpers.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), helpers.test_count);
}

// spec: Test Reachability - Records each file's test edges beside its plain import edges while building the graph

test "buildDirs records the referencing edges beside the textual ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = try buildDirs(a, "test-project", &.{ "src", "test" });
    const root = nodeAt(nodes, "src/main.zig") orelse return error.TestUnexpectedResult;
    // The fixture's root aggregates its two modules with `_ = @import(...)`, so
    // both relations hold for them — and `std`, which is neither a file in the
    // walk set nor an edge, is filtered out of both.
    try std.testing.expect(hasEdge(root.edges, "src/core/math.zig"));
    try std.testing.expect(hasEdge(root.test_edges, "src/core/math.zig"));
    try std.testing.expect(!hasEdge(root.test_edges, "std"));
    // A config `exclude` glob drops the file from the graph entirely, so a
    // reachability verdict never reasons about a file no other check may see.
    const filtered = try buildDirsExcluding(a, "test-project", &.{"src"}, &.{"core/"});
    try std.testing.expect(filtered.len < nodes.len);
    try std.testing.expect(nodeAt(filtered, "src/core/math.zig") == null);
}

// spec: Test Reachability - Walks reachability over the referencing edges when asked for the test-compiled set

test "reachableVia follows only the referencing edges for the test-compiled set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        // The root mentions both files but only references one of them.
        .{ .path = "src/root.zig", .edges = &.{ "src/a.zig", "src/b.zig" }, .test_edges = &.{"src/a.zig"} },
        .{ .path = "src/a.zig", .edges = &.{}, .test_edges = &.{} },
        .{ .path = "src/b.zig", .edges = &.{}, .test_edges = &.{} },
    };
    const roots = &[_][]const u8{"src/root.zig"};
    // The textual walk keeps the unused import alive; the test-compiling walk
    // does not, which is the whole difference between "mentioned" and "its
    // tests are compiled".
    try std.testing.expectEqual(@as(usize, 3), (try reachableFrom(a, nodes, roots)).len);
    const compiled = try reachableVia(a, nodes, roots, .test_compiling);
    try std.testing.expectEqual(@as(usize, 2), compiled.len);
    try std.testing.expect(!containsPath(compiled, "src/b.zig"));
}

/// True when `edges` holds `needle` (test-local, so assertions stay loop-free).
fn hasEdge(edges: []const []const u8, needle: []const u8) bool {
    for (edges) |e| {
        if (std.mem.eql(u8, e, needle)) return true;
    }
    return false;
}

/// True when `paths` holds `needle`.
fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    return hasEdge(paths, needle);
}

test "findCycle returns null for acyclic graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/a.zig", .edges = &.{"src/b.zig"} },
        .{ .path = "src/b.zig", .edges = &.{"src/c.zig"} },
        .{ .path = "src/c.zig", .edges = &.{} },
    };
    try std.testing.expect((try findCycle(a, nodes)) == null);
}

// spec: Imports - Detects cycles in the @import graph
test "findCycle detects two-node cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/a.zig", .edges = &.{"src/b.zig"} },
        .{ .path = "src/b.zig", .edges = &.{"src/a.zig"} },
    };
    const cycle = try findCycle(a, nodes);
    try std.testing.expect(cycle != null);
    try std.testing.expect(cycle.?.len >= 2);
}

// spec: Imports - Selects the same cycle regardless of filesystem walk order
test "findCycle selects a stable cycle when node order changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = &[_]Node{
        .{ .path = "src/z.zig", .edges = &.{"src/y.zig"} },
        .{ .path = "src/y.zig", .edges = &.{"src/z.zig"} },
        .{ .path = "src/a.zig", .edges = &.{"src/b.zig"} },
        .{ .path = "src/b.zig", .edges = &.{"src/a.zig"} },
    };
    const second = &[_]Node{
        .{ .path = "src/b.zig", .edges = &.{"src/a.zig"} },
        .{ .path = "src/a.zig", .edges = &.{"src/b.zig"} },
        .{ .path = "src/y.zig", .edges = &.{"src/z.zig"} },
        .{ .path = "src/z.zig", .edges = &.{"src/y.zig"} },
    };
    const first_cycle = (try findCycle(a, first)).?;
    const second_cycle = (try findCycle(a, second)).?;
    try std.testing.expectEqual(@as(usize, 3), first_cycle.len);
    try std.testing.expectEqual(@as(usize, 3), second_cycle.len);
    for (first_cycle, second_cycle) |first_path, second_path| {
        try std.testing.expectEqualStrings(first_path, second_path);
    }
    try std.testing.expectEqualStrings("src/a.zig", first_cycle[0]);
}

// spec: Assertion Discipline - Cycle detection visits a node reached by multiple import paths only once
test "findCycle handles a diamond where two paths reach one node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a -> b, a -> c, b -> d, c -> d: d is reachable by two paths. The DFS marks
    // d black after the first visit, so the second edge into it is a no-op — the
    // white-on-entry invariant (dfs) holds and no false cycle is reported.
    const nodes = &[_]Node{
        .{ .path = "src/a.zig", .edges = &.{ "src/b.zig", "src/c.zig" } },
        .{ .path = "src/b.zig", .edges = &.{"src/d.zig"} },
        .{ .path = "src/c.zig", .edges = &.{"src/d.zig"} },
        .{ .path = "src/d.zig", .edges = &.{} },
    };
    try std.testing.expect(try findCycle(a, nodes) == null);
}

test "findCycle ignores edges to unknown nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/a.zig", .edges = &.{ "src/external.zig", "src/b.zig" } },
        .{ .path = "src/b.zig", .edges = &.{} },
    };
    try std.testing.expect((try findCycle(a, nodes)) == null);
}

test "reachableFrom finds transitively imported files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/main.zig", .edges = &.{"src/a.zig"} },
        .{ .path = "src/a.zig", .edges = &.{"src/b.zig"} },
        .{ .path = "src/b.zig", .edges = &.{} },
        .{ .path = "src/orphan.zig", .edges = &.{} },
    };
    const roots = &[_][]const u8{"src/main.zig"};
    const reached = try reachableFrom(a, nodes, roots);
    try std.testing.expectEqual(@as(usize, 3), reached.len);
    try std.testing.expectEqualStrings("src/a.zig", reached[0]);
    try std.testing.expectEqualStrings("src/b.zig", reached[1]);
    try std.testing.expectEqualStrings("src/main.zig", reached[2]);
}

test "reachableFrom handles multiple roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/r1.zig", .edges = &.{"src/x.zig"} },
        .{ .path = "src/r2.zig", .edges = &.{"src/y.zig"} },
        .{ .path = "src/x.zig", .edges = &.{} },
        .{ .path = "src/y.zig", .edges = &.{} },
        .{ .path = "src/orphan.zig", .edges = &.{} },
    };
    const roots = &[_][]const u8{ "src/r1.zig", "src/r2.zig" };
    const reached = try reachableFrom(a, nodes, roots);
    try std.testing.expectEqual(@as(usize, 4), reached.len);
}

test "reachableFrom handles cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/a.zig", .edges = &.{"src/b.zig"} },
        .{ .path = "src/b.zig", .edges = &.{"src/a.zig"} },
    };
    const roots = &[_][]const u8{"src/a.zig"};
    const reached = try reachableFrom(a, nodes, roots);
    try std.testing.expectEqual(@as(usize, 2), reached.len);
}
