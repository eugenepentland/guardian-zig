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
//! REAL: a comment line cannot disagree with the owner at runtime, and a Zig
//! `test` block's literal is the independent golden a sync-triangle test is
//! supposed to spell. Both — and the every-extension file walk a `files` glob
//! needs — live in `lexical_scan.zig`, shared with `canonical-idiom`, so the two
//! relational checks can never disagree about what a lexical scan may judge.
//!
//! **`require_in` is the same relation read the other way.** Ownership is
//! permissive — only the owner may spell it — and that direction cannot see the
//! failure that hurts most: a mirror the project DECIDED to keep, which quietly
//! stops matching. The motivating case (eda, 2026-08-12, commit 51bff373): a DRC
//! kind string was renamed in Zig and the viewer's hand-mirrored JS branch went
//! dead. 531 grep-marker tests missed it, because no marker watched that string.
//! Worse, the JS side's 8-entry `DRC_BLOCK` gate table fails PERMISSIVELY on a
//! rename — a kind nobody recognises simply stops blocking. `require_in` names
//! those mirrors and demands that EVERY literal of the family appear in EACH of
//! them; a required mirror is therefore owner-equivalent, since a file the rule
//! commands to spell a literal cannot also be drift for spelling it.
//!
//! **`literals_from` makes the family TOTAL.** A hand-written `literals` list is
//! a snapshot of the day someone wrote it: add an enum variant, and the new wire
//! string joins no family, so no mirror is ever asked for it. `literals_from`
//! reads the family out of the owner instead — every double-quoted string on a
//! line carrying all of the configured `fragments` — so a new variant enrols
//! itself and a mirror missing it fails with nobody editing guardian.toml. An
//! unreadable file, or an extraction that yields nothing, is a hard finding
//! rather than a shrug: a silently empty family passes every mirror.
//!
//! Zero `[[concept]]` entries is the zero-config default: the check passes
//! without reading a single file.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const lexical = @import("lexical_scan.zig");
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

/// Remedy for the other direction: a mirror the rule REQUIRES has fallen behind
/// the family. There is no "add it to the owner list" escape here — the file was
/// named on purpose.
const mirror_fix_hint = "teach the required mirror the missing spelling, " ++
    "or drop it from that [[concept]] rule's require_in list.";

/// Remedy for a `literals_from` that produced no family. Deliberately blunt: the
/// rule is inert until it is fixed, and an inert relational rule reads in the
/// config exactly like an enforced one.
const extract_fix_hint = "point literals_from at the file that spells the family " ++
    "and at fragments its emitting lines all carry \u{2014} an empty family passes every mirror.";

/// Every remedy this check can print, in report order. Sizing the dedupe pass
/// off the set itself means a fourth rule's hint joins by being declared here,
/// not by someone remembering to widen a buffer.
const fix_hints = [_][]const u8{ fix_hint, mirror_fix_hint, extract_fix_hint };

/// How many occurrence lines one violation names before it stops listing them.
/// A drifted file can carry dozens; the first few are what a reader jumps to,
/// and the total is in the count.
const max_reported_lines = 5;

/// How much of one match the report quotes before eliding the rest. A declared
/// literal is short by construction; a wildcard match is bounded only by the
/// token it landed in, and in a minified bundle that token can be the width of
/// a terminal several times over.
const max_spelling_bytes = 40;

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

/// True when `rel_path` is one of the files `rule` says the concept lives in —
/// its `owner` list, or its `require_in` list. Both use Guardian's ordinary
/// path-glob syntax (`walk.matchGlob`), so a bare path is a substring match and
/// `src/board/*` covers a subtree.
///
/// `require_in` counts as ownership because the two keys are one relation read
/// in opposite directions: a file the rule COMMANDS to spell every literal
/// cannot simultaneously be drift for spelling one. Without this a mirror would
/// be reported twice — once for holding the literal, once for not holding
/// enough of them — with the two findings contradicting each other.
fn owns(rule: config.ConceptRule, rel_path: []const u8) bool {
    for (rule.owner) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return requiredIn(rule, rel_path);
}

