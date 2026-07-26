const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    max_params: u32,
    violations: *std.ArrayList(reporter.Violation),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const fns = if (entry.tree) |t| try ast.allFnsFromTree(a, t) else try ast.allFns(a, entry.content);
    for (fns) |f| {
        const runtime_params = f.param_count - f.comptime_param_count;
        if (runtime_params <= ctx.max_params) continue;
        try ctx.violations.append(a, .{
            .check = "function-size",
            .file = entry.rel_path,
            // The offender's line, so the console summary can point straight at
            // the signature instead of naming only the file.
            .line = f.line,
            .message = try std.fmt.allocPrint(
                a,
                "fn {s} has {d} runtime params (+{d} comptime; runtime limit: {d})",
                .{ f.name, runtime_params, f.comptime_param_count, ctx.max_params },
            ),
            .ratchet_key = try std.fmt.allocPrint(a, "{s}|{s}", .{ entry.rel_path, f.name }),
            .metric = runtime_params,
        });
    }
}

/// Entry point for the function-size check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    const project_dir = ctx_param.project_dir;

    if (!cfg.function_size.enabled) {
        ok("function size skipped (disabled in config)", .{});
        return;
    }

    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .max_params = cfg.function_size.max_params,
        .violations = &violations,
    };

    // `src` reuses the shared parsed index; `test` is not indexed, so it
    // still walks (its parses are not shared).
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });
    const test_path = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    try walk.walkZigFiles(allocator, test_path, .{ .display_root = "test" }, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all functions within {d} param limit", .{cfg.function_size.max_params});
        return;
    }

    fail("function size FAILED ({d} fn(s) over {d} param limit)", .{
        violations.items.len,
        cfg.function_size.max_params,
    });
    for (violations.items) |v| reporter.emit(v);
    print(
        "  fix: bundle related runtime parameters into a struct; " ++
            "comptime specialization inputs are excluded.\n",
        .{},
    );
    return error.CheckFailed;
}

// spec: Function Size - Caps parameter count per function
// spec: Function Size - Excludes comptime specialization parameters from the runtime parameter cap

test "visit catches over-budget functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .max_params = 3, .violations = &violations };
    const content =
        \\pub fn ok_fn(a: i32, b: i32, c: i32) void {}
        \\pub fn too_many(a: i32, b: i32, c: i32, d: i32, e: i32) void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit excludes comptime parameters from the runtime cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .max_params = 4, .violations = &violations };
    const content =
        \\fn genericOk(comptime T: type, comptime map: fn (T) T, a: T, b: T, c: T, d: T) void {}
        \\fn runtimeLarge(comptime T: type, a: T, b: T, c: T, d: T, e: T) void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expectEqual(@as(?u64, 5), violations.items[0].metric);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0].message, "+1 comptime") != null);
}

// spec: Function Size - Reports the offending function's source line with the file

test "visit records the offender's line so the summary can point at it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .max_params = 2, .violations = &violations };
    const content =
        \\fn narrow(a: i32) void {}
        \\
        \\fn wide(a: i32, b: i32, c: i32) void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    // file:line, not file alone — the run summary echoes this verbatim.
    try std.testing.expectEqual(@as(?u32, 3), violations.items[0].line);
    try std.testing.expectEqualStrings("src/x.zig", violations.items[0].file.?);
}
