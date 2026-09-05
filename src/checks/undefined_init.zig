//! undefined-init (opt-in) — an `undefined` that reaches a VALUE must say why.
//!
//! `undefined` is Zig's only silent poison. A debug build catches a read of it
//! with runtime safety; an optimized build does not, so the same code reads
//! garbage in release and nowhere in the source says that was intended. zlint
//! ships this rule as `unsafe-undefined` (category `restriction`, default-on at
//! warning severity) with exactly that rationale: "While debug builds come with
//! runtime safety checks for `undefined` access, they are otherwise undetectable
//! and will not cause panics in release builds." The language itself only
//! narrowed the comptime half of the problem — Zig 0.15.1's release notes
//! formalized that only operators which can never trigger Illegal Behavior
//! accept `undefined` as an operand, so the compiler diagnoses the comptime case
//! and every runtime use still needs an external gate. This is that gate.
//!
//! Three shapes are flagged, all of them a value being *born* poisoned:
//!   * a `var`/`const` declaration initializer (`var x: Foo = undefined;`),
//!   * a container FIELD default (`buf: [16]u8 = undefined,`), and
//!   * an assignment right-hand side (`self.buf = undefined;`).
//! The escape hatch is a comment: a `// SAFETY: <reason>` line (the marker is
//! matched case-insensitively) in the comment block directly above the site
//! silences it — any line of that block may carry the marker, so a reason is
//! free to wrap. That is the whole point: the check does not ban the idiom, it
//! demands that the invariant be written down where the next agent reads it.
//!
//! **Seam with `unsafe-ops-budget`.** That check counts `undefined` RE-ASSIGNMENT
//! (`x = undefined` on a live lvalue) tree-wide against a committed budget, and
//! its own header records the hole: "Declaration-init `undefined` and test blocks
//! are excluded" — `tallyUndefined` returns early on `stmt.is_decl`. The two do
//! not overlap in what they ANSWER. The budget answers "did the tree's total
//! poison count grow?" — one aggregate number, no per-site justification, no way
//! to bless one line. This check answers "is THIS site justified?" — per-site,
//! identity-baselined, silenced by a `// SAFETY:` line the budget cannot see.
//! A site silenced here is still counted there, deliberately: a project that
//! writes fifty justified poisons still gets told its unsafe surface grew. The
//! declaration and field-default shapes are this check's alone; the assignment
//! shape is shared, and the exemptions carve the budget's blind spot the other
//! way (a `deinit`/`destroy`/`reset` body is where re-poisoning is the whole
//! idiom, so those are silent here and still counted there).
//!
//! **Exemptions**, all structural rather than configured:
//!   * `test { ... }` bodies — a test may poke any unsafe corner it likes;
//!   * `deinit` / `destroy` / `reset` bodies — deliberate pointer poisoning,
//!     the sanctioned use-after-free tripwire;
//!   * an array-typed VARIABLE declaration (`var buf: [N]u8 = undefined;`), the
//!     sanctioned buffer idiom, whose storage is written before it is read —
//!     through one same-file alias hop too (`const Digest = [32]u8;` then
//!     `var out: Digest = undefined;`), so the carve-out does not reward the
//!     less readable spelling. A container field with an array type and an
//!     `undefined` default is NOT exempt: a field default is a value every
//!     instance is born holding, and nothing in the type says who fills it;
//!   * an identifier that merely SPELLS `undefined` — an enum/union/error member
//!     name, `.undefined`, `E.undefined` — which is never a value node here, so
//!     the AST shape excludes it by construction rather than by a name test.
//!
//! **Known limitations.** The marker must be in the comment block directly
//! above the site — a blank or code line ends the block — so a trailing
//! same-line comment does not count (one place to look, and `zig fmt` never
//! moves it). `undefined` nested inside an initializer expression
//! (`.{ .a = undefined }`, `if (c) undefined else x`) is not a declaration
//! initializer or an assignment RHS and is out of scope for now. The three
//! poisoning function names are matched exactly, so `deinitAll` is not exempt.
//! The array-alias hop is same-file and unqualified only: an imported
//! fixed-size type (`var out: cache.Digest = undefined;`) needs semantic
//! analysis to resolve, so it reports — the largest false-positive class here,
//! and a `// SAFETY:` line is its one-line answer. Opt-in
//! (`[undefined_init] enabled = true`) because the volume on an existing tree
//! is the whole classic Zig init idiom; `--dry-run` and `--list` measure
//! anyway, which is how a project sizes the debt first.

