//! The project-configurable concept-ownership check: enforces the `[[concept]]`
//! rules a project declares in its own guardian.toml — "these literal spellings
//! belong to one owner module; anywhere else is drift".
//!
//! Every other check in the suite is per-item: one file, one function, one
//! declaration. This one is RELATIONAL. The case it exists for is a set of
//! magic spellings that model a single domain fact and get hand-copied outward
//! until they disagree: a PCB tool's layer names ("F.Cu", "In1.Cu"), the hexes
//! its viewer paints them with, the Gerber suffixes it writes them to — found
//! duplicated across ~40 sites in Zig, JS and CSS, with no gate able to say
//! anything about it. `[[ban]]` cannot: it matches Zig identifier chains, it has
//! no notion of a home for a symbol, and it never sees a `.css` file.
//!
//! **Matching is LEXICAL — plain text, not AST — and that is the point.** Drift
//! of this kind crosses languages, so the scan must work on JS, CSS, TOML and
//! anything else a project globs in `files`; there is no parser that spans them.
//! A spelling that happens to occur for unrelated reasons is a false positive
//! the `owner` list or a narrower `literals` entry is meant to absorb.
//!
//! Two contexts are exempt, and the exemption is what keeps the frozen ledger
//! REAL. A comment line cannot disagree with the owner at runtime, and a Zig
//! `test` block's literal is the independent golden a sync-triangle test is
//! supposed to spell (deriving the expectation from the owner would make the
//! test circular). Counting either forced whole files into the baseline — and
//! because a violation's identity is `<file>|<concept>`, a file frozen over a
//! doc comment is a file whose REAL drift the gate can never see again.
//!
//! Exactly what is blanked, since a `files` glob reaches languages no Zig lexer
//! sees: a line whose first non-whitespace opens `//` (so `///` and `//!` too),
//! in every file; a line-leading `/* … */` block through its closing delimiter,
//! in `.css` files; and a Zig `test` declaration's whole span, wherever a parse
//! tree was available. Nothing else. A TRAILING comment of either shape shares
//! a code line, and judging one needs the per-language string lexer this check
//! refuses to be (`"https://…"`), so a code line always counts whole. Blanking
//! writes spaces over the bytes and never over a newline, so every surviving
//! occurrence keeps its exact offset AND its exact source line — a reported
//! line is one a reader can jump to, not one they have to re-grep for.
//!
//! Zero `[[concept]]` entries is the zero-config default: the check passes
//! without reading a single file.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const decls = @import("../ast/decls.zig");
const config = @import("../config.zig");
const lineOf = @import("../text.zig").lineOf;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const check_name = "concept";

/// Stands in for a rule's `reason` when the project didn't give one. Where the
/// spelling is supposed to come from is the useful half of the message, so its
/// absence says so out loud rather than printing a bare "this is drift".
const no_reason = "no reason given (add reason = \"...\" to the [[concept]] rule)";

/// Stands in for an empty `owner` list. A concept nobody owns bans its literals
/// everywhere, which is legal but is almost always a half-written rule.
const no_owner = "nobody (add owner = [\"...\"] to the [[concept]] rule)";

const fix_hint = "derive the value from the concept's owner module, " ++
    "or add this path to that [[concept]] rule's owner list.";

/// How many occurrence lines one violation names before it stops listing them.
/// A drifted file can carry dozens; the first few are what a reader jumps to,
/// and the total is in the count.
const max_reported_lines = 5;

/// How much of one match the report quotes before eliding the rest. A declared
/// literal is short by construction; a wildcard match is bounded only by the
/// token it landed in, and in a minified bundle that token can be the width of
/// a terminal several times over.
const max_spelling_bytes = 40;

/// Read cap for a file pulled in by a `files` glob. Above this the read fails
/// loud (as the source walker does) rather than skipping the file: a silently
/// unscanned file is exempt from the gate, which is the failure this check is
/// least able to afford.
const glob_read_limit = 10 * 1024 * 1024;

/// Paths exempt from every concept rule, always. The declaration names its own
/// literals, and Guardian's own metadata records the violations verbatim — a
/// rule that flagged either would flag the act of declaring or recording it.
const always_exempt = [_][]const u8{ "guardian.toml", ".guardian/" };

/// Directory names a `files` glob never descends into: dot-directories (VCS
/// metadata, Guardian state, editor and agent scratch) and build output. None
/// of them is project source, and on a real repo `.git` / `.zig-cache` /
/// `zig-out` dwarf everything a rule could legitimately name.
const skip_dir_names = [_][]const u8{ "zig-out", "zig-cache", "node_modules" };

// ── Wildcard matching ───────────────────────────────────────────────────

/// True when `c` may be consumed by a `*`. Whitespace, quotes and structural
/// punctuation are excluded so a pattern can never swallow across tokens:
/// `In*.Cu` matches `In3.Cu` inside a string but cannot span `"In1", "x.Cu"` —
/// and cannot bridge minified code, where `...cInterpolant=jo,t.Cu...` in a
/// vendored three.js once read as an inner copper layer. Whitespace exclusion
/// also means a match never crosses a newline, which keeps the reported line
/// exact.
fn wildcardByte(c: u8) bool {
    if (std.ascii.isWhitespace(c)) return false;
    return switch (c) {
        '"', '\'', '`', ',', ';', '=', ':', '(', ')', '{', '}', '[', ']' => false,
        else => true,
    };
}

