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
//!
//! **The drift sample is filtered against this check's own baseline.** Each
//! pair reports twice: a `reporter.emit` Violation the baseline layer can
//! freeze, and an advisory `reporter.warn` naming the lines only one copy has.
//! The advisory channel is excluded from baselines by construction — that is
//! what makes it survive baseline mode's capture-and-replace — so nothing
//! downstream could subtract it, and a project that froze its whole backlog
//! kept being told about it on every run (measured in eda: 125 frozen pairs,
//! `--list` reading `NEW (0) / LIVE (125)`, and a cold gate still printing
//! `twin-drift: 124 finding(s) — report-only` plus 124 `warning:` lines).
//!
//! Of the two available fixes, this check consults the baseline itself
//! (`frozenPairs` → `detailFor`) rather than moving the sample onto the console
//! through the Violation's `fix_hint`. `fix_hint` would have been filtered for
//! free, but on the text path it would also have been INVISIBLE: this check
//! reports through `emitQuiet`, whose printed line drops the hint by design
//! (one shared `fix:` line beneath the list is the console contract), and
//! baseline mode replays a NEW violation as its stored `flatLine`, which
//! carries no hint either. Consulting the baseline is also the smaller change
//! and moves no identity key: `identityFor` is untouched, so a consumer's
//! frozen rows stay LIVE.
//!
//! **The idf table is FROZEN, because a live one moves every score at once.**
//! `idf(s) = ln((N+1)/(df+1)) + 1` is a function of the whole corpus, so adding
//! or deleting a body ANYWHERE re-weighs every shingle in the tree — measured on
//! eda across five merges: 128 of 174 untouched surviving pairs (74%) changed
//! score without either of their own files being edited, and one pair crossed
//! the 0.5 floor into a blocking row in two files no branch had opened
//! (`docs/twin-drift-scoring-study-2026-09-02.md`). Removing the idf is not the
//! fix — it IS the discriminator, and every corpus-independent weighting
//! measured gave back the separation that rejects `padNets` at 0.44. So the
//! weighting stays and the TABLE is pinned: `.guardian/twin-drift-df.txt` holds
//! the document count and the per-shingle frequency of the corpus as it stood
//! at the last `accept twin-drift`, and every score decision reads that instead
//! of the tree in front of it. A shingle the table has never seen — one a change
//! just introduced — falls back to its live frequency. With no table the check
//! behaves exactly as it did before one existed, so a zero-config project
//! notices nothing.
//!
//! Both halves of the decision are frozen, the weight AND `proposes`: the
//! proposal gate is `2 <= df <= max_df`, so a boilerplate 3-gram drifting across
//! `max_df` adds or removes real mass from an untouched pair's cosine. Freezing
//! only the weight still let the eda pair cross. What stays live is the posting
//! COUNT, because a posting list has to be exactly as long as the number of
//! bodies written into it. Two bodies that did not change therefore score
//! bit-identically however the rest of the tree moved — replayed over the
//! study's six eda states, a table frozen at the first reproduces the study's
//! frozen-idf column exactly (125/85/49/31/14/0) five merges later.
//!
//! Freezing is not a substitute for the diff-aware blocking below; the study is
//! explicit that it is the lesser of the two. It removes drift caused by
//! Guardian's own scoring. It does nothing about a pair that genuinely crosses
//! because a third file changed, and every refresh is a fresh chance for such a
//! pair to appear — which is what `Touched`/SURFACED is for.
//!
//! **The corpus is the whole tree on every run.** twin-drift is registered
//! `whole_tree`, so `run_all.indexFor` hands it the complete index even when the
//! surrounding run is diff-scoped, and `scope.Posture` refuses to scope a run
//! with a refresh pending. A diff-scoped run therefore reads the same corpus a
//! whole-tree one does — only which pairs BLOCK narrows — and no run that could
//! write a partial table exists.
//!
//! `fix_hint` still carries the sample for the OTHER reader. `last-run.jsonl`
//! has no advisory tier — a warning never reaches it — so `sinkHint` puts what
//! drifted on the row beside the remedy, and the baseline layer forwards it
//! only for a pair this run actually reported. Frozen debt is therefore silent
//! on both channels, and a NEW pair carries the sample on both.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_decls = @import("../ast/decls.zig");
const ast_index = @import("../ast/index.zig");
const baseline = @import("../baseline.zig");
const violation_key = @import("../violation_key.zig");
const config = @import("../config.zig");
const scope = @import("../scope.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
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
/// ascending by id, plus — per vocabulary id — the shingle it stands for and
/// the two document frequencies the pass reads.
///
/// The two frequencies are the whole of the freeze. `df` is what this run
/// MEASURED, and only `buildPostings` reads it, to size each posting list: a
/// list must be exactly as long as the number of bodies that will be written
/// into it, or the index is corrupt. `scoring_df` is what every DECISION reads
/// — the idf weight and `proposes` alike — and it is the frozen table's value
/// wherever the table has one. Keeping them apart is what lets a stale table
/// change the verdict without touching the index's shape.
///
/// `hashes` is what makes a frozen lookup possible at all: a vocabulary id is
/// an artifact of the order this run happened to intern shingles in and means
/// nothing across two runs, while the shingle hash is the same number in every
/// corpus that holds that 3-gram.
const Corpus = struct {
    docs: []const []Term,
    df: []const u32,
    scoring_df: []u32,
    hashes: []const u64,
    /// The document count the idf divides by — frozen with the table when there
    /// is one, else this run's own candidate count.
    scoring_docs: usize,
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
    var hashes: std.ArrayList(u64) = .empty;
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
                try hashes.append(allocator, s);
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
    const measured = try df.toOwnedSlice(allocator);
    return .{
        .docs = docs,
        .df = measured,
        // Live until `applyFrozen` says otherwise, so a project with no table
        // scores exactly as it did before the table existed.
        .scoring_df = try allocator.dupe(u32, measured),
        .hashes = try hashes.toOwnedSlice(allocator),
        .scoring_docs = candidates.len,
    };
}

/// Substitutes the frozen table into everything that DECIDES: the document
/// count and, per shingle, the frequency both the idf and `proposes` read. A
/// shingle the table does not hold keeps its live frequency.
///
/// Nothing here touches `Corpus.df`, so `buildPostings` still allocates against
/// the tree in front of it. What changes is which shingles are allowed to
/// propose and how heavily each one counts — and because BOTH are frozen, two
/// bodies that did not change get a bit-identical score however the rest of the
/// tree moved. Freezing only the weight is not enough: `proposes` gates a
/// shingle on `df <= max_df`, so a boilerplate 3-gram drifting across that line
/// adds or removes real mass from an untouched pair's cosine. Measured on eda's
/// six states, weight-only freezing still let `module_policy.stripUpper` cross
/// the floor at state 2 in two files nothing had touched — the exact failure
/// the freeze exists to remove.
fn applyFrozen(corpus: *Corpus, frozen: ?FrozenDf) void {
    const table = frozen orelse return;
    corpus.scoring_docs = table.docs;
    for (corpus.scoring_df, corpus.hashes) |*frequency, hash| {
        frequency.* = table.df.get(dfKey(hash)) orelse frequency.*;
    }
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
/// zero cannot be normalised and simply pairs with nothing. Reads the scoring
/// frequencies, so a frozen table decides the weights (see `applyFrozen`).
fn weighDocs(corpus: Corpus) void {
    for (corpus.docs) |terms| {
        var sum: f64 = 0;
        for (terms) |*t| {
            t.weight = @as(f64, @floatFromInt(t.tf)) *
                idf(corpus.scoring_docs, corpus.scoring_df[t.id]);
            sum += t.weight * t.weight;
        }
        if (sum == 0) continue;
        const norm = @sqrt(sum);
        for (terms) |*t| t.weight /= norm;
    }
}

// ── The frozen df table ─────────────────────────────────────────────────

/// Where the frozen table lives, beside the baselines it stabilises.
const df_leaf = "twin-drift-df.txt";

/// Its snapshot header version. Distinct from every other `.guardian/` format
/// (v1/v2 counters, v2 ratchets and pub-api, v3 identity baselines) so the
/// merge driver can classify the file from its header alone when git hands it
/// three temporaries and no pathname.
const df_version: u32 = 4;

/// The row that carries the frozen document count. Four characters, where every
/// shingle row's first field is exactly `df_key_len`, so the two can never be
/// confused whatever order the file is sorted into.
const df_docs_field = "docs";

/// The df a row with no count spells. `1` is the overwhelming majority of any
/// corpus's vocabulary (eda: 179,539 of 264,931 shingles), and writing it out
/// would be a third of the file spent repeating the same character.
const df_implicit: u32 = 1;

/// Bits of the 64-bit shingle hash a row stores, and the base-36 width that
/// holds them (36^8 > 2^41). Truncating is a size decision with a measurable
/// error bar: over eda's 264,931 shingles the expected number of distinct
/// 3-grams sharing a stored key is 16 — 0.006% of the vocabulary — and a
/// collision costs those shingles one merged frequency, never a crash, a
/// missed pair, or a non-deterministic file.
const df_key_bits = 41;
const df_key_len = 8;
const df_key_mask: u64 = (@as(u64, 1) << df_key_bits) - 1;

/// The stored key of a shingle hash.
fn dfKey(hash: u64) u64 {
    return hash & df_key_mask;
}

/// A committed df table: the document count that was frozen with it, and the df
/// of every shingle it kept. Absent shingles are NOT recorded as zero — they are
/// absent, and `weighingDf` falls back to the live count for them.
const FrozenDf = struct {
    docs: usize,
    df: std.AutoHashMapUnmanaged(u64, u32),
};

/// `<project>/.guardian/twin-drift-df.txt`.
fn dfPath(allocator: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return snapshot_helper.snapshotPath(allocator, project_dir, df_leaf);
}

/// One stored key as base-36, zero-padded to a fixed width so the file sorts
/// stably and a row's two fields can be told apart by length alone.
fn encodeDfKey(key: u64) [df_key_len]u8 {
    var out: [df_key_len]u8 = @splat('0');
    var rest = key;
    var i: usize = df_key_len;
    while (i > 0) {
        i -= 1;
        const digit: u8 = @intCast(rest % 36);
        out[i] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        rest /= 36;
    }
    return out;
}

/// The key a stored field spells, or null when it is not one — a wrong width, a
/// character outside base-36, or a value past `df_key_bits`.
fn decodeDfKey(text: []const u8) ?u64 {
    if (text.len != df_key_len) return null;
    var value: u64 = 0;
    for (text) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            else => return null,
        };
        value = value * 36 + digit;
    }
    return if (value > df_key_mask) null else value;
}

