const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    max_per_file: u32,
    exclude: []const []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// True when `rel_path` matches any exclude pattern (a legitimate
/// variadic/formatting boundary exempt from the cap).
fn isExcluded(rel_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (walk.matchGlob(rel_path, p)) return true;
    }
    return false;
}

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

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isExcluded(entry.rel_path, ctx.exclude)) return;
    const a = ctx.allocator;
    const count = countAnytype(a, entry.content);
    if (count > ctx.max_per_file) {
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: {d} `anytype` parameters (limit: {d})",
            .{ entry.rel_path, count, ctx.max_per_file },
        );
        try ctx.violations.append(a, msg);
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
        .exclude = cfg.anytype_budget.exclude,
        .violations = &violations,
    };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("anytype budget within limit (max {d} per file)", .{ctx.max_per_file});
        return;
    }

    fail("anytype budget FAILED ({d} file(s) over limit)", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: replace anytype with comptime-typed generics where possible.\n", .{});
    return error.CheckFailed;
}

// spec: Anytype Budget - Caps anytype parameter count per file
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

// spec: Anytype Budget - Skips files matching the exclude patterns
test "isExcluded matches files against the exclude patterns" {
    try std.testing.expect(isExcluded("src/reporter.zig", &.{"reporter.zig"}));
    try std.testing.expect(isExcluded("src/testing/golden_runner.zig", &.{"testing/golden_runner.zig"}));
    try std.testing.expect(!isExcluded("src/checks/spec.zig", &.{"reporter.zig"}));
    try std.testing.expect(!isExcluded("src/reporter.zig", &.{}));
}
