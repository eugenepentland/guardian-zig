const std = @import("std");
const walk = @import("../walk.zig");
const config_mod = @import("../config.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const ast = @import("../ast/parser.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const BoundaryCtx = struct {
    allocator: std.mem.Allocator,
    rules: []const config_mod.BoundaryRule,
    violations: *std.ArrayList([]const u8),
};

fn boundaryVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *BoundaryCtx = @ptrCast(@alignCast(raw_ctx));
    const imports = try extractImports(ctx.allocator, entry.content, entry.rel_path);
    for (ctx.rules) |rule| {
        if (!walk.matchGlob(entry.rel_path, rule.module_pattern)) continue;
        try recordRuleViolations(ctx, entry.rel_path, imports, rule);
    }
}

fn recordRuleViolations(
    ctx: *BoundaryCtx,
    rel_path: []const u8,
    imports: []const []const u8,
    rule: config_mod.BoundaryRule,
) !void {
    for (imports) |imp| {
        for (rule.forbidden_imports) |f| {
            if (std.mem.indexOf(u8, imp, f) == null) continue;
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "{s}: forbidden import '{s}' (rule: {s})",
                .{ rel_path, imp, rule.module_pattern },
            );
            try ctx.violations.append(ctx.allocator, msg);
        }
    }
}

/// Entry point for the boundaries check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    const project_dir = ctx_param.project_dir;

    if (cfg.boundary_rules.len == 0) {
        ok("no boundary rules configured", .{});
        return;
    }

    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: BoundaryCtx = .{
        .allocator = allocator,
        .rules = cfg.boundary_rules,
        .violations = &violations,
    };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = boundaryVisit });

    if (violations.items.len == 0) {
        ok("all imports comply with boundary rules", .{});
        return;
    }

    fail("boundary check FAILED ({d} violation(s))", .{violations.items.len});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    return error.CheckFailed;
}

fn extractImports(allocator: std.mem.Allocator, content: []const u8, file_path: []const u8) ![]const []const u8 {
    const raw_imports = ast.imports(allocator, content);
    var resolved: std.ArrayList([]const u8) = .empty;
    for (raw_imports) |imp| {
        if (std.mem.eql(u8, imp.path, "std")) continue;
        if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |dir_end| {
            const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ file_path[0..dir_end], imp.path });
            try resolved.append(allocator, try walk.normalizePath(allocator, joined));
        } else {
            try resolved.append(allocator, imp.path);
        }
    }
    return resolved.toOwnedSlice(allocator);
}

// spec: Boundaries - Extracts @import paths from source files and normalizes relative paths
// spec: Boundaries - Matches file paths against glob and prefix boundary patterns
// spec: Boundaries - Checks against boundary rules defined in guardian.toml
// spec: Boundaries - Reports forbidden import violations

test "extractImports resolves paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const std = @import("std");
        \\const shell = @import("shell.zig");
        \\const parser = @import("../spec/parser.zig");
    ;
    const imports = try extractImports(a, content, "src/stages/foo.zig");
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    try std.testing.expectEqualStrings("src/stages/shell.zig", imports[0]);
    try std.testing.expectEqualStrings("src/spec/parser.zig", imports[1]);
}

test "boundaryVisit detects violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = &[_]config_mod.BoundaryRule{
        .{ .module_pattern = "src/core/*", .forbidden_imports = &.{"utils"} },
    };
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: BoundaryCtx = .{ .allocator = a, .rules = rules, .violations = &violations };
    try walk.walkZigFiles(a, "test-project/src", .{ .display_root = "src" }, .{ .ctx = &ctx, .visit = boundaryVisit });
    try std.testing.expect(violations.items.len > 0);
}
