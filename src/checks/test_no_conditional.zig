const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for control flow at the top level
/// of test bodies. A single `for` is allowed (table-driven case loop).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_test) continue;

        var lbrace: std.zig.Token = undefined;
        while (true) {
            lbrace = tok.next();
            if (lbrace.tag == .l_brace or lbrace.tag == .eof) break;
        }
        if (lbrace.tag != .l_brace) continue;

        try scanBody(ctx, z, &tok);
    }
}

/// Mutable state and shared inputs threaded through the per-keyword handlers
/// while scanning a single test body. `depth` starts at 1 (the body itself).
const BodyScan = struct {
    ctx: *ScanCtx,
    z: []const u8,
    tok: *std.zig.Tokenizer,
    depth: u32 = 1,
    top_loop_count: u32 = 0,
};

fn scanBody(ctx: *ScanCtx, z: []const u8, tok: *std.zig.Tokenizer) Allocator.Error!void {
    var bs: BodyScan = .{ .ctx = ctx, .z = z, .tok = tok };
    while (bs.depth > 0) {
        const t = tok.next();
        if (t.tag == .eof) return;
        switch (t.tag) {
            .l_brace => bs.depth += 1,
            .r_brace => bs.depth -= 1,
            .keyword_for => try handleLoop(&bs, t.loc.start),
            .keyword_while => try handleWhile(&bs, t.loc.start),
            .keyword_if => try handleIf(&bs, t.loc.start),
            .keyword_switch => try handleSwitch(&bs, t.loc.start),
            else => {},
        }
    }
}

/// Counts a top-level loop and flags the second (and later) one.
fn handleLoop(bs: *BodyScan, byte: usize) Allocator.Error!void {
    if (bs.depth != 1) return;
    bs.top_loop_count += 1;
    if (bs.top_loop_count > 1) {
        try report(bs.ctx, bs.z, byte, "more than one top-level loop");
    }
}

/// Flags a `switch` at the top level of a test body.
fn handleSwitch(bs: *BodyScan, byte: usize) Allocator.Error!void {
    if (bs.depth != 1) return;
    try report(bs.ctx, bs.z, byte, "switch at top level of test body");
}

/// A capturing `while (it.next()) |x|` is an iterator loop — functionally the
/// allowed table-driven `for`, not a conditional. Only a plain conditional
/// while is flagged.
fn handleWhile(bs: *BodyScan, byte: usize) Allocator.Error!void {
    if (bs.depth != 1) return;
    if (whileIsCapturing(bs.tok, &bs.depth)) {
        try handleLoop(bs, byte);
    } else {
        try report(bs.ctx, bs.z, byte, "while at top level of test body");
    }
}

/// Allow the standard skip idiom `if (cond) return error.SkipZigTest;` — it's
/// how a test opts out, not logic. Any other top-level `if` is flagged.
fn handleIf(bs: *BodyScan, byte: usize) Allocator.Error!void {
    if (bs.depth != 1) return;
    consumeParenGroup(bs.tok);
    const nxt = bs.tok.next();
    if (nxt.tag == .keyword_return and thenClauseIsSkip(bs.tok, bs.z)) return;
    if (nxt.tag == .l_brace) bs.depth += 1;
    try report(bs.ctx, bs.z, byte, "if at top level of test body");
}

/// Consumes a `( ... )` group from the current position (the next token is
/// expected to be `(`), leaving the tokenizer just past the matching `)`.
fn consumeParenGroup(tok: *std.zig.Tokenizer) void {
    var paren: u32 = 0;
    while (true) {
        const t = tok.next();
        switch (t.tag) {
            .l_paren => paren += 1,
            .r_paren => {
                if (paren > 0) paren -= 1;
                if (paren == 0) return;
            },
            .eof => return,
            else => {},
        }
    }
}

/// After a `keyword_while`, consumes its `(cond)` and returns true when a
/// `|capture|` follows (iterator loop). If instead the body `{` is consumed,
/// bumps `depth` so brace balance stays correct.
fn whileIsCapturing(tok: *std.zig.Tokenizer, depth: *u32) bool {
    consumeParenGroup(tok);
    const nxt = tok.next();
    switch (nxt.tag) {
        .pipe => return true,
        .l_brace => {
            depth.* += 1;
            return false;
        },
        else => return false,
    }
}

/// After `if (cond) return`, consumes the rest of the return statement (to the
/// balanced `;`) and returns true if it mentions `SkipZigTest`.
fn thenClauseIsSkip(tok: *std.zig.Tokenizer, z: []const u8) bool {
    var nesting: i32 = 0;
    var found = false;
    while (true) {
        const t = tok.next();
        switch (t.tag) {
            .l_brace, .l_paren, .l_bracket => nesting += 1,
            .r_brace, .r_paren, .r_bracket => nesting -= 1,
            .semicolon => if (nesting <= 0) return found,
            .identifier => {
                if (std.mem.eql(u8, z[t.loc.start..t.loc.end], "SkipZigTest")) found = true;
            },
            .eof => return found,
            else => {},
        }
    }
}

fn report(ctx: *ScanCtx, z: []const u8, byte: usize, reason: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const line = lineOf(z, byte);
    const msg = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ ctx.rel_path, line, reason });
    try ctx.violations.append(a, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
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

/// Entry point for the test-no-conditional check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("test-no-conditional: tests are free of top-level branching", .{});
        return;
    }
    reporter.fail("test-no-conditional FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: split a conditional test into two independent tests; use a single table-driven `for`.\n", .{});
    return error.CheckFailed;
}

// spec: Test Hygiene - Rejects if/while/switch and extra for loops at the top level of a test body

test "analyzeContent flags top-level if in test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "branchy" {
        \\    if (true) {
        \\        try std.testing.expect(true);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
test "analyzeContent allows the SkipZigTest idiom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "skips" {
        \\    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
        \\    try std.testing.expect(true);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
test "analyzeContent allows a capturing iterator while, flags a conditional one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok_iter = try analyzeContent(a, "src/x.zig",
        \\test "iterates" {
        \\    var it = map.iterator();
        \\    while (it.next()) |e| {
        \\        try std.testing.expect(e.value > 0);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), ok_iter.len);
    const bad_cond = try analyzeContent(a, "src/x.zig",
        \\test "loops" {
        \\    while (cond) {
        \\        try std.testing.expect(true);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), bad_cond.len);
}

test "analyzeContent allows single table-driven for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "table" {
        \\    const cases = [_]u32{ 1, 2, 3 };
        \\    for (cases) |c| {
        \\        try std.testing.expect(c > 0);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags second top-level for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "two loops" {
        \\    for (a) |x| try expect(x > 0);
        \\    for (b) |y| try expect(y > 0);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows nested if inside for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "nested ok" {
        \\    for (cases) |c| {
        \\        if (c.skip) continue;
        \\        try expect(c.value > 0);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
