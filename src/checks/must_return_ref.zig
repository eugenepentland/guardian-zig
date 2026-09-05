//! must-return-ref: a function whose declared return type is a capacity-owning
//! container (`ArrayList`, `array_list.Managed`, `HashMap` / `AutoHashMap` /
//! `StringHashMap`, `ArenaAllocator`) hands back one of its OWN fields BY VALUE.
//!
//! Zig has no move semantics. Returning such a struct by value copies the
//! bookkeeping — `items`, `capacity`, the buckets pointer — while the original
//! keeps pointing at the same heap buffer. The caller then grows its copy, the
//! copy reallocates (or the owner's `defer deinit()` frees the shared buffer),
//! and the two views silently disagree about who owns what:
//!
//!     fn foo(self: *Foo) std.array_list.Managed(u32) { return self.list; }
//!     var list = foo.getList();
//!     try list.append(1); // leaked!
//!
//! Evidence: DonIsaac/zlint ships exactly this rule as `must-return-ref`,
//! category Suspicious, default-on at warning severity. Its documented bad case
//! is the `getList` shape above, and its rule doc states the rationale
//! verbatim: "Zig does not have move semantics. Returning a value by value
//! copies it. Returning a copy of a struct's field that records how much memory
//! it has allocated can easily lead to memory leaks." The fix is `*T` plus
//! `&self.field`.
//!
//! **Three conjuncts, all required.** The return-type signature alone is
//! necessary but NOT sufficient — a check keyed on the signature would flag
//! every factory function in the tree. So a finding needs all of:
//!   1. the peeled return type names one of the container types above,
//!   2. it is returned BY VALUE (a `*T` / `[]T` return type is the fix, never
//!      the bug), and
//!   3. the returned expression's AST node tag is `.field_access` whose
//!      accessed object does not itself resolve to a type — so
//!      `return ArenaAllocator.init(alloc);` (a `.call`) and
//!      `return Foo.shared_map;` (a type-qualified namespace read) are not
//!      flagged, while `return self.list;` is.
//!
//! **Capability tier: AST, single-function local, no interprocedural
//! analysis** — deliberately the same tier zlint's own `must_return_ref.zig`
//! `runOnNode` operates at (it inspects only the checked function's own return
//! statements and matches the return type against a hardcoded type set).
//!
//! Limitations that follow from that tier: the type set is matched by its
//! syntactic dotted tail, so a project-local alias (`const List = ArrayList;`
//! then `fn get(...) List`) is invisible until the alias is added to
//! `[must_return_ref] extra_types`; "object resolves to a type" is decided by
//! the PascalCase convention over the object's identifier chain rather than by
//! real name resolution; and a container reached through a call
//! (`return self.owner().list;`) is not flagged, since the object is then a
//! temporary rather than a field of a live owner.
//!
//! **False positives are low but not zero.** Deliberate ownership TRANSFER — a
//! builder handing its list to a caller who then owns it — is the legitimate
//! pattern this shape has. Waive such a site with an
//! `// OWNERSHIP: transferred` comment on the return line or the line directly
//! above it; `[[allow]] check = "must-return-ref"` path globs waive a whole
//! subtree. The check emits identity-keyed violations, so a consumer can also
//! baseline the existing instances and block only on new ones.

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const lineOf = @import("../text.zig").lineOf;

const Allocator = std.mem.Allocator;

pub const check_name = "must-return-ref";

/// The comment that waives one site: a deliberate ownership transfer, where the
/// caller really does become the owner and the original never deinits.
const ownership_marker = "// OWNERSHIP: transferred";

/// The capacity-owning container types, matched against the return type's
/// syntactic dotted tail. An entry with a `.` must match the last TWO segments
/// (`std.array_list.Managed` -> `array_list.Managed`); an entry without one
/// matches the last segment alone, so `std.ArrayList`, `foo.ArrayList` and a
/// bare `ArrayList` all count. A project extends this set through
/// `[must_return_ref] extra_types`.
const default_types = [_][]const u8{
    "ArrayList",
    "array_list.Managed",
    "HashMap",
    "AutoHashMap",
    "StringHashMap",
    "ArenaAllocator",
};

const fix_hint = "return `*T` and `&self.<field>` — Zig has no move semantics, " ++
    "so a by-value return copies the capacity bookkeeping while the original " ++
    "still owns the buffer.";

// ── Type-expression shape ───────────────────────────────────────────────