/// The committed table, or null when this project has none (the zero-config
/// case: scoring then reads live df exactly as it always has).
///
/// A file that is present but unreadable — a stale version, a broken row, a
/// missing `docs` header — is NOT silently ignored: it warns once, naming the
/// file and the command that rewrites it, and then falls back to live df. A
/// frozen table is a scoring input, so degrading quietly would move every score
/// with nothing on the console to explain why.
fn loadFrozenDf(allocator: Allocator, project_dir: []const u8) Allocator.Error!?FrozenDf {
    const path = try dfPath(allocator, project_dir);
    // The BYTES rather than `snapshot.read`, because the merge driver's
    // regenerate marker is a comment and every parser here drops comments — so
    // a table that a merge resolved instead of measuring would otherwise be
    // indistinguishable from one an accept had just written.
    const content = fs.cwd().readFileAlloc(allocator, path, max_df_bytes) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return warnUnusableDf(allocator, path, "it could not be read"),
    };
    const snap = snapshot.parse(allocator, content, df_version) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return warnUnusableDf(allocator, path, describeDfError(e)),
    };
    const table = try parseFrozenDf(allocator, path, snap.lines) orelse return null;
    if (snapshot.hasRegenMarker(content)) try warnMergedDf(allocator, path);
    return table;
}

/// Upper bound on a frozen table this check will read — the same ceiling every
/// other `.guardian/` reader uses. eda's is 2.5 MB, so the headroom is real.
const max_df_bytes = 16 * 1024 * 1024;

/// The one line a merge-resolved table earns.
///
/// `merge-file` cannot combine two frozen corpora, so it keeps OURS whole and
/// stamps `snapshot.regen_marker`. That result is a VALID freeze — it is one
/// branch's real measurement — so the table is still used and nothing fails.
/// But it describes the tree as that branch left it, not the merged tree in
/// front of the check, and the marker is a comment: `snapshot.parse` drops it
/// and every scoring decision below would read the stale table in silence. The
/// `merge-state` check does report the marker, but only on an `all` pass; a
/// direct `guardian-check twin-drift .` never sees it. So this says so once, on
/// the alert tier, where `--summary` cannot collapse it and `--list` replays it
/// above the listing.
fn warnMergedDf(allocator: Allocator, path: []const u8) Allocator.Error!void {
    reporter.warn(.{
        .check = check_name,
        .alert = true,
        .file = path,
        .message = try std.fmt.allocPrint(
            allocator,
            "{s}: the frozen df table {s} was resolved by a merge rather than measured (`{s}`) " ++
                "\u{2014} scoring uses it as it stands; `guardian-check accept {s} .` re-measures " ++
                "it on this tree",
            .{ check_name, df_leaf, snapshot.regen_marker, check_name },
        ),
    });
}

/// Why a stored table could not be read, in one clause.
fn describeDfError(e: snapshot.ReadError) []const u8 {
    return switch (e) {
        error.VersionMismatch => "it was written by a different Guardian format version",
        error.ConflictMarkers => "it still holds unresolved merge conflict markers",
        error.BadFormat => "its header is missing or malformed",
        else => "it could not be read",
    };
}

/// Turns already-parsed snapshot rows into a table, or warns and returns null.
fn parseFrozenDf(
    allocator: Allocator,
    path: []const u8,
    rows: []const []const u8,
) Allocator.Error!?FrozenDf {
    var docs: ?usize = null;
    var df: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    for (rows) |row| {
        const space = std.mem.indexOfScalar(u8, row, ' ');
        const field = if (space) |s| row[0..s] else row;
        const value = if (space) |s| row[s + 1 ..] else "";
        if (std.mem.eql(u8, field, df_docs_field)) {
            docs = std.fmt.parseInt(usize, value, 10) catch
                return warnUnusableDf(allocator, path, "its `docs` count is not a number");
            continue;
        }
        const key = decodeDfKey(field) orelse
            return warnUnusableDf(allocator, path, "a row's shingle key is not an 8-character base-36 word");
        // A bare key is the implicit df=1 row; anything else spells its count.
        const count = if (space == null) df_implicit else std.fmt.parseInt(u32, value, 10) catch
            return warnUnusableDf(allocator, path, "a row's frequency is not a number");
        try df.put(allocator, key, count);
    }
    const n = docs orelse
        return warnUnusableDf(allocator, path, "it carries no `docs` count");
    return .{ .docs = n, .df = df };
}

/// The one warning an unusable table earns, and the null it resolves to.
fn warnUnusableDf(allocator: Allocator, path: []const u8, why: []const u8) Allocator.Error!?FrozenDf {
    reporter.warn(.{
        .check = check_name,
        .file = path,
        .message = try std.fmt.allocPrint(
            allocator,
            "{s}: ignoring the frozen df table {s} \u{2014} {s}; scoring falls back to live " ++
                "document frequency (`guardian-check accept {s} .` rewrites it)",
            .{ check_name, df_leaf, why, check_name },
        ),
    });
    return null;
}