/// Half-open byte range of one match. The END is carried because the report
/// names the text a wildcard actually matched (`In1.Cu`), not the pattern that
/// found it (`In*.Cu`) — with the pattern alone a reader cannot tell a real hit
/// from a coincidence without opening the file.
const Span = struct { start: usize, end: usize };

/// The end offset of `pattern`'s match starting exactly at `at`, or null. `*` is
/// the only metacharacter — every other byte, `.` and `#` included, is literal —
/// and it matches ONE OR MORE `wildcardByte`s. A run of consecutive `*`
/// collapses to one, so `In**.Cu` is `In*.Cu`. Backtracks, so an early gap match
/// that dead-ends never hides a later one.
fn matchAt(text: []const u8, at: usize, pattern: []const u8) ?usize {
    if (pattern.len == 0) return at;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        if (!std.mem.startsWith(u8, text[at..], pattern)) return null;
        return at + pattern.len;
    };
    const literal = pattern[0..star];
    if (!std.mem.startsWith(u8, text[at..], literal)) return null;
    return matchStar(text, at + literal.len, pattern[star..]);
}

/// Matches a pattern that opens with a `*` run: consume at least one wildcard
/// byte, then match the remainder anchored. A trailing `*` needs a byte too, so
/// `In*` does not match a bare `In` — and it then takes the whole run, since
/// what the reader wants to see is the token that matched, not its first byte.
fn matchStar(text: []const u8, at: usize, pattern: []const u8) ?usize {
    var rest = pattern;
    while (rest.len > 0 and rest[0] == '*') rest = rest[1..];
    var cursor = at;
    if (rest.len == 0) {
        while (cursor < text.len and wildcardByte(text[cursor])) cursor += 1;
        return if (cursor > at) cursor else null;
    }
    while (cursor < text.len and wildcardByte(text[cursor])) {
        cursor += 1;
        if (matchAt(text, cursor, rest)) |end| return end;
    }
    return null;
}

/// The leftmost `pattern` match in `text` at or after `from`, or null when there
/// is none. An empty pattern matches nothing (the parser rejects one, so this is
/// the total-function guarantee rather than a reachable case).
fn findPattern(text: []const u8, pattern: []const u8, from: usize) ?Span {
    if (pattern.len == 0) return null;
    var i = from;
    while (i < text.len) : (i += 1) {
        if (matchAt(text, i, pattern)) |end| return .{ .start = i, .end = end };
    }
    return null;
}

// ── Scrubbing: the contexts the scan must not judge ─────────────────────

/// A copy of `content` with the exempt contexts blanked to spaces: every line
/// whose first non-whitespace bytes open a `//` comment, every line-leading
/// `/* … */` block in a `.css` file, and — when a Zig parse `tree` is supplied
/// — every `test` declaration's span. Bytes are replaced, never removed, and a
/// newline is never one of them, so each surviving occurrence keeps its exact
/// offset AND its exact source line.
fn scrubbed(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    tree: ?*const Ast,
) Allocator.Error![]u8 {
    const out = try allocator.dupe(u8, content);
    blankCommentLines(out);
    if (std.mem.endsWith(u8, rel_path, ".css")) blankCssCommentLines(out);
    if (tree) |t| try blankTestBlocks(allocator, out, t);
    return out;
}

/// Overwrites `span` with spaces, leaving its newlines in place. A blanked
/// region that swallowed its newlines would shift every LATER occurrence's
/// reported line up by the number it ate — which is how a hit at source line
/// 3951 once got reported as 3820, past a file's worth of blanked test blocks.
fn blankSpan(span: []u8) void {
    for (span) |*byte| {
        if (byte.* != '\n') byte.* = ' ';
    }
}

/// Blanks each line that IS a `//` comment — first non-whitespace is `//`
/// (which covers `///` and `//!`). Run over every file: a line-leading `//` is
/// unambiguous in each `//` language a rule can glob (Zig, JS, TS), and in a
/// language without `//` comments it simply matches nothing. CSS is the
/// exception worth naming — its only comment syntax is `/* … */`, handled by
/// `blankCssCommentLines`. Trailing comments are left alone: whether a mid-line
/// `//` opens a comment or sits inside a string is a per-language question. A
/// hash-comment language gets no skip at all — `#` opens the very hex literals
/// a palette rule exists to match.
fn blankCommentLines(text: []u8) void {
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        var i = line_start;
        while (i < line_end and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i + 1 < line_end and text[i] == '/' and text[i + 1] == '/') {
            @memset(text[i..line_end], ' ');
        }
        line_start = line_end + 1;
    }
}

/// Blanks every line-leading CSS block comment, `/*` through the `*/` that
/// closes it — including the lines between, since a prose header comment is
/// usually several. CSS has no `//`, so without this a `.css` file pulled in by
/// a `files` glob had NO comment exemption at all, and a pure-prose comment
/// above a rule froze the stylesheet into the ledger.
fn blankCssCommentLines(text: []u8) void {
    var line_start: usize = 0;
    var open = false;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        open = blankCssCommentOnLine(text, line_start, line_end, open);
        line_start = line_end + 1;
    }
}

/// Blanks one line's share of a line-leading CSS comment and returns whether
/// the comment is still open on the next line. `open` says an earlier line
/// opened one. Bytes after the closing `*/` are left alone, exactly as a
/// trailing `//` is: what follows on that line is code and counts. A block
/// opened MID-line is not tracked at all, for the same reason — deciding
/// whether that `/*` is a comment or string content needs the per-language
/// lexer this check refuses to be.
fn blankCssCommentOnLine(text: []u8, line_start: usize, line_end: usize, open: bool) bool {
    const from = if (open) line_start else cssCommentStart(text, line_start, line_end) orelse return false;
    // `/*/` does not close itself, so a fresh opener starts looking past its
    // own delimiter; a continuation line looks from its first byte.
    const search = if (open) from else from + 2;
    const close = std.mem.indexOfPos(u8, text[0..line_end], search, "*/");
    @memset(text[from..(if (close) |at| at + 2 else line_end)], ' ');
    return close == null;
}