/// The last one or two identifier segments of a dotted type expression:
/// `std.array_list.Managed` -> `.{ .parent = "array_list", .last = "Managed" }`.
const Tail = struct {
    last: []const u8,
    parent: ?[]const u8,
};

/// Reads the dotted tail of an identifier / `a.b.c` chain. Null for anything
/// else (a call, a builtin, an anonymous struct type), which is exactly the
/// shape this check declines to reason about.
fn dottedTail(tree: *const Ast, node: Ast.Node.Index) ?Tail {
    return switch (tree.nodeTag(node)) {
        .identifier => .{ .last = tree.tokenSlice(tree.nodeMainToken(node)), .parent = null },
        .field_access => blk: {
            const object, const field_tok = tree.nodeData(node).node_and_token;
            const parent: ?[]const u8 = switch (tree.nodeTag(object)) {
                .identifier => tree.tokenSlice(tree.nodeMainToken(object)),
                .field_access => tree.tokenSlice(tree.nodeData(object).node_and_token[1]),
                else => null,
            };
            break :blk .{ .last = tree.tokenSlice(field_tok), .parent = parent };
        },
        else => null,
    };
}

/// True when `tail` names one of the capacity-owning container types.
fn matchesType(tail: Tail, types: []const []const u8) bool {
    for (types) |want| {
        if (std.mem.indexOfScalar(u8, want, '.')) |dot| {
            const parent = tail.parent orelse continue;
            if (!std.mem.eql(u8, parent, want[0..dot])) continue;
            if (std.mem.eql(u8, tail.last, want[dot + 1 ..])) return true;
            continue;
        }
        if (std.mem.eql(u8, tail.last, want)) return true;
    }
    return false;
}

/// True when the return type is spelled by reference (`*T`, `[]T`, `[*]T`) —
/// that IS the fix, so it can never be the bug.
fn isByReference(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => true,
        else => false,
    };
}

// twin-drift-ok: shares only the peel-loop shape with stack_escape's name
// walkers. This one peels TYPE wrappers (error union, optional) to a node;
// those peel a VALUE chain to an identifier string. Merging them would force a
// helper that peels both node families, which is how a type wrapper starts
// getting stripped off an expression.
/// Peels the wrappers that do not change WHICH type is returned: an explicit
/// `E!T` error union (an inferred `!T` never reaches the node, the `!` is a
/// preceding token), `?T`, and parentheses.
fn peelType(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var cur = node;
    while (true) {
        switch (tree.nodeTag(cur)) {
            .error_union => cur = tree.nodeData(cur).node_and_node[1],
            .optional_type => cur = tree.nodeData(cur).node,
            .grouped_expression => cur = tree.nodeData(cur).node_and_token[0],
            else => return cur,
        }
    }
}

/// The container type a function returns by value, or null when the signature
/// fails conjunct 1 or conjunct 2. `std.ArrayList(u32)` is a call, so the type
/// NAME lives on its callee.
fn returnedContainer(
    tree: *const Ast,
    proto: Ast.full.FnProto,
    types: []const []const u8,
) ?[]const u8 {
    const declared = proto.ast.return_type.unwrap() orelse return null;
    const peeled = peelType(tree, declared);
    if (isByReference(tree, peeled)) return null;

    var buf: [1]Ast.Node.Index = undefined;
    const named = if (tree.fullCall(&buf, peeled)) |call| call.ast.fn_expr else peeled;
    const tail = dottedTail(tree, named) orelse return null;
    if (!matchesType(tail, types)) return null;
    return sourceSpan(tree, named);
}

// ── Return-expression shape ─────────────────────────────────────────────

// twin-drift-ok: same peel-loop shape, different node family from peelType
// above and from stack_escape's walkers — this one strips `try`/`nosuspend`/
// `comptime`, which are meaningless on a type.
/// Strips the wrappers that do not change the returned expression's shape.
fn peelExpr(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var cur = node;
    while (true) {
        switch (tree.nodeTag(cur)) {
            .@"try", .@"nosuspend", .@"comptime" => cur = tree.nodeData(cur).node,
            .grouped_expression => cur = tree.nodeData(cur).node_and_token[0],
            else => return cur,
        }
    }
}

