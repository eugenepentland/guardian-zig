//! measure-vocabulary check: a NAMING-CONSISTENCY rule over a project-declared
//! unit/quantity vocabulary. It reports that two names in one expression
//! DISAGREE about what they measure — nothing more.
//!
//! The vocabulary comes from TigerBeetle's TIGER_STYLE.md, which states these
//! as mechanical rules: `index` is 0-based and points AT an item; `count` is
//! 1-based and is the NUMBER of items; `size` is a count of BYTES, with
//! `size = @sizeOf(T) * count`; `offset` is the bytewise counterpart of
//! `index`; the positive invariant is `index < count`; and `length` is banned
//! as ambiguous. Verbatim: "The usual suspects for off-by-one errors are casual
//! interactions between an `index`, a `count` or a `size`... These are all
//! primitive integer types, but should be seen as distinct types, with clear
//! rules to cast between them. To go from an `index` to a `count` you need to
//! add one, since indexes are _0-based_ but counts are _1-based_." The second
//! rule this check depends on is the suffix convention: "Add units or
//! qualifiers to variable names, and put the units or qualifiers last...
//! `latency_ms_max` rather than `max_latency_ms`." Corroborated by
//! TigerBeetle's 2026-02-16 engineering post "Index, Count, Offset, Size".
//!
//! **The evidence is doctrine, not measurement.** TIGER_STYLE is PRESCRIPTIVE:
//! it names "usual suspects" from stated experience and attributes NO specific
//! production bug, so this check must never be cited as a measured defect rate.
//! The post itself concedes "While we don't solve this problem perfectly at
//! TigerBeetle, I think we have a naming convention that helps." The hazard is
//! also not Zig-exclusive — only `size = @sizeOf(T) * count` is Zig-flavored;
//! every other rule is language-neutral. This was the weakest-grounded check in
//! the research behind it, and it ships accordingly: **default disabled,
//! opt-in, and ADVISORY-ONLY.** `run` never returns `error.CheckFailed`, on any
//! path, so it can never block a build or a commit.
//!
//! **Scope: naming consistency, NOT off-by-one detection.** General off-by-one
//! detection is an open research problem, and nothing here attempts it. A
//! finding says only that two names disagree about their unit or quantity kind.
//! It is not evidence of a bug, and every message says so.
//!
//! Tier, honestly: the comparison itself is PURE LEXICAL — an identifier is
//! split into segments and resolved to a vocabulary term, with no name
//! resolution, no types, no dataflow, and nothing cross-file. Pairs of names to
//! compare are found in three local ways: a declaration's `= <name>` (AST var
//! decl), an assignment or comparison of two bare names (the parser's token
//! stream, so a string literal or a comment can never supply one), and a call
//! argument matched positionally against the parameter NAME of a function
//! declared in the SAME file. An initializer with any arithmetic in it is not a
//! bare name and is therefore never reported — which is exactly the `±1
//! adjustment` carve-out, obtained structurally rather than by pattern-matching
//! for `+ 1`.
//!
//! Known limitations, all deliberate: a positional argument is matched against
//! the callee's parameter name only when a fn of that name is declared in the
//! same file (no import resolution, and a name declared twice in one file is
//! dropped as ambiguous); `index < count` is the CORRECT invariant, so a
//! quantity-kind disagreement is reported for assignment only, never for a
//! comparison; and the false-positive rate is expected to be HIGH on a codebase
//! that has not adopted the vocabulary, which is the whole reason the check is
//! opt-in and cannot block.

const std = @import("std");
const Ast = std.zig.Ast;
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const config = @import("../config.zig");
const lineOf = @import("../text.zig").lineOf;

const Allocator = std.mem.Allocator;
const TokenIndex = Ast.TokenIndex;
const allocPrint = std.fmt.allocPrint;

pub const check_name = "measure-vocabulary";

const fix_hint = "rename one side to the term it actually measures, or make the conversion " ++
    "explicit so the adjustment is visible in the source. Advisory only: this check never blocks.";

const disclaimer = "names only \u{2014} not a claim that an off-by-one bug exists";

// ── The vocabulary ──────────────────────────────────────────────────────

/// One family of mutually exclusive terms. For `kinds`, two names in DIFFERENT
/// families disagree (an `index` is not a `count`). For `units`, two names in
/// the same family but on DIFFERENT terms disagree (`ms` is not `us`) — which
/// is the same shape a domain-entity family needs (`net` is not `pad`).
const Group = struct {
    label: []const u8,
    terms: []const []const u8,
};

/// The parsed `[measure_vocabulary]` tables.
const Vocabulary = struct {
    kinds: []const Group = &.{},
    units: []const Group = &.{},
    banned: []const []const u8 = &.{},
};