/// The offset of a `/*` that OPENS the line — first non-whitespace — or null.
fn cssCommentStart(text: []const u8, line_start: usize, line_end: usize) ?usize {
    var i = line_start;
    while (i < line_end and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i + 1 < line_end and text[i] == '/' and text[i + 1] == '*') return i;
    return null;
}

/// Blanks every `test` declaration's whole span. `decls.collectDecls` descends
/// into container members, so a test nested inside a struct is blanked too.
/// The bounds guard is defensive only: the tree was parsed from these bytes.
fn blankTestBlocks(allocator: Allocator, text: []u8, tree: *const Ast) Allocator.Error!void {
    for (try decls.collectDecls(allocator, tree)) |decl| {
        if (tree.nodeTag(decl) != .test_decl) continue;
        const last = tree.lastToken(decl);
        const start = tree.tokenStart(tree.firstToken(decl));
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        if (start >= end or end > text.len) continue;
        blankSpan(text[start..end]);
    }
}

// ── Per-file analysis ───────────────────────────────────────────────────

/// One match of one declared spelling: where it starts in the file and how many
/// bytes it covers. The length is what lets the report quote the text that
/// matched — for a literal that is the literal, for a pattern it is the concrete
/// instance the wildcard resolved to.
const Occurrence = struct {
    offset: usize,
    len: usize,
};

fn byOffset(_: void, a: Occurrence, b: Occurrence) bool {
    return a.offset < b.offset;
}

/// Every occurrence of `rule`'s literals and patterns in `content`, ascending
/// by offset. Overlapping hits each count: the scan advances one byte past a
/// match rather than past its end, so a doubled spelling is never silently one.
fn occurrencesOf(
    allocator: Allocator,
    content: []const u8,
    rule: config.ConceptRule,
) Allocator.Error![]Occurrence {
    var found: std.ArrayList(Occurrence) = .empty;
    for (rule.literals) |literal| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, content, from, literal)) |at| : (from = at + 1) {
            try found.append(allocator, .{ .offset = at, .len = literal.len });
        }
    }
    for (rule.patterns) |pattern| {
        var from: usize = 0;
        while (findPattern(content, pattern, from)) |span| : (from = span.start + 1) {
            try found.append(allocator, .{ .offset = span.start, .len = span.end - span.start });
        }
    }
    const out = try found.toOwnedSlice(allocator);
    std.mem.sort(Occurrence, out, {}, byOffset);
    return out;
}

/// True when `rel_path` is one of the files `rule` says the concept lives in.
/// Owner paths use Guardian's ordinary path-glob syntax (`walk.matchGlob`), so a
/// bare path is a substring match and `src/board/*` covers a subtree.
fn owns(rule: config.ConceptRule, rel_path: []const u8) bool {
    for (rule.owner) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// True when `rel_path` is exempt from every rule by construction — the
/// guardian.toml that declares the literals, or Guardian's own `.guardian/`
/// state that records the findings.
fn selfExempt(rel_path: []const u8) bool {
    for (always_exempt) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    }
    return false;
}

/// The bytes `occurrence` matched, capped at `max_spelling_bytes` on a UTF-8
/// boundary so one wildcard hit in a minified bundle cannot flood the line. The
/// caller marks a shortened result by comparing lengths.
fn matchedText(content: []const u8, occurrence: Occurrence) []const u8 {
    const raw = content[occurrence.offset..][0..occurrence.len];
    if (raw.len <= max_spelling_bytes) return raw;
    var end: usize = max_spelling_bytes;
    while (end > 0 and raw[end] & 0xC0 == 0x80) end -= 1;
    return raw[0..end];
}

/// Renders the first `max_reported_lines` occurrences as
/// `line 12: "F.Cu", line 40: "In1.Cu"`, with a trailing `…` when more were
/// found. The matched text rides ALONG each line because a rule with several
/// literals — one of which is also an ordinary identifier substring — otherwise
/// makes every listed line a file to open by hand before it can be triaged.
fn formatLines(allocator: Allocator, content: []const u8, found: []const Occurrence) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const shown = @min(found.len, max_reported_lines);
    for (found[0..shown], 0..) |occurrence, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const text = matchedText(content, occurrence);
        const rendered = try std.fmt.allocPrint(allocator, "line {d}: \"{s}{s}\"", .{
            lineOf(content, occurrence.offset),
            text,
            if (text.len < occurrence.len) "\u{2026}" else "",
        });
        defer allocator.free(rendered);
        try buf.appendSlice(allocator, rendered);
    }
    if (found.len > shown) try buf.appendSlice(allocator, ", \u{2026}");
    return buf.toOwnedSlice(allocator);
}

/// Renders a rule's owner list as `"a, b"`, or the `no_owner` placeholder.
fn formatOwner(allocator: Allocator, rule: config.ConceptRule) Allocator.Error![]const u8 {
    if (rule.owner.len == 0) return no_owner;
    return std.mem.join(allocator, ", ", rule.owner);
}

