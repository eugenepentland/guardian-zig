//! shadowed-const: a value that already HAS a name reappears somewhere else as
//! a BARE literal.
//!
//! This is `divergent-const`'s blind spot, and the reason a clean
//! divergent-const run is not the same thing as a consistent codebase: that
//! check compares one NAME's value across files, so a second copy that never
//! got a name is invisible to it. The audit that produced this check (eda,
//! 2026-08-14) found divergent-const reporting zero rows on a tree carrying
//! exactly that shape of drift:
//!
//!   * `export_fab.zig` declares `pub const auto_outline_margin_mm: f64 = 1.0`,
//!     and `placement/pour.zig` and `placement/route_free_space.zig` each
//!     re-derive the same outline rectangle from a bare `1.0` — one of them with
//!     a comment reading "Replicated here to avoid an import cycle". Change the
//!     constant and the pour raster silently stops following the Edge.Cuts
//!     outline it is supposed to sit inside.
//!   * Three files declare a `1e-6` clearance epsilon under three different
//!     names, so no NAME disagrees anywhere.
//!   * A `0.05` mm sampling step sits bare in two files.
//!   * A 16 MiB sidecar cap is spelled four ways, one of them 256 MiB.
//!
//! **Two modes, and the split is the point.**
//!
//! `declared` (the default) is the GATE. A project names the handful of
//! constants whose silent re-derivation would actually ship a bug:
//!
//!   [[shadow]]
//!   const = "src/export_fab.zig.auto_outline_margin_mm"
//!   reason = "the pour raster must follow the same Edge.Cuts outline"
//!
//! and every bare literal folding to that constant's value, anywhere outside
//! the file that declares it, is a violation. Zero rules is a zero-config pass,
//! and — like `divergent-const`'s `/// mirror-of:` annotation — a declared rule
//! is an explicit author claim, so it is verified whatever the noise controls
//! below say. A rule whose referent does not resolve is itself a violation, on
//! the same principle `twin-referent` reports a dangling claim: a rule that
//! silently matches nothing reads as a guarantee and is not one.
//!
//! `auto` is a MEASUREMENT tier, for finding out how much of this a tree
//! carries before deciding what to gate. It sweeps every unit-suffixed
//! file-scope const (the same population `divergent-const`'s default mode
//! groups) and reports bare occurrences of each value in other files. It is
//! deliberately not the default, and two measurements say why. The flagship
//! case above is invisible to it — `1.0` is on the `ignore_values` list — so
//! the sweep misses the very finding that motivated the check. And on
//! Guardian's own tree (2026-08-14) it reports **33 rows, 30 of them a
//! power-of-two I/O buffer size** (`1024`, `4096`, `256`) that happens to equal
//! a `_bytes`-suffixed const in another module. Both are the mode working as
//! designed: it produces a prevalence number, not a promise. Declaring the
//! handful that matter is what makes them enforceable.
//!
//! **Bare means unnamed.** A numeric literal that IS the initializer of a
//! named `const`/`var` is not a shadow — it is a name, and a name holding the
//! same value elsewhere is `divergent-const`'s subject (or a checked
//! `/// mirror-of:` copy), with a different fix. Reporting it here would also
//! fight `magic-number`, whose whole remedy is "push this literal into a named
//! const". Everything else counts: an expression operand, a call argument, a
//! struct field default, an array length. Comments and string contents are not
//! literals at all — the scan reads `number_literal` nodes out of the parse
//! tree, never text — and a `test` block's literals are skipped, because a
//! test's expected value is supposed to be spelled independently of the
//! constant it is checking.
//!
//! A file that declares the value under ANY name is skipped for that value, in
//! both modes. Its bare copies sit beside a name for the number, so the finding
//! there is a different (and lesser) one, and `divergent-const` already owns the
//! file when the names disagree.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const config = @import("../config.zig");
const const_fold = @import("const_fold.zig");
const baseline = @import("../baseline.zig");
const violation_key = @import("../violation_key.zig");
const LineCursor = @import("../text.zig").LineCursor;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// The shared numeric fold (see `const_fold.zig`), so a value this check calls
/// a shadow is the same value `divergent-const` calls a divergence.
const Value = const_fold.Value;
const valuesEqual = const_fold.valuesEqual;
const renderValue = const_fold.renderValue;
const foldNode = const_fold.foldNode;
const foldSpelled = const_fold.foldSpelled;
const hasUnitSegment = const_fold.hasUnitSegment;