/// True when one of `rule`'s `require_in` globs names `rel_path`.
fn requiredIn(rule: config.ConceptRule, rel_path: []const u8) bool {
    for (rule.require_in) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
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
    if (lexical.selfExempt(rel_path) or rules.len == 0) return &.{};
    const text = try lexical.scrubbed(allocator, rel_path, content, tree);
    var violations: std.ArrayList(reporter.Violation) = .empty;
    for (rules) |rule| {
        if (owns(rule, rel_path)) continue;
        const found = try occurrencesOf(allocator, text, rule);
        if (found.len == 0) continue;
        try violations.append(allocator, try violationFor(allocator, rel_path, text, rule, found));
    }
    return violations.toOwnedSlice(allocator);
}

// ── require_in: the totality direction ──────────────────────────────────

/// Pure core: one violation per literal of `rule` that this REQUIRED mirror does
/// not spell. Judged over the same scrubbed text ownership is judged over, so a
/// literal surviving only in a comment does not satisfy the requirement — a
/// comment cannot carry the value at runtime, which is the whole point of asking
/// the mirror to hold it.
///
/// `patterns` are deliberately excluded. A wildcard names a shape, not a
/// spelling, so there is no single text a mirror could be required to contain.
pub fn analyzeMirror(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    tree: ?*const Ast,
    rule: config.ConceptRule,
) Allocator.Error![]const reporter.Violation {
    const text = try lexical.scrubbed(allocator, rel_path, content, tree);
    var violations: std.ArrayList(reporter.Violation) = .empty;
    for (rule.literals) |literal| {
        if (std.mem.indexOf(u8, text, literal) != null) continue;
        try violations.append(allocator, .{
            .check = check_name,
            .file = rel_path,
            .message = try std.fmt.allocPrint(
                allocator,
                "required mirror is missing concept '{s}' literal \"{s}\" \u{2014} {s}",
                .{ rule.name, literal, rule.reason orelse no_reason },
            ),
            .fix_hint = mirror_fix_hint,
            // One row per (rule, literal, file): a mirror that learns one of
            // three missing spellings must resolve exactly that row and keep
            // failing on the other two, which a per-file key could not express.
            .identity = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ rule.name, literal, rel_path }),
        });
    }
    return violations.toOwnedSlice(allocator);
}

/// The violation for a `require_in` glob that named no file at all.
///
/// Silence would be the permissive failure this key exists to kill: delete or
/// rename the mirror and every literal is vacuously "required in" nothing, so
/// the rule reports clean at the exact moment the mirror stopped existing. (A
/// `files` glob matching nothing IS silence — that one only widens a scan.)
fn unmatchedMirrorViolation(
    allocator: Allocator,
    rule: config.ConceptRule,
    glob: []const u8,
) Allocator.Error!reporter.Violation {
    return .{
        .check = check_name,
        .message = try std.fmt.allocPrint(
            allocator,
            "concept '{s}' requires its literals in \"{s}\", which names no file",
            .{ rule.name, glob },
        ),
        .fix_hint = mirror_fix_hint,
        .identity = try std.fmt.allocPrint(allocator, "{s}|require_in|{s}", .{ rule.name, glob }),
    };
}

// ── literals_from: reading the family out of the owner ──────────────────

/// Pure core: every double-quoted string on a line of `content` that contains
/// ALL of `fragments`, in source order.
///
/// The extracted text is the spelling AS WRITTEN — escapes are not resolved —
/// because a mirror hand-copying the owner writes the same characters the owner
/// does, and that is what the lexical scan then looks for. Empty strings are
/// dropped: an empty literal matches at every offset in every file, which would
/// turn one careless fragment into a tree-wide false positive.
fn extractLiterals(
    allocator: Allocator,
    content: []const u8,
    fragments: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!containsAll(line, fragments)) continue;
        try appendQuoted(allocator, &out, line);
    }
    return out.toOwnedSlice(allocator);
}

/// True when `line` contains every fragment. An empty fragment list would match
/// every line, which the config parser refuses precisely so this cannot happen.
fn containsAll(line: []const u8, fragments: []const []const u8) bool {
    if (fragments.len == 0) return false;
    for (fragments) |fragment| {
        if (std.mem.indexOf(u8, line, fragment) == null) return false;
    }
    return true;
}

