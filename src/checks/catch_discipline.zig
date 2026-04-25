const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Catch Discipline - Rejects catch unreachable in production code
// spec: Catch Discipline - Rejects catch with empty block (silent error swallow)

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    // Tokenizer-based 3-state scan looking for two forbidden patterns:
    //   `catch unreachable`  — production code shouldn't crash silently
    //   `catch {}`           — silent error swallow (catch immediately
    //                          followed by an empty block)
    // The Tokenizer skips //-comments and string literals so we only
    // match real code, not text inside doc-strings or comments.
    const z = try a.dupeZ(u8, entry.content);
    var tok = std.zig.Tokenizer.init(z);
    const State = enum { none, after_catch, after_catch_lbrace };
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
                    const line = lineOf(z, catch_pos);
                    const msg = try std.fmt.allocPrint(a, "{s}:{d}: catch unreachable in production code", .{ entry.rel_path, line });
                    try ctx.violations.append(a, msg);
                    state = .none;
                },
                .l_brace => state = .after_catch_lbrace,
                .keyword_catch => catch_pos = t.loc.start,
                else => state = .none,
            },
            .after_catch_lbrace => {
                if (t.tag == .r_brace) {
                    const line = lineOf(z, catch_pos);
                    const msg = try std.fmt.allocPrint(a, "{s}:{d}: catch {{}} silently swallows error", .{ entry.rel_path, line });
                    try ctx.violations.append(a, msg);
                }
                state = if (t.tag == .keyword_catch) blk: {
                    catch_pos = t.loc.start;
                    break :blk .after_catch;
                } else .none;
            },
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

/// Entry point for the catch-discipline check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    // Scan src/ only — test files are exempt.
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no catch unreachable in production code", .{});
        return;
    }

    fail("catch discipline FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: handle the error explicitly with a switch or named return.\n", .{});
    std.process.exit(1);
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