/// Builds the single violation for one drifted (file, concept) pair.
fn violationFor(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    rule: config.ConceptRule,
    found: []const Occurrence,
) Allocator.Error!reporter.Violation {
    const lines = try formatLines(allocator, content, found);
    const message = try std.fmt.allocPrint(
        allocator,
        "concept '{s}' appears {d} time(s) ({s}) — owned by {s} — {s}",
        .{
            rule.name,
            found.len,
            lines,
            try formatOwner(allocator, rule),
            rule.reason orelse no_reason,
        },
    );
    // Identity is the file and the CONCEPT, never the literal or the count: a
    // second drifted spelling in an already-frozen file must keep the same
    // baseline key, so it cannot arrive as a brand-new violation that a stale
    // key would have to be re-accepted for. What that costs is stated in
    // README/SPEC: growth inside a frozen file is invisible until the file is
    // cleaned, and `[baseline] deny_growth = ["concept"]` is the way to freeze
    // the counts too.
    const identity = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ rel_path, rule.name });
    return .{
        .check = check_name,
        .file = rel_path,
        .line = lineOf(content, found[0].offset),
        .message = message,
        .fix_hint = fix_hint,
        .identity = identity,
        .metric = found.len,
    };
}

/// Pure core: one violation per rule whose concept appears in this file outside
/// its owner. Takes plain bytes, so the same function judges a `.zig` file from
/// the shared source index (whose pre-parsed `tree` exempts its test blocks)
/// and a `.css` file pulled in by a `files` glob (`tree` = null).
pub fn analyzeFile(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    tree: ?*const Ast,
    rules: []const config.ConceptRule,
) Allocator.Error![]const reporter.Violation {
    if (selfExempt(rel_path) or rules.len == 0) return &.{};
    const text = try scrubbed(allocator, rel_path, content, tree);
    var violations: std.ArrayList(reporter.Violation) = .empty;
    for (rules) |rule| {
        if (owns(rule, rel_path)) continue;
        const found = try occurrencesOf(allocator, text, rule);
        if (found.len == 0) continue;
        try violations.append(allocator, try violationFor(allocator, rel_path, text, rule, found));
    }
    return violations.toOwnedSlice(allocator);
}

// ── Run: the default source set plus any `files` globs ──────────────────

/// True when a configured path glob names `rel_path`. Both skip lists this
/// check honors are path globs of the same shape, so they share one matcher.
fn skipPath(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// Shared across both scans: where findings land, and the paths this check
/// never judges.
const ScanCtx = struct {
    allocator: Allocator,
    rules: []const config.ConceptRule,
    /// Path globs no rule is applied to: a `[[allow]] check = "concept"` entry,
    /// plus the top-level `exclude` list. `exclude` is folded in here because
    /// its contract is "no check ever sees a file whose path matches", and the
    /// `files` scan reads from disk rather than through the shared source index
    /// that applies it — so honoring it is this check's own job.
    skip: []const []const u8,
    violations: *std.ArrayList(reporter.Violation),

    /// Judges one file against exactly `rules` — the subset that claims it. The
    /// glob scan hands its own per-file subset here (no parse tree: those files
    /// are CSS/JS/anything); the source scan hands the whole set plus the
    /// index's pre-parsed tree, which is what "no `files` key" means.
    fn scanWith(
        self: *ScanCtx,
        rel_path: []const u8,
        content: []const u8,
        tree: ?*const Ast,
        rules: []const config.ConceptRule,
    ) Allocator.Error!void {
        if (skipPath(self.skip, rel_path)) return;
        const found = try analyzeFile(self.allocator, rel_path, content, tree, rules);
        try self.violations.appendSlice(self.allocator, found);
    }
};

fn sourceVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try ctx.scanWith(entry.rel_path, entry.content, entry.tree, ctx.rules);
}

/// True when a directory is never descended into while expanding a `files`
/// glob (see `skip_dir_names`; every dot-directory is skipped too).
fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dir_names) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// True when one of `rule`'s own `files` globs names `rel_path`.
fn namesPath(rule: config.ConceptRule, rel_path: []const u8) bool {
    for (rule.files) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// The rules whose own `files` globs name `rel_path`.
///
/// A rule's `files` scopes THAT rule. Previously every rule declaring the key
/// was applied to the UNION of their globs, so a JS-only rule reported Zig
/// offenders and a Zig-only rule reported CSS ones — the file set read as "also
/// scan these" rather than as the rule's own domain, which is what a per-rule
/// key can only mean.
fn rulesNaming(
    allocator: Allocator,
    rules: []const config.ConceptRule,
    rel_path: []const u8,
) Allocator.Error![]const config.ConceptRule {
    var out: std.ArrayList(config.ConceptRule) = .empty;
    for (rules) |rule| {
        if (namesPath(rule, rel_path)) try out.append(allocator, rule);
    }
    return out.toOwnedSlice(allocator);
}

/// Reads and scans one globbed file against the rules that named it. Matching
/// happens BEFORE the read, so a glob that names `*.css` never opens the
/// repository's binaries — and a file a rule did name is read whatever its
/// extension. A globbed `.zig` parses its own tree: a broad rule names
/// `src/**` alongside its JS and CSS, and a test block is exempt wherever the
/// file was reached — the shared index serves only the no-`files` scan.
fn scanGlobbedFile(ctx: *ScanCtx, dir: fs.Dir, name: []const u8, rel_path: []const u8) !void {
    const rules = try rulesNaming(ctx.allocator, ctx.rules, rel_path);
    if (rules.len == 0) return;
    const content = try dir.readFileAlloc(ctx.allocator, name, glob_read_limit);
    if (std.mem.endsWith(u8, rel_path, ".zig")) {
        const source = try ctx.allocator.dupeSentinel(u8, content, 0);
        var tree = try Ast.parse(ctx.allocator, source, .{});
        return ctx.scanWith(rel_path, source, &tree, rules);
    }
    try ctx.scanWith(rel_path, content, null, rules);
}

/// Walks `dir` recursively, scanning every file a `files` glob names. A glob
/// matching nothing is silence, not an error: a project may declare the concept
/// before the owner or the drifting asset exists.
fn scanGlobs(ctx: *ScanCtx, dir: fs.Dir, prefix: []const u8) walk.WalkError!void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try ctx.allocator.dupe(u8, entry.name);
        switch (entry.kind) {
            .directory => {
                if (skipDir(entry.name)) continue;
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try scanGlobs(ctx, sub, rel);
            },
            .file => try scanGlobbedFile(ctx, dir, entry.name, rel),
            else => {},
        }
    }
}