const check_name = "shadowed-const";

/// The `<file>.zig.` infix a `[[shadow]] const` referent must carry, so the path
/// half and the symbol half split without resolving anything. Deliberately the
/// same spelling `divergent-const` reads after `/// mirror-of:`: both name one
/// declaration in one file, and a project should not have to learn two
/// syntaxes for that.
const zig_infix = ".zig.";

const fix_hint = "import the constant instead of respelling its value — or, if the copy must " ++
    "stay local, give it a name and a `/// mirror-of: <path>.zig.<name>` annotation so it is checked.";

// ── What a scan is looking for ──────────────────────────────────────────

/// One declaration site: the file and line a value's name lives on.
const Site = struct {
    file: []const u8,
    line: u32,
};

/// Which files one rule's scan covers. Both lists are Guardian's ordinary `*`
/// globs (see `walk.matchGlob`), where `*` spans `/` — so `src/*.zig` is the
/// whole source tree and `src/placement/*.zig` is one subtree. An empty `files`
/// means every indexed file.
const Scope = struct {
    files: []const []const u8 = &.{},
    ignore: []const []const u8 = &.{},
};

/// A value the scan hunts bare occurrences of: what it is called, what it folds
/// to, where its name lives, and which files are exempt because they declare it
/// too. `key` is the `<path>.zig.<name>` referent — the first half of every
/// finding's baseline identity, and (in auto mode) a paste-ready
/// `[[shadow]] const = "…"` for gating what the sweep found.
const Target = struct {
    key: []const u8,
    name: []const u8,
    value: Value,
    owner: Site,
    owner_files: []const []const u8,
    scope: Scope = .{},
    reason: ?[]const u8 = null,
};

/// One file-scope numeric const found in the tree.
const Named = struct {
    file: []const u8,
    name: []const u8,
    line: u32,
    value: Value,
};

/// One bare numeric literal: its byte offset, its 1-indexed line, and what it
/// folds to. The column is derived from the offset only when a finding actually
/// reports it, which is once per violation rather than once per literal.
const Bare = struct {
    offset: u32,
    line: u32,
    value: Value,
};

/// One file's bare literals, in source order, with the content they were read
/// from so a reported occurrence can name its column.
const FileBares = struct {
    file: []const u8,
    content: []const u8,
    items: []const Bare,
};

// ── Collecting one file ─────────────────────────────────────────────────

/// Collects every file-scope `const NAME = <numeric literal expr>;` in one
/// parsed file — the population both modes resolve a target against. Only
/// `rootDecls` are read, for the reason `divergent-const` reads only those: a
/// const inside a container is namespaced by it, and a const inside a function
/// is local by construction.
fn collectNamed(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    out: *std.ArrayList(Named),
) Allocator.Error!void {
    for (try const_fold.rootConsts(allocator, &entry.tree, entry.content)) |c| {
        try out.append(allocator, .{
            .file = entry.rel_path,
            .name = c.name,
            .line = c.line,
            .value = c.value,
        });
    }
}

/// A half-open token range, used to skip a `test` declaration whole.
const TokenSpan = struct { first: u32, last: u32 };

/// The per-file facts a literal is judged against: which nodes are a named
/// declaration's initializer (so they are a NAME, not a bare literal), which
/// literals are wrapped in a negation (so `-1` folds as -1 rather than 1), and
/// which token ranges belong to `test` blocks.
const FileFacts = struct {
    named_inits: std.AutoHashMapUnmanaged(u32, void) = .empty,
    negated: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    tests: std.ArrayList(TokenSpan) = .empty,
};

/// True when `tok` falls inside one of the file's `test` declarations.
fn inTest(spans: []const TokenSpan, tok: u32) bool {
    for (spans) |span| {
        if (tok >= span.first and tok <= span.last) return true;
    }
    return false;
}

/// Records one node's contribution to the per-file facts: a declaration's
/// initializer (plus the literal under a negated one), a negation's literal
/// operand, or a `test` block's token span.
fn noteNode(
    allocator: Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
    facts: *FileFacts,
) Allocator.Error!void {
    if (tree.nodeTag(node) == .test_decl) {
        try facts.tests.append(allocator, .{ .first = tree.firstToken(node), .last = tree.lastToken(node) });
        return;
    }
    if (tree.nodeTag(node) == .negation) {
        const inner = tree.nodeData(node).node;
        if (tree.nodeTag(inner) == .number_literal) try facts.negated.put(allocator, key(inner), key(node));
        return;
    }
    const var_decl = tree.fullVarDecl(node) orelse return;
    const init_node = var_decl.ast.init_node.unwrap() orelse return;
    try facts.named_inits.put(allocator, key(init_node), {});
}

