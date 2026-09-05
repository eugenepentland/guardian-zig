//! compound-assert — flag `std.debug.assert(a and b)`; one assert per conjunct.
//!
//! WHY: `assert` reports only that *the* condition was false. A conjunction
//! collapses several independent claims into one failure site, so the panic
//! names the line and nothing else — the reader still has to re-derive which
//! half broke, and in a release-safe binary there is no expression text to read.
//! Split, each conjunct gets its own line number, and the failure identifies
//! itself:
//!
//!     assert(i < len and buf[i] == 0);      // "which one?"
//!     assert(i < len);                      // vs. two lines, two answers
//!     assert(buf[i] == 0);
//!
//! Splitting is *semantics-preserving* for `std.debug.assert` specifically:
//! `and` short-circuits, and the first assert aborts before the second is
//! evaluated, so a conjunct that is only well-defined when its predecessor holds
//! (the bounds-check idiom above) stays safe. That equivalence is the whole
//! justification, and it is exactly what a project's own `assert` may not have.
//!
//! FALSE-POSITIVE GUARD (the load-bearing part): a project-defined `assert` is
//! NEVER flagged. A local `fn assert(...)` may log, count, accumulate, or return
//! — calling it twice is not the same program. So the check flags a call only
//! when it can NAME the callee as std's:
//!   * the literal chain `std.debug.assert(...)`,
//!   * a call through a binding proven equal to it — `const assert =
//!     std.debug.assert;` or `@import("std").debug.assert`, and
//!   * `<alias>.assert(...)` where `<alias>` is bound to `std.debug`.
//! Anything else — a bare `assert(` with no such binding in the file, a file
//! that declares its own `fn assert`, a binding rebound to something else —
//! is left alone. The default is "not std's", so an unrecognized spelling
//! under-reports rather than rewriting code that could change behavior.
//!
//! LIMITATIONS, deliberate: only `and` is flagged (`or` cannot be split into
//! two asserts at all), only at the argument's top paren level — `assert(f(a and
//! b))` is one claim about `f`, not two — and a call carrying a top-level comma
//! is skipped, since `std.debug.assert` takes exactly one argument and anything
//! else is a different function. Bindings are matched syntactically per file;
//! a binding re-exported through another module is not followed.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const text = @import("../text.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const detail = reporter.detail;

const check_name = "compound-assert";

/// What a file-local name is bound to, as far as this check can prove.
const Binding = enum {
    /// `const assert = std.debug.assert;` — calling it twice is calling std's.
    std_assert,
    /// `const debug = std.debug;` — `<name>.assert(...)` reaches std's.
    std_debug,
    /// Bound to something else, or declared as a function here. Never flagged:
    /// a project-defined `assert` may not be idempotent.
    other,
};

const Bindings = std.StringHashMapUnmanaged(Binding);

/// Records every file-local `const NAME = ...` / `fn NAME` binding that decides
/// whether a call named NAME is `std.debug.assert`.
///
/// Only the two provable std spellings map to `std_assert`/`std_debug`; every
/// other declaration of the same name maps to `other`, which is what keeps a
/// project's own `assert` out of the results. A later declaration overwrites an
/// earlier one, so a rebound name degrades to `other` rather than staying std's.
fn collectBindings(a: Allocator, tree: *const Ast, out: *Bindings) Allocator.Error!void {
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag == .keyword_fn and i + 1 < tags.len and tags[i + 1] == .identifier) {
            try out.put(a, tree.tokenSlice(@intCast(i + 1)), .other);
            continue;
        }
        if (tag != .keyword_const and tag != .keyword_var) continue;
        if (i + 2 >= tags.len) continue;
        if (tags[i + 1] != .identifier or tags[i + 2] != .equal) continue;
        const name = tree.tokenSlice(@intCast(i + 1));
        try out.put(a, name, classifyInit(tree, @intCast(i + 3)));
    }
}

