const std = @import("std");
const ast = @import("../ast/parser.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Test Hygiene - Rejects production code @import-ing test files

const ScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for `@import("X")` paths that look
/// like test files (ending `_test.zig` or under `tests/`).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    if (isTestFile(rel_path)) return violations.toOwnedSlice(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const imports = ast.imports(arena.allocator(), content);
    for (imports) |imp| {
        if (looksLikeTest(imp.path)) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}: imports test path '{s}'",
                .{ rel_path, imp.path },
            );
            try violations.append(allocator, msg);
        }
    }
    return violations.toOwnedSlice(allocator);
}

fn isTestFile(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "_test.zig")) return true;
    if (std.mem.indexOf(u8, path, "/tests/") != null) return true;
    if (std.mem.startsWith(u8, path, "tests/")) return true;
    return false;
}

fn looksLikeTest(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "_test.zig")) return true;
    if (std.mem.indexOf(u8, path, "/tests/") != null) return true;
    if (std.mem.startsWith(u8, path, "tests/")) return true;
    return false;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeContent(ctx.allocator, entry.rel_path, entry.content);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the prod-imports-no-test check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("prod-imports-no-test: production code does not import test files", .{});
        return;
    }
    reporter.fail("prod-imports-no-test FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: keep test-only utilities under tests/ or *_test.zig and import them only from tests.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags import of *_test.zig from prod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/main.zig",
        \\const helpers = @import("auth_test.zig");
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags import of tests/ path from prod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/main.zig",
        \\const helpers = @import("tests/fixtures.zig");
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows test files importing test files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/auth_test.zig",
        \\const helpers = @import("auth_test.zig");
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows non-test imports from prod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/main.zig",
        \\const std = @import("std");
        \\const cfg = @import("config.zig");
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