/// Which file set a rule is judged against: the source set Guardian already
/// walks (no `files` key), or exactly what the rule's `files` globs name.
const ScanSet = enum { source, globs };

/// The subset of `rules` whose scan set is `want`.
fn rulesFor(
    allocator: Allocator,
    rules: []const config.ConceptRule,
    want: ScanSet,
) Allocator.Error![]const config.ConceptRule {
    var out: std.ArrayList(config.ConceptRule) = .empty;
    for (rules) |rule| {
        const set: ScanSet = if (rule.files.len > 0) .globs else .source;
        if (set == want) try out.append(allocator, rule);
    }
    return out.toOwnedSlice(allocator);
}

/// Entry point for the concept check (opt-in: declare `[[concept]]` entries).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const rules = ctx_param.cfg.concept_rules;
    if (rules.len == 0) {
        reporter.ok("concept: no [[concept]] rules configured", .{});
        return;
    }

    var found: std.ArrayList(reporter.Violation) = .empty;
    const skip = try std.mem.concat(allocator, []const u8, &.{
        ctx_param.cfg.extraAllowed(check_name),
        ctx_param.cfg.exclude,
    });
    const source_rules = try rulesFor(allocator, rules, .source);
    if (source_rules.len > 0) {
        var src_ctx: ScanCtx = .{
            .allocator = allocator,
            .rules = source_rules,
            .skip = skip,
            .violations = &found,
        };
        try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{
            .ctx = &src_ctx,
            .visit = sourceVisit,
        });
    }
    const glob_rules = try rulesFor(allocator, rules, .globs);
    if (glob_rules.len > 0) {
        var glob_ctx: ScanCtx = .{
            .allocator = allocator,
            .rules = glob_rules,
            .skip = skip,
            .violations = &found,
        };
        var root = try fs.cwd().openDir(ctx_param.project_dir, .{ .iterate = true });
        defer root.close();
        try scanGlobs(&glob_ctx, root, "");
    }

    if (found.items.len == 0) {
        reporter.ok("concept: no drifted concepts ({d} rule(s))", .{rules.len});
        return;
    }
    reporter.fail("concept FAILED ({d} file(s) outside an owner)", .{found.items.len});
    // emitQuiet, not emit: one shared `fix:` line closes the list below, and
    // repeating a near-identical remedy under every finding is console noise.
    // The hint still rides each record into last-run.jsonl, which has no
    // "beneath the list".
    for (found.items) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const layer_rule = config.ConceptRule{
    .name = "layer-names",
    .literals = &.{ "F.Cu", "B.Cu" },
    .patterns = &.{"In*.Cu"},
    .owner = &.{"src/board_layers.zig"},
    .reason = "layer names come from board_layers.LayerTable",
};

const test_rules = [_]config.ConceptRule{layer_rule};

// spec: Concept Ownership - Flags a concept literal used outside its owner

test "analyzeFile flags an owned literal appearing in another file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, "src/render.zig",
        \\const top = "F.Cu";
        \\const bottom = "B.Cu";
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(check_name, out[0].check);
    // Identity carries its own file: `<file>|<concept>` is a tier-1 key, used
    // whole and never re-qualified (violation_key.fromRecord).
    try testing.expectEqualStrings("src/render.zig|layer-names", out[0].identity.?);
    try testing.expectEqual(@as(u64, 2), out[0].metric.?);
}

// spec: Concept Ownership - Ignores a concept literal inside its owner file

test "analyzeFile ignores the owner's own occurrences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), "src/board_layers.zig",
        \\pub const front = "F.Cu";
        \\pub const back = "B.Cu";
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Concept Ownership - Passes trivially when no concept rules are configured

test "analyzeFile finds nothing when no rules are configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), "src/render.zig",
        \\const top = "F.Cu";
    , null, &.{});
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Concept Ownership - Skips a line-leading comment when counting occurrences

test "analyzeFile skips comment lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A comment line cannot disagree with the owner at runtime, and counting it
    // froze whole files into the ledger — where the file's REAL drift then
    // hides behind the `<file>|<concept>` identity forever.
    const out = try analyzeFile(arena.allocator(), "src/render.zig",
        \\// the front copper layer is F.Cu
        \\/// B.Cu is the back face
        \\const x = 1;
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Concept Ownership - Counts a trailing comment on a code line as an occurrence

test "analyzeFile counts a code line whole, trailing comment included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Whether a mid-line `//` opens a comment or sits inside a string
    // ("https://…") is a per-language lexing question, so a code line always
    // counts whole.
    const out = try analyzeFile(arena.allocator(), "src/render.zig",
        \\const x = 1; // F.Cu
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u64, 1), out[0].metric.?);
}

