const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Debug Print Ban - Rejects std.debug.print call expressions outside test blocks and pub fn main

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

const ChainState = enum {
    none,
    saw_std,
    after_std_dot,
    saw_std_debug,
    after_std_debug_dot,
    saw_std_debug_print,
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const z = try a.dupeZ(u8, entry.content);
    var tok = std.zig.Tokenizer.init(z);

    // Same permissive-scope tracking as allocator_hygiene: test {…} and
    // pub fn main are exempt. Tokenizer skips strings/comments for free.
    var depth: u32 = 0;
    var permissive: std.ArrayListUnmanaged(u32) = .empty;
    defer permissive.deinit(a);

    var pending_permissive = false;
    var saw_fn = false;

    var chain: ChainState = .none;
    var chain_start: usize = 0;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;

        switch (t.tag) {
            .keyword_test => {
                pending_permissive = true;
                saw_fn = false;
                chain = .none;
            },
            .keyword_fn => {
                saw_fn = true;
                chain = .none;
            },
            .l_brace => {
                depth += 1;
                if (pending_permissive) {
                    try permissive.append(a, depth);
                    pending_permissive = false;
                }
                chain = .none;
            },
            .r_brace => {
                if (permissive.items.len > 0 and permissive.items[permissive.items.len - 1] == depth) {
                    _ = permissive.pop();
                }
                if (depth > 0) depth -= 1;
                chain = .none;
            },
            .identifier => {
                const text = z[t.loc.start..t.loc.end];
                if (saw_fn) {
                    if (std.mem.eql(u8, text, "main")) pending_permissive = true;
                    saw_fn = false;
                }
                chain = switch (chain) {
                    .none, .saw_std, .saw_std_debug, .saw_std_debug_print => blk: {
                        if (std.mem.eql(u8, text, "std")) {
                            chain_start = t.loc.start;
                            break :blk .saw_std;
                        }
                        break :blk .none;
                    },
                    .after_std_dot => blk: {
                        if (std.mem.eql(u8, text, "debug")) break :blk .saw_std_debug;
                        break :blk .none;
                    },
                    .after_std_debug_dot => blk: {
                        if (std.mem.eql(u8, text, "print")) break :blk .saw_std_debug_print;
                        break :blk .none;
                    },
                };
            },
            .period => {
                chain = switch (chain) {
                    .saw_std => .after_std_dot,
                    .saw_std_debug => .after_std_debug_dot,
                    else => .none,
                };
            },
            .l_paren => {
                if (chain == .saw_std_debug_print and permissive.items.len == 0) {
                    const line = lineOf(z, chain_start);
                    const msg = try std.fmt.allocPrint(
                        a,
                        "{s}:{d}: std.debug.print(...) call outside main/test",
                        .{ entry.rel_path, line },
                    );
                    try ctx.violations.append(a, msg);
                }
                chain = .none;
            },
            else => {
                chain = .none;
                saw_fn = false;
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

/// Entry point for the debug-print-ban check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no std.debug.print calls in production code", .{});
        return;
    }

    fail("debug print ban FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: route through reporter.print/detail, or alias once at file scope and use the alias.\n", .{});
    return error.CheckFailed;
}

test "visit flags std.debug.print call outside main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper() void {
        \\    std.debug.print("hello", .{});
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows std.debug.print inside pub fn main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn main() !void {
        \\    std.debug.print("startup\n", .{});
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit allows std.debug.print inside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\test "shows debug" {
        \\    std.debug.print("trace\n", .{});
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit allows alias declaration std.debug.print" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    // Alias form: chain followed by `;`, not `(`. Must not be flagged.
    const content =
        \\const print = std.debug.print;
        \\fn use() void {
        \\    print("via alias\n", .{});
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit ignores std.debug.print inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "const s = \"std.debug.print(\\\"x\\\", .{})\";\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit ignores std.debug.print inside comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\// std.debug.print("commented", .{});
        \\fn x() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit handles non-main fn followed by std.debug.print" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn run() !void {
        \\    std.debug.print("not main\n", .{});
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
