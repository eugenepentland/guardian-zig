//! twin-drift: two hand-written copies of one rule that have stopped agreeing.
//!
//! The motivating measurement (eda, an audit of 155 fix commits, 2026-09):
//! "two copies of one rule drifted" is the cause behind **25** of them. The
//! canonical live case is `buildNetClassOverrides`, duplicated in
//! `drc_session.zig` and `wasm_drc.zig` — the header of the first says the JSON
//! board parser was copied on purpose, to keep one file under the size cap.
//! The wasm copy then gained `.class`, `.power_branch_width`, `.keepout_mm` and
//! `.keepout_escape_mm` over two commits; the session copy gained none of them,
//! so the session DRC now runs with no keepout rule at all. Nothing in a
//! compiler can see that: the two functions share no type, no call and no file,
//! and each one's own tests keep passing.
//!
//! **Identical copies are debt, not drift.** The same two files also hold
//! `buildTracks`, `buildVias`, `buildPoly` and `buildNetRules` as byte-identical
//! twins. Those are a duplication problem, and reporting them here would bury
//! the one pair that is actively wrong under the ones that are merely repeated
//! — so a pair whose normalised bodies are EQUAL is silent unless
//! `[twin_drift] report_identical = true` asks for the inventory.
//!
//! The rule, then: two functions in DIFFERENT files whose normalised bodies
//! overlap by at least `min_similarity` but are not equal. Similarity is
//! `2·|LCS| / (|A| + |B|)` over normalised body lines (comments and blanks
//! dropped, internal whitespace collapsed), which reads directly as "share N%
//! of their body". The motivating pair measures 81% — one copy has grown four
//! lines the other never got.
//!
//! **Pairing is name-agnostic (v2).** v1 proposed a pair only when the two
//! functions shared a NAME. That is cheap and it is the shape every motivating
//! case had, and it is wrong twice over: it cannot see a copy that was renamed,
//! and a shared name is not evidence of a shared rule, so two functions that
//! overlap only in scaffolding got proposed and then judged on that scaffolding.
//!
//! v2 proposes pairs from the BODIES. Each body is re-tokenised with Zig's own
//! tokenizer — every string and char literal collapsed to one `$str` token,
//! every number to `$num`, keywords, operators and identifiers kept as their
//! text — and its document is the multiset of 3-gram token shingles. Across all
//! candidate bodies of the run each shingle gets an `idf`, each body a `tf·idf`
//! vector, L2-normalised; a pair is PROPOSED when the cosine reaches
//! `pair_similarity`. An inverted index accumulates those dot products sparsely
//! and only through shingles held by at most `max_df` bodies, so two bodies
//! sharing nothing rare are never compared at all. Judgement is untouched: the
//! LCS above still decides, so v2 changed which pairs are *proposed*, not how a
//! proposed pair is judged — the seam v1's own doc promised.
//!
//! Measured on eda (526 files, ~510k lines, 2026-09), `pair_similarity = 0.5`:
//!
//!   * v1 0.26 s / 69 pairs; v2 0.49 s / 126 pairs over 5,734 candidate bodies
//!     and 263,536 distinct shingles. The whole-tree pass stays sub-second
//!     because the index proposes 1,026 pairs for the LCS out of the 16.4M two
//!     bodies could form.
//!   * The motivating `buildNetClassOverrides` pair scores 0.68 against the 0.5
//!     floor. The two scaffolding-only pairs v1 misreported score 0.44
//!     (`padNets`, two maps built from one loop under different value types) and
//!     0.33 (`placement`, two unrelated helpers sharing a name) — out, with
//!     room.
//!   * 56 of v1's 69 stay, 13 drop and 70 are new; every one of the 70 is a copy
//!     under a different name, which is exactly the population v1 could not see
//!     (`shapeOfPoly`/`shapeFromWorldPoly`, `isSafeLibName`/`isSafeFootprint`,
//!     `writeXml`/`writeHtmlEscaped`).
//!
//! Pairing by body is not pairing by protocol: one interface implemented once
//! per file still looks alike whatever the implementations are called, so a
//! project whose checks all spell `run` still wants them in `[twin_drift]
//! ignore` (Guardian's own tree: 8 findings with that list, 70 without).
//!
//! Two populations are excluded because they are noise by construction:
//!
//!   * a fn declared inside a `test` block (never a shipped rule), and
//!   * a private fn reachable only from `test` blocks in its own file, directly
//!     or through another such helper — `fixture`, `testPlacement`, `mkPart`.
//!     Measured on eda: skipping those drops the finding count from 203 to 77,
//!     and every one of the 126 was a per-file test fixture written to the same
//!     shape on purpose.
//!
//! A `mirrors …` / `same as …` claim in either function's comment block does
//! NOT exempt the pair — a declared mirror that drifted is the worst case, not
//! the safe one — but the message says `(declared mirror)` so the reader knows
//! the divergence contradicts a written promise. The only exemptions are an
//! explicit `// twin-drift-ok: <reason>` above either copy, `[twin_drift]
//! ignore`, and the generic `[[allow]]` path list.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_decls = @import("../ast/decls.zig");
const ast_index = @import("../ast/index.zig");
const config = @import("../config.zig");
const lexical_scan = @import("lexical_scan.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const check_name = "twin-drift";

/// The annotation that silences one pair, written above either copy.
const exempt_marker = "twin-drift-ok:";

/// Phrases that make a comment block a DECLARED mirror. Deliberately separate
/// from `twin-referent`'s list, which resolves the referent it finds: nothing
/// here is resolved, and the phrase only adds three words to a message — it
/// never creates, silences, or re-keys a finding.
const mirror_phrases = [_][]const u8{
    "mirrors",
    "mirror of",
    "same as",
    "twin of",
    "duplicate of",
    "duplicated",
    "copy of",
    "copied from",
    "in lockstep with",
    "kept in sync",
};

/// How many differing lines the advisory detail names before it elides.
const max_detail_lines = 4;

/// Tokens per shingle. Three is the smallest window that carries SHAPE rather
/// than vocabulary: `for ( x` says something about the code, `for` on its own
/// says only that the language has loops.
const shingle_tokens = 3;

/// A shingle held by more than this many bodies never proposes a pair. That cut
/// does two jobs, and the second is why the number is tuned rather than picked.
///
/// It bounds the cost: the accumulator below visits `sum(df²)` postings, so an
/// uncapped `df` is the quadratic pass back again (on eda, 946 shingles sit over
/// this line out of 263,536).
///
/// And it is the SIGNAL. A 3-gram written in a hundred unrelated functions is
/// boilerplate, and dropping it from the numerator — while every norm still
/// holds it — is what pulls a scaffolding-only pair away from a copied rule.
/// Measured on eda at the 0.5 floor, as this constant moves (pairs / seconds):
///
///   *  32 — 61 / 0.45. Loses the whole JSON-escaper family and a third of
///           everything else with it.
///   *  64 — 92 / 0.47. Still loses that family, including the pair where one
///           copy escapes `<` and the other does not: 95% of their lines, and
///           the archetypal finding for this check.
///   *  96 — 126 / 0.49. The family is back; the nearest scaffolding-only pair
///           (`padNets`) sits at 0.44 and the nearest real one at 0.55.
///   * 128 — 144 / 0.50. `padNets` reaches 0.4949, one thousandth under.
///   * 256 — 165 / 0.56. `padNets` 0.64 and `placement` 0.57: both of v1's
///           false positives are back, which is the cut this line exists for.
const max_df = 96;

const fix_hint = "reconcile the two copies, or lift the shared part into one fn both call. " ++
    "If the divergence is deliberate, say so above either copy: `// twin-drift-ok: <why>`.";

// ── Normalising a body ──────────────────────────────────────────────────

/// One function worth comparing: its normalised body plus what its comment
/// block claims about it.
const Candidate = struct {
    file: []const u8,
    name: []const u8,
    line: u32,
    /// Normalised body, one entry per surviving source line.
    body: []const []const u8,
    /// `body` hashed line by line. The LCS runs over these rather than the
    /// text: a 400x400 comparison is 160k cell comparisons, and comparing
    /// 64-bit hashes there instead of ~40-byte strings is what keeps this
    /// check's whole-tree pass in the tens of milliseconds.
    hashes: []const u64,
    /// A `// twin-drift-ok:` marker in the comment block above the fn.
    exempt: bool,
    /// A `mirrors …` / `same as …` claim in that same comment block.
    mirror: bool,
};

/// Drops a line's `//` comment, honouring string and character literals so a
/// `"http://…"` inside one is not read as the start of a comment. A `\\`
/// multiline-string line is content to its end and is returned whole.
fn stripLineComment(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, &std.ascii.whitespace), "\\\\")) return line;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (c == '\\') i += 1 else if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return line[0..i];
        }
    }
    return line;
}