/// A `"<label>: <term>, <term>"` row, or null when it carries no colon or no
/// term. A malformed row is reported by name and skipped rather than silently
/// treated as a term, so a typo in the table cannot quietly disable a family.
fn parseGroup(allocator: Allocator, row: []const u8) Allocator.Error!?Group {
    const colon = std.mem.indexOfScalar(u8, row, ':') orelse return null;
    const label = std.mem.trim(u8, row[0..colon], " \t");
    if (label.len == 0) return null;
    var terms: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, row[colon + 1 ..], ',');
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, " \t");
        if (term.len != 0) try terms.append(allocator, term);
    }
    if (terms.items.len == 0) return null;
    return .{ .label = label, .terms = try terms.toOwnedSlice(allocator) };
}

/// Parses both group tables, appending every unparseable row to `malformed`.
fn parseVocabulary(
    allocator: Allocator,
    cfg: config.MeasureVocabularyCfg,
    malformed: *std.ArrayList([]const u8),
) Allocator.Error!Vocabulary {
    return .{
        .kinds = try parseGroups(allocator, cfg.kinds, malformed),
        .units = try parseGroups(allocator, cfg.units, malformed),
        .banned = cfg.banned,
    };
}

fn parseGroups(
    allocator: Allocator,
    rows: []const []const u8,
    malformed: *std.ArrayList([]const u8),
) Allocator.Error![]const Group {
    var groups: std.ArrayList(Group) = .empty;
    for (rows) |row| {
        if (try parseGroup(allocator, row)) |g| {
            try groups.append(allocator, g);
        } else {
            try malformed.append(allocator, row);
        }
    }
    return groups.toOwnedSlice(allocator);
}

// ── Identifier → vocabulary term ────────────────────────────────────────

/// An identifier's lowercased word segments, split on `_` and on every
/// lower→upper transition, so `row_index`, `rowIndex` and `latency_ms_max` all
/// decompose the way a reader reads them.
fn segments(allocator: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= name.len) : (i += 1) {
        const boundary = i == name.len or name[i] == '_' or
            (i > start and i < name.len and std.ascii.isUpper(name[i]) and !std.ascii.isUpper(name[i - 1]));
        if (!boundary) continue;
        if (i > start) try out.append(allocator, try lowered(allocator, name[start..i]));
        start = if (i < name.len and name[i] == '_') i + 1 else i;
    }
    return out.toOwnedSlice(allocator);
}

