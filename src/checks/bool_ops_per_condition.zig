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
    violations: *std.ArrayList(reporter.Violation),
    max_ops: u32,
};

/// Pure-function entry: scans `content` for `if (...)` / `while (...)`
/// conditions whose `and`/`or`/`!` count exceeds `max_ops`.
pub fn analyzeContentWithLimit(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
    max_ops: u32,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
        .max_ops = max_ops,
    };
    try scan(&ctx, content);
    return reporter.flatLines(allocator, violations.items);
}

/// Pure-function entry using the framework default (3) for tests.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const []const u8 {
    return analyzeContentWithLimit(allocator, rel_path, content, 3);
}

fn scan(ctx: *ScanCtx, z: [:0]const u8) Allocator.Error!void {
    const a = ctx.allocator;
    var tok = std.zig.Tokenizer.init(z);

    // Attribute each condition to the most recent `fn <name>` so item 5 can key
    // a per-fn ceiling (best-effort: a condition outside any fn falls back to
    // the file). Tracking the name never affects the emitted message text.
    var current_fn: ?[]const u8 = null;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .keyword_fn) {
            current_fn = fnNameAfter(&tok, z);
            continue;
        }
        if (t.tag != .keyword_if and t.tag != .keyword_while) continue;
        const start_byte = t.loc.start;
        const lparen = tok.next();
        if (lparen.tag != .l_paren) continue;
        const ops = countOpsUntilMatchingRparen(&tok);
        if (ops > ctx.max_ops) {
            try ctx.violations.append(a, .{
                .check = "bool-ops-per-condition",
                .file = ctx.rel_path,
                .line = lineOf(z, start_byte),
                .message = try std.fmt.allocPrint(a, "condition has {d} boolean ops (cap {d})", .{ ops, ctx.max_ops }),
                .ratchet_key = try ratchetKey(a, ctx.rel_path, current_fn),
                .metric = ops,
            });
        }
    }
}

/// The identifier immediately after a `fn` keyword (a named fn), or null for an
/// anonymous fn type. Consumes the name token; callers only care about `if`/
/// `while`, so consuming an identifier here is harmless.
fn fnNameAfter(tok: *std.zig.Tokenizer, z: []const u8) ?[]const u8 {
    const nt = tok.next();
    return if (nt.tag == .identifier) z[nt.loc.start..nt.loc.end] else null;
}

/// Ratchet subject: `<file>|<fn>` when the enclosing fn is known, else `<file>`.
fn ratchetKey(a: Allocator, rel_path: []const u8, current_fn: ?[]const u8) Allocator.Error![]const u8 {
    if (current_fn) |name| return std.fmt.allocPrint(a, "{s}|{s}", .{ rel_path, name });
    return a.dupe(u8, rel_path);
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
    violations: *std.ArrayList(reporter.Violation),
    max_ops: u32,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
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
    var violations: std.ArrayList(reporter.Violation) = .empty;
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
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: split into nested/sequential ifs, or extract into a named bool.\n", .{});
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

test "analyzeContentWithLimit honors a custom cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Two ops: under the default 3, but over a tightened cap of 1.
    const out = try analyzeContentWithLimit(arena.allocator(), "src/x.zig",
        \\fn x(a: bool, b: bool, c: bool) void {
        \\    if (a and b or c) {}
        \\}
    , 1);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
