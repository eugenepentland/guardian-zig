//! divergent-const: one file-scope const NAME holding DIFFERENT values in two
//! or more files.
//!
//! The motivating measurement (eda, 2026-08): 24 same-name file-scope constants
//! disagreed across files — `silk_stroke_mm` 0.12 in the Gerber writer and 0.15
//! in the `.kicad_mod` writer (two fabs' worth of silkscreen from one board),
//! `max_footprint_bytes` 1 MiB in four readers and 256 KiB in two (a footprint
//! that loads in the editor and fails in the preview), `max_board_bytes` 64 vs
//! 48 MiB, `default_tolerance_mm` 0.2 vs 0.5.
//!
//! Guardian manufactures some of this debt itself: `magic-number` pushes a bare
//! literal into a named const, and nothing then looks across files, so the
//! second copy is written by hand and drifts. This check is the missing half.
//!
//! **The polarity is the opposite of `repeated-string-literal`'s cross-file
//! rule.** There, same name + same value is the finding (two copies of one
//! spelling). Here, same name + same value is the HARMLESS case — annoying, not
//! dangerous — and same name + DIFFERENT value is the risk, because two call
//! sites that read as one fact do not behave as one.
//!
//! Comparison is on the FOLDED value, not the source text: `16 << 20`,
//! `16 * 1024 * 1024` and `16_777_216` are one value, and `1_000_000` equals
//! `1_000_000.0`. An initializer that does not fold to a number (a call, another
//! identifier, a struct literal) is skipped entirely rather than compared as
//! text.
//!
//! Default `mode = "units"` keeps it near-silent: only a const whose name ends
//! in a unit segment (`_mm`, `_bytes`, `_ms`, `_hz`, …) is grouped, because a
//! physical quantity is where a silent disagreement actually ships. `mode =
//! "all"` widens it to every name, and `ignore_names` is the escape hatch for
//! the generic ones (`eps`, `margin`) that legitimately differ per module.
//!
//! `/// mirror-of: <path>.zig.<name>` turns a deliberate copy into a CHECKED
//! one: the annotated const is exempt from the divergence rule and instead must
//! equal the value it names. That rule ignores mode and `ignore_names` — it is
//! an explicit claim by the author, so it is always verified.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const ast_decls = @import("../ast/decls.zig");
const config = @import("../config.zig");
const LineCursor = @import("../text.zig").LineCursor;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const check_name = "divergent-const";

/// Marker introducing a checked-mirror annotation inside a `///` doc comment.
const mirror_marker = "mirror-of:";

/// The `<file>.zig.` infix a mirror referent must carry, so the path half and
/// the symbol half can be split without resolving anything.
const zig_infix = ".zig.";

/// How many declaration sites one violation names before it elides the rest.
/// The count stays exact in the message and in `metric`.
const max_reported_sites = 6;

/// Recursion cap while folding an initializer. A literal expression is a few
/// levels deep in practice; anything past this is treated as unfoldable rather
/// than risking the stack on pathological input.
const max_fold_depth = 32;

/// Longest numeric literal folded. Longer text is treated as unfoldable, which
/// keeps the underscore-stripping buffer fixed-size.
const max_number_len = 64;

const fix_hint = "give the two files one const — import it from the module that owns the " ++
    "fact — or, if the copy is deliberate, annotate it `/// mirror-of: <path>.zig.<name>`.";

// ── Folded values ───────────────────────────────────────────────────────

/// A const initializer folded to a number. Integers stay exact (i128 holds
/// every `u64`/`i64` literal and the products this folds), floats carry the
/// literal's own f64 value.
const Value = union(enum) {
    int: i128,
    float: f64,
};

/// True when two folded values are the same number, across representations:
/// `1_000_000` equals `1_000_000.0`, and `16 << 20` equals `16777216`.
fn valuesEqual(a: Value, b: Value) bool {
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
fn renderValue(allocator: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .int => |x| std.fmt.allocPrint(allocator, "{d}", .{x}),
        .float => |x| std.fmt.allocPrint(allocator, "{d}", .{x}),
    };
}

