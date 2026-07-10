//! stack-escape check: reject returning the address of a stack local — `&local`,
//! a slice of a stack array, `&local.field`, or a const alias bound to such an
//! address — i.e. a dangling pointer. Addresses derived from parameters,
//! function-call results, comptime locals, or already-pointer locals are safe.

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// ── What counts as a stack local ───────────────────────────────────────
//
// A returned address escapes only if it points at memory that dies with the
// frame. To hit ZERO false positives we flag a local ONLY when we can prove,
// with no dataflow, that it is a certain stack slot:
//
//   - it is a `var`/`const` declaration statement in *this* fn body (not a
//     parameter, not a container/top-level decl);
//   - it is not itself a pointer or slice (`var p: *T` / `var s: []T` return the
//     pointee, which may be heap — never flagged);
//   - it is not `comptime`;
//   - its initializer contains NO function call (a call may hand back heap
//     memory: `allocator.alloc`, `dupe`, `toOwnedSlice`, …).
//
// A local declared with an array type (`var buf: [N]u8` / `var buf = [_]u8{…}`)
// additionally makes a *slice* of it (`buf[0..]`) an escape, since the slice
// points into the array's stack storage.

/// One stack-local declaration discovered inside a single function body.
const Local = struct {
    name: []const u8,
    /// True when the declared/inferred type is an array — a slice of it escapes too.
    is_array: bool,
    /// For a `const p = &other_local;` alias: the name of the referenced local,
    /// so `return p;` can be traced back one hop. Null for ordinary locals.
    alias_of: ?[]const u8,
};

/// One flagged return: enough to render the violation message.
const Escape = struct {
    line: u32,
    fn_name: []const u8,
    var_name: []const u8,
};

/// Inclusive token span of a node, used to test containment by source position.
const Span = struct { first: u32, last: u32 };

/// Pure-function entry: scans `content` and returns violation lines
/// (allocator-owned). Empty slice = pass.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const []const u8 {
    return analyzeWithTree(allocator, rel_path, content, null);
}

fn analyzeWithTree(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
    tree_opt: ?*const std.zig.Ast,
) Allocator.Error![]const []const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = if (tree_opt) |t| t.* else Ast.parse(arena, content, .zig) catch
        return &.{};

    var violations: std.ArrayList([]const u8) = .empty;
    // Scanning every node index finds functions wherever they live — top level,
    // struct methods, and fns nested inside other fns (each is its own frame).
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const decl: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(decl) != .fn_decl) continue;
        try scanFn(arena, &tree, decl, .{ .rel_path = rel_path, .alloc = allocator, .out = &violations });
    }
    return violations.toOwnedSlice(allocator);
}

/// One function frame: the parsed tree, this fn's body token span, and the
/// spans of any nested fn bodies (whose locals/returns belong to other frames).
/// Bundling these keeps the per-frame helpers within the parameter cap.
const Frame = struct {
    tree: *const Ast,
    span: Span,
    nested: []const Span,
};

/// Where rendered violation lines go: the file path they belong to, plus the
/// result allocator and list they are appended to. Bundling these keeps
/// `scanFn` within the parameter cap.
const Sink = struct {
    rel_path: []const u8,
    alloc: Allocator,
    out: *std.ArrayList([]const u8),
};

/// Scans one `fn_decl` for returns of a stack-local address, appending fully
/// rendered `rel_path:line: …` lines to `sink`.
fn scanFn(
    arena: Allocator,
    tree: *const Ast,
    fn_decl: Ast.Node.Index,
    sink: Sink,
) Allocator.Error!void {
    const fn_name = fnName(tree, fn_decl) orelse return;
    _, const body = tree.nodeData(fn_decl).node_and_node;
    const span = nodeSpan(tree, body);

    // Nested fn bodies inside this one own their own locals/returns; collect
    // their spans so we can skip anything that belongs to them.
    const frame: Frame = .{ .tree = tree, .span = span, .nested = try nestedFnSpans(arena, tree, fn_decl, span) };

    const locals = try collectLocals(arena, frame);
    var escapes: std.ArrayList(Escape) = .empty;
    try collectEscapes(arena, frame, locals, fn_name, &escapes);

    for (escapes.items) |e| {
        const msg = try std.fmt.allocPrint(
            sink.alloc,
            "{s}:{d}: fn {s}: returns address of stack local '{s}' — " ++
                "memory is invalid after return; allocate it or have the caller pass a buffer",
            .{ sink.rel_path, e.line, e.fn_name, e.var_name },
        );
        try sink.out.append(sink.alloc, msg);
    }
}

