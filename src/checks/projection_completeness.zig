//! projection-completeness: a struct literal that PROJECTS a declared bundle of
//! fields — the "rebuild this value out of the parts I happen to hold" shape —
//! while silently omitting part of the bundle.
//!
//! The eda motivating case (audited 2026-09 across that repo's fix commits):
//! `pour.Copper` gained a defaulted `arcs` field in 30c8b52c. Five existing
//! literals that rebuilt a Copper out of a routed result (`.tracks = rr.tracks,
//! .vias = rr.vias`) kept compiling untouched, because every field of that
//! struct defaults to an empty slice — which is exactly why the compiler cannot
//! help: an omitted field is not an error, it is a silent empty. The
//! connectivity oracle those literals feed then ignored curved copper, so a net
//! joined only by an arc read as an open. Three follow-up commits (60275963,
//! 04af9ace) fixed ten sites by hand, and two were STILL wrong at HEAD when this
//! check was written (`placement/fine_accept.zig`, `placement/congestion.zig`).
//!
//! The rule is declared, not inferred: `[[projection]]` names the `type` and the
//! `fields` that must travel together, and a literal of that type setting SOME
//! of them but not ALL of them is the finding. `type` matches the tail of a
//! literal's type PATH at a segment boundary, so a bare `Copper` covers
//! `Copper{`, `pour.Copper{` and `routed_copper.Copper{` while the qualified
//! `routed_copper.Copper` covers only the last — the narrow spelling a repo
//! holding several same-named types needs (eda has four distinct `Copper`s, one
//! of them a two-field struct whose COMPLETE literal a bare rule misreads).
//! `optional` completes the type's vocabulary: the fields a projection may
//! legitimately omit. It never causes a violation.
//!
//! An anonymous `.{ … }` literal has no type path at all, so it takes both
//! signals its field names can give: it sets at least `anonymous_min_fields`
//! (default 2) of the declared set, AND it sets nothing outside
//! `fields` + `optional` (a literal setting a field the projection does not
//! declare is, by construction, some other type). Even so, that half is
//! inherently weaker than the typed half, and how much weaker depends on how
//! distinctive the field names are: measured on eda, one rule over
//! `{tracks, vias, arcs, rf_paths}` reported 4 typed literals and 98 anonymous
//! ones, of which roughly a third were real Copper coercions and the rest were
//! `SavedRoutes` / `LiftedNet` / `mask_relief.Copper` literals whose whole
//! vocabulary happens to be a subset of Copper's. `anonymous_min_fields = 0`
//! turns that half off, which is the right setting for a rule over field names
//! that common; the default stays 2 because a project whose bundle is spelled
//! distinctively gets the coerced call arguments for free.
//!
//! Two placements are exempt by construction. A `test` block is skipped — a
//! fixture legitimately builds a partial value, and a test that spelled the
//! whole bundle would be asserting the check's own rule rather than behavior. A
//! `// projection-ok: <why>` note on the literal's line, on a comment line
//! directly above it, or on the enclosing statement's line, marks a deliberate
//! partial projection: the omission gets a reason in the source instead of a
//! baseline row nobody reads. (The marker is matched lexically, so one spelled
//! inside a string literal on the same line also exempts it — a tradeoff paid
//! for keeping the annotation readable in a comment.)
//!
//! Not implemented here, deliberately: the DIFF-AWARE companion — "a defaulted
//! field was just added to a pub struct; list every literal of that struct which
//! does not set the new field". That one reports on the ADDING commit and needs
//! the `--against` diff plumbing; this check is the standing, config-declared
//! half, which keeps reporting after that commit has scrolled out of the diff
//! window. The two are complements, not alternatives.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const config = @import("../config.zig");
const text = @import("../text.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// Registry name, read by `cli/registry.zig` so the check and its entry cannot
/// drift apart.
pub const check_name = "projection-completeness";

/// The in-source opt-out. A deliberate partial projection carries its reason
/// here rather than in a baseline file.
const ok_marker = "// projection-ok:";

/// What `enclosingFn` reports for a literal outside every function body (a
/// file-scope `const` initializer). Half of the violation identity, so it has to
/// be a stable name rather than an empty string.
const file_scope = "<file scope>";

const fix_hint = "set every field the rule declares — they travel together — or, if this " ++
    "projection deliberately drops one, note `" ++ ok_marker ++ " <why>` on the literal.";

// ── The literals one file holds ─────────────────────────────────────────

/// One struct-literal expression, reduced to what the rule needs to judge it.
const Literal = struct {
    /// True for a `.{ … }` literal, whose type comes from its context. Kept
    /// apart from a null `type_name` so a TYPED literal whose type is not a
    /// plain path (`Foo(T){ … }`) is judged by neither rule half instead of
    /// being mistaken for an anonymous one.
    anonymous: bool,
    /// The literal's explicit type PATH, dotted and whole
    /// (`routed_copper.Copper`), or null when the type is not a plain path.
    /// Whole rather than reduced to its last segment because a repo may hold
    /// several same-named types — eda has four distinct `Copper`s — and a rule
    /// that has to tell them apart declares the qualified spelling.
    type_path: ?[]const u8,
    /// Field names the literal sets, in source order.
    fields: []const []const u8,
    /// 1-indexed line of the literal's first token.
    line: u32,
    /// 1-indexed line the enclosing statement starts on — one of the three
    /// places a `// projection-ok:` note is honored.
    statement_line: u32,
};

/// Every struct literal in one parsed file, excluding those inside `test`
/// blocks. Array literals are not struct inits and never appear here.
fn collectLiterals(allocator: Allocator, entry: *const ast_index.Entry) Allocator.Error![]const Literal {
    const tree = &entry.tree;
    const lines = try tokenLines(allocator, tree);
    const in_test = try testMask(allocator, tree);
    var out: std.ArrayList(Literal) = .empty;
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buf: [2]Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&buf, node) orelse continue;
        const first = tree.firstToken(node);
        if (in_test[first]) continue;
        const type_expr = init.ast.type_expr.unwrap();
        try out.append(allocator, .{
            .anonymous = type_expr == null,
            .type_path = if (type_expr) |t| try pathText(allocator, tree, t) else null,
            .fields = try fieldNames(allocator, tree, init),
            .line = lines[first],
            .statement_line = lines[statementStart(tree, first)],
        });
    }
    return out.toOwnedSlice(allocator);
}