const std = @import("std");
const Ast = std.zig.Ast;
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const walk = @import("../walk.zig");
const lineOf = @import("../text.zig").lineOf;

const Allocator = std.mem.Allocator;

/// Registry name (also the `[[allow]]` key and the config section's check).
pub const check_name = "undefined-init";

/// The justification marker, matched case-insensitively in the comment block
/// above a site. Spelled as Zig core spells it (`// SAFETY: ...`).
const safety_marker = "SAFETY:";

/// Function names whose bodies poison deliberately: the value is being torn
/// down, and an `undefined` there is the use-after-free tripwire, not a gap.
const poison_fns = [_][]const u8{ "deinit", "destroy", "reset" };

/// The remedy, carried on every record so `last-run.jsonl` is actionable.
const fix_hint = "initialize the value, or write the invariant down as a " ++
    "`// SAFETY: <reason>` comment directly above it";

/// What a flagged `undefined` was used as. Part of the violation identity, so a
/// site that changes shape is a different subject rather than a silent match.
const Kind = enum {
    declaration,
    field_default,
    assignment,

    /// The short, stable tag used in the baseline identity.
    fn tag(self: Kind) []const u8 {
        return switch (self) {
            .declaration => "decl",
            .field_default => "field",
            .assignment => "assign",
        };
    }
};

/// One `undefined` value site before exemptions and rendering: what it was used
/// as, the name it was used on, and the token the `undefined` itself sits at.
const Site = struct {
    kind: Kind,
    name: []const u8,
    token: Ast.TokenIndex,
};

/// Inclusive token span of a node, used to test containment by token index.
const Span = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,

    /// True when `token` lies inside this span.
    fn holds(self: Span, token: Ast.TokenIndex) bool {
        return token >= self.first and token <= self.last;
    }
};

/// A function body's span with the name it was declared under, so a finding can
/// name its innermost owner and a poisoning body can be skipped whole.
const Owner = struct {
    span: Span,
    name: []const u8,
};

/// The scope structure of one file: every function span (for owner naming) and
/// the spans whose `undefined` uses are exempt (tests, poisoning bodies).
const Scopes = struct {
    fns: []const Owner,
    exempt: []const Span,

    /// True when `token` sits inside a test block or a poisoning function body.
    fn exempts(self: Scopes, token: Ast.TokenIndex) bool {
        for (self.exempt) |span| if (span.holds(token)) return true;
        return false;
    }

    /// The innermost function containing `token`, or the file-scope marker when
    /// the site is a container-level declaration or field.
    fn ownerOf(self: Scopes, token: Ast.TokenIndex) []const u8 {
        var best: ?Owner = null;
        for (self.fns) |owner| {
            if (!owner.span.holds(token)) continue;
            if (best == null or owner.span.first > best.?.span.first) best = owner;
        }
        const found = best orelse return file_scope;
        return found.name;
    }
};

/// Owner name for a site that sits outside every function.
const file_scope = "@file";

// ── Site discovery ──────────────────────────────────────────────────────

/// True when `node` IS the value `undefined`. Reading the AST rather than the
/// token stream is what makes a member merely NAMED `undefined` invisible: an
/// enum/union/error member is a field or a `.enum_literal`, never an identifier
/// value node.
fn isUndefined(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined");
}

/// True when an optional declared type is an array type (`[N]T` / `[N:s]T`),
/// directly or through one same-file alias in `aliases`.
///
/// Slices, many-pointers and single pointers are NOT arrays: a poisoned pointer
/// is a dangling pointer, which is the thing this check is for. The alias hop
/// matters because the buffer idiom is usually spelled through a name —
/// `pub const Digest = [32]u8;` then `var out: Digest = undefined;` — and
/// flagging that while exempting the inlined `[32]u8` would reward the less
/// readable spelling.
fn isArrayType(tree: *const Ast, type_node: Ast.Node.OptionalIndex, aliases: []const []const u8) bool {
    const node = type_node.unwrap() orelse return false;
    return switch (tree.nodeTag(node)) {
        .array_type, .array_type_sentinel => true,
        .identifier => namedIn(tree.tokenSlice(tree.nodeMainToken(node)), aliases),
        else => false,
    };
}

