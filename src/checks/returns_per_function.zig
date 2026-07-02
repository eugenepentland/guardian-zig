const std = @import("std");
const ast = @import("../ast/parser.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Complexity Bounds - Caps return statements per function body

/// Pure-function entry: scans `content` for fns whose body contains
/// more than `cap` `return` keywords.
pub fn analyzeContentWithLimit(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    cap: u32,
    tree: ?*const std.zig.Ast,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = (if (tree) |t| ast.fnDeclInfosFromTree(a, t) else ast.fnDeclInfos(a, content)) catch return violations.toOwnedSlice(allocator);

    for (fns) |fn_info| {
        const count = try countReturns(a, fn_info.body_text);
        if (count > cap) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}:{d}: fn '{s}' has {d} return statements (cap {d})",
                .{ rel_path, fn_info.start_line, fn_info.name, count, cap },
            );
            try violations.append(allocator, msg);
        }
    }
    return violations.toOwnedSlice(allocator);
}

/// Pure-function entry using the framework default (3) for tests.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    return analyzeContentWithLimit(allocator, rel_path, content, 3, null);
}

fn countReturns(arena: Allocator, body: []const u8) Allocator.Error!u32 {
    const z = try arena.dupeZ(u8, body);
    var tok = std.zig.Tokenizer.init(z);
    var count: u32 = 0;
    var fn_depth: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_fn => fn_depth += 1,
            .keyword_return => if (fn_depth == 0) {
                count += 1;
            },
            .l_brace, .r_brace => {},
            else => {},
        }
        // Reset fn_depth when we exit nested fns. Approximate by tracking
        // braces only after a `fn` keyword has been seen.
        if (t.tag == .r_brace and fn_depth > 0) fn_depth -|= 1;
    }
    return count;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    cap: u32,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeContentWithLimit(ctx.allocator, entry.rel_path, entry.content, ctx.cap, entry.tree);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the returns-per-function check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const cap = ctx.cfg.returns_per_fn.max_returns;
    if (!ctx.cfg.returns_per_fn.enabled) {
        reporter.ok("returns-per-function disabled by config", .{});
        return;
    }
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .cap = cap,
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("returns-per-function: every fn has <= {d} returns", .{cap});
        return;
    }
    reporter.fail("returns-per-function FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: collapse early returns into a guard clause + single tail return, or split the fn.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags fn with 4 returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn classify(x: u32) u8 {
        \\    if (x == 0) return 0;
        \\    if (x == 1) return 1;
        \\    if (x == 2) return 2;
        \\    if (x == 3) return 3;
        \\    return 99;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows fn with 2 returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn classify(x: u32) u8 {
        \\    if (x == 0) return 0;
        \\    return 1;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