/// Folds one numeric literal's source text, or null when it is not a plain
/// number this check compares (a `big_int` past u64, a malformed literal, or a
/// spelling longer than `max_number_len`).
fn foldNumber(text: []const u8) ?Value {
    if (text.len > max_number_len) return null;
    return switch (std.zig.parseNumberLiteral(text)) {
        .int => |v| .{ .int = @as(i128, v) },
        .float => foldFloat(text),
        .big_int, .failure => null,
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
fn foldNode(tree: *const Ast, node: Ast.Node.Index, depth: u8) ?Value {
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
    return switch (inner) {
        .int => |x| .{ .int = -x },
        .float => |x| .{ .float = -x },
    };
}

/// Folds a binary expression by folding both sides first.
fn foldBinary(tree: *const Ast, node: Ast.Node.Index, depth: u8) ?Value {
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    const a = foldNode(tree, lhs, depth + 1) orelse return null;
    const b = foldNode(tree, rhs, depth + 1) orelse return null;
    return applyBinary(tree.nodeTag(node), a, b);
}

// ── Declaration collection ──────────────────────────────────────────────

/// One file-scope numeric const: where it is declared, what it folds to, and
/// the mirror referent its doc comment claims (null for the ordinary case).
const Decl = struct {
    file: []const u8,
    name: []const u8,
    line: u32,
    value: Value,
    mirror: ?[]const u8,
};

/// Collects every file-scope `const NAME = <numeric literal expr>;` in one
/// parsed file. Only `rootDecls` are read: a const nested inside a container is
/// namespaced by that container, so two structs holding the same name with
/// different values is normal, and a const inside a function body is local by
/// construction — which is exactly where harmless one-off numbers live.
fn collectFile(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    out: *std.ArrayList(Decl),
) Allocator.Error!void {
    const tree = &entry.tree;
    // rootDecls are in source order, so one forward-only cursor covers the file
    // instead of re-counting newlines from byte 0 per declaration.
    var cursor: LineCursor = .{};
    for (tree.rootDecls()) |node| {
        const var_decl = tree.fullVarDecl(node) orelse continue;
        if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const value = foldNode(tree, init_node, 0) orelse continue;
        const doc = try ast_decls.precedingDocText(allocator, tree, node);
        try out.append(allocator, .{
            .file = entry.rel_path,
            .name = tree.tokenSlice(var_decl.ast.mut_token + 1),
            .line = cursor.at(entry.content, tree.tokenStart(var_decl.ast.mut_token)),
            .value = value,
            .mirror = if (doc) |text| mirrorReferent(text) else null,
        });
    }
}

/// The referent text of a `mirror-of:` doc annotation — everything after the
/// marker up to the end of that doc line — or null when the doc makes no such
/// claim.
fn mirrorReferent(doc: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, doc, mirror_marker) orelse return null;
    const rest = doc[at + mirror_marker.len ..];
    const line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
    const text = std.mem.trim(u8, line, &std.ascii.whitespace);
    return if (text.len == 0) null else text;
}

/// Splits a mirror referent into its file path and symbol name at the last
/// `.zig.`, or null when it is not spelled `<path>.zig.<name>`.
fn splitReferent(text: []const u8) ?struct { []const u8, []const u8 } {
    const at = std.mem.lastIndexOf(u8, text, zig_infix) orelse return null;
    const path = text[0 .. at + zig_infix.len - 1];
    const symbol = text[at + zig_infix.len ..];
    if (symbol.len == 0) return null;
    return .{ path, symbol };
}

/// The declaration a mirror referent names, matched on the symbol plus a path
/// that is either the indexed path itself or its tail — so `limits.zig.max` and
/// `src/board/limits.zig.max` both resolve.
fn findReferent(decls: []const Decl, path: []const u8, symbol: []const u8) ?Decl {
    for (decls) |d| {
        if (!std.mem.eql(u8, d.name, symbol)) continue;
        if (pathNames(d.file, path)) return d;
    }
    return null;
}

/// True when `referenced` names the indexed file `file`: an exact match, or a
/// suffix that starts at a path separator.
fn pathNames(file: []const u8, referenced: []const u8) bool {
    if (std.mem.eql(u8, file, referenced)) return true;
    if (file.len <= referenced.len) return false;
    if (!std.mem.endsWith(u8, file, referenced)) return false;
    return file[file.len - referenced.len - 1] == '/';
}

// ── Which names the divergence rule groups ──────────────────────────────

/// Unit segments recognised in `units` mode — the trailing `_`-separated word
/// of a name like `silk_stroke_mm` or `max_footprint_bytes`. Single-letter
/// units (`_a`, `_v`, `_s`, `_w`) are deliberately absent: `node_a` / `point_b`
/// pair naming is far more common in real code than amperes, and a name that
/// generic belongs to `mode = "all"` rather than to the quiet default.
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
fn hasUnitSegment(name: []const u8) bool {
    const tail = trailingSegment(name) orelse return false;
    for (unit_segments) |unit| {
        if (std.ascii.eqlIgnoreCase(tail, unit)) return true;
    }
    return false;
}

/// True when the divergence rule groups this name: not on `ignore_names`, and
/// — in the default `units` mode — carrying a unit segment.
fn isGrouped(name: []const u8, cfg: config.DivergentConstCfg) bool {
    for (cfg.ignore_names) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return false;
    }
    return cfg.mode == .all or hasUnitSegment(name);
}