/// True when `name` is one of `names`.
fn namedIn(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// Every file-scope `const Name = [N]T;` in the file. Container-level only and
/// same-file only: an imported alias (`cache.Digest`) is a qualified name this
/// check cannot resolve without semantic analysis, and is a documented
/// false-positive class rather than a half-resolved guess.
fn collectArrayAliases(arena: Allocator, tree: *const Ast) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (tree.rootDecls()) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        switch (tree.nodeTag(init_node)) {
            .array_type, .array_type_sentinel => {},
            else => continue,
        }
        try names.append(arena, tree.tokenSlice(var_decl.ast.mut_token + 1));
    }
    return names.toOwnedSlice(arena);
}

/// The source text spanned by `node`, verbatim.
fn sourceOf(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return tree.source[start..end];
}

/// Collapses each whitespace run in `text` to one space, so a multi-line
/// assignment target renders (and keys) as one stable name.
fn condense(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            pending_space = true;
            continue;
        }
        if (pending_space and out.items.len > 0) try out.append(arena, ' ');
        pending_space = false;
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// The `undefined` value site `node` is, or null when it is not one of the
/// three flagged shapes. Array-typed variable declarations return null here:
/// the sanctioned buffer idiom is not a site at all.
fn siteOf(
    arena: Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
    aliases: []const []const u8,
) Allocator.Error!?Site {
    if (tree.nodeTag(node) == .assign) {
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        if (!isUndefined(tree, rhs)) return null;
        return .{
            .kind = .assignment,
            .name = try condense(arena, sourceOf(tree, lhs)),
            .token = tree.nodeMainToken(rhs),
        };
    }
    if (tree.fullVarDecl(node)) |decl| {
        const init_node = decl.ast.init_node.unwrap() orelse return null;
        if (!isUndefined(tree, init_node)) return null;
        if (isArrayType(tree, decl.ast.type_node, aliases)) return null;
        return .{
            .kind = .declaration,
            .name = tree.tokenSlice(decl.ast.mut_token + 1),
            .token = tree.nodeMainToken(init_node),
        };
    }
    if (tree.fullContainerField(node)) |field| {
        const value = field.ast.value_expr.unwrap() orelse return null;
        if (!isUndefined(tree, value)) return null;
        return .{
            .kind = .field_default,
            .name = tree.tokenSlice(field.ast.main_token),
            .token = tree.nodeMainToken(value),
        };
    }
    return null;
}

// ── Scope structure ─────────────────────────────────────────────────────

/// The inclusive token span of `node`.
fn spanOf(tree: *const Ast, node: Ast.Node.Index) Span {
    return .{ .first = tree.firstToken(node), .last = tree.lastToken(node) };
}

/// The declared name of a `fn_decl`, or null for an unnamed one.
fn fnName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, node) orelse return null;
    const name_token = proto.name_token orelse return null;
    return tree.tokenSlice(name_token);
}

/// True when `name` is one of the teardown functions where poisoning is the
/// idiom. Matched exactly: `deinitAll` is a different function.
fn isPoisonFn(name: []const u8) bool {
    return namedIn(name, &poison_fns);
}

/// Every function span in the file plus the spans exempt from the check.
fn collectScopes(arena: Allocator, tree: *const Ast) Allocator.Error!Scopes {
    var fns: std.ArrayList(Owner) = .empty;
    var exempt: std.ArrayList(Span) = .empty;
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tree.nodeTag(node)) {
            .test_decl => try exempt.append(arena, spanOf(tree, node)),
            .fn_decl => {
                const name = fnName(tree, node) orelse "";
                const span = spanOf(tree, node);
                try fns.append(arena, .{ .span = span, .name = name });
                if (isPoisonFn(name)) try exempt.append(arena, span);
            },
            else => {},
        }
    }
    return .{ .fns = try fns.toOwnedSlice(arena), .exempt = try exempt.toOwnedSlice(arena) };
}

// ── The SAFETY escape hatch ─────────────────────────────────────────────