/// A node index as a plain integer, for the per-file maps.
fn key(node: Ast.Node.Index) u32 {
    return @backingInt(node);
}

/// Builds the per-file facts in one pass over every node.
fn collectFacts(allocator: Allocator, tree: *const Ast) Allocator.Error!FileFacts {
    var facts: FileFacts = .{};
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        try noteNode(allocator, tree, @fromBackingInt(@intCast(i)), &facts);
    }
    return facts;
}

/// The folded value one literal node contributes and the node that OWNS it —
/// itself, or the negation wrapping it — or null when it does not fold.
fn literalValue(tree: *const Ast, facts: *const FileFacts, node: Ast.Node.Index) ?struct { u32, Value } {
    const owner = facts.negated.get(key(node)) orelse return .{ key(node), foldNode(tree, node, 0) orelse return null };
    return .{ owner, foldNode(tree, @fromBackingInt(@intCast(owner)), 0) orelse return null };
}

/// Collects every BARE numeric literal in one parsed file, in source order: a
/// `number_literal` that is not a named declaration's initializer and does not
/// sit inside a `test` block.
fn collectBares(allocator: Allocator, entry: *const ast_index.Entry) Allocator.Error!FileBares {
    const tree = &entry.tree;
    const facts = try collectFacts(allocator, tree);
    var items: std.ArrayList(Bare) = .empty;
    var i: u32 = 0;
    const count: u32 = @intCast(tree.nodes.len);
    while (i < count) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .number_literal) continue;
        const tok = tree.nodeMainToken(node);
        if (inTest(facts.tests.items, tok)) continue;
        const owner, const value = literalValue(tree, &facts, node) orelse continue;
        if (facts.named_inits.contains(owner)) continue;
        try items.append(allocator, .{ .offset = tree.tokenStart(tok), .line = 0, .value = value });
    }
    return finishBares(allocator, entry, items.items);
}

/// Orders one file's literals by source position and fills in their lines with
/// a single forward pass. Node order is a parse artefact, so the sort is what
/// makes "first occurrence" mean first in the FILE.
fn finishBares(allocator: Allocator, entry: *const ast_index.Entry, items: []Bare) Allocator.Error!FileBares {
    std.mem.sort(Bare, items, {}, byOffset);
    var cursor: LineCursor = .{};
    for (items) |*bare| bare.line = cursor.at(entry.content, bare.offset);
    return .{
        .file = entry.rel_path,
        .content = entry.content,
        .items = try allocator.dupe(Bare, items),
    };
}

fn byOffset(_: void, a: Bare, b: Bare) bool {
    return a.offset < b.offset;
}

/// The 1-indexed column of a byte offset — the distance back to the start of
/// its line. Scanned backwards on demand, which is bounded by one line's length
/// and paid once per reported finding rather than once per literal.
fn columnOf(content: []const u8, offset: u32) u32 {
    const at = @min(offset, content.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..at], '\n')) |nl| nl + 1 else 0;
    return @intCast(at - line_start + 1);
}

// ── Resolving declared rules ────────────────────────────────────────────

/// Splits a referent into its file path and symbol name at the last `.zig.`,
/// or null when it is not spelled `<path>.zig.<name>`.
fn splitReferent(text: []const u8) ?struct { []const u8, []const u8 } {
    const at = std.mem.lastIndexOf(u8, text, zig_infix) orelse return null;
    const path = text[0 .. at + zig_infix.len - 1];
    const symbol = text[at + zig_infix.len ..];
    if (symbol.len == 0) return null;
    return .{ path, symbol };
}

/// True when `referenced` names the indexed file `file`: an exact match, or a
/// suffix that starts at a path separator, so a bare `limits.zig` resolves.
fn pathNames(file: []const u8, referenced: []const u8) bool {
    if (std.mem.eql(u8, file, referenced)) return true;
    if (file.len <= referenced.len) return false;
    if (!std.mem.endsWith(u8, file, referenced)) return false;
    return file[file.len - referenced.len - 1] == '/';
}

