//! Resolved direct calls and function bodies for operation-contract analysis.
//! Dynamic receivers remain explicit external calls; ambiguous symbols are
//! never guessed. The graph follows same-file and imported constant aliases.
const std = @import("std");
const source_index = @import("../ast/index.zig");
const decls = @import("../ast/decls.zig");
const text = @import("../text.zig");
const model = @import("model.zig");
const A = std.mem.Allocator;
const Ast = std.zig.Ast;

/// A real AST call, optionally carrying its catch handler and captured error.
pub const Call = struct {
    node: Ast.Node.Index,
    name: []const u8,
    target: ?usize = null,
    line: u32,
    offset: usize,
    arguments: []const u8,
    handler: ?Handler = null,
};

/// The catch expression and its optional captured error identifier.
pub const Handler = struct { source: []const u8, capture: []const u8 = "" };

/// A source declaration; body/header slices borrow the shared source index.
pub const Function = struct {
    file: []const u8,
    qualified: []const u8,
    return_type: []const u8,
    line: u32,
    start: usize,
    end: usize,
    calls: std.ArrayList(Call) = .empty,
};

/// Reusable run-scoped direct-call graph. All allocations belong to the arena.
pub const Graph = struct {
    functions: []Function,
    aliases: std.StringHashMapUnmanaged([]const u8),
    symbols: std.StringHashMapUnmanaged(usize),

    fn canonical(self: *const Graph, name: []const u8) []const u8 {
        var cur = name;
        for (0..32) |_| {
            if (self.symbols.contains(cur)) return cur;
            cur = self.aliases.get(cur) orelse return cur;
        }
        return "<alias-cycle>";
    }

    /// Resolve a constant alias chain; cycles and ambiguous functions fail closed.
    pub fn resolve(self: *const Graph, name: []const u8) ?usize {
        var cur = name;
        for (0..32) |_| {
            if (self.symbols.get(cur)) |n| return if (n < self.functions.len) n else null;
            cur = self.aliases.get(cur) orelse return null;
        }
        return null;
    }

    /// Compute the least fixed point of functions reaching declared operations.
    /// Recursion is finite: each function becomes marked at most once.
    pub fn effects(self: *const Graph, a: A, operations: []const []const u8) A.Error![]bool {
        const marked = try a.alloc(bool, self.functions.len);
        @memset(marked, false);
        var changed = true;
        while (changed) {
            changed = false;
            for (self.functions, 0..) |f, i| {
                if (marked[i]) continue;
                for (f.calls.items) |call| {
                    if (!model.matches(operations, call.name) and !(if (call.target) |t| marked[t] else false)) continue;
                    marked[i] = true;
                    changed = true;
                    break;
                }
            }
        }
        return marked;
    }
};

fn slice(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const last = tree.lastToken(node);
    return tree.source[tree.tokenStart(tree.firstToken(node)) .. tree.tokenStart(last) + tree.tokenSlice(last).len];
}

fn key(a: A, file: []const u8, name: []const u8) A.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}::{s}", .{ file, name });
}

fn expressionName(a: A, file: []const u8, expr: []const u8, aliases: *const std.StringHashMapUnmanaged([]const u8)) A.Error![]const u8 {
    var tokens = std.zig.Tokenizer.init(try a.dupeSentinel(u8, expr, 0));
    var parts: std.ArrayList([]const u8) = .empty;
    var complex = false;
    while (true) {
        const t = tokens.next();
        if (t.tag == .eof) break;
        if (t.tag == .identifier) try parts.append(a, expr[t.loc.start..t.loc.end]) else if (t.tag != .period) {
            complex = true;
        }
    }
    if (parts.items.len == 0) return "<dynamic>";
    const leaf = parts.items[parts.items.len - 1];
    if (complex) return std.fmt.allocPrint(a, "external.{s}", .{leaf});
    if (parts.items.len == 1) return key(a, file, leaf);
    const first = try key(a, file, parts.items[0]);
    if (aliases.get(first)) |module| {
        if (std.mem.startsWith(u8, module, "module:")) {
            const tail = try std.mem.join(a, ".", parts.items[1..]);
            return key(a, module[7..], tail);
        }
    }
    return std.fmt.allocPrint(a, "external.{s}", .{leaf});
}

fn importTarget(a: A, file: []const u8, expr: []const u8) A.Error!?[]const u8 {
    if (!std.mem.startsWith(u8, expr, "@import(")) return null;
    const quote = std.mem.indexOfScalar(u8, expr, '"') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, expr, quote + 1, '"') orelse return null;
    const path = expr[quote + 1 .. end];
    if (!std.mem.endsWith(u8, path, ".zig")) return null;
    const resolved = try std.fs.path.resolve(a, &.{ "/", std.fs.path.dirname(file) orelse "", path });
    const close = std.mem.indexOfScalarPos(u8, expr, end, ')') orelse return null;
    if (close + 1 < expr.len and expr[close + 1] == '.') return try key(a, resolved[1..], expr[close + 2 ..]);
    return try std.fmt.allocPrint(a, "module:{s}", .{resolved[1..]});
}