fn lowered(allocator: Allocator, word: []const u8) Allocator.Error![]const u8 {
    const buf = try allocator.alloc(u8, word.len);
    for (word, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

/// Where a name landed in a group table: which family, and on which term.
const Hit = struct {
    group: usize,
    label: []const u8,
    term: []const u8,
};

/// The LAST segment that names a vocabulary term, scanning right to left.
/// Right-to-left because TIGER_STYLE puts the unit or qualifier last
/// (`latency_ms_max`), so the rightmost known term is the one that types the
/// name; a left-to-right scan reads `count_index_max` as a count.
fn resolve(groups: []const Group, segs: []const []const u8) ?Hit {
    var n = segs.len;
    while (n > 0) {
        n -= 1;
        for (groups, 0..) |g, gi| {
            for (g.terms) |term| {
                if (std.mem.eql(u8, segs[n], term)) {
                    return .{ .group = gi, .label = g.label, .term = term };
                }
            }
        }
    }
    return null;
}

/// True when `segs` contains `term`'s own segments as a contiguous run — so a
/// single-word ban (`length`) matches `buf_length` and `lengthMax`, and a
/// multi-word ban (`len_bytes`) matches `header_len_bytes` and nothing else.
fn bansName(allocator: Allocator, segs: []const []const u8, term: []const u8) Allocator.Error!bool {
    const want = try segments(allocator, term);
    if (want.len == 0 or want.len > segs.len) return false;
    var start: usize = 0;
    while (start + want.len <= segs.len) : (start += 1) {
        var all = true;
        for (want, 0..) |w, k| {
            if (!std.mem.eql(u8, w, segs[start + k])) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

// ── The one comparison every detector shares ────────────────────────────

/// Which axis two names fell out on. `.kind` is a cross-family quantity
/// disagreement (an index bound from a count); `.unit` is a same-family,
/// different-term disagreement (ms vs us, net vs pad).
const Axis = enum { kind, unit };

const Disagreement = struct {
    axis: Axis,
    /// The family both terms belong to (`.unit`), or the empty string when the
    /// two terms come from different families (`.kind`).
    family: []const u8,
    left: []const u8,
    left_label: []const u8,
    right: []const u8,
    right_label: []const u8,
};

/// The single lexical judgement: do these two identifiers disagree about what
/// they measure? Quantity kind is checked first because it is the coarser
/// error. Returns null whenever either name is outside the vocabulary — an
/// unclassified name is never evidence of anything.
fn disagreement(
    allocator: Allocator,
    vocab: Vocabulary,
    left: []const u8,
    right: []const u8,
    kinds_apply: bool,
) Allocator.Error!?Disagreement {
    const l = try segments(allocator, left);
    const r = try segments(allocator, right);
    if (kinds_apply) {
        if (resolve(vocab.kinds, l)) |lk| {
            if (resolve(vocab.kinds, r)) |rk| {
                if (lk.group != rk.group) return .{
                    .axis = .kind,
                    .family = "",
                    .left = lk.term,
                    .left_label = lk.label,
                    .right = rk.term,
                    .right_label = rk.label,
                };
            }
        }
    }
    if (resolve(vocab.units, l)) |lu| {
        if (resolve(vocab.units, r)) |ru| {
            if (lu.group == ru.group and !std.mem.eql(u8, lu.term, ru.term)) return .{
                .axis = .unit,
                .family = lu.label,
                .left = lu.term,
                .left_label = lu.label,
                .right = ru.term,
                .right_label = ru.label,
            };
        }
    }
    return null;
}

// ── Rendering ───────────────────────────────────────────────────────────

/// How the two names met. Only the wording differs; the judgement does not.
const Relation = enum {
    binding,
    assignment,
    comparison,
    argument,

    fn phrase(self: Relation) []const u8 {
        return switch (self) {
            .binding => "bound from",
            .assignment => "assigned from",
            .comparison => "compared with",
            .argument => "passed to parameter",
        };
    }
};

/// One candidate pair: where the two names met, how, and how they are spelled.
/// A struct rather than four positional arguments because all three detectors
/// hand the same tuple to one judge and one renderer.
const Pair = struct {
    line: u32,
    relation: Relation,
    left: []const u8,
    right: []const u8,
};

fn violationFor(
    allocator: Allocator,
    rel_path: []const u8,
    pair: Pair,
    d: Disagreement,
) Allocator.Error!reporter.Violation {
    const axis_text = if (d.axis == .kind)
        try allocPrint(allocator, "quantity kind ({s} vs {s})", .{ d.left_label, d.right_label })
    else
        try allocPrint(allocator, "{s} unit ({s} vs {s})", .{ d.family, d.left, d.right });
    const message = try allocPrint(
        allocator,
        "'{s}' {s} '{s}': the two names disagree about {s} \u{2014} {s}",
        .{ pair.left, pair.relation.phrase(), pair.right, axis_text, disclaimer },
    );
    return .{
        .check = check_name,
        .file = rel_path,
        .line = pair.line,
        .message = message,
        .fix_hint = fix_hint,
        .identity = try allocPrint(
            allocator,
            "{s}|{s}|{s}|{s}",
            .{ @tagName(d.axis), @tagName(pair.relation), pair.left, pair.right },
        ),
    };
}

fn bannedViolation(
    allocator: Allocator,
    rel_path: []const u8,
    line: u32,
    name: []const u8,
    term: []const u8,
) Allocator.Error!reporter.Violation {
    return .{
        .check = check_name,
        .file = rel_path,
        .line = line,
        .message = try allocPrint(
            allocator,
            "'{s}' uses '{s}', which [measure_vocabulary] bans as ambiguous \u{2014} {s}",
            .{ name, term, disclaimer },
        ),
        .fix_hint = fix_hint,
        .identity = try allocPrint(allocator, "banned|{s}|{s}", .{ term, name }),
    };
}

// ── Pair discovery ──────────────────────────────────────────────────────

/// Per-file scan state. `seen` deduplicates a repeated banned identifier so one
/// misnamed field reported on 40 lines does not drown the run.
const Scan = struct {
    allocator: Allocator,
    vocab: Vocabulary,
    rel_path: []const u8,
    tree: *const Ast,
    out: *std.ArrayList(reporter.Violation),
    seen: *std.StringHashMapUnmanaged(void),

    fn lineAt(self: Scan, tok: TokenIndex) u32 {
        return lineOf(self.tree.source, self.tree.tokenStart(tok));
    }
};

/// Pure core: every naming disagreement in one parsed file.
fn analyzeFile(
    allocator: Allocator,
    rel_path: []const u8,
    tree: *const Ast,
    vocab: Vocabulary,
) Allocator.Error![]const reporter.Violation {
    var out: std.ArrayList(reporter.Violation) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const scan: Scan = .{
        .allocator = allocator,
        .vocab = vocab,
        .rel_path = rel_path,
        .tree = tree,
        .out = &out,
        .seen = &seen,
    };
    try scanBannedTerms(scan);
    try scanDeclarations(scan);
    try scanTokenPairs(scan);
    try scanCallArguments(scan);
    return out.toOwnedSlice(allocator);
}

/// Every identifier token carrying a banned term, once per distinct spelling.
fn scanBannedTerms(scan: Scan) Allocator.Error!void {
    if (scan.vocab.banned.len == 0) return;
    var tok: TokenIndex = 0;
    while (tok < scan.tree.tokens.len) : (tok += 1) {
        if (scan.tree.tokenTag(tok) != .identifier) continue;
        const name = scan.tree.tokenSlice(tok);
        if (scan.seen.contains(name)) continue;
        const segs = try segments(scan.allocator, name);
        for (scan.vocab.banned) |term| {
            if (!try bansName(scan.allocator, segs, term)) continue;
            try scan.seen.put(scan.allocator, name, {});
            try scan.out.append(
                scan.allocator,
                try bannedViolation(scan.allocator, scan.rel_path, scan.lineAt(tok), name, term),
            );
            break;
        }
    }
}

/// `const <name> = <bare name>;` — the declaration form. The initializer must
/// be a single identifier or field access: any arithmetic makes it a different
/// node, so the `±1 adjustment` carve-out falls out of the shape rather than
/// out of a search for `+ 1`.
fn scanDeclarations(scan: Scan) Allocator.Error!void {
    var i: u32 = 0;
    while (i < scan.tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const decl = scan.tree.fullVarDecl(node) orelse continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        const right = bareName(scan.tree, init) orelse continue;
        const left = scan.tree.tokenSlice(decl.ast.mut_token + 1);
        try report(scan, .{
            .line = scan.lineAt(decl.ast.mut_token),
            .relation = .binding,
            .left = left,
            .right = right,
        }, true);
    }
}

/// The leaf name of an expression that is exactly one identifier or one field
/// access (`a`, `a.b`, `self.cfg.timeout_ms`), else null.
fn bareName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tree.tokenSlice(tree.nodeData(node).node_and_token[1]),
        else => null,
    };
}

/// `<name> = <name>;` and `<name> <cmp> <name>` over the parser's TOKEN stream.
/// Token-level rather than byte-level so a comment or a string literal can
/// never supply a pair: neither survives tokenization.
fn scanTokenPairs(scan: Scan) Allocator.Error!void {
    const tree = scan.tree;
    var tok: TokenIndex = 0;
    while (tok + 2 < tree.tokens.len) : (tok += 1) {
        if (!isChainLeaf(tree, tok)) continue;
        const relation: Relation = switch (tree.tokenTag(tok + 1)) {
            .equal => .assignment,
            .equal_equal,
            .bang_equal,
            .angle_bracket_left,
            .angle_bracket_right,
            .angle_bracket_left_equal,
            .angle_bracket_right_equal,
            => .comparison,
            else => continue,
        };
        // A declaration's `=` is scanDeclarations' job, and a `<type> = <expr>`
        // pair would compare the TYPE name. Both are ruled out by what precedes
        // the left chain.
        if (!opensExpression(tree, chainStart(tree, tok))) continue;
        const rhs = chainLeafFrom(tree, tok + 2) orelse continue;
        if (!closesValue(tree, rhs + 1)) continue;
        // `index < count` is the POSITIVE invariant, so a quantity-kind
        // disagreement is an assignment finding only.
        try report(scan, .{
            .line = scan.lineAt(tok),
            .relation = relation,
            .left = tree.tokenSlice(tok),
            .right = tree.tokenSlice(rhs),
        }, relation == .assignment);
    }
}

/// The last identifier of a dotted chain: true when `tok` names something and
/// is not followed by `.<identifier>`.
fn isChainLeaf(tree: *const Ast, tok: TokenIndex) bool {
    if (tree.tokenTag(tok) != .identifier) return false;
    return !(tok + 2 < tree.tokens.len and
        tree.tokenTag(tok + 1) == .period and
        tree.tokenTag(tok + 2) == .identifier);
}

/// The first identifier of the dotted chain whose leaf is `tok`.
fn chainStart(tree: *const Ast, tok: TokenIndex) TokenIndex {
    var at = tok;
    while (at >= 2 and tree.tokenTag(at - 1) == .period and tree.tokenTag(at - 2) == .identifier) at -= 2;
    return at;
}

/// The leaf of the dotted chain starting at `tok`, or null when `tok` does not
/// start one (a literal, a call, a `@builtin`, an open paren...).
fn chainLeafFrom(tree: *const Ast, tok: TokenIndex) ?TokenIndex {
    if (tree.tokenTag(tok) != .identifier) return null;
    var at = tok;
    while (at + 2 < tree.tokens.len and
        tree.tokenTag(at + 1) == .period and
        tree.tokenTag(at + 2) == .identifier) at += 2;
    return at;
}

/// True when the token BEFORE a left-hand chain can only open an expression.
/// A whitelist, so an unrecognised context is silently skipped rather than
/// guessed at — the fail-closed direction for an advisory check.
fn opensExpression(tree: *const Ast, start: TokenIndex) bool {
    if (start == 0) return false;
    return switch (tree.tokenTag(start - 1)) {
        .semicolon,
        .l_paren,
        .l_brace,
        .r_brace,
        .comma,
        .keyword_if,
        .keyword_while,
        .keyword_and,
        .keyword_or,
        .keyword_return,
        => true,
        else => false,
    };
}

/// True when the token AFTER a right-hand chain ends its value. Arithmetic,
/// an index, a call and a further field access are all excluded by omission:
/// each means the name is not the whole value, so the two sides were never a
/// plain name-to-name pair.
fn closesValue(tree: *const Ast, after: TokenIndex) bool {
    if (after >= tree.tokens.len) return false;
    return switch (tree.tokenTag(after)) {
        .semicolon,
        .r_paren,
        .r_brace,
        .r_bracket,
        .comma,
        .keyword_and,
        .keyword_or,
        .keyword_orelse,
        .keyword_catch,
        => true,
        else => false,
    };
}

/// A positional argument checked against the callee's PARAMETER NAME, for a
/// function declared in the same file. No import resolution and no dataflow:
/// a callee this file does not declare is simply not judged.
fn scanCallArguments(scan: Scan) Allocator.Error!void {
    var params = try localFnParams(scan.allocator, scan.tree);
    if (params.count() == 0) return;
    var i: u32 = 0;
    var buf: [1]Ast.Node.Index = undefined;
    while (i < scan.tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const call = scan.tree.fullCall(&buf, node) orelse continue;
        const callee = bareName(scan.tree, call.ast.fn_expr) orelse continue;
        const names = params.get(callee) orelse continue;
        for (call.ast.params, 0..) |arg, at| {
            if (at >= names.len) break;
            const param = names[at] orelse continue;
            const given = bareName(scan.tree, arg) orelse continue;
            try report(scan, .{
                .line = scan.lineAt(call.ast.lparen),
                .relation = .argument,
                .left = given,
                .right = param,
            }, true);
        }
    }
}

/// Parameter names of every `fn` declared in this file, by function name. A
/// name declared twice is dropped: two protos under one name make every
/// positional match a guess, and a guess is not evidence.
fn localFnParams(
    allocator: Allocator,
    tree: *const Ast,
) Allocator.Error!std.StringHashMapUnmanaged([]const ?[]const u8) {
    var map: std.StringHashMapUnmanaged([]const ?[]const u8) = .empty;
    var ambiguous: std.StringHashMapUnmanaged(void) = .empty;
    var i: u32 = 0;
    var buf: [1]Ast.Node.Index = undefined;
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) != .fn_decl) continue;
        const proto = tree.fullFnProto(&buf, node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_tok);
        if (ambiguous.contains(name)) continue;
        if (map.contains(name)) {
            _ = map.remove(name);
            try ambiguous.put(allocator, name, {});
            continue;
        }
        var names: std.ArrayList(?[]const u8) = .empty;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            try names.append(allocator, if (param.name_token) |t| tree.tokenSlice(t) else null);
        }
        try map.put(allocator, name, try names.toOwnedSlice(allocator));
    }
    return map;
}