/// True when `haystack` contains `needle` ignoring ASCII case. Hand-rolled
/// because std.ascii offers only the anchored `startsWithIgnoreCase`.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// True when the comment block directly above `offset` carries the `SAFETY:`
/// marker (case-insensitive) on any of its lines.
///
/// The block, not one line, because a reason worth writing usually wraps — and
/// a two-line justification that silently does not count is the kind of trap
/// that teaches agents to delete the comment instead of writing it. The walk
/// still stops at the first line that is not a comment (a blank line included),
/// so the marker cannot drift away from the site it justifies.
fn justifiedAt(source: []const u8, offset: usize) bool {
    const at = @min(offset, source.len);
    var end = std.mem.lastIndexOfScalar(u8, source[0..at], '\n') orelse return false;
    while (end > 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, source[0..end], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trim(u8, source[start..end], " \t\r");
        if (!std.mem.startsWith(u8, line, "//")) return false;
        if (containsIgnoreCase(line, safety_marker)) return true;
        if (start == 0) return false;
        end = start - 1;
    }
    return false;
}

// ── Rendering ───────────────────────────────────────────────────────────

/// The rendered message for one site. Wording is free to change: every record
/// carries an `identity`, so a baseline is keyed by the subject, not the prose.
fn messageFor(arena: Allocator, site: Site) Allocator.Error![]const u8 {
    return switch (site.kind) {
        .declaration => std.fmt.allocPrint(arena, "`{s}` is declared `undefined`", .{site.name}),
        .field_default => std.fmt.allocPrint(arena, "field `{s}` defaults to `undefined`", .{site.name}),
        .assignment => std.fmt.allocPrint(arena, "`{s}` is assigned `undefined`", .{site.name}),
    };
}

/// The baseline identity: `<file>|<owner>|<kind>|<name>`. Content-derived and
/// line-free, so moving the site or rewording the message keeps the key.
fn identityFor(arena: Allocator, file: []const u8, owner: []const u8, site: Site) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}|{s}|{s}|{s}", .{ file, owner, site.kind.tag(), site.name });
}

// ── Entry points ────────────────────────────────────────────────────────

/// Pure core: every unjustified `undefined` value in one parsed file.
pub fn analyzeFile(
    allocator: Allocator,
    entry: *const ast_index.Entry,
) Allocator.Error![]const reporter.Violation {
    const tree = &entry.tree;
    const scopes = try collectScopes(allocator, tree);
    const aliases = try collectArrayAliases(allocator, tree);
    var out: std.ArrayList(reporter.Violation) = .empty;
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const site = try siteOf(allocator, tree, node, aliases) orelse continue;
        if (scopes.exempts(site.token)) continue;
        const offset = tree.tokenStart(site.token);
        if (justifiedAt(tree.source, offset)) continue;
        try out.append(allocator, .{
            .check = check_name,
            .file = entry.rel_path,
            .line = lineOf(tree.source, offset),
            .message = try messageFor(allocator, site),
            .fix_hint = fix_hint,
            .identity = try identityFor(allocator, entry.rel_path, scopes.ownerOf(site.token), site),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// True when a run must measure even though the check is off. `--dry-run` and
/// `--list` are read-only introspection, and sizing the debt is exactly how a
/// project decides whether to turn the gate on.
fn measuresWhileDisabled(ctx: *const registry.RunCtx) bool {
    return ctx.dry_run or ctx.list;
}

/// True when `rel_path` is covered by a `[[allow]]` entry for this check.
fn isAllowed(rel_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| if (walk.matchGlob(rel_path, pattern)) return true;
    return false;
}

/// Entry point for the undefined-init check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    if (!ctx.cfg.undefined_init.enabled and !measuresWhileDisabled(ctx)) {
        reporter.ok("undefined-init disabled by config (opt-in via [undefined_init] enabled = true)", .{});
        return;
    }
    const allowed = ctx.cfg.extraAllowed(check_name);
    // SAFETY: resolve() fills storage before returning it, and only when
    // ctx.source_index is null; nothing reads it on the shared-index path.
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);

    var found: std.ArrayList(reporter.Violation) = .empty;
    for (idx.files) |*entry| {
        if (isAllowed(entry.rel_path, allowed)) continue;
        try found.appendSlice(allocator, try analyzeFile(allocator, entry));
    }
    if (found.items.len == 0) {
        reporter.ok("undefined-init: every `undefined` value is initialized or justified", .{});
        return;
    }
    reporter.fail("undefined-init FAILED ({d} unjustified `undefined` value(s))", .{found.items.len});
    for (found.items) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses one in-test source string and runs the pure core over it.
fn analyzeSource(arena: Allocator, source: [:0]const u8) ![]const reporter.Violation {
    const entry: ast_index.Entry = .{
        .rel_path = "src/widget.zig",
        .content = source,
        .tree = try Ast.parse(arena, source, .{}),
    };
    return analyzeFile(arena, &entry);
}

// spec: Undefined Init - Flags a non-array declaration initialized to undefined

test "analyzeFile flags a non-array declaration initialized to undefined" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\fn build() void {
        \\    var conn: Connection = undefined;
        \\    use(&conn);
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(
        "src/widget.zig:2: `conn` is declared `undefined`",
        try reporter.flatLine(arena, out[0]),
    );
}

// spec: Undefined Init - Flags an assignment whose right-hand side is undefined

test "analyzeFile flags an assignment of undefined to a live value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\fn clear(self: *Widget) void {
        \\    self.cache = undefined;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(
        "src/widget.zig:2: `self.cache` is assigned `undefined`",
        try reporter.flatLine(arena, out[0]),
    );
}

