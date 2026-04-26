const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

// spec: Debug Print Ban - Rejects std.debug.print call expressions outside test blocks and pub fn main
// spec: Debug Print Ban - Rejects std.log.* call expressions outside test blocks and pub fn main

const rules = [_]helper.Rule{
    .{ .chain = &.{ "std", "debug", "print" }, .display = "std.debug.print", .require_call = true },
    .{ .chain = &.{ "std", "log", "debug" }, .display = "std.log.debug", .require_call = true },
    .{ .chain = &.{ "std", "log", "info" }, .display = "std.log.info", .require_call = true },
    .{ .chain = &.{ "std", "log", "warn" }, .display = "std.log.warn", .require_call = true },
    .{ .chain = &.{ "std", "log", "err" }, .display = "std.log.err", .require_call = true },
    .{ .chain = &.{ "std", "log", "scoped" }, .display = "std.log.scoped", .require_call = true },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    .allowed_paths = &.{
        // Guardian-internal: legitimate diagnostic warnings (parse failures,
        // snapshot read failures, test-cleanup notices, capture-write OOM).
        // Downstream consumers should leave this empty and route logging
        // through their adapter.
        "src/ast/parser*",
        "src/snapshot.zig",
        "src/snapshot_helper*",
        "src/baseline.zig",
        "src/reporter.zig",
    },
    .fix_hint = "route through reporter.print/detail, or alias once at file scope and use the alias.",
};

/// Pure-function entry: scans `content` and returns violation lines
/// (allocator-owned). Empty slice = pass. Used by the golden-file test
/// harness; the production walker calls into the helper directly.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the debug-print-ban check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx_param, "debug print ban", opts);
}

test "analyzeContent flags std.debug.print call outside main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn helper_fn() void {
        \\    std.debug.print("hello", .{});
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows std.debug.print inside pub fn main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\pub fn main() !void {
        \\    std.debug.print("startup\n", .{});
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows std.debug.print inside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\test "shows debug" {
        \\    std.debug.print("trace\n", .{});
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows alias declaration std.debug.print" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const print = std.debug.print;
        \\fn use() void {
        \\    print("via alias\n", .{});
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores std.debug.print inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "const s = \"std.debug.print(\\\"x\\\", .{})\";\n";
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores std.debug.print inside comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\// std.debug.print("commented", .{});
        \\fn x() void {}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// ── Golden file scenarios ──────────────────────────────────────────────

const golden = @import("../testing/golden_runner.zig");

test "golden: raw-call-outside-main" {
    try golden.run(std.testing.allocator, .{
        .check_name = "debug-print-ban",
        .name = "raw-call-outside-main",
        .input = @embedFile("../testing/golden/debug-print-ban/raw-call-outside-main/input.zig.in"),
        .expected = @embedFile("../testing/golden/debug-print-ban/raw-call-outside-main/expected.txt"),
        .expected_path = "src/testing/golden/debug-print-ban/raw-call-outside-main/expected.txt",
    }, analyzeContent);
}

test "golden: alias-and-test-allowed" {
    try golden.run(std.testing.allocator, .{
        .check_name = "debug-print-ban",
        .name = "alias-and-test-allowed",
        .input = @embedFile("../testing/golden/debug-print-ban/alias-and-test-allowed/input.zig.in"),
        .expected = @embedFile("../testing/golden/debug-print-ban/alias-and-test-allowed/expected.txt"),
        .expected_path = "src/testing/golden/debug-print-ban/alias-and-test-allowed/expected.txt",
    }, analyzeContent);
}

test "analyzeContent handles non-main fn followed by std.debug.print" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\pub fn run() !void {
        \\    std.debug.print("not main\n", .{});
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