/// The rows of a table frozen from `corpus`: the `docs` count, then one row per
/// shingle ascending by key — a bare `<key>` at the implicit df, `<key> <df>`
/// above it.
///
/// The WHOLE vocabulary is written, df=1 shingles included, and that is a
/// measured decision rather than an oversight. Dropping the df=1 tail would cut
/// eda's table from 264,931 rows to 85,392 — but a shingle the table does not
/// hold falls back to its LIVE frequency, and a 3-gram that was unique when the
/// table was frozen and is held by two bodies now is exactly the corpus shift
/// the freeze exists to absorb. Replayed over eda's six states, a df>=2-only
/// table reported 125/86/50/32/15/0 against the frozen-idf reference of
/// 125/85/49/31/14/0: it re-admitted `module_policy.stripUpper` in two files
/// nothing had touched, which is the one finding this whole feature exists to
/// remove. The other way out — treating an absent shingle as df=1 instead of
/// live — is worse, because `proposes` needs df >= 2: every 3-gram of a NEWLY
/// added file would then be unable to propose anything, and two fresh copies of
/// one rule, the freshest drift there is, would go unseen until the next
/// accept. So the row count is paid, and paid down in the encoding instead: the
/// truncated key and the implicit df=1 take eda's table from 5.9 MB to 2.5 MB.
///
/// Two shingles whose hashes truncate to one key are folded to the larger
/// count, so the file holds each key exactly once and reading it back cannot
/// depend on row order.
fn frozenDfRows(allocator: Allocator, corpus: Corpus) Allocator.Error![]const []const u8 {
    var by_key: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer by_key.deinit(allocator);
    for (corpus.hashes, corpus.df) |hash, frequency| {
        const slot = try by_key.getOrPut(allocator, dfKey(hash));
        slot.value_ptr.* = if (slot.found_existing) @max(slot.value_ptr.*, frequency) else frequency;
    }
    var keys: std.ArrayList([]const u8) = .empty;
    var it = by_key.iterator();
    while (it.next()) |e| {
        const key = encodeDfKey(e.key_ptr.*);
        try keys.append(allocator, if (e.value_ptr.* == df_implicit)
            try allocator.dupe(u8, key[0..])
        else
            try std.fmt.allocPrint(allocator, "{s} {d}", .{ key[0..], e.value_ptr.* }));
    }
    std.mem.sort([]const u8, keys.items, {}, lessThanRow);
    var rows: std.ArrayList([]const u8) = .empty;
    try rows.append(allocator, try std.fmt.allocPrint(
        allocator,
        "{s} {d}",
        .{ df_docs_field, corpus.docs.len },
    ));
    try rows.appendSlice(allocator, keys.items);
    return rows.toOwnedSlice(allocator);
}

/// Orders two rendered rows, so the written file is byte-stable across runs.
fn lessThanRow(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Rewrites the table from the corpus this run measured. Called only from an
/// accept of THIS check (see `writesDfTable`): accept means "ratify the current
/// state", so the table is refreshed even when no pair is new.
fn writeFrozenDf(
    allocator: Allocator,
    project_dir: []const u8,
    corpus: Corpus,
) (Allocator.Error || snapshot.WriteError)!void {
    const path = try dfPath(allocator, project_dir);
    const rows = try frozenDfRows(allocator, corpus);
    // The content-identical short-circuit every other `.guardian/` writer uses:
    // an accept that re-measures the same corpus leaves `git status` clean.
    _ = try snapshot.writePresortedChecked(allocator, path, df_version, rows);
}

/// True when this run may (re)write the table: an accept that NAMES this check,
/// and nothing else.
///
/// `shouldUpdateForCtx` is the one seam every accept path already goes through
/// — `guardian-check accept twin-drift .`, `GUARDIAN_UPDATE_SNAPSHOT=twin-drift`
/// (or `=all`), and the `zig build guardian-accept -Dguardian-checks=…` step
/// that spells the env var — so the table refreshes wherever a snapshot would,
/// and accepting an unrelated check never re-freezes the scoring. It is the
/// same flag the surfaced tier already reads, which is what makes one accept
/// record the surfaced pairs AND the table they were scored with.
///
/// The two exclusions are the read-only contracts: `--dry-run` and `--list` DO
/// read an existing table (that is scoring, not baseline filtering) but may
/// never write one, even under the environment variable — and
/// `cli/introspect.zig` clears `refresh` besides.
///
/// A diff-scoped run cannot reach here, twice over: `scope.Posture` refuses to
/// scope a run with a refresh pending, and twin-drift is classified
/// `whole_tree`, so `run_all.indexFor` hands it the entire index even when the
/// surrounding run IS scoped. The corpus this table is frozen from is therefore
/// always the whole tree.
fn writesDfTable(ctx: *registry.RunCtx) bool {
    if (ctx.dry_run or ctx.list) return false;
    return snapshot_helper.shouldUpdateForCtx(ctx, check_name);
}

/// The `--list` header naming what the frozen table covers: how many of this
/// run's live shingles it holds, and the document count it was frozen at
/// against the one measured now. Deliberately NOT printed on an ordinary run —
/// staleness is a thing to look up before a release, not a line on every gate.
fn dfCoverage(allocator: Allocator, frozen: ?FrozenDf, corpus: Corpus) Allocator.Error![]const u8 {
    const table = frozen orelse return std.fmt.allocPrint(
        allocator,
        "{s}: no frozen df table ({s}) \u{2014} scoring uses live document frequency; " ++
            "`guardian-check accept {s} .` freezes it",
        .{ check_name, df_leaf, check_name },
    );
    var held: usize = 0;
    for (corpus.hashes) |hash| {
        if (table.df.contains(dfKey(hash))) held += 1;
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: frozen df table {s} covers {d}/{d} live shingle(s); frozen N = {d}, live N = {d} " ++
            "\u{2014} `guardian-check accept {s} .` refreshes it",
        .{ check_name, df_leaf, held, corpus.hashes.len, table.docs, corpus.docs.len, check_name },
    );
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
    // The DECISION is the scoring frequency (frozen when a table says so); the
    // LENGTH is the live one, because that is how many bodies the fill loop
    // below actually has to write.
    for (corpus.df, corpus.scoring_df, 0..) |live, scoring, id| {
        starts[id] = total;
        if (proposes(scoring)) total += live;
    }
    starts[corpus.df.len] = total;

    const docs = try allocator.alloc(u32, total);
    const weights = try allocator.alloc(f64, total);
    const cursor = try allocator.alloc(u32, corpus.df.len);
    defer allocator.free(cursor);
    @memcpy(cursor, starts[0..corpus.df.len]);
    for (corpus.docs, 0..) |terms, i| {
        for (terms) |t| {
            if (!proposes(corpus.scoring_df[t.id])) continue;
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
            if (!proposes(corpus.scoring_df[t.id])) continue;
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
    /// The tf-idf document set this pass built, kept so an accept can freeze
    /// the df table it was scored with rather than measuring the tree twice.
    corpus: Corpus,
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
    frozen: ?FrozenDf,
) Allocator.Error!Analysis {
    var candidates: std.ArrayList(Candidate) = .empty;
    for (files) |*entry| try collectFile(allocator, entry, cfg, &candidates);

    var corpus = try buildCorpus(allocator, candidates.items);
    applyFrozen(&corpus, frozen);
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
    return .{ .twins = try out.toOwnedSlice(allocator), .oversize = oversize, .corpus = corpus };
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
        .fix_hint = try sinkHint(allocator, t),
        .identity = try identityFor(allocator, t),
        .metric = t.percent,
    };
}

/// The pair's identity: both names under both paths, ordered by path. ONE
/// definition, read by the Violation above and by the frozen-key lookup below,
/// so the key the gate stores and the key the advisory channel consults can
/// never drift apart — the whole suppression rests on the two agreeing.
fn identityFor(allocator: Allocator, t: Twin) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}|{s}|{s}|{s}", .{ t.a.name, t.a.file, t.b.name, t.b.file });
}

/// True when `frozen` — the rows of this project's `twin-drift` baseline —
/// already records this pair. Keyed through `violation_key.fromRecord`, the
/// same function `baseline.keyedViolations` runs the emitted record through,
/// rather than by re-formatting the stored line here.
fn recorded(allocator: Allocator, frozen: []const []const u8, t: Twin) Allocator.Error!bool {
    if (frozen.len == 0) return false;
    const key = try violation_key.fromRecord(allocator, check_name, .{
        .check = check_name,
        .message = "",
        .identity = try identityFor(allocator, t),
    });
    for (frozen) |row| {
        if (std.mem.eql(u8, row, key)) return true;
    }
    return false;
}

