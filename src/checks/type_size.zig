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
    cfg: config_mod.TypeSizeCfg,
};

/// True when `rel_path` matches any exclude pattern (a legitimate flat
/// aggregation struct exempt from the field cap).
fn isExcluded(rel_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (walk.matchGlob(rel_path, p)) return true;
    }
    return false;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isExcluded(entry.rel_path, ctx.cfg.exclude)) return;
    const a = ctx.allocator;

    const containers = if (entry.tree) |t|
        try ast.pubContainersFromTree(a, t)
    else
        try ast.pubContainers(a, entry.content);
    for (containers) |c| {
        // Enums are closed vocabularies (error kinds, token tags, form names);
        // a high variant count is domain size, not a god-struct smell, and
        // splitting them is semantically wrong. Only struct/union/opaque count.
        if (c.kind == .enum_) continue;
        if (c.field_count <= ctx.cfg.max_fields) continue;
        try ctx.violations.append(a, .{
            .check = "type-size",
            .file = entry.rel_path,
            .message = try std.fmt.allocPrint(
                a,
                "pub const {s} ({s}) has {d} fields (cap {d})",
                .{ c.name, @tagName(c.kind), c.field_count, ctx.cfg.max_fields },
            ),
            .ratchet_key = try std.fmt.allocPrint(a, "{s}|{s}", .{ entry.rel_path, c.name }),
            .metric = c.field_count,
        });
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
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };
    visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = content }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return reporter.flatLines(allocator, violations.items);
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

    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no public containers exceed {d} fields", .{cfg.max_fields});
        return;
    }

    fail("type size FAILED ({d} container(s) over {d} field cap)", .{ violations.items.len, cfg.max_fields });
    for (violations.items) |v| reporter.emit(v);
    print("  fix: split into smaller types, group related fields into nested structs, " ++
        "or raise [type_size] max_fields.\n", .{});
    return error.CheckFailed;
}

// spec: Type Size - Caps fields per pub struct/union/opaque
test "visit flags oversized struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
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

// spec: Type Size - Exempts enums from the field cap
test "visit exempts enums regardless of variant count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_fields = 2 },
    };
    const content =
        \\pub const Color = enum { red, green, blue, yellow };
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

// spec: Type Size - Skips pub containers in files matching the exclude patterns
test "visit skips excluded files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_fields = 1, .exclude = &.{"config.zig"} },
    };
    const content =
        \\pub const Big = struct { a: i32, b: i32, c: i32 };
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/config.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit doesn't count methods toward the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
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