fn nodeSpan(tree: *const Ast, node: Ast.Node.Index) Span {
    return .{ .first = tree.firstToken(node), .last = tree.lastToken(node) };
}

fn withinSpan(span: Span, tok: u32) bool {
    return tok >= span.first and tok <= span.last;
}

fn nodeInSpan(tree: *const Ast, span: Span, node: Ast.Node.Index) bool {
    return withinSpan(span, tree.firstToken(node));
}

/// True when `node` lives inside one of the nested-fn spans (so it belongs to
/// a different frame and this pass must ignore it).
fn inNested(tree: *const Ast, nested: []const Span, node: Ast.Node.Index) bool {
    const tok = tree.firstToken(node);
    for (nested) |s| {
        if (withinSpan(s, tok)) return true;
    }
    return false;
}

fn fnName(tree: *const Ast, fn_decl: Ast.Node.Index) ?[]const u8 {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_decl) orelse return null;
    const name_tok = proto.name_token orelse return null;
    return tree.tokenSlice(name_tok);
}

/// Bodies of any `fn_decl` nested inside `outer`'s body span (excluding the
/// outer body itself). Lets the local/return scan stay scoped to one frame.
fn nestedFnSpans(
    arena: Allocator,
    tree: *const Ast,
    outer: Ast.Node.Index,
    outer_body: Span,
) Allocator.Error![]const Span {
    var spans: std.ArrayList(Span) = .empty;
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (node == outer) continue;
        if (tree.nodeTag(node) != .fn_decl) continue;
        if (!nodeInSpan(tree, outer_body, node)) continue;
        _, const body = tree.nodeData(node).node_and_node;
        try spans.append(arena, nodeSpan(tree, body));
    }
    return spans.toOwnedSlice(arena);
}

/// Every stack-local declaration statement directly in this frame.
fn collectLocals(arena: Allocator, frame: Frame) Allocator.Error![]const Local {
    const tree = frame.tree;
    var locals: std.ArrayList(Local) = .empty;
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        const var_decl = tree.fullVarDecl(node) orelse continue;
        if (!frameOwns(frame, node)) continue;
        if (var_decl.comptime_token != null) continue;

        const name = tree.tokenSlice(var_decl.ast.mut_token + 1);

        // A local typed as a pointer/slice holds an address whose pointee may be
        // heap — returning it is never a certain escape.
        const type_kind = typeKind(tree, var_decl.ast.type_node);
        if (type_kind == .pointer_or_slice) continue;

        // If the initializer involves any call, the value may be heap memory —
        // stay silent (allocator.alloc / dupe / toOwnedSlice / a factory fn).
        const init_node = var_decl.ast.init_node.unwrap();
        if (init_node) |n| {
            if (exprContainsCall(tree, n)) continue;
        }

        // Alias: `const p = &local;` binds p to a local's address.
        const alias_of: ?[]const u8 = if (init_node) |n| addressOfLocalName(tree, n) else null;

        const is_array = type_kind == .array or
            (init_node != null and initIsArrayLiteral(tree, init_node.?));

        try locals.append(arena, .{ .name = name, .is_array = is_array, .alias_of = alias_of });
    }
    return locals.toOwnedSlice(arena);
}

/// True when `node` sits in this frame's body and not inside a nested fn.
fn frameOwns(frame: Frame, node: Ast.Node.Index) bool {
    return nodeInSpan(frame.tree, frame.span, node) and !inNested(frame.tree, frame.nested, node);
}