/// True when an identifier chain reads as a TYPE rather than a value: any
/// segment in PascalCase (`Foo.shared`, `pkg.Registry`). Zig's naming
/// convention is the only signal available at this tier, and it is the same
/// convention `naming` already gates in this tree.
fn resolvesToType(tree: *const Ast, node: Ast.Node.Index) bool {
    var cur = node;
    while (true) {
        switch (tree.nodeTag(cur)) {
            .identifier => return isPascal(tree.tokenSlice(tree.nodeMainToken(cur))),
            .field_access => {
                const object, const field_tok = tree.nodeData(cur).node_and_token;
                if (isPascal(tree.tokenSlice(field_tok))) return true;
                cur = object;
            },
            // A call, a deref, an index — not a plain namespace read, and not a
            // live owner's field either. Treated as "type-like" so the caller
            // stays silent.
            else => return true,
        }
    }
}

/// True when `name` starts with an ASCII uppercase letter (Zig's type-name
/// convention).
fn isPascal(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

/// The exact source text spanned by `node`, used to echo the returned
/// expression (`self.list`) and the type name back in the message.
fn sourceSpan(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return tree.source[start..end];
}

/// True when an `// OWNERSHIP: transferred` waiver sits on the offending line
/// or the line directly above it. The tokenizer drops comments, so this
/// re-reads the raw source around the flagged byte — the same shape
/// `allocator-hygiene`'s `// allocator-ok` hatch uses.
fn transferred(content: []const u8, byte: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..byte], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, content, byte, '\n') orelse content.len;
    if (std.mem.indexOf(u8, content[line_start..line_end], ownership_marker) != null) return true;
    if (line_start == 0) return false;
    const prev_end = line_start - 1;
    const prev_start = if (std.mem.lastIndexOfScalar(u8, content[0..prev_end], '\n')) |i| i + 1 else 0;
    return std.mem.indexOf(u8, content[prev_start..prev_end], ownership_marker) != null;
}

// ── Per-file analysis ───────────────────────────────────────────────────

/// One function's body span plus what its signature promised, so a `return`
/// can be attributed to the INNERMOST function enclosing it (a nested fn owns
/// its own returns).
const Frame = struct {
    first: u32,
    last: u32,
    name: []const u8,
    /// The container type name when the signature satisfies conjuncts 1 and 2;
    /// null for every other function (still recorded, so a nested plain fn
    /// still shadows its enclosing container-returning one).
    container: ?[]const u8,
};

/// Collects one frame per `fn_decl` in the file, in node order.
fn collectFrames(
    arena: Allocator,
    tree: *const Ast,
    types: []const []const u8,
) Allocator.Error![]const Frame {
    var frames: std.ArrayList(Frame) = .empty;
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        _, const body = tree.nodeData(node).node_and_node;
        try frames.append(arena, .{
            .first = tree.firstToken(body),
            .last = tree.lastToken(body),
            .name = tree.tokenSlice(name_tok),
            .container = returnedContainer(tree, proto, types),
        });
    }
    return frames.toOwnedSlice(arena);
}

/// The innermost frame containing `tok`, or null when the token sits outside
/// every function body (a `test { }` block, a container-level decl).
fn innermostFrame(frames: []const Frame, tok: u32) ?Frame {
    var best: ?Frame = null;
    for (frames) |f| {
        if (tok < f.first or tok > f.last) continue;
        const incumbent = best orelse {
            best = f;
            continue;
        };
        if (f.first >= incumbent.first and f.last <= incumbent.last) best = f;
    }
    return best;
}

/// Pure entry point: every `must-return-ref` violation in one parsed file.
/// Empty slice = pass. Allocator-owned; used directly by the unit tests.
pub fn analyzeFile(
    allocator: Allocator,
    rel_path: []const u8,
    tree: *const Ast,
    types: []const []const u8,
) Allocator.Error![]const reporter.Violation {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const frames = try collectFrames(arena, tree, types);
    var out: std.ArrayList(reporter.Violation) = .empty;

    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .@"return") continue;
        const frame = innermostFrame(frames, tree.nodeMainToken(node)) orelse continue;
        const container = frame.container orelse continue;
        const found = try flag(allocator, rel_path, tree, node, frame.name, container) orelse continue;
        try out.append(allocator, found);
    }
    return out.toOwnedSlice(allocator);
}