/// The 1-indexed source line of every token, indexed by token. Token starts
/// ascend, so one forward cursor covers the file instead of re-counting newlines
/// from byte 0 per literal.
fn tokenLines(allocator: Allocator, tree: *const Ast) Allocator.Error![]const u32 {
    const out = try allocator.alloc(u32, tree.tokens.len);
    var cursor: text.LineCursor = .{};
    for (out, 0..) |*slot, i| slot.* = cursor.at(tree.source, tree.tokenStart(@intCast(i)));
    return out;
}

/// Per-token "is inside a `test { … }` body", from the shared brace tracker.
fn testMask(allocator: Allocator, tree: *const Ast) Allocator.Error![]const bool {
    const tags = tree.tokens.items(.tag);
    const out = try allocator.alloc(bool, tags.len);
    var scope: text.TestScope = .{};
    for (tags, out) |tag, *slot| {
        scope.update(tag);
        slot.* = scope.in_test;
    }
    return out;
}

/// A literal's type expression as a dotted path (`routed_copper.Copper`), or
/// null when it is not a plain path — a generic call (`List(T){`), `@This(){`,
/// anything with a token that is neither an identifier nor a `.`.
fn pathText(allocator: Allocator, tree: *const Ast, type_expr: Ast.Node.Index) Allocator.Error!?[]const u8 {
    const first = tree.firstToken(type_expr);
    const last = tree.lastToken(type_expr);
    if (tree.tokenTag(last) != .identifier) return null;
    var out: std.ArrayList(u8) = .empty;
    var i = first;
    while (i <= last) : (i += 1) {
        switch (tree.tokenTag(i)) {
            .identifier, .period => try out.appendSlice(allocator, tree.tokenSlice(i)),
            else => return null,
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// The field names a struct literal sets. A field initializer is preceded by
/// `.` `name` `=`, so its name token sits two before the value's first token —
/// the same arithmetic AstGen uses.
fn fieldNames(
    allocator: Allocator,
    tree: *const Ast,
    init: Ast.full.StructInit,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (init.ast.fields) |field| {
        const first = tree.firstToken(field);
        if (first < 2) continue;
        if (tree.tokenTag(first - 2) != .identifier) continue;
        try out.append(allocator, tree.tokenSlice(first - 2));
    }
    return out.toOwnedSlice(allocator);
}

/// The first token of the statement a literal sits in: everything back to the
/// last `;` / `{` / `}`. A `,` deliberately does not end the scan, so a literal
/// passed as one argument of a multi-line call still reports the call's line as
/// its statement — which is where a reader would write the note.
fn statementStart(tree: *const Ast, first: Ast.TokenIndex) Ast.TokenIndex {
    var i = first;
    while (i > 0) : (i -= 1) {
        switch (tree.tokenTag(i - 1)) {
            .semicolon, .l_brace, .r_brace => return i,
            else => {},
        }
    }
    return 0;
}

// ── Judging one literal against one rule ────────────────────────────────

/// The declared fields a literal sets and the ones it leaves out, both in the
/// rule's declared order so a message reads the way the config does.
const Split = struct {
    present: []const []const u8,
    missing: []const []const u8,
};

/// Splits `rule.fields` by whether `lit` sets each one.
fn splitFields(allocator: Allocator, rule: config.ProjectionRule, lit: Literal) Allocator.Error!Split {
    var present: std.ArrayList([]const u8) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    for (rule.fields) |declared| {
        const target = if (contains(lit.fields, declared)) &present else &missing;
        try target.append(allocator, declared);
    }
    return .{
        .present = try present.toOwnedSlice(allocator),
        .missing = try missing.toOwnedSlice(allocator),
    };
}

/// True when `names` holds `needle`.
fn contains(names: []const []const u8, needle: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, needle)) return true;
    }
    return false;
}

