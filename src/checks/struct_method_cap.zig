const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const max_methods: u32 = 20;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayList(reporter.Violation),
};

/// Pure-function entry: scans `content` for pub container declarations
/// whose body contains more than `max_methods` `pub fn` declarations.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return reporter.flatLines(allocator, violations.items);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_pub) continue;
        const next = tok.next();
        if (next.tag != .keyword_const) continue;
        if (parseHead(&tok, z)) |head| {
            const count = countPubFns(&tok);
            if (count > max_methods) {
                try ctx.violations.append(a, .{
                    .check = "struct-method-cap",
                    .file = ctx.rel_path,
                    .line = head.line,
                    .message = try std.fmt.allocPrint(
                        a,
                        "pub container '{s}' has {d} pub fn methods (cap {d})",
                        .{ head.name, count, max_methods },
                    ),
                    .ratchet_key = try std.fmt.allocPrint(a, "{s}|{s}", .{ ctx.rel_path, head.name }),
                    .metric = count,
                });
            }
        }
    }
}

const Head = struct {
    name: []const u8,
    line: u32,
};

fn parseHead(tok: *std.zig.Tokenizer, z: []const u8) ?Head {
    const id = tok.next();
    const eq = tok.next();
    if (id.tag != .identifier or eq.tag != .equal) return null;
    const name = z[id.loc.start..id.loc.end];

    var t = tok.next();
    while (t.tag == .keyword_extern or t.tag == .keyword_packed) t = tok.next();
    const is_container = t.tag == .keyword_struct or t.tag == .keyword_enum or t.tag == .keyword_union;
    if (!is_container or !skipToBrace(tok)) return null;
    return .{ .name = name, .line = lineOf(z, id.loc.start) };
}

// Consumes tokens up to and including the container body's opening `{`, skipping
// an optional `(tag_type)` for tagged unions / enums. Returns false if the
// stream ends or the next significant token isn't `(` or `{`.
fn skipToBrace(tok: *std.zig.Tokenizer) bool {
    var nxt = tok.next();
    if (nxt.tag == .l_paren) {
        var d: u32 = 1;
        while (d > 0) {
            const inner = tok.next();
            if (inner.tag == .eof) return false;
            if (inner.tag == .l_paren) d += 1;
            if (inner.tag == .r_paren) d -= 1;
        }
        nxt = tok.next();
    }
    return nxt.tag == .l_brace;
}

fn countPubFns(tok: *std.zig.Tokenizer) u32 {
    var depth: u32 = 1;
    var count: u32 = 0;
    var saw_pub = false;
    while (depth > 0) {
        const t = tok.next();
        if (t.tag == .eof) return count;
        switch (t.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            .keyword_pub => saw_pub = true,
            // Modifiers sit between `pub` and `fn`; they must not clear saw_pub,
            // or `pub inline fn` / `pub extern fn` / `pub export fn` go uncounted.
            .keyword_inline, .keyword_noinline, .keyword_extern, .keyword_export => {},
            .keyword_fn => {
                if (saw_pub and depth == 1) count += 1;
                saw_pub = false;
            },
            else => {
                if (t.tag != .doc_comment and t.tag != .container_doc_comment) saw_pub = false;
            },
        }
    }
    return count;
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList(reporter.Violation),
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

/// Entry point for the struct-method-cap check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("struct-method-cap: every container has <= {d} pub fn methods", .{max_methods});
        return;
    }
    reporter.fail("struct-method-cap FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: split the type into smaller responsibilities — large method sets indicate two roles.\n", .{});
    return error.CheckFailed;
}

// spec: Tier 2 Anti-patterns - Caps pub fn methods per pub struct/enum/union

test "analyzeContent flags struct with > 20 methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena.allocator());
    const a = arena.allocator();
    try buf.appendSlice(a, "pub const Big = struct {\n");
    const indices = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    for (indices) |i| {
        const line = try std.fmt.allocPrint(a, "    pub fn m{d}() void {{}}\n", .{i});
        try buf.appendSlice(a, line);
    }
    try buf.appendSlice(a, "};\n");
    const out = try analyzeContent(a, "src/x.zig", buf.items);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent counts pub inline/extern methods toward the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "pub const Big = struct {\n");
    // 21 `pub inline fn` methods: before the fix the modifier reset saw_pub
    // and none were counted.
    for (0..21) |i| {
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "    pub inline fn m{d}() void {{}}\n", .{i}));
    }
    try buf.appendSlice(a, "};\n");
    const out = try analyzeContent(a, "src/x.zig", buf.items);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
test "analyzeContent allows struct with few methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Small = struct {
        \\    pub fn a() void {}
        \\    pub fn b() void {}
        \\};
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