/// Every file declaring a const whose value equals `value`, in index order.
fn declaringFiles(allocator: Allocator, named: []const Named, value: Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (named) |d| {
        if (!valuesEqual(d.value, value)) continue;
        if (!contains(out.items, d.file)) try out.append(allocator, d.file);
    }
    return out.toOwnedSlice(allocator);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// The target one `[[shadow]]` rule resolves to, or a violation explaining why
/// the rule names nothing. A dangling rule is reported rather than skipped:
/// silence would be indistinguishable from a rule that is being honoured.
fn resolveRule(
    allocator: Allocator,
    rule: config.ShadowRule,
    named: []const Named,
) Allocator.Error!union(enum) { target: Target, dangling: reporter.Violation } {
    const parts = splitReferent(rule.const_ref) orelse
        return .{ .dangling = try danglingViolation(allocator, rule, null, "is not spelled <path>.zig.<name>") };
    for (named) |d| {
        if (!std.mem.eql(u8, d.name, parts[1])) continue;
        if (!pathNames(d.file, parts[0])) continue;
        return .{ .target = try targetFor(allocator, rule, d, named) };
    }
    const why = try std.fmt.allocPrint(
        allocator,
        "names no file-scope numeric const {s} in {s}",
        .{ parts[1], parts[0] },
    );
    return .{ .dangling = try danglingViolation(allocator, rule, parts[0], why) };
}

/// Builds the target a resolved rule hunts for.
fn targetFor(
    allocator: Allocator,
    rule: config.ShadowRule,
    decl: Named,
    named: []const Named,
) Allocator.Error!Target {
    return .{
        .key = rule.const_ref,
        .name = decl.name,
        .value = decl.value,
        .owner = .{ .file = decl.file, .line = decl.line },
        .owner_files = try declaringFiles(allocator, named, decl.value),
        .scope = .{ .files = rule.files, .ignore = rule.ignore },
        .reason = rule.reason,
    };
}

/// The violation a rule that resolves to nothing raises. `file` is the path
/// half when the referent had one, so the finding lands where a reader would
/// look; a referent with no path at all renders as bare prose.
fn danglingViolation(
    allocator: Allocator,
    rule: config.ShadowRule,
    file: ?[]const u8,
    why: []const u8,
) Allocator.Error!reporter.Violation {
    const message = try std.fmt.allocPrint(
        allocator,
        "[[shadow]] const \"{s}\" {s}",
        .{ rule.const_ref, why },
    );
    return .{
        .check = check_name,
        .file = file,
        .message = message,
        .fix_hint = "repoint the rule at a file-scope numeric const that exists, or drop it.",
        // Keyed by the RULE, not by a file: the broken claim is the config's
        // own, and it is one row however many files the rule would have scanned.
        .identity = try std.fmt.allocPrint(allocator, "rule {s}", .{rule.const_ref}),
    };
}

// ── The auto-mode sweep ─────────────────────────────────────────────────

/// Digit characters in a value's shortest round-trip decimal spelling, with a
/// leading zero before the point NOT counted and zeros after it counted. That
/// is what makes `1e-6` (six) and `0.05` (two) specific enough to mean
/// something while `0.5` (one) is not.
fn digitWidth(allocator: Allocator, v: Value) Allocator.Error!u32 {
    const text = try renderValue(allocator, v);
    defer allocator.free(text);
    const body = if (std.mem.startsWith(u8, text, "-")) text[1..] else text;
    const digits = if (std.mem.startsWith(u8, body, "0.")) body[2..] else body;
    var count: u32 = 0;
    for (digits) |c| {
        if (std.ascii.isDigit(c)) count += 1;
    }
    return count;
}

/// True when a swept value is specific enough that a bare occurrence of it says
/// anything: not on the folded `ignore_values` deny list, and past the digit
/// floor for its kind. Declared rules never consult this — an explicit rule is
/// an author's claim, not a heuristic's guess.
fn isSignificant(allocator: Allocator, v: Value, cfg: config.ShadowedConstCfg) Allocator.Error!bool {
    for (cfg.ignore_values) |spelling| {
        const ignored = foldSpelled(spelling) orelse continue;
        if (valuesEqual(ignored, v)) return false;
    }
    const floor = switch (v) {
        .int => cfg.min_int_digits,
        .float => cfg.min_float_digits,
    };
    const width = try digitWidth(allocator, v);
    return width >= floor;
}

/// The auto-mode targets: one per distinct value held by a unit-suffixed
/// file-scope const that passes the significance test, represented by the first
/// declaration of that value in index order so the sweep is deterministic.
fn autoTargets(
    allocator: Allocator,
    named: []const Named,
    cfg: config.ShadowedConstCfg,
) Allocator.Error![]const Target {
    var out: std.ArrayList(Target) = .empty;
    for (named) |d| {
        if (!hasUnitSegment(d.name)) continue;
        if (!try isSignificant(allocator, d.value, cfg)) continue;
        if (alreadyTargeted(out.items, d.value)) continue;
        try out.append(allocator, .{
            // The same `<path>.zig.<name>` spelling a [[shadow]] rule takes, so
            // a sweep row is the rule that would gate it.
            .key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ d.file, d.name }),
            .name = d.name,
            .value = d.value,
            .owner = .{ .file = d.file, .line = d.line },
            .owner_files = try declaringFiles(allocator, named, d.value),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn alreadyTargeted(targets: []const Target, value: Value) bool {
    for (targets) |t| {
        if (valuesEqual(t.value, value)) return true;
    }
    return false;
}

// ── Matching targets against files ──────────────────────────────────────

/// True when this file is inside a target's scan: named by `files` (or by no
/// `files` at all, which means every indexed file) and not named by `ignore`.
fn inScope(scope: Scope, rel_path: []const u8) bool {
    if (scope.files.len != 0 and !matchesAny(scope.files, rel_path)) return false;
    return !matchesAny(scope.ignore, rel_path);
}

fn matchesAny(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// The bare literals in one file that fold to a target's value.
fn hitsIn(allocator: Allocator, bares: FileBares, value: Value) Allocator.Error![]const Bare {
    var out: std.ArrayList(Bare) = .empty;
    for (bares.items) |bare| {
        if (valuesEqual(bare.value, value)) try out.append(allocator, bare);
    }
    return out.toOwnedSlice(allocator);
}

/// Builds the one violation for a target shadowed in one file.
fn shadowViolation(
    allocator: Allocator,
    target: Target,
    bares: FileBares,
    hits: []const Bare,
) Allocator.Error!reporter.Violation {
    const rendered = try renderValue(allocator, target.value);
    defer allocator.free(rendered);
    const tail = if (target.reason) |reason|
        try std.fmt.allocPrint(allocator, " \u{2014} {s}", .{reason})
    else
        "";
    const message = try std.fmt.allocPrint(
        allocator,
        "{d} bare occurrence(s) of {s} shadow const {s} ({s}:{d}); first at {d}:{d}{s}",
        .{
            hits.len,          rendered,     target.name,                             target.owner.file,
            target.owner.line, hits[0].line, columnOf(bares.content, hits[0].offset), tail,
        },
    );
    return .{
        .check = check_name,
        .file = bares.file,
        .line = hits[0].line,
        .message = message,
        .fix_hint = fix_hint,
        // `<referent>|<file>`: the constant this is about plus the file that
        // shadows it. A fourth bare copy landing in an already-reported file
        // joins that row instead of arriving as a new violation, and the same
        // file shadowing a DIFFERENT constant is its own row.
        .identity = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ target.key, bares.file }),
        .metric = hits.len,
    };
}

/// Appends one violation per file shadowing this target.
fn targetViolations(
    allocator: Allocator,
    target: Target,
    files: []const FileBares,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    for (files) |bares| {
        if (contains(target.owner_files, bares.file)) continue;
        if (!inScope(target.scope, bares.file)) continue;
        const hits = try hitsIn(allocator, bares, target.value);
        if (hits.len == 0) continue;
        try out.append(allocator, try shadowViolation(allocator, target, bares, hits));
    }
}

// ── Entry points ────────────────────────────────────────────────────────

/// The targets this run hunts, plus any violation raised by a rule that names
/// nothing. Declared mode reads only the project's rules; auto mode ignores
/// them and sweeps the tree.
fn resolveTargets(
    allocator: Allocator,
    named: []const Named,
    cfg: config.ShadowedConstCfg,
    rules: []const config.ShadowRule,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error![]const Target {
    if (cfg.mode == .auto) return autoTargets(allocator, named, cfg);
    var targets: std.ArrayList(Target) = .empty;
    for (rules) |rule| {
        switch (try resolveRule(allocator, rule, named)) {
            .target => |t| try targets.append(allocator, t),
            .dangling => |v| try out.append(allocator, v),
        }
    }
    return targets.toOwnedSlice(allocator);
}

/// Pure core: every shadowed-value and dangling-rule violation across an
/// already parsed set of files. Takes the shared index's entries, so an `all`
/// run pays no parse of its own.
pub fn analyzeIndex(
    allocator: Allocator,
    files: []const ast_index.Entry,
    cfg: config.ShadowedConstCfg,
    rules: []const config.ShadowRule,
) Allocator.Error![]const reporter.Violation {
    var out: std.ArrayList(reporter.Violation) = .empty;
    if (cfg.mode != .auto and rules.len == 0) return out.toOwnedSlice(allocator);
    var named: std.ArrayList(Named) = .empty;
    for (files) |*entry| try collectNamed(allocator, entry, &named);
    const targets = try resolveTargets(allocator, named.items, cfg, rules, &out);
    if (targets.len == 0) return out.toOwnedSlice(allocator);
    var bares: std.ArrayList(FileBares) = .empty;
    for (files) |*entry| try bares.append(allocator, try collectBares(allocator, entry));
    for (targets) |target| try targetViolations(allocator, target, bares.items, &out);
    return out.toOwnedSlice(allocator);
}

/// The indexed files this check reads: everything except the paths an
/// `[[allow]] check = "shadowed-const"` entry exempts.
fn allowedFiles(
    allocator: Allocator,
    files: []const ast_index.Entry,
    skip: []const []const u8,
) Allocator.Error![]const ast_index.Entry {
    if (skip.len == 0) return files;
    var kept: std.ArrayList(ast_index.Entry) = .empty;
    for (files) |entry| {
        if (matchesAny(skip, entry.rel_path)) continue;
        try kept.append(allocator, entry);
    }
    return kept.toOwnedSlice(allocator);
}

/// The passing line, which says which mode produced it — a green `declared` run
/// with no rules has verified nothing, and must not read like a swept tree.
fn reportClean(cfg: config.ShadowedConstCfg, rules: usize) void {
    if (cfg.mode == .auto) {
        reporter.ok("shadowed-const: no swept value reappears bare in another file", .{});
        return;
    }
    reporter.ok("shadowed-const: {d} declared constant(s) are not shadowed by a bare literal", .{rules});
}

/// Entry point for the shadowed-const check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    const files = try allowedFiles(allocator, idx.files, ctx.cfg.extraAllowed(check_name));
    const cfg = ctx.cfg.shadowed_const;
    const found = try analyzeIndex(allocator, files, cfg, ctx.cfg.shadow_rules);
    if (found.len == 0) {
        reportClean(cfg, ctx.cfg.shadow_rules.len);
        return;
    }
    reporter.fail("shadowed-const FAILED ({d} finding(s))", .{found.len});
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

/// The owning file every declared-mode fixture points its rule at.
const owner_source =
    \\pub const auto_outline_margin_mm: f64 = 1.0;
    \\
;

/// One `[[shadow]]` rule naming the fixture's owning constant.
const owner_rule: config.ShadowRule = .{ .const_ref = "src/export_fab.zig.auto_outline_margin_mm" };

/// Runs declared mode over the owning file plus one more file.
fn analyzeWith(a: Allocator, rel_path: []const u8, source: [:0]const u8) ![]const reporter.Violation {
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/export_fab.zig", owner_source),
        try testEntry(a, rel_path, source),
    };
    return analyzeIndex(a, &files, .{}, &.{owner_rule});
}

// spec: Shadowed Const - Flags a declared constant's value reappearing as a bare literal in another file

test "analyzeIndex flags a bare literal shadowing a declared constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The eda case: a second file re-derives the outline rectangle from a bare
    // copy of the margin instead of importing the constant.
    const out = try analyzeWith(a, "src/placement/pour.zig",
        \\// Replicated here to avoid an import cycle.
        \\fn inset(w: f64) f64 {
        \\    return w - 1.0 - 1.0;
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(
        "src/export_fab.zig.auto_outline_margin_mm|src/placement/pour.zig",
        out[0].identity.?,
    );
    try testing.expectEqual(@as(u64, 2), out[0].metric.?);
    try testing.expectEqualStrings(
        "src/placement/pour.zig:3: 2 bare occurrence(s) of 1 shadow const auto_outline_margin_mm " ++
            "(src/export_fab.zig:1); first at 3:16",
        try reporter.flatLine(a, out[0]),
    );
}

// spec: Shadowed Const - Never reports the owning file's own declaration

test "analyzeIndex leaves the declaring file alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The rule's own file holds the value twice — once as the declaration, once
    // bare — and neither is a cross-file shadow.
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/export_fab.zig",
            \\pub const auto_outline_margin_mm: f64 = 1.0;
            \\fn inset(w: f64) f64 {
            \\    return w - 1.0;
            \\}
            \\
        ),
    };
    try testing.expectEqual(@as(usize, 0), (try analyzeIndex(a, &files, .{}, &.{owner_rule})).len);
}