// ── The divergence rule ─────────────────────────────────────────────────

/// Every declaration of `name` that the divergence rule considers, in index
/// order so the reported site list is deterministic.
fn groupOf(allocator: Allocator, decls: []const Decl, name: []const u8) Allocator.Error![]const Decl {
    var group: std.ArrayList(Decl) = .empty;
    for (decls) |d| {
        if (d.mirror != null) continue;
        if (!std.mem.eql(u8, d.name, name)) continue;
        try group.append(allocator, d);
    }
    return group.toOwnedSlice(allocator);
}

/// How many distinct values a group holds. Two is already a divergence; the
/// number rides the violation as its metric.
fn distinctValues(group: []const Decl) u64 {
    var count: u64 = 0;
    for (group, 0..) |d, i| {
        if (firstIndexOfValue(group[0..i], d.value) == null) count += 1;
    }
    return count;
}

/// The index of the first declaration in `group` holding `value`, or null.
fn firstIndexOfValue(group: []const Decl, value: Value) ?usize {
    for (group, 0..) |d, i| {
        if (valuesEqual(d.value, value)) return i;
    }
    return null;
}

/// How many distinct files a group spans. A group confined to one file is not a
/// cross-file divergence, whatever its values say.
fn distinctFiles(group: []const Decl) usize {
    var count: usize = 0;
    for (group, 0..) |d, i| {
        if (firstIndexOfFile(group[0..i], d.file) == null) count += 1;
    }
    return count;
}

/// The index of the first declaration in `group` declared in `file`, or null.
fn firstIndexOfFile(group: []const Decl, file: []const u8) ?usize {
    for (group, 0..) |d, i| {
        if (std.mem.eql(u8, d.file, file)) return i;
    }
    return null;
}

/// Renders the site list as `0.12 (src/a.zig:10), 0.15 (src/b.zig:20)`, elided
/// after `max_reported_sites`.
fn formatSites(allocator: Allocator, group: []const Decl) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const shown = @min(group.len, max_reported_sites);
    for (group[0..shown], 0..) |d, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const value = try renderValue(allocator, d.value);
        defer allocator.free(value);
        const site = try std.fmt.allocPrint(allocator, "{s} ({s}:{d})", .{ value, d.file, d.line });
        defer allocator.free(site);
        try buf.appendSlice(allocator, site);
    }
    if (group.len > shown) try buf.appendSlice(allocator, ", \u{2026}");
    return buf.toOwnedSlice(allocator);
}

/// Builds the one violation for a name whose declarations disagree.
fn divergenceViolation(
    allocator: Allocator,
    group: []const Decl,
    values: u64,
) Allocator.Error!reporter.Violation {
    const sites = try formatSites(allocator, group);
    const message = try std.fmt.allocPrint(
        allocator,
        "const {s} holds {d} different values across {d} file(s): {s}",
        .{ group[0].name, values, distinctFiles(group), sites },
    );
    // Identity is the NAME alone: the finding is about one fact spelled twice,
    // so it must be ONE baseline row however many files carry it, and adding a
    // third disagreeing copy must not arrive as a brand-new violation key.
    const identity = try std.fmt.allocPrint(allocator, "const {s}", .{group[0].name});
    return .{
        .check = check_name,
        .file = group[0].file,
        .line = group[0].line,
        .message = message,
        .fix_hint = fix_hint,
        .identity = identity,
        .metric = values,
    };
}

/// Appends one violation per name whose ungrouped declarations hold two or more
/// distinct values in two or more files.
fn divergenceViolations(
    allocator: Allocator,
    decls: []const Decl,
    cfg: config.DivergentConstCfg,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (decls) |d| {
        if (d.mirror != null) continue;
        if (!isGrouped(d.name, cfg)) continue;
        if ((try seen.getOrPut(allocator, d.name)).found_existing) continue;
        const group = try groupOf(allocator, decls, d.name);
        const values = distinctValues(group);
        if (values < 2 or distinctFiles(group) < 2) continue;
        try out.append(allocator, try divergenceViolation(allocator, group, values));
    }
}