/// Whether `rule` judges `lit` at all: an explicit type whose last path segment
/// is the declared one, or an anonymous literal recognizable as this projection.
///
/// An anonymous literal has no type path, so the only evidence is its field
/// names, and it takes BOTH available signals: it sets at least
/// `anonymous_min_fields` of the declared set, AND every field it sets belongs
/// to the projection's own vocabulary (`fields` + `optional`). The second is
/// what keeps the rule usable — measured on eda, `tracks` and `vias` are also
/// fields of half a dozen unrelated `Stats` / summary structs, so the count
/// alone reported 240 literals of which four were projections of the declared
/// type. A literal setting a field the projection does not declare is, by
/// construction, a literal of some OTHER type.
fn matches(rule: config.ProjectionRule, lit: Literal, present: usize) bool {
    if (lit.anonymous) {
        if (rule.anonymous_min_fields == 0 or present < rule.anonymous_min_fields) return false;
        return !setsForeignField(rule, lit);
    }
    const path = lit.type_path orelse return false;
    return pathEndsWith(path, rule.type_name);
}

/// True when the literal's dotted type path ends in the declared one AT a
/// segment boundary: `Copper` names `Copper{`, `pour.Copper{` and
/// `routed_copper.Copper{` alike, while the qualified `routed_copper.Copper`
/// names only the last of the three. The narrow spelling is what a repo holding
/// several same-named types reaches for — in eda, `drc_diffpair.Copper` is a
/// two-field struct whose complete literal a bare `Copper` rule misreads as a
/// partial projection of the six-field one.
fn pathEndsWith(path: []const u8, declared: []const u8) bool {
    if (std.mem.eql(u8, path, declared)) return true;
    if (path.len <= declared.len) return false;
    return path[path.len - declared.len - 1] == '.' and std.mem.endsWith(u8, path, declared);
}