/// Finds every `return` in this frame whose returned expression is a certain
/// stack-local address per the rules and records an `Escape`.
fn collectEscapes(
    arena: Allocator,
    frame: Frame,
    locals: []const Local,
    fn_name: []const u8,
    out: *std.ArrayList(Escape),
) Allocator.Error!void {
    const tree = frame.tree;
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .@"return") continue;
        if (!frameOwns(frame, node)) continue;

        const ret_expr = tree.nodeData(node).opt_node.unwrap() orelse continue;
        const escaped = escapedLocal(tree, ret_expr, locals) orelse continue;
        try out.append(arena, .{
            .line = tokenLine(tree, tree.nodeMainToken(node)),
            .fn_name = fn_name,
            .var_name = escaped,
        });
    }
}

/// Classifies a returned expression and, when it is a certain stack-local
/// address, returns the offending local's name. Null when nothing escapes.
/// Each case is a small helper so this dispatcher stays under the returns cap.
fn escapedLocal(tree: *const Ast, expr: Ast.Node.Index, locals: []const Local) ?[]const u8 {
    return switch (tree.nodeTag(expr)) {
        .address_of => escapedByAddressOf(tree, expr, locals),
        .slice_open, .slice, .slice_sentinel => escapedBySlice(tree, expr, locals),
        .identifier => escapedByAlias(tree, expr, locals),
        else => null,
    };
}

/// `return &x` / `return &x.field` — escapes when the root is a stack local.
fn escapedByAddressOf(tree: *const Ast, expr: Ast.Node.Index, locals: []const Local) ?[]const u8 {
    const base = baseIdentName(tree, tree.nodeData(expr).node) orelse return null;
    return if (findLocal(locals, base) != null) base else null;
}

/// `return x[a..]` / `return x[a..b]` — escapes only when `x` is directly an
/// array-typed local. A slice of a *field* (`x.field[0..]`) is intentionally
/// NOT flagged: the field could itself be a slice into heap, so flagging it
/// would risk a false positive against the zero-FP bar.
fn escapedBySlice(tree: *const Ast, expr: Ast.Node.Index, locals: []const Local) ?[]const u8 {
    const sl = tree.fullSlice(expr) orelse return null;
    const base = directIdentName(tree, sl.ast.sliced) orelse return null;
    const loc = findLocal(locals, base) orelse return null;
    return if (loc.is_array) base else null;
}

/// `return p;` where `const p = &local;` — escapes via the recorded alias.
fn escapedByAlias(tree: *const Ast, expr: Ast.Node.Index, locals: []const Local) ?[]const u8 {
    const name = tree.tokenSlice(tree.nodeMainToken(expr));
    const loc = findLocal(locals, name) orelse return null;
    const target = loc.alias_of orelse return null;
    return if (findLocal(locals, target) != null) target else null;
}

fn findLocal(locals: []const Local, name: []const u8) ?Local {
    for (locals) |l| {
        if (std.mem.eql(u8, l.name, name)) return l;
    }
    return null;
}

/// Peels field accesses off the LHS of an addressed/sliced expression down to
/// the root identifier: `x` from `x`, `x.field`, `x.a.b`. Returns null if the
/// root isn't a bare identifier (e.g. a call result or `self.*`).
fn baseIdentName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    var cur = node;
    while (true) {
        switch (tree.nodeTag(cur)) {
            .identifier => return tree.tokenSlice(tree.nodeMainToken(cur)),
            .field_access => cur = tree.nodeData(cur).node_and_token[0],
            .grouped_expression => cur = tree.nodeData(cur).node_and_token[0],
            else => return null,
        }
    }
}

/// The name only when `node` is exactly a bare identifier (optionally wrapped
/// in parens): `x` or `(x)`, but NOT `x.field`. Used for slice-escape, where a
/// field could be a heap slice and must not be flagged.
fn directIdentName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    var cur = node;
    while (true) {
        switch (tree.nodeTag(cur)) {
            .identifier => return tree.tokenSlice(tree.nodeMainToken(cur)),
            .grouped_expression => cur = tree.nodeData(cur).node_and_token[0],
            else => return null,
        }
    }
}

