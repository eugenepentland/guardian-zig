//! pub-exposes-private — a `pub fn` whose signature names a type, or an error
//! set, that is not `pub`.
//!
//! WHY: this is the accidental-API-break an agent makes without noticing. It
//! adds a helper type next to the code that uses it, forgets the `pub`, then
//! threads that type through a public signature. The file still compiles — the
//! definition and the use are in the same file — but the API is now unusable
//! from outside: a caller cannot declare a variable of the parameter's type,
//! cannot store the return value in a named field, and cannot write a wrapper.
//! The reverse mistake is worse: making the *function* pub to "expose" it while
//! its type stays private widens the surface without widening what a consumer
//! can actually do with it. Either way the break is invisible until a consumer
//! updates, which for an agent-authored change is long after the commit.
//!
//! WHAT: for every `pub fn` reachable from a file's public surface (top-level,
//! or nested inside `pub const T = struct { ... }` — a `pub fn` inside a private
//! container is not exposed and is not flagged), every parameter type and the
//! return type is scanned for identifiers that resolve, in the enclosing
//! lexical scopes, to a NON-`pub` declaration whose initializer is a type
//! definition written in this file: a `struct`/`enum`/`union`/`opaque` literal
//! (ziglint Z012) or an `error { ... }` set (Z015).
//!
//! WHY ONE FILE IS ENOUGH — this is the reason the check needs no module graph:
//! Zig already refuses cross-file access to a declaration that is not `pub`
//! (`error: 'X' is not marked 'pub'`). So the ONLY place a public signature can
//! name a private type is the file that defines it, and the compiler enforces
//! the rest. Resolution is therefore lexical and file-local, and complete.
//!
//! WHAT IS DELIBERATELY NOT FLAGGED, because it is not un-nameable:
//!   * an alias to a type that lives elsewhere — `const Allocator =
//!     std.mem.Allocator;`, `const Self = @This();`, `const Ast = std.zig.Ast;`.
//!     The alias is private, but the TYPE is public under its real name, so a
//!     caller can still name it. Only a type *definition* written here is
//!     genuinely inaccessible. This distinction is what keeps the check quiet
//!     on idiomatic Zig instead of firing on every file.
//!   * a private `const` that is a value, not a type (`const max_len = 64;`
//!     inside `[max_len]u8`) — an array length is not API surface.
//!   * a private `fn` used as a generic type constructor (`fn List(T) type`).
//!     Resolving those needs comptime evaluation, not name resolution.
//!   * a name declared in an inner scope shadowing an outer private type: the
//!     innermost declaration wins, as in Zig.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const decls = @import("../ast/decls.zig");
const lineOf = @import("../text.zig").lineOf;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const detail = reporter.detail;

const check_name = "pub-exposes-private";

/// What a name declared in a container scope resolves to, for the one question
/// this check asks: "can a caller outside this file name it?"
const DeclKind = enum {
    /// `const T = struct/enum/union/opaque { ... };` with no `pub` — a type
    /// definition that exists only here, so no caller can name it (Z012).
    private_type,
    /// `const E = error { ... };` with no `pub` — same, for an error set (Z015).
    private_error_set,
    /// Declared here, but nameable from outside (it is `pub`) or not a type
    /// definition at all (an alias, a value, a function). Recorded anyway so it
    /// SHADOWS an outer private type of the same name, exactly as in Zig.
    nameable,

    /// The noun used when reporting this kind, or null when it is not a finding.
    fn noun(self: DeclKind) ?[]const u8 {
        return switch (self) {
            .private_type => "type",
            .private_error_set => "error set",
            .nameable => null,
        };
    }
};

const Scope = std.StringHashMapUnmanaged(DeclKind);

/// Where in a signature an exposed type appeared. Named so the message can say
/// which half of the contract broke without the check re-deriving it.
const Position = enum {
    parameter,
    @"return",

    fn text(self: Position) []const u8 {
        return switch (self) {
            .parameter => "parameter",
            .@"return" => "return",
        };
    }
};

const ScanCtx = struct {
    a: Allocator,
    rel_path: []const u8,
    tree: *const Ast,
    scopes: std.ArrayList(Scope),
    out: *std.ArrayList(reporter.Violation),
    /// Names already reported for the function being scanned, so a type used in
    /// three parameters is one finding, not three.
    seen: Scope,
};

