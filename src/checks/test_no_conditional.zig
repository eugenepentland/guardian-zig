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
// twin-drift-ok: this is the check-plugin protocol under a name the
// `[twin_drift] ignore` list cannot spell. Every scanning check builds its own
// ScanCtx, calls its own `scan`, and returns; `bool-ops-per-condition`'s
// `analyzeContentWithLimit` is that shape too. The three lines they share are
// the protocol; the ctx and the scan behind it are each check's own.
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

/// One top-level loop in a test body: where it starts, and whether anything
/// inside it asserts. An assertion-free loop is the fixture-builder shape — the
/// one worth extracting when a test has several loops.
const LoopRec = struct { line: u32, has_assert: bool = false };

/// Mutable state and shared inputs threaded through the per-keyword handlers
/// while scanning a single test body. `depth` starts at 1 (the body itself).
const BodyScan = struct {
    ctx: *ScanCtx,
    z: []const u8,
    tok: *std.zig.Tokenizer,
    /// The enclosing test's name, carried into each violation's identity.
    test_name: []const u8,
    depth: u32 = 1,
    /// Every top-level loop seen so far, in source order.
    loops: std.ArrayList(LoopRec) = .empty,
    /// Index into `loops` of the loop currently being scanned for assertions,
    /// or null between loops.
    active_loop: ?usize = null,
    /// This body's extra-loop findings, whose message is finalized once every
    /// loop's assertion status is known.
    extra_loops: std.ArrayList(ExtraLoop) = .empty,
};

/// One flagged extra loop: where its record sits in `ctx.violations`, and the
/// line of the loop it flagged — the one to hoist when no loop stands out as a
/// fixture builder.
const ExtraLoop = struct { violation: usize, line: u32 };

fn scanBody(ctx: *ScanCtx, z: []const u8, tok: *std.zig.Tokenizer, test_name: []const u8) Allocator.Error!void {
    var bs: BodyScan = .{ .ctx = ctx, .z = z, .tok = tok, .test_name = test_name };
    while (bs.depth > 0) {
        const t = tok.next();
        if (t.tag == .eof) break;
        noteAssertion(&bs, t);
        switch (t.tag) {
            .l_brace => bs.depth += 1,
            .r_brace => bs.depth -= 1,
            .keyword_for => try handleLoop(&bs, t.loc.start),
            .keyword_while => try handleWhile(&bs, t.loc.start),
            .keyword_if => try handleIf(&bs, t.loc.start),
            .keyword_switch => try handleSwitch(&bs, t.loc.start),
            else => {},
        }
        closeLoopIfEnded(&bs, t.tag);
    }
    try nameExtractionCandidate(&bs);
}

/// Records that the loop currently being scanned contains an assertion call.
/// `try` alone is deliberately NOT enough: a fixture builder is full of `try
/// list.append(...)`, and counting that would make every loop look assertive.
fn noteAssertion(bs: *BodyScan, t: std.zig.Token) void {
    const idx = bs.active_loop orelse return;
    if (t.tag != .identifier) return;
    if (!isAssertionName(bs.z[t.loc.start..t.loc.end])) return;
    bs.loops.items[idx].has_assert = true;
}

/// Ends the active loop's extent: its braced body closed back to the top level,
/// or a braceless `for (x) |v| stmt;` reached its terminating semicolon.
fn closeLoopIfEnded(bs: *BodyScan, tag: std.zig.Token.Tag) void {
    if (bs.active_loop == null or bs.depth != 1) return;
    if (tag == .r_brace or tag == .semicolon) bs.active_loop = null;
}

/// Counts a top-level loop and flags the second (and later) one. The finding's
/// message is provisional: which loop to extract is only known once the whole
/// body has been scanned (see `nameExtractionCandidate`).
fn handleLoop(bs: *BodyScan, byte: usize) Allocator.Error!void {
    if (bs.depth != 1) return;
    const line = lineOf(bs.z, byte);
    try bs.loops.append(bs.ctx.allocator, .{ .line = line });
    bs.active_loop = bs.loops.items.len - 1;
    if (bs.loops.items.len > 1) {
        try report(bs, byte, "loop", multi_loop_reason);
        try bs.extra_loops.append(bs.ctx.allocator, .{
            .violation = bs.ctx.violations.items.len - 1,
            .line = line,
        });
    }
}

/// The bare finding text: the count, with no remedy attached. Kept as the opener
/// of both finalized messages so the historical wording still greps.
const multi_loop_reason = "more than one top-level loop";

/// The rule the count is measured against, stated in the finding itself. Six
/// separate reports read the bare count as "loops are banned here" or went
/// looking for the wrong loop, because the message never said what the budget is.
const loop_rule = multi_loop_reason ++ " — a test may keep one; ";

/// Fixture-split shape: one loop asserts and another does not, so the
/// assertion-free one is setup and is the one to move out.
const fixture_loop_fmt = loop_rule ++ "the loop at line {d} asserts nothing, so hoist that one into a named helper";

