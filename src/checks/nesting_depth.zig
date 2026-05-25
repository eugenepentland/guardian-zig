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

// spec: Nesting Depth - Caps brace-nesting depth inside fn bodies

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
    var depth: u32 = 0;
    var max_depth: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .l_brace => {
                depth += 1;
                if (depth > max_depth) max_depth = depth;
            },
            .r_brace => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
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
