//! Folded numeric values of Zig const initializers — the one arithmetic
//! `divergent-const` and `shadowed-const` both compare by.
//!
//! Both checks ask "is this the same number?" about text that spells it
//! differently: `16 << 20`, `16 * 1024 * 1024` and `16_777_216` are one value,
//! and `1_000_000` equals `1_000_000.0`. Comparing source text instead would
//! make every check's answer depend on how the author typed it, so the compare
//! runs on a folded `Value` and an expression that does not fold to a number is
//! skipped entirely rather than compared as prose.
//!
//! This module started inside `divergent_const.zig` and moved here when
//! `shadowed_const.zig` needed the same fold. Two copies of a numeric fold is
//! precisely the debt those checks exist to find, so the extraction is not
//! tidiness — a divergence between the two folds would make one check silent
//! about a value the other reports.
//!
//! The unit-segment table lives here for the same reason: `divergent-const`
//! groups unit-suffixed names in its default mode and `shadowed-const`'s auto
//! mode sweeps the same population, so a unit added for one is added for both.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// Recursion cap while folding an initializer. A literal expression is a few
/// levels deep in practice; anything past this is treated as unfoldable rather
/// than risking the stack on pathological input.
const max_fold_depth = 32;

/// Longest numeric literal folded. Longer text is treated as unfoldable, which
/// keeps the underscore-stripping buffer fixed-size.
const max_number_len = 64;

/// A const initializer folded to a number. Integers stay exact (i128 holds
/// every `u64`/`i64` literal and the products this folds), floats carry the
/// literal's own f64 value.
pub const Value = union(enum) {
    int: i128,
    float: f64,
};

/// True when two folded values are the same number, across representations:
/// `1_000_000` equals `1_000_000.0`, and `16 << 20` equals `16777216`.
pub fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .int => |x| switch (b) {
            .int => |y| x == y,
            .float => |y| intEqualsFloat(x, y),
        },
        .float => |x| switch (b) {
            .int => |y| intEqualsFloat(y, x),
            .float => |y| x == y,
        },
    };
}

/// True when an integer and a float denote the same number. A non-integral or
/// non-finite float can never equal an integer, so those are rejected before
/// the widening compare.
fn intEqualsFloat(i: i128, f: f64) bool {
    if (!std.math.isFinite(f)) return false;
    if (@floor(f) != f) return false;
    const widened: f64 = @floatFromInt(i);
    return widened == f;
}

/// Renders a folded value the way its source spelled the number: an integer in
/// decimal, a float in Zig's shortest round-trip form.
pub fn renderValue(allocator: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .int => |x| std.fmt.allocPrint(allocator, "{d}", .{x}),
        .float => |x| std.fmt.allocPrint(allocator, "{d}", .{x}),
    };
}

/// Folds one numeric literal's source text, or null when it is not a plain
/// number this compares (a `big_int` past u64, a malformed literal, or a
/// spelling longer than `max_number_len`).
///
/// The leading-digit guard is load-bearing, not defensive: `parseNumberLiteral`
/// ASSERTS its input starts with a digit and panics otherwise, which is fine
/// for a token the tokenizer already classified and fatal for a spelling that
/// came out of a config file.
fn foldNumber(text: []const u8) ?Value {
    if (text.len == 0 or text.len > max_number_len) return null;
    if (!std.ascii.isDigit(text[0])) return null;
    return switch (std.zig.parseNumberLiteral(text)) {
        .int => |v| .{ .int = @as(i128, v) },
        .float => foldFloat(text),
        .big_int, .failure => null,
    };
}

/// Folds a numeric spelling that came from CONFIG rather than from a parse
/// tree, where a leading sign is part of the text (`"-1"`) instead of a
/// separate negation node. Everything else routes through the same
/// `foldNumber`, so a configured value and a source literal can never fold by
/// different rules.
pub fn foldSpelled(text: []const u8) ?Value {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '-') return negate(foldNumber(trimmed[1..]) orelse return null);
    if (trimmed[0] == '+') return foldNumber(trimmed[1..]);
    return foldNumber(trimmed);
}

