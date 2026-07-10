const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const decls = @import("decls.zig");

const AstError = decls.AstError;
const collectDecls = decls.collectDecls;
const isContainerNode = decls.isContainerNode;
const precedingDocText = decls.precedingDocText;

/// Coarse classification of a `pub const` initializer.
pub const PubConstKind = enum {
    struct_,
    enum_,
    union_,
    opaque_,
    fn_proto,
    value,
};

/// A top-level public constant declaration.
pub const PubConst = struct {
    name: []const u8,
    kind: PubConstKind,
    has_doc_comment: bool,
    /// Joined text of preceding /// doc comments with `///` stripped and
    /// lines joined by `\n`. Null when has_doc_comment is false.
    doc_text: ?[]const u8,
};

/// A top-level pub container declaration with its field/variant count.
/// Skips `pub const X = 42;` (value-kind) and `pub const F = fn(...)`
/// (fn_proto-kind) — only structs, enums, unions, and opaques appear.
pub const PubContainerInfo = struct {
    name: []const u8,
    kind: PubConstKind,
    /// Count of declared fields (struct/union) or variants (enum). Methods
    /// and inner const decls are not counted.
    field_count: u32,
};

/// Iterates every `pub const Name = struct/enum/union/opaque { ... }` and
/// reports the field/variant count. Used by the type-size check.
pub fn pubContainers(arena: Allocator, source: []const u8) AstError![]const PubContainerInfo {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    return pubContainersFromTree(arena, &tree);
}

/// Same as `pubContainers` but operates on an already-parsed syntax tree
/// so a caller holding a shared parse can skip re-parsing the source.
pub fn pubContainersFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const PubContainerInfo {
    var tree = tree_ptr.*;
    var result: std.ArrayList(PubContainerInfo) = .empty;

    for (try collectDecls(arena, &tree)) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        if (var_decl.visib_token == null) continue;
        const name_tok = var_decl.ast.mut_token + 1;
        const name = tree.tokenSlice(name_tok);

        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        if (!isContainerNode(&tree, init_node)) continue;
        const kind = classifyContainer(&tree, init_node);
        switch (kind) {
            .struct_, .enum_, .union_, .opaque_ => {},
            else => continue,
        }

        var buf: [2]Ast.Node.Index = undefined;
        const cdecl = tree.fullContainerDecl(&buf, init_node) orelse continue;
        try result.append(arena, .{
            .name = name,
            .kind = kind,
            .field_count = countFields(&tree, cdecl.ast.members),
        });
    }
    return result.toOwnedSlice(arena);
}

/// Counts declared struct/union fields and enum variants among `members`,
/// ignoring methods and nested const decls. Extracted so the caller's loop
/// stays within the nesting-depth cap.
fn countFields(tree: *const Ast, members: []const Ast.Node.Index) u32 {
    var field_count: u32 = 0;
    for (members) |member| {
        switch (tree.nodeTag(member)) {
            .container_field,
            .container_field_init,
            .container_field_align,
            => field_count += 1,
            else => {},
        }
    }
    return field_count;
}

/// Top-level pub const declarations classified by initializer kind.
pub fn pubConsts(arena: Allocator, source: []const u8) AstError![]const PubConst {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    return pubConstsFromTree(arena, &tree);
}

/// Same as `pubConsts` but operates on an already-parsed syntax tree so a
/// caller holding a shared parse can skip re-parsing the source.
pub fn pubConstsFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const PubConst {
    var tree = tree_ptr.*;
    var result: std.ArrayList(PubConst) = .empty;

    for (try collectDecls(arena, &tree)) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        if (var_decl.visib_token == null) continue;
        const name_tok = var_decl.ast.mut_token + 1;
        const name = tree.tokenSlice(name_tok);

        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const init_tag = tree.nodeTag(init_node);
        const kind: PubConstKind = if (isContainerNode(&tree, init_node))
            classifyContainer(&tree, init_node)
        else switch (init_tag) {
            .fn_proto, .fn_proto_simple, .fn_proto_one, .fn_proto_multi => .fn_proto,
            else => .value,
        };

        const doc_text = try precedingDocText(arena, &tree, decl);
        try result.append(arena, .{
            .name = name,
            .kind = kind,
            .has_doc_comment = doc_text != null,
            .doc_text = doc_text,
        });
    }
    return result.toOwnedSlice(arena);
}

/// Every container-scope `const` name (pub and private), including those nested
/// inside a `pub const T = struct { ... }`. Unlike `pubConstsFromTree` this keeps
/// private consts and filters to `const` (not `var`), so the naming check can
/// inspect the casing of every constant regardless of visibility. Function-body
/// locals are not reached (collectDecls descends into containers, not fn bodies).
pub fn allConstNamesFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const []const u8 {
    var tree = tree_ptr.*;
    var result: std.ArrayList([]const u8) = .empty;
    const tags = tree.tokens.items(.tag);
    for (try collectDecls(arena, &tree)) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        if (tags[var_decl.ast.mut_token] != .keyword_const) continue; // skip `var`
        try result.append(arena, tree.tokenSlice(var_decl.ast.mut_token + 1));
    }
    return result.toOwnedSlice(arena);
}

