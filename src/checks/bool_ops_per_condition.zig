const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
    max_ops: u32,
};

/// Pure-function entry: scans `content` for `if (...)` / `while (...)`
/// conditions whose `and`/`or`/`!` count exceeds `max_ops`.
pub fn analyzeContentWithLimit(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    max_ops: u32,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
        .max_ops = max_ops,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

/// Pure-function entry using the framework default (3) for tests.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    return analyzeContentWithLimit(allocator, rel_path, content, 3);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_if and t.tag != .keyword_while) continue;
        const start_byte = t.loc.start;
        const lparen = tok.next();
        if (lparen.tag != .l_paren) continue;
        const ops = countOpsUntilMatchingRparen(&tok);
        if (ops > ctx.max_ops) {
            const line = lineOf(z, start_byte);
            const msg = try std.fmt.allocPrint(
                a,
                "{s}:{d}: condition has {d} boolean ops (cap {d})",
                .{ ctx.rel_path, line, ops, ctx.max_ops },
            );
            try ctx.violations.append(a, msg);
        }
    }
}

fn countOpsUntilMatchingRparen(tok: *std.zig.Tokenizer) u32 {
    var depth: u32 = 1;
    var ops: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return ops;
        switch (t.tag) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return ops;
            },
            .keyword_and, .keyword_or, .bang => ops += 1,
            else => {},
        }
    }
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    max_ops: u32,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
        .max_ops = ctx.max_ops,
    };
    try scan(&local, entry.content);
}

/// Entry point for the bool-ops-per-condition check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const cap = ctx.cfg.bool_ops.max_ops;
    if (!ctx.cfg.bool_ops.enabled) {
        reporter.ok("bool-ops-per-condition disabled by config", .{});
        return;
    }
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .max_ops = cap,
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("bool-ops-per-condition: every condition has <= {d} boolean ops", .{cap});
        return;
    }
    reporter.fail("bool-ops-per-condition FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: extract the condition into a named bool, or split into nested ifs.\n", .{});
    return error.CheckFailed;
}

// spec: Complexity Bounds - Caps boolean operators per condition

test "analyzeContent flags 4-op condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn x(a: bool, b: bool, c: bool, d: bool, e: bool) void {
        \\    if (a and b and c and d and e) {}
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows 2-op condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn x(a: bool, b: bool, c: bool) void {
        \\    if (a and b or c) {}
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent counts ! (negation)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn x(a: bool, b: bool, c: bool, d: bool) void {
        \\    if (!a and !b and !c and !d) {}
        \\}
    );
    try std.testing.expect(out.len >= 1);
}
