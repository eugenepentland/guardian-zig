const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayList([]const u8),
};

/// Pure-function entry: scans `content` for bare or empty `@compileError` calls.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

fn scan(ctx: *ScanCtx, z: [:0]const u8) Allocator.Error!void {
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .builtin) continue;
        const name = z[t.loc.start..t.loc.end];
        if (!std.mem.eql(u8, name, "@compileError")) continue;
        const lparen = tok.next();
        if (lparen.tag != .l_paren) continue;
        const arg = tok.next();
        if (arg.tag != .string_literal) {
            try report(ctx, z, t.loc.start, "@compileError without string literal");
            continue;
        }
        const raw = z[arg.loc.start..arg.loc.end];
        if (raw.len <= 2) {
            try report(ctx, z, t.loc.start, "@compileError with empty string");
        }
    }
}

fn report(ctx: *ScanCtx, z: []const u8, byte: usize, kind: []const u8) Allocator.Error!void {
    const line = lineOf(z, byte);
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: {s}",
        .{ ctx.rel_path, line, kind },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the compile-error-explanation check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("compile-error-explanation: every @compileError has a string", .{});
        return;
    }
    reporter.fail("compile-error-explanation FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: pass a string literal explaining why this branch is unreachable.\n", .{});
    return error.CheckFailed;
}

// spec: Constructor Hygiene - Rejects @compileError without a non-empty string explanation

test "analyzeContent flags @compileError with no args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn x() void { @compileError(); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags @compileError with empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn x() void { @compileError(""); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows @compileError with non-empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn x() void { @compileError("only supported on x86_64"); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