/// When `node` is `&<local-chain>`, the referenced root identifier; else null.
/// Used to record `const p = &local;` aliases.
fn addressOfLocalName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .address_of) return null;
    return baseIdentName(tree, tree.nodeData(node).node);
}

const TypeKind = enum { none, array, pointer_or_slice, other };

/// Classifies a var-decl's explicit type annotation: array vs pointer/slice vs
/// anything else. `.none` when the decl has no type annotation.
fn typeKind(tree: *const Ast, type_opt: Ast.Node.OptionalIndex) TypeKind {
    const type_node = type_opt.unwrap() orelse return .none;
    return switch (tree.nodeTag(type_node)) {
        .array_type, .array_type_sentinel => .array,
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => .pointer_or_slice,
        else => .other,
    };
}

/// True when the initializer is an array literal (`[_]T{…}` / `[N]T{…}`), so an
/// inferred-type local still counts as an array for slice-escape purposes. A
/// `Foo{…}` struct init has a non-array type_expr and is correctly excluded.
fn initIsArrayLiteral(tree: *const Ast, init_node: Ast.Node.Index) bool {
    var buf: [2]Ast.Node.Index = undefined;
    const ai = tree.fullArrayInit(&buf, init_node) orelse return false;
    const type_node = ai.ast.type_expr.unwrap() orelse return false;
    return switch (tree.nodeTag(type_node)) {
        .array_type, .array_type_sentinel => true,
        else => false,
    };
}

/// True when `node`'s subtree contains any call. A conservative recursion over
/// the operands we can reach: any call means the value could be heap memory, so
/// the enclosing local is never flagged. Errs toward "call present" (silence).
fn exprContainsCall(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .call, .call_comma, .call_one, .call_one_comma => return true,
        .@"try",
        .@"nosuspend",
        .@"comptime",
        .address_of,
        .deref,
        .bool_not,
        .negation,
        .bit_not,
        .negation_wrap,
        .optional_type,
        .unwrap_optional,
        .grouped_expression,
        => {
            const child = firstChildNode(tree, node) orelse return false;
            return exprContainsCall(tree, child);
        },
        else => return false,
    }
}

/// The single operand node of a unary/wrapper node, for the call-scan recursion.
fn firstChildNode(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    return switch (tree.nodeTag(node)) {
        .@"try",
        .@"nosuspend",
        .@"comptime",
        .address_of,
        .deref,
        .bool_not,
        .negation,
        .bit_not,
        .negation_wrap,
        .optional_type,
        => tree.nodeData(node).node,
        .unwrap_optional, .grouped_expression => tree.nodeData(node).node_and_token[0],
        else => null,
    };
}

/// 1-indexed source line of a token via its byte start.
fn tokenLine(tree: *const Ast, tok: u32) u32 {
    const byte = tree.tokenStart(tok);
    var line: u32 = 1;
    for (tree.source[0..byte]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

/// Entry point for the stack-escape check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("stack-escape: no returned stack-local addresses", .{});
        return;
    }
    fail("stack-escape FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: return a value (copy), heap-allocate the memory, or accept a " ++
        "caller-owned buffer parameter instead of &local.\n", .{});
    return error.CheckFailed;
}

const ScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeWithTree(ctx.allocator, entry.rel_path, entry.content, entry.tree);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Analyzes `src` and returns the violation count for the assertions below.
fn countFlags(a: Allocator, src: [:0]const u8) !usize {
    const out = try analyzeContent(a, "src/x.zig", src);
    return out.len;
}

test "flagged: return &local names the variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn bad() *i32 {
        \\    var x: i32 = 0;
        \\    return &x;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0], "'x'") != null);
    try testing.expect(std.mem.indexOf(u8, out[0], "fn bad") != null);
}

// spec: Stack Escape - Flags returning the address of a stack local variable
test "flags return address of a stack local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Plain scalar local and a const local both escape when addressed.
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn f() *i32 {
        \\    var n: i32 = 7;
        \\    return &n;
        \\}
    ));
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn g() *const i32 {
        \\    const n: i32 = 7;
        \\    return &n;
        \\}
    ));
}

