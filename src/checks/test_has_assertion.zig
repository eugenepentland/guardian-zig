const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Test Hygiene - Requires every test block to contain at least one std.testing.expect call

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for `test "..." { ... }` blocks
/// whose body has no `expect*` token.
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
        const test_byte = t.loc.start;

        // Anonymous tests (`test { ... }`) are typically test aggregators
        // (`_ = @import(...)`) — exempt them.
        var lbrace: std.zig.Token = undefined;
        var has_name = false;
        while (true) {
            lbrace = tok.next();
            if (lbrace.tag == .string_literal) has_name = true;
            if (lbrace.tag == .l_brace or lbrace.tag == .eof) break;
        }
        if (lbrace.tag != .l_brace) continue;
        if (!has_name) {
            // Skip the body to keep the outer loop in sync.
            var depth: u32 = 1;
            while (depth > 0) {
                const inner = tok.next();
                if (inner.tag == .eof) return;
                if (inner.tag == .l_brace) depth += 1;
                if (inner.tag == .r_brace) depth -= 1;
            }
            continue;
        }

        const body_start = lbrace.loc.end;
        var depth: u32 = 1;
        var body_end: usize = body_start;
        while (true) {
            const inner = tok.next();
            if (inner.tag == .eof) break;
            if (inner.tag == .l_brace) depth += 1;
            if (inner.tag == .r_brace) {
                depth -= 1;
                if (depth == 0) {
                    body_end = inner.loc.start;
                    break;
                }
            }
        }
        if (body_end <= body_start) continue;
        const body = z[body_start..body_end];
        if (std.mem.indexOf(u8, body, "expect") == null) {
            const line = lineOf(z, test_byte);
            const msg = try std.fmt.allocPrint(
                a,
                "{s}:{d}: test block has no expect* assertion",
                .{ ctx.rel_path, line },
            );
            try ctx.violations.append(a, msg);
        }
    }
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

/// Entry point for the test-has-assertion check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("test-has-assertion: every test block has an expect* call", .{});
        return;
    }
    reporter.fail("test-has-assertion FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: add at least one `try std.testing.expect*` call to verify behavior.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags test with no expect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "side effect only" {
        \\    var x: u32 = 1;
        \\    x += 1;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows test with expectEqual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "with assertion" {
        \\    try std.testing.expectEqual(@as(u32, 2), 1 + 1);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows aliased expect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const expect = std.testing.expect;
        \\test "alias works" {
        \\    try expect(true);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