/// The advisory line naming WHAT drifted: up to four lines that one copy has
/// and the other does not. It rides `reporter.warn` because baselines and
/// ratchets exclude the advisory channel by construction — the sample changes
/// with every edit to either body, and no consumer should ever have to accept
/// it.
///
/// That exclusion is also why `frozen` is a parameter. Nothing downstream can
/// subtract an advisory line for this check, so a project that baselined its
/// whole backlog kept getting the sample for all of it (measured in eda: 125
/// frozen pairs, 124 `warning:` lines on every gate run, and a `twin-drift:
/// 124 finding(s) — report-only` beside a `--list` reading `NEW (0)`). Frozen
/// debt must be silent, so the check consults its OWN baseline and returns null
/// for a pair already recorded there — the same seam `spec` uses for its
/// unlinked-tag hints. `frozen` is empty whenever nothing will be subtracted
/// (baseline mode off for this check, `--dry-run`), and then every pair keeps
/// its detail.
///
/// Also null when the two bodies hold the same lines in a different order,
/// which the sample cannot show.
fn detailFor(allocator: Allocator, frozen: []const []const u8, t: Twin) Allocator.Error!?reporter.Violation {
    if (try recorded(allocator, frozen, t)) return null;
    const sample = (try driftSample(allocator, t)) orelse return null;
    return .{
        .check = check_name,
        .file = t.a.file,
        .line = t.a.line,
        .message = try std.fmt.allocPrint(allocator, "twin-drift: fn {s} \u{2014}{s}", .{ t.a.name, sample }),
    };
}

/// The sample itself — `` only in <fileA>: `x`; only in <fileB>: `y`;`` — with
/// no leading prose, so the two readers can frame it their own way. Null when
/// the two bodies hold the same lines in a different order, which the sample
/// cannot show.
fn driftSample(allocator: Allocator, t: Twin) Allocator.Error!?[]const u8 {
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
    // Half the room to each side when both drifted, so a long one-sided list
    // cannot crowd the other copy's lines out of the sample entirely.
    const shown_a = try appendSide(allocator, &buf, t.a.file, only_a, if (only_b.len == 0)
        max_detail_lines
    else
        max_detail_lines / 2);
    const shown = shown_a + try appendSide(allocator, &buf, t.b.file, only_b, max_detail_lines - shown_a);
    const total = only_a.len + only_b.len;
    if (total > shown) try appendFmt(allocator, &buf, " (+{d} more)", .{total - shown});
    return try buf.toOwnedSlice(allocator);
}

/// The remedy the JSONL sink carries for one pair, which is where the second
/// reader of the sample lives. `last-run.jsonl` has no "beneath the list"
/// channel and no advisory tier at all — warnings never reach it — so a row
/// that said only "reconcile the two copies" named no subject to reconcile.
/// The sample rides `fix_hint`, which `emitQuiet` keeps off the printed line
/// (the console gets it once, through `detailFor`), and which the baseline
/// layer forwards ONLY for a violation this run actually reported — so frozen
/// debt stays out of the log for exactly the reason it stays off the console.
fn sinkHint(allocator: Allocator, t: Twin) Allocator.Error![]const u8 {
    const sample = (try driftSample(allocator, t)) orelse return fix_hint;
    return std.fmt.allocPrint(allocator, "{s} what drifted:{s}", .{ fix_hint, sample });
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

/// The pairs whose drift sample this run must NOT print: the keys already
/// recorded in `.guardian/baselines/twin-drift.txt`.
///
/// Empty — every pair keeps its detail — in the two cases where nothing is
/// being subtracted from this check's violations, and the sample therefore
/// belongs beside every one of them: baseline mode is not what filters this
/// check (`[baseline] enabled = false`, or a `[policy]` mode that bypasses it),
/// and `--dry-run`, whose entire contract is "every current finding, no
/// baseline filtering". `--list` is unaffected either way: it reports keyed
/// rows, never the advisory channel.
fn frozenPairs(ctx: *registry.RunCtx) Allocator.Error![]const []const u8 {
    if (ctx.dry_run) return &.{};
    if (!ctx.cfg.policy.usesBaselineFor(check_name, ctx.cfg.baseline)) return &.{};
    return baseline.frozenKeys(ctx.allocator, ctx.project_dir, check_name);
}

// ── What blocks ─────────────────────────────────────────────────────────

/// The change this run judges an UNRECORDED pair against.
///
/// The proposal is corpus-wide by construction: `idf(s) = ln((N+1)/(df+1)) + 1`
/// moves whenever a body is added or removed ANYWHERE in the tree, so a pair
/// sitting just under `pair_similarity` crosses it with no edit to either of
/// its own files. Measured in eda (2026-09-02, five branches each reconciling a
/// disjoint family out of 125 frozen pairs): after the first merge removed 40
/// bodies, the next branch's rebased tree reported `module_policy.stripUpper`
/// and `pin_roles.normalizeIdent` (90% LCS, cosine crossed the floor from
/// below) as a NEW blocking row in two files no branch had touched, and
/// `assembly_debug.writeJsonString` / `route_review.writeJsonString` with it;
/// one merge left main red until a later branch's baseline happened to carry
/// the row. Both pairs were real drift — the proposal was RIGHT — but a gate
/// whose verdict on files A and B changes because file C was deleted is not a
/// stable gate, and it contradicts Guardian's own rule: block at commit what
/// the change introduced.
///
/// So the tf-idf proposal and the LCS judgement are untouched, and what BLOCKS
/// is narrowed: an unrecorded pair blocks only when this change touched one of
/// its two files. Everything else is SURFACED — advisory, recordable by
/// `accept`, never silently dropped.
const Touched = union(enum) {
    /// The base resolved: exactly this plan's paths differ from it (working
    /// tree plus index, plus untracked files).
    plan: scope.Plan,
    /// No base could be resolved; the payload is why. Nothing can be PROVEN
    /// untouched, so every unrecorded pair blocks — the pre-narrowing
    /// behaviour, kept because failing open here would hide real drift from
    /// every project judged outside a git repository.
    unresolved: []const u8,

    /// True when this change touched either side of `t`.
    fn covers(self: Touched, t: Twin) bool {
        return switch (self) {
            .unresolved => true,
            .plan => |p| p.covers(t.a.file) or p.covers(t.b.file),
        };
    }

    /// Why no base resolved, or null when one did.
    fn missingBase(self: Touched) ?[]const u8 {
        return switch (self) {
            .unresolved => |reason| reason,
            .plan => null,
        };
    }
};

/// The run's diff scope, read through the SAME resolver every other diff-aware
/// feature uses: `--against` / `GUARDIAN_AGAINST` when given, else the merge
/// base with `main`/`master`, plus untracked files. The posture is empty on
/// purpose — the seam `external-gates` already reads — because `scope.Posture`
/// decides whether the per-file checks may be NARROWED, and a `--gate` run is
/// exactly the run that must still be able to say what its change touched.
fn touchedIn(ctx: *registry.RunCtx) Allocator.Error!Touched {
    return switch (try scope.resolve(ctx.allocator, ctx.project_dir, ctx.against, .{})) {
        .scoped => |p| .{ .plan = p },
        .whole_tree => |reason| .{ .unresolved = reason },
    };
}

/// How one drifted pair is treated by this run.
const Verdict = enum {
    /// Recorded in the baseline (LIVE), or in a file this change touched, or
    /// judged with no base to prove otherwise: emitted as a violation, and the
    /// baseline layer above decides whether it blocks.
    blocking,
    /// Unrecorded, and neither file was touched: advisory only.
    surfaced,
};

/// The split above as a pure function of its inputs, so the policy can be read
/// — and tested — without a repository or a baseline file.
fn verdictFor(recorded_here: bool, touched: Touched, dry_run: bool, t: Twin) Verdict {
    // `--dry-run` promises every current finding with no filtering of any kind,
    // and the surfaced tier is a filter.
    if (dry_run or recorded_here or touched.covers(t)) return .blocking;
    return .surfaced;
}

/// Entry point for the twin-drift check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    return runAgainst(ctx, try touchedIn(ctx));
}