/// Appends every non-empty double-quoted string on one line, treating `\"` as
/// an escaped quote rather than a terminator. An unterminated quote ends the
/// line's extraction rather than running into the next one.
fn appendQuoted(
    allocator: Allocator,
    out: *std.ArrayList([]const u8),
    line: []const u8,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '"') continue;
        const start = i + 1;
        var j = start;
        while (j < line.len and line[j] != '"') : (j += 1) {
            if (line[j] == '\\') j += 1;
        }
        if (j >= line.len) return;
        if (j > start) try out.append(allocator, line[start..j]);
        i = j;
    }
}

/// One rule's resolved family plus whatever went wrong resolving it.
const Resolved = struct {
    rules: []const config.ConceptRule,
    errors: []const reporter.Violation,
};

/// Expands every rule's `literals_from`, returning the rules with their families
/// filled in and a violation for each extraction that failed.
///
/// A rule whose extraction failed keeps whatever it declared by hand and stays
/// in the scan: dropping it would weaken enforcement on top of a config error,
/// and the error itself already blocks the gate.
fn resolveRules(
    allocator: Allocator,
    project_dir: []const u8,
    rules: []const config.ConceptRule,
) Allocator.Error!Resolved {
    var out: std.ArrayList(config.ConceptRule) = .empty;
    var errors: std.ArrayList(reporter.Violation) = .empty;
    for (rules) |rule| {
        const from = rule.literals_from orelse {
            try out.append(allocator, rule);
            continue;
        };
        var resolved = rule;
        const extracted = readFamily(allocator, project_dir, from) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unreadable => {
                try errors.append(allocator, try extractionError(allocator, rule, from, "is missing or unreadable"));
                try out.append(allocator, rule);
                continue;
            },
        };
        if (extracted.len == 0) {
            try errors.append(allocator, try extractionError(allocator, rule, from, "yielded no literals"));
            try out.append(allocator, rule);
            continue;
        }
        resolved.literals = try mergeLiterals(allocator, rule.literals, extracted);
        try out.append(allocator, resolved);
    }
    return .{ .rules = try out.toOwnedSlice(allocator), .errors = try errors.toOwnedSlice(allocator) };
}

/// Reads and extracts one `literals_from` source. Comment lines are blanked
/// first (via the same `scrubbed` pass the scan uses), so prose ABOUT the
/// emitting switch cannot enrol a literal the code never writes.
fn readFamily(
    allocator: Allocator,
    project_dir: []const u8,
    from: config.LiteralsFrom,
) (Allocator.Error || error{Unreadable})![]const []const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, from.file });
    const content = fs.cwd().readFileAlloc(allocator, path, lexical.read_limit) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unreadable,
    };
    const text = try lexical.scrubbed(allocator, from.file, content, null);
    return extractLiterals(allocator, text, from.fragments);
}

/// The declared literals plus the extracted ones, in that order, dropping an
/// extracted spelling a hand-written entry already names. Duplicates would
/// double every occurrence count in a report for no gain.
fn mergeLiterals(
    allocator: Allocator,
    declared: []const []const u8,
    extracted: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(allocator, declared);
    for (extracted) |literal| {
        if (containsLiteral(out.items, literal)) continue;
        try out.append(allocator, literal);
    }
    return out.toOwnedSlice(allocator);
}

fn containsLiteral(list: []const []const u8, wanted: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, wanted)) return true;
    }
    return false;
}

/// The violation for a `literals_from` that produced no usable family.
fn extractionError(
    allocator: Allocator,
    rule: config.ConceptRule,
    from: config.LiteralsFrom,
    what: []const u8,
) Allocator.Error!reporter.Violation {
    return .{
        .check = check_name,
        .file = from.file,
        .message = try std.fmt.allocPrint(
            allocator,
            "concept '{s}' literals_from {s}: the family is empty, so every mirror passes",
            .{ rule.name, what },
        ),
        .fix_hint = extract_fix_hint,
        .identity = try std.fmt.allocPrint(allocator, "{s}|literals_from", .{rule.name}),
    };
}

