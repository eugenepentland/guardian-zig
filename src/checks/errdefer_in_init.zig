const std = @import("std");
const ast = @import("../ast/parser.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const init_names = [_][]const u8{ "init", "create", "make" };

/// Pure-function entry: scans `content` for init-shaped fns whose body
/// contains 2+ `try` calls but no `errdefer` between them.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    return analyzeWithTree(allocator, rel_path, content, null);
}

fn analyzeWithTree(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    tree: ?*const std.zig.Ast,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = if (tree) |t| try ast.fnDeclInfosFromTree(a, t) else try ast.fnDeclInfos(a, content);

    for (fns) |fn_info| {
        if (!isInitName(fn_info.name)) continue;
        if (try needsErrdefer(a, fn_info.body_text)) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}:{d}: init-shaped fn '{s}' has multiple `try` calls without errdefer",
                .{ rel_path, fn_info.start_line, fn_info.name },
            );
            try violations.append(allocator, msg);
        }
    }
    return violations.toOwnedSlice(allocator);
}

fn isInitName(name: []const u8) bool {
    for (init_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn needsErrdefer(arena: Allocator, body: []const u8) Allocator.Error!bool {
    const z = try arena.dupeSentinel(u8, body, 0);
    var tok = std.zig.Tokenizer.init(z);
    var try_count: u32 = 0;
    var saw_errdefer = false;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_try => try_count += 1,
            .keyword_errdefer => saw_errdefer = true,
            else => {},
        }
    }
    return try_count >= 2 and !saw_errdefer;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeWithTree(ctx.allocator, entry.rel_path, entry.content, entry.tree);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the errdefer-in-init check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("errdefer-in-init: every multi-try init pairs an errdefer", .{});
        return;
    }
    reporter.fail("errdefer-in-init FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: add `errdefer` after each allocating `try` so a later failure cleans up.\n", .{});
    return error.CheckFailed;
}

// spec: Constructor Hygiene - Requires init bodies with multiple try calls to use errdefer

test "analyzeContent flags init with two trys and no errdefer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(a: std.mem.Allocator) !Foo {
        \\    const buf = try a.alloc(u8, 64);
        \\    const more = try a.alloc(u8, 64);
        \\    return .{ .buf = buf, .more = more };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows init with errdefer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(a: std.mem.Allocator) !Foo {
        \\    const buf = try a.alloc(u8, 64);
        \\    errdefer a.free(buf);
        \\    const more = try a.alloc(u8, 64);
        \\    return .{ .buf = buf, .more = more };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows init with single try" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(a: std.mem.Allocator) !Foo {
        \\    const buf = try a.alloc(u8, 64);
        \\    return .{ .buf = buf };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
