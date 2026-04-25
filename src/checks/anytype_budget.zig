const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Anytype Budget - Caps anytype parameter count per file

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    max_per_file: u32,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Counts `anytype` parameter tokens in source. Tokenizer-based so it
/// correctly skips strings and comments.
fn countAnytype(allocator: std.mem.Allocator, content: []const u8) u32 {
    const z = allocator.dupeZ(u8, content) catch return 0;
    var tok = std.zig.Tokenizer.init(z);
    var count: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .keyword_anytype) count += 1;
    }
    return count;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const count = countAnytype(a, entry.content);
    if (count > ctx.max_per_file) {
        const msg = std.fmt.allocPrint(
            a,
            "{s}: {d} `anytype` parameters (limit: {d})",
            .{ entry.rel_path, count, ctx.max_per_file },
        ) catch return;
        ctx.violations.append(a, msg) catch {};
    }
}

/// Entry point for the anytype-budget check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg;

    if (!cfg.anytype_budget.enabled) {
        ok("anytype budget skipped (disabled in config)", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .max_per_file = cfg.anytype_budget.max_per_file,
        .violations = &violations,
    };

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit }) catch {};

    if (violations.items.len == 0) {
        ok("anytype budget within limit (max {d} per file)", .{ctx.max_per_file});
        return;
    }

    fail("anytype budget FAILED ({d} file(s) over limit)", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: replace anytype with comptime-typed generics where possible.\n", .{});
    std.process.exit(1);
}

test "countAnytype counts only the keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\pub fn one(args: anytype) void {}
        \\pub fn two(a: anytype, b: anytype) void {}
        \\const s = "anytype";
    ;
    // 3 anytype tokens total (1 + 2; string literal not counted)
    try std.testing.expectEqual(@as(u32, 3), countAnytype(a, content));
}