fn collectAliases(a: A, entry: *const source_index.Entry, aliases: *std.StringHashMapUnmanaged([]const u8)) A.Error!void {
    const tree = &entry.tree;
    if (tree.errors.len > 0) return;
    // Two passes resolve imports before forwarded function constants regardless
    // of declaration order. Further constant aliases are followed by Graph.resolve.
    for (0..2) |_| for (try decls.collectDecls(a, tree)) |node| {
        const v = tree.fullVarDecl(node) orelse continue;
        if (tree.tokenTag(v.ast.mut_token) != .keyword_const) continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        const name = tree.tokenSlice(v.ast.mut_token + 1);
        const expr = slice(tree, init);
        const target = try importTarget(a, entry.rel_path, expr) orelse try expressionName(a, entry.rel_path, expr, aliases);
        try aliases.put(a, try key(a, entry.rel_path, name), target);
    };
}

fn byStart(_: void, lhs: Function, rhs: Function) bool {
    return lhs.start < rhs.start;
}

fn owner(functions: []const Function, offset: usize) ?usize {
    var lo: usize = 0;
    var hi = functions.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (functions[mid].start <= offset) lo = mid + 1 else hi = mid;
    }
    if (lo == 0 or offset >= functions[lo - 1].end) return null;
    return lo - 1;
}

fn collectCalls(a: A, entry: *const source_index.Entry, functions: []Function, aliases: *const std.StringHashMapUnmanaged([]const u8)) A.Error!void {
    const tree = &entry.tree;
    for (0..tree.nodes.len) |n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        var buf: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buf, node) orelse continue;
        const offset = tree.tokenStart(tree.firstToken(node));
        const at = owner(functions, offset) orelse continue;
        const expr = slice(tree, call.ast.fn_expr);
        try functions[at].calls.append(a, .{
            .node = node,
            .name = try expressionName(a, entry.rel_path, expr, aliases),
            .line = text.lineOf(tree.source, offset),
            .offset = offset,
            .arguments = slice(tree, node),
        });
    }
    for (0..tree.nodes.len) |n| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        if (tree.nodeTag(node) != .@"catch") continue;
        const raw_lhs, const rhs = tree.nodeData(node).node_and_node;
        var lhs = raw_lhs;
        while (tree.nodeTag(lhs) == .grouped_expression) lhs = tree.nodeData(lhs).node_and_token[0];
        const at = owner(functions, tree.tokenStart(tree.firstToken(node))) orelse continue;
        for (functions[at].calls.items) |*call| {
            if (call.node != lhs) continue;
            call.handler = .{ .source = slice(tree, rhs) };
            const t = tree.nodeMainToken(node);
            if (tree.tokens.items(.tag)[t + 1] == .pipe) call.handler.?.capture = tree.tokenSlice(t + 2);
        }
    }
}

/// Build direct calls once from the already-parsed source index.
pub fn build(a: A, source: *const source_index.Index) A.Error!Graph {
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (source.files) |*entry| try collectAliases(a, entry, &aliases);
    var functions: std.ArrayList(Function) = .empty;
    for (source.files) |*entry| {
        if (entry.tree.errors.len > 0) continue;
        const begin = functions.items.len;
        const tree = &entry.tree;
        for (try decls.collectDecls(a, tree)) |node| {
            if (tree.nodeTag(node) != .fn_decl) continue;
            var buf: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buf, node) orelse continue;
            const name = tree.tokenSlice(proto.name_token orelse continue);
            const body = tree.nodeData(node).node_and_node[1];
            const start = tree.tokenStart(tree.firstToken(body));
            const end = tree.tokenStart(tree.lastToken(body)) + tree.tokenSlice(tree.lastToken(body)).len;
            var ret: []const u8 = "";
            if (proto.ast.return_type.unwrap()) |ret_node| {
                const first = tree.firstToken(ret_node);
                ret = if (first > 0 and tree.tokenTag(first - 1) == .bang) "!inferred" else slice(tree, ret_node);
            }
            try functions.append(a, .{ .file = entry.rel_path, .qualified = try key(a, entry.rel_path, name), .return_type = ret, .line = text.lineOf(tree.source, tree.tokenStart(proto.ast.fn_token)), .start = start, .end = end });
        }
        std.mem.sort(Function, functions.items[begin..], {}, byStart);
        try collectCalls(a, entry, functions.items[begin..], &aliases);
    }
    var symbols: std.StringHashMapUnmanaged(usize) = .empty;
    for (functions.items, 0..) |f, i| {
        const slot = try symbols.getOrPut(a, f.qualified);
        slot.value_ptr.* = if (slot.found_existing) std.math.maxInt(usize) else i;
    }
    var graph: Graph = .{ .functions = try functions.toOwnedSlice(a), .aliases = aliases, .symbols = symbols };
    for (graph.functions) |*f| for (f.calls.items) |*call| {
        call.name = graph.canonical(call.name);
        call.target = graph.resolve(call.name);
        if (call.target) |t| call.name = graph.functions[t].qualified;
    };
    return graph;
}