// spec: Undefined Init - Flags a container field defaulting to undefined

test "analyzeFile flags a container field default, array-typed or not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A field default is a value every instance is BORN holding and nothing in
    // the type says who fills it — so the array carve-out that covers a local
    // buffer deliberately stops at the container boundary.
    const out = try analyzeSource(arena,
        \\const Widget = struct {
        \\    buf: [16]u8 = undefined,
        \\    conn: Connection = undefined,
        \\};
    );
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings(
        "src/widget.zig:2: field `buf` defaults to `undefined`",
        try reporter.flatLine(arena, out[0]),
    );
}

// spec: Undefined Init - Exempts a site justified by a preceding SAFETY comment

test "analyzeFile exempts a site whose previous line carries the SAFETY marker" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Case-insensitive on the marker, and it must be the line directly above.
    const justified = try analyzeSource(arena,
        \\fn build() void {
        \\    // SAFETY: fill() writes every field before the first read.
        \\    var conn: Connection = undefined;
        \\    // safety: the lowercase spelling counts too.
        \\    var other: Connection = undefined;
        \\}
    );
    try testing.expectEqual(@as(usize, 0), justified.len);
    // A reason that wraps is still one justification: the marker may sit on any
    // line of the comment block directly above the site.
    const wrapped = try analyzeSource(arena,
        \\fn build() void {
        \\    // SAFETY: fill() writes every field before the first read, and
        \\    // nothing between here and that call touches the value.
        \\    var conn: Connection = undefined;
        \\}
    );
    try testing.expectEqual(@as(usize, 0), wrapped.len);
    // A marker two lines up, or on the same line, is not the contract: one
    // place to look is what makes the justification readable.
    const distant = try analyzeSource(arena,
        \\fn build() void {
        \\    // SAFETY: this comment is not adjacent.
        \\
        \\    var conn: Connection = undefined;
        \\    var trailing: Connection = undefined; // SAFETY: not read here
        \\}
    );
    try testing.expectEqual(@as(usize, 2), distant.len);
}

// spec: Undefined Init - Exempts an array-typed variable declaration

test "analyzeFile exempts the array buffer idiom but not a poisoned pointer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\fn build() void {
        \\    var buf: [64]u8 = undefined;
        \\    var line: [16:0]u8 = undefined;
        \\    var slice: []u8 = undefined;
        \\    var ptr: *Widget = undefined;
        \\}
    );
    // The two arrays are the sanctioned buffer setup; the slice and the pointer
    // are dangling references, which is the case this check exists for.
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("src/widget.zig|build|decl|slice", out[0].identity.?);
    try testing.expectEqualStrings("src/widget.zig|build|decl|ptr", out[1].identity.?);

    // The idiom is usually spelled through a name, so the carve-out follows one
    // same-file alias hop: flagging `var out: Digest = undefined` while
    // exempting the inlined `[32]u8` would reward the less readable spelling.
    // A non-array alias keeps no such cover.
    const aliased = try analyzeSource(arena,
        \\const Digest = [32]u8;
        \\const Connection = struct { fd: i32 };
        \\fn build() void {
        \\    var out: Digest = undefined;
        \\    var conn: Connection = undefined;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), aliased.len);
    try testing.expectEqualStrings("src/widget.zig|build|decl|conn", aliased[0].identity.?);
}