/// Builds the violation for one `return` statement, or null when conjunct 3
/// fails or an `// OWNERSHIP: transferred` waiver covers the site.
fn flag(
    allocator: Allocator,
    rel_path: []const u8,
    tree: *const Ast,
    ret: Ast.Node.Index,
    fn_name: []const u8,
    container: []const u8,
) Allocator.Error!?reporter.Violation {
    const expr = peelExpr(tree, tree.nodeData(ret).opt_node.unwrap() orelse return null);
    if (tree.nodeTag(expr) != .field_access) return null;
    if (resolvesToType(tree, tree.nodeData(expr).node_and_token[0])) return null;

    const byte = tree.tokenStart(tree.nodeMainToken(ret));
    if (transferred(tree.source, byte)) return null;

    const text = sourceSpan(tree, expr);
    const message = try std.fmt.allocPrint(
        allocator,
        "fn {s} returns {s} by value as `{s}` — the caller mutates a copy while " ++
            "the original's deinit frees the buffer; return `*{s}` and `&{s}`",
        .{ fn_name, container, text, container, text },
    );
    const identity = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ rel_path, fn_name, text });
    return .{
        .check = check_name,
        .file = rel_path,
        .line = lineOf(tree.source, byte),
        .message = message,
        .fix_hint = fix_hint,
        .identity = identity,
    };
}

/// True when `rel_path` matches a configured `[[allow]]` path glob.
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

/// The full type set for this run: the compiled defaults plus any
/// `[must_return_ref] extra_types` the project declared.
fn typeSet(arena: Allocator, extra: []const []const u8) Allocator.Error![]const []const u8 {
    if (extra.len == 0) return &default_types;
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, &default_types);
    try list.appendSlice(arena, extra);
    return list.toOwnedSlice(arena);
}

/// Entry point for the must-return-ref check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const allowed = ctx.cfg.extraAllowed(check_name);
    const types = try typeSet(allocator, ctx.cfg.must_return_ref.extra_types);

    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    var found: std.ArrayList(reporter.Violation) = .empty;
    for (idx.files) |*entry| {
        if (isAllowed(entry.rel_path, allowed)) continue;
        try found.appendSlice(allocator, try analyzeFile(allocator, entry.rel_path, &entry.tree, types));
    }

    if (found.items.len == 0) {
        reporter.ok("must-return-ref: no capacity-owning field returned by value", .{});
        return;
    }
    reporter.fail("must-return-ref FAILED ({d} return(s))", .{found.items.len});
    for (found.items) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    reporter.detail("  waive a deliberate transfer with `{s}` above the return.\n", .{ownership_marker});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses one in-test source string and runs the pure core over it with the
/// default type set.
fn analyzeSource(a: Allocator, source: [:0]const u8) ![]const reporter.Violation {
    const tree = try Ast.parse(a, source, .{});
    return analyzeFile(a, "src/foo.zig", &tree, &default_types);
}

/// The violation count for `source` — the shape most assertions below need.
fn countFlags(a: Allocator, source: [:0]const u8) !usize {
    return (try analyzeSource(a, source)).len;
}

// spec: Must Return Ref - Flags a capacity-owning field returned by value from its owner

test "analyzeFile flags the zlint getList case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeSource(a,
        \\const Foo = struct {
        \\    list: std.array_list.Managed(u32),
        \\    fn getList(self: *Foo) std.array_list.Managed(u32) {
        \\        return self.list;
        \\    }
        \\};
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "fn getList") != null);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "`self.list`") != null);
    try testing.expectEqual(@as(u32, 4), out[0].line.?);
}

// spec: Must Return Ref - Allows the same field returned by pointer

test "analyzeFile allows a by-pointer return of the same field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `*T` + `&self.field` IS the fix, so it can never be the bug.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn getList(self: *Foo) *std.array_list.Managed(u32) {
        \\    return &self.list;
        \\}
    ));
}

// spec: Must Return Ref - Requires the returned expression to be a field access

test "analyzeFile ignores a constructed container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A call is not a field access: the callee owns nothing yet, so returning
    // it by value is the ordinary factory shape.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn make(alloc: Allocator) std.heap.ArenaAllocator {
        \\    return std.heap.ArenaAllocator.init(alloc);
        \\}
    ));
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn empty() std.ArrayList(u32) {
        \\    return .empty;
        \\}
    ));
}

// spec: Must Return Ref - Ignores a field access whose object resolves to a type

test "analyzeFile ignores a type-qualified namespace read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `Registry.shared` reads a container-level decl off a TYPE, not a field of
    // a live owner whose deinit would free the buffer.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn shared() std.StringHashMap(u32) {
        \\    return Registry.shared;
        \\}
    ));
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn qualified() std.StringHashMap(u32) {
        \\    return pkg.Registry.shared;
        \\}
    ));
}

