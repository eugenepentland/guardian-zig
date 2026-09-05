//! test-has-assertion check: require every named test block to contain at least
//! one assertion — a `try` (error-propagation counts) or an `expect*`/`assert*`
//! call. Anonymous `test { … }` aggregators are exempt. Token-based, so a
//! `expected` variable or a comment never counts as an assertion.

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
    violations: *std.ArrayList([]const u8),
};

/// Pure-function entry: scans `content` for `test "..." { ... }` blocks
/// whose body has no `expect*` token.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

// twin-drift-ok: test-skip-ban walks the same test-header token stream and asks
// a different question of each body (does it assert, vs is it skipped or
// empty); the divergence is the question, not an unpropagated edit.
fn scan(ctx: *ScanCtx, z: [:0]const u8) Allocator.Error!void {
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_test) continue;
        const test_byte = t.loc.start;

        const header = scanTestHeader(&tok);
        if (!header.reached_lbrace) continue;

        // A named test (`test "..."` or decltest `test foo`) with no assertion
        // in its body is a violation. Anonymous tests (`test { ... }`) are
        // typically aggregators (`_ = @import(...)`) and are exempt.
        if (header.has_name and !bodyHasAssertion(&tok, z)) {
            try appendMissingAssertion(ctx, lineOf(z, test_byte));
        }
    }
}

const TestHeader = struct { has_name: bool, reached_lbrace: bool };

/// Consumes tokens from just after `test` up to and including the opening
/// `{`. Reports whether a name (string literal or identifier) preceded it —
/// a decltest `test foo` has an identifier name and IS a real test.
fn scanTestHeader(tok: *std.zig.Tokenizer) TestHeader {
    var has_name = false;
    while (true) {
        const t = tok.next();
        if (t.tag == .string_literal or t.tag == .identifier) has_name = true;
        if (t.tag == .l_brace) return .{ .has_name = has_name, .reached_lbrace = true };
        if (t.tag == .eof) return .{ .has_name = has_name, .reached_lbrace = false };
    }
}

/// Scans a test body token-by-token (never a raw substring, which matched a
/// variable named `expected` or a comment and missed try-based/custom
/// assertions). An assertion is a `try` (error-propagation counts) or an
/// `expect*`/`assert*` call. Consumes through the body's closing `}`.
fn bodyHasAssertion(tok: *std.zig.Tokenizer, z: [:0]const u8) bool {
    var depth: u32 = 1;
    var has_assertion = false;
    while (true) {
        const inner = tok.next();
        switch (inner.tag) {
            .eof => break,
            .l_brace => depth += 1,
            .r_brace => {
                depth -= 1;
                if (depth == 0) break;
            },
            .keyword_try => has_assertion = true,
            .identifier => has_assertion = has_assertion or
                isAssertionName(z[inner.loc.start..inner.loc.end]),
            else => {},
        }
    }
    return has_assertion;
}

fn appendMissingAssertion(ctx: *ScanCtx, line: u32) Allocator.Error!void {
    const a = ctx.allocator;
    const msg = try std.fmt.allocPrint(
        a,
        "{s}:{d}: test has no assertion (expect*/assert*/try)",
        .{ ctx.rel_path, line },
    );
    try ctx.violations.append(a, msg);
}

/// How many assertions `z` contains, by the same token rule this check gates
/// on: a `try` (error-propagation counts) or an `expect*` / `assert*` call.
///
/// Shared so `test-erosion` can measure whether a rewritten test body kept as
/// many assertions as it had, without re-deciding what an assertion is — two
/// answers to that question would let a test lose its only real check while one
/// of the two gates still called the body assertive.
///
/// Unscoped on purpose: the caller decides what `z` covers (a whole file, one
/// body, the added lines of a diff hunk). Assertion-shaped tokens in a comment
/// are not counted — the tokenizer skips comments — but a token inside a string
/// literal is likewise invisible, so this counts calls, not text.
pub fn assertionCount(z: [:0]const u8) u32 {
    var tok = std.zig.Tokenizer.init(z);
    var count: u32 = 0;
    while (true) {
        const t = tok.next();
        switch (t.tag) {
            .eof => return count,
            .keyword_try => count += 1,
            .identifier => if (isAssertionName(z[t.loc.start..t.loc.end])) {
                count += 1;
            },
            else => {},
        }
    }
}

/// True for std.testing / std.debug assertion call names: exactly `expect` or
/// `assert`, or those prefixes continued in camelCase (expectEqual,
/// expectError, assertEqual). A lowercase continuation (`expected`,
/// `assertion`) is a variable, not a call, so it does not match.
fn isAssertionName(name: []const u8) bool {
    return matchesAssertPrefix(name, "expect") or matchesAssertPrefix(name, "assert");
}

fn matchesAssertPrefix(name: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (name.len == prefix.len) return true;
    return std.ascii.isUpper(name[prefix.len]);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
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

/// Entry point for the test-has-assertion check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("test-has-assertion: every test block has an expect* call", .{});
        return;
    }
    reporter.fail("test-has-assertion FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: add at least one `try std.testing.expect*` call to verify behavior.\n", .{});
    return error.CheckFailed;
}

// spec: Test Hygiene - Requires every test block to contain at least one std.testing.expect call

test "analyzeContent flags test with no expect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "side effect only" {
        \\    var x: u32 = 1;
        \\    x += 1;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
test "analyzeContent: `expected` variable does not count as an assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "no real assertion" {
        \\    const expected: u32 = 1;
        \\    _ = expected;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
test "analyzeContent: a bare try counts as a (weak) assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "propagates" {
        \\    try doSomethingThatMayError();
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
test "analyzeContent: decltests are not exempt like anonymous tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test decltestName {
        \\    var x: u32 = 1;
        \\    x += 1;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows test with expectEqual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "with assertion" {
        \\    try std.testing.expectEqual(@as(u32, 2), 1 + 1);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Test Hygiene - Counts the assertions in a snippet by the same rule the gate uses

test "assertionCount counts try and expect/assert calls but not lookalike names" {
    // `try` + `expectEqual` + `assert` = 3; `expected` and `assertion` are
    // variables, and the same rule the gate uses must not count them.
    try std.testing.expectEqual(@as(u32, 3), assertionCount(
        \\const expected: u32 = 1;
        \\const assertion = 2;
        \\try std.testing.expectEqual(expected, one());
        \\std.debug.assert(assertion == 2);
    ));
    try std.testing.expectEqual(@as(u32, 0), assertionCount(""));
}

test "analyzeContent allows aliased expect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const expect = std.testing.expect;
        \\test "alias works" {
        \\    try expect(true);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