/// Judges one candidate pair and records it when the two names disagree.
/// `kinds_apply` is false exactly where `index < count` lives: a comparison.
fn report(scan: Scan, pair: Pair, kinds_apply: bool) Allocator.Error!void {
    const d = try disagreement(scan.allocator, scan.vocab, pair.left, pair.right, kinds_apply) orelse return;
    try scan.out.append(
        scan.allocator,
        try violationFor(scan.allocator, scan.rel_path, pair, d),
    );
}

// ── Run ─────────────────────────────────────────────────────────────────

const ScanCtx = struct {
    allocator: Allocator,
    vocab: Vocabulary,
    skip: []const []const u8,
    out: *std.ArrayList(reporter.Violation),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    for (ctx.skip) |pattern| {
        if (walk.matchGlob(entry.rel_path, pattern)) return;
    }
    var owned: ?Ast = null;
    defer if (owned) |*t| t.deinit(ctx.allocator);
    const tree: *const Ast = if (entry.tree) |t| t else blk: {
        owned = Ast.parse(ctx.allocator, entry.content, .{}) catch return;
        break :blk &owned.?;
    };
    const found = try analyzeFile(ctx.allocator, entry.rel_path, tree, ctx.vocab);
    try ctx.out.appendSlice(ctx.allocator, found);
}

