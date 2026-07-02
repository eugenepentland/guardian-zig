const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Test Hygiene - Rejects if/while/switch and extra for loops at the top level of a test body

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

        try scanBody(ctx, a, z, &tok);
    }
}

fn scanBody(ctx: *ScanCtx, a: Allocator, z: []const u8, tok: *std.zig.Tokenizer) Allocator.Error!void {
    var depth: u32 = 1;
    var top_loop_count: u32 = 0;
    while (depth > 0) {
        const t = tok.next();
        if (t.tag == .eof) return;
        switch (t.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            .keyword_for => {
                if (depth == 1) {
                    top_loop_count += 1;
                    if (top_loop_count > 1) {
                        try report(ctx, a, z, t.loc.start, "more than one top-level loop");
                    }
                }
            },
            .keyword_while => {
                if (depth == 1) {
                    // A capturing `while (it.next()) |x|` is an iterator loop —
                    // functionally the allowed table-driven `for`, not a
                    // conditional. Only a plain conditional while is flagged.
                    if (whileIsCapturing(tok, &depth)) {
                        top_loop_count += 1;
                        if (top_loop_count > 1) {
                            try report(ctx, a, z, t.loc.start, "more than one top-level loop");
                        }
                    } else {
                        try report(ctx, a, z, t.loc.start, "while at top level of test body");
                    }
                }
            },
            .keyword_if => {
                if (depth == 1) {
                    // Allow the standard skip idiom `if (cond) return
                    // error.SkipZigTest;` — it's how a test opts out, not logic.
                    consumeParenGroup(tok);
                    const nxt = tok.next();
                    if (nxt.tag == .keyword_return and thenClauseIsSkip(tok, z)) {
                        // allowed
                    } else {
                        if (nxt.tag == .l_brace) depth += 1;
                        try report(ctx, a, z, t.loc.start, "if at top level of test body");
                    }
                }
            },
            .keyword_switch => {
                if (depth == 1) try report(ctx, a, z, t.loc.start, "switch at top level of test body");
            },
            else => {},
        }
    }
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

fn report(
    ctx: *ScanCtx,
    a: Allocator,
    z: []const u8,
    byte: usize,
    reason: []const u8,
) Allocator.Error!void {
    const line = lineOf(z, byte);
    const msg = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ ctx.rel_path, line, reason });
    try ctx.violations.append(a, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
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