/// Source-string convenience wrapper over `allConstNamesFromTree`.
pub fn allConstNames(arena: Allocator, source: []const u8) AstError![]const []const u8 {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    return allConstNamesFromTree(arena, &tree);
}

fn classifyContainer(tree: *const Ast, node: Ast.Node.Index) PubConstKind {
    // The container keyword (struct/enum/union/opaque) is the node's *main*
    // token. firstToken returns the layout keyword for `packed struct` /
    // `extern struct`, so those would misclassify as .value if compared by
    // text — compare the main token's tag instead. tagged_union nodes
    // (`union(enum)`) also main-token on `union`.
    const main_tok = tree.nodeMainToken(node);
    return switch (tree.tokens.items(.tag)[main_tok]) {
        .keyword_struct => .struct_,
        .keyword_enum => .enum_,
        .keyword_union => .union_,
        .keyword_opaque => .opaque_,
        else => .value,
    };
}

/// A top-level function declaration with a body (i.e. .fn_decl, not extern
/// fn_proto). Carries the raw body and return-type spans so callers can do
/// shape checks without re-parsing.
pub const FnDeclInfo = struct {
    name: []const u8,
    is_pub: bool,
    /// Source slice of the return type, or null if the proto has none.
    return_type_text: ?[]const u8,
    /// Source slice of the body block, including the surrounding braces.
    body_text: []const u8,
    /// 1-indexed source line of the `fn` keyword.
    start_line: u32,
    /// Total source lines spanned by the decl, from `fn` keyword line
    /// through the closing `}` line (both inclusive).
    line_count: u32,
};

/// Yields every top-level fn declaration with a body. Bare extern protos
/// (no body) are skipped.
pub fn fnDeclInfos(arena: Allocator, source: []const u8) AstError![]const FnDeclInfo {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    return fnDeclInfosFromTree(arena, &tree);
}

/// Same as `fnDeclInfos` but operates on an already-parsed syntax tree so
/// a caller holding a shared parse can skip re-parsing the source.
pub fn fnDeclInfosFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const FnDeclInfo {
    var tree = tree_ptr.*;
    var result: std.ArrayList(FnDeclInfo) = .empty;

    const tags = tree.tokens.items(.tag);
    const newlines = try newlineOffsets(arena, tree.source); // O(log n) line lookups

    for (try collectDecls(arena, &tree)) |decl| {
        if (tree.nodeTag(decl) != .fn_decl) continue;
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);
        const is_pub = proto.visib_token != null;

        const ret_text: ?[]const u8 = if (proto.ast.return_type.unwrap()) |ret_node| blk: {
            const first_tok = tree.firstToken(ret_node);
            const start = tree.tokenStart(first_tok);
            const last_tok = tree.lastToken(ret_node);
            const end = tree.tokenStart(last_tok) + tree.tokenSlice(last_tok).len;
            break :blk tree.source[start..end];
        } else null;

        // Body starts at the first `{` after the proto and ends at lastToken(decl).
        const decl_last_tok = tree.lastToken(decl);
        const search_start: u32 = if (proto.ast.return_type.unwrap()) |ret_node|
            tree.lastToken(ret_node) + 1
        else
            tree.firstToken(decl) + 1;

        var body_start_tok: ?u32 = null;
        var i: u32 = search_start;
        while (i <= decl_last_tok) : (i += 1) {
            if (tags[i] == .l_brace) {
                body_start_tok = i;
                break;
            }
        }
        const start_tok = body_start_tok orelse continue;
        const start = tree.tokenStart(start_tok);
        const end_pos = tree.tokenStart(decl_last_tok) + tree.tokenSlice(decl_last_tok).len;
        const body_text = tree.source[start..end_pos];

        const fn_kw_byte = tree.tokenStart(proto.ast.fn_token);
        const start_line = lineFromOffsets(newlines, fn_kw_byte);
        const end_line = lineFromOffsets(newlines, end_pos -| 1);
        const line_count = end_line - start_line + 1;

        try result.append(arena, .{
            .name = name,
            .is_pub = is_pub,
            .return_type_text = ret_text,
            .body_text = body_text,
            .start_line = start_line,
            .line_count = line_count,
        });
    }
    return result.toOwnedSlice(arena);
}

/// Ascending byte offsets of every `\n` in `source`. Built once per file so
/// line lookups can binary-search instead of rescanning from byte 0.
fn newlineOffsets(arena: Allocator, source: []const u8) AstError![]const usize {
    var offs: std.ArrayList(usize) = .empty;
    for (source, 0..) |c, idx| {
        if (c == '\n') try offs.append(arena, idx);
    }
    return offs.toOwnedSlice(arena);
}