// spec: Undefined Init - Exempts undefined inside a test block

test "analyzeFile exempts undefined inside a test block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\test "poke an unsafe corner" {
        \\    var conn: Connection = undefined;
        \\    conn.fd = undefined;
        \\}
        \\fn build() void {
        \\    var live: Connection = undefined;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/widget.zig|build|decl|live", out[0].identity.?);
}

// spec: Undefined Init - Exempts a deinit, destroy, or reset body

test "analyzeFile exempts deliberate poisoning in teardown bodies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\fn deinit(self: *Widget) void { self.* = undefined; }
        \\fn destroy(self: *Widget) void { self.node = undefined; }
        \\fn reset(self: *Widget) void { self.cache = undefined; }
        \\fn deinitAll(self: *Widget) void { self.cache = undefined; }
    );
    // Exactly the three teardown names, matched whole: `deinitAll` is a
    // different function and gets no free pass.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/widget.zig|deinitAll|assign|self.cache", out[0].identity.?);
}

// spec: Undefined Init - Ignores an identifier that only spells undefined

test "analyzeFile ignores a member merely named undefined" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\const State = enum { undefined, ready };
        \\const Error = error{undefined};
        \\fn build(s: *State) void {
        \\    s.* = .undefined;
        \\    s.* = State.undefined;
        \\}
    );
    // Reading value NODES rather than tokens is what makes this free: a member
    // name is a field or an enum literal, never an identifier value.
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Undefined Init - Keys a finding by file, owner, kind, and subject

test "the identity is content-derived and survives a move or a reword" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try analyzeSource(arena,
        \\fn build() void {
        \\    var conn: Connection = undefined;
        \\}
    );
    // The same declaration pushed down the file keeps its key: no line number
    // is in any tier of the identity, so a consumer's baseline holds.
    const after = try analyzeSource(arena,
        \\const unrelated = 1;
        \\
        \\fn build() void {
        \\    const other = unrelated;
        \\    var conn: Connection = undefined;
        \\    _ = other;
        \\}
    );
    try testing.expectEqualStrings("src/widget.zig|build|decl|conn", before[0].identity.?);
    try testing.expectEqualStrings(before[0].identity.?, after[0].identity.?);
    try testing.expectEqual(@as(?u32, 2), before[0].line);
    try testing.expectEqual(@as(?u32, 5), after[0].line);
}

test "a file-scope declaration is keyed under the file-scope owner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\var runtime_io: Io = undefined;
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/widget.zig|@file|decl|runtime_io", out[0].identity.?);
}

test "the innermost function owns a site inside a nested function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\fn outer() void {
        \\    const inner = struct {
        \\        fn go() void {
        \\            var conn: Connection = undefined;
        \\        }
        \\    };
        \\    _ = inner;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/widget.zig|go|decl|conn", out[0].identity.?);
}

test "an undefined inside a string or a comment is not a value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try analyzeSource(arena,
        \\// var x: T = undefined;
        \\const doc = "var x: T = undefined;";
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "condense collapses a multi-line assignment target to one stable name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a.b", try condense(arena, "a.b"));
    try testing.expectEqualStrings("self.items[ i ]", try condense(arena, "self.items[\n    i\n]"));
    try testing.expectEqualStrings("", try condense(arena, "   "));
}

test "isAllowed matches a configured exemption path" {
    try testing.expect(isAllowed("src/generated/tables.zig", &.{"src/generated/*"}));
    try testing.expect(!isAllowed("src/widget.zig", &.{"src/generated/*"}));
}

test "a disabled run still measures under the read-only introspection flags" {
    var cfg: @import("../config.zig").Config = .{};
    var ctx: registry.RunCtx = .{
        .allocator = testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    // Off by default, and a plain run stays silent...
    try testing.expect(!cfg.undefined_init.enabled);
    try testing.expect(!measuresWhileDisabled(&ctx));
    // ...but `--dry-run` / `--list` size the debt anyway, which is how a
    // project decides whether to enable the gate at all.
    ctx.dry_run = true;
    try testing.expect(measuresWhileDisabled(&ctx));
    ctx.dry_run = false;
    ctx.list = true;
    try testing.expect(measuresWhileDisabled(&ctx));
}
