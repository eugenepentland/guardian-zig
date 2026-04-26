const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Naming - PascalCase pub fn must return type
// spec: Naming - camelCase pub fn must not return type
// spec: Naming - pub const struct/enum/union with fields must be PascalCase

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn caseKind(name: []const u8) enum { pascal, camel, snake, other } {
    if (name.len == 0) return .other;
    const first = name[0];
    if (std.ascii.isUpper(first)) return .pascal;
    if (std.ascii.isLower(first)) {
        // Distinguish camelCase from snake_case by presence of underscore.
        if (std.mem.indexOfScalar(u8, name, '_') != null) return .snake;
        return .camel;
    }
    return .other;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = try ast.pubFns(a, entry.content);
    for (fns) |f| {
        const kind = caseKind(f.name);
        switch (f.return_kind) {
            .type_kw => {
                if (kind != .pascal) {
                    const msg = try std.fmt.allocPrint(a, "{s}: pub fn {s} returns `type` but is not PascalCase", .{ entry.rel_path, f.name });
                    try ctx.violations.append(a, msg);
                }
            },
            else => {
                if (kind == .pascal) {
                    const msg = try std.fmt.allocPrint(a, "{s}: pub fn {s} is PascalCase but does not return `type`", .{ entry.rel_path, f.name });
                    try ctx.violations.append(a, msg);
                }
            },
        }
    }

    const consts = try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        switch (c.kind) {
            .struct_, .enum_, .union_, .opaque_ => {
                const kind = caseKind(c.name);
                if (kind != .pascal) {
                    const msg = try std.fmt.allocPrint(a, "{s}: pub const {s} is a {s} type but is not PascalCase", .{ entry.rel_path, c.name, @tagName(c.kind) });
                    try ctx.violations.append(a, msg);
                }
            },
            else => {},
        }
    }
}

/// Entry point for the naming check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("naming conventions OK", .{});
        return;
    }

    fail("naming check FAILED ({d} violation(s))", .{violations.items.len});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    print("  fix: PascalCase iff the fn returns `type`; types use PascalCase.\n", .{});
    return error.CheckFailed;
}

test "caseKind classifies common cases" {
    try std.testing.expectEqual(@as(@TypeOf(caseKind("Foo")), .pascal), caseKind("Foo"));
    try std.testing.expectEqual(@as(@TypeOf(caseKind("foo")), .camel), caseKind("foo"));
    try std.testing.expectEqual(@as(@TypeOf(caseKind("foo_bar")), .snake), caseKind("foo_bar"));
    try std.testing.expectEqual(@as(@TypeOf(caseKind("fooBar")), .camel), caseKind("fooBar"));
}

test "visit catches pascal fn that does not return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn DoThing() void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit accepts pascal fn returning type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn List(comptime T: type) type { return T; }\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches snake_case struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub const my_struct = struct { x: i32 };\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