/// The check with its diff scope already resolved. Split from `run` so the
/// policy above is exercised over stated inputs rather than over whatever git
/// happens to say about the directory a test wrote its fixtures into.
fn runAgainst(ctx: *registry.RunCtx, touched: Touched) registry.RunError!void {
    const allocator = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    const files = try allowedFiles(allocator, idx.files, ctx.cfg.extraAllowed(check_name));
    const frozen_df = try loadFrozenDf(allocator, ctx.project_dir);
    const found = try analyzeIndex(allocator, files, ctx.cfg.twin_drift, frozen_df);
    if (writesDfTable(ctx)) try writeFrozenDf(allocator, ctx.project_dir, found.corpus);
    if (ctx.list) reporter.warn(.{
        .check = check_name,
        .alert = true,
        .message = try dfCoverage(allocator, frozen_df, found.corpus),
    });
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
    const frozen = try frozenPairs(ctx);
    var blocking: std.ArrayList(Twin) = .empty;
    var surfaced: std.ArrayList(Twin) = .empty;
    for (found.twins) |t| {
        switch (verdictFor(try recorded(allocator, frozen, t), touched, ctx.dry_run, t)) {
            .blocking => try blocking.append(allocator, t),
            .surfaced => try surfaced.append(allocator, t),
        }
    }
    // An accept of THIS check is the one run that records a surfaced pair, so it
    // is the one run that emits it as a violation: the baseline layer writes
    // what the check reported, and `growth_exempt` is the proof it may do so
    // under `deny_growth` (see `reportSurfaced`).
    const recording = snapshot_helper.shouldUpdateForCtx(ctx, check_name);
    if (blocking.items.len > 0) {
        reporter.fail("twin-drift FAILED ({d} drifted pair(s))", .{blocking.items.len});
        for (blocking.items) |t| {
            reporter.emitQuiet(try violationFor(allocator, t));
            if (try detailFor(allocator, frozen, t)) |d| reporter.warn(d);
        }
        reporter.detail("  fix: {s}\n", .{fix_hint});
        if (touched.missingBase()) |reason| reporter.detail(
            "  note: no diff base ({s}) \u{2014} every unrecorded pair blocks\n",
            .{reason},
        );
    } else if (surfaced.items.len > 0) {
        reporter.ok("twin-drift: no drifted pair in the files this change touched", .{});
    }
    if (surfaced.items.len > 0) try reportSurfaced(ctx, frozen, surfaced.items, recording);
    if (blocking.items.len > 0 or (recording and surfaced.items.len > 0)) return error.CheckFailed;
}

/// The surfaced tier's output: ONE line by default, the pairs themselves under
/// `--verbose` (and under `--list`, which renders its own SURFACED bucket from
/// these records rather than printing them).
///
/// The collapsed line is flagged `alert` for the same reason `near_cap`'s is. A
/// surfaced pair is real drift this change did not cause, so it belongs in the
/// advisory tier — but that tier collapses to a bare `N finding(s) —
/// report-only` count under `--summary`, and burying the line that says "there
/// are pairs here nobody has looked at" is how frozen drift rots.
/// `run_view.showsAlerts` replays it whatever the collapse decided. It stays a
/// warning: no baseline, ratchet or snapshot records it.
///
/// Under `recording` the pairs are emitted as violations instead, carrying
/// `growth_exempt` — this run PROVED neither file changed against the base, so
/// recording them is pre-existing debt made visible, not growth the change
/// introduced, and `[baseline] deny_growth` may accept them. A pair whose file
/// the change DID touch is never surfaced, so it never carries the flag and a
/// deny_growth refresh still refuses it.
fn reportSurfaced(
    ctx: *registry.RunCtx,
    frozen: []const []const u8,
    surfaced: []const Twin,
    recording: bool,
) Allocator.Error!void {
    const allocator = ctx.allocator;
    if (recording) {
        for (surfaced) |t| {
            var v = try violationFor(allocator, t);
            v.growth_exempt = true;
            reporter.emitQuiet(v);
        }
        return;
    }
    reporter.warn(.{
        .check = check_name,
        .alert = true,
        .message = try std.fmt.allocPrint(
            allocator,
            "{s}: {d} pair(s) surfaced by corpus shift, none in files this change touched " ++
                "\u{2014} advisory; guardian-check accept {s} . records them",
            .{ check_name, surfaced.len, check_name },
        ),
    });
    if (!ctx.verbose and !ctx.list) return;
    for (surfaced) |t| {
        reporter.warn(try violationFor(allocator, t));
        if (try detailFor(allocator, frozen, t)) |d| reporter.warn(d);
    }
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
    return analyzeIndex(a, files.items, cfg, null);
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
    const detail = (try detailFor(a, &.{}, t)).?;
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
    const detail = (try detailFor(a, &.{}, found.twins[0])).?;
    try testing.expect(std.mem.indexOf(u8, detail.message, "`out += 7;`") != null);
    // `v,` is the first copy's own line, split — not something it never got.
    try testing.expect(std.mem.indexOf(u8, detail.message, "`v,`") == null);
}

// spec: Twin Drift - Carries what drifted on the reported pair's machine-readable fix hint

test "twin-drift: the sink hint names the remedy and what drifted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try analyzeSources(a, &.{
        .{ "src/a.zig", try ruleSource(a, "", base_body) },
        .{ "src/b.zig", try ruleSource(a, "", try grownBody(a)) },
    }, .{});
    try testing.expectEqual(@as(usize, 1), found.twins.len);
    // `emitQuiet` keeps this off the printed line — it exists for the JSONL
    // row, which has no advisory tier to read the warning from.
    const hint = (try violationFor(a, found.twins[0])).fix_hint.?;
    try testing.expect(std.mem.indexOf(u8, hint, "lift the shared part") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "what drifted:") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "out += 6;") != null);
}

/// `base_body` with one statement the other copy never got. Spliced from
/// `base_body` rather than written out a second time, so the two fixtures
/// cannot drift apart in the one file whose whole subject is copies drifting
/// apart.
fn grownBody(a: Allocator) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, a, base_body, "    return out;", "    out += 6;\n    return out;");
}

/// The baseline row the pair `baselineProject` writes is keyed under: exactly
/// `<check>|<identity>`, the form `baseline.keyedViolations` stores.
const frozen_row = "twin-drift|parseRule|src/a.zig|parseRule|src/b.zig";

/// A throwaway project holding that one drifted pair, with `rows` already
/// recorded in its twin-drift baseline. The stored state is the only thing the
/// three tests below vary.
fn baselineProject(a: Allocator, dir: []const u8, rows: []const []const u8) !void {
    // deleteTree succeeds on a path that does not exist, so a first run and a
    // rerun after a crashed one both start from the same empty project.
    try fs.cwd().deleteTree(dir);
    try fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/src", .{dir}));
    try fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/.guardian/baselines", .{dir}));
    try fs.cwd().writeFile(.{
        .sub_path = try std.fmt.allocPrint(a, "{s}/src/a.zig", .{dir}),
        .data = try ruleSource(a, "", base_body),
    });
    try fs.cwd().writeFile(.{
        .sub_path = try std.fmt.allocPrint(a, "{s}/src/b.zig", .{dir}),
        .data = try ruleSource(a, "", try grownBody(a)),
    });
    var stored: std.ArrayList(u8) = .empty;
    try stored.appendSlice(a, "# guardian-snapshot v3\n");
    for (rows) |row| {
        try stored.appendSlice(a, row);
        try stored.append(a, '\n');
    }
    try fs.cwd().writeFile(.{
        .sub_path = try std.fmt.allocPrint(a, "{s}/.guardian/baselines/twin-drift.txt", .{dir}),
        .data = stored.items,
    });
}

/// A change that edited both copies: every drifted pair between them is in
/// scope, which is the posture the pre-narrowing behaviour was the whole of.
const touched_both: Touched = .{ .plan = .{ .base = "test-base", .files = &.{ "src/a.zig", "src/b.zig" } } };

/// A resolved base that touched neither copy — the corpus-shift posture, where
/// an unrecorded pair is surfaced rather than blocking.
const touched_neither: Touched = .{ .plan = .{ .base = "test-base", .files = &.{"src/elsewhere.zig"} } };

/// Runs the check over `dir` under capture and hands back what it reported.
/// The diff scope is STATED rather than resolved: these fixtures live in a
/// gitignored scratch directory, so asking git about them would answer about
/// Guardian's own repository. The check FAILS whenever it emits a violation —
/// the baseline layer above it is what turns frozen debt green — so the verdict
/// is swallowed and only the two channels are inspected.
fn captureOver(ctx: *registry.RunCtx, cap: *reporter.Capture, touched: Touched) !void {
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = cap;
    try testing.expectError(error.CheckFailed, runAgainst(ctx, touched));
}