// ── The mirror rule ─────────────────────────────────────────────────────

/// Builds a mirror violation for one annotated declaration.
fn mirrorViolation(
    allocator: Allocator,
    d: Decl,
    detail_text: []const u8,
) Allocator.Error!reporter.Violation {
    const message = try std.fmt.allocPrint(
        allocator,
        "const {s} declares `{s} {s}` but {s}",
        .{ d.name, mirror_marker, d.mirror.?, detail_text },
    );
    // A mirror failure is one declaration's own broken claim, so it is keyed by
    // that site — unlike a divergence, which is keyed by the shared name.
    const identity = try std.fmt.allocPrint(allocator, "mirror {s}|{s}", .{ d.file, d.name });
    return .{
        .check = check_name,
        .file = d.file,
        .line = d.line,
        .message = message,
        .fix_hint = "make the two values equal, repoint the annotation, or drop it.",
        .identity = identity,
    };
}

/// The reason one mirror claim fails, or null when it holds. Runs regardless of
/// `mode` and `ignore_names`: the annotation is an explicit author claim, so it
/// is always verified.
fn mirrorFailure(allocator: Allocator, d: Decl, decls: []const Decl) Allocator.Error!?[]const u8 {
    const referent = d.mirror.?;
    const parts = splitReferent(referent) orelse
        return try allocator.dupe(u8, "that is not spelled <path>.zig.<name>");
    const target = findReferent(decls, parts[0], parts[1]) orelse return try std.fmt.allocPrint(
        allocator,
        "no file-scope numeric const {s} was found in {s}",
        .{ parts[1], parts[0] },
    );
    if (valuesEqual(d.value, target.value)) return null;
    const mine = try renderValue(allocator, d.value);
    defer allocator.free(mine);
    const theirs = try renderValue(allocator, target.value);
    defer allocator.free(theirs);
    return try std.fmt.allocPrint(
        allocator,
        "the documented mirror has drifted: {s} here, {s} at {s}:{d}",
        .{ mine, theirs, target.file, target.line },
    );
}

/// Appends one violation per annotated declaration whose claim does not hold.
fn mirrorViolations(
    allocator: Allocator,
    decls: []const Decl,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    for (decls) |d| {
        if (d.mirror == null) continue;
        const failure = try mirrorFailure(allocator, d, decls) orelse continue;
        defer allocator.free(failure);
        try out.append(allocator, try mirrorViolation(allocator, d, failure));
    }
}

// ── Entry points ────────────────────────────────────────────────────────

/// Pure core: every divergence and broken-mirror violation across an already
/// parsed set of files. Takes the shared index's entries, so an `all` run pays
/// no parse of its own.
pub fn analyzeIndex(
    allocator: Allocator,
    files: []const ast_index.Entry,
    cfg: config.DivergentConstCfg,
) Allocator.Error![]const reporter.Violation {
    var decls: std.ArrayList(Decl) = .empty;
    for (files) |*entry| try collectFile(allocator, entry, &decls);
    var out: std.ArrayList(reporter.Violation) = .empty;
    try divergenceViolations(allocator, decls.items, cfg, &out);
    try mirrorViolations(allocator, decls.items, &out);
    return out.toOwnedSlice(allocator);
}

/// The indexed files this check reads: everything except the paths an
/// `[[allow]] check = "divergent-const"` entry exempts.
fn allowedFiles(
    allocator: Allocator,
    files: []const ast_index.Entry,
    skip: []const []const u8,
) Allocator.Error![]const ast_index.Entry {
    if (skip.len == 0) return files;
    var kept: std.ArrayList(ast_index.Entry) = .empty;
    for (files) |entry| {
        if (skipped(skip, entry.rel_path)) continue;
        try kept.append(allocator, entry);
    }
    return kept.toOwnedSlice(allocator);
}

