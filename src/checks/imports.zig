const std = @import("std");
const Allocator = std.mem.Allocator;
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Imports - Detects cycles in the @import graph

/// One node in the import graph: a source file's outgoing edges.
const Node = struct {
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

const Color = enum { white, gray, black };

const CycleFinder = struct {
    allocator: Allocator,
    nodes: []const Node,
    /// Colors keyed by index into `nodes`.
    colors: []Color,
    /// Stack of indices currently in DFS recursion.
    stack: std.ArrayListUnmanaged(usize),
    /// First cycle found, as a list of node indices forming the loop.
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
                    // Found a back-edge — extract the cycle from the stack.
                    var loop: std.ArrayListUnmanaged(usize) = .empty;
                    var found_start = false;
                    for (self.stack.items) |s| {
                        if (s == target) found_start = true;
                        if (found_start) loop.append(self.allocator, s) catch return;
                    }
                    loop.append(self.allocator, target) catch return; // close the loop
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
fn findCycle(allocator: Allocator, nodes: []const Node) ?[]const []const u8 {
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

/// Entry point for the imports check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    var collect_ctx: CollectCtx = .{ .allocator = allocator, .nodes = &nodes };

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &collect_ctx, .visit = collectVisit });

    if (nodes.items.len == 0) {
        ok("no source files to scan", .{});
        return;
    }

    const cycle = findCycle(allocator, nodes.items);
    if (cycle == null) {
        ok("import graph is acyclic ({d} files)", .{nodes.items.len});
        return;
    }

    fail("imports FAILED — cycle detected", .{});
    for (cycle.?) |p| print("  → {s}\n", .{p});
    print("  fix: extract shared types into a third module, or invert one direction.\n", .{});
    std.process.exit(1);
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

test "findCycle detects three-node cycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]Node{
        .{ .path = "src/a.zig", .edges = &.{"src/b.zig"} },
        .{ .path = "src/b.zig", .edges = &.{"src/c.zig"} },
        .{ .path = "src/c.zig", .edges = &.{"src/a.zig"} },
    };
    const cycle = findCycle(a, nodes);
    try std.testing.expect(cycle != null);
    try std.testing.expect(cycle.?.len >= 3);
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