/// True when `lit` sets a field the rule declares in neither `fields` nor
/// `optional` — proof that the literal is not of the projected type.
fn setsForeignField(rule: config.ProjectionRule, lit: Literal) bool {
    for (lit.fields) |set| {
        if (contains(rule.fields, set) or contains(rule.optional, set)) continue;
        return true;
    }
    return false;
}

/// True when a `// projection-ok:` note covers this literal: on its own line, on
/// a comment line directly above it, or on the enclosing statement's line.
fn noted(source: []const u8, lit: Literal) bool {
    if (markerOn(source, lit.line)) return true;
    if (markerOn(source, lit.statement_line)) return true;
    if (lit.line <= 1) return false;
    const above = std.mem.trim(u8, lineText(source, lit.line - 1), &std.ascii.whitespace);
    return std.mem.startsWith(u8, above, ok_marker);
}

/// True when `line` carries the marker anywhere (a trailing comment counts).
fn markerOn(source: []const u8, line: u32) bool {
    return std.mem.indexOf(u8, lineText(source, line), ok_marker) != null;
}

/// The text of 1-indexed `line`, without its newline; empty past the end.
fn lineText(source: []const u8, line: u32) []const u8 {
    var start: usize = 0;
    var n: u32 = 1;
    while (n < line) : (n += 1) {
        const nl = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return "";
        start = nl + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    return source[start..end];
}

/// The innermost declared function containing `line`, or `file_scope`. Only
/// declared functions are known (the shared decl walk does not descend into
/// bodies), so a literal inside a nested closure reports its outer function —
/// which is still a stable identity for the baseline key.
fn enclosingFn(fns: []const ast.FnDeclInfo, line: u32) []const u8 {
    var best: ?ast.FnDeclInfo = null;
    for (fns) |f| {
        if (line < f.start_line or line >= f.start_line + f.line_count) continue;
        if (best == null or f.line_count < best.?.line_count) best = f;
    }
    return if (best) |f| f.name else file_scope;
}

/// Builds the violation for one partial projection.
///
/// The message lists both halves in the rule's declared order; the identity
/// sorts the present set instead, so two literals that set the same fields in a
/// different source order are one baseline row rather than two. Neither carries
/// a line number: moving the literal must not re-key it.
fn violationFor(
    allocator: Allocator,
    rule: config.ProjectionRule,
    file: []const u8,
    lit: Literal,
    split: Split,
    fn_name: []const u8,
) Allocator.Error!reporter.Violation {
    const sorted = try allocator.dupe([]const u8, split.present);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    return .{
        .check = check_name,
        .file = file,
        .line = lit.line,
        .message = try std.fmt.allocPrint(
            allocator,
            "projection {s}: {s}{s} literal sets {s} but not {s} \u{2014} set every declared field " ++
                "(or note {s} <why>); {s}",
            .{
                rule.name,
                if (lit.anonymous) "anonymous " else "",
                rule.type_name,
                try std.mem.join(allocator, ", ", split.present),
                try std.mem.join(allocator, ", ", split.missing),
                ok_marker,
                rule.reason,
            },
        ),
        .fix_hint = try std.fmt.allocPrint(
            allocator,
            "add the missing field(s) to this literal: {s}",
            .{try std.mem.join(allocator, ", ", split.missing)},
        ),
        .identity = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}|{s}", .{
            rule.name,
            file,
            fn_name,
            try std.mem.join(allocator, ",", sorted),
        }),
        .metric = split.missing.len,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── Entry points ────────────────────────────────────────────────────────

/// True when any glob in `patterns` names `rel_path`.
fn matchesAny(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |p| {
        if (walk.matchGlob(rel_path, p)) return true;
    }
    return false;
}