/// 1-indexed source line for `byte`: 1 + the number of newline offsets before
/// it, found by binary search over the precomputed `newlines` table.
fn lineFromOffsets(newlines: []const usize, byte: usize) u32 {
    var lo: usize = 0;
    var hi: usize = newlines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (newlines[mid] < byte) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo + 1);
}

test "pubContainers counts struct fields and enum variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\pub const Point = struct { x: i32, y: i32 };
        \\pub const Color = enum { red, green, blue, yellow };
        \\pub const Inner = union { i: i32, f: f32, s: []const u8 };
        \\pub const Methods = struct {
        \\    x: i32,
        \\    pub fn get(self: Methods) i32 { return self.x; }
        \\};
        \\pub const Value = 42;
    ;
    const containers = try pubContainers(a, source);
    try std.testing.expectEqual(@as(usize, 4), containers.len);
    try std.testing.expectEqualStrings("Point", containers[0].name);
    try std.testing.expectEqual(@as(u32, 2), containers[0].field_count);
    try std.testing.expectEqualStrings("Color", containers[1].name);
    try std.testing.expectEqual(@as(u32, 4), containers[1].field_count);
    try std.testing.expectEqualStrings("Inner", containers[2].name);
    try std.testing.expectEqual(@as(u32, 3), containers[2].field_count);
    try std.testing.expectEqualStrings("Methods", containers[3].name);
    // Methods has 1 field — `get` is a fn decl, not counted.
    try std.testing.expectEqual(@as(u32, 1), containers[3].field_count);
}

test "pubConsts and pubContainers classify tagged unions and layout structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub const Tagged = union(enum) { a: u8, b: u16 };
        \\pub const Packed = packed struct { x: u1, y: u1 };
        \\pub const Ext = extern struct { p: usize };
    ;
    const consts = try pubConsts(a, source);
    try std.testing.expectEqual(@as(usize, 3), consts.len);
    try std.testing.expectEqual(PubConstKind.union_, consts[0].kind);
    try std.testing.expectEqual(PubConstKind.struct_, consts[1].kind);
    try std.testing.expectEqual(PubConstKind.struct_, consts[2].kind);

    // All three are containers with counted fields (previously misclassified
    // as .value and skipped entirely).
    const containers = try pubContainers(a, source);
    try std.testing.expectEqual(@as(usize, 3), containers.len);
    try std.testing.expectEqual(@as(u32, 2), containers[0].field_count);
}

test "pubConsts classifies container kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub const A = struct { x: i32 };
        \\pub const B = enum { one, two };
        \\pub const C = union { a: i32, b: f32 };
        \\pub const D = 42;
        \\const private_const = 1;
    ;
    const consts = try pubConsts(a, source);
    try std.testing.expectEqual(@as(usize, 4), consts.len);
    try std.testing.expectEqual(PubConstKind.struct_, consts[0].kind);
    try std.testing.expectEqual(PubConstKind.enum_, consts[1].kind);
    try std.testing.expectEqual(PubConstKind.union_, consts[2].kind);
    try std.testing.expectEqual(PubConstKind.value, consts[3].kind);
}

test "allConstNames returns pub and private container-scope const names only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub const Public = 1;
        \\const private_max = 2;
        \\var mutable = 3;
        \\pub const Wrapper = struct {
        \\    const nested = 4;
        \\};
        \\pub fn f() void {
        \\    const local_only = 5;
        \\    _ = local_only;
        \\}
    ;
    // Public, private_max, Wrapper, nested — the `var` and the fn-body local drop out.
    const names = try allConstNames(a, source);
    try std.testing.expectEqual(@as(usize, 4), names.len);

    // The *FromTree variant yields the same set from a shared parse.
    var tree = try Ast.parse(a, source, .zig);
    const from_tree = try allConstNamesFromTree(a, &tree);
    try std.testing.expectEqual(@as(usize, 4), from_tree.len);
}

test "fnDeclInfos extracts body, return-type, and line span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\pub fn foo() void { return; }
        \\fn bar() noreturn {
        \\    unreachable;
        \\}
        \\extern fn baz() void;
    ;
    const fns = try fnDeclInfos(a, source);
    try std.testing.expectEqual(@as(usize, 2), fns.len);
    try std.testing.expectEqualStrings("foo", fns[0].name);
    try std.testing.expectEqual(true, fns[0].is_pub);
    try std.testing.expectEqualStrings("void", fns[0].return_type_text.?);
    try std.testing.expectEqualStrings("{ return; }", fns[0].body_text);
    try std.testing.expectEqual(@as(u32, 1), fns[0].start_line);
    try std.testing.expectEqual(@as(u32, 1), fns[0].line_count);
    try std.testing.expectEqualStrings("bar", fns[1].name);
    try std.testing.expectEqual(false, fns[1].is_pub);
    try std.testing.expectEqualStrings("noreturn", fns[1].return_type_text.?);
    try std.testing.expectEqual(@as(u32, 2), fns[1].start_line);
    try std.testing.expectEqual(@as(u32, 3), fns[1].line_count);
}
