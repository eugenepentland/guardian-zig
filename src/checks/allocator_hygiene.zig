const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Allocator Hygiene - Rejects hardcoded global allocators outside test blocks and pub fn main

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

const ChainState = enum {
    none,
    saw_std,
    after_std_dot,
    saw_std_heap,
    after_std_heap_dot,
    saw_std_testing,
    after_std_testing_dot,
};

fn isForbiddenHeap(name: []const u8) bool {
    const forbidden = [_][]const u8{
        "page_allocator",
        "c_allocator",
        "smp_allocator",
        "GeneralPurposeAllocator",
    };
    for (forbidden) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const z = try a.dupeZ(u8, entry.content);
    var tok = std.zig.Tokenizer.init(z);

    // Permissive-scope tracking: when we enter a `test {…}` block or a
    // `pub fn main(…) … {…}`, push the current brace depth. While the
    // stack is non-empty, the file is exempt. The Zig tokenizer skips
    // string literals and comments, so forbidden text inside strings or
    // doc-comments never reaches us.
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
                const in_permissive = permissive.items.len > 0;
                chain = switch (chain) {
                    .none, .saw_std, .saw_std_heap, .saw_std_testing => blk: {
                        if (std.mem.eql(u8, text, "std")) {
                            chain_start = t.loc.start;
                            break :blk .saw_std;
                        }
                        break :blk .none;
                    },
                    .after_std_dot => blk: {
                        if (std.mem.eql(u8, text, "heap")) break :blk .saw_std_heap;
                        if (std.mem.eql(u8, text, "testing")) break :blk .saw_std_testing;
                        break :blk .none;
                    },
                    .after_std_heap_dot => blk: {
                        if (!in_permissive and isForbiddenHeap(text)) {
                            const line = lineOf(z, chain_start);
                            const msg = try std.fmt.allocPrint(
                                a,
                                "{s}:{d}: hardcoded std.heap.{s} outside main/test",
                                .{ entry.rel_path, line, text },
                            );
                            try ctx.violations.append(a, msg);
                        }
                        break :blk .none;
                    },
                    .after_std_testing_dot => blk: {
                        if (!in_permissive and std.mem.eql(u8, text, "allocator")) {
                            const line = lineOf(z, chain_start);
                            const msg = try std.fmt.allocPrint(
                                a,
                                "{s}:{d}: hardcoded std.testing.allocator outside test block",
                                .{ entry.rel_path, line },
                            );
                            try ctx.violations.append(a, msg);
                        }
                        break :blk .none;
                    },
                };
            },
            .period => {
                chain = switch (chain) {
                    .saw_std => .after_std_dot,
                    .saw_std_heap => .after_std_heap_dot,
                    .saw_std_testing => .after_std_testing_dot,
                    else => .none,
                };
            },
            else => {
                // Don't clear `pending_permissive` here — it must survive
                // intermediate tokens (paren list, return type, the string
                // literal after `test`) and only get consumed by the next
                // `l_brace`.
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

/// Entry point for the allocator-hygiene check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no hardcoded global allocators in production code", .{});
        return;
    }

    fail("allocator hygiene FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: thread the allocator through as a parameter instead of hardcoding a global.\n", .{});
    return error.CheckFailed;
}

test "visit flags page_allocator outside main and test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper() void {
        \\    const v = std.heap.page_allocator;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows page_allocator inside pub fn main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn main() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    _ = arena;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit allows testing.allocator inside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\test "uses testing allocator" {
        \\    var x = std.testing.allocator;
        \\    _ = x;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit flags testing.allocator outside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper() void {
        \\    const v = std.testing.allocator;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit ignores std.heap.ArenaAllocator (not a forbidden chain)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper(parent: std.mem.Allocator) void {
        \\    var arena = std.heap.ArenaAllocator.init(parent);
        \\    _ = arena;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit ignores forbidden chain inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "const s = \"std.heap.page_allocator\";\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit flags GeneralPurposeAllocator outside main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper() void {
        \\    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
        \\    _ = gpa;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit handles non-main fn followed by allocator pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn run() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    _ = arena;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