// spec: Concept Ownership - Skips a Zig test block's occurrences when a parse tree is available

test "analyzeFile skips golden literals inside a test block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try a.dupeSentinel(u8,
        \\const top = "F.Cu";
        \\test "golden pins the wire format" {
        \\    const want = "B.Cu In2.Cu";
        \\    _ = want;
        \\}
    , 0);
    var tree = try Ast.parse(a, src, .{});
    const out = try analyzeFile(a, "src/render.zig", src, &tree, &test_rules);
    // The const outside the test still counts; the goldens inside do not — a
    // test's literal is the independent witness of the owner's value, not a
    // second authority that can drift.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u64, 1), out[0].metric.?);
}

// spec: Concept Ownership - Reports an occurrence line in source coordinates past every blanked span

test "analyzeFile reports the true source line after a blanked comment and test block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try a.dupeSentinel(u8,
        \\// a prose header that mentions
        \\// nothing this rule owns
        \\const unrelated = 0;
        \\test "golden pins the wire format" {
        \\    const want = "In2.Cu";
        \\    _ = want;
        \\}
        \\const top = "F.Cu";
    , 0);
    var tree = try Ast.parse(a, src, .{});
    const out = try analyzeFile(a, "src/render.zig", src, &tree, &test_rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    // Line 8 as the file is written. Blanking that ate the test block's four
    // newlines would report 5 — the shape that made every number in a finding
    // something to re-grep before it could be used.
    try testing.expectEqual(@as(u32, 8), out[0].line.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "line 8: \"F.Cu\"") != null);
}

// spec: Concept Ownership - Skips a line-leading CSS block comment but counts the code after its close

test "analyzeFile blanks a whole-line CSS comment and keeps what follows exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, "assets/theme.css",
        \\/* the front copper layer, F.Cu, is painted
        \\   with the colour below */ .front::after { content: "B.Cu"; }
        \\.in1::after { content: "In1.Cu"; }
    , null, &test_rules);
    // CSS has no `//`, so before this a globbed stylesheet had no comment
    // exemption at all and a pure-prose header froze the file. The rule is the
    // `//` one: the block is blanked through its `*/`, and the code sharing the
    // closing line still counts — at its own, unshifted line number.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u64, 2), out[0].metric.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "(line 2: \"B.Cu\", line 3: \"In1.Cu\")") != null);
}

// spec: Concept Ownership - Counts a trailing CSS block comment on a code line as an occurrence

test "analyzeFile counts a CSS code line whole, trailing block comment included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, "assets/theme.css",
        \\.front { color: #c83434; } /* the F.Cu paint */
    , null, &test_rules);
    // Only a LINE-LEADING block is skipped: deciding whether a mid-line `/*`
    // opens a comment or sits inside a string is the per-language lexing
    // question this check refuses to answer, exactly as for a trailing `//`.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u64, 1), out[0].metric.?);
}

// spec: Concept Ownership - Reports one violation per file and concept with the occurrence count and lines

test "analyzeFile reports one violation naming the count, lines, owner and reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, "src/render.zig",
        \\const top = "F.Cu";
        \\const mid = "In1.Cu";
        \\const bottom = "B.Cu";
    , null, &test_rules);
    // Three matched spellings, one violation: the subject is the (file, concept)
    // pair, not each literal.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(
        "src/render.zig:1: concept 'layer-names' appears 3 time(s) " ++
            "(line 1: \"F.Cu\", line 2: \"In1.Cu\", line 3: \"B.Cu\") " ++
            "— owned by src/board_layers.zig — layer names come from board_layers.LayerTable",
        try reporter.flatLine(a, out[0]),
    );
}

// spec: Concept Ownership - Quotes the text matched at each reported occurrence line

test "analyzeFile names which spelling matched on each listed line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The triage question a line number alone cannot answer: of a rule's five
    // spellings, WHICH one fired here — the wire-format key or the identifier
    // that merely contains it? A pattern reports the concrete text it resolved
    // to (`In2.Cu`), not the pattern that found it (`In*.Cu`).
    const out = try analyzeFile(a, "src/render.zig",
        \\const mid = "In2.Cu";
        \\const bottom = "B.Cu";
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "(line 1: \"In2.Cu\", line 2: \"B.Cu\")") != null);
}

// spec: Concept Ownership - Elides a matched text longer than the quoted cap

test "formatLines truncates a long match on a UTF-8 boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A wildcard match is bounded only by its token, so a minified bundle can
    // hand the report a token wider than the terminal. The cut lands between
    // codepoints: the multi-byte `é` straddles byte 40 and is dropped whole
    // rather than printed as a lone continuation byte.
    const filler = try a.alloc(u8, max_spelling_bytes - 3);
    @memset(filler, 'x');
    const content = try std.mem.concat(a, u8, &.{ "aa", filler, "\u{e9}bb" });
    const found = [_]Occurrence{.{ .offset = 0, .len = content.len }};
    const rendered = try formatLines(a, content, &found);
    const want = try std.mem.concat(a, u8, &.{ "line 1: \"aa", filler, "\u{2026}\"" });
    try testing.expectEqualStrings(want, rendered);
}

// spec: Concept Ownership - Names the missing owner and reason when a rule declares neither

