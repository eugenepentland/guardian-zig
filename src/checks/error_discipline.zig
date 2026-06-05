const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Error Discipline - Rejects inferred error sets on pub fn
// spec: Error Discipline - Rejects anyerror on pub fn

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        // `main` is conventionally exempt; its inferred error set is idiomatic.
        if (std.mem.eql(u8, f.name, "main")) continue;
        switch (f.return_kind) {
            .err_union_inferred => {
                const msg = try std.fmt.allocPrint(a, "{s}: pub fn {s} uses inferred error set `!T` (use `MyErr!T`)", .{ entry.rel_path, f.name });
                try ctx.violations.append(a, msg);
            },
            .anyerror_union => {
                const msg = try std.fmt.allocPrint(a, "{s}: pub fn {s} uses anyerror (declare a specific error set)", .{ entry.rel_path, f.name });
                try ctx.violations.append(a, msg);
            },
            else => {},
        }
    }
}

/// Entry point for the error-discipline check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("error discipline OK", .{});
        return;
    }

    fail("error discipline FAILED ({d} violation(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: declare an explicit error set, e.g.\n", .{});
    print("    pub const MyError = error{{ Foo, Bar }};\n", .{});
    print("    pub fn run(...) MyError!void {{ ... }}\n", .{});
    return error.CheckFailed;
}

test "visit catches inferred error set on pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn bad() !void {}
        \\pub const MyErr = error{ X };
        \\pub fn good() MyErr!void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows main with inferred error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn main() !void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/main.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches anyerror on pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn dynamic() anyerror!void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