// ── Run: the default source set plus any `files` globs ──────────────────

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
    /// Rules declaring `require_in`, judged over the same walk. Kept apart from
    /// `rules` because the two questions have different file sets: `rules` is
    /// "who owns this path", `require` is "which mirrors must spell the family".
    require: []const config.ConceptRule = &.{},
    /// `matched[i][j]` — whether `require[i]`'s glob `j` named any file on this
    /// walk. A glob that matched nothing is reported once the walk is over,
    /// which is the only place that fact is known.
    matched: []const []bool = &.{},

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
        if (lexical.skipPath(self.skip, rel_path)) return;
        const found = try analyzeFile(self.allocator, rel_path, content, tree, rules);
        try self.violations.appendSlice(self.allocator, found);
    }

    /// Judges one file as a required mirror of every `require` rule that names
    /// it, marking the globs that matched so the post-walk pass can report the
    /// ones that named nothing.
    ///
    /// A skipped path is marked matched and then not judged, in that order. The
    /// glob DID name a file — an `[[allow]]` / `exclude` entry says "do not
    /// judge this one", not "pretend the mirror is gone" — so reporting the
    /// glob as naming nothing would answer a question nobody asked.
    fn scanMirror(
        self: *ScanCtx,
        rel_path: []const u8,
        content: []const u8,
        tree: ?*const Ast,
    ) Allocator.Error!void {
        for (self.require, 0..) |rule, i| {
            if (!self.markMatched(rule, rel_path, i)) continue;
            if (lexical.skipPath(self.skip, rel_path)) continue;
            const found = try analyzeMirror(self.allocator, rel_path, content, tree, rule);
            try self.violations.appendSlice(self.allocator, found);
        }
    }

    /// Records which of `rule`'s `require_in` globs `rel_path` satisfies,
    /// returning whether any did.
    fn markMatched(self: *ScanCtx, rule: config.ConceptRule, rel_path: []const u8, index: usize) bool {
        var hit = false;
        for (rule.require_in, 0..) |pattern, j| {
            if (!walk.matchGlob(rel_path, pattern)) continue;
            self.matched[index][j] = true;
            hit = true;
        }
        return hit;
    }

    /// True when some `require` rule's glob names `rel_path` — the cheap test
    /// that decides whether a file is worth reading at all.
    fn wantsMirror(self: *const ScanCtx, rel_path: []const u8) bool {
        for (self.require) |rule| {
            if (requiredIn(rule, rel_path)) return true;
        }
        return false;
    }
};

fn sourceVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try ctx.scanWith(entry.rel_path, entry.content, entry.tree, ctx.rules);
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

/// Reads and scans one globbed file: against the rules whose `files` name it
/// (ownership) and against the rules whose `require_in` names it (totality).
/// Matching happens BEFORE the read, so a glob that names `*.css` never opens
/// the repository's binaries — and a file a rule did name is read whatever its
/// extension. A globbed `.zig` parses its own tree: a broad rule names
/// `src/**` alongside its JS and CSS, and a test block is exempt wherever the
/// file was reached — the shared index serves only the no-`files` scan.
fn scanGlobbedFile(ctx: *ScanCtx, dir: fs.Dir, name: []const u8, rel_path: []const u8) !void {
    const rules = try rulesNaming(ctx.allocator, ctx.rules, rel_path);
    if (rules.len == 0 and !ctx.wantsMirror(rel_path)) return;
    const content = try dir.readFileAlloc(ctx.allocator, name, lexical.read_limit);
    if (std.mem.endsWith(u8, rel_path, ".zig")) {
        const source = try ctx.allocator.dupeSentinel(u8, content, 0);
        var tree = try Ast.parse(ctx.allocator, source, .{});
        try ctx.scanWith(rel_path, source, &tree, rules);
        return ctx.scanMirror(rel_path, source, &tree);
    }
    try ctx.scanWith(rel_path, content, null, rules);
    try ctx.scanMirror(rel_path, content, null);
}

fn globVisit(raw_ctx: *anyopaque, dir: fs.Dir, name: []const u8, rel_path: []const u8) walk.WalkError!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try scanGlobbedFile(ctx, dir, name, rel_path);
}

