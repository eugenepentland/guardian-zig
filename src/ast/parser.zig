//! Zig-AST extraction helpers over `std.zig.Ast`: pull @import paths and public
//! fn/const declarations (name, return kind, doc text, signature span) plus
//! per-fn body info that the structural checks consume. `...FromTree` variants
//! reuse the shared parse; the plain variants parse the passed source once.

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
    /// Total syntactic parameters, retained for callers that describe the
    /// complete signature.
    param_count: u32,
    /// Parameters introduced with `comptime`; structural arity checks subtract
    /// these because they are generic specialization inputs, not runtime data
    /// that can usefully be bundled into an options struct.
    comptime_param_count: u32,
    return_kind: ReturnKind,
    /// 1-indexed source line of the fn's name token, so a finding about this
    /// function can be reported as `file:line` instead of file-only.
    line: u32 = 0,
};

/// Coarse classification of a function's return type.
pub const ReturnKind = enum {
    err_union_inferred, // `!T` with no explicit error set
    err_union_explicit, // `error{...}!T` or `MyErr!T`
    type_kw, // returns the literal `type`
    anyerror_union, // `anyerror!T`
    other,
};

// Shared declaration primitives (collectDecls, isContainerNode, doc-comment
// extraction) live in the dependency-free decls.zig leaf so parser.zig and
// containers.zig can both use them without an import cycle.
const decls = @import("decls.zig");
pub const AstError = decls.AstError;
pub const collectDecls = decls.collectDecls;
const precedingDocText = decls.precedingDocText;

// Container/const/doc queries live in containers.zig (keeps this file under
// the file-size cap). Re-exported here so callers keep using `ast.pubConsts`,
// `ast.pubContainers`, `ast.PubConst`, etc. through this module.
const containers = @import("containers.zig");
pub const PubConstKind = containers.PubConstKind;
pub const PubConst = containers.PubConst;
pub const PubContainerInfo = containers.PubContainerInfo;
pub const pubContainers = containers.pubContainers;
pub const pubContainersFromTree = containers.pubContainersFromTree;
pub const pubConsts = containers.pubConsts;
pub const pubConstsFromTree = containers.pubConstsFromTree;
pub const allConstNames = containers.allConstNames;
pub const allConstNamesFromTree = containers.allConstNamesFromTree;

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
    var result: std.ArrayList(Import) = .empty;
    const z = try arena.dupeSentinel(u8, source, 0);
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

/// AST-based public function discovery.
pub fn pubFns(arena: Allocator, source: []const u8) AstError![]const PubFn {
    const z = try arena.dupeSentinel(u8, source, 0);
    var tree = try Ast.parse(arena, z, .{});
    return pubFnsFromTree(arena, &tree);
}

/// Same as `pubFns` but operates on an already-parsed syntax tree, so a
/// caller holding a shared parse (see ast/index.zig) avoids re-tokenizing
/// and re-parsing the source for this query.
pub fn pubFnsFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const PubFn {
    var tree = tree_ptr.*;
    var result: std.ArrayList(PubFn) = .empty;

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
    var buf: std.ArrayList(u8) = .empty;
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

// fn-declaration shape queries (body/return-type/line-span) live in
// containers.zig alongside the other decl-shape queries; re-exported so
// callers keep using `ast.fnDeclInfos` / `ast.FnDeclInfo`.
pub const FnDeclInfo = containers.FnDeclInfo;
pub const fnDeclInfos = containers.fnDeclInfos;
pub const fnDeclInfosFromTree = containers.fnDeclInfosFromTree;

/// All top-level functions (pub and private), with parameter counts.
pub fn allFns(arena: Allocator, source: []const u8) AstError![]const FnInfo {
    const z = try arena.dupeSentinel(u8, source, 0);
    var tree = try Ast.parse(arena, z, .{});
    return allFnsFromTree(arena, &tree);
}

/// Same as `allFns` but operates on an already-parsed syntax tree so a
/// caller holding a shared parse can skip re-parsing the source.
pub fn allFnsFromTree(arena: Allocator, tree_ptr: *const Ast) AstError![]const FnInfo {
    var tree = tree_ptr.*;
    var result: std.ArrayList(FnInfo) = .empty;

    for (try collectDecls(arena, &tree)) |decl| {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);

        var it = proto.iterate(&tree);
        var count: u32 = 0;
        var comptime_count: u32 = 0;
        while (it.next()) |param| {
            count += 1;
            const modifier = param.comptime_noalias orelse continue;
            if (tree.tokens.items(.tag)[modifier] == .keyword_comptime) comptime_count += 1;
        }

        try result.append(arena, .{
            .name = name,
            .is_pub = proto.visib_token != null,
            .param_count = count,
            .comptime_param_count = comptime_count,
            .return_kind = classifyReturn(&tree, proto),
            .line = @intCast(tree.tokenLocation(0, name_tok).line + 1),
        });
    }
    return result.toOwnedSlice(arena);
}

fn classifyReturn(tree: *const Ast, proto: Ast.full.FnProto) ReturnKind {
    const ret_node = proto.ast.return_type.unwrap() orelse return .other;
    if (tree.nodeTag(ret_node) == .error_union) return classifyErrorUnion(tree, ret_node);
    return classifyPlainReturn(tree, ret_node);
}

/// Classifies an `error_union` return type: `anyerror!T` vs any other
/// explicit/named error set.
fn classifyErrorUnion(tree: *const Ast, ret_node: Ast.Node.Index) ReturnKind {
    // Look at the left-hand-side identifier of the error_union for `anyerror`.
    const text = tree.tokenSlice(tree.firstToken(ret_node));
    if (std.mem.eql(u8, text, "anyerror")) return .anyerror_union;
    return .err_union_explicit;
}

/// Classifies a non-error-union return type: `!T` (inferred error set),
/// the literal `type`, or anything else.
fn classifyPlainReturn(tree: *const Ast, ret_node: Ast.Node.Index) ReturnKind {
    const first_tok = tree.firstToken(ret_node);
    if (first_tok > 0 and tree.tokens.items(.tag)[first_tok - 1] == .bang) {
        return .err_union_inferred;
    }
    if (std.mem.eql(u8, tree.tokenSlice(first_tok), "type")) return .type_kw;
    return .other;
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

test "the *FromTree variants operate on a shared parsed tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\pub const T = struct { x: i32, pub fn m(self: T) void { _ = self; } };
        \\pub fn top(a2: i32) void { _ = a2; }
        \\pub const V = 1;
    ;
    var tree = try Ast.parse(a, source, .{});
    const t = &tree;
    try std.testing.expect((try collectDecls(a, t)).len >= 3);
    try std.testing.expect((try pubFnsFromTree(a, t)).len == 2);
    try std.testing.expect((try allFnsFromTree(a, t)).len == 2);
    try std.testing.expect((try fnDeclInfosFromTree(a, t)).len == 2);
    try std.testing.expect((try pubContainersFromTree(a, t)).len == 1);
    try std.testing.expect((try pubConstsFromTree(a, t)).len >= 2);
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
