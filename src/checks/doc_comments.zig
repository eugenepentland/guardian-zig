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
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        if (f.has_doc_comment) continue;
        const msg = try std.fmt.allocPrint(a, "{s}: pub fn {s} has no /// doc comment", .{ entry.rel_path, f.name });
        try ctx.violations.append(a, msg);
    }

    const consts = if (entry.tree) |t| try ast.pubConstsFromTree(a, t) else try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        switch (c.kind) {
            .struct_, .enum_, .union_, .opaque_ => {
                if (c.has_doc_comment) continue;
                const msg = try std.fmt.allocPrint(
                    a,
                    "{s}: pub const {s} ({s}) has no /// doc comment",
                    .{ entry.rel_path, c.name, @tagName(c.kind) },
                );
                try ctx.violations.append(a, msg);
            },
            else => {},
        }
    }
}

/// Entry point for the doc-comments check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all public declarations have doc comments", .{});
        return;
    }

    fail("doc comments FAILED ({d} undocumented pub declaration(s))", .{violations.items.len});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    print("  fix: add a /// doc comment line above each public declaration.\n", .{});
    return error.CheckFailed;
}

// spec: Doc Comments - Requires /// on every pub fn
// spec: Doc Comments - Requires /// on every pub struct/enum/union/opaque

test "visit flags missing doc comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\/// Documented.
        \\pub fn doc_fn() void {}
        \\
        \\pub fn nodoc_fn() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit flags missing doc comment on pub struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub const X = struct { x: i32 };
        \\pub const Y = 42;
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    // X has no /// → flag. Y is a value, exempt.
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
