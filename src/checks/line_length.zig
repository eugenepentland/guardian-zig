const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

/// Pure-function entry: scans `content` for any line whose codepoint
/// length exceeds `max_len`.
pub fn analyzeContentWithLimit(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    max_len: u32,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var line_num: u32 = 1;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| : (line_num += 1) {
        // A multiline-string (`\\...`) line is emitted verbatim — its length is
        // template data (HTML/SVG/KiCad), not code, and it cannot be wrapped
        // without changing the output bytes. Skip it.
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, &std.ascii.whitespace), "\\\\")) continue;
        const codepoint_len = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (codepoint_len > max_len) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}:{d}: line is {d} chars (cap {d})",
                .{ rel_path, line_num, codepoint_len, max_len },
            );
            try violations.append(allocator, msg);
        }
    }
    return violations.toOwnedSlice(allocator);
}

/// Pure-function entry using the framework default (120) for tests.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    return analyzeContentWithLimit(allocator, rel_path, content, 120);
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    cap: u32,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeContentWithLimit(ctx.allocator, entry.rel_path, entry.content, ctx.cap);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the line-length check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const cap = ctx.cfg.line_length.max_len;
    if (!ctx.cfg.line_length.enabled) {
        reporter.ok("line-length disabled by config", .{});
        return;
    }
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .cap = cap,
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("line-length: every line is <= {d} chars", .{cap});
        return;
    }
    reporter.fail("line-length FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: split long expressions; introduce intermediate names.\n", .{});
    return error.CheckFailed;
}

// spec: Tier 2 Anti-patterns - Caps source line length

test "analyzeContent flags overlong line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [200]u8 = undefined;
    @memset(&buf, 'x');
    const out = try analyzeContent(arena.allocator(), "src/x.zig", buf[0..150]);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows short lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const x = 1;
        \\const y = 2;
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Tier 2 Anti-patterns - Skips multiline-string literal lines from the length cap
test "analyzeContent skips overlong multiline-string lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long = "x" ** 130;
    // A `\\`-prefixed template line over the cap; the code lines are short.
    const content = "const s =\n    \\\\" ++ long ++ "\n;\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
