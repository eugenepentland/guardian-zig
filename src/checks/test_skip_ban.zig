const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

/// How the first statement of a test body classifies. `unconditional_skip`
/// is a body whose first statement is `return error.SkipZigTest;` (a test
/// that never runs yet still satisfies its `// spec:` tag); `empty` is a body
/// with no statements at all; `other` is any real body — including a
/// conditional `if (...) return error.SkipZigTest;`, which is legitimate.
const BodyKind = enum { other, empty, unconditional_skip };

/// Tokens of a test body's first statement inspected to classify it: a
/// `return error.SkipZigTest` prefix is exactly four tokens.
const PREFIX_TOKENS = 4;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for `test { ... }` blocks whose body
/// is empty or begins with an unconditional `return error.SkipZigTest;`.
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
        const test_byte = t.loc.start;

        if (!reachLBrace(&tok)) continue;
        switch (classifyBody(&tok, z)) {
            .empty => try report(ctx, z, test_byte, "empty test body asserts nothing"),
            .unconditional_skip => try report(ctx, z, test_byte, "test body unconditionally returns error.SkipZigTest"),
            .other => {},
        }
    }
}

/// Consumes tokens from just after `test` up to and including the opening
/// `{`. Returns false at EOF before a brace (a malformed / partial test).
fn reachLBrace(tok: *std.zig.Tokenizer) bool {
    while (true) {
        const t = tok.next();
        if (t.tag == .l_brace) return true;
        if (t.tag == .eof) return false;
    }
}

/// Classifies a test body, consuming its tokens through the matching `}` so
/// the outer scan resumes at the next top-level token. `tok` is positioned
/// just past the body's opening `{` (brace depth 1). An empty body records no
/// prefix tokens; an unconditional skip has `return` as its first token and a
/// `SkipZigTest` identifier within the statement prefix.
fn classifyBody(tok: *std.zig.Tokenizer, z: [:0]const u8) BodyKind {
    var depth: u32 = 1;
    var seen: usize = 0;
    var tags: [PREFIX_TOKENS]std.zig.Token.Tag = undefined;
    var saw_skip_ident = false;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .l_brace) depth += 1;
        if (t.tag == .r_brace) {
            depth -= 1;
            if (depth == 0) break;
        }
        if (seen < tags.len) {
            tags[seen] = t.tag;
            if (t.tag == .identifier and std.mem.eql(u8, z[t.loc.start..t.loc.end], "SkipZigTest"))
                saw_skip_ident = true;
        }
        seen += 1;
    }
    if (seen == 0) return .empty;
    if (isUnconditionalSkip(tags[0..@min(seen, tags.len)], saw_skip_ident)) return .unconditional_skip;
    return .other;
}

/// True when a body's first-statement prefix is `return error.SkipZigTest`.
/// A conditional skip leads with `if`, so `tags[0]` is not `return` and this
/// stays false — the whole point of allowing guarded skips.
fn isUnconditionalSkip(tags: []const std.zig.Token.Tag, saw_skip_ident: bool) bool {
    return tags.len > 0 and tags[0] == .keyword_return and saw_skip_ident;
}

fn report(ctx: *ScanCtx, z: [:0]const u8, byte: usize, reason: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const msg = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ ctx.rel_path, lineOf(z, byte), reason });
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

/// Entry point for the test-skip-ban check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("test-skip-ban: no unconditionally-skipped or empty tests", .{});
        return;
    }
    reporter.fail("test-skip-ban FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: implement the test (assert real behavior) or delete it and its // spec: tag.\n", .{});
    return error.CheckFailed;
}

// spec: Test Skip Ban - Flags a test whose first statement is an unconditional SkipZigTest

test "analyzeContent flags an unconditional SkipZigTest body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "not done yet" {
        \\    return error.SkipZigTest;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Test Skip Ban - Allows a conditional SkipZigTest guard

test "analyzeContent allows a guarded SkipZigTest and a following body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "conditionally skips" {
        \\    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
        \\    try std.testing.expect(true);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Test Skip Ban - Flags a test with an empty body

test "analyzeContent flags an empty test body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "placeholder" {}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Test Skip Ban - Allows a test with a real assertion body

test "analyzeContent allows a real test body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "does work" {
        \\    try std.testing.expectEqual(@as(u32, 2), 1 + 1);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent does not flag an anonymous import aggregator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test {
        \\    _ = @import("other.zig");
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores a SkipZigTest string mentioned mid-body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The skip is not the first statement, and only named in a string — a real
    // test body that happens to mention the error must not be flagged.
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "mentions skip" {
        \\    const note = "return error.SkipZigTest";
        \\    try std.testing.expect(note.len > 0);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