/// Collapses every internal whitespace run to one space, so re-indenting or
/// re-wrapping a line does not read as an edit to it.
fn collapseWhitespace(allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_space = false;
    for (text) |c| {
        const is_space = std.ascii.isWhitespace(c);
        if (is_space) {
            in_space = true;
            continue;
        }
        if (in_space and out.items.len > 0) try out.append(allocator, ' ');
        in_space = false;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// The normalised form of one function body: the braces of the block itself
/// dropped, then comments and blank lines dropped and every surviving line
/// trimmed and whitespace-collapsed. One entry per source line, because a
/// statement moved to its own line IS an edit worth seeing.
fn normalizeBody(allocator: Allocator, body_text: []const u8) Allocator.Error![]const []const u8 {
    var inner = body_text;
    if (inner.len > 0 and inner[0] == '{') inner = inner[1..];
    if (inner.len > 0 and inner[inner.len - 1] == '}') inner = inner[0 .. inner.len - 1];

    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, inner, '\n');
    while (it.next()) |raw| {
        const code = std.mem.trim(u8, stripLineComment(raw), &std.ascii.whitespace);
        if (code.len == 0) continue;
        try out.append(allocator, try collapseWhitespace(allocator, code));
    }
    return out.toOwnedSlice(allocator);
}

/// Hashes each normalised line once, for the LCS and the bag prefilter.
fn hashLines(allocator: Allocator, lines: []const []const u8) Allocator.Error![]const u64 {
    const out = try allocator.alloc(u64, lines.len);
    for (lines, 0..) |line, i| out[i] = std.hash.Wyhash.hash(0, line);
    return out;
}

// ── Reading one file ────────────────────────────────────────────────────

/// Byte offset of the first character of each source line, indexed from 0 for
/// line 1. Built once per file and shared by the comment-block lookup and the
/// token-to-line mapping.
fn lineStarts(allocator: Allocator, content: []const u8) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    try out.append(allocator, 0);
    for (content, 0..) |c, i| {
        if (c == '\n') try out.append(allocator, @intCast(i + 1));
    }
    return out.toOwnedSlice(allocator);
}

/// The text of 1-indexed `line`, without its newline.
fn lineText(content: []const u8, starts: []const u32, line: u32) []const u8 {
    if (line == 0 or line > starts.len) return "";
    const start = starts[line - 1];
    const end = if (line < starts.len) starts[line] - 1 else content.len;
    return content[start..@min(end, content.len)];
}

/// The contiguous run of `//` comment lines directly above a declaration, as
/// one slice of the source (empty when the line above is not a comment). Both
/// exemption spellings the check accepts live in it: a plain `//` note on the
/// line above, and a `///` doc comment.
fn commentBlockAbove(content: []const u8, starts: []const u32, line: u32) []const u8 {
    var first = line;
    while (first > 1 and isCommentLine(lineText(content, starts, first - 1))) first -= 1;
    if (first == line) return "";
    return content[starts[first - 1]..starts[line - 1]];
}

/// True when a source line holds nothing but a `//` comment.
fn isCommentLine(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, &std.ascii.whitespace), "//");
}

/// True when a comment block claims this function mirrors another one.
fn claimsMirror(block: []const u8) bool {
    for (mirror_phrases) |phrase| {
        if (std.ascii.findIgnoreCase(block, phrase) != null) return true;
    }
    return false;
}

/// A half-open 1-indexed line span.
const Span = struct { start: u32, end: u32 };

/// The line span of every `test` declaration in a file. `collectDecls` descends
/// into container members, so a test nested inside a struct counts too.
fn testSpans(allocator: Allocator, entry: *const ast_index.Entry, starts: []const u32) Allocator.Error![]const Span {
    var out: std.ArrayList(Span) = .empty;
    const tree = &entry.tree;
    for (try ast_decls.collectDecls(allocator, tree)) |decl| {
        if (tree.nodeTag(decl) != .test_decl) continue;
        const first = lineOfOffset(starts, tree.tokenStart(tree.firstToken(decl)));
        const last = lineOfOffset(starts, tree.tokenStart(tree.lastToken(decl)));
        try out.append(allocator, .{ .start = first, .end = last + 1 });
    }
    return out.toOwnedSlice(allocator);
}

/// The 1-indexed line holding `offset`, by binary search over the line index.
fn lineOfOffset(starts: []const u32, offset: u32) u32 {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= offset) lo = mid else hi = mid;
    }
    return @intCast(lo + 1);
}

/// True when `line` falls inside any of the spans.
fn inSpans(spans: []const Span, line: u32) bool {
    for (spans) |s| {
        if (line >= s.start and line < s.end) return true;
    }
    return false;
}

// ── Which functions are not test-only helpers ───────────────────────────

/// One non-test reference to a function of this file, and the function it was
/// written inside (null for a reference at file scope).
const Ref = struct { caller: ?u32, callee: u32 };

/// Marks every function reachable from non-test code: a `pub` fn is reachable
/// by definition, a file-scope reference makes one reachable, and a reference
/// from an already-reachable function propagates. What is left over is a
/// private helper only `test` blocks reach — a fixture, not a rule.
fn liveFns(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    fns: []const ast.FnDeclInfo,
    starts: []const u32,
) Allocator.Error![]bool {
    const live = try allocator.alloc(bool, fns.len);
    for (fns, 0..) |f, i| live[i] = f.is_pub;
    // A name declared twice in one file cannot be attributed to one decl, so
    // both stay live: this filter exists to remove noise, never to hide a rule.
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_name.deinit(allocator);
    for (fns, 0..) |f, i| {
        const gop = try by_name.getOrPut(allocator, f.name);
        if (gop.found_existing) live[gop.value_ptr.*] = true else gop.value_ptr.* = @intCast(i);
    }
    const refs = try collectRefs(allocator, entry, fns, starts, by_name);
    propagate(refs, live);
    return live;
}