/// Entry point for the measure-vocabulary check. Opt-in and ADVISORY-ONLY:
/// every finding rides `reporter.warn`, and no path returns `error.CheckFailed`.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg.measure_vocabulary;
    if (!cfg.enabled) {
        reporter.ok("measure-vocabulary: disabled (opt in with [measure_vocabulary] enabled = true)", .{});
        return;
    }

    var malformed: std.ArrayList([]const u8) = .empty;
    const vocab = try parseVocabulary(allocator, cfg, &malformed);
    for (malformed.items) |row| {
        reporter.warn(.{
            .check = check_name,
            .message = try allocPrint(
                allocator,
                "ignoring malformed [measure_vocabulary] row '{s}' (expected \"<family>: <term>, <term>\")",
                .{row},
            ),
        });
    }

    var found: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .vocab = vocab,
        .skip = try std.mem.concat(allocator, []const u8, &.{
            ctx_param.cfg.extraAllowed(check_name),
            ctx_param.cfg.exclude,
        }),
        .out = &found,
    };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{
        .ctx = &ctx,
        .visit = visit,
    });

    if (found.items.len == 0) {
        reporter.ok("measure-vocabulary: no naming disagreements", .{});
        return;
    }
    // Advisory by construction: warn, then return cleanly. This check reports a
    // naming smell whose false-positive rate is expected to be high, so it must
    // never be the reason a build or a commit fails.
    reporter.detail(
        "guardian: measure-vocabulary \u{2014} {d} naming disagreement(s), advisory only\n",
        .{found.items.len},
    );
    for (found.items) |v| reporter.warn(v);
    reporter.detail("  fix: {s}\n", .{fix_hint});
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The default TIGER_STYLE table plus the two extra families an eda-shaped
/// project declares, so the tests exercise the SAME shape a consumer writes.
const test_kinds = [_]Group{
    .{ .label = "position", .terms = &.{ "index", "idx", "offset" } },
    .{ .label = "cardinality", .terms = &.{"count"} },
    .{ .label = "bytes", .terms = &.{"size"} },
};