// spec: Shadowed Const - Leaves a same-valued named const elsewhere to divergent-const

test "analyzeIndex ignores a named copy of the value in another file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A NAME holding the same value is divergent-const's subject (or a checked
    // `/// mirror-of:` copy) with a different fix, and naming it is what
    // magic-number asks for — so this check stays silent, and stays silent
    // about the bare copies sitting beside that name too.
    try testing.expectEqual(@as(usize, 0), (try analyzeWith(a, "src/pour.zig",
        \\const margin_mm: f64 = 1.0;
        \\fn inset(w: f64) f64 {
        \\    return w - 1.0;
        \\}
        \\
    )).len);
}

// spec: Shadowed Const - Never reads a value out of a comment, a string or a test block

test "analyzeIndex skips comments, strings and test blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The literal appears four times in this file and not once as a literal the
    // scan can see: twice as text, twice inside a test's own expectations.
    try testing.expectEqual(@as(usize, 0), (try analyzeWith(a, "src/pour.zig",
        \\// The margin is 1.0 mm.
        \\const label = "inset by 1.0 mm";
        \\test "inset" {
        \\    const w: f64 = 1.0;
        \\    try std.testing.expectEqual(1.0, w);
        \\}
        \\
    )).len);
}

// spec: Shadowed Const - Reports a rule whose referent resolves to nothing

