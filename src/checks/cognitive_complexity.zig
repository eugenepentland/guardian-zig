const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Cognitive Complexity - Caps per-function cognitive complexity score

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    threshold: u32,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Score a single function body span. We count branch keywords
/// (if/while/for/switch/catch) +1 each, plus +1 per `and`/`or` token.
/// True Sonar-style nesting depth requires AST traversal; we approximate
/// with a flat count, which under-counts deeply-nested code but never
/// over-counts. Threshold tuning compensates.
fn scoreBody(allocator: std.mem.Allocator, body: []const u8) u32 {
    const z = allocator.dupeZ(u8, body) catch return 0;
    var tok = std.zig.Tokenizer.init(z);
    var score: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_if,
            .keyword_while,
            .keyword_for,
            .keyword_switch,
            .keyword_catch,
            => score += 1,
            .keyword_and, .keyword_or => score += 1,
            else => {},
        }
    }
    return score;
}

fn visitFile(ctx: *ScanCtx, rel_path: []const u8, content: []const u8) void {
    const a = ctx.allocator;
    const z = a.dupeZ(u8, content) catch return;
    var tree = std.zig.Ast.parse(a, z, .zig) catch return;
    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) != .fn_decl) continue;
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);

        const first = tree.firstToken(decl);
        const last = tree.lastToken(decl);
        const start = tree.tokenStart(first);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        const score = scoreBody(a, z[start..end]);
        if (score > ctx.threshold) {
            const msg = std.fmt.allocPrint(
                a,
                "{s}: fn {s} cognitive complexity {d} (limit: {d})",
                .{ rel_path, name, score, ctx.threshold },
            ) catch continue;
            ctx.violations.append(a, msg) catch {};
        }
    }
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    visitFile(ctx, entry.rel_path, entry.content);
}

/// Entry point for the cognitive-complexity check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg;

    if (!cfg.complexity.enabled) {
        ok("cognitive complexity skipped (disabled in config)", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .threshold = cfg.complexity.max_score,
        .violations = &violations,
    };

    const dirs = [_][]const u8{ "src", "test" };
    for (&dirs) |dir| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir });
        walk.walkZigFiles(allocator, dir_path, dir, .{}, .{ .ctx = &ctx, .visit = visit }) catch {};
    }

    if (violations.items.len == 0) {
        ok("all functions within complexity {d}", .{ctx.threshold});
        return;
    }

    fail("cognitive complexity FAILED ({d} fn(s) over {d})", .{ violations.items.len, ctx.threshold });
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: extract helpers; reduce nested control flow.\n", .{});
    std.process.exit(1);
}

test "scoreBody scores trivial fn as 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "fn x() void {}";
    try std.testing.expectEqual(@as(u32, 0), scoreBody(a, body));
}

test "scoreBody counts branches additively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const two = "fn x() void { if (true) {} if (false) {} }";
    const three = "fn y() void { if (true) { if (true) { if (true) {} } } }";
    try std.testing.expectEqual(@as(u32, 2), scoreBody(a, two));
    try std.testing.expectEqual(@as(u32, 3), scoreBody(a, three));
}

test "scoreBody counts branch keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\fn x() void {
        \\    if (true) {}
        \\    while (false) {}
        \\    for (0..1) |_| {}
        \\    switch (1) { else => {} }
        \\}
    ;
    // 4 branch keywords at depth 0 → score 4
    try std.testing.expectEqual(@as(u32, 4), scoreBody(a, body));
}