/// The same, for a run that emits nothing blocking and therefore passes.
fn captureGreenOver(ctx: *registry.RunCtx, cap: *reporter.Capture, touched: Touched) !void {
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = cap;
    try runAgainst(ctx, touched);
}

// spec: Twin Drift - Prints no drift sample for a pair its own baseline already records

test "twin-drift: a pair frozen in the baseline gets no advisory detail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-frozen";
    defer fs.cwd().deleteTree(dir) catch {};
    try baselineProject(a, dir, &.{frozen_row});

    const cfg: config.Config = .{ .baseline = .{ .enabled = true } };
    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &cfg, .quiet = true };
    var cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&ctx, &cap, touched_both);

    // The keyed violation still fires: subtracting it is the baseline layer's
    // job, and it is what keeps a consumer's frozen row LIVE rather than
    // RESOLVED.
    try testing.expectEqual(@as(usize, 1), cap.records.items.len);
    // The advisory sample beside it does not — nothing downstream could filter
    // it, so this run is the only place that can stay quiet.
    try testing.expectEqual(@as(usize, 0), cap.warnings.items.len);
}

// spec: Twin Drift - Keeps the drift sample for a pair its baseline does not record

test "twin-drift: a pair the baseline does not record keeps its detail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-new";
    defer fs.cwd().deleteTree(dir) catch {};
    // A baseline holding a DIFFERENT pair: the file is readable and non-empty,
    // so a suppression keyed on anything but the identity would still hide this.
    try baselineProject(a, dir, &.{"twin-drift|parseRule|src/a.zig|parseOther|src/b.zig"});

    const cfg: config.Config = .{ .baseline = .{ .enabled = true } };
    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &cfg, .quiet = true };
    var cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&ctx, &cap, touched_both);

    try testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.warnings.items[0].message, "out += 6;") != null);
}

// spec: Twin Drift - Keeps every drift sample under a dry run whatever the baseline records

test "twin-drift: a dry run keeps the detail for a frozen pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-dry-run";
    defer fs.cwd().deleteTree(dir) catch {};
    try baselineProject(a, dir, &.{frozen_row});

    const cfg: config.Config = .{ .baseline = .{ .enabled = true } };
    var ctx: registry.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &cfg,
        .quiet = true,
        .dry_run = true,
    };
    var cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&ctx, &cap, touched_both);

    // Same frozen row as the first test, opposite answer: `--dry-run` promises
    // every current finding with no baseline filtering, and the sample is part
    // of the finding.
    try testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.warnings.items[0].message, "out += 6;") != null);
}

/// A project holding the one drifted pair with a baseline that records a
/// DIFFERENT pair — the state every stability test below starts from, so the
/// pair under test is always unrecorded and the file is always readable.
fn unrecordedProject(a: Allocator, dir: []const u8) !void {
    return baselineProject(a, dir, &.{"twin-drift|parseRule|src/a.zig|parseOther|src/b.zig"});
}

/// The baseline-mode config those tests share.
const baseline_on: config.Config = .{ .baseline = .{ .enabled = true } };

// spec: Twin Drift - Blocks an unrecorded pair when the change touched one of its files

test "twin-drift: an unrecorded pair in a touched file is a blocking violation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-touched";
    defer fs.cwd().deleteTree(dir) catch {};
    try unrecordedProject(a, dir);

    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &baseline_on, .quiet = true };
    var cap: reporter.Capture = .{ .allocator = a };
    // The change edited src/b.zig; ONE of the two sides is enough.
    try captureOver(&ctx, &cap, .{ .plan = .{ .base = "test-base", .files = &.{"src/b.zig"} } });

    try testing.expectEqual(@as(usize, 1), cap.records.items.len);
    try testing.expect(!cap.records.items[0].growth_exempt);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "twin-drift FAILED (1 drifted pair(s))") != null);
}

// spec: Twin Drift - Surfaces an unrecorded pair in untouched files as one advisory line

test "twin-drift: an unrecorded pair in untouched files surfaces instead of blocking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-surfaced";
    defer fs.cwd().deleteTree(dir) catch {};
    try unrecordedProject(a, dir);

    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &baseline_on, .quiet = true };
    var cap: reporter.Capture = .{ .allocator = a };
    // The corpus-shift posture: the same drift, in two files the change never
    // opened. It is real — so it is reported — but it is not this change's.
    try captureGreenOver(&ctx, &cap, touched_neither);

    try testing.expectEqual(@as(usize, 0), cap.records.items.len);
    try testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
    const line = cap.warnings.items[0].message;
    try testing.expectEqualStrings(
        "twin-drift: 1 pair(s) surfaced by corpus shift, none in files this change touched " ++
            "\u{2014} advisory; guardian-check accept twin-drift . records them",
        line,
    );
    // Flagged so `--summary` cannot collapse it into a bare finding count.
    try testing.expect(cap.warnings.items[0].alert);
}

// spec: Twin Drift - Names every surfaced pair under a verbose run

test "twin-drift: --verbose expands the collapsed surfaced line into its pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-surfaced-verbose";
    defer fs.cwd().deleteTree(dir) catch {};
    try unrecordedProject(a, dir);

    var ctx: registry.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &baseline_on,
        .quiet = true,
        .verbose = true,
    };
    var cap: reporter.Capture = .{ .allocator = a };
    try captureGreenOver(&ctx, &cap, touched_neither);

    // The collapsed line, the pair itself (keyed, so `--list` can bucket it),
    // and the drift sample that says WHAT diverged.
    try testing.expectEqual(@as(usize, 3), cap.warnings.items.len);
    try testing.expectEqualStrings(
        "parseRule|src/a.zig|parseRule|src/b.zig",
        cap.warnings.items[1].identity.?,
    );
    try testing.expect(std.mem.indexOf(u8, cap.warnings.items[2].message, "out += 6;") != null);
}

// spec: Twin Drift - Blocks every unrecorded pair when no diff base resolves

test "twin-drift: an unresolvable diff base blocks every unrecorded pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-no-base";
    defer fs.cwd().deleteTree(dir) catch {};
    try unrecordedProject(a, dir);

    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &baseline_on, .quiet = true };
    var cap: reporter.Capture = .{ .allocator = a };
    // Outside a repository nothing can be PROVEN untouched, so the narrowing
    // must fail closed onto the pre-narrowing behaviour rather than go quiet.
    try captureOver(&ctx, &cap, .{ .unresolved = "no diff base could be resolved" });

    try testing.expectEqual(@as(usize, 1), cap.records.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "no diff base (no diff base could be resolved)") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "every unrecorded pair blocks") != null);
}

// spec: Twin Drift - Records a surfaced pair as growth-exempt and a touched one as ordinary growth

test "twin-drift: an accept records a surfaced pair exempt and a touched pair not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-accept";
    defer fs.cwd().deleteTree(dir) catch {};
    try unrecordedProject(a, dir);

    // `accept twin-drift .` — the one run that records a surfaced pair, so the
    // one run that emits it as a violation for the baseline layer to write.
    var ctx: registry.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &baseline_on,
        .quiet = true,
        .refresh = &.{check_name},
    };
    var cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&ctx, &cap, touched_neither);
    try testing.expectEqual(@as(usize, 1), cap.records.items.len);
    // Proven pre-existing: neither file changed against the base, so a
    // `deny_growth` refresh may record it (see baseline.denyGrowthGuard).
    try testing.expect(cap.records.items[0].growth_exempt);

    // The same accept over a pair the change DID touch carries no exemption,
    // so `deny_growth` still refuses to ratify it.
    var touched_cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&ctx, &touched_cap, touched_both);
    try testing.expectEqual(@as(usize, 1), touched_cap.records.items.len);
    try testing.expect(!touched_cap.records.items[0].growth_exempt);
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
    const found = try analyzeIndex(a, try entriesOf(a, sources.items), .{}, null);
    try testing.expectEqual(@as(usize, 0), found.twins.len);
    // The LCS the judgement uses would have said yes — 8 of 11 lines are shared
    // — so it is the pair floor, not the similarity floor, keeping this quiet.
    const wide = try analyzeIndex(a, try entriesOf(a, sources.items), .{ .pair_similarity = 0.01 }, null);
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

// ── Tests: the frozen df table ──────────────────────────────────────────