test "analyzeIndex reports a dangling shadow rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{try testEntry(a, "src/export_fab.zig", owner_source)};
    const rules = [_]config.ShadowRule{
        .{ .const_ref = "src/gone.zig.auto_outline_margin_mm" },
        .{ .const_ref = "notAReferent" },
    };
    const out = try analyzeIndex(a, &files, .{}, &rules);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("rule src/gone.zig.auto_outline_margin_mm", out[0].identity.?);
    try testing.expectEqualStrings(
        "src/gone.zig: [[shadow]] const \"src/gone.zig.auto_outline_margin_mm\" " ++
            "names no file-scope numeric const auto_outline_margin_mm in src/gone.zig",
        try reporter.flatLine(a, out[0]),
    );
    // A referent with no path half at all renders as bare prose.
    try testing.expectEqualStrings(
        "[[shadow]] const \"notAReferent\" is not spelled <path>.zig.<name>",
        try reporter.flatLine(a, out[1]),
    );
}

// spec: Shadowed Const - Passes trivially when no shadow rules are configured

test "analyzeIndex is a zero-config pass in declared mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/limits.zig", "const gap_mm = 0.127;\n"),
        try testEntry(a, "src/other.zig", "fn f(w: f64) f64 { return w * 0.127; }\n"),
    };
    try testing.expectEqual(@as(usize, 0), (try analyzeIndex(a, &files, .{}, &.{})).len);
    // The same tree in auto mode is where that value gets swept up.
    try testing.expectEqual(@as(usize, 1), (try analyzeIndex(a, &files, .{ .mode = .auto }, &.{})).len);
}

