const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Function Size - Caps parameter count per function

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    max_params: u32,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const fns = ast.allFns(a, entry.content) catch return;
    for (fns) |f| {
        if (f.param_count <= ctx.max_params) continue;
        const msg = std.fmt.allocPrint(
            a,
            "{s}: fn {s} has {d} params (limit: {d})",
            .{ entry.rel_path, f.name, f.param_count, ctx.max_params },
        ) catch continue;
        ctx.violations.append(a, msg) catch {};
    }
}

/// Entry point for the function-size check.
pub fn run(ctx_param: *registry.RunCtx) !void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    const project_dir = ctx_param.project_dir;

    if (!cfg.function_size.enabled) {
        ok("function size skipped (disabled in config)", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .max_params = cfg.function_size.max_params,
        .violations = &violations,
    };

    const dirs_to_check = [_][]const u8{ "src", "test" };
    for (&dirs_to_check) |dir_name| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir_name });
        walk.walkZigFiles(allocator, dir_path, dir_name, .{}, .{ .ctx = &ctx, .visit = visit }) catch {};
    }

    if (violations.items.len == 0) {
        ok("all functions within {d} param limit", .{cfg.function_size.max_params});
        return;
    }

    fail("function size FAILED ({d} fn(s) over {d} param limit)", .{
        violations.items.len,
        cfg.function_size.max_params,
    });
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    print("  fix: bundle related parameters into a struct.\n", .{});
    std.process.exit(1);
}

test "visit catches over-budget functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .max_params = 3, .violations = &violations };
    const content =
        \\pub fn ok_fn(a: i32, b: i32, c: i32) void {}
        \\pub fn too_many(a: i32, b: i32, c: i32, d: i32, e: i32) void {}
    ;
    visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
