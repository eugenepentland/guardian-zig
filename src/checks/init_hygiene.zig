const std = @import("std");
const ast = @import("../ast/parser.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Constructor Hygiene - Rejects init bodies with loops, conditionals, or switch statements

const init_names = [_][]const u8{ "init", "create", "make" };

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for init-shaped fns whose body
/// contains control flow (if / while / for / switch).
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
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = if (tree) |t| try ast.fnDeclInfosFromTree(a, t) else try ast.fnDeclInfos(a, content);

    for (fns) |fn_info| {
        if (!isInitName(fn_info.name)) continue;
        const offender = (try scanBody(a, fn_info.body_text)) orelse continue;
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}:{d}: init-shaped fn '{s}' contains '{s}' (constructors should be straight-line)",
            .{ rel_path, fn_info.start_line, fn_info.name, offender },
        );
        try violations.append(allocator, msg);
    }
    return violations.toOwnedSlice(allocator);
}

fn isInitName(name: []const u8) bool {
    for (init_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn scanBody(arena: Allocator, body: []const u8) Allocator.Error!?[]const u8 {
    const z = try arena.dupeZ(u8, body);
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_if => return "if",
            .keyword_while => return "while",
            .keyword_for => return "for",
            .keyword_switch => return "switch",
            else => {},
        }
    }
    return null;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeWithTree(ctx.allocator, entry.rel_path, entry.content, entry.tree);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the init-hygiene check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("init-hygiene: every init/create/make body is straight-line", .{});
        return;
    }
    reporter.fail("init-hygiene FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: move conditional logic into a factory or builder; keep init field-assignment-only.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags init with if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(x: u32) Foo { if (x > 0) return .{}; return .{}; }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags init with for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(items: []u32) Foo { for (items) |i| { _ = i; } return .{}; }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows straight-line init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(a: u32, b: u32) Foo { return .{ .a = a, .b = b }; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores non-init fns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn process(x: u32) void { if (x > 0) return; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
