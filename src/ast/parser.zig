const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// One @import("...") call extracted from source. Path is the literal argument.
pub const Import = struct {
    path: []const u8,
};

/// A top-level public function discovered by pubFns().
pub const PubFn = struct {
    name: []const u8,
    return_kind: ReturnKind,
    has_doc_comment: bool,
    /// Joined text of preceding /// doc comments with `///` stripped and
    /// lines joined by `\n`. Null when has_doc_comment is false.
    doc_text: ?[]const u8,
    /// Source span from the `fn` keyword through the return type, with
    /// runs of whitespace collapsed to a single space.
    proto_span: []const u8,
};

/// A top-level function (pub or private) discovered by allFns().
pub const FnInfo = struct {
    name: []const u8,
    is_pub: bool,
    param_count: u32,
    return_kind: ReturnKind,
};

/// Coarse classification of a function's return type.
pub const ReturnKind = enum {
    err_union_inferred, // `!T` with no explicit error set
    err_union_explicit, // `error{...}!T` or `MyErr!T`
    type_kw, // returns the literal `type`
    anyerror_union, // `anyerror!T`
    other,
};

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

/// Tokenizer-based @import extraction. Skips strings/comments correctly.
/// Returns an empty slice on allocator failure (best-effort, for use in
/// hot paths where we'd rather skip than abort).
pub fn imports(arena: Allocator, source: []const u8) []const Import {
    return importsImpl(arena, source) catch |e| {
        std.log.warn("ast.imports allocation failed: {s}", .{@errorName(e)});
        return &.{};
    };
}

fn importsImpl(arena: Allocator, source: []const u8) ![]const Import {
    var result: std.ArrayListUnmanaged(Import) = .empty;
    const z = try arena.dupeZ(u8, source);
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .builtin) continue;
        const name = z[t.loc.start..t.loc.end];
        if (!std.mem.eql(u8, name, "@import")) continue;

        const lparen = tok.next();
        if (lparen.tag != .l_paren) continue;
        const str = tok.next();
        if (str.tag != .string_literal) continue;
        const raw = z[str.loc.start..str.loc.end];
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') continue;
        const path = raw[1 .. raw.len - 1];
        try result.append(arena, .{ .path = path });
    }
    return result.toOwnedSlice(arena);
}

/// Errors that AST primitives may propagate.
pub const AstError = std.mem.Allocator.Error;

/// True when `node` is a container definition (struct/enum/union/opaque,
/// including tagged unions) — i.e. something with a `{ members }` body.
fn isContainerNode(tree: *const Ast, node: Ast.Node.Index) bool {
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
    var out: std.ArrayListUnmanaged(Ast.Node.Index) = .empty;
    try collectDeclsInto(arena, tree, tree.rootDecls(), &out);
    return out.toOwnedSlice(arena);
}

fn collectDeclsInto(
    arena: Allocator,
    tree: *const Ast,
    members: []const Ast.Node.Index,
    out: *std.ArrayListUnmanaged(Ast.Node.Index),
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

/// AST-based public function discovery.
pub fn pubFns(arena: Allocator, source: []const u8) AstError![]const PubFn {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    return pubFnsFromTree(arena, &tree);
}

/// Same as `pubFns` but operates on an already-parsed syntax tree, so a
/// caller holding a shared parse (see ast/index.zig) avoids re-tokenizing
/// and re-parsing the source for this query.
pub fn pubFnsFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const PubFn {
    var tree = tree_ptr.*;
    var result: std.ArrayListUnmanaged(PubFn) = .empty;

    for (try collectDecls(arena, &tree)) |decl| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        if (proto.visib_token == null) continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);

        const return_kind = classifyReturn(&tree, proto);
        const doc_text = try precedingDocText(arena, &tree, decl);
        const proto_span = try collapseWhitespace(arena, fnProtoSource(&tree, proto));

        try result.append(arena, .{
            .name = name,
            .return_kind = return_kind,
            .has_doc_comment = doc_text != null,
            .doc_text = doc_text,
            .proto_span = proto_span,
        });
    }
    return result.toOwnedSlice(arena);
}