/// Every identifier token that names one of this file's functions, outside any
/// `test` block, paired with the function whose body it sits in. A token inside
/// the very function it names (its own declaration, or a recursive call) is not
/// a reference — counting it would make every unused helper look reachable.
fn collectRefs(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    fns: []const ast.FnDeclInfo,
    starts: []const u32,
    by_name: std.StringHashMapUnmanaged(u32),
) Allocator.Error![]const Ref {
    const tests = try testSpans(allocator, entry, starts);
    var out: std.ArrayList(Ref) = .empty;
    const tree = &entry.tree;
    for (tree.tokens.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const callee = by_name.get(tree.tokenSlice(@intCast(i))) orelse continue;
        const line = lineOfOffset(starts, tree.tokenStart(@intCast(i)));
        if (inSpans(tests, line)) continue;
        const caller = enclosingFn(fns, line);
        if (caller != null and caller.? == callee) continue;
        try out.append(allocator, .{ .caller = caller, .callee = callee });
    }
    return out.toOwnedSlice(allocator);
}

/// The index of the function whose declaration spans `line`, or null when the
/// line is at file scope. Function declarations never nest, so the first hit is
/// the only one.
fn enclosingFn(fns: []const ast.FnDeclInfo, line: u32) ?u32 {
    for (fns, 0..) |f, i| {
        if (line >= f.start_line and line < f.start_line + f.line_count) return @intCast(i);
    }
    return null;
}

/// Propagates reachability along the reference edges until it stops changing.
fn propagate(refs: []const Ref, live: []bool) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (refs) |r| {
            if (live[r.callee]) continue;
            if (r.caller) |c| {
                if (!live[c]) continue;
            }
            live[r.callee] = true;
            changed = true;
        }
    }
}

// ── Collecting the candidates ───────────────────────────────────────────

/// Appends every comparable function of one parsed file.
fn collectFile(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    cfg: config.TwinDriftCfg,
    out: *std.ArrayList(Candidate),
) Allocator.Error!void {
    const fns = try ast.fnDeclInfosFromTree(allocator, &entry.tree);
    if (fns.len == 0) return;
    const starts = try lineStarts(allocator, entry.content);
    const live = try liveFns(allocator, entry, fns, starts);
    for (fns, 0..) |f, i| {
        if (!live[i]) continue;
        if (named(cfg.ignore, f.name)) continue;
        const body = try normalizeBody(allocator, f.body_text);
        if (body.len < cfg.min_statements) continue;
        const block = commentBlockAbove(entry.content, starts, f.start_line);
        try out.append(allocator, .{
            .file = entry.rel_path,
            .name = f.name,
            .line = f.start_line,
            .body = body,
            .hashes = try hashLines(allocator, body),
            .exempt = std.mem.indexOf(u8, block, exempt_marker) != null,
            .mirror = claimsMirror(block),
        });
    }
}