/// The ten filler bodies that make `scaffold_body` scaffolding. With them in
/// the corpus the pair below is under the pair floor; without them it is over —
/// the corpus shift this whole feature exists to pin, written small.
fn scaffoldFillerSources(a: Allocator) ![]const [2][]const u8 {
    var sources: std.ArrayList([2][]const u8) = .empty;
    for (0..10) |i| {
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, scaffold_body);
        for (0..12) |k| {
            try body.appendSlice(a, try std.fmt.allocPrint(
                a,
                "    out = f{d}_{d}(v) + g{d}_{d}(v) * h{d}_{d}(v) - j{d}_{d}(v);\n",
                .{ i, k, i, k, i, k, i, k },
            ));
        }
        const name = try std.fmt.allocPrint(a, "src/filler{d}.zig", .{i});
        try sources.append(a, .{ name, try renamedSource(a, "sweep", body.items) });
    }
    return sources.toOwnedSlice(a);
}

/// The two bodies under test, appended to whatever corpus surrounds them.
fn scaffoldPairSources(a: Allocator, prefix: []const [2][]const u8) ![]const [2][]const u8 {
    var sources: std.ArrayList([2][]const u8) = .empty;
    try sources.appendSlice(a, prefix);
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
    return sources.toOwnedSlice(a);
}

/// Freezes a table from `sources` through the real rendering and the real
/// parser, so every test below exercises the encoding a consumer commits rather
/// than an in-memory shortcut.
fn frozenFrom(a: Allocator, sources: []const [2][]const u8) !FrozenDf {
    const found = try analyzeIndex(a, try entriesOf(a, sources), .{}, null);
    const rows = try frozenDfRows(a, found.corpus);
    return (try parseFrozenDf(a, "test-table.txt", rows)).?;
}

// spec: Twin Drift - Leaves every scoring frequency live when no frozen table exists

test "twin-drift: with no table the scoring frequencies are the measured ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try analyzeIndex(a, try entriesOf(a, try scaffoldPairSources(a, &.{})), .{}, null);
    // Byte-for-byte the pre-freeze behaviour: every decision reads what this
    // run measured, and the document count is this run's own.
    try testing.expectEqualSlices(u32, found.corpus.df, found.corpus.scoring_df);
    try testing.expectEqual(found.corpus.docs.len, found.corpus.scoring_docs);
}

// spec: Twin Drift - Holds a pair's verdict steady when an unrelated body leaves the corpus

test "twin-drift: a frozen table pins a pair that a deletion elsewhere would surface" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const with_fillers = try scaffoldPairSources(a, try scaffoldFillerSources(a));
    const without = try scaffoldPairSources(a, &.{});

    // Ten unrelated bodies write the same scaffolding, so the pair's only
    // common ground is discounted and it stays under the floor.
    const before = try analyzeIndex(a, try entriesOf(a, with_fillers), .{}, null);
    try testing.expectEqual(@as(usize, 0), before.twins.len);
    // Delete them — nothing about either copy changes — and a live idf makes
    // that same scaffolding rare enough to propose the pair.
    const after = try analyzeIndex(a, try entriesOf(a, without), .{}, null);
    try testing.expectEqual(@as(usize, 1), after.twins.len);

    // Scored against the table frozen while the fillers were there, the pair is
    // exactly where it was: the deletion moved no verdict.
    const frozen = try frozenFrom(a, with_fillers);
    const pinned = try analyzeIndex(a, try entriesOf(a, without), .{}, frozen);
    try testing.expectEqual(@as(usize, 0), pinned.twins.len);
}

// spec: Twin Drift - Weighs a shingle the frozen table never saw at its live frequency

test "twin-drift: an unseen shingle falls back to the live frequency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frozen = try frozenFrom(a, try scaffoldPairSources(a, &.{}));

    // The same two bodies plus a third whose lines share no 3-gram with them:
    // every shingle of the newcomer is one the table has never seen.
    const grown = try scaffoldPairSources(a, &.{
        .{
            "src/new.zig",
            try renamedSource(a, "collectNew",
                \\    var tally: u32 = 0;
                \\    tally = seatOf(v) * rowOf(v);
                \\    tally = tally + berthOf(v);
                \\    tally = tally - deckOf(v);
                \\    tally = tally * cabinOf(v);
                \\    tally = tally / holdOf(v);
                \\    tally = tally + keelOf(v);
                \\    return tally;
                \\
            ),
        },
    });
    const found = try analyzeIndex(a, try entriesOf(a, grown), .{}, frozen);

    var seen_frozen = false;
    var seen_live = false;
    for (found.corpus.hashes, found.corpus.df, found.corpus.scoring_df) |hash, live, scoring| {
        if (frozen.df.get(dfKey(hash))) |stored| {
            try testing.expectEqual(stored, scoring);
            seen_frozen = true;
        } else {
            // Never seen: the live count stands, which is what keeps a copy
            // added AFTER the freeze visible to the index at all.
            try testing.expectEqual(live, scoring);
            seen_live = true;
        }
    }
    try testing.expect(seen_frozen and seen_live);
    // The count divided by is the frozen one, not this larger corpus's.
    try testing.expectEqual(frozen.docs, found.corpus.scoring_docs);
    try testing.expect(found.corpus.scoring_docs != found.corpus.docs.len);
}

// spec: Twin Drift - Round-trips every frozen shingle through a fixed-width base-36 key

test "twin-drift: the frozen table's rows round-trip through their encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectKeysRoundTrip();
    // Only the fixed width, in the lower-case alphabet, decodes.
    try testing.expect(decodeDfKey("0000000") == null);
    try testing.expect(decodeDfKey("000000000") == null);
    try testing.expect(decodeDfKey("0000000A") == null);

    // The rendered file is sorted, headed by its document count, and spells the
    // implicit frequency as a bare key.
    const found = try analyzeIndex(a, try entriesOf(a, try scaffoldPairSources(a, &.{})), .{}, null);
    const rows = try frozenDfRows(a, found.corpus);
    try testing.expectEqualStrings("docs 2", rows[0]);
    try testing.expect(std.sort.isSorted([]const u8, rows[1..], {}, lessThanRow));
    try testing.expect(bareRowCount(rows[1..]) > 0);

    // And every measured frequency survives the trip back.
    const reread = (try parseFrozenDf(a, "test-table.txt", rows)).?;
    try testing.expectEqual(@as(usize, 2), reread.docs);
    for (found.corpus.hashes, found.corpus.df) |hash, live| {
        try testing.expectEqual(live, reread.df.get(dfKey(hash)).?);
    }
}

/// Every stored key survives `encodeDfKey` → `decodeDfKey` at the fixed width,
/// across the interesting corners of the key space.
fn expectKeysRoundTrip() !void {
    for ([_]u64{ 0, 1, 35, 36, df_key_mask, 0xdead_beef_cafe_1234 }) |raw| {
        const key = dfKey(raw);
        const text = encodeDfKey(key);
        try testing.expectEqual(@as(usize, df_key_len), text.len);
        try testing.expectEqual(key, decodeDfKey(text[0..]).?);
    }
}

/// How many of `rows` are a bare key — the implicit-frequency spelling.
fn bareRowCount(rows: []const []const u8) usize {
    var bare: usize = 0;
    for (rows) |row| {
        if (std.mem.indexOfScalar(u8, row, ' ') == null) bare += 1;
    }
    return bare;
}

/// Writes `content` as the frozen table of a throwaway project and reads it
/// back under capture, so a broken file's ONE warning can be inspected.
fn loadTableFrom(a: Allocator, dir: []const u8, content: []const u8, cap: *reporter.Capture) !?FrozenDf {
    try fs.cwd().deleteTree(dir);
    try fs.cwd().makePath(try std.fmt.allocPrint(a, "{s}/.guardian", .{dir}));
    try fs.cwd().writeFile(.{
        .sub_path = try std.fmt.allocPrint(a, "{s}/.guardian/{s}", .{ dir, df_leaf }),
        .data = content,
    });
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = cap;
    return loadFrozenDf(a, dir);
}

// spec: Twin Drift - Warns once and scores live when the frozen table cannot be read