fn fnProtoSource(tree: *const Ast, proto: Ast.full.FnProto) []const u8 {
    const fn_kw = proto.ast.fn_token;
    const ret_node = proto.ast.return_type.unwrap() orelse return tree.tokenSlice(fn_kw);
    const last_tok = tree.lastToken(ret_node);
    const start = tree.tokenStart(fn_kw);
    const end_tok = tree.tokenStart(last_tok) + tree.tokenSlice(last_tok).len;
    return tree.source[start..end_tok];
}

fn collapseWhitespace(arena: Allocator, text: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var prev_was_space = false;
    for (text) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_space) {
            if (!prev_was_space and buf.items.len > 0) try buf.append(arena, ' ');
            prev_was_space = true;
        } else {
            try buf.append(arena, c);
            prev_was_space = false;
        }
    }
    // Trim trailing space
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') _ = buf.pop();
    return buf.toOwnedSlice(arena);
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
    var result: std.ArrayListUnmanaged(FnDeclInfo) = .empty;

    const tags = tree.tokens.items(.tag);

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
        const start_line = lineOfByte(tree.source, fn_kw_byte);
        const end_line = lineOfByte(tree.source, end_pos -| 1);
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

fn lineOfByte(source: []const u8, byte: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < byte and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

/// All top-level functions (pub and private), with parameter counts.
pub fn allFns(arena: Allocator, source: []const u8) AstError![]const FnInfo {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    return allFnsFromTree(arena, &tree);
}

/// Same as `allFns` but operates on an already-parsed syntax tree so a
/// caller holding a shared parse can skip re-parsing the source.
pub fn allFnsFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const FnInfo {
    var tree = tree_ptr.*;
    var result: std.ArrayListUnmanaged(FnInfo) = .empty;

    for (try collectDecls(arena, &tree)) |decl| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);

        var it = proto.iterate(&tree);
        var count: u32 = 0;
        while (it.next()) |_| count += 1;

        try result.append(arena, .{
            .name = name,
            .is_pub = proto.visib_token != null,
            .param_count = count,
            .return_kind = classifyReturn(&tree, proto),
        });
    }
    return result.toOwnedSlice(arena);
}

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
    var result: std.ArrayListUnmanaged(PubContainerInfo) = .empty;

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
        var field_count: u32 = 0;
        for (cdecl.ast.members) |member| {
            const tag = tree.nodeTag(member);
            switch (tag) {
                .container_field,
                .container_field_init,
                .container_field_align,
                => field_count += 1,
                else => {},
            }
        }
        try result.append(arena, .{
            .name = name,
            .kind = kind,
            .field_count = field_count,
        });
    }
    return result.toOwnedSlice(arena);
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
    var result: std.ArrayListUnmanaged(PubConst) = .empty;

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

fn hasPrecedingDocComment(tree: *const Ast, decl: Ast.Node.Index) bool {
    const first_tok = tree.firstToken(decl);
    if (first_tok == 0) return false;
    return tree.tokens.items(.tag)[first_tok - 1] == .doc_comment;
}

/// Returns the joined text of /// doc comments immediately preceding `decl`,
/// with the `///` prefix stripped and a single space of leading whitespace
/// removed per line. Multi-line doc comments are joined with `\n`. Returns
/// null when there are no preceding doc-comment tokens.
fn precedingDocText(arena: Allocator, tree: *const Ast, decl: Ast.Node.Index) AstError!?[]const u8 {
    const first_tok = tree.firstToken(decl);
    if (first_tok == 0) return null;
    const tags = tree.tokens.items(.tag);
    if (tags[first_tok - 1] != .doc_comment) return null;

    // Walk backwards through the run of doc_comment tokens.
    var start: u32 = first_tok;
    while (start > 0 and tags[start - 1] == .doc_comment) start -= 1;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
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

fn classifyReturn(tree: *const Ast, proto: Ast.full.FnProto) ReturnKind {
    const ret_node = proto.ast.return_type.unwrap() orelse return .other;
    const tag = tree.nodeTag(ret_node);
    if (tag == .error_union) {
        // Look at the left-hand-side identifier of the error_union for `anyerror`.
        const first_tok = tree.firstToken(ret_node);
        const text = tree.tokenSlice(first_tok);
        if (std.mem.eql(u8, text, "anyerror")) return .anyerror_union;
        return .err_union_explicit;
    }
    const first_tok = tree.firstToken(ret_node);
    if (first_tok > 0) {
        const prev_tag = tree.tokens.items(.tag)[first_tok - 1];
        if (prev_tag == .bang) return .err_union_inferred;
    }
    const text = tree.tokenSlice(first_tok);
    if (std.mem.eql(u8, text, "type")) return .type_kw;
    return .other;
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

test "imports finds simple @import calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\const std = @import("std");
        \\const foo = @import("foo.zig");
        \\const bar = @import("../bar.zig");
    ;
    const result = imports(a, source);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("std", result[0].path);
    try std.testing.expectEqualStrings("foo.zig", result[1].path);
    try std.testing.expectEqualStrings("../bar.zig", result[2].path);
}

test "imports skips @import inside comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\const x = @import("real.zig");
        \\// @import("commented.zig")
        \\/// @import("doc-commented.zig")
    ;
    const result = imports(a, source);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("real.zig", result[0].path);
}