/// Classifies the initializer beginning at token `start`.
///
/// Accepts `std` and `@import("std")` as equivalent roots, so the two ordinary
/// spellings of the same binding are both proven rather than one silently
/// falling through to `other`.
fn classifyInit(tree: *const Ast, start: u32) Binding {
    const tags = tree.tokens.items(.tag);
    var i = start;
    if (i < tags.len and tags[i] == .builtin and std.mem.eql(u8, tree.tokenSlice(i), "@import")) {
        // `@import ( "std" )` — four tokens before the `.debug` continues.
        if (i + 3 >= tags.len or tags[i + 1] != .l_paren or tags[i + 2] != .string_literal) return .other;
        if (!std.mem.eql(u8, tree.tokenSlice(i + 2), "\"std\"") or tags[i + 3] != .r_paren) return .other;
        i += 4;
    } else if (i < tags.len and tags[i] == .identifier and std.mem.eql(u8, tree.tokenSlice(i), "std")) {
        i += 1;
    } else return .other;

    if (!isDotIdent(tree, i, "debug")) return .other;
    i += 2;
    if (i < tags.len and tags[i] == .semicolon) return .std_debug;
    if (!isDotIdent(tree, i, "assert")) return .other;
    if (i + 2 < tags.len and tags[i + 2] == .semicolon) return .std_assert;
    return .other;
}

/// True when tokens `i` and `i + 1` spell `.<name>` — one segment of a path.
fn isDotIdent(tree: *const Ast, i: u32, name: []const u8) bool {
    const tags = tree.tokens.items(.tag);
    if (i + 1 >= tags.len) return false;
    if (tags[i] != .period or tags[i + 1] != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(i + 1), name);
}

/// True when the call whose callee identifier is token `i` (immediately followed
/// by `(`) is provably `std.debug.assert`. Returns false for every spelling the
/// check cannot name, which is the fail-safe direction: an unproven `assert` is
/// treated as the project's own.
fn isStdAssertCall(tree: *const Ast, bindings: *const Bindings, i: u32) bool {
    const tags = tree.tokens.items(.tag);
    if (!std.mem.eql(u8, tree.tokenSlice(i), "assert")) return false;
    // Bare `assert(...)`: only a proven binding counts.
    if (i == 0 or tags[i - 1] != .period) {
        return bindings.get(tree.tokenSlice(i)) == .std_assert;
    }
    if (i < 2 or tags[i - 2] != .identifier) return false;
    // `std.debug.assert(...)` written out in full.
    if (isFullStdDebugChain(tree, i)) return true;
    // `<alias>.assert(...)` where the alias is bound to `std.debug`.
    return bindings.get(tree.tokenSlice(i - 2)) == .std_debug;
}

/// True when the four tokens before `i` spell `std . debug .` — the fully
/// written-out path, needing no binding to prove.
fn isFullStdDebugChain(tree: *const Ast, i: u32) bool {
    const tags = tree.tokens.items(.tag);
    if (i < 4) return false;
    if (tags[i - 3] != .period or tags[i - 4] != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(i - 2), "debug")) return false;
    return std.mem.eql(u8, tree.tokenSlice(i - 4), "std");
}

/// The outcome of scanning one call's argument list.
const Args = struct {
    /// Token index of the closing `)`.
    close: u32,
    /// An `and` sits at the argument's top paren level.
    has_top_level_and: bool,
    /// A `,` sits at that level — not the single-argument `std.debug.assert`.
    multi_arg: bool,
};

/// Scans the argument list whose `(` is token `lparen`, tracking bracket depth
/// so only the argument's own top level is inspected.
fn scanArgs(tree: *const Ast, lparen: u32) Args {
    const tags = tree.tokens.items(.tag);
    var depth: u32 = 0;
    var out: Args = .{ .close = lparen, .has_top_level_and = false, .multi_arg = false };
    var i = lparen;
    while (i < tags.len) : (i += 1) {
        switch (tags[i]) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => {
                depth -= 1;
                if (depth == 0) {
                    out.close = i;
                    return out;
                }
            },
            .keyword_and => if (depth == 1) {
                out.has_top_level_and = true;
            },
            .comma => if (depth == 1) {
                out.multi_arg = true;
            },
            else => {},
        }
    }
    out.close = @intCast(tags.len - 1);
    return out;
}

