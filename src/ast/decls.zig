//! Shared AST declaration primitives used by both parser.zig (function/import
//! queries) and containers.zig (container/const/fn-decl-shape queries). Kept
//! in a dependency-free leaf module so those two can each import it without
//! forming an import cycle.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

/// Errors that AST primitives may propagate.
pub const AstError = std.mem.Allocator.Error;

/// True when `node` is a container definition (struct/enum/union/opaque,
/// including tagged unions) — i.e. something with a `{ members }` body.
pub fn isContainerNode(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

/// Flattens every declaration reachable from the root, descending into the
/// members of any container that initializes a const/var decl. Idiomatic Zig
/// puts methods and nested types inside `pub const T = struct { ... }`; without
/// this recursion the per-decl queries below would only ever see top-level
/// declarations, so an agent could dodge every AST check by wrapping code in a
/// struct. Containers returned from a function body (generic type
/// constructors) are not reached — those live inside expressions, not decls.
pub fn collectDecls(arena: Allocator, tree: *const Ast) AstError![]const Ast.Node.Index {
    var out: std.ArrayList(Ast.Node.Index) = .empty;
    try collectDeclsInto(arena, tree, tree.rootDecls(), &out);
    return out.toOwnedSlice(arena);
}

fn collectDeclsInto(
    arena: Allocator,
    tree: *const Ast,
    members: []const Ast.Node.Index,
    out: *std.ArrayList(Ast.Node.Index),
) AstError!void {
    for (members) |decl| {
        try out.append(arena, decl);
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        if (!isContainerNode(tree, init_node)) continue;
        var buf: [2]Ast.Node.Index = undefined;
        const cdecl = tree.fullContainerDecl(&buf, init_node) orelse continue;
        try collectDeclsInto(arena, tree, cdecl.ast.members, out);
    }
}

/// Returns the joined text of /// doc comments immediately preceding `decl`,
/// with the `///` prefix stripped and a single space of leading whitespace
/// removed per line. Multi-line doc comments are joined with `\n`. Returns
/// null when there are no preceding doc-comment tokens.
pub fn precedingDocText(arena: Allocator, tree: *const Ast, decl: Ast.Node.Index) AstError!?[]const u8 {
    const first_tok = tree.firstToken(decl);
    if (first_tok == 0) return null;
    const tags = tree.tokens.items(.tag);
    if (tags[first_tok - 1] != .doc_comment) return null;

    // Walk backwards through the run of doc_comment tokens.
    var start: u32 = first_tok;
    while (start > 0 and tags[start - 1] == .doc_comment) start -= 1;

    var buf: std.ArrayList(u8) = .empty;
    var i: u32 = start;
    while (i < first_tok) : (i += 1) {
        const slice = tree.tokenSlice(i);
        const stripped = stripDocPrefix(slice);
        if (i > start) try buf.append(arena, '\n');
        try buf.appendSlice(arena, stripped);
    }
    const owned = try buf.toOwnedSlice(arena);
    return owned;
}

fn stripDocPrefix(slice: []const u8) []const u8 {
    var s = slice;
    if (std.mem.startsWith(u8, s, "///")) s = s[3..];
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

test "collectDecls descends into container members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub const T = struct { x: i32, pub fn m(self: T) void { _ = self; } };
        \\pub fn top() void {}
    ;
    var tree = try Ast.parse(a, source, .zig);
    // T, x, m, top → at least the outer decl plus the nested method.
    try std.testing.expect((try collectDecls(a, &tree)).len >= 3);
}

test "isContainerNode detects container initializers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\const S = struct { x: i32 };
        \\const V = 42;
    ;
    var tree = try Ast.parse(a, source, .zig);
    var saw_container = false;
    var saw_value = false;
    for (tree.rootDecls()) |decl| {
        const vd = tree.fullVarDecl(decl) orelse continue;
        const init_node = vd.ast.init_node.unwrap() orelse continue;
        if (isContainerNode(&tree, init_node)) saw_container = true else saw_value = true;
    }
    try std.testing.expect(saw_container);
    try std.testing.expect(saw_value);
}

test "precedingDocText joins the run of preceding doc comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\/// line one
        \\/// line two
        \\pub const X = 1;
        \\pub const Y = 2;
    ;
    var tree = try Ast.parse(a, source, .zig);
    const decls = tree.rootDecls();
    const doc = try precedingDocText(a, &tree, decls[0]);
    try std.testing.expectEqualStrings("line one\nline two", doc.?);
    try std.testing.expect((try precedingDocText(a, &tree, decls[1])) == null);
}