/// Walks `dir` recursively, scanning every file a `files` or `require_in` glob
/// names. A `files` glob matching nothing is silence, not an error: a project
/// may declare the concept before the owner or the drifting asset exists. A
/// `require_in` glob matching nothing is NOT silence — see
/// `unmatchedMirrorViolation`.
fn scanGlobs(ctx: *ScanCtx, dir: fs.Dir, prefix: []const u8) walk.WalkError!void {
    try lexical.walkFiles(ctx.allocator, dir, prefix, .{ .ctx = ctx, .visit = globVisit });
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

/// The subset of `rules` that names required mirrors, plus a fresh
/// `matched[i][j]` grid the walk marks as each glob lands on a file.
const MirrorPlan = struct {
    rules: []const config.ConceptRule,
    matched: []const []bool,

    fn build(allocator: Allocator, rules: []const config.ConceptRule) Allocator.Error!MirrorPlan {
        var out: std.ArrayList(config.ConceptRule) = .empty;
        for (rules) |rule| {
            if (rule.require_in.len > 0) try out.append(allocator, rule);
        }
        const kept = try out.toOwnedSlice(allocator);
        const grid = try allocator.alloc([]bool, kept.len);
        for (kept, grid) |rule, *row| {
            row.* = try allocator.alloc(bool, rule.require_in.len);
            @memset(row.*, false);
        }
        return .{ .rules = kept, .matched = grid };
    }

    /// One violation per glob that named no file, appended after the walk.
    fn reportUnmatched(
        self: MirrorPlan,
        allocator: Allocator,
        into: *std.ArrayList(reporter.Violation),
    ) Allocator.Error!void {
        for (self.rules, self.matched) |rule, row| {
            for (rule.require_in, row) |glob, hit| {
                if (hit) continue;
                try into.append(allocator, try unmatchedMirrorViolation(allocator, rule, glob));
            }
        }
    }
};

/// Entry point for the concept check (opt-in: declare `[[concept]]` entries).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const declared = ctx_param.cfg.concept_rules;
    if (declared.len == 0) {
        reporter.ok("concept: no [[concept]] rules configured", .{});
        return;
    }

    var found: std.ArrayList(reporter.Violation) = .empty;
    // Families are resolved BEFORE any scan: `literals_from` changes what every
    // later question is asked about, so a rule must never be scanned with the
    // hand-written half of its family and then required in a mirror with the
    // whole of it.
    const resolved = try resolveRules(allocator, ctx_param.project_dir, declared);
    const rules = resolved.rules;
    try found.appendSlice(allocator, resolved.errors);
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
    const mirrors = try MirrorPlan.build(allocator, rules);
    if (glob_rules.len > 0 or mirrors.rules.len > 0) {
        var glob_ctx: ScanCtx = .{
            .allocator = allocator,
            .rules = glob_rules,
            .skip = skip,
            .violations = &found,
            .require = mirrors.rules,
            .matched = mirrors.matched,
        };
        var root = try fs.cwd().openDir(ctx_param.project_dir, .{ .iterate = true });
        defer root.close();
        try scanGlobs(&glob_ctx, root, "");
        try mirrors.reportUnmatched(allocator, &found);
    }

    if (found.items.len == 0) {
        reporter.ok("concept: no drifted concepts ({d} rule(s))", .{rules.len});
        return;
    }
    // "finding(s)", not "file(s) outside an owner": the same check now also
    // reports a required mirror that fell behind, a require_in glob that named
    // nothing, and a literals_from that read no family — none of which is a
    // file outside an owner.
    reporter.fail("concept FAILED ({d} finding(s))", .{found.items.len});
    // emitQuiet, not emit: the remedies close the list below, and repeating a
    // near-identical one under every finding is console noise. The hint still
    // rides each record into last-run.jsonl, which has no "beneath the list".
    for (found.items) |violation| reporter.emitQuiet(violation);
    printFixHints(found.items);
    return error.CheckFailed;
}

/// Prints each remedy some finding carries, once, in a fixed order. One shared
/// line was right while every finding was drift; a mirror that fell behind and a
/// `literals_from` that read nothing have their OWN fixes, and printing only the
/// first would tell a reader to solve the wrong problem. Walking the hint set
/// rather than the findings makes the output deduplicated and deterministic by
/// construction.
fn printFixHints(found: []const reporter.Violation) void {
    for (fix_hints) |hint| {
        if (!anyCarries(found, hint)) continue;
        reporter.detail("  fix: {s}\n", .{hint});
    }
}