const test_units = [_]Group{
    .{ .label = "duration", .terms = &.{ "ns", "us", "ms", "s" } },
    .{ .label = "entity", .terms = &.{ "net", "pad", "pin" } },
};

const test_banned = [_][]const u8{ "length", "len_bytes" };

const test_vocab: Vocabulary = .{
    .kinds = &test_kinds,
    .units = &test_units,
    .banned = &test_banned,
};

/// The same vocabulary with no ban list — the banned-term scan reads EVERY
/// identifier, so a test aimed at one pair keeps it out of the way.
const no_bans: Vocabulary = .{ .kinds = &test_kinds, .units = &test_units };

fn analyze(a: Allocator, source: [:0]const u8) ![]const reporter.Violation {
    return analyzeWith(a, source, test_vocab);
}

fn analyzeWith(a: Allocator, source: [:0]const u8, vocab: Vocabulary) ![]const reporter.Violation {
    var tree = try Ast.parse(a, source, .{});
    return analyzeFile(a, "src/x.zig", &tree, vocab);
}

// spec: Measure Vocabulary - Reports a declaration bound from a name of a different quantity kind

test "analyzeFile reports an index bound straight from a count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeWith(a,
        \\fn f(row_count: u32) u32 {
        \\    const row_index = row_count;
        \\    return row_index;
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(check_name, out[0].check);
    try testing.expectEqual(@as(u32, 2), out[0].line.?);
    try testing.expectEqualStrings("kind|binding|row_index|row_count", out[0].identity.?);
    // The message says the two NAMES disagree, and disowns the stronger claim.
    try testing.expect(std.mem.indexOf(u8, out[0].message, "disagree about quantity kind") != null);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "not a claim that an off-by-one bug exists") != null);
}

// spec: Measure Vocabulary - Stays silent when the initializer adjusts the value