// spec: Shadowed Const - Sweeps unit-suffixed constants in auto mode and keys each row as a rule

test "analyzeIndex auto mode reports a swept value under its referent key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/limits.zig", "const clearance_mm = 1e-6;\nconst scale = 0.127;\n"),
        try testEntry(a, "src/router.zig", "fn f(w: f64) f64 { return w + 1e-6 + 0.127; }\n"),
    };
    const out = try analyzeIndex(a, &files, .{ .mode = .auto }, &.{});
    // Only the unit-suffixed name is swept; `scale` carries no unit segment.
    try testing.expectEqual(@as(usize, 1), out.len);
    // The key is the [[shadow]] rule that would gate this row.
    try testing.expectEqualStrings("src/limits.zig.clearance_mm|src/router.zig", out[0].identity.?);
}

// spec: Shadowed Const - Skips an auto-mode value on the ignore list or under the digit floors

test "isSignificant honors the ignore list and the digit floors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config.ShadowedConstCfg = .{};
    // On the deny list by folded value, whichever way it was spelled.
    try testing.expect(!try isSignificant(a, .{ .float = 0.5 }, cfg));
    try testing.expect(!try isSignificant(a, .{ .int = 1000 }, cfg));
    // Too round to mean anything: one digit of float, one of int.
    try testing.expect(!try isSignificant(a, .{ .float = 0.4 }, cfg));
    try testing.expect(!try isSignificant(a, .{ .int = 5 }, cfg));
    // Specific enough to carry a claim.
    try testing.expect(try isSignificant(a, .{ .float = 0.127 }, cfg));
    try testing.expect(try isSignificant(a, .{ .float = 1e-6 }, cfg));
    try testing.expect(try isSignificant(a, .{ .float = 3.3 }, cfg));
    try testing.expect(try isSignificant(a, .{ .int = 16777216 }, cfg));
    // An emptied deny list ignores nothing, so a value the list was the only
    // thing hiding comes back; a raised floor drops one the list never named.
    try testing.expect(try isSignificant(a, .{ .int = 1000 }, .{ .ignore_values = &.{} }));
    try testing.expect(!try isSignificant(a, .{ .int = 16777216 }, .{ .min_int_digits = 9 }));
}