/// True when `name` is one of the configured names.
fn named(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// ── Measuring one pair ──────────────────────────────────────────────────

/// Length of the longest common subsequence of two hashed bodies, over two
/// rolling rows: the full matrix is never held, so the worst allowed pair costs
/// about 3 KB instead of 640 KB.
fn lcsLength(allocator: Allocator, a: []const u64, b: []const u64) Allocator.Error!u32 {
    const prev = try allocator.alloc(u32, b.len + 1);
    defer allocator.free(prev);
    const cur = try allocator.alloc(u32, b.len + 1);
    defer allocator.free(cur);
    @memset(prev, 0);
    for (a) |x| {
        cur[0] = 0;
        for (b, 1..) |y, j| {
            cur[j] = if (x == y) prev[j - 1] + 1 else @max(prev[j], cur[j - 1]);
        }
        @memcpy(prev, cur);
    }
    return prev[b.len];
}

/// How many lines two bodies could share at most, comparing them as BAGS —
/// order ignored, so it can only over-count what an LCS finds. Running this
/// first turns a proposed pair the index was optimistic about into an O(n+m)
/// rejection instead of an O(n·m) one. It measures LINES, where the index
/// measures token shingles, so it still rejects pairs the cosine proposed.
fn sharedUpperBound(allocator: Allocator, a: []const u64, b: []const u64) Allocator.Error!u32 {
    var counts: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer counts.deinit(allocator);
    for (a) |h| {
        const gop = try counts.getOrPut(allocator, h);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var shared: u32 = 0;
    for (b) |h| {
        const slot = counts.getPtr(h) orelse continue;
        if (slot.* == 0) continue;
        slot.* -= 1;
        shared += 1;
    }
    return shared;
}

/// True when `2·shared / (|a| + |b|)` reaches `floor`. Written as a
/// multiplication rather than a division so the only float in the check is the
/// configured threshold itself: no rounding decides a verdict, and nothing
/// converts a float back to an integer to reach one.
fn reaches(floor: f64, shared: u32, la: usize, lb: usize) bool {
    const total = la + lb;
    if (total == 0) return false;
    return @as(f64, @floatFromInt(2 * shared)) >= floor * @as(f64, @floatFromInt(total));
}

/// `2·shared / (|a| + |b|)` as a percentage, rounded half-up in integer
/// arithmetic. 100 exactly when the bodies are equal.
fn sharePercent(shared: u32, la: usize, lb: usize) u32 {
    const total = la + lb;
    if (total == 0) return 0;
    return @intCast((200 * shared + total / 2) / total);
}

/// One drifted twin: two functions in different files, ordered by path, with
/// the overlap measured between their normalised bodies. Their names may
/// differ — the index proposed the pair from the bodies alone.
const Twin = struct {
    a: Candidate,
    b: Candidate,
    shared: u32,
    percent: u32,
    differing: u32,
    identical: bool,

    /// True when either copy's comment block claims to mirror another.
    fn declaredMirror(self: Twin) bool {
        return self.a.mirror or self.b.mirror;
    }
};

/// The measured twin for one candidate pair, or null when the pair is exempt,
/// too large to compare, or not similar enough to report.
fn measure(
    allocator: Allocator,
    first: Candidate,
    second: Candidate,
    cfg: config.TwinDriftCfg,
) Allocator.Error!?Twin {
    const ordered = std.mem.order(u8, first.file, second.file) != .gt;
    const a = if (ordered) first else second;
    const b = if (ordered) second else first;
    const bound = try sharedUpperBound(allocator, a.hashes, b.hashes);
    if (!reaches(cfg.min_similarity, bound, a.body.len, b.body.len)) return null;
    const shared = try lcsLength(allocator, a.hashes, b.hashes);
    if (!reaches(cfg.min_similarity, shared, a.body.len, b.body.len)) return null;
    const identical = shared == a.body.len and shared == b.body.len;
    if (identical and !cfg.report_identical) return null;
    return .{
        .a = a,
        .b = b,
        .shared = shared,
        .percent = sharePercent(shared, a.body.len, b.body.len),
        .differing = @intCast((a.body.len - shared) + (b.body.len - shared)),
        .identical = identical,
    };
}

// ── Proposing pairs: tf-idf over token shingles ─────────────────────────

/// Every string and character literal hashes to this, and every number literal
/// to `num_token`. A copy that reworded a message or moved a constant is still
/// the same rule; leaving the text in would also make two unrelated bodies that
/// merely both say `"error"` look related. Identifiers are NOT collapsed — idf
/// discounts the common ones on its own, and resolving what an identifier means
/// would need scope analysis this check deliberately does not do.
const str_token: u64 = 0x5f2a_7b31_c4d8_e601;
const num_token: u64 = 0x9c1e_43a7_02bd_f58a;

/// The 3-gram token shingles of one normalised body, hashed, one entry per
/// occurrence. The body is re-joined into one text and re-tokenised with Zig's
/// own tokenizer, so `a+b` and `a + b` shingle identically and a renamed local
/// changes only the shingles that touch it.
fn bodyShingles(allocator: Allocator, body: []const []const u8) Allocator.Error![]const u64 {
    var joined: std.ArrayList(u8) = .empty;
    for (body, 0..) |line, i| {
        if (i > 0) try joined.append(allocator, '\n');
        try joined.appendSlice(allocator, line);
    }
    const text = try joined.toOwnedSliceSentinel(allocator, 0);
    defer allocator.free(text);

    var window: [shingle_tokens]u64 = undefined;
    var filled: usize = 0;
    var out: std.ArrayList(u64) = .empty;
    var tz = std.zig.Tokenizer.init(text);
    while (true) {
        const t = tz.next();
        if (t.tag == .eof) break;
        const h: u64 = switch (t.tag) {
            .string_literal, .char_literal, .multiline_string_literal_line => str_token,
            .number_literal => num_token,
            else => std.hash.Wyhash.hash(3, text[t.loc.start..t.loc.end]),
        };
        if (filled == shingle_tokens) {
            std.mem.copyForwards(u64, window[0 .. shingle_tokens - 1], window[1..]);
            window[shingle_tokens - 1] = h;
        } else {
            window[filled] = h;
            filled += 1;
        }
        if (filled == shingle_tokens) {
            try out.append(allocator, std.hash.Wyhash.hash(5, std.mem.sliceAsBytes(&window)));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// One shingle of one body: its vocabulary id, how often the body holds it, and
/// the L2-normalised `tf·idf` that weight becomes.
const Term = struct { id: u32, tf: u32, weight: f64 };

/// The whole run's tf-idf document set: one weighted term list per candidate,
/// ascending by id, plus the document frequency of every shingle in the
/// vocabulary.
const Corpus = struct {
    docs: []const []Term,
    df: []const u32,
};

/// Orders a document's terms by vocabulary id, so the sparse accumulation below
/// adds its products in one fixed order — two runs over the same tree must
/// agree to the last bit, and float addition is not associative.
fn lessById(_: void, a: Term, b: Term) bool {
    return a.id < b.id;
}

/// Interns every candidate's shingles into one vocabulary and counts document
/// frequencies. `tf` is the raw occurrence count: a body that repeats a line
/// twice really does lean twice as hard on it.
fn buildCorpus(allocator: Allocator, candidates: []const Candidate) Allocator.Error!Corpus {
    var vocab: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer vocab.deinit(allocator);
    var df: std.ArrayList(u32) = .empty;
    var counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer counts.deinit(allocator);

    const docs = try allocator.alloc([]Term, candidates.len);
    for (candidates, 0..) |c, i| {
        const shingles = try bodyShingles(allocator, c.body);
        defer allocator.free(shingles);
        counts.clearRetainingCapacity();
        for (shingles) |s| {
            const slot = try vocab.getOrPut(allocator, s);
            if (!slot.found_existing) {
                slot.value_ptr.* = @intCast(df.items.len);
                try df.append(allocator, 0);
            }
            const seen = try counts.getOrPut(allocator, slot.value_ptr.*);
            if (seen.found_existing) {
                seen.value_ptr.* += 1;
            } else {
                seen.value_ptr.* = 1;
                df.items[slot.value_ptr.*] += 1;
            }
        }
        const terms = try allocator.alloc(Term, counts.count());
        var it = counts.iterator();
        var k: usize = 0;
        while (it.next()) |e| : (k += 1) {
            terms[k] = .{ .id = e.key_ptr.*, .tf = e.value_ptr.*, .weight = 0 };
        }
        std.mem.sort(Term, terms, {}, lessById);
        docs[i] = terms;
    }
    return .{ .docs = docs, .df = try df.toOwnedSlice(allocator) };
}

/// Inverse document frequency, smoothed: `ln((N+1)/(df+1)) + 1`. The textbook
/// `ln(N/df)` is exactly 0 for a shingle every body holds, and in a corpus of
/// two bodies EVERY shared shingle is one — an unsmoothed index would go blind
/// on a two-file project (and on every unit test below). Smoothed, the ordering
/// is unchanged and the discount is still steep: on eda a shingle held once is
/// weighed 8.0 against 1.0 for one held by every body.
fn idf(docs: usize, frequency: u32) f64 {
    const n: f64 = @floatFromInt(docs);
    const d: f64 = @floatFromInt(frequency);
    return @log((n + 1) / (d + 1)) + 1;
}

/// Weighs every term `tf·idf` and L2-normalises each document, so the cosine
/// between two of them is a plain dot product. A body whose weights are all
/// zero cannot be normalised and simply pairs with nothing.
fn weighDocs(corpus: Corpus) void {
    for (corpus.docs) |terms| {
        var sum: f64 = 0;
        for (terms) |*t| {
            t.weight = @as(f64, @floatFromInt(t.tf)) * idf(corpus.docs.len, corpus.df[t.id]);
            sum += t.weight * t.weight;
        }
        if (sum == 0) continue;
        const norm = @sqrt(sum);
        for (terms) |*t| t.weight /= norm;
    }
}

/// True when a shingle may propose a pair: held by at least two bodies (one is
/// nothing to pair with) and by no more than `max_df` (above that it is
/// scaffolding). Note what this does to the measurement — the cosine the
/// accumulator computes omits those terms from the numerator while the norms
/// still hold them, so it is a LOWER bound on the true cosine. It can therefore
/// miss a pair, never invent one.
fn proposes(frequency: u32) bool {
    return frequency >= 2 and frequency <= max_df;
}

/// The inverted index in CSR form: `docs[starts[id]..starts[id+1]]` are the
/// bodies holding shingle `id`, ascending, with their weights alongside. A
/// shingle `proposes` rejects gets an empty range.
const Postings = struct {
    starts: []const u32,
    docs: []const u32,
    weights: []const f64,
};

/// Builds that index. Document frequency already IS each kept shingle's posting
/// count, so the offsets need no counting pass, and filling in document order
/// leaves every posting list ascending by document.
fn buildPostings(allocator: Allocator, corpus: Corpus) Allocator.Error!Postings {
    const starts = try allocator.alloc(u32, corpus.df.len + 1);
    var total: u32 = 0;
    for (corpus.df, 0..) |frequency, id| {
        starts[id] = total;
        if (proposes(frequency)) total += frequency;
    }
    starts[corpus.df.len] = total;

    const docs = try allocator.alloc(u32, total);
    const weights = try allocator.alloc(f64, total);
    const cursor = try allocator.alloc(u32, corpus.df.len);
    defer allocator.free(cursor);
    @memcpy(cursor, starts[0..corpus.df.len]);
    for (corpus.docs, 0..) |terms, i| {
        for (terms) |t| {
            if (!proposes(corpus.df[t.id])) continue;
            docs[cursor[t.id]] = @intCast(i);
            weights[cursor[t.id]] = t.weight;
            cursor[t.id] += 1;
        }
    }
    return .{ .starts = starts, .docs = docs, .weights = weights };
}

/// Every pair of documents whose truncated tf-idf cosine reaches `floor`, as
/// `[i, j]` with `i < j`, ascending — the pairs v2 PROPOSES, before any of them
/// is judged. One reused score row per document keeps this sparse: only the
/// documents actually reached through a shared rare shingle are touched, so two
/// bodies with nothing rare in common cost nothing at all.
fn cosinePairs(
    allocator: Allocator,
    corpus: Corpus,
    postings: Postings,
    floor: f64,
) Allocator.Error![]const [2]u32 {
    const scores = try allocator.alloc(f64, corpus.docs.len);
    defer allocator.free(scores);
    // Which row a score belongs to, so `touched` needs no clearing pass and a
    // stale score can never be read as a live one. `docs.len` is never a row
    // index, so it is the "no row yet" stamp.
    const stamp = try allocator.alloc(usize, corpus.docs.len);
    defer allocator.free(stamp);
    @memset(stamp, corpus.docs.len);
    var touched: std.ArrayList(u32) = .empty;
    defer touched.deinit(allocator);
    var out: std.ArrayList([2]u32) = .empty;

    for (corpus.docs, 0..) |terms, i| {
        touched.clearRetainingCapacity();
        for (terms) |t| {
            if (!proposes(corpus.df[t.id])) continue;
            const from = postings.starts[t.id];
            const to = postings.starts[t.id + 1];
            for (postings.docs[from..to], postings.weights[from..to]) |j, w| {
                if (j <= i) continue;
                if (stamp[j] != i) {
                    stamp[j] = i;
                    scores[j] = 0;
                    try touched.append(allocator, j);
                }
                scores[j] += t.weight * w;
            }
        }
        std.mem.sort(u32, touched.items, {}, std.sort.asc(u32));
        for (touched.items) |j| {
            if (scores[j] >= floor) try out.append(allocator, .{ @intCast(i), j });
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── The pairing pass ────────────────────────────────────────────────────

/// What one whole-tree pass found: the drifted pairs in source order, plus how
/// many pairs were left uncompared because a body exceeded `max_lines`.
const Analysis = struct {
    twins: []const Twin,
    oversize: u32,
};

/// Every drifted twin across an already-parsed set of files. The tf-idf index
/// proposes the pairs — no name is consulted — and the LCS above judges the
/// ones it proposes. The index is what keeps a 510k-line tree cheap: the
/// quadratic comparison only ever runs on bodies that already share a rare
/// shingle.
fn analyzeIndex(
    allocator: Allocator,
    files: []const ast_index.Entry,
    cfg: config.TwinDriftCfg,
) Allocator.Error!Analysis {
    var candidates: std.ArrayList(Candidate) = .empty;
    for (files) |*entry| try collectFile(allocator, entry, cfg, &candidates);

    const corpus = try buildCorpus(allocator, candidates.items);
    weighDocs(corpus);
    const postings = try buildPostings(allocator, corpus);
    const proposed = try cosinePairs(allocator, corpus, postings, cfg.pair_similarity);

    var out: std.ArrayList(Twin) = .empty;
    var oversize: u32 = 0;
    for (proposed) |pair| {
        const a = candidates.items[pair[0]];
        const b = candidates.items[pair[1]];
        if (std.mem.eql(u8, a.file, b.file)) continue;
        if (a.exempt or b.exempt) continue;
        if (a.body.len > cfg.max_lines or b.body.len > cfg.max_lines) {
            oversize += 1;
            continue;
        }
        const twin = try measure(allocator, a, b, cfg) orelse continue;
        try out.append(allocator, twin);
    }
    return .{ .twins = try out.toOwnedSlice(allocator), .oversize = oversize };
}

// ── Reporting ───────────────────────────────────────────────────────────

/// The blocking violation for one drifted pair. `identity` is both names under
/// both paths, ordered by path, and carries no measurement — so editing either
/// copy further, which moves the percentage and the line counts, leaves a
/// consumer's baseline row exactly where it was. A renamed copy DOES re-key,
/// which is right: after a rename it is a different pair of functions.
fn violationFor(allocator: Allocator, t: Twin) Allocator.Error!reporter.Violation {
    // The second name is named only when it differs — for the same-name pairs
    // that were all v1 could see, the message reads exactly as it did.
    const second = if (std.mem.eql(u8, t.a.name, t.b.name))
        ""
    else
        try std.fmt.allocPrint(allocator, "fn {s} ", .{t.b.name});
    const message = try std.fmt.allocPrint(
        allocator,
        "twin-drift: fn {s} ({d} lines) and {s}:{d} {s}({d} lines) share {d}% of their body " ++
            "and differ in {d} line(s){s} \u{2014} reconcile the two copies or lift the shared " ++
            "part into one fn (// twin-drift-ok: <why> if the divergence is deliberate)",
        .{
            t.a.name,  t.a.body.len, t.b.file,
            t.b.line,  second,       t.b.body.len,
            t.percent, t.differing,  if (t.declaredMirror()) " (declared mirror)" else "",
        },
    );
    return .{
        .check = check_name,
        .file = t.a.file,
        .line = t.a.line,
        .message = message,
        .fix_hint = fix_hint,
        .identity = try std.fmt.allocPrint(
            allocator,
            "{s}|{s}|{s}|{s}",
            .{ t.a.name, t.a.file, t.b.name, t.b.file },
        ),
        .metric = t.percent,
    };
}

/// The advisory line naming WHAT drifted: up to four lines that one copy has
/// and the other does not. It rides `reporter.warn` because baselines and
/// ratchets exclude the advisory channel by construction — the sample changes
/// with every edit to either body, and no consumer should ever have to accept
/// it. Null when the two bodies hold the same lines in a different order, which
/// the sample cannot show.
fn detailFor(allocator: Allocator, t: Twin) Allocator.Error!?reporter.Violation {
    const raw_a = try onlyIn(allocator, t.a, t.b);
    const raw_b = try onlyIn(allocator, t.b, t.a);
    if (raw_a.len == 0 and raw_b.len == 0) return null;
    // Prefer the lines that are new content over the ones that are the same
    // code re-wrapped; fall back to the raw sets when re-wrapping is ALL that
    // differs, so the sample is never empty for a pair that does differ.
    const kept_a = try newLines(allocator, raw_a, raw_b);
    const kept_b = try newLines(allocator, raw_b, raw_a);
    const only_a = if (kept_a.len + kept_b.len == 0) raw_a else kept_a;
    const only_b = if (kept_a.len + kept_b.len == 0) raw_b else kept_b;
    var buf: std.ArrayList(u8) = .empty;
    try appendFmt(allocator, &buf, "twin-drift: fn {s} \u{2014}", .{t.a.name});
    // Half the room to each side when both drifted, so a long one-sided list
    // cannot crowd the other copy's lines out of the sample entirely.
    const shown_a = try appendSide(allocator, &buf, t.a.file, only_a, if (only_b.len == 0)
        max_detail_lines
    else
        max_detail_lines / 2);
    const shown = shown_a + try appendSide(allocator, &buf, t.b.file, only_b, max_detail_lines - shown_a);
    const total = only_a.len + only_b.len;
    if (total > shown) try appendFmt(allocator, &buf, " (+{d} more)", .{total - shown});
    return .{ .check = check_name, .file = t.a.file, .line = t.a.line, .message = try buf.toOwnedSlice(allocator) };
}

/// Appends one formatted fragment to a growing message.
fn appendFmt(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try buf.appendSlice(allocator, text);
}

/// Appends ``only in <file>: `line`, `line`;`` for up to `room` lines,
/// returning how many it wrote.
fn appendSide(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    file: []const u8,
    lines: []const []const u8,
    room: usize,
) Allocator.Error!usize {
    const shown = @min(lines.len, room);
    if (shown == 0) return 0;
    try appendFmt(allocator, buf, " only in {s}:", .{file});
    for (lines[0..shown], 0..) |line, i| {
        try appendFmt(allocator, buf, "{s} `{s}`", .{ if (i == 0) "" else ",", line });
    }
    try buf.append(allocator, ';');
    return shown;
}

/// The differing lines of `mine` that are genuinely new content. A line the
/// other copy holds *inside* one of ITS differing lines is the same code
/// re-wrapped across two source lines, not something one copy never got — and
/// the re-wrap sorts first in body order, which is what pushed the motivating
/// pair's four new rule fields out of the sample.
fn newLines(
    allocator: Allocator,
    mine: []const []const u8,
    theirs: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (mine) |line| {
        if (fragmentOfAny(line, theirs)) continue;
        try out.append(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

/// True when `line` appears inside a strictly longer line of `others`.
fn fragmentOfAny(line: []const u8, others: []const []const u8) bool {
    for (others) |other| {
        if (other.len > line.len and std.mem.indexOf(u8, other, line) != null) return true;
    }
    return false;
}

/// True when a normalised line says something a reader can act on. A line of
/// pure structure (`}`, `});`, `.{`) differs between two copies whenever one of
/// them wraps an expression differently, and showing those first is what buried
/// the actual payload of the motivating eda pair — four new rule fields — under
/// a brace the formatter moved.
fn informative(line: []const u8) bool {
    for (line) |c| {
        if (std.mem.indexOfScalar(u8, "{}()[];,. ", c) == null) return true;
    }
    return false;
}

/// The normalised lines `have` holds more often than `other` does — the part of
/// one copy the other never got, structure-only lines dropped. A bag
/// difference, so a line that merely MOVED inside the body is not reported as a
/// difference.
fn onlyIn(allocator: Allocator, have: Candidate, other: Candidate) Allocator.Error![]const []const u8 {
    var counts: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer counts.deinit(allocator);
    for (other.hashes) |h| {
        const gop = try counts.getOrPut(allocator, h);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (have.hashes, 0..) |h, i| {
        if (counts.getPtr(h)) |slot| {
            if (slot.* > 0) {
                slot.* -= 1;
                continue;
            }
        }
        if (informative(have.body[i])) try out.append(allocator, have.body[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// The indexed files this check reads: everything except the paths an
/// `[[allow]] check = "twin-drift"` entry exempts.
fn allowedFiles(
    allocator: Allocator,
    files: []const ast_index.Entry,
    skip: []const []const u8,
) Allocator.Error![]const ast_index.Entry {
    if (skip.len == 0) return files;
    var kept: std.ArrayList(ast_index.Entry) = .empty;
    for (files) |entry| {
        if (lexical_scan.skipPath(skip, entry.rel_path)) continue;
        try kept.append(allocator, entry);
    }
    return kept.toOwnedSlice(allocator);
}

/// Entry point for the twin-drift check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    const files = try allowedFiles(allocator, idx.files, ctx.cfg.extraAllowed(check_name));
    const found = try analyzeIndex(allocator, files, ctx.cfg.twin_drift);
    if (found.oversize > 0) reporter.warn(.{
        .check = check_name,
        .message = try std.fmt.allocPrint(
            allocator,
            "{d} pair(s) not compared: a body exceeds [twin_drift] max_lines = {d}",
            .{ found.oversize, ctx.cfg.twin_drift.max_lines },
        ),
    });
    if (found.twins.len == 0) {
        reporter.ok("twin-drift: no copied function body has drifted from its twin", .{});
        return;
    }
    reporter.fail("twin-drift FAILED ({d} drifted pair(s))", .{found.twins.len});
    for (found.twins) |t| {
        reporter.emitQuiet(try violationFor(allocator, t));
        if (try detailFor(allocator, t)) |d| reporter.warn(d);
    }
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

/// A `pub fn parseRule` whose body is `lines` — the shape every pairing test
/// needs, with the one part under test spelled by the caller.
fn ruleSource(a: Allocator, prefix: []const u8, lines: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}pub fn parseRule(v: u32) u32 {{\n{s}}}\n", .{ prefix, lines }, 0);
}

/// A body of pure scaffolding — the shape a tree writes over and over, which is
/// what makes its shingles common and its agreement meaningless.
const scaffold_body =
    \\    var out: u32 = 0;
    \\    const a0 = p0;
    \\    const a1 = p1;
    \\    const a2 = p2;
    \\    const a3 = p3;
    \\    const a4 = p4;
    \\    const a5 = p5;
    \\    const a6 = p6;
    \\
;

/// Parses a list of `(path, source)` pairs into the index entries the pure core
/// consumes.
fn entriesOf(a: Allocator, sources: []const [2][]const u8) ![]const ast_index.Entry {
    var files: std.ArrayList(ast_index.Entry) = .empty;
    for (sources) |src| {
        try files.append(a, try testEntry(a, src[0], try a.dupeSentinel(u8, src[1], 0)));
    }
    return files.toOwnedSlice(a);
}

/// The same shape under another function name, for the pairing v1 could not do.
fn renamedSource(a: Allocator, name: []const u8, lines: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "pub fn {s}(v: u32) u32 {{\n{s}}}\n", .{ name, lines }, 0);
}

/// The eight-line body the min_statements floor admits, as a baseline both
/// sides of a pairing test start from.
const base_body =
    \\    var out: u32 = 0;
    \\    out += v;
    \\    out += 1;
    \\    out += 2;
    \\    out += 3;
    \\    out += 4;
    \\    out += 5;
    \\    return out;
    \\
;

fn analyzeSources(
    a: Allocator,
    sources: []const [2][]const u8,
    cfg: config.TwinDriftCfg,
) !Analysis {
    var files: std.ArrayList(ast_index.Entry) = .empty;
    for (sources) |s| {
        const z = try a.dupeSentinel(u8, s[1], 0);
        try files.append(a, try testEntry(a, s[0], z));
    }
    return analyzeIndex(a, files.items, cfg);
}

// spec: Twin Drift - Normalizes a body by dropping comments and blank lines and collapsing whitespace

test "twin-drift: normalizeBody drops comments and blanks and collapses whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\{
        \\    // a comment line
        \\
        \\    const url = "http://x"; // trailing note
        \\        const  wide   =  1;
        \\}
    ;
    const lines = try normalizeBody(a, body);
    try testing.expectEqual(@as(usize, 2), lines.len);
    // The `//` inside the string literal is not a comment; the trailing one is.
    try testing.expectEqualStrings("const url = \"http://x\";", lines[0]);
    try testing.expectEqualStrings("const wide = 1;", lines[1]);
}

// spec: Twin Drift - Measures overlap as twice the longest common subsequence over both body lengths

test "twin-drift: lcsLength finds the longest common subsequence, not a common prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = [_]u64{ 1, 2, 3, 4, 5 };
    const right = [_]u64{ 9, 1, 3, 8, 5 };
    // 1,3,5 is common in order; a prefix comparison would answer 0.
    try testing.expectEqual(@as(u32, 3), try lcsLength(a, &left, &right));
    try testing.expectEqual(@as(u32, 5), try lcsLength(a, &left, &left));
    // 2*3/(5+5) is exactly the 0.6 default: the floor is inclusive.
    try testing.expectEqual(@as(u32, 60), sharePercent(3, 5, 5));
    try testing.expect(reaches(0.6, 3, 5, 5));
    try testing.expect(!reaches(0.61, 3, 5, 5));
}

// spec: Twin Drift - Skips a body shorter than the configured statement floor

test "twin-drift: a body under min_statements is never paired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const short = "pub fn parseRule(v: u32) u32 {\n    return v + 1;\n}\n";
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", short },
        .{ "src/b.zig", "pub fn parseRule(v: u32) u32 {\n    return v + 2;\n}\n" },
    }, .{});
    try testing.expectEqual(@as(usize, 0), found.twins.len);
}

// spec: Twin Drift - Stays silent on identical copies unless report_identical asks for them

test "twin-drift: an identical pair is silent by default and reported on request" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try ruleSource(a, "", base_body);
    const sources = [_][2][]const u8{ .{ "src/a.zig", src }, .{ "src/b.zig", src } };
    try testing.expectEqual(@as(usize, 0), (try analyzeSources(a, &sources, .{})).twins.len);

    const found = try analyzeSources(a, &sources, .{ .report_identical = true });
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    try testing.expect(found.twins[0].identical);
    try testing.expectEqual(@as(u32, 100), found.twins[0].percent);
}

// spec: Twin Drift - Reports a drifted pair above the similarity floor and no pair below it

test "twin-drift: a drifted pair fires and a dissimilar pair does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const drifted = try ruleSource(a, "", base_body ++ "    // the copy that grew\n");
    const grown = try ruleSource(a, "",
        \\    var out: u32 = 0;
        \\    out += v;
        \\    out += 1;
        \\    out += 2;
        \\    out += 3;
        \\    out += 4;
        \\    out += 5;
        \\    out += 6;
        \\    return out;
        \\
    );
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", drifted },
        .{ "src/b.zig", grown },
    }, .{});
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    const t = found.twins[0];
    // Eight of nine lines shared: 2*8/17 = 94%, one line differing.
    try testing.expectEqual(@as(u32, 94), t.percent);
    try testing.expectEqual(@as(u32, 1), t.differing);
    const v = try violationFor(a, t);
    try testing.expectEqualStrings("parseRule|src/a.zig|parseRule|src/b.zig", v.identity.?);
    try testing.expect(std.mem.indexOf(u8, v.message, "share 94% of their body") != null);
    const detail = (try detailFor(a, t)).?;
    try testing.expect(std.mem.indexOf(u8, detail.message, "out += 6;") != null);

    // A body that shares only its scaffolding is under the floor and silent.
    const unrelated = try ruleSource(a, "",
        \\    var out: u32 = 0;
        \\    out *= 11;
        \\    out *= 12;
        \\    out *= 13;
        \\    out *= 14;
        \\    out *= 15;
        \\    out *= 16;
        \\    return out;
        \\
    );
    const quiet = try analyzeSources(a, &.{
        .{ "src/a.zig", drifted },
        .{ "src/b.zig", unrelated },
    }, .{});
    try testing.expectEqual(@as(usize, 0), quiet.twins.len);
}

// spec: Twin Drift - Names the lines one copy never got and passes over a re-wrapped one

test "twin-drift: the detail names new content rather than a re-wrapped line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const packed_call = try ruleSource(a, "",
        \\    var out: u32 = 0;
        \\    out += v;
        \\    out += 1;
        \\    out += 2;
        \\    out += 3;
        \\    out += 4;
        \\    out += add(v, 1);
        \\    return out;
        \\
    );
    // The same call re-wrapped over four lines, plus one line the first copy
    // never got. Only the second is worth a reader's attention.
    const wrapped_call = try ruleSource(a, "",
        \\    var out: u32 = 0;
        \\    out += v;
        \\    out += 1;
        \\    out += 2;
        \\    out += 3;
        \\    out += 4;
        \\    out += add(
        \\        v,
        \\        1,
        \\    );
        \\    out += 7;
        \\    return out;
        \\
    );
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", packed_call },
        .{ "src/b.zig", wrapped_call },
    }, .{});
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    const detail = (try detailFor(a, found.twins[0])).?;
    try testing.expect(std.mem.indexOf(u8, detail.message, "`out += 7;`") != null);
    // `v,` is the first copy's own line, split — not something it never got.
    try testing.expect(std.mem.indexOf(u8, detail.message, "`v,`") == null);
}

