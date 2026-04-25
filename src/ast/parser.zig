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
};

/// Tokenizer-based @import extraction. Skips strings/comments correctly.
pub fn imports(arena: Allocator, source: []const u8) []const Import {
    var result: std.ArrayListUnmanaged(Import) = .empty;
    const z = arena.dupeZ(u8, source) catch return &.{};
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
        result.append(arena, .{ .path = path }) catch {};
    }
    return result.toOwnedSlice(arena) catch &.{};
}

/// Errors that AST primitives may propagate.
pub const AstError = std.mem.Allocator.Error;

/// AST-based public function discovery.
pub fn pubFns(arena: Allocator, source: []const u8) AstError![]const PubFn {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    var result: std.ArrayListUnmanaged(PubFn) = .empty;

    for (tree.rootDecls()) |decl| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        if (proto.visib_token == null) continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);

        const return_kind = classifyReturn(&tree, proto);
        const has_doc = hasPrecedingDocComment(&tree, decl);
        const proto_span = collapseWhitespace(arena, fnProtoSource(&tree, proto)) catch "";

        result.append(arena, .{
            .name = name,
            .return_kind = return_kind,
            .has_doc_comment = has_doc,
            .proto_span = proto_span,
        }) catch {};
    }
    return result.toOwnedSlice(arena) catch &.{};
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

/// All top-level functions (pub and private), with parameter counts.
pub fn allFns(arena: Allocator, source: []const u8) AstError![]const FnInfo {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    var result: std.ArrayListUnmanaged(FnInfo) = .empty;

    for (tree.rootDecls()) |decl| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);

        var it = proto.iterate(&tree);
        var count: u32 = 0;
        while (it.next()) |_| count += 1;

        result.append(arena, .{
            .name = name,
            .is_pub = proto.visib_token != null,
            .param_count = count,
            .return_kind = classifyReturn(&tree, proto),
        }) catch {};
    }
    return result.toOwnedSlice(arena) catch &.{};
}

/// Top-level pub const declarations classified by initializer kind.
pub fn pubConsts(arena: Allocator, source: []const u8) AstError![]const PubConst {
    const z = try arena.dupeZ(u8, source);
    var tree = try Ast.parse(arena, z, .zig);
    var result: std.ArrayListUnmanaged(PubConst) = .empty;

    for (tree.rootDecls()) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        if (var_decl.visib_token == null) continue;
        const name_tok = var_decl.ast.mut_token + 1;
        const name = tree.tokenSlice(name_tok);

        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const init_tag = tree.nodeTag(init_node);
        const kind: PubConstKind = switch (init_tag) {
            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing => classifyContainer(&tree, init_node),
            .fn_proto, .fn_proto_simple, .fn_proto_one, .fn_proto_multi => .fn_proto,
            else => .value,
        };

        const has_doc = hasPrecedingDocComment(&tree, decl);
        result.append(arena, .{ .name = name, .kind = kind, .has_doc_comment = has_doc }) catch {};
    }
    return result.toOwnedSlice(arena) catch &.{};
}

fn hasPrecedingDocComment(tree: *const Ast, decl: Ast.Node.Index) bool {
    const first_tok = tree.firstToken(decl);
    if (first_tok == 0) return false;
    return tree.tokens.items(.tag)[first_tok - 1] == .doc_comment;
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
    // First token of a container_decl is the container keyword: struct/enum/union/opaque
    const first_tok = tree.firstToken(node);
    const text = tree.tokenSlice(first_tok);
    if (std.mem.eql(u8, text, "struct")) return .struct_;
    if (std.mem.eql(u8, text, "enum")) return .enum_;
    if (std.mem.eql(u8, text, "union")) return .union_;
    if (std.mem.eql(u8, text, "opaque")) return .opaque_;
    return .value;
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