test "analyzeFile names an absent owner and reason in the message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bare = [_]config.ConceptRule{.{ .name = "hexes", .literals = &.{"#C83434"} }};
    const out = try analyzeFile(a, "src/render.zig",
        \\const front = "#C83434";
    , null, &bare);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0].message, no_owner) != null);
    try testing.expect(std.mem.endsWith(u8, out[0].message, no_reason));
}

// spec: Concept Ownership - Caps the listed occurrence lines and keeps the full count

test "analyzeFile lists at most the first few lines but counts every occurrence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, "src/render.zig",
        \\const a = "F.Cu";
        \\const b = "F.Cu";
        \\const c = "F.Cu";
        \\const d = "F.Cu";
        \\const e = "F.Cu";
        \\const f = "F.Cu";
        \\const g = "F.Cu";
    , null, &test_rules);
    try testing.expectEqual(@as(u64, 7), out[0].metric.?);
    try testing.expect(std.mem.indexOf(
        u8,
        out[0].message,
        "(line 1: \"F.Cu\", line 2: \"F.Cu\", line 3: \"F.Cu\", line 4: \"F.Cu\", line 5: \"F.Cu\", \u{2026})",
    ) != null);
}

// spec: Concept Ownership - Exempts guardian.toml and the .guardian directory from every rule

test "analyzeFile never flags the declaration or Guardian's own metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const declaration =
        \\[[concept]]
        \\literals = ["F.Cu", "B.Cu"]
    ;
    try testing.expectEqual(@as(usize, 0), (try analyzeFile(a, "guardian.toml", declaration, null, &test_rules)).len);
    const baselined = "concept|src/render.zig|layer-names F.Cu";
    try testing.expectEqual(
        @as(usize, 0),
        (try analyzeFile(a, ".guardian/baselines/concept.txt", baselined, null, &test_rules)).len,
    );
}

// spec: Concept Ownership - Matches a wildcard against one or more characters that are not whitespace, quotes or structural punctuation

test "matchAt requires at least one wildcard byte and never spans a quote" {
    // The motivating shape: one pattern covering In1.Cu … In4.Cu.
    try testing.expect(findPattern("x = \"In3.Cu\";", "In*.Cu", 0) != null);
    try testing.expect(findPattern("x = \"In12.Cu\";", "In*.Cu", 0) != null);
    // `*` is one-or-more, so the zero-width spelling is not a match.
    try testing.expect(findPattern("x = \"In.Cu\";", "In*.Cu", 0) == null);
    // It cannot swallow a quote or whitespace, so two adjacent tokens never
    // fuse into one match.
    try testing.expect(findPattern("[\"In1\", \"x.Cu\"]", "In*.Cu", 0) == null);
    try testing.expect(findPattern("In 1.Cu", "In*.Cu", 0) == null);
    // A match therefore never crosses a newline, which is what makes the one
    // reported line exact.
    try testing.expect(findPattern("In\n1.Cu", "In*.Cu", 0) == null);
    // Nor structural punctuation, so minified code cannot fuse two tokens into
    // one match: a vendored three.js read as an inner copper layer through
    // `Interpolant=jo,t.Cu` until `,`/`=` stopped the gap.
    try testing.expect(findPattern("cInterpolant=jo,t.Cu", "In*.Cu", 0) == null);
    try testing.expect(findPattern("In1;x.Cu", "In*.Cu", 0) == null);
    try testing.expect(findPattern("In(3).Cu", "In*.Cu", 0) == null);
}

// spec: Concept Ownership - Treats a run of wildcards as one and matches leading and trailing wildcards

test "matchAt collapses star runs and anchors leading and trailing stars" {
    // A run of stars is one star: `In**.Cu` is `In*.Cu`, not "two gaps".
    try testing.expect(findPattern("In3.Cu", "In**.Cu", 0) != null);
    try testing.expect(findPattern("In.Cu", "In**.Cu", 0) == null);
    // Leading `*`: at least one wildcard byte must precede the literal.
    try testing.expectEqual(@as(usize, 0), findPattern("xIn3.Cu", "*.Cu", 0).?.start);
    try testing.expect(findPattern(".Cu", "*.Cu", 0) == null);
    // Trailing `*`: at least one wildcard byte must follow it, and it then takes
    // the whole run — the reported span is the token, not its first byte.
    try testing.expectEqual(@as(usize, 3), findPattern("In3", "In*", 0).?.end);
    try testing.expectEqual(@as(usize, 6), findPattern("In3.Cu", "In*", 0).?.end);
    try testing.expect(findPattern("In", "In*", 0) == null);
    // A pattern with no `*` is an exact substring, and an empty one — which the
    // parser refuses — matches nothing rather than everything.
    try testing.expect(findPattern("F.Cu", "F.Cu", 0) != null);
    try testing.expect(findPattern("anything", "", 0) == null);
}

// spec: Concept Ownership - Resumes scanning after a candidate start that does not match

test "findPattern keeps scanning past a start position that fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The first `In` opens a candidate that cannot close (no character between
    // `In` and `.Cu`); the scan must continue rather than report the file clean.
    try testing.expectEqual(@as(usize, 6), findPattern("In.Cu In3.Cu", "In*.Cu", 0).?.start);
    // `from` resumes after a hit, which is how repeat occurrences are counted.
    try testing.expectEqual(@as(usize, 7), findPattern("In3.Cu In4.Cu", "In*.Cu", 1).?.start);
    // Two gaps in one pattern, each needing its own character.
    try testing.expect(findPattern("a-b-b-c", "a*b*c", 0) != null);
    try testing.expect(findPattern("a-bc", "a*b*c", 0) == null);
}