fn anyCarries(found: []const reporter.Violation, hint: []const u8) bool {
    for (found) |violation| {
        const own = violation.fix_hint orelse continue;
        if (std.mem.eql(u8, own, hint)) return true;
    }
    return false;
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

// ── require_in and literals_from ───────────────────────────────────────

/// The fixture family: three DRC wire strings the owner's emitting switch
/// spells, mirrored (incompletely) by `test-project/mirrors/viewer.js`.
const drc_literals_from = config.LiteralsFrom{
    .file = "mirrors/kinds.zig",
    .fragments = &.{"=> \""},
};

const drc_rule = config.ConceptRule{
    .name = "drc-kinds",
    .literals = &.{ "clearance", "track_track", "hole_size" },
    .owner = &.{"mirrors/kinds.zig"},
    .require_in = &.{"mirrors/viewer.js"},
    .reason = "DRC kind strings come from kinds.Kind.wire",
};

// spec: Concept Ownership - Flags a literal a required mirror does not spell

test "analyzeMirror reports each literal the mirror is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeMirror(a, "assets/viewer.js",
        \\const BLOCK = { clearance: true };
    , null, drc_rule);
    // The mirror spells one of three, so the two it lost are two separate rows:
    // learning one must resolve exactly that row and keep failing on the other.
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("drc-kinds|track_track|assets/viewer.js", out[0].identity.?);
    try testing.expectEqualStrings("drc-kinds|hole_size|assets/viewer.js", out[1].identity.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "required mirror is missing") != null);
    // The rule's reason rides along here too — it is what says where the
    // spelling is supposed to come from.
    try testing.expect(std.mem.endsWith(u8, out[0].message, "DRC kind strings come from kinds.Kind.wire"));
}

// spec: Concept Ownership - Passes a required mirror that spells every literal

test "analyzeMirror is silent when the mirror is complete" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeMirror(a, "assets/viewer.js",
        \\const BLOCK = { clearance: 1, track_track: 1, hole_size: 1 };
    , null, drc_rule);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Concept Ownership - Refuses to count a comment-only mention as a mirror's spelling

test "analyzeMirror ignores a literal that survives only in a comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Same blanking as the ownership scan, and for a stronger reason here: a
    // comment cannot carry the value at runtime, so a mirror that only mentions
    // the spelling has not learned it.
    const out = try analyzeMirror(a, "assets/viewer.js",
        \\// hole_size is handled elsewhere
        \\const BLOCK = { clearance: 1, track_track: 1 };
    , null, drc_rule);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("drc-kinds|hole_size|assets/viewer.js", out[0].identity.?);
}

// spec: Concept Ownership - Treats a required mirror as an owner for the ownership scan

test "owns accepts a require_in path so a mirror is never also drift" {
    // The two directions are one relation: a file the rule COMMANDS to spell
    // every literal cannot simultaneously be drift for spelling one, and
    // reporting both would be two findings that contradict each other.
    try testing.expect(owns(drc_rule, "mirrors/viewer.js"));
    try testing.expect(owns(drc_rule, "mirrors/kinds.zig"));
    try testing.expect(!owns(drc_rule, "src/elsewhere.zig"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), "mirrors/viewer.js",
        \\const BLOCK = { clearance: 1 };
    , null, &.{drc_rule});
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Concept Ownership - Reads a required mirror through the tree walk and flags what it lost

test "scanGlobs judges a required mirror even when the rule declares no files glob" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.ConceptRule{drc_rule};
    const plan = try MirrorPlan.build(a, &rules);
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        // No `files` rules at all: the walk exists here only to reach the
        // mirror, which is a .js file no source scan could ever open.
        .rules = &.{},
        .skip = &.{},
        .violations = &violations,
        .require = plan.rules,
        .matched = plan.matched,
    };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try scanGlobs(&ctx, root, "");
    try plan.reportUnmatched(a, &violations);
    // The fixture mirror knows clearance and track_track and lost hole_size.
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqualStrings("drc-kinds|hole_size|mirrors/viewer.js", violations.items[0].identity.?);
}

// spec: Concept Ownership - Reports a require_in glob that names no file

test "MirrorPlan reports a required mirror glob that matched nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Delete or rename the mirror and every literal is vacuously "required in"
    // nothing — the rule reports clean at the exact moment it stopped being
    // enforced. That is the permissive failure this key exists to kill.
    var gone = drc_rule;
    gone.require_in = &.{"mirrors/deleted.js"};
    const rules = [_]config.ConceptRule{gone};
    const plan = try MirrorPlan.build(a, &rules);
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .rules = &.{},
        .skip = &.{},
        .violations = &violations,
        .require = plan.rules,
        .matched = plan.matched,
    };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try scanGlobs(&ctx, root, "");
    try plan.reportUnmatched(a, &violations);
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqualStrings("drc-kinds|require_in|mirrors/deleted.js", violations.items[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, violations.items[0].message, "names no file") != null);
}

