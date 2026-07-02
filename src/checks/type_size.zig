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
    cfg: config_mod.TypeSizeCfg,
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const containers = if (entry.tree) |t|
        try ast.pubContainersFromTree(a, t)
    else
        try ast.pubContainers(a, entry.content);
    for (containers) |c| {
        if (c.field_count <= ctx.cfg.max_fields) continue;
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: pub const {s} ({s}) has {d} fields (cap {d})",
            .{ entry.rel_path, c.name, @tagName(c.kind), c.field_count, ctx.cfg.max_fields },
        );
        try ctx.violations.append(a, msg);
    }
}

/// Pure-function entry: scans `content` and returns violation lines
/// (allocator-owned). Empty slice = pass. Used by the golden-file test
/// harness; the production walker calls `visit()` directly.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
    cfg: config_mod.TypeSizeCfg,
) std.mem.Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };
    visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = content }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return violations.toOwnedSlice(allocator);
}

/// Entry point for the type-size check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.type_size;

    if (!cfg.enabled) {
        ok("type-size disabled by config", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no public containers exceed {d} fields", .{cfg.max_fields});
        return;
    }

    fail("type size FAILED ({d} container(s) over {d} field cap)", .{ violations.items.len, cfg.max_fields });
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: split into smaller types, group related fields into nested structs, " ++
        "or raise [type_size] max_fields.\n", .{});
    return error.CheckFailed;
}

// spec: Type Size - Caps fields per pub struct/enum/union/opaque

test "visit flags oversized struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_fields = 3 },
    };
    const content =
        \\pub const Big = struct {
        \\    a: i32,
        \\    b: i32,
        \\    c: i32,
        \\    d: i32,
        \\};
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows struct at the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_fields = 3 },
    };
    const content =
        \\pub const Trio = struct {
        \\    a: i32,
        \\    b: i32,
        \\    c: i32,
        \\};
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit ignores private structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_fields = 1 },
    };
    const content =
        \\const PrivateBig = struct {
        \\    a: i32, b: i32, c: i32,
        \\};
        \\pub const PubSmall = struct { x: i32 };
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit flags oversized enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_fields = 2 },
    };
    const content =
        \\pub const Color = enum { red, green, blue, yellow };
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit doesn't count methods toward the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_fields = 2 },
    };
    const content =
        \\pub const T = struct {
        \\    x: i32,
        \\    y: i32,
        \\    pub fn a(_: T) void {}
        \\    pub fn b(_: T) void {}
        \\    pub fn c(_: T) void {}
        \\};
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
