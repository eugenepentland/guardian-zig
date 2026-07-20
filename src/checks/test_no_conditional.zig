//! test-no-conditional check: reject if/while/switch (and a second `for`) at the
//! top level of a test body — branching in a test usually means it silently
//! skips the case it was meant to pin. One table-driven `for` is allowed.

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
    violations: *std.ArrayList(reporter.Violation),
};

/// Structured entry: the violation records, carrying the stable identity the
/// baseline keys on. `analyzeContent` renders these to the same lines it always
/// returned, so the golden harness and the string-shaped callers are unaffected.
pub fn analyzeRecords(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const reporter.Violation {
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

/// Pure-function entry: scans `content` for control flow at the top level
/// of test bodies. A single `for` is allowed (table-driven case loop).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const []const u8 {
    return reporter.flatLines(allocator, try analyzeRecords(allocator, rel_path, content));
}

fn scan(ctx: *ScanCtx, z: [:0]const u8) Allocator.Error!void {
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_test) continue;

        // Everything between `test` and the body brace is the test's name (a
        // string literal, or a bare identifier for `test declName {}`). It is
        // the stable half of the violation identity: line numbers move and the
        // prose reason may be reworded, but "the switch in test X" does not.
        var name: []const u8 = "";
        var lbrace: std.zig.Token = undefined;
        while (true) {
            lbrace = tok.next();
            if (lbrace.tag == .l_brace or lbrace.tag == .eof) break;
            if (lbrace.tag == .string_literal or lbrace.tag == .identifier) {
                name = std.mem.trim(u8, z[lbrace.loc.start..lbrace.loc.end], "\"");
            }
        }
        if (lbrace.tag != .l_brace) continue;

        try scanBody(ctx, z, &tok, name);
    }
}

/// Mutable state and shared inputs threaded through the per-keyword handlers
/// while scanning a single test body. `depth` starts at 1 (the body itself).
const BodyScan = struct {
    ctx: *ScanCtx,
    z: []const u8,
    tok: *std.zig.Tokenizer,
    /// The enclosing test's name, carried into each violation's identity.
    test_name: []const u8,
    depth: u32 = 1,
    top_loop_count: u32 = 0,
};

fn scanBody(ctx: *ScanCtx, z: []const u8, tok: *std.zig.Tokenizer, test_name: []const u8) Allocator.Error!void {
    var bs: BodyScan = .{ .ctx = ctx, .z = z, .tok = tok, .test_name = test_name };
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
        try report(bs, byte, "loop", "more than one top-level loop");
    }
}

/// Flags a `switch` at the top level of a test body.
fn handleSwitch(bs: *BodyScan, byte: usize) Allocator.Error!void {
    if (bs.depth != 1) return;
    try report(bs, byte, "switch", "switch at top level of test body");
}

/// A capturing `while (it.next()) |x|` is an iterator loop — functionally the
/// allowed table-driven `for`, not a conditional. Only a plain conditional
/// while is flagged.
fn handleWhile(bs: *BodyScan, byte: usize) Allocator.Error!void {
    if (bs.depth != 1) return;
    if (whileIsCapturing(bs.tok, &bs.depth)) {
        try handleLoop(bs, byte);
    } else {
        try report(bs, byte, "while", "while at top level of test body");
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
    try report(bs, byte, "if", "if at top level of test body");
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

/// Records one violation. `construct` is the offending keyword — the stable
/// half of the identity, unlike `reason`, which is prose and may be reworded.
/// The identity self-qualifies with the file because tier 1 keys are used
/// whole, without being re-qualified (see violation_key.fromRecord).
fn report(bs: *BodyScan, byte: usize, construct: []const u8, reason: []const u8) Allocator.Error!void {
    const a = bs.ctx.allocator;
    const identity = try std.fmt.allocPrint(
        a,
        "{s}|{s}|{s}",
        .{ bs.ctx.rel_path, bs.test_name, construct },
    );
    try bs.ctx.violations.append(a, .{
        .check = check_name,
        .file = bs.ctx.rel_path,
        .line = lineOf(bs.z, byte),
        .message = reason,
        .identity = identity,
    });
}

/// The check's registry name, reused as each record's `check` field.
const check_name = "test-no-conditional";

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

/// Entry point for the test-no-conditional check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("test-no-conditional: tests are free of top-level branching", .{});
        return;
    }
    reporter.fail("test-no-conditional FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  why: tests assert, helpers compute — a conditional or a second loop can " ++
        "silently skip the assertion it was meant to pin.\n", .{});
    detail("  fix: one top-level loop is fine; merge multiple loops into one table-driven " ++
        "loop, split a branch into two independent tests, or hoist the computation into a helper.\n", .{});
    return error.CheckFailed;
}

// spec: Test Hygiene - Identifies a flagged construct by its test and keyword

test "analyzeRecords identifies by test name and keyword, not the prose reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recs = try analyzeRecords(a, "src/x.zig",
        \\test "alpha" {
        \\    switch (x) { else => {} }
        \\}
        \\test "beta" {
        \\    if (cond) {}
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), recs.len);
    // Identity names the file, the enclosing test and the offending keyword —
    // no line number, and none of the reworded prose.
    try std.testing.expectEqualStrings("src/x.zig|alpha|switch", recs[0].identity.?);
    try std.testing.expectEqualStrings("src/x.zig|beta|if", recs[1].identity.?);
    try std.testing.expectEqual(@as(u32, 2), recs[0].line.?);
    // Rendering is unchanged: flatLine reproduces the pre-migration text.
    const lines = try reporter.flatLines(a, recs);
    try std.testing.expectEqualStrings("src/x.zig:2: switch at top level of test body", lines[0]);
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