// spec: Concept Ownership - Applies a rule to only its own concept when several are declared

test "analyzeFile keeps two concepts' findings apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.ConceptRule{
        layer_rule,
        .{ .name = "layer-colors", .literals = &.{"#C83434"}, .owner = &.{"src/palette.zig"} },
    };
    // The palette owns the hex but not the layer name, so exactly one of the two
    // rules fires here.
    const out = try analyzeFile(a, "src/palette.zig",
        \\pub const front_hex = "#C83434";
        \\pub const front_layer = "F.Cu";
    , null, &rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/palette.zig|layer-names", out[0].identity.?);
}

// spec: Concept Ownership - Skips build output and dot directories when expanding a files glob

test "skipDir prunes VCS, Guardian state and build output" {
    try testing.expect(skipDir(".git"));
    try testing.expect(skipDir(".zig-cache"));
    try testing.expect(skipDir(".guardian"));
    try testing.expect(skipDir("zig-out"));
    try testing.expect(skipDir("node_modules"));
    // Ordinary source directories are walked.
    try testing.expect(!skipDir("src"));
    try testing.expect(!skipDir("assets"));
}

// spec: Concept Ownership - Skips a path an allow entry or a top-level exclude glob names

test "skipPath drops a path either skip list names" {
    // Both lists reaching this check are ordinary path globs: `[[allow]] check =
    // "concept"` (this check's own exemptions) and the top-level `exclude`
    // (files no check may see at all), concatenated by `run`.
    const skip = [_][]const u8{ "src/vendor/*", "src/generated/*" };
    try testing.expect(skipPath(&skip, "src/vendor/theirs.zig"));
    try testing.expect(skipPath(&skip, "src/generated/tables.zig"));
    try testing.expect(!skipPath(&skip, "src/render.zig"));
    // An empty list — the zero-config default — skips nothing.
    try testing.expect(!skipPath(&.{}, "src/render.zig"));
}

// spec: Concept Ownership - Splits rules by whether they declare a files glob

test "rulesFor partitions the configured rules by scan set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.ConceptRule{
        layer_rule,
        .{ .name = "layer-colors", .literals = &.{"#C83434"}, .files = &.{"*.css"} },
    };
    const source_set = try rulesFor(a, &rules, .source);
    try testing.expectEqual(@as(usize, 1), source_set.len);
    try testing.expectEqualStrings("layer-names", source_set[0].name);
    const glob_set = try rulesFor(a, &rules, .globs);
    try testing.expectEqual(@as(usize, 1), glob_set.len);
    try testing.expectEqualStrings("layer-colors", glob_set[0].name);
}

// spec: Concept Ownership - Scopes each rule's files glob to that rule alone

test "scanGlobs never judges a file against another rule's files glob" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.ConceptRule{
        // A CSS-scoped rule whose spelling occurs only in the fixture's Zig
        // source, and a Zig-scoped rule whose spelling occurs only in its CSS.
        // Under the old union scan each fired on the OTHER rule's file.
        .{ .name = "css-only", .literals = &.{"std.debug.print"}, .files = &.{"assets/*.css"} },
        .{ .name = "zig-only", .literals = &.{"#C83434"}, .files = &.{"src/*.zig"} },
        // A correctly scoped rule, so a green result cannot come from the scan
        // simply reading nothing.
        .{ .name = "layer-colors", .literals = &.{"#C83434"}, .files = &.{"assets/*.css"} },
    };
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .rules = &rules, .skip = &.{}, .violations = &violations };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try scanGlobs(&ctx, root, "");
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqualStrings("assets/theme.css|layer-colors", violations.items[0].identity.?);
}

// spec: Concept Ownership - Parses a globbed Zig file so its test blocks are exempt there too

test "scanGlobs exempts test blocks in a Zig file a files glob names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "hello world" occurs in the fixture only inside `test "join"`; the
    // debug-print spelling occurs in `pub fn main`. A rule that reaches the
    // file through a `files` glob must exempt the first and flag the second —
    // the glob path parses its own tree, since the shared index serves only
    // the no-`files` scan. The second rule doubles as proof the file was read
    // at all, so the zero cannot be the glob silently matching nothing.
    const rules = [_]config.ConceptRule{
        .{ .name = "greeting", .literals = &.{"hello world"}, .owner = &.{"src/greeting.zig"}, .files = &.{"src/main.zig"} },
        .{ .name = "debug-print", .literals = &.{"std.debug.print"}, .owner = &.{"src/logging.zig"}, .files = &.{"src/main.zig"} },
    };
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .rules = &rules, .skip = &.{}, .violations = &violations };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try scanGlobs(&ctx, root, "");
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqualStrings("src/main.zig|debug-print", violations.items[0].identity.?);
}

// spec: Concept Ownership - Scans a globbed non-Zig file and ignores paths no glob names

test "scanGlobs reads a globbed asset outside the Zig source set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.ConceptRule{.{
        .name = "layer-colors",
        .literals = &.{"#C83434"},
        .owner = &.{"src/board_layers.zig"},
        .files = &.{"assets/*.css"},
    }};
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .rules = &rules, .skip = &.{}, .violations = &violations };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try scanGlobs(&ctx, root, "");
    // The stylesheet is not a .zig file, so nothing but a `files` glob could
    // reach it — and the rest of the fixture project, which the glob does not
    // name, is never read.
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqualStrings("assets/theme.css|layer-colors", violations.items[0].identity.?);
}