/// Every top-level loop asserts (or none does): nothing is a fixture builder, so
/// the finding names its OWN loop instead of claiming a loop asserts nothing —
/// a claim that was simply false when both loops carried expects.
const extra_loop_fmt = loop_rule ++ "hoist the loop at line {d} into a named helper, " ++
    "or merge the loops into one table-driven loop";

/// States the rule and points the reader at the loop to move. A test with one
/// loop that asserts and another that does not is the fixture-builder shape: the
/// assertion-free loop is setup, and moving *that* one into a helper leaves the
/// assertions where they belong. When every loop asserts there is no such split,
/// so each finding names its own loop rather than a loop that "asserts nothing".
/// Naming both the rule and the target costs nothing here and saves the gate
/// cycle otherwise spent guessing what the check meant.
fn nameExtractionCandidate(bs: *BodyScan) Allocator.Error!void {
    if (bs.extra_loops.items.len == 0) return;
    if (fixtureLoop(bs.loops.items)) |candidate| {
        const msg = try std.fmt.allocPrint(bs.ctx.allocator, fixture_loop_fmt, .{candidate.line});
        for (bs.extra_loops.items) |extra| bs.ctx.violations.items[extra.violation].message = msg;
        return;
    }
    for (bs.extra_loops.items) |extra| {
        const msg = try std.fmt.allocPrint(bs.ctx.allocator, extra_loop_fmt, .{extra.line});
        bs.ctx.violations.items[extra.violation].message = msg;
    }
}

/// The first assertion-free loop, but only when another loop in the same test
/// does assert — otherwise there is no fixture/assertion split to point at and
/// the check says nothing it cannot back up.
fn fixtureLoop(loops: []const LoopRec) ?LoopRec {
    var candidate: ?LoopRec = null;
    var any_asserts = false;
    for (loops) |l| {
        if (l.has_assert) any_asserts = true else if (candidate == null) candidate = l;
    }
    return if (any_asserts) candidate else null;
}

/// True for std.testing / std.debug assertion call names — `expect`/`assert`
/// exactly, or continued in camelCase (expectEqual, assertEqual). A lowercase
/// continuation (`expected`) is a variable, not a call. Mirrors the same rule in
/// the test-has-assertion check.
fn isAssertionName(name: []const u8) bool {
    return assertPrefix(name, "expect") or assertPrefix(name, "assert");
}

fn assertPrefix(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (name.len == prefix.len) return true;
    return std.ascii.isUpper(name[prefix.len]);
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
        "loop, split a branch into two independent tests, or hoist the computation into a helper. " ++
        "A multi-loop finding names the loop to hoist — the assertion-free one when there is one, " ++
        "otherwise the extra loop itself.\n", .{});
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

// spec: Test Hygiene - Names the assertion-free loop as the one to extract

test "analyzeRecords points a multi-loop finding at the fixture loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The reported shape: a fixture builder that fills a board, then the loop
    // that actually asserts. Guessing which one the check meant costs a full
    // gate cycle, so the finding names the assertion-free one by line.
    const recs = try analyzeRecords(a, "src/x.zig",
        \\test "two loops" {
        \\    var board: [9]u8 = undefined;
        \\    for (&board, 0..) |*cell, i| {
        \\        cell.* = @intCast(i);
        \\    }
        \\    for (board) |cell| {
        \\        try std.testing.expect(cell < 9);
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    // The finding still sits on the second loop (line 6) — it is the one the
    // rule flags — but the message points at the fixture loop on line 3.
    try std.testing.expectEqual(@as(u32, 6), recs[0].line.?);
    try std.testing.expect(std.mem.indexOf(u8, recs[0].message, "line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, recs[0].message, "asserts nothing") != null);
}

// spec: Test Hygiene - Names a loop to hoist when every top-level loop asserts

test "analyzeRecords states the rule and names its own loop when both loops assert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two asserting loops: the old message claimed one of them "asserts nothing",
    // which was simply false, and never said what the budget was.
    const recs = try analyzeRecords(a, "src/x.zig",
        \\test "both assert" {
        \\    for (a1) |x| try std.testing.expect(x > 0);
        \\    for (b1) |y| try std.testing.expect(y > 0);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    // The rule is in the finding: one top-level loop is the budget.
    try std.testing.expect(std.mem.indexOf(u8, recs[0].message, "a test may keep one") != null);
    // It names the extra loop (line 3) as the one to hoist, and claims nothing
    // about assertions it cannot back up.
    try std.testing.expect(std.mem.indexOf(u8, recs[0].message, "line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, recs[0].message, "asserts nothing") == null);
    // Identity is unchanged by the rewording — a consumer's baseline keys on the
    // file, the test and the keyword, never on this prose.
    try std.testing.expectEqualStrings("src/x.zig|both assert|loop", recs[0].identity.?);
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