test "analyzeFile ignores a conversion that shows its adjustment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `count - 1` is the CORRECT cast TIGER_STYLE prescribes, and it is not a
    // bare name, so the SHAPE of the initializer — not a search for `+ 1` —
    // is what exempts it. Same for a call and for a `@sizeOf` product.
    const out = try analyzeWith(a,
        \\fn f(row_count: u32, item_count: u32) void {
        \\    const row_index = row_count - 1;
        \\    const other_index = lastIndex(item_count);
        \\    const buffer_size = @sizeOf(u32) * item_count;
        \\    _ = .{ row_index, other_index, buffer_size };
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Measure Vocabulary - Reports an assignment between two names of different quantity kinds

test "analyzeFile reports a plain assignment across quantity kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeWith(a,
        \\fn f(self: *S, row_count: u32) void {
        \\    self.row_index = row_count;
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("kind|assignment|row_index|row_count", out[0].identity.?);
}

// spec: Measure Vocabulary - Reports a comparison between two names of one unit family on different units

test "analyzeFile reports a comparison mixing two units of one family" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeWith(a,
        \\fn f(elapsed_ms: u64, budget_us: u64) bool {
        \\    return elapsed_ms > budget_us;
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("unit|comparison|elapsed_ms|budget_us", out[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "duration unit (ms vs us)") != null);
    // A unit family is any mutually exclusive set, which is how an eda-shaped
    // table reports a pad count assigned from a net count — a disagreement no
    // physical-unit table could express.
    const entity = try analyzeWith(a,
        \\fn g(self: *S, net_count: u32) void {
        \\    self.pad_count = net_count;
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 1), entity.len);
    try testing.expect(std.mem.indexOf(u8, entity[0].message, "entity unit (pad vs net)") != null);
}

// spec: Measure Vocabulary - Never reports a quantity-kind disagreement for a comparison

test "analyzeFile leaves the index-less-than-count invariant alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `index < count` is TIGER_STYLE's POSITIVE invariant — the shape correct
    // code is supposed to have. Reporting it would make the check fire hardest
    // on the code that already follows the rule.
    const out = try analyzeWith(a,
        \\fn f(row_index: u32, row_count: u32) bool {
        \\    return row_index < row_count;
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Measure Vocabulary - Reports an argument whose name disagrees with the callee's parameter name

test "analyzeFile matches a positional argument against a same-file parameter name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeWith(a,
        \\fn reserve(item_count: u32) void {
        \\    _ = item_count;
        \\}
        \\fn f(payload_size: u32) void {
        \\    reserve(payload_size);
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("kind|argument|payload_size|item_count", out[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "passed to parameter") != null);
}

// spec: Measure Vocabulary - Ignores a call whose callee this file does not declare

test "analyzeFile judges no argument of a callee it cannot see" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No import resolution: another module's parameter names are not in this
    // file, and guessing them would be the loudest possible false positive.
    const foreign = try analyzeWith(a,
        \\fn f(payload_size: u32) void {
        \\    other.reserve(payload_size);
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 0), foreign.len);
    // Nor one declared TWICE here: two protos under one name make every
    // positional match a guess, and a guess is not evidence.
    const twice = try analyzeWith(a,
        \\fn reserve(item_count: u32) void {
        \\    _ = item_count;
        \\}
        \\const S = struct {
        \\    fn reserve(byte_offset: u32) void {
        \\        _ = byte_offset;
        \\    }
        \\};
        \\fn f(payload_size: u32) void {
        \\    reserve(payload_size);
        \\}
    , no_bans);
    try testing.expectEqual(@as(usize, 0), twice.len);
}

// spec: Measure Vocabulary - Reports an identifier carrying a banned term once per file

test "analyzeFile reports each banned spelling once however often it recurs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyze(a,
        \\fn f(buf_length: u32) u32 {
        \\    const x = buf_length;
        \\    return x + buf_length;
        \\}
    );
    // One misnamed parameter read on three lines is one finding, not three.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("banned|length|buf_length", out[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "bans as ambiguous") != null);
}

// spec: Measure Vocabulary - Reports nothing when a name falls outside the vocabulary

test "analyzeFile stays silent on names it cannot classify" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An unclassified name is never evidence of anything, and a comment or a
    // string literal cannot supply a pair at all: pairs come off the parser's
    // token stream, where neither survives.
    const out = try analyze(a,
        \\// row_index = row_count is described here, not written
        \\fn f(widget: u32, gadget: u32) void {
        \\    const label = "row_index = row_count";
        \\    _ = .{ widget, gadget, label };
        \\}
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Measure Vocabulary - Resolves the rightmost segment that names a vocabulary term

test "resolve reads the qualifier-last convention right to left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // TIGER_STYLE puts the unit or qualifier last (`latency_ms_max`), so the
    // RIGHTMOST known term types the name; left to right, `count_index_max`
    // would read as a count.
    const hit = resolve(&test_kinds, try segments(a, "count_index_max")).?;
    try testing.expectEqualStrings("index", hit.term);
    try testing.expectEqualStrings("position", hit.label);
    const unit = resolve(&test_units, try segments(a, "latency_ms_max")).?;
    try testing.expectEqualStrings("ms", unit.term);
    // A name with no vocabulary segment resolves to nothing at all.
    try testing.expect(resolve(&test_kinds, try segments(a, "widget_name")) == null);
}

// spec: Measure Vocabulary - Splits an identifier on underscores and camelCase boundaries

test "segments decomposes snake_case and camelCase alike" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snake = try segments(a, "row_index_max");
    try testing.expectEqual(@as(usize, 3), snake.len);
    try testing.expectEqualStrings("row", snake[0]);
    try testing.expectEqualStrings("index", snake[1]);
    try testing.expectEqualStrings("max", snake[2]);
    // camelCase decomposes the way a reader reads it, lowercased.
    const camel = try segments(a, "rowIndex");
    try testing.expectEqual(@as(usize, 2), camel.len);
    try testing.expectEqualStrings("index", camel[1]);
    // And a name with neither is a single segment, not an empty list.
    const bare = try segments(a, "count");
    try testing.expectEqual(@as(usize, 1), bare.len);
    try testing.expectEqualStrings("count", bare[0]);
}

// spec: Measure Vocabulary - Matches a banned term against a contiguous run of word segments

test "bansName matches whole segments and never a substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try bansName(a, try segments(a, "buf_length"), "length"));
    try testing.expect(try bansName(a, try segments(a, "lengthMax"), "length"));
    // A multi-word ban needs its words adjacent and in order.
    try testing.expect(try bansName(a, try segments(a, "header_len_bytes"), "len_bytes"));
    try testing.expect(!try bansName(a, try segments(a, "len_of_bytes"), "len_bytes"));
    // Segment-wise, so a name that merely CONTAINS the letters is untouched —
    // `wavelengths` is one segment and is not the banned word.
    try testing.expect(!try bansName(a, try segments(a, "wavelengths"), "length"));
}