// spec: Concept Ownership - Extracts every quoted string on a line carrying all the configured fragments

test "extractLiterals reads the family off the owner's emitting lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try extractLiterals(a,
        \\return switch (self) {
        \\    .clearance => "clearance",
        \\    .track_track => "track_track",
        \\};
        \\const unrelated = "not part of the family";
    , &.{"=> \""});
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("clearance", out[0]);
    try testing.expectEqualStrings("track_track", out[1]);
    // ALL fragments must be present, so a second fragment narrows rather than
    // widens — this is what keeps a family aimed at one switch.
    const narrowed = try extractLiterals(a,
        \\    .clearance => "clearance", // kind
        \\    .track_track => "track_track",
    , &.{ "=> \"", "// kind" });
    try testing.expectEqual(@as(usize, 1), narrowed.len);
    try testing.expectEqualStrings("clearance", narrowed[0]);
    // An empty string is dropped: it would match at every offset in every file.
    const empties = try extractLiterals(a, "x => \"\" and \"real\"", &.{"=> \""});
    try testing.expectEqual(@as(usize, 1), empties.len);
    try testing.expectEqualStrings("real", empties[0]);
}

// spec: Concept Ownership - Merges the extracted family into the declared literals without duplicating one

test "resolveRules unions the extracted literals with the declared ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rule = drc_rule;
    // One literal is declared by hand AND spelled by the owner's switch. The
    // family must hold it once: a duplicate would double every occurrence count
    // a report prints.
    rule.literals = &.{"clearance"};
    rule.literals_from = drc_literals_from;
    const resolved = try resolveRules(a, "test-project", &.{rule});
    try testing.expectEqual(@as(usize, 0), resolved.errors.len);
    try testing.expectEqual(@as(usize, 3), resolved.rules[0].literals.len);
    try testing.expectEqualStrings("clearance", resolved.rules[0].literals[0]);
    try testing.expectEqualStrings("track_track", resolved.rules[0].literals[1]);
    try testing.expectEqualStrings("hole_size", resolved.rules[0].literals[2]);
}

// spec: Concept Ownership - Reports a literals_from source that cannot be read or yields no literals

test "resolveRules surfaces an extraction that produced no family" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var missing = drc_rule;
    missing.literals_from = .{ .file = "mirrors/gone.zig", .fragments = &.{"=> \""} };
    const unreadable = try resolveRules(a, "test-project", &.{missing});
    try testing.expectEqual(@as(usize, 1), unreadable.errors.len);
    try testing.expectEqualStrings("drc-kinds|literals_from", unreadable.errors[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, unreadable.errors[0].message, "missing or unreadable") != null);
    // The rule still scans with what it declared by hand: an extraction failure
    // is a config error to fix, never a reason to enforce less than before.
    try testing.expectEqual(@as(usize, 3), unreadable.rules[0].literals.len);

    var empty = drc_rule;
    empty.literals_from = .{ .file = "mirrors/kinds.zig", .fragments = &.{"no line carries this"} };
    const nothing = try resolveRules(a, "test-project", &.{empty});
    try testing.expectEqual(@as(usize, 1), nothing.errors.len);
    try testing.expect(std.mem.indexOf(u8, nothing.errors[0].message, "yielded no literals") != null);
    // Both messages say the consequence out loud, because "the family is empty"
    // is indistinguishable from "every mirror is fine" in the output otherwise.
    try testing.expect(std.mem.indexOf(u8, nothing.errors[0].message, "every mirror passes") != null);
}

// spec: Concept Ownership - Blanks comment lines before extracting a literals_from family

test "resolveRules never enrols a literal that only a comment spells" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rule = drc_rule;
    rule.literals = &.{};
    rule.literals_from = drc_literals_from;
    const resolved = try resolveRules(a, "test-project", &.{rule});
    // The fixture's doc comment names `not_a_kind` on a line carrying the
    // fragment. Prose ABOUT the switch must not enrol a spelling the code never
    // writes — the family would then demand it of every mirror.
    for (resolved.rules[0].literals) |literal| {
        try testing.expect(!std.mem.eql(u8, literal, "not_a_kind"));
    }
    try testing.expectEqual(@as(usize, 3), resolved.rules[0].literals.len);
}