/// True when any exemption glob names this path.
fn skipped(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// Entry point for the divergent-const check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    const files = try allowedFiles(allocator, idx.files, ctx.cfg.extraAllowed(check_name));
    const found = try analyzeIndex(allocator, files, ctx.cfg.divergent_const);
    if (found.len == 0) {
        reporter.ok("divergent-const: no const holds different values across files", .{});
        return;
    }
    reporter.fail("divergent-const FAILED ({d} name(s))", .{found.len});
    for (found) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses one in-test source string into the index entry shape the pure core
/// consumes, so a test states a whole file rather than an AST.
fn testEntry(a: Allocator, rel_path: []const u8, source: [:0]const u8) !ast_index.Entry {
    return .{ .rel_path = rel_path, .content = source, .tree = try Ast.parse(a, source, .{}) };
}

/// Folds the initializer of the first file-scope const in `source`.
fn foldFirst(a: Allocator, source: [:0]const u8) !?Value {
    var tree = try Ast.parse(a, source, .{});
    const decl = tree.rootDecls()[0];
    const init_node = tree.fullVarDecl(decl).?.ast.init_node.unwrap().?;
    return foldNode(&tree, init_node, 0);
}

// spec: Divergent Const - Flags one const name holding different values in two files

test "analyzeIndex flags a name whose two files disagree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/gerber.zig", "const silk_stroke_mm = 0.12;\n"),
        try testEntry(a, "src/kicad.zig", "pub const silk_stroke_mm = 0.15;\n"),
    };
    const out = try analyzeIndex(a, &files, .{});
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("const silk_stroke_mm", out[0].identity.?);
    try testing.expectEqual(@as(u64, 2), out[0].metric.?);
    try testing.expectEqualStrings(
        "src/gerber.zig:1: const silk_stroke_mm holds 2 different values across 2 file(s): " ++
            "0.12 (src/gerber.zig:1), 0.15 (src/kicad.zig:1)",
        try reporter.flatLine(a, out[0]),
    );
}

// spec: Divergent Const - Ignores a name whose copies all hold the same value

test "analyzeIndex ignores agreeing copies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Same name, same value: duplication, not divergence — the opposite polarity
    // to repeated-string-literal's cross-file rule, and deliberately silent.
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/a.zig", "const grid_mm = 0.5;\n"),
        try testEntry(a, "src/b.zig", "const grid_mm = 0.5;\n"),
    };
    try testing.expectEqual(@as(usize, 0), (try analyzeIndex(a, &files, .{})).len);
}

// spec: Divergent Const - Treats folded integer expressions of one value as equal

test "foldNode folds shifts, products and separators to one value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shifted = (try foldFirst(a, "const max_board_bytes = 16 << 20;\n")).?;
    const multiplied = (try foldFirst(a, "const max_board_bytes = 16 * 1024 * 1024;\n")).?;
    const spelled = (try foldFirst(a, "const max_board_bytes = 16_777_216;\n")).?;
    try testing.expect(valuesEqual(shifted, multiplied));
    try testing.expect(valuesEqual(shifted, spelled));
    // A float spelling of the same number is the same value too.
    const as_float = (try foldFirst(a, "const n_bytes = 16777216.0;\n")).?;
    try testing.expect(valuesEqual(spelled, as_float));
    // Parentheses and negation fold; a non-integral float never equals an int.
    const grouped = (try foldFirst(a, "const off_mm = -(1 + 2);\n")).?;
    try testing.expect(valuesEqual(grouped, .{ .int = -3 }));
    try testing.expect(!valuesEqual(.{ .int = 1 }, .{ .float = 1.5 }));
}

// spec: Divergent Const - Skips a const whose initializer is not a numeric literal expression

test "collectFile skips unfoldable initializers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A call, another identifier, a division and a string are all unfoldable, so
    // the const is never compared as text.
    try testing.expect((try foldFirst(a, "const limit_mm = compute();\n")) == null);
    try testing.expect((try foldFirst(a, "const limit_mm = other_mm;\n")) == null);
    try testing.expect((try foldFirst(a, "const limit_mm = 1 / 2;\n")) == null);
    try testing.expect((try foldFirst(a, "const limit_mm = \"0.5\";\n")) == null);
    // An overflowing product is unfoldable rather than a wrapped number.
    try testing.expect((try foldFirst(a, "const big_bytes = 170141183460469231731687303715884105727 * 4;\n")) == null);
}

// spec: Divergent Const - Groups only unit-suffixed names in the default units mode

test "isGrouped narrows to unit segments by default and widens in all mode" {
    try testing.expect(isGrouped("silk_stroke_mm", .{}));
    try testing.expect(isGrouped("max_footprint_bytes", .{}));
    try testing.expect(isGrouped("timeout_secs", .{}));
    // No unit segment, so the quiet default leaves it alone.
    try testing.expect(!isGrouped("eps", .{}));
    try testing.expect(!isGrouped("default_scale", .{}));
    // `all` mode widens to every name.
    try testing.expect(isGrouped("eps", .{ .mode = .all }));
}

