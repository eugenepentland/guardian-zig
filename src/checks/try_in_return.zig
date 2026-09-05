//! try-in-return — flag `return try <expr>;`, the fused form of "call, unwrap
//! the error, hand the payload straight back out".
//!
//! WHY (this is a hazard, not a style preference): `return try f()` performs two
//! independent coercions in one unnamed step — `try` unwraps `f`'s error union
//! and re-raises its error set into the *enclosing* function's error set, and
//! `return` then coerces the surviving payload into the enclosing return type.
//! Because neither result is ever bound, the compiler has nowhere to disagree
//! with the author about what the payload's type is. The edit that bites is the
//! ordinary one an agent makes: `f` stops returning an error union (or the
//! author "simplifies"), the `try` is dropped, and `return f();` still compiles
//! wherever the enclosing return type can absorb the whole `E!T` value rather
//! than the `T` that was meant — the error union is now the payload, silently.
//! Binding first is what makes that edit a compile error at the binding:
//!
//!     const parsed = try parse(src);   // `parsed` is T, named and typed
//!     return parsed;                   // dropping `try` now fails to compile
//!
//! The named local is also the only place an `errdefer`, a log, or an assertion
//! about the value can attach without restructuring the function.
//!
//! WHAT: a `return` token immediately followed by a `try` token. Adjacency is
//! the whole rule, which is why it has essentially no false-positive surface.
//!
//! LIMITATIONS, deliberate: `try` deeper inside a returned expression
//! (`return if (c) try a() else b();`, `return .{ .x = try a() };`) is NOT
//! flagged — there the payload already sits in a larger expression whose type
//! the compiler checks structurally, so the fused-coercion argument does not
//! apply. `break :blk try f();` is likewise out of scope. The scan is over the
//! token stream, so a `return try` inside a string literal or a comment can
//! never fire.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const text = @import("../text.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const detail = reporter.detail;

const check_name = "try-in-return";

/// Appends one Violation per `return try` in `tree` to `out`.
///
/// The enclosing `fn` name rides along as the violation's identity so the
/// baseline key survives a reworded message and a moved line (see
/// violation_key.zig tier 1); the callee path disambiguates two returns in one
/// function.
fn scanTree(
    a: Allocator,
    rel_path: []const u8,
    tree: *const Ast,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    const tags = tree.tokens.items(.tag);
    var cursor: text.LineCursor = .{};
    var current_fn: []const u8 = "<file>";

    for (tags, 0..) |tag, i| {
        const idx: u32 = @intCast(i);
        if (tag == .keyword_fn and i + 1 < tags.len and tags[i + 1] == .identifier) {
            current_fn = tree.tokenSlice(idx + 1);
            continue;
        }
        if (tag != .keyword_return) continue;
        if (i + 1 >= tags.len or tags[i + 1] != .keyword_try) continue;

        const callee = calleePath(tree, @intCast(i + 2));
        try out.append(a, .{
            .check = check_name,
            .file = rel_path,
            .line = cursor.at(tree.source, tree.tokenStart(idx)),
            .message = try std.fmt.allocPrint(
                a,
                "`return try {s}...` — bind the tried value to a local, then return it",
                .{callee},
            ),
            .identity = try std.fmt.allocPrint(a, "{s}|{s}", .{ current_fn, callee }),
            .fix_hint = "const v = try <expr>; return v;",
        });
    }
}

/// The dotted identifier path starting at `start` (`foo`, `foo.bar.baz`), or
/// `<expr>` when the returned expression does not open with one. Used only to
/// name the subject in the message and identity — never to decide the verdict.
fn calleePath(tree: *const Ast, start: u32) []const u8 {
    const tags = tree.tokens.items(.tag);
    if (start >= tags.len or tags[start] != .identifier) return "<expr>";
    var end = start;
    while (end + 2 < tags.len and tags[end + 1] == .period and tags[end + 2] == .identifier) end += 2;
    const first = tree.tokenStart(start);
    const last = tree.tokenStart(end);
    return tree.source[first .. last + tree.tokenSlice(end).len];
}

/// Pure-function entry: the rendered violation lines for every `return try` in
/// `content`. Empty slice = pass. Used by the unit tests; production goes
/// through `run`, which reuses the shared parse.
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

/// Entry point for the try-in-return check.
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
        reporter.ok("try-in-return: no `return try ...` — every tried value is bound first", .{});
        return;
    }
    reporter.fail("try-in-return FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: `const v = try <expr>; return v;` — the named local is what makes " ++
        "a later `try` removal a compile error instead of a silent coercion.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Try In Return - Flags a try used directly in a return expression

test "analyzeContent flags return try" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn g() !void {
        \\    return try f();
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    // The callee is named so the finding is actionable without opening the file.
    try testing.expect(std.mem.indexOf(u8, out[0], "return try f") != null);
}

// spec: Try In Return - Allows a tried value bound to a local before it is returned

test "analyzeContent allows a bound local returned afterwards" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn g() !u8 {
        \\    const v = try f();
        \\    return v;
        \\}
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Try In Return - Ignores a try nested deeper inside the returned expression

test "analyzeContent ignores try nested inside the returned expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn g(c: bool) !u8 {
        \\    return if (c) try a() else b();
        \\}
        \\fn h() !S {
        \\    return .{ .x = try a() };
        \\}
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores return try inside a string literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const s = "return try f();"; // return try f();
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "calleePath names a dotted callee and falls back for a non-identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(reporter.Violation) = .empty;
    const src: [:0]const u8 =
        \\fn g() !void {
        \\    return try foo.bar.baz();
        \\}
        \\fn h() !void {
        \\    return try (comptime k());
        \\}
    ;
    var tree = try Ast.parse(a, src, .{});
    try scanTree(a, "src/x.zig", &tree, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("g|foo.bar.baz", out.items[0].identity.?);
    try testing.expectEqualStrings("h|<expr>", out.items[1].identity.?);
}
