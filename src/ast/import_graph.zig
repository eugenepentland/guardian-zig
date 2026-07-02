const std = @import("std");
const Allocator = std.mem.Allocator;
const walk = @import("../walk.zig");
const ast = @import("parser.zig");

/// One node in the import graph: a source file's outgoing edges (each edge is
/// a normalized rel_path of an importable .zig under the project's src tree).
/// Edges to "std", "builtin", "root", or any path not in the walk set are
/// already filtered out by the builder.
pub const Node = struct {
    path: []const u8,
    edges: []const []const u8,
};

const CollectCtx = struct {
    allocator: Allocator,
    nodes: *std.ArrayListUnmanaged(Node),
};

fn collectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const raw = ast.imports(a, entry.content);
    var edges: std.ArrayListUnmanaged([]const u8) = .empty;
    for (raw) |imp| {
        if (std.mem.eql(u8, imp.path, "std")) continue;
        if (std.mem.eql(u8, imp.path, "builtin")) continue;
        if (std.mem.eql(u8, imp.path, "root")) continue;
        const resolved = if (std.mem.lastIndexOfScalar(u8, entry.rel_path, '/')) |slash| blk: {
            const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ entry.rel_path[0..slash], imp.path });
            break :blk try walk.normalizePath(a, joined);
        } else imp.path;
        try edges.append(a, resolved);
    }

    try ctx.nodes.append(a, .{
        .path = entry.rel_path,
        .edges = try edges.toOwnedSlice(a),
    });
}

/// Errors propagated out of `build`. The walker visitor uses `anyerror` so
/// arbitrary I/O / allocator failures surface; we accept that here.
pub const BuildError = anyerror;

/// Walks `<project_dir>/src/`, parses every .zig file's @import paths, and
/// returns one Node per file. Edges are normalized rel_paths suitable for
/// matching against other Node.path values. Edges that don't resolve to a
/// node in the walk set are still kept (callers filter them).
pub fn build(allocator: Allocator, project_dir: []const u8) BuildError![]const Node {
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    var ctx: CollectCtx = .{ .allocator = allocator, .nodes = &nodes };

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = collectVisit });
    return nodes.toOwnedSlice(allocator);
}

const Color = enum { white, gray, black };

const CycleFinder = struct {
    allocator: Allocator,
    nodes: []const Node,
    colors: []Color,
    stack: std.ArrayListUnmanaged(usize),
    cycle: ?[]const usize,

    fn nodeIndex(self: *CycleFinder, path: []const u8) ?usize {
        for (self.nodes, 0..) |n, i| {
            if (std.mem.eql(u8, n.path, path)) return i;
        }
        return null;
    }

    fn dfs(self: *CycleFinder, idx: usize) void {
        if (self.cycle != null) return;
        self.colors[idx] = .gray;
        self.stack.append(self.allocator, idx) catch return;
        for (self.nodes[idx].edges) |edge| {
            const target = self.nodeIndex(edge) orelse continue;
            switch (self.colors[target]) {
                .white => self.dfs(target),
                .gray => {
                    var loop: std.ArrayListUnmanaged(usize) = .empty;
                    var found_start = false;
                    for (self.stack.items) |s| {
                        if (s == target) found_start = true;
                        if (found_start) loop.append(self.allocator, s) catch return;
                    }
                    loop.append(self.allocator, target) catch return;
                    self.cycle = loop.toOwnedSlice(self.allocator) catch null;
                    return;
                },
                .black => {},
            }
            if (self.cycle != null) return;
        }
        _ = self.stack.pop();
        self.colors[idx] = .black;
    }
};

/// Returns the first cycle found in the graph, as an ordered list of node
/// paths (start == end). Null if the graph is acyclic.
pub fn findCycle(allocator: Allocator, nodes: []const Node) ?[]const []const u8 {
    if (nodes.len == 0) return null;
    const colors = allocator.alloc(Color, nodes.len) catch return null;
    @memset(colors, .white);
    var finder: CycleFinder = .{
        .allocator = allocator,
        .nodes = nodes,
        .colors = colors,
        .stack = .empty,
        .cycle = null,
    };
    for (nodes, 0..) |_, i| {
        if (finder.colors[i] == .white) finder.dfs(i);
        if (finder.cycle != null) break;
    }
    const indices = finder.cycle orelse return null;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (indices) |idx| out.append(allocator, nodes[idx].path) catch return null;
    return out.toOwnedSlice(allocator) catch null;
}

/// Returns the set of node paths reachable from any of `roots` via BFS.
/// Roots that don't exist in the node set are silently skipped. The
/// returned slice is sorted for stable output.
pub fn reachableFrom(allocator: Allocator, nodes: []const Node, roots: []const []const u8) Allocator.Error![]const []const u8 {
    var visited = try allocator.alloc(bool, nodes.len);
    @memset(visited, false);

    var queue: std.ArrayListUnmanaged(usize) = .empty;
    for (roots) |r| {
        for (nodes, 0..) |n, i| {
            if (std.mem.eql(u8, n.path, r) and !visited[i]) {
                visited[i] = true;
                try queue.append(allocator, i);
                break;
            }
        }
    }

    while (queue.items.len > 0) {
        const idx = queue.orderedRemove(0);
        for (nodes[idx].edges) |edge| {
            for (nodes, 0..) |n, j| {
                if (std.mem.eql(u8, n.path, edge) and !visited[j]) {
                    visited[j] = true;
                    try queue.append(allocator, j);
                    break;
                }
            }
        }
    }

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (nodes, 0..) |n, i| {
        if (visited[i]) try out.append(allocator, n.path);
    }
    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, lessThan);
    return slice;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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
    try std.testing.expect(findCycle(a, nodes) == null);
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
    const cycle = findCycle(a, nodes);
    try std.testing.expect(cycle != null);
    try std.testing.expect(cycle.?.len >= 2);
}

test "findCycle ignores edges to unknown nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/a.zig", .edges = &.{ "src/external.zig", "src/b.zig" } },
        .{ .path = "src/b.zig", .edges = &.{} },
    };
    try std.testing.expect(findCycle(a, nodes) == null);
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