test "imports skips @import inside string literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\const x = @import("real.zig");
        \\const s = "@import(\"in-string.zig\")";
    ;
    const result = imports(a, source);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("real.zig", result[0].path);
}

test "pubFns finds public functions only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub fn foo() void {}
        \\fn private() void {}
        \\pub fn bar(x: i32) !void {}
    ;
    const fns = try pubFns(a, source);
    try std.testing.expectEqual(@as(usize, 2), fns.len);
    try std.testing.expectEqualStrings("foo", fns[0].name);
    try std.testing.expectEqualStrings("bar", fns[1].name);
    try std.testing.expectEqual(ReturnKind.err_union_inferred, fns[1].return_kind);
    try std.testing.expectEqualStrings("fn foo() void", fns[0].proto_span);
    try std.testing.expectEqualStrings("fn bar(x: i32) !void", fns[1].proto_span);
}

test "pubFns classifies return type=type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub fn List(comptime T: type) type { return T; }
        \\pub fn run() void {}
    ;
    const fns = try pubFns(a, source);
    try std.testing.expectEqual(@as(usize, 2), fns.len);
    try std.testing.expectEqual(ReturnKind.type_kw, fns[0].return_kind);
    try std.testing.expectEqual(ReturnKind.other, fns[1].return_kind);
}

test "queries descend into methods and types nested in containers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub const Server = struct {
        \\    port: u16,
        \\    pub fn start(self: Server) !void { _ = self; }
        \\    fn helper(self: Server) void { _ = self; }
        \\    pub const Inner = struct { a: i32, b: i32 };
        \\};
        \\pub fn topLevel() void {}
    ;

    // pubFns sees the nested pub method and the top-level fn (not the private one).
    const pf = try pubFns(a, source);
    try std.testing.expectEqual(@as(usize, 2), pf.len);

    // allFns sees the nested private method too.
    const af = try allFns(a, source);
    try std.testing.expectEqual(@as(usize, 3), af.len);

    // fnDeclInfos sees both nested methods plus the top-level fn.
    const fd = try fnDeclInfos(a, source);
    try std.testing.expectEqual(@as(usize, 3), fd.len);

    // pubContainers sees the outer struct AND the nested Inner struct.
    const pc = try pubContainers(a, source);
    try std.testing.expectEqual(@as(usize, 2), pc.len);
}

test "allFns returns all functions with params and visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\pub fn foo(x: i32, y: i32) void {}
        \\fn private(a: u8) void {}
        \\pub fn nullary() void {}
    ;
    const fns = try allFns(a, source);
    try std.testing.expectEqual(@as(usize, 3), fns.len);
    try std.testing.expectEqualStrings("foo", fns[0].name);
    try std.testing.expectEqual(true, fns[0].is_pub);
    try std.testing.expectEqual(@as(u32, 2), fns[0].param_count);
    try std.testing.expectEqualStrings("private", fns[1].name);
    try std.testing.expectEqual(false, fns[1].is_pub);
    try std.testing.expectEqual(@as(u32, 1), fns[1].param_count);
    try std.testing.expectEqual(@as(u32, 0), fns[2].param_count);
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