// spec: Twin Drift - Silences a pair annotated twin-drift-ok above either copy

test "twin-drift: a twin-drift-ok annotation above one copy silences the pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try ruleSource(a, "", base_body ++ "    out += 9;\n");
    const marked = try ruleSource(a, "// twin-drift-ok: the wasm bridge clamps differently on purpose\n", base_body);
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", plain },
        .{ "src/b.zig", marked },
    }, .{});
    try testing.expectEqual(@as(usize, 0), found.twins.len);
}

// spec: Twin Drift - Silences a function name the ignore list holds

test "twin-drift: an ignored name is never paired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = try ruleSource(a, "", base_body ++ "    out += 9;\n");
    const right = try ruleSource(a, "", base_body);
    const cfg: config.TwinDriftCfg = .{ .ignore = &.{"parseRule"} };
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", left },
        .{ "src/b.zig", right },
    }, cfg);
    try testing.expectEqual(@as(usize, 0), found.twins.len);
}

// spec: Twin Drift - Reads a struct member function as a candidate like a top-level one

test "twin-drift: a member fn is a candidate beside a top-level fn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const member = try std.fmt.allocPrintSentinel(a,
        \\pub const Rules = struct {{
        \\    pub fn parseRule(v: u32) u32 {{
        \\{s}    }}
        \\}};
        \\
    , .{base_body ++ "    // grew here\n    "}, 0);
    const top = try ruleSource(a, "", base_body ++ "    out += 7;\n");
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", member },
        .{ "src/b.zig", top },
    }, .{});
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    try testing.expectEqualStrings("parseRule", found.twins[0].a.name);
}