// spec: Measure Vocabulary - Parses a vocabulary row into its family label and terms

test "parseGroup reads a family label and its terms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = (try parseGroup(a, "distance: nm, um, mm, mil")).?;
    try testing.expectEqualStrings("distance", g.label);
    try testing.expectEqual(@as(usize, 4), g.terms.len);
    try testing.expectEqualStrings("nm", g.terms[0]);
    try testing.expectEqualStrings("mil", g.terms[3]);
}

// spec: Measure Vocabulary - Reports a malformed vocabulary row instead of treating it as a term

test "parseVocabulary collects a row it cannot read rather than swallowing it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var malformed: std.ArrayList([]const u8) = .empty;
    // A row with no colon, and one with a label but no terms: neither can be a
    // family, and silently treating either as a term would disable a rule the
    // project believes it declared.
    const rows = [_][]const u8{ "duration: ms, us", "nocolon", "empty:" };
    const vocab = try parseVocabulary(a, .{ .kinds = &rows, .units = &.{}, .banned = &.{} }, &malformed);
    try testing.expectEqual(@as(usize, 1), vocab.kinds.len);
    try testing.expectEqual(@as(usize, 2), malformed.items.len);
    try testing.expectEqualStrings("nocolon", malformed.items[0]);
    try testing.expectEqualStrings("empty:", malformed.items[1]);
}

// spec: Measure Vocabulary - Decides a disagreement from the two names alone

test "disagreement judges two bare names and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Cross-family on the kind axis.
    const kind = (try disagreement(a, test_vocab, "row_index", "row_count", true)).?;
    try testing.expect(kind.axis == .kind);
    // The same pair is NOT a kind finding where kinds do not apply (a
    // comparison), which is the single switch that keeps `index < count` green.
    try testing.expect((try disagreement(a, test_vocab, "row_index", "row_count", false)) == null);
    // Same family, same term: agreement, not disagreement.
    try testing.expect((try disagreement(a, test_vocab, "start_index", "end_index", true)) == null);
    // Same family, different term, on the unit axis.
    const unit = (try disagreement(a, test_vocab, "elapsed_ms", "budget_us", false)).?;
    try testing.expect(unit.axis == .unit);
    try testing.expectEqualStrings("duration", unit.family);
    // Either side outside the vocabulary is never evidence.
    try testing.expect((try disagreement(a, test_vocab, "row_index", "widget", true)) == null);
}