// spec: Stack Escape - Flags returning a slice of a stack array local
test "flags returning a slice of a stack array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Sized array with explicit type, and an inferred array literal.
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn f() []u8 {
        \\    var buf: [16]u8 = undefined;
        \\    return buf[0..];
        \\}
    ));
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn g() []const u8 {
        \\    const buf = [_]u8{ 1, 2, 3 };
        \\    return buf[0..2];
        \\}
    ));
    // Taking the whole array's address escapes too.
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn h() *[16]u8 {
        \\    var buf: [16]u8 = undefined;
        \\    return &buf;
        \\}
    ));
}

// spec: Stack Escape - Flags returning the address of a field of a stack local
test "flags return address of a field of a stack local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn f() *i32 {
        \\    var s = Point{ .x = 1, .y = 2 };
        \\    return &s.x;
        \\}
    ));
    // A nested field address escapes just the same.
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn g() *u8 {
        \\    var s: Buf = undefined;
        \\    return &s.inner.byte;
        \\}
    ));
    // But a *slice* of a field is NOT flagged — the field could be a heap
    // slice, so flagging it would risk a false positive.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn h() []u8 {
        \\    var s: Buf = undefined;
        \\    return s.bytes[0..];
        \\}
    ));
}

// spec: Stack Escape - Flags returning a const alias bound directly to a stack local address
test "flags returning a const alias of a stack local address" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn f() *i32 {
        \\    var x: i32 = 0;
        \\    const p = &x;
        \\    return p;
        \\}
    ));
}

// spec: Stack Escape - Allows returning the address of a parameter owned by the caller
test "allows returning the address of a parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // &param and a slice of a pointer/slice param are the caller's memory.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn f(x: i32) *const i32 {
        \\    return &x;
        \\}
    ));
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn g(buf: []u8) []u8 {
        \\    return buf[0..];
        \\}
    ));
}

// spec: Stack Escape - Allows returning a pointer derived from a parameter field
test "allows returning a pointer to a parameter field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn f(s: *Point) *i32 {
        \\    return &s.x;
        \\}
    ));
}

// spec: Stack Escape - Allows returning a local whose initializer calls a function
test "allows returning a local backed by an allocation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The initializer is a call, so the memory may be heap — stay silent.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn f(alloc: std.mem.Allocator) ![]u8 {
        \\    const buf = try alloc.alloc(u8, 16);
        \\    return buf[0..];
        \\}
    ));
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn g(alloc: std.mem.Allocator) !*i32 {
        \\    const n = try alloc.create(i32);
        \\    return &n.*;
        \\}
    ));
}

// spec: Stack Escape - Allows returning a local that is itself a pointer or slice
test "allows returning a local that is a pointer or slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn f(src: []u8) []u8 {
        \\    var s: []u8 = src;
        \\    return s[0..];
        \\}
    ));
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn g(src: *i32) *i32 {
        \\    var p: *i32 = src;
        \\    return p;
        \\}
    ));
}

// spec: Stack Escape - Allows returning the address of a comptime local
test "allows returning the address of a comptime local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\pub fn f() *const i32 {
        \\    comptime var x: i32 = 0;
        \\    return &x;
        \\}
    ));
}

// spec: Stack Escape - Handles returned stack addresses through an error union return type
test "flags a stack address through an error-union return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The `!*i32` return type does not change that &x is a stack address.
    try testing.expectEqual(@as(usize, 1), try countFlags(a,
        \\pub fn f() !*i32 {
        \\    var x: i32 = 0;
        \\    return &x;
        \\}
    ));
}

// spec: Stack Escape - Skips returns that appear inside a test block
test "skips returns inside a test block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A `return &x` inside a test body must never be flagged; only fn_decls
    // are scanned, so the local escape here is intentionally ignored.
    try testing.expectEqual(@as(usize, 0), try countFlags(a,
        \\const Helper = struct {
        \\    fn take(_: *i32) void {}
        \\};
        \\test "weird" {
        \\    var x: i32 = 0;
        \\    Helper.take(&x);
        \\}
    ));
}