// spec: Divergent Const - Skips a name the ignore list names

test "isGrouped honors the ignore list in both modes" {
    const cfg: config.DivergentConstCfg = .{ .ignore_names = &.{ "eps", "margin_mm" } };
    try testing.expect(!isGrouped("eps", .{ .mode = .all, .ignore_names = cfg.ignore_names }));
    // The list outranks a unit segment too.
    try testing.expect(!isGrouped("margin_mm", cfg));
    try testing.expect(isGrouped("stroke_mm", cfg));
}

// spec: Divergent Const - Ignores two same-named consts declared in one file

test "analyzeIndex needs two files before it reports a divergence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/a.zig", "const gap_mm = 1.0;\nconst gap_mm = 2.0;\n"),
    };
    try testing.expectEqual(@as(usize, 0), (try analyzeIndex(a, &files, .{})).len);
}

// spec: Divergent Const - Exempts an annotated mirror from the divergence rule

test "analyzeIndex exempts a mirror-of const from divergence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/limits.zig", "pub const max_blob_bytes = 1024;\n"),
        try testEntry(a, "src/copy.zig",
            \\/// mirror-of: src/limits.zig.max_blob_bytes
            \\const max_blob_bytes = 1024;
            \\
        ),
    };
    try testing.expectEqual(@as(usize, 0), (try analyzeIndex(a, &files, .{})).len);
}

// spec: Divergent Const - Fails an annotated mirror whose value drifted from its referent

test "analyzeIndex reports a drifted mirror" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/limits.zig", "pub const max_blob_bytes = 1024;\n"),
        try testEntry(a, "src/copy.zig",
            \\/// mirror-of: limits.zig.max_blob_bytes
            \\const max_blob_bytes = 2048;
            \\
        ),
    };
    const out = try analyzeIndex(a, &files, .{});
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("mirror src/copy.zig|max_blob_bytes", out[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "drifted: 2048 here, 1024 at src/limits.zig:1") != null);
}

// spec: Divergent Const - Fails an annotated mirror whose referent does not resolve

test "analyzeIndex reports an unresolvable mirror referent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/copy.zig",
            \\/// mirror-of: src/gone.zig.max_blob_bytes
            \\const max_blob_bytes = 2048;
            \\/// mirror-of: notAPath
            \\const other_bytes = 7;
            \\
        ),
    };
    const out = try analyzeIndex(a, &files, .{});
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "no file-scope numeric const max_blob_bytes") != null);
    try testing.expect(std.mem.endsWith(u8, out[1].message, "that is not spelled <path>.zig.<name>"));
}

// spec: Divergent Const - Resolves a mirror referent by exact path or path tail

test "pathNames matches an indexed path exactly or at a separator" {
    try testing.expect(pathNames("src/board/limits.zig", "src/board/limits.zig"));
    try testing.expect(pathNames("src/board/limits.zig", "board/limits.zig"));
    try testing.expect(pathNames("src/board/limits.zig", "limits.zig"));
    // A tail that does not start at a separator is a different file.
    try testing.expect(!pathNames("src/board/oldlimits.zig", "limits.zig"));
    try testing.expect(!pathNames("src/a.zig", "src/board/a.zig"));
}

// spec: Divergent Const - Elides the site list past a cap while keeping the exact count

test "formatSites lists a bounded number of declaration sites" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var group: std.ArrayList(Decl) = .empty;
    try group.appendNTimes(a, .{
        .file = "src/a.zig",
        .name = "gap_mm",
        .line = 3,
        .value = .{ .int = 1 },
        .mirror = null,
    }, max_reported_sites + 2);
    const sites = try formatSites(a, group.items);
    try testing.expect(std.mem.endsWith(u8, sites, ", \u{2026}"));
    try testing.expectEqual(@as(usize, max_reported_sites), std.mem.count(u8, sites, "src/a.zig"));
}

// spec: Divergent Const - Skips a file an allow entry exempts

test "allowedFiles drops the paths an allow entry names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/vendor/theirs.zig", "const gap_mm = 1.0;\n"),
        try testEntry(a, "src/ours.zig", "const gap_mm = 2.0;\n"),
    };
    const kept = try allowedFiles(a, &files, &.{"src/vendor/*"});
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("src/ours.zig", kept[0].rel_path);
    // With nothing exempted the original slice is handed back untouched.
    try testing.expectEqual(@as(usize, 2), (try allowedFiles(a, &files, &.{})).len);
}
