const std = @import("std");
const Allocator = std.mem.Allocator;
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const import_graph = @import("../ast/import_graph.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// Returns the set of root paths to use for reachability. If the user
/// configured `[orphan_files] roots`, those win; otherwise default to
/// every node whose path is a top-level src/* file (no further slash
/// after "src/").
fn defaultRoots(allocator: Allocator, nodes: []const import_graph.Node) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (nodes) |n| {
        if (!std.mem.startsWith(u8, n.path, "src/")) continue;
        const rest = n.path["src/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null) {
            try out.append(allocator, n.path);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Returns the orphan paths: nodes not reachable from any of `roots`.
/// Returned slice is sorted for stable output.
pub fn findOrphans(
    allocator: Allocator,
    nodes: []const import_graph.Node,
    roots: []const []const u8,
) Allocator.Error![]const []const u8 {
    const reached = try import_graph.reachableFrom(allocator, nodes, roots);
    var orphans: std.ArrayListUnmanaged([]const u8) = .empty;
    for (nodes) |n| {
        var found = false;
        for (reached) |r| {
            if (std.mem.eql(u8, n.path, r)) {
                found = true;
                break;
            }
        }
        if (!found) try orphans.append(allocator, n.path);
    }
    const slice = try orphans.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, lessThan);
    return slice;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Entry point for the orphan-files check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.orphan_files;

    if (!cfg.enabled) {
        ok("orphan-files disabled by config", .{});
        return;
    }

    const nodes = try import_graph.build(allocator, project_dir);
    if (nodes.len == 0) {
        ok("no source files to scan", .{});
        return;
    }

    const roots = if (cfg.roots.len > 0) cfg.roots else try defaultRoots(allocator, nodes);
    if (roots.len == 0) {
        fail("orphan-files FAILED — no roots discovered (no top-level src/*.zig files)", .{});
        print("  fix: set [orphan_files] roots = [\"src/main.zig\"] in guardian.toml.\n", .{});
        return error.CheckFailed;
    }

    const orphans = try findOrphans(allocator, nodes, roots);
    if (orphans.len == 0) {
        ok("all {d} source files reachable from {d} root(s)", .{ nodes.len, roots.len });
        return;
    }

    fail("orphan-files FAILED ({d} unreachable file(s))", .{orphans.len});
    for (orphans) |p| print("  {s}\n", .{p});
    print("  fix: import the file from a reachable module, or add it to [orphan_files] roots in guardian.toml.\n", .{});
    return error.CheckFailed;
}

// spec: Orphan Files - Reports .zig files under src/ unreachable from any configured root via @import

test "defaultRoots picks only top-level src files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]import_graph.Node{
        .{ .path = "src/main.zig", .edges = &.{} },
        .{ .path = "src/walk.zig", .edges = &.{} },
        .{ .path = "src/checks/foo.zig", .edges = &.{} },
        .{ .path = "src/cli/registry.zig", .edges = &.{} },
    };
    const roots = try defaultRoots(a, nodes);
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings("src/main.zig", roots[0]);
    try std.testing.expectEqualStrings("src/walk.zig", roots[1]);
}

test "findOrphans flags unreachable files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]import_graph.Node{
        .{ .path = "src/main.zig", .edges = &.{"src/used.zig"} },
        .{ .path = "src/used.zig", .edges = &.{} },
        .{ .path = "src/orphan.zig", .edges = &.{} },
    };
    const roots = &[_][]const u8{"src/main.zig"};
    const orphans = try findOrphans(a, nodes, roots);
    try std.testing.expectEqual(@as(usize, 1), orphans.len);
    try std.testing.expectEqualStrings("src/orphan.zig", orphans[0]);
}

test "findOrphans returns empty when everything reachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]import_graph.Node{
        .{ .path = "src/main.zig", .edges = &.{ "src/a.zig", "src/b.zig" } },
        .{ .path = "src/a.zig", .edges = &.{} },
        .{ .path = "src/b.zig", .edges = &.{} },
    };
    const roots = &[_][]const u8{"src/main.zig"};
    const orphans = try findOrphans(a, nodes, roots);
    try std.testing.expectEqual(@as(usize, 0), orphans.len);
}

test "findOrphans handles multiple roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]import_graph.Node{
        .{ .path = "src/r1.zig", .edges = &.{"src/x.zig"} },
        .{ .path = "src/r2.zig", .edges = &.{} },
        .{ .path = "src/x.zig", .edges = &.{} },
        .{ .path = "src/orphan.zig", .edges = &.{} },
    };
    const roots = &[_][]const u8{ "src/r1.zig", "src/r2.zig" };
    const orphans = try findOrphans(a, nodes, roots);
    try std.testing.expectEqual(@as(usize, 1), orphans.len);
    try std.testing.expectEqualStrings("src/orphan.zig", orphans[0]);
}
