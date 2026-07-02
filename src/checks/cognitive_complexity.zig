const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const ast = @import("../ast/parser.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    threshold: u32,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Branch-keyword tokens that contribute +1 to a function's score. We
/// approximate true Sonar-style nesting cost with a flat count: this
/// under-counts deeply-nested code but never over-counts. Threshold tuning
/// compensates.
fn isBranchTag(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .keyword_if,
        .keyword_while,
        .keyword_for,
        .keyword_switch,
        .keyword_catch,
        .keyword_and,
        .keyword_or,
        => true,
        else => false,
    };
}

/// Score a slice of pre-tokenized token tags. Pure — used by both the
/// per-file walker and the inline tests.
fn scoreTokens(tags: []const std.zig.Token.Tag) u32 {
    var score: u32 = 0;
    for (tags) |t| {
        if (isBranchTag(t)) score += 1;
    }
    return score;
}

fn scoreTree(ctx: *ScanCtx, rel_path: []const u8, tree_ptr: *const std.zig.Ast) !void {
    const a = ctx.allocator;
    var tree = tree_ptr.*;
    const all_tags = tree.tokens.items(.tag);

    // collectDecls descends into container members, so methods nested in
    // structs are scored too (fixes the same rootDecls-only blind spot P0-2
    // fixed for the other checks).
    for (try ast.collectDecls(a, &tree)) |decl| {
        if (tree.nodeTag(decl) != .fn_decl) continue;
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);

        const first = tree.firstToken(decl);
        const last = tree.lastToken(decl);
        const score = scoreTokens(all_tags[first .. last + 1]);

        if (score > ctx.threshold) {
            const msg = try std.fmt.allocPrint(
                a,
                "{s}: fn {s} cognitive complexity {d} (limit: {d})",
                .{ rel_path, name, score, ctx.threshold },
            );
            try ctx.violations.append(a, msg);
        }
    }
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    // Reuse the shared parse when the index provides it; only parse standalone.
    if (entry.tree) |t| {
        try scoreTree(ctx, entry.rel_path, t);
    } else {
        var tree = try std.zig.Ast.parse(ctx.allocator, entry.content, .zig);
        try scoreTree(ctx, entry.rel_path, &tree);
    }
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

    // `src` reuses the shared index's cached file contents; `test` is not
    // indexed, so it still walks.
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });
    const test_path = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    try walk.walkZigFiles(allocator, test_path, .{ .display_root = "test" }, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all functions within complexity {d}", .{ctx.threshold});
        return;
    }

    fail("cognitive complexity FAILED ({d} fn(s) over {d})", .{ violations.items.len, ctx.threshold });
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: extract helpers; reduce nested control flow.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn scoreSource(allocator: std.mem.Allocator, source: []const u8) !u32 {
    const z = try allocator.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(allocator, z, .zig);
    const tags = tree.tokens.items(.tag);
    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) != .fn_decl) continue;
        const first = tree.firstToken(decl);
        const last = tree.lastToken(decl);
        return scoreTokens(tags[first .. last + 1]);
    }
    return 0;
}

// spec: Cognitive Complexity - Caps per-function cognitive complexity score

test "scoreTokens scores trivial fn as 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(u32, 0), try scoreSource(a, "fn x() void {}"));
}

test "scoreTokens counts branches additively" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(
        @as(u32, 2),
        try scoreSource(a, "fn x() void { if (true) {} if (false) {} }"),
    );
    try testing.expectEqual(
        @as(u32, 3),
        try scoreSource(a, "fn y() void { if (true) { if (true) { if (true) {} } } }"),
    );
}

test "scoreTokens counts every branch keyword once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
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
    try testing.expectEqual(@as(u32, 4), try scoreSource(a, body));
}

test "visit scores every function in a file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .threshold = 1, .violations = &violations };
    const content =
        \\fn small() void { if (true) {} }
        \\fn big() void { if (a) {} if (b) {} if (c) {} }
        \\fn empty() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try testing.expectEqual(@as(usize, 1), violations.items.len);
}
test "visit scores methods nested inside a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .threshold = 1, .violations = &violations };
    const content =
        \\pub const S = struct {
        \\    pub fn big(self: S) void { _ = self; if (a) {} if (b) {} if (c) {} }
        \\};
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try testing.expectEqual(@as(usize, 1), violations.items.len);
}