// spec: Must Return Ref - Ignores a function whose return type is not a capacity-owning container

test "analyzeFile ignores a non-container return type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn name(self: *Foo) []const u8 {
        \\    return self.name;
        \\}
    ));
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn point(self: *Foo) Point {
        \\    return self.origin;
        \\}
    ));
}

// spec: Must Return Ref - Sees a container through an error union and an optional return type

test "analyzeFile peels an error union and an optional return type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\fn get(self: *Foo) !std.AutoHashMap(u32, u32) {
        \\    return self.map;
        \\}
    ));
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\fn get(self: *Foo) Error!std.AutoHashMap(u32, u32) {
        \\    return self.map;
        \\}
    ));
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\fn get(self: *Foo) ?std.AutoHashMap(u32, u32) {
        \\    return self.map;
        \\}
    ));
}

// spec: Must Return Ref - Honors an OWNERSHIP transferred comment on or above the return

test "analyzeFile honors the ownership-transfer waiver" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn take(self: *Builder) std.ArrayList(u32) {
        \\    // OWNERSHIP: transferred — the builder never deinits after this.
        \\    return self.list;
        \\}
    ));
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn take(self: *Builder) std.ArrayList(u32) {
        \\    return self.list; // OWNERSHIP: transferred
        \\}
    ));
    // An unrelated comment does not waive it.
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\fn take(self: *Builder) std.ArrayList(u32) {
        \\    // caller owns this
        \\    return self.list;
        \\}
    ));
}

// spec: Must Return Ref - Attributes a return to the innermost enclosing function

test "analyzeFile attributes a nested fn's return to the nested fn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The inner fn returns a plain value; the outer one's container signature
    // must not claim it.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\fn outer(self: *Foo) std.ArrayList(u32) {
        \\    const Inner = struct {
        \\        fn name(s: *Foo) []const u8 {
        \\            return s.name;
        \\        }
        \\    };
        \\    return build(Inner.name(self));
        \\}
    ));
}

// spec: Must Return Ref - Matches a two-segment container spelling only on both segments

test "matchesType distinguishes a one-segment name from a dotted tail" {
    // `array_list.Managed` needs BOTH segments: a bare `Managed` (or some other
    // module's `Managed`) is not the std container this rule is about.
    try testing.expect(matchesType(.{ .last = "Managed", .parent = "array_list" }, &default_types));
    try testing.expect(!matchesType(.{ .last = "Managed", .parent = null }, &default_types));
    try testing.expect(!matchesType(.{ .last = "Managed", .parent = "mine" }, &default_types));
    // A one-segment entry matches whatever namespace it is reached through.
    try testing.expect(matchesType(.{ .last = "ArrayList", .parent = "std" }, &default_types));
    try testing.expect(matchesType(.{ .last = "ArrayList", .parent = null }, &default_types));
    try testing.expect(!matchesType(.{ .last = "Deque", .parent = "std" }, &default_types));
}

// spec: Must Return Ref - Extends the container set with project-declared types

test "typeSet appends the project's extra container types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const only_defaults = try typeSet(a, &.{});
    try testing.expectEqual(default_types.len, only_defaults.len);
    const extended = try typeSet(a, &.{"RingBuffer"});
    try testing.expectEqual(default_types.len + 1, extended.len);
    try testing.expect(matchesType(.{ .last = "RingBuffer", .parent = "mine" }, extended));
    try testing.expect(!matchesType(.{ .last = "RingBuffer", .parent = "mine" }, only_defaults));

    const tree = try Ast.parse(a,
        \\fn get(self: *Foo) mine.RingBuffer(u8) {
        \\    return self.ring;
        \\}
    , .{});
    try testing.expectEqual(@as(usize, 1), (try analyzeFile(a, "src/foo.zig", &tree, extended)).len);
    try testing.expectEqual(@as(usize, 0), (try analyzeFile(a, "src/foo.zig", &tree, only_defaults)).len);
}

// spec: Must Return Ref - Waives a whole subtree through an allow path glob

test "isAllowed matches a configured allow path" {
    try testing.expect(isAllowed("src/vendor/list.zig", &.{"src/vendor/*"}));
    try testing.expect(!isAllowed("src/core/list.zig", &.{"src/vendor/*"}));
}
