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
    violations: *std.ArrayListUnmanaged(reporter.Violation),
    cfg: config_mod.FunctionLengthCfg,
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.fnDeclInfosFromTree(a, t) else try ast.fnDeclInfos(a, entry.content);
    for (fns) |f| {
        if (f.line_count <= ctx.cfg.max_lines) continue;
        try ctx.violations.append(a, .{
            .check = "function-length",
            .file = entry.rel_path,
            .line = f.start_line,
            .message = try std.fmt.allocPrint(
                a,
                "fn {s} is {d} lines (cap {d})",
                .{ f.name, f.line_count, ctx.cfg.max_lines },
            ),
            .ratchet_key = try std.fmt.allocPrint(a, "{s}|{s}", .{ entry.rel_path, f.name }),
            .metric = f.line_count,
        });
    }
}

/// Pure-function entry: scans `content` and returns violation lines
/// (allocator-owned). Empty slice = pass.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
    cfg: config_mod.FunctionLengthCfg,
) std.mem.Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };
    try visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = content });
    return reporter.flatLines(allocator, violations.items);
}

/// Entry point for the function-length check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.function_length;

    if (!cfg.enabled) {
        ok("function-length disabled by config", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all functions within {d} line cap", .{cfg.max_lines});
        return;
    }

    fail("function length FAILED ({d} fn(s) over {d} line cap)", .{ violations.items.len, cfg.max_lines });
    for (violations.items) |v| reporter.emit(v);
    print("  fix: extract helpers to break the function into focused units, " ++
        "or raise [function_length] max_lines.\n", .{});
    return error.CheckFailed;
}

// spec: Function Length - Caps source lines per fn decl

test "visit flags fn over the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 3 },
    };
    const content =
        \\pub fn long() void {
        \\    var x: i32 = 0;
        \\    x += 1;
        \\    _ = x;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows fn at the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 3 },
    };
    const content =
        \\pub fn short() void {
        \\    return;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit reports correct start_line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 1 },
    };
    const content =
        \\const x = 1;
        \\
        \\pub fn long() void {
        \\    return;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    // The violation should reference line 3 (where `pub fn` sits) as structured data.
    try std.testing.expectEqual(@as(u32, 3), violations.items[0].line.?);
    try std.testing.expectEqualStrings("src/x.zig|long", violations.items[0].ratchet_key.?);
}
