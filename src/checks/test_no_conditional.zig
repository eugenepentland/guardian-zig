const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Test Hygiene - Rejects if/while/switch and extra for loops at the top level of a test body

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for control flow at the top level
/// of test bodies. A single `for` is allowed (table-driven case loop).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_test) continue;

        var lbrace: std.zig.Token = undefined;
        while (true) {
            lbrace = tok.next();
            if (lbrace.tag == .l_brace or lbrace.tag == .eof) break;
        }
        if (lbrace.tag != .l_brace) continue;

        try scanBody(ctx, a, z, &tok);
    }
}

fn scanBody(ctx: *ScanCtx, a: Allocator, z: []const u8, tok: *std.zig.Tokenizer) Allocator.Error!void {
    var depth: u32 = 1;
    var top_for_count: u32 = 0;
    while (depth > 0) {
        const t = tok.next();
        if (t.tag == .eof) return;
        switch (t.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            .keyword_for => {
                if (depth == 1) {
                    top_for_count += 1;
                    if (top_for_count > 1) {
                        try report(ctx, a, z, t.loc.start, "more than one top-level for loop");
                    }
                }
            },
            .keyword_if => {
                if (depth == 1) try report(ctx, a, z, t.loc.start, "if at top level of test body");
            },
            .keyword_while => {
                if (depth == 1) try report(ctx, a, z, t.loc.start, "while at top level of test body");
            },
            .keyword_switch => {
                if (depth == 1) try report(ctx, a, z, t.loc.start, "switch at top level of test body");
            },
            else => {},
        }
    }
}

fn report(
    ctx: *ScanCtx,
    a: Allocator,
    z: []const u8,
    byte: usize,
    reason: []const u8,
) Allocator.Error!void {
    const line = lineOf(z, byte);
    const msg = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ ctx.rel_path, line, reason });
    try ctx.violations.append(a, msg);
}

fn lineOf(source: []const u8, byte_offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < byte_offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the test-no-conditional check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("test-no-conditional: tests are free of top-level branching", .{});
        return;
    }
    reporter.fail("test-no-conditional FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: split a conditional test into two independent tests; use a single table-driven `for`.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags top-level if in test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "branchy" {
        \\    if (true) {
        \\        try std.testing.expect(true);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows single table-driven for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "table" {
        \\    const cases = [_]u32{ 1, 2, 3 };
        \\    for (cases) |c| {
        \\        try std.testing.expect(c > 0);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags second top-level for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "two loops" {
        \\    for (a) |x| try expect(x > 0);
        \\    for (b) |y| try expect(y > 0);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows nested if inside for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "nested ok" {
        \\    for (cases) |c| {
        \\        if (c.skip) continue;
        \\        try expect(c.value > 0);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
