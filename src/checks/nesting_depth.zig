const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const config_mod = @import("../config.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    cfg: config_mod.NestingDepthCfg,
};

/// Returns the maximum brace depth observed inside `body_text`. The
/// caller passes the body slice including the outer `{` and `}` from
/// `ast.fnDeclInfos.body_text`. The body's own opening `{` is depth 1;
/// each nested block adds 1.
///
/// Tokenizer-based to skip strings and comments correctly. Allocator
/// failure during tokenizer init returns 0 (treated as no violation).
fn maxNestingDepth(allocator: std.mem.Allocator, body_text: []const u8) u32 {
    const z = allocator.dupeZ(u8, body_text) catch return 0;
    defer allocator.free(z);
    var tok = std.zig.Tokenizer.init(z);
    // Data-literal braces (`.{ ... }`, `Foo{ ... }`, `[_]u8{ ... }`) are not
    // control-flow nesting — counting them punished declarative data. Track,
    // per open brace, whether it counted, so the matching close stays balanced
    // even when literals and blocks nest inside each other.
    var counted: std.ArrayListUnmanaged(bool) = .empty;
    defer counted.deinit(allocator);
    var depth: u32 = 0;
    var max_depth: u32 = 0;
    var prev_tag: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .l_brace => {
                const is_literal = prev_tag == .period or prev_tag == .identifier or prev_tag == .r_bracket;
                counted.append(allocator, !is_literal) catch return max_depth;
                if (!is_literal) {
                    depth += 1;
                    if (depth > max_depth) max_depth = depth;
                }
            },
            .r_brace => {
                if (counted.pop()) |was_counted| {
                    if (was_counted and depth > 0) depth -= 1;
                }
            },
            else => {},
        }
        prev_tag = t.tag;
    }
    return max_depth;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.fnDeclInfosFromTree(a, t) else try ast.fnDeclInfos(a, entry.content);
    for (fns) |f| {
        const depth = maxNestingDepth(a, f.body_text);
        if (depth <= ctx.cfg.max_depth) continue;
        const msg = try std.fmt.allocPrint(
            a,
            "{s}:{d}: fn {s} reaches nesting depth {d} (cap {d})",
            .{ entry.rel_path, f.start_line, f.name, depth, ctx.cfg.max_depth },
        );
        try ctx.violations.append(a, msg);
    }
}

/// Pure-function entry: scans `content` and returns violation lines
/// (allocator-owned). Empty slice = pass.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
    cfg: config_mod.NestingDepthCfg,
) std.mem.Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };
    visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = content }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return violations.toOwnedSlice(allocator);
}

/// Entry point for the nesting-depth check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.nesting_depth;

    if (!cfg.enabled) {
        ok("nesting-depth disabled by config", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all functions within nesting depth {d}", .{cfg.max_depth});
        return;
    }

    fail("nesting depth FAILED ({d} fn(s) over depth {d})", .{ violations.items.len, cfg.max_depth });
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: extract nested blocks into helper fns, invert conditions to early-return, or raise [nesting_depth] max_depth.\n", .{});
    return error.CheckFailed;
}

// spec: Nesting Depth - Caps brace-nesting depth inside fn bodies

test "maxNestingDepth flat body is depth 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 1), maxNestingDepth(arena.allocator(), "{ return; }"));
}

test "maxNestingDepth nested if reaches 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 2), maxNestingDepth(arena.allocator(), "{ if (x) { return; } }"));
}
test "maxNestingDepth ignores data-literal braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A nested anonymous struct literal is data, not control-flow nesting.
    try std.testing.expectEqual(@as(u32, 1), maxNestingDepth(a, "{ const c = .{ .a = .{ .b = 1 } }; }"));
    // Typed struct/array literals likewise don't add depth.
    try std.testing.expectEqual(@as(u32, 1), maxNestingDepth(a, "{ const c = Foo{ .a = 1 }; }"));
    // Control-flow still counts through/around a literal.
    try std.testing.expectEqual(@as(u32, 2), maxNestingDepth(a, "{ if (x) { const c = .{ .a = 1 }; } }"));
}

test "maxNestingDepth deeply nested reaches 4" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 4), maxNestingDepth(arena.allocator(), "{ if (a) { while (b) { for (c) |_| { return; } } } }"));
}

test "maxNestingDepth ignores braces in strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 1), maxNestingDepth(arena.allocator(), "{ const s = \"{{nope}}\"; _ = s; }"));
}

test "visit flags fn over depth cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_depth = 2 },
    };
    const content =
        \\fn deep() void {
        \\    if (true) {
        \\        if (false) {
        \\            return;
        \\        }
        \\    }
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows fn at the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_depth = 3 },
    };
    const content =
        \\fn ok_fn() void {
        \\    if (true) {
        \\        if (false) {
        \\            return;
        \\        }
        \\    }
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