/// The whitespace-collapsed source of the argument between `lparen` and
/// `rparen`, truncated to `max_condition_chars`. Names the subject in the
/// message and in the baseline identity; never decides the verdict.
const max_condition_chars = 60;

fn conditionText(a: Allocator, tree: *const Ast, lparen: u32, rparen: u32) Allocator.Error![]const u8 {
    const start = tree.tokenStart(lparen) + 1;
    const end = tree.tokenStart(rparen);
    var out: std.ArrayList(u8) = .empty;
    var was_space = true;
    for (tree.source[start..end]) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (!was_space) try out.append(a, ' ');
        } else try out.append(a, c);
        was_space = is_space;
        if (out.items.len >= max_condition_chars) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(a);
}

/// Appends one Violation per compound `std.debug.assert` in `tree` to `out`.
fn scanTree(
    a: Allocator,
    rel_path: []const u8,
    tree: *const Ast,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    var bindings: Bindings = .empty;
    try collectBindings(a, tree, &bindings);

    const tags = tree.tokens.items(.tag);
    var cursor: text.LineCursor = .{};
    for (tags, 0..) |tag, i| {
        if (tag != .identifier) continue;
        if (i + 1 >= tags.len or tags[i + 1] != .l_paren) continue;
        const idx: u32 = @intCast(i);
        if (!isStdAssertCall(tree, &bindings, idx)) continue;

        const args = scanArgs(tree, idx + 1);
        if (args.multi_arg or !args.has_top_level_and) continue;

        const cond = try conditionText(a, tree, idx + 1, args.close);
        try out.append(a, .{
            .check = check_name,
            .file = rel_path,
            .line = cursor.at(tree.source, tree.tokenStart(idx)),
            .message = try std.fmt.allocPrint(
                a,
                "compound assert({s}) — one assert per conjunct names which half broke",
                .{cond},
            ),
            .identity = cond,
            .fix_hint = "split on `and`: assert(a); assert(b);",
        });
    }
}

/// Pure-function entry: the rendered violation lines for every compound
/// `std.debug.assert` in `content`. Empty slice = pass.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const []const u8 {
    var tree = try Ast.parse(allocator, content, .{});
    var out: std.ArrayList(reporter.Violation) = .empty;
    try scanTree(allocator, rel_path, &tree, &out);
    return reporter.flatLines(allocator, out.items);
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList(reporter.Violation),
    extra_allowed: []const []const u8 = &.{},
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    for (ctx.extra_allowed) |pat| if (walk.matchGlob(entry.rel_path, pat)) return;
    if (entry.tree) |t| {
        try scanTree(ctx.allocator, entry.rel_path, t, ctx.violations);
    } else {
        var tree = try Ast.parse(ctx.allocator, entry.content, .{});
        try scanTree(ctx.allocator, entry.rel_path, &tree, ctx.violations);
    }
}

/// Entry point for the compound-assert check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .extra_allowed = ctx.cfg.extraAllowed(check_name),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("compound-assert: every std.debug.assert states one claim", .{});
        return;
    }
    reporter.fail("compound-assert FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: split the conjunction into one assert per conjunct — `and` short-circuits " ++
        "and the first assert aborts, so a bounds-then-index pair stays safe. " ++
        "Only std.debug.assert is flagged; a project-defined assert never is.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Compound Assert - Flags a std.debug.assert whose condition is a conjunction

test "analyzeContent flags std.debug.assert with a top-level and" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const std = @import("std");
        \\fn f(i: usize, len: usize) void {
        \\    std.debug.assert(i < len and len > 0);
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0], "i < len and len > 0") != null);
}