/// Classifies one container member's declaration for the scope map.
fn classify(tree: *const Ast, decl: Ast.Node.Index) ?struct { name: []const u8, kind: DeclKind } {
    if (tree.fullVarDecl(decl)) |var_decl| {
        const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const init_node = var_decl.ast.init_node.unwrap() orelse
            return .{ .name = name, .kind = .nameable };
        if (var_decl.visib_token != null) return .{ .name = name, .kind = .nameable };
        if (decls.isContainerNode(tree, init_node)) return .{ .name = name, .kind = .private_type };
        if (tree.nodeTag(init_node) == .error_set_decl)
            return .{ .name = name, .kind = .private_error_set };
        return .{ .name = name, .kind = .nameable };
    }
    if (tree.nodeTag(decl) == .fn_decl) {
        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, decl) orelse return null;
        const name_tok = proto.name_token orelse return null;
        return .{ .name = tree.tokenSlice(name_tok), .kind = .nameable };
    }
    return null;
}

/// Builds the scope map for one container's members. Zig declarations are
/// order-independent, so the whole map is built before any member is walked.
fn buildScope(a: Allocator, tree: *const Ast, members: []const Ast.Node.Index) Allocator.Error!Scope {
    var scope: Scope = .empty;
    for (members) |member| {
        const entry = classify(tree, member) orelse continue;
        try scope.put(a, entry.name, entry.kind);
    }
    return scope;
}

/// Resolves `name` innermost-scope-first, as Zig does. Null means the name is
/// not a container declaration in this file at all — a parameter, a comptime
/// type parameter, a builtin type, or an import's member — none of which this
/// check has anything to say about.
fn resolve(ctx: *const ScanCtx, name: []const u8) ?DeclKind {
    var i = ctx.scopes.items.len;
    while (i > 0) {
        i -= 1;
        if (ctx.scopes.items[i].get(name)) |kind| return kind;
    }
    return null;
}

/// Scans one type expression for identifiers resolving to a private type
/// definition, appending a violation per distinct name.
///
/// An identifier preceded by `.` is a field of something else (`std.mem` in
/// `std.mem.Allocator`), never a scope lookup, so only the leading identifier of
/// a path is resolved — which is also what makes `Private.Inner` report the
/// private root rather than a member Zig would have rejected anyway.
fn scanTypeExpr(
    ctx: *ScanCtx,
    node: Ast.Node.Index,
    fn_name: []const u8,
    position: Position,
) Allocator.Error!void {
    const tree = ctx.tree;
    const tags = tree.tokens.items(.tag);
    var tok = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (tok <= last and tok < tags.len) : (tok += 1) {
        if (tags[tok] != .identifier) continue;
        if (tok > 0 and tags[tok - 1] == .period) continue;
        const name = tree.tokenSlice(tok);
        const kind = resolve(ctx, name) orelse continue;
        const noun = kind.noun() orelse continue;
        if (ctx.seen.contains(name)) continue;
        try ctx.seen.put(ctx.a, name, kind);
        try ctx.out.append(ctx.a, .{
            .check = check_name,
            .file = ctx.rel_path,
            .line = lineOf(tree.source, tree.tokenStart(tok)),
            .message = try std.fmt.allocPrint(
                ctx.a,
                "pub fn {s}: {s} {s} `{s}` is not pub — callers cannot name it",
                .{ fn_name, position.text(), noun, name },
            ),
            .identity = try std.fmt.allocPrint(ctx.a, "{s}|{s}", .{ fn_name, name }),
            .fix_hint = "mark the type `pub`, or take/return a public type instead",
        });
    }
}

/// Scans one `pub fn`'s parameters and return type.
fn scanSignature(ctx: *ScanCtx, decl: Ast.Node.Index) Allocator.Error!void {
    var buf: [1]Ast.Node.Index = undefined;
    var proto = ctx.tree.fullFnProto(&buf, decl) orelse return;
    const name_tok = proto.name_token orelse return;
    const fn_name = ctx.tree.tokenSlice(name_tok);

    ctx.seen.clearRetainingCapacity();
    var params = proto.iterate(ctx.tree);
    while (params.next()) |param| {
        const type_expr = param.type_expr orelse continue;
        try scanTypeExpr(ctx, type_expr, fn_name, .parameter);
    }
    if (proto.ast.return_type.unwrap()) |ret| try scanTypeExpr(ctx, ret, fn_name, .@"return");
}