// spec: Twin Drift - Names a declared mirror in the message without exempting it

test "twin-drift: a declared mirror is reported and says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const claimed = try ruleSource(a, "/// Mirrors src/a.zig's parser, kept in sync by hand.\n", base_body);
    const other = try ruleSource(a, "", base_body ++ "    out += 8;\n");
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", other },
        .{ "src/b.zig", claimed },
    }, .{});
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    try testing.expect(found.twins[0].declaredMirror());
    const v = try violationFor(a, found.twins[0]);
    try testing.expect(std.mem.indexOf(u8, v.message, "(declared mirror)") != null);
}

// spec: Twin Drift - Skips a private helper only test blocks reach

test "twin-drift: a private helper reached only from tests is not a twin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `fixture` is private and named only inside a test block (through a second
    // private helper, so the exclusion has to be transitive); `parseRule` is pub.
    const file =
        \\fn fixture(v: u32) u32 {{
        \\{s}}}
        \\fn wrap(v: u32) u32 {{ return fixture(v); }}
        \\test "uses it" {{ _ = wrap(1); }}
        \\
    ;
    const left = try std.fmt.allocPrintSentinel(a, file, .{base_body}, 0);
    const right = try std.fmt.allocPrintSentinel(a, file, .{base_body ++ "    // drifted\n"}, 0);
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", left },
        .{ "src/b.zig", right },
    }, .{ .report_identical = true });
    try testing.expectEqual(@as(usize, 0), found.twins.len);
}