// spec: Compound Assert - Flags a conjunction through a binding proven equal to std.debug.assert

test "analyzeContent flags a call through an alias bound to std.debug.assert" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const aliased = try analyzeContent(a, "src/x.zig",
        \\const std = @import("std");
        \\const assert = std.debug.assert;
        \\fn f(a: bool, b: bool) void {
        \\    assert(a and b);
        \\}
    );
    try testing.expectEqual(@as(usize, 1), aliased.len);
    // `const debug = std.debug;` reaches the same function one segment later.
    const via_debug = try analyzeContent(a, "src/y.zig",
        \\const std = @import("std");
        \\const debug = std.debug;
        \\fn f(a: bool, b: bool) void {
        \\    debug.assert(a and b);
        \\}
    );
    try testing.expectEqual(@as(usize, 1), via_debug.len);
    // `@import("std")` inline is the same binding written differently.
    const inline_import = try analyzeContent(a, "src/z.zig",
        \\const assert = @import("std").debug.assert;
        \\fn f(a: bool, b: bool) void {
        \\    assert(a and b);
        \\}
    );
    try testing.expectEqual(@as(usize, 1), inline_import.len);
}

// spec: Compound Assert - Never flags a project-defined assert

test "analyzeContent never flags a project-defined assert" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A local fn named assert may log or count — calling it twice is a
    // different program, so rewriting it is not the check's business.
    const local_fn = try analyzeContent(a, "src/x.zig",
        \\fn assert(cond: bool) void {
        \\    count += 1;
        \\    if (!cond) @panic("boom");
        \\}
        \\fn f(a: bool, b: bool) void {
        \\    assert(a and b);
        \\}
    );
    try testing.expectEqual(@as(usize, 0), local_fn.len);
    // A bare `assert(` with no binding at all is equally unproven.
    const unbound = try analyzeContent(a, "src/y.zig",
        \\fn f(a: bool, b: bool) void {
        \\    assert(a and b);
        \\}
    );
    try testing.expectEqual(@as(usize, 0), unbound.len);
    // A name rebound to something else is no longer std's.
    const rebound = try analyzeContent(a, "src/z.zig",
        \\const assert = mylib.assert;
        \\fn f(a: bool, b: bool) void {
        \\    assert(a and b);
        \\}
    );
    try testing.expectEqual(@as(usize, 0), rebound.len);
}

// spec: Compound Assert - Ignores an and nested below the argument's top level

test "analyzeContent ignores a nested and and a non-conjunction assert" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `f(a and b)` is one claim about f's result, not two claims.
    const nested = try analyzeContent(a, "src/x.zig",
        \\const std = @import("std");
        \\fn f(a: bool, b: bool) void {
        \\    std.debug.assert(check(a and b));
        \\}
    );
    try testing.expectEqual(@as(usize, 0), nested.len);
    // `or` cannot be split into two asserts at all.
    const disjunction = try analyzeContent(a, "src/y.zig",
        \\const std = @import("std");
        \\fn f(a: bool, b: bool) void {
        \\    std.debug.assert(a or b);
        \\}
    );
    try testing.expectEqual(@as(usize, 0), disjunction.len);
}

/// Index of the first `(` token in `tree` — how the test below locates the one
/// call's argument list without a branch in the test body.
fn firstLParen(tree: *const Ast) u32 {
    for (tree.tokens.items(.tag), 0..) |t, i| if (t == .l_paren) return @intCast(i);
    return 0;
}

test "scanArgs reports the closing paren, the top-level and, and a comma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src: [:0]const u8 = "const x = f(a and (b and c), d);";
    var tree = try Ast.parse(a, src, .{});
    const tags = tree.tokens.items(.tag);
    const args = scanArgs(&tree, firstLParen(&tree));
    try testing.expect(args.has_top_level_and);
    try testing.expect(args.multi_arg);
    try testing.expectEqual(std.zig.Token.Tag.r_paren, tags[args.close]);
}