// spec: Shadowed Const - Scopes one rule's scan with its files and ignore globs

test "inScope narrows a rule to its own files and away from its ignores" {
    // No files list at all means every indexed file.
    try testing.expect(inScope(.{}, "src/anything.zig"));
    const scoped: Scope = .{ .files = &.{"src/placement/*.zig"}, .ignore = &.{"src/placement/vendor*"} };
    try testing.expect(inScope(scoped, "src/placement/pour.zig"));
    try testing.expect(!inScope(scoped, "src/serve/page.zig"));
    try testing.expect(!inScope(scoped, "src/placement/vendor_tess.zig"));
}

// spec: Shadowed Const - Reads a negated literal as its negative value

test "collectBares folds a negation into the literal's own value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/limits.zig", "const floor_mm = -0.127;\n"),
        // The first is a real shadow of -0.127; the second is +0.127 and is not.
        try testEntry(a, "src/router.zig", "fn f(w: f64) f64 { return w + -0.127 + 0.127; }\n"),
    };
    const out = try analyzeIndex(a, &files, .{ .mode = .auto }, &.{});
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u64, 1), out[0].metric.?);
}

// spec: Shadowed Const - Freezes a baselined shadowing file while a new one still fails

test "a baselined shadow stays frozen as its file gains another bare copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try analyzeWith(a, "src/pour.zig", "fn f(w: f64) f64 { return w - 1.0 - 1.0; }\n");
    const stored = [_][]const u8{try violation_key.fromRecord(a, check_name, first[0])};
    // The same file later gains a third bare copy AND a second file starts
    // shadowing: the count, the message and the line all move.
    const grown = [_]ast_index.Entry{
        try testEntry(a, "src/export_fab.zig", owner_source),
        try testEntry(a, "src/pour.zig", "\nfn f(w: f64) f64 { return w - 1.0 - 1.0 - 1.0; }\n"),
        try testEntry(a, "src/route_free_space.zig", "fn g(w: f64) f64 { return w - 1.0; }\n"),
    };
    const found = try analyzeIndex(a, &grown, .{}, &.{owner_rule});
    const current = try baseline.keyedViolations(a, check_name, "", found);
    const split = try baseline.splitAgainst(a, &stored, current);
    // Frozen debt stays frozen through the churn; the new file is what fails.
    try testing.expectEqual(@as(usize, 1), split.live.len);
    try testing.expectEqual(@as(usize, 0), split.removed.len);
    try testing.expectEqual(@as(usize, 1), split.added.len);
    try testing.expect(std.mem.endsWith(u8, split.added[0].key, "|src/route_free_space.zig"));
}

// spec: Shadowed Const - Skips a file an allow entry exempts

test "allowedFiles drops the paths an allow entry names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/vendor/theirs.zig", "fn f(w: f64) f64 { return w * 1.0; }\n"),
        try testEntry(a, "src/ours.zig", "fn f(w: f64) f64 { return w * 1.0; }\n"),
    };
    const kept = try allowedFiles(a, &files, &.{"src/vendor/*"});
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("src/ours.zig", kept[0].rel_path);
    // With nothing exempted the original slice is handed back untouched.
    try testing.expectEqual(@as(usize, 2), (try allowedFiles(a, &files, &.{})).len);
}