// spec: Twin Drift - Keys a pair by both names under both paths ordered by path

test "twin-drift: identity carries both names and both paths, ordered by path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = try ruleSource(a, "", base_body ++ "    out += 9;\n");
    const renamed = try renamedSource(a, "readRule", base_body);
    // The later path is stated FIRST, so ordering by path is what puts a.zig on
    // the left of the key rather than the order the files happened to arrive in.
    const found = try analyzeSources(a, &.{
        .{ "src/b.zig", renamed },
        .{ "src/a.zig", left },
    }, .{});
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    const v = try violationFor(a, found.twins[0]);
    try testing.expectEqualStrings("parseRule|src/a.zig|readRule|src/b.zig", v.identity.?);

    // Editing either body further moves the measurement, never the key.
    const after = try analyzeSources(a, &.{
        .{ "src/a.zig", left },
        .{ "src/b.zig", try renamedSource(a, "readRule", base_body ++ "    out += 4;\n") },
    }, .{});
    try testing.expect(found.twins[0].percent != after.twins[0].percent);
    try testing.expectEqualStrings(v.identity.?, (try violationFor(a, after.twins[0])).identity.?);
}

// spec: Twin Drift - Maps every string, character and number literal to one placeholder token

test "twin-drift: shingles read past the literals a copy reworded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = [_][]const u8{ "try w.writeAll(\"expected a net\");", "count += 12;", "if (c == 'x') return;" };
    const second = [_][]const u8{ "try w.writeAll(\"no net here\");", "count += 9_000;", "if (c == 'q') return;" };
    // Same code, every literal reworded: the shingles come out byte-identical.
    try testing.expectEqualSlices(u64, try bodyShingles(a, &first), try bodyShingles(a, &second));
    // An identifier is NOT collapsed, so renaming one really does move shingles.
    const renamed = [_][]const u8{ "try w.writeAll(\"expected a net\");", "total += 12;", "if (c == 'x') return;" };
    try testing.expect(!std.mem.eql(u64, try bodyShingles(a, &first), try bodyShingles(a, &renamed)));
}

