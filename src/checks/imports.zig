const std = @import("std");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const import_graph = @import("../ast/import_graph.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Imports - Detects cycles in the @import graph

/// Entry point for the imports check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    const nodes = try import_graph.build(allocator, project_dir);

    if (nodes.len == 0) {
        ok("no source files to scan", .{});
        return;
    }

    const cycle = import_graph.findCycle(allocator, nodes);
    if (cycle == null) {
        ok("import graph is acyclic ({d} files)", .{nodes.len});
        return;
    }

    fail("imports FAILED — cycle detected", .{});
    for (cycle.?) |p| print("  → {s}\n", .{p});
    print("  fix: extract shared types into a third module, or invert one direction.\n", .{});
    return error.CheckFailed;
}