/// Negates a folded value, keeping it in its own arm.
fn negate(v: Value) Value {
    return switch (v) {
        .int => |x| .{ .int = -x },
        .float => |x| .{ .float = -x },
    };
}

/// Parses a float literal, stripping the `_` digit separators `parseFloat` does
/// not accept. Hex floats (`0x1p4`) pass through unchanged.
fn foldFloat(text: []const u8) ?Value {
    var buf: [max_number_len]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        buf[len] = c;
        len += 1;
    }
    const parsed = std.fmt.parseFloat(f64, buf[0..len]) catch return null;
    return .{ .float = parsed };
}

/// Applies one folded binary operator, or null when the operands cannot carry
/// it: a shift needs two integers, and any overflow makes the expression
/// unfoldable rather than silently wrapping.
fn applyBinary(tag: Ast.Node.Tag, a: Value, b: Value) ?Value {
    if (tag == .shl or tag == .shr) return applyShift(tag, a, b);
    if (a == .int and b == .int) return applyIntBinary(tag, a.int, b.int);
    return applyFloatBinary(tag, toFloat(a), toFloat(b));
}

/// Widens a folded value to f64 for a mixed-type arithmetic fold.
fn toFloat(v: Value) f64 {
    return switch (v) {
        .int => |x| @floatFromInt(x),
        .float => |x| x,
    };
}

/// Folds `<<` / `>>` over two integers; a float operand, a negative or
/// oversized shift, or a shift that would drop bits yields null.
fn applyShift(tag: Ast.Node.Tag, a: Value, b: Value) ?Value {
    if (a != .int or b != .int) return null;
    const amount = std.math.cast(u7, b.int) orelse return null;
    const shifted = switch (tag) {
        .shl => std.math.shlExact(i128, a.int, amount) catch return null,
        else => a.int >> amount,
    };
    return .{ .int = shifted };
}

/// Folds `+` / `-` / `*` over two integers, refusing an overflowing product or
/// sum rather than reporting a wrapped value as the constant's meaning.
fn applyIntBinary(tag: Ast.Node.Tag, a: i128, b: i128) ?Value {
    const out = switch (tag) {
        .add => std.math.add(i128, a, b) catch return null,
        .sub => std.math.sub(i128, a, b) catch return null,
        .mul => std.math.mul(i128, a, b) catch return null,
        else => return null,
    };
    return .{ .int = out };
}

/// Folds `+` / `-` / `*` once either operand is a float.
fn applyFloatBinary(tag: Ast.Node.Tag, a: f64, b: f64) ?Value {
    return switch (tag) {
        .add => .{ .float = a + b },
        .sub => .{ .float = a - b },
        .mul => .{ .float = a * b },
        else => null,
    };
}

/// Folds an initializer expression to a number, or null when any part of it is
/// not a literal, a parenthesized group, a negation, or one of `+ - * << >>`.
/// Division is deliberately absent: `1 / 2` means 0 between integers and 0.5
/// between floats, and this fold has no type information to tell them apart.
pub fn foldNode(tree: *const Ast, node: Ast.Node.Index, depth: u8) ?Value {
    if (depth > max_fold_depth) return null;
    return switch (tree.nodeTag(node)) {
        .number_literal => foldNumber(tree.tokenSlice(tree.nodeMainToken(node))),
        .grouped_expression => foldNode(tree, tree.nodeData(node).node_and_token[0], depth + 1),
        .negation => foldNegation(tree, node, depth),
        .add, .sub, .mul, .shl, .shr => foldBinary(tree, node, depth),
        else => null,
    };
}

/// Folds `-expr` by negating its folded operand.
fn foldNegation(tree: *const Ast, node: Ast.Node.Index, depth: u8) ?Value {
    const inner = foldNode(tree, tree.nodeData(node).node, depth + 1) orelse return null;
    return negate(inner);
}

/// Folds a binary expression by folding both sides first.
fn foldBinary(tree: *const Ast, node: Ast.Node.Index, depth: u8) ?Value {
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    const a = foldNode(tree, lhs, depth + 1) orelse return null;
    const b = foldNode(tree, rhs, depth + 1) orelse return null;
    return applyBinary(tree.nodeTag(node), a, b);
}

// ── Unit-suffixed names ─────────────────────────────────────────────────

