const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Catch Discipline - Rejects catch unreachable in production code
// spec: Catch Discipline - Rejects catch with empty block (silent error swallow)
// spec: Catch Discipline - Rejects catch undefined assigning undefined on error

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));

    // Tokenizer-based scan for catch patterns that hide failures:
    //   `catch unreachable`  — crashes instead of handling the error
    //   `catch undefined`    — assigns undefined (UB) on error
    //   `catch {}`           — empty block silently swallows the error
    //   `catch |e| {}`       — captured but empty body, the same swallow
    // The Tokenizer skips //-comments and string literals so we only
    // match real code, not text inside doc-strings or comments.
    // entry.content is already null-terminated by the walker.
    const z = entry.content;
    var tok = std.zig.Tokenizer.init(z);
    const State = enum { none, after_catch, in_capture, expect_brace, after_lbrace };
    var state: State = .none;
    var catch_pos: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (state) {
            .none => if (t.tag == .keyword_catch) {
                state = .after_catch;
                catch_pos = t.loc.start;
            },
            .after_catch => switch (t.tag) {
                .keyword_unreachable => {
                    try appendAt(ctx, z, entry.rel_path, catch_pos, "catch unreachable in production code");
                    state = .none;
                },
                .identifier => {
                    if (std.mem.eql(u8, z[t.loc.start..t.loc.end], "undefined")) {
                        try appendAt(ctx, z, entry.rel_path, catch_pos, "catch undefined assigns undefined on error");
                    }
                    state = .none;
                },
                .pipe => state = .in_capture,
                .l_brace => state = .after_lbrace,
                .keyword_catch => catch_pos = t.loc.start,
                else => state = .none,
            },
            // Skip the `|capture|`; the closing pipe leads to the body.
            .in_capture => if (t.tag == .pipe) {
                state = .expect_brace;
            },
            .expect_brace => switch (t.tag) {
                .l_brace => state = .after_lbrace,
                .keyword_catch => {
                    catch_pos = t.loc.start;
                    state = .after_catch;
                },
                else => state = .none,
            },
            .after_lbrace => {
                if (t.tag == .r_brace) {
                    try appendAt(ctx, z, entry.rel_path, catch_pos, "catch block is empty (silently swallows the error)");
                }
                state = if (t.tag == .keyword_catch) blk: {
                    catch_pos = t.loc.start;
                    break :blk .after_catch;
                } else .none;
            },
        }
    }
}

fn appendAt(ctx: *ScanCtx, z: []const u8, rel_path: []const u8, pos: usize, comptime what: []const u8) !void {
    const msg = try std.fmt.allocPrint(ctx.allocator, "{s}:{d}: " ++ what, .{ rel_path, lineOf(z, pos) });
    try ctx.violations.append(ctx.allocator, msg);
}

fn lineOf(source: []const u8, byte_offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < byte_offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

/// Entry point for the catch-discipline check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    // Scan src/ only — test files are exempt.
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no catch unreachable in production code", .{});
        return;
    }

    fail("catch discipline FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: handle the error explicitly with a switch or named return.\n", .{});
    return error.CheckFailed;
}

test "visit catches `catch unreachable`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    const f = std.fs.cwd().openFile("x", .{}) catch unreachable;
        \\    _ = f;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit ignores `catch unreachable` inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "const s = \"catch unreachable\";\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches `catch {}`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    list.append(item) catch {};
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows `catch |err| ...`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() !void {
        \\    const f = std.fs.cwd().openFile("x", .{}) catch |err| return err;
        \\    _ = f;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches `catch undefined`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    const n = parse(s) catch undefined;
        \\    _ = n;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit catches `catch |e| {}` empty captured body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    list.append(item) catch |e| {};
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows `catch |e| { handle(e); }` non-empty body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    list.append(item) catch |e| { log(e); };
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