/// Every partial projection across an already-parsed set of files. `exempt` is
/// the check-wide `[[allow]]` path list; each rule's own `allow` is applied on
/// top of it, per rule.
fn analyzeIndex(
    allocator: Allocator,
    files: []const ast_index.Entry,
    rules: []const config.ProjectionRule,
    exempt: []const []const u8,
) Allocator.Error![]const reporter.Violation {
    var out: std.ArrayList(reporter.Violation) = .empty;
    for (files) |*entry| {
        if (matchesAny(exempt, entry.rel_path)) continue;
        try analyzeFile(allocator, entry, rules, &out);
    }
    return out.toOwnedSlice(allocator);
}

/// Appends every partial projection in one file. The function map is built only
/// once a violation actually needs a name for its identity, so a clean file pays
/// the literal scan and nothing else.
fn analyzeFile(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    rules: []const config.ProjectionRule,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    const literals = try collectLiterals(allocator, entry);
    if (literals.len == 0) return;
    var fns: ?[]const ast.FnDeclInfo = null;
    for (rules) |rule| {
        if (matchesAny(rule.allow, entry.rel_path)) continue;
        try ruleViolations(allocator, entry, rule, literals, &fns, out);
    }
}

/// Appends one rule's violations over one file's already-collected literals.
fn ruleViolations(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    rule: config.ProjectionRule,
    literals: []const Literal,
    fns: *?[]const ast.FnDeclInfo,
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    for (literals) |lit| {
        const split = try splitFields(allocator, rule, lit);
        if (split.present.len == 0 or split.missing.len == 0) continue;
        if (!matches(rule, lit, split.present.len)) continue;
        if (noted(entry.content, lit)) continue;
        if (fns.* == null) fns.* = try ast.fnDeclInfosFromTree(allocator, &entry.tree);
        const name = enclosingFn(fns.*.?, lit.line);
        try out.append(allocator, try violationFor(allocator, rule, entry.rel_path, lit, split, name));
    }
}

/// Entry point for projection-completeness (opt-in: `[[projection]]` rules).
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const rules = ctx.cfg.projection_rules;
    if (rules.len == 0) {
        reporter.ok("projection-completeness: no [[projection]] rules configured", .{});
        return;
    }
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    const found = try analyzeIndex(allocator, idx.files, rules, ctx.cfg.extraAllowed(check_name));
    if (found.len == 0) {
        reporter.ok(
            "projection-completeness: every projected literal sets its declared fields ({d} rule(s))",
            .{rules.len},
        );
        return;
    }
    reporter.fail("projection-completeness FAILED ({d} partial projection(s))", .{found.len});
    for (found) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The rule the eda audit produced, used by most tests below.
const copper_rule: config.ProjectionRule = .{
    .name = "routed-copper",
    .type_name = "Copper",
    .fields = &.{ "tracks", "vias", "arcs", "rf_paths" },
    .optional = &.{"zones"},
    .reason = "connectivity oracles carve every copper kind",
};

/// Parses one in-test source string into the index entry shape the pure core
/// consumes, so a test states a whole file rather than an AST.
fn testEntry(a: Allocator, rel_path: []const u8, source: [:0]const u8) !ast_index.Entry {
    return .{ .rel_path = rel_path, .content = source, .tree = try Ast.parse(a, source, .{}) };
}

/// Runs the pure core over one source string with the shared Copper rule.
fn findIn(a: Allocator, source: [:0]const u8, rule: config.ProjectionRule) ![]const reporter.Violation {
    const files = [_]ast_index.Entry{try testEntry(a, "src/placement/fine_accept.zig", source)};
    return analyzeIndex(a, &files, &.{rule}, &.{});
}

// spec: Projection Completeness - Flags a partial projection whether the type is written bare or qualified