// spec: Twin Drift - Weighs a shingle by inverse document frequency so a common one counts for less

test "twin-drift: idf falls as a shingle spreads across more bodies" {
    // Rare beats common, monotonically, and a shingle every body holds still
    // carries a floor rather than 0 — an unsmoothed idf is exactly 0 there, and
    // in a two-body corpus EVERY shared shingle is one, so nothing would pair.
    try testing.expect(idf(100, 1) > idf(100, 10));
    try testing.expect(idf(100, 10) > idf(100, 100));
    try testing.expect(idf(100, 100) > 0);
    try testing.expect(idf(2, 2) > 0);
}

// spec: Twin Drift - Refuses to pair two bodies whose only overlap is scaffolding the tree repeats

test "twin-drift: a scaffolding-only overlap is under the pair floor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sources: std.ArrayList([2][]const u8) = .empty;
    // Ten other files write the same scaffolding, which is what MAKES it
    // scaffolding: idf discounts it and the pair loses its only common ground.
    // Each filler carries twelve lines of its own as well, so no filler is
    // itself a twin of anything — only the scaffolding's frequency is at issue.
    for (0..10) |i| {
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, scaffold_body);
        for (0..12) |k| {
            const line = try std.fmt.allocPrint(
                a,
                "    out = f{d}_{d}(v) + g{d}_{d}(v) * h{d}_{d}(v) - j{d}_{d}(v);\n",
                .{ i, k, i, k, i, k, i, k },
            );
            try body.appendSlice(a, line);
        }
        const name = try std.fmt.allocPrint(a, "src/filler{d}.zig", .{i});
        try sources.append(a, .{ name, try renamedSource(a, "sweep", body.items) });
    }
    try sources.append(a, .{
        "src/left.zig",
        try renamedSource(a, "collectLeft", scaffold_body ++
            \\    out += widthOf(v);
            \\    out += heightOf(v);
            \\    out += depthOf(v);
            \\
        ),
    });
    try sources.append(a, .{
        "src/right.zig",
        try renamedSource(a, "collectRight", scaffold_body ++
            \\    out -= angleOf(v);
            \\    out -= radiusOf(v);
            \\    out -= chordOf(v);
            \\
        ),
    });
    const found = try analyzeIndex(a, try entriesOf(a, sources.items), .{});
    try testing.expectEqual(@as(usize, 0), found.twins.len);
    // The LCS the judgement uses would have said yes — 8 of 11 lines are shared
    // — so it is the pair floor, not the similarity floor, keeping this quiet.
    const wide = try analyzeIndex(a, try entriesOf(a, sources.items), .{ .pair_similarity = 0.01 });
    try testing.expect(wide.twins.len > 0);
}

// spec: Twin Drift - Pairs a copy that was renamed, function and parameter alike

test "twin-drift: a renamed copy with a renamed parameter still pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try ruleSource(a, "", base_body ++ "    out += 9;\n");
    // Another function name, another parameter spelling, and one line the copy
    // never got. v1 saw nothing here at all.
    const copy =
        \\pub fn readRule(n: u32) u32 {
        \\    var out: u32 = 0;
        \\    out += n;
        \\    out += 1;
        \\    out += 2;
        \\    out += 3;
        \\    out += 4;
        \\    out += 5;
        \\    return out;
        \\}
        \\
    ;
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", original },
        .{ "src/b.zig", copy },
    }, .{});
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    const v = try violationFor(a, found.twins[0]);
    // Both names are on the line, because neither one identifies the pair alone.
    try testing.expect(std.mem.indexOf(u8, v.message, "fn parseRule") != null);
    try testing.expect(std.mem.indexOf(u8, v.message, "src/b.zig:1 fn readRule") != null);
}

// spec: Twin Drift - Proposes no pair below the configured pair floor

test "twin-drift: raising pair_similarity withdraws a pair the LCS would report" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_][2][]const u8{
        .{ "src/a.zig", try ruleSource(a, "", base_body ++ "    out += 9;\n") },
        .{ "src/b.zig", try renamedSource(a, "readRule", base_body) },
    };
    try testing.expectEqual(@as(usize, 1), (try analyzeSources(a, &sources, .{})).twins.len);
    // Nothing about the pair moved but the floor it has to clear.
    const strict = try analyzeSources(a, &sources, .{ .pair_similarity = 0.999 });
    try testing.expectEqual(@as(usize, 0), strict.twins.len);
}

// spec: Twin Drift - Never reaches a body that shares no shingle rare enough to propose a pair

test "twin-drift: the index proposes only pairs that share a rare shingle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one: Candidate = .{
        .file = "src/a.zig",
        .name = "a",
        .line = 1,
        .body = &.{ "const seat = rowOf(v);", "return seat + 1;" },
        .hashes = &.{},
        .exempt = false,
        .mirror = false,
    };
    var twin = one;
    twin.file = "src/b.zig";
    var alien = one;
    alien.file = "src/c.zig";
    alien.body = &.{ "while (n < cap) n *= 3;", "emit(n);" };
    const candidates = [_]Candidate{ one, twin, alien };

    const corpus = try buildCorpus(a, &candidates);
    weighDocs(corpus);
    const pairs = try cosinePairs(a, corpus, try buildPostings(a, corpus), 0.000_1);
    // Floored at almost nothing, the third body is still never scored: it shares
    // no shingle with either of the others, so the index never reaches it.
    try testing.expectEqual(@as(usize, 1), pairs.len);
    try testing.expectEqual(@as(u32, 0), pairs[0][0]);
    try testing.expectEqual(@as(u32, 1), pairs[0][1]);
}

// spec: Twin Drift - Leaves a pair uncompared when a body exceeds max_lines

test "twin-drift: a body over max_lines is counted rather than compared" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const left = try ruleSource(a, "", base_body ++ "    out += 9;\n");
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", left },
        .{ "src/b.zig", try ruleSource(a, "", base_body) },
    }, .{ .max_lines = 4 });
    try testing.expectEqual(@as(usize, 0), found.twins.len);
    try testing.expectEqual(@as(u32, 1), found.oversize);
}
