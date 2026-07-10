//! `assert-doc-consistency` — a fn whose doc comment claims a precondition with
//! the Zig-core convention (the capitalized marker word) must actually enforce
//! it: the body has to contain at least one `assert(` call. This catches an
//! agent — or a drifting refactor — that writes `/// Asserts x > 0` but never
//! guards it, so the doc lies about a precondition the code doesn't check.
//!
//! Precision-first / zero-noise by construction. The doc trigger is the whole
//! word matched CASE-SENSITIVELY (the Zig std `/// Asserts ...` convention), so
//! lowercase prose like "asserts that" mid-sentence, or a longer word like
//! "Assertion", never fires. The body satisfier is the substring `assert(`,
//! which every call form carries (`std.debug.assert(`, `debug.assert(`, a bare
//! `assert(`) and which `assertFoo(` — no `(` right after `assert` — never
//! matches. A file can be exempted via `[[allow]] check = "assert-doc-consistency"`.

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const decls = @import("../ast/decls.zig");
const lineOf = @import("../text.zig").lineOf;

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// Registry name (also the [[allow]] key).
pub const CHECK_NAME = "assert-doc-consistency";
/// The capitalized doc-marker word that signals a precondition claim.
const DOC_MARKER = "Asserts";
/// The call substring that satisfies the claim in a fn body.
const ASSERT_CALL = "assert(";

/// True when `c` is an identifier character — the word-boundary test.
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when `doc` carries the precondition marker (`DOC_MARKER`) as a whole
/// word: case-sensitive, bounded on both sides by a non-identifier char (or the
/// string edge). Whole-word + case-sensitive is what keeps this zero-noise —
/// lowercase prose or a longer word never counts as a claim.
fn docClaimsMarker(doc: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, doc, i, DOC_MARKER)) |at| {
        const before_ok = at == 0 or !isIdentChar(doc[at - 1]);
        const after = at + DOC_MARKER.len;
        const after_ok = after == doc.len or !isIdentChar(doc[after]);
        if (before_ok and after_ok) return true;
        i = at + 1;
    }
    return false;
}

/// True when `decl_source` (a fn decl's `fn`-keyword-through-`}` span) contains
/// an `assert(` call. A substring is enough: zig fmt normalizes the call form,
/// so every real call carries `assert(` exactly while `assertFoo(` does not.
fn bodyHasAssertCall(decl_source: []const u8) bool {
    return std.mem.indexOf(u8, decl_source, ASSERT_CALL) != null;
}

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    /// [[allow]] path globs for this check; a matching file is skipped whole.
    allowed_paths: []const []const u8 = &.{},
};

/// Scans one parsed file, appending a violation line for every fn whose doc
/// claims the marker but whose body has no `assert(` call.
fn scanTree(ctx: *ScanCtx, rel_path: []const u8, tree_ptr: *const Ast) std.mem.Allocator.Error!void {
    const a = ctx.allocator;
    var tree = tree_ptr.*;
    for (try decls.collectDecls(a, &tree)) |decl| {
        if (tree.nodeTag(decl) != .fn_decl) continue;
        const doc = (try decls.precedingDocText(a, &tree, decl)) orelse continue;
        if (!docClaimsMarker(doc)) continue;

        const first = tree.firstToken(decl);
        const last = tree.lastToken(decl);
        const start = tree.tokenStart(first);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        if (bodyHasAssertCall(tree.source[start..end])) continue;

        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        try ctx.violations.append(a, try std.fmt.allocPrint(
            a,
            "{s}:{d}: fn {s} doc claims a precondition ({s}) but its body has no {s} call",
            .{ rel_path, lineOf(tree.source, start), tree.tokenSlice(name_tok), DOC_MARKER, ASSERT_CALL },
        ));
    }
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    for (ctx.allowed_paths) |pat| {
        if (walk.matchGlob(entry.rel_path, pat)) return;
    }
    if (entry.tree) |t| {
        try scanTree(ctx, entry.rel_path, t);
    } else {
        var tree = try Ast.parse(ctx.allocator, entry.content, .zig);
        try scanTree(ctx, entry.rel_path, &tree);
    }
}

/// Pure-function entry: violation lines for one file's `content` (allocator-
/// owned). Empty slice = consistent. Used by the inline tests.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };
    const z = try allocator.dupeZ(u8, content);
    var tree = try Ast.parse(allocator, z, .zig);
    try scanTree(&ctx, rel_path, &tree);
    return violations.toOwnedSlice(allocator);
}

/// Entry point for the assert-doc-consistency check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .allowed_paths = ctx_param.cfg.extraAllowed(CHECK_NAME),
    };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("assert-doc-consistency: every '{s}' doc has a matching {s} call", .{ DOC_MARKER, ASSERT_CALL });
        return;
    }
    fail("assert-doc-consistency FAILED ({d} doc(s) without a body assert)", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print(
        "  fix: add the {s} the doc promises, or reword the doc to drop the '{s}' claim.\n",
        .{ ASSERT_CALL, DOC_MARKER },
    );
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Assert Doc Consistency - Flags a fn whose doc claims an assertion but whose body has none

test "analyzeContent flags a doc precondition claim with no body assert" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\/// Asserts the index is in range.
        \\pub fn at(i: usize) usize {
        \\    return i;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0], "fn at") != null);
}

// spec: Assert Doc Consistency - Accepts a claiming doc backed by an assert call

test "analyzeContent accepts a claiming doc whose body has an assert" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Both the qualified std.debug.assert and a bare assert satisfy the claim,
    // and a fn with no claim is never examined.
    const content =
        \\/// Asserts the index is in range.
        \\pub fn at(i: usize, n: usize) usize {
        \\    std.debug.assert(i < n);
        \\    return i;
        \\}
        \\/// Asserts non-empty.
        \\fn head(xs: []const u8) u8 {
        \\    assert(xs.len > 0);
        \\    return xs[0];
        \\}
        \\/// A plain undocumented-precondition helper.
        \\pub fn plain() void {}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Assert Doc Consistency - Ignores lowercase or mid-word marker prose

test "analyzeContent ignores lowercase prose and longer words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "asserts" (lowercase), "Assertion" (longer word), and "reAsserts"
    // (no leading boundary) are prose, not the whole-word capitalized marker,
    // so none demands a body assert.
    const content =
        \\/// This helper asserts nothing and does no real work here.
        \\pub fn a1() void {}
        \\/// Assertion helpers live elsewhere in the module.
        \\pub fn a2() void {}
        \\/// The caller reAsserts the lock before returning to the loop.
        \\pub fn a3() void {}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Assert Doc Consistency - Reports the fn name and line of a missing assert

test "analyzeContent reports the offending fn name and line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const std = @import("std");
        \\
        \\/// Asserts the slice is sorted.
        \\fn merge(xs: []const u8) void {
        \\    _ = xs;
        \\}
    ;
    const out = try analyzeContent(a, "src/y.zig", content);
    try testing.expectEqual(@as(usize, 1), out.len);
    // The fn keyword is on line 4; the message carries file:line and the name.
    try testing.expect(std.mem.indexOf(u8, out[0], "src/y.zig:4:") != null);
    try testing.expect(std.mem.indexOf(u8, out[0], "fn merge") != null);
}
