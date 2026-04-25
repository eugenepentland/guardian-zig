const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Catch Discipline - Rejects catch unreachable in production code

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    // Tokenizer-based scan: keyword_catch immediately followed by
    // keyword_unreachable. The Tokenizer skips //-comments and string
    // literals, so this only matches real code patterns.
    const z = a.dupeZ(u8, entry.content) catch return;
    var tok = std.zig.Tokenizer.init(z);
    var line: u32 = 1;
    var last_pos: usize = 0;
    var prev_was_catch = false;
    var catch_pos: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (prev_was_catch and t.tag == .keyword_unreachable) {
            for (z[last_pos..catch_pos]) |c| {
                if (c == '\n') line += 1;
            }
            last_pos = catch_pos;
            const msg = std.fmt.allocPrint(
                a,
                "{s}:{d}: catch unreachable in production code",
                .{ entry.rel_path, line },
            ) catch return;
            ctx.violations.append(a, msg) catch {};
        }
        prev_was_catch = (t.tag == .keyword_catch);
        if (prev_was_catch) catch_pos = t.loc.start;
    }
}

/// Entry point for the catch-discipline check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    // Scan src/ only — test files are exempt.
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit }) catch {};

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
    visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit ignores `catch unreachable` inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "const s = \"catch unreachable\";\n";
    visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
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
    visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