/// Walks one container's members, descending only into containers that are
/// themselves publicly reachable.
///
/// `exposed` is what keeps the check honest about what an outside caller can
/// actually see: a `pub fn` inside a private struct is not public API, so its
/// signature is nobody's contract and naming a private type there is fine.
fn scanContainer(
    ctx: *ScanCtx,
    members: []const Ast.Node.Index,
    exposed: bool,
) Allocator.Error!void {
    try ctx.scopes.append(ctx.a, try buildScope(ctx.a, ctx.tree, members));
    defer _ = ctx.scopes.pop();

    for (members) |member| {
        if (ctx.tree.nodeTag(member) == .fn_decl) {
            if (!exposed) continue;
            var buf: [1]Ast.Node.Index = undefined;
            const proto = ctx.tree.fullFnProto(&buf, member) orelse continue;
            if (proto.visib_token == null) continue;
            try scanSignature(ctx, member);
            continue;
        }
        const var_decl = ctx.tree.fullVarDecl(member) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        if (!decls.isContainerNode(ctx.tree, init_node)) continue;
        var cbuf: [2]Ast.Node.Index = undefined;
        const container = ctx.tree.fullContainerDecl(&cbuf, init_node) orelse continue;
        try scanContainer(ctx, container.ast.members, exposed and var_decl.visib_token != null);
    }
}

/// Appends one Violation per exposed private type in `tree` to `out`.
fn scanTree(
    a: Allocator,
    rel_path: []const u8,
    tree: *const Ast,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    var ctx: ScanCtx = .{
        .a = a,
        .rel_path = rel_path,
        .tree = tree,
        .scopes = .empty,
        .out = out,
        .seen = .empty,
    };
    try scanContainer(&ctx, tree.rootDecls(), true);
}

/// Pure-function entry: the rendered violation lines for every private type
/// exposed by a `pub fn` in `content`. Empty slice = pass.
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

/// Entry point for the pub-exposes-private check.
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
        reporter.ok("pub-exposes-private: every pub fn signature names only nameable types", .{});
        return;
    }
    reporter.fail("pub-exposes-private FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: mark the type `pub` if it is part of the contract, or change the " ++
        "signature to take/return a public type. Demoting the fn to private also " ++
        "resolves it — the signature is then nobody's contract.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Pub Exposes Private - Flags a pub fn whose parameter type is not pub

test "analyzeContent flags a private parameter type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const Widget = struct { id: u32 };
        \\pub fn place(w: Widget) void { _ = w; }
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0], "parameter type `Widget`") != null);
}

// spec: Pub Exposes Private - Flags a pub fn whose return type is not pub

test "analyzeContent flags a private return type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const Handle = opaque {};
        \\pub fn open() *Handle { return undefined; }
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0], "return type `Handle`") != null);
}

// spec: Pub Exposes Private - Flags a pub fn returning an error set that is not pub

test "analyzeContent flags a private error set in the return type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const Error = error{ Bad, Worse };
        \\pub fn parse() Error!void {}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0], "return error set `Error`") != null);
}

// spec: Pub Exposes Private - Allows a pub type and a private alias to a type defined elsewhere

test "analyzeContent allows pub types and private aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A pub definition is nameable by construction.
    const public = try analyzeContent(a, "src/x.zig",
        \\pub const Widget = struct { id: u32 };
        \\pub fn place(w: Widget) Widget { return w; }
    );
    try testing.expectEqual(@as(usize, 0), public.len);
    // The alias is private, but `std.mem.Allocator` is nameable under its own
    // name — flagging this is what would make the check unusable.
    const alias = try analyzeContent(a, "src/y.zig",
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\const max_len = 64;
        \\pub fn dup(gpa: Allocator, buf: [max_len]u8) void { _ = gpa; _ = buf; }
    );
    try testing.expectEqual(@as(usize, 0), alias.len);
}

// spec: Pub Exposes Private - Ignores a pub fn nested inside a container that is not pub

test "analyzeContent ignores a pub fn inside a private container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Not reachable from outside, so its signature is nobody's contract.
    const hidden = try analyzeContent(a, "src/x.zig",
        \\const Widget = struct { id: u32 };
        \\const Inner = struct {
        \\    pub fn place(w: Widget) void { _ = w; }
        \\};
    );
    try testing.expectEqual(@as(usize, 0), hidden.len);
    // The same method inside a pub container IS reachable, and is flagged.
    const exposed = try analyzeContent(a, "src/y.zig",
        \\const Widget = struct { id: u32 };
        \\pub const Outer = struct {
        \\    pub fn place(w: Widget) void { _ = w; }
        \\};
    );
    try testing.expectEqual(@as(usize, 1), exposed.len);
}

test "analyzeContent reports one finding per type however many parameters use it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const Widget = struct { id: u32 };
        \\pub fn swap(a: Widget, b: Widget) Widget { _ = b; return a; }
    );
    try testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent lets an inner declaration shadow an outer private type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const Widget = struct { id: u32 };
        \\pub const Outer = struct {
        \\    pub const Widget = struct { id: u64 };
        \\    pub fn place(w: Widget) void { _ = w; }
        \\};
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent leaves a private fn signature alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const Widget = struct { id: u32 };
        \\fn place(w: Widget) void { _ = w; }
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}
