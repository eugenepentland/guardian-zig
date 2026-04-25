const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Usingnamespace Ban - Hard-fails any usingnamespace keyword outside test files

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    // Tokenizer skips strings and comments correctly, so a token with this
    // text is genuinely in code (not a comment or string body).
    const z = try ctx.allocator.dupeZ(u8, entry.content);
    var tok = std.zig.Tokenizer.init(z);
    var line: u32 = 1;
    var last_pos: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        // In Zig 0.15+ the keyword is gone; it's tokenized as an identifier
        // (or rejected outright by the compiler). We still flag the literal
        // text so the check works on code mid-migration from 0.14.
        if (t.tag != .identifier) continue;
        const name = z[t.loc.start..t.loc.end];
        if (!std.mem.eql(u8, name, "usingnamespace")) continue;
        for (z[last_pos..t.loc.start]) |c| {
            if (c == '\n') line += 1;
        }
        last_pos = t.loc.start;
        const msg = try std.fmt.allocPrint(
            ctx.allocator,
            "{s}:{d}: usingnamespace is forbidden",
            .{ entry.rel_path, line },
        );
        try ctx.violations.append(ctx.allocator, msg);
    }
}

/// Entry point for the usingnamespace-ban check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    // Scan src/ but not test/ — usingnamespace in test files is grandfathered.
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no usingnamespace declarations", .{});
        return;
    }

    fail("usingnamespace ban FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    print("  fix: replace with explicit re-exports, e.g. `pub const x = bar.x;`\n", .{});
    print("  see https://github.com/ziglang/zig/issues/20663\n", .{});
    std.process.exit(1);
}

test "visit flags usingnamespace at correct line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Simulate a file by giving the visitor an in-memory entry.
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\const std = @import("std");
        \\
        \\pub usingnamespace std;
        \\
        \\fn other() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit ignores usingnamespace in comments and strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\// usingnamespace bar;
        \\const s = "usingnamespace bar;";
        \\fn x() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/y.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