test "analyzeIndex flags a partial projection under a bare and a qualified type path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Both spellings name one type; matching on the last path segment is what
    // makes the rule survive the import alias a file happens to use.
    const out = try findIn(a,
        \\fn measure(b: Board) void {
        \\    const bare = Copper{ .tracks = b.tracks, .vias = b.vias };
        \\    const qualified = routed_copper.Copper{ .tracks = b.tracks, .vias = b.vias };
        \\    _ = .{ bare, qualified };
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u32, 2), out[0].line.?);
    try testing.expectEqual(@as(u32, 3), out[1].line.?);
}

// spec: Projection Completeness - Judges an anonymous literal only once it sets the configured field count

test "analyzeIndex matches an anonymous literal at the threshold and not below it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two declared fields set: this is recognizably the projection even with no
    // type path to read. One declared field set: too weak a signal to claim.
    const at = try findIn(a,
        \\fn f(b: Board) void {
        \\    sink(.{ .tracks = b.tracks, .vias = b.vias });
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 1), at.len);
    try testing.expect(std.mem.indexOf(u8, at[0].message, "anonymous Copper literal") != null);
    const below = try findIn(a,
        \\fn f(b: Board) void {
        \\    sink(.{ .tracks = b.tracks });
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 0), below.len);
    // Zero switches anonymous matching off entirely, for field names too common
    // to bet on.
    var off = copper_rule;
    off.anonymous_min_fields = 0;
    const disabled = try findIn(a,
        \\fn f(b: Board) void {
        \\    sink(.{ .tracks = b.tracks, .vias = b.vias });
        \\}
    , off);
    try testing.expectEqual(@as(usize, 0), disabled.len);
}

// spec: Projection Completeness - Narrows to one of several same-named types when the rule qualifies the path

test "analyzeIndex judges only the qualified type when the rule spells the path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Measured in eda: four distinct types are named `Copper`, and
    // `drc_diffpair.Copper` is a two-field struct whose COMPLETE literal a bare
    // `Copper` rule reads as a partial projection of the six-field one.
    const source: [:0]const u8 =
        \\fn f(b: Board) void {
        \\    const wide = drc_diffpair.Copper{ .tracks = b.tracks, .vias = b.vias };
        \\    const narrow = routed_copper.Copper{ .tracks = b.tracks, .vias = b.vias };
        \\    _ = .{ wide, narrow };
        \\}
    ;
    try testing.expectEqual(@as(usize, 2), (try findIn(a, source, copper_rule)).len);
    var qualified = copper_rule;
    qualified.type_name = "routed_copper.Copper";
    const out = try findIn(a, source, qualified);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u32, 3), out[0].line.?);
}

// spec: Projection Completeness - Ignores an anonymous literal setting a field the projection never declares