test "twin-drift: an unusable frozen table warns and falls back to live frequencies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-df-broken";
    defer fs.cwd().deleteTree(dir) catch {};

    const broken = [_][]const u8{
        // A row that is not a key at all.
        "# guardian-snapshot v4\ndocs 12\nnot-a-key 3\n",
        // A key row whose frequency is not a number.
        "# guardian-snapshot v4\ndocs 12\n0000000a many\n",
        // No document count to divide by.
        "# guardian-snapshot v4\n0000000a 3\n",
        // A `docs` row that is not a number.
        "# guardian-snapshot v4\ndocs lots\n",
        // Written by a format version this Guardian does not speak.
        "# guardian-snapshot v99\ndocs 12\n0000000a 3\n",
        // Left unresolved by a hand-merge.
        "# guardian-snapshot v4\ndocs 12\n<<<<<<< HEAD\n0000000a 3\n",
    };
    for (broken) |content| {
        var cap: reporter.Capture = .{ .allocator = a };
        // Never a crash, and never a silent degrade: the table is refused and
        // the run says which file it refused and what rewrites it.
        try testing.expect(try loadTableFrom(a, dir, content, &cap) == null);
        try testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
        const message = cap.warnings.items[0].message;
        try testing.expect(std.mem.indexOf(u8, message, df_leaf) != null);
        try testing.expect(std.mem.indexOf(u8, message, "live document frequency") != null);
        try testing.expect(std.mem.indexOf(u8, message, "accept twin-drift .") != null);
    }

    // A well-formed table is read in silence.
    var quiet: reporter.Capture = .{ .allocator = a };
    const good = try loadTableFrom(a, dir, "# guardian-snapshot v4\ndocs 12\n0000000a 3\n0000000b\n", &quiet);
    try testing.expectEqual(@as(usize, 0), quiet.warnings.items.len);
    try testing.expectEqual(@as(usize, 12), good.?.docs);
    try testing.expectEqual(@as(u32, 3), good.?.df.get(decodeDfKey("0000000a").?).?);
    try testing.expectEqual(@as(u32, df_implicit), good.?.df.get(decodeDfKey("0000000b").?).?);
}

// spec: Twin Drift - Writes the frozen table only on an accept that names this check

test "twin-drift: an accept freezes the table and an ordinary run leaves none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-df-write";
    defer fs.cwd().deleteTree(dir) catch {};
    try unrecordedProject(a, dir);
    const path = try std.fmt.allocPrint(a, "{s}/.guardian/{s}", .{ dir, df_leaf });

    // An ordinary gate run measures the corpus and writes nothing: a consumer
    // that never accepts never grows the file, and `git status` stays clean.
    var plain: registry.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &baseline_on, .quiet = true };
    var plain_cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&plain, &plain_cap, touched_both);
    try testing.expectError(error.FileNotFound, fs.cwd().access(path, .{}));

    // The accept of THIS check is the one run that records it.
    var accepting: registry.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &baseline_on,
        .quiet = true,
        .refresh = &.{check_name},
    };
    var accept_cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&accepting, &accept_cap, touched_both);
    try fs.cwd().access(path, .{});
    // What landed is a table this Guardian can read back.
    const reloaded = (try loadFrozenDf(a, dir)).?;
    try testing.expect(reloaded.docs > 0);
    try testing.expect(reloaded.df.count() > 0);

    // Accepting a DIFFERENT check leaves it alone, and so do the two read-only
    // introspection flags.
    try testing.expect(!writesDfTable(&plain));
    try testing.expect(writesDfTable(&accepting));
    var dry = accepting;
    dry.dry_run = true;
    try testing.expect(!writesDfTable(&dry));
    var listing = accepting;
    listing.list = true;
    try testing.expect(!writesDfTable(&listing));
    var other = plain;
    other.refresh = &.{"pub-api-surface"};
    try testing.expect(!writesDfTable(&other));
}

// spec: Twin Drift - Reports the frozen table's coverage on a list run

test "twin-drift: the list header names the table's coverage and both counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try analyzeIndex(a, try entriesOf(a, try scaffoldPairSources(a, &.{})), .{}, null);

    // No table: the line says so and names the command that makes one.
    const none = try dfCoverage(a, null, found.corpus);
    try testing.expect(std.mem.indexOf(u8, none, "no frozen df table") != null);
    try testing.expect(std.mem.indexOf(u8, none, "accept twin-drift .") != null);

    // A table frozen from this very corpus covers all of it, at its own count.
    const frozen = try frozenFrom(a, try scaffoldPairSources(a, &.{}));
    const covered = try dfCoverage(a, frozen, found.corpus);
    const both = try std.fmt.allocPrint(
        a,
        "covers {d}/{d} live shingle(s); frozen N = 2, live N = 2",
        .{ found.corpus.hashes.len, found.corpus.hashes.len },
    );
    try testing.expect(std.mem.indexOf(u8, covered, both) != null);
}

// spec: Twin Drift - Says so once when the frozen table was merge-resolved rather than measured

test "twin-drift: a merge-resolved table is still used and says so once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-df-merged";
    defer fs.cwd().deleteTree(dir) catch {};

    // Exactly what `merge-file` leaves behind for this format: OURS whole,
    // under the regenerate marker it stamps on a result it did not measure.
    const merged = "# guardian-snapshot v4\n" ++ snapshot.regen_marker ++
        " (GUARDIAN_UPDATE_SNAPSHOT=twin-drift)\ndocs 12\n0000000a 3\n0000000b\n";
    var cap: reporter.Capture = .{ .allocator = a };
    const table = try loadTableFrom(a, dir, merged, &cap);

    // Still USED — one branch's real measurement is a valid freeze, and the
    // marker is not a reason to fall back to a live idf.
    try testing.expectEqual(@as(usize, 12), table.?.docs);
    try testing.expectEqual(@as(u32, 3), table.?.df.get(decodeDfKey("0000000a").?).?);
    // …and said out loud exactly once, on the tier `--summary` cannot collapse.
    try testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
    try testing.expect(cap.warnings.items[0].alert);
    const message = cap.warnings.items[0].message;
    try testing.expect(std.mem.indexOf(u8, message, df_leaf) != null);
    try testing.expect(std.mem.indexOf(u8, message, snapshot.regen_marker) != null);
    try testing.expect(std.mem.indexOf(u8, message, "accept twin-drift .") != null);

    // The same file without the marker is read in silence, so the line is about
    // the merge and not about having a table at all.
    var quiet: reporter.Capture = .{ .allocator = a };
    _ = try loadTableFrom(a, dir, "# guardian-snapshot v4\ndocs 12\n0000000a 3\n0000000b\n", &quiet);
    try testing.expectEqual(@as(usize, 0), quiet.warnings.items.len);
}

// spec: Twin Drift - Drops a merge-resolve marker when an accept re-measures the table

test "twin-drift: an accept rewrites a merge-resolved table without its marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-twin-drift-df-remeasure";
    defer fs.cwd().deleteTree(dir) catch {};
    try unrecordedProject(a, dir);
    const path = try std.fmt.allocPrint(a, "{s}/.guardian/{s}", .{ dir, df_leaf });

    // A table a merge resolved, sitting in the project when the accept runs.
    try fs.cwd().writeFile(.{
        .sub_path = path,
        .data = "# guardian-snapshot v4\n" ++ snapshot.regen_marker ++
            " (GUARDIAN_UPDATE_SNAPSHOT=twin-drift)\ndocs 12\n0000000a 3\n",
    });
    var accepting: registry.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &baseline_on,
        .quiet = true,
        .refresh = &.{check_name},
    };
    var cap: reporter.Capture = .{ .allocator = a };
    try captureOver(&accepting, &cap, touched_both);

    // The write is a full replacement, so the marker is gone and the count is
    // this tree's — the merge's placeholder cannot survive its own remedy.
    const after = try fs.cwd().readFileAlloc(a, path, max_df_bytes);
    try testing.expect(!snapshot.hasRegenMarker(after));
    try testing.expect(std.mem.indexOf(u8, after, "docs 12\n") == null);

    // And a run over the rewritten table is silent again.
    var quiet: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &quiet;
    _ = try loadFrozenDf(a, dir);
    reporter.default.capture = prior;
    try testing.expectEqual(@as(usize, 0), quiet.warnings.items.len);
}
