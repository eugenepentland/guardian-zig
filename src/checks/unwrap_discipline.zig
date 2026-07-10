const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
};

// Per-file destination for reported violations. `z` and `rel_path` are constant
// for the duration of one `visit`, so bundling them keeps `appendAt` to a small
// parameter list.
const Sink = struct {
    ctx: *ScanCtx,
    z: []const u8,
    rel_path: []const u8,
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));

    // Flag the optional-unwrap forms that turn a null into a crash or UB
    // instead of handling it: `orelse unreachable` and `orelse undefined`.
    // The Tokenizer skips //-comments and string literals, so only real
    // code matches. Bare `.?` is intentionally NOT flagged — it is too
    // common a (usually safe) idiom for a hard block to read soundly.
    // entry.content is already null-terminated by the walker.
    const z = entry.content;
    var sink = Sink{ .ctx = ctx, .z = z, .rel_path = entry.rel_path };
    var tok = std.zig.Tokenizer.init(z);
    var after_orelse = false;
    var orelse_pos: usize = 0;
    // Inline `test { ... }` blocks are exempt — `x orelse unreachable` is an
    // idiomatic assertion in a test.
    var scope = TestScope{};
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        scope.update(t.tag);
        if (after_orelse and !scope.in_test) {
            if (t.tag == .keyword_unreachable) {
                try appendAt(&sink, orelse_pos, "orelse unreachable crashes on null");
            } else if (t.tag == .identifier and std.mem.eql(u8, z[t.loc.start..t.loc.end], "undefined")) {
                try appendAt(&sink, orelse_pos, "orelse undefined assigns undefined on null");
            }
        }
        after_orelse = t.tag == .keyword_orelse;
        if (t.tag == .keyword_orelse) orelse_pos = t.loc.start;
    }
}

const TestScope = @import("../text.zig").TestScope;

fn appendAt(sink: *Sink, pos: usize, comptime what: []const u8) !void {
    const ctx = sink.ctx;
    const msg = try std.fmt.allocPrint(ctx.allocator, "{s}:{d}: " ++ what, .{ sink.rel_path, lineOf(sink.z, pos) });
    try ctx.violations.append(ctx.allocator, msg);
}

const lineOf = @import("../text.zig").lineOf;

/// Entry point for the unwrap-discipline check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    // Scan src/ only — test files are exempt.
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no orelse unreachable/undefined in production code", .{});
        return;
    }

    fail("unwrap discipline FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: handle the null case — `orelse <fallback>`, `if (x) |v| …`, or `orelse return error.X`.\n", .{});
    return error.CheckFailed;
}

// spec: Unwrap Discipline - Rejects orelse unreachable in production code
// spec: Unwrap Discipline - Rejects orelse undefined in production code

test "visit exempts orelse unreachable inside a test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\test "ok" {
        \\    const v = map.get(key) orelse unreachable;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
test "visit catches `orelse unreachable`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    const v = map.get(key) orelse unreachable;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit catches `orelse undefined`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    const v = maybe() orelse undefined;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows `orelse <fallback>` and `orelse return`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() !u32 {
        \\    const a2 = map.get(k) orelse 0;
        \\    const b2 = map.get(k) orelse return error.Missing;
        \\    return a2 + b2;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit ignores `orelse unreachable` inside a string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "const s = \"orelse unreachable\";\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