/// Unit segments recognised in the unit-suffixed name population — the trailing
/// `_`-separated word of a name like `silk_stroke_mm` or `max_footprint_bytes`.
/// Single-letter units (`_a`, `_v`, `_s`, `_w`) are deliberately absent:
/// `node_a` / `point_b` pair naming is far more common in real code than
/// amperes, and a name that generic belongs to a widened mode rather than to
/// the quiet default.
const unit_segments = [_][]const u8{
    "mm",  "cm",   "um",  "nm",  "mil",   "mils",
    "ms",  "us",   "ns",  "sec", "secs",  "seconds",
    "hz",  "khz",  "mhz", "ghz", "bytes", "byte",
    "kb",  "mb",   "gb",  "kib", "mib",   "gib",
    "mv",  "uv",   "kv",  "ma",  "ua",    "mw",
    "ohm", "ohms", "deg", "rad", "pct",   "percent",
    "ppm", "pf",   "nf",  "uf",  "nh",    "uh",
    "px",  "dpi",
};

/// The trailing `_`-separated segment of a name, or null when the name carries
/// no `_` at all (`eps`, `margin`) — a name with no segments cannot claim a
/// unit.
fn trailingSegment(name: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const tail = name[at + 1 ..];
    return if (tail.len == 0) null else tail;
}

/// True when a name ends in a recognised unit segment.
pub fn hasUnitSegment(name: []const u8) bool {
    const tail = trailingSegment(name) orelse return false;
    for (unit_segments) |unit| {
        if (std.ascii.eqlIgnoreCase(tail, unit)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The parsed first file-scope declaration's initializer node, so a test can
/// hand `foldNode` a real initializer while stating a whole file.
fn firstInit(tree: *const Ast) Ast.Node.Index {
    return tree.fullVarDecl(tree.rootDecls()[0]).?.ast.init_node.unwrap().?;
}

// spec: Const Folding - Folds one literal initializer expression to one comparable value

test "foldNode folds every spelling of one number to one value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var shifted = try Ast.parse(a, "const cap_bytes = 16 << 20;\n", .{});
    var spelled = try Ast.parse(a, "const cap_bytes = 16_777_216;\n", .{});
    const from_shift = foldNode(&shifted, firstInit(&shifted), 0).?;
    const from_digits = foldNode(&spelled, firstInit(&spelled), 0).?;
    try testing.expect(valuesEqual(from_shift, from_digits));
    // The rendered form is the number, not the spelling that produced it.
    try testing.expectEqualStrings("16777216", try renderValue(a, from_shift));
    // An expression with no type information to resolve it stays unfoldable.
    var divided = try Ast.parse(a, "const half = 1 / 2;\n", .{});
    try testing.expect(foldNode(&divided, firstInit(&divided), 0) == null);
}

// spec: Const Folding - Folds a signed numeric spelling supplied by config

test "foldSpelled reads a config-declared number including its sign" {
    // Config carries the sign in the text; a parse tree carries it as a node.
    try testing.expect(valuesEqual(foldSpelled("-1").?, .{ .int = -1 }));
    try testing.expect(valuesEqual(foldSpelled(" 0.5 ").?, .{ .float = 0.5 }));
    try testing.expect(valuesEqual(foldSpelled("+2").?, .{ .int = 2 }));
    // Prose is not a number, and neither is a spelling with nothing after its
    // sign — both reach `parseNumberLiteral`, which panics on a non-digit, so
    // rejecting them here is what keeps a typo in guardian.toml from aborting
    // the gate.
    try testing.expect(foldSpelled("half") == null);
    try testing.expect(foldSpelled("-") == null);
    try testing.expect(foldSpelled("") == null);
}

// spec: Const Folding - Recognises a name whose trailing segment is a unit

test "hasUnitSegment reads the trailing segment of a name" {
    try testing.expect(hasUnitSegment("silk_stroke_mm"));
    try testing.expect(hasUnitSegment("max_footprint_bytes"));
    // No trailing segment at all, and a segment that is not a unit.
    try testing.expect(!hasUnitSegment("eps"));
    try testing.expect(!hasUnitSegment("default_scale"));
}