test "analyzeIndex skips an anonymous literal whose vocabulary is not the projection's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A `Stats` literal counting tracks and vias is not a Copper: it sets
    // `parts`, which the projection declares in neither `fields` nor `optional`.
    // Without this the eda rule reported 240 literals instead of 102.
    const out = try findIn(a,
        \\fn f(c: Copper) void {
        \\    const stats = .{ .parts = 4, .tracks = c.tracks.len, .vias = c.vias.len };
        \\    _ = stats;
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Projection Completeness - Passes a literal that sets every declared field

test "analyzeIndex passes a complete projection and a literal that sets none of the fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A complete projection may still carry undeclared fields (`zones` is
    // documented optional), and a literal setting only undeclared fields is not
    // a projection of this bundle at all.
    const out = try findIn(a,
        \\fn f(b: Board) void {
        \\    const whole = Copper{
        \\        .tracks = b.tracks,
        \\        .vias = b.vias,
        \\        .arcs = b.arcs,
        \\        .rf_paths = b.rf_paths,
        \\        .zones = b.zones,
        \\    };
        \\    const none = Copper{ .zones = b.zones };
        \\    _ = .{ whole, none };
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Projection Completeness - Accepts a deliberate omission noted on the literal or the line above it

test "analyzeIndex honors a projection-ok note beside and above the literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try findIn(a,
        \\fn f(b: Board) void {
        \\    const same = Copper{ .tracks = b.tracks, .vias = b.vias }; // projection-ok: chords only
        \\    // projection-ok: the DRC pass reads straight copper alone
        \\    const above = Copper{ .tracks = b.tracks, .vias = b.vias };
        \\    // projection-ok: a multi-line literal is noted at its statement
        \\    const statement = Copper{
        \\        .tracks = b.tracks,
        \\        .vias = b.vias,
        \\    };
        \\    _ = .{ same, above, statement };
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Projection Completeness - Skips a partial literal built inside a test block

test "analyzeIndex skips a partial projection inside a test block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A fixture legitimately builds a partial value; requiring the whole bundle
    // there would only assert the check's own rule back at itself.
    const out = try findIn(a,
        \\test "connectivity joins a traced net" {
        \\    const copper = Copper{ .tracks = &.{}, .vias = &.{} };
        \\    _ = copper;
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Projection Completeness - Exempts a file the rule's own allow globs name

test "analyzeIndex exempts a file named by the rule's allow globs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\fn f(b: Board) void {
        \\    const c = Copper{ .tracks = b.tracks, .vias = b.vias };
        \\    _ = c;
        \\}
    ;
    var allowed = copper_rule;
    allowed.allow = &.{"src/placement/*"};
    const files = [_]ast_index.Entry{try testEntry(a, "src/placement/fine_accept.zig", source)};
    try testing.expectEqual(@as(usize, 0), (try analyzeIndex(a, &files, &.{allowed}, &.{})).len);
    // The check-wide [[allow]] list silences the same file for every rule.
    try testing.expectEqual(
        @as(usize, 0),
        (try analyzeIndex(a, &files, &.{copper_rule}, &.{"src/placement/fine_accept.zig"})).len,
    );
}

// spec: Projection Completeness - Names the set and unset fields and closes with the rule's reason

test "violationFor renders the set fields, the missing ones and the configured reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try findIn(a,
        \\fn measure(b: Board) void {
        \\    const c = routed_copper.Copper{ .tracks = b.tracks, .vias = b.vias, .zones = b.zones };
        \\    _ = c;
        \\}
    , copper_rule);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(
        "src/placement/fine_accept.zig:2: projection routed-copper: Copper literal sets tracks, vias " ++
            "but not arcs, rf_paths \u{2014} set every declared field (or note // projection-ok: <why>); " ++
            "connectivity oracles carve every copper kind",
        try reporter.flatLine(a, out[0]),
    );
    // The hint names exactly what to add, so the sink row is actionable alone.
    try testing.expectEqualStrings("add the missing field(s) to this literal: arcs, rf_paths", out[0].fix_hint.?);
    try testing.expectEqual(@as(u64, 2), out[0].metric.?);
}

// spec: Projection Completeness - Keys a finding by the rule, file, function and sorted field set

test "violationFor keys one literal identically however its fields are ordered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const declared = try findIn(a,
        \\fn measure(b: Board) void {
        \\    const c = Copper{ .tracks = b.tracks, .vias = b.vias };
        \\    _ = c;
        \\}
    , copper_rule);
    const reordered = try findIn(a,
        \\fn measure(b: Board) void {
        \\
        \\    const c = Copper{ .vias = b.vias, .tracks = b.tracks };
        \\    _ = c;
        \\}
    , copper_rule);
    // Same rule, file, function and field set: one baseline row, whatever order
    // the literal spells the fields in and whatever line it moved to.
    try testing.expectEqualStrings(
        "routed-copper|src/placement/fine_accept.zig|measure|tracks,vias",
        declared[0].identity.?,
    );
    try testing.expectEqualStrings(declared[0].identity.?, reordered[0].identity.?);
    try testing.expect(declared[0].line.? != reordered[0].line.?);
}
