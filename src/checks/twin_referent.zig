//! twin-referent: a comment that CLAIMS a relationship to a named piece of
//! code, where the name no longer resolves.
//!
//! "mirrors X", "same as Y", "verified against Z" is a maintenance contract
//! written in prose, and prose does not move when code does. The motivating
//! audit (eda, 2026-08) found six of them wrong: a doc naming a function that
//! was deleted now sits on an unrelated one; `render_svg.zig` named after it was
//! split into a directory; a hard-coded `file.zig:120-160` line range pointing
//! at code that had shifted; `optimizer.INNER_LAYER_COLORS` where the symbol is
//! spelled lowercase. Each reads as verified and is not.
//!
//! **Precision comes from the referent, not the phrase.** A claim phrase alone
//! is never enough — English is full of "matches the filter" and "the same as
//! before". This check only speaks when the claim is followed, in the same
//! sentence, by something code-SHAPED:
//!
//!   * a word ending in `.zig` (no glob, non-empty basename),
//!   * a dotted identifier chain whose first segment names a module in the tree.
//!
//! Backticks are stripped as ordinary punctuation and do NOT by themselves make
//! a word a referent, though the design started that way. Measured on Guardian's
//! own tree, "this is in backticks so it is code" produced two false positives
//! in one doc comment — `In*.Cu` matches `In3.Cu`, prose about a wildcard, where
//! `In3.Cu` reads as `module.symbol`. Requiring a module root costs nothing real
//! (the motivating `optimizer.INNER_LAYER_COLORS` is module-rooted) and removes
//! the whole class.
//!
//! Resolution is deliberately cheap: a path must name an indexed file (exactly,
//! or as a tail starting at a separator, so a bare `limits.zig` resolves), and a
//! chain's final symbol must be declared or dereferenced SOMEWHERE in the tree.
//! That is containment, not semantic resolution — it cannot tell you the symbol
//! lives in the module named, only that it exists at all. The failure it does
//! catch is the one that matters: the name is gone, or was never spelled that
//! way. A chain rooted in a namespace this check has no index for — `std`,
//! `builtin` — is skipped rather than guessed at.
//!
//! A hard-coded `file.zig:120-160` line reference is reported outright. It is
//! not resolvable in principle — the lines move with the next edit — so the
//! remedy is to name the symbol instead.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const config = @import("../config.zig");
const LineCursor = @import("../text.zig").LineCursor;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const check_name = "twin-referent";

/// The extension every referent path carries, and the tail a chain may not end
/// in (a path is resolved as a path, never as a symbol).
const zig_ext = ".zig";

/// Phrases that turn a comment into a claim about another piece of code. Each
/// is matched case-insensitively and only at a word boundary, so "rematches"
/// is not "matches".
const claim_phrases = [_][]const u8{
    "mirrors",
    "mirror of",
    "same as",
    "twin of",
    "in lockstep with",
    "verified against",
    "matches",
};

/// Dotted-chain tails that name a FILE rather than a symbol. Without this,
/// `guardian.toml` and `package.json` read as `module.symbol` chains and are
/// reported for a symbol that was never meant to exist.
const non_symbol_tails = [_][]const u8{
    "toml", "json", "jsonl", "md",  "zon", "txt",
    "js",   "css",  "html",  "sh",  "py",  "yml",
    "yaml", "lock", "png",   "svg", "zig",
};

/// Namespaces this check has no index of, so a chain rooted in one is skipped
/// instead of resolved against the project's own symbols. Guardian's own
/// `i128` matches `std.time.nanoTimestamp` is the case: a correct referent into
/// a library the scan never reads.
const external_roots = [_][]const u8{ "std", "builtin", "root" };

/// Characters stripped from the front of a candidate word — the punctuation
/// prose wraps a referent in.
const lead_punctuation = "`'\"([{<";

/// Characters stripped from the end of a candidate word, sentence punctuation
/// included.
const trail_punctuation = "`'\".,;:!?)]}>";

const fix_hint = "repoint the comment at a name that exists, or drop the claim — " ++
    "a wrong 'mirrors X' reads as verified and is not.";

/// A set of names, used for the two containment questions this check asks:
/// does the tree hold a module by this basename, and does it hold this symbol?
pub const NameSet = std.StringHashMapUnmanaged(void);

/// The tree-wide facts a referent is resolved against. Built once per run and
/// shared by every file, because a comment in one file routinely names another.
pub const Resolver = struct {
    /// Every indexed file path, as the walker spells it (`src/checks/ban.zig`).
    paths: []const []const u8,
    /// Indexed basenames without the extension, so `optimizer.foo` can ask
    /// whether `optimizer` is a module here at all.
    modules: NameSet,
    /// Names the tree declares (`const`/`var`/`fn`) or dereferences (`x.name`).
    symbols: NameSet,
};

// ── Building the resolver ───────────────────────────────────────────────

/// Records one file's module basename and every name it declares, names as a
/// field, or dereferences — one token pass. The set is deliberately generous:
/// it is used to STAY SILENT, so every extra name is a claim not reported, and
/// the only thing it must never miss is a name that genuinely exists.
fn indexNames(allocator: Allocator, entry: *const ast_index.Entry, into: *Resolver) Allocator.Error!void {
    const stem = std.fs.path.stem(entry.rel_path);
    try into.modules.put(allocator, stem, {});
    const tree = &entry.tree;
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .identifier or i == 0) continue;
        if (!isName(tags[i - 1], if (i + 1 < tags.len) tags[i + 1] else .eof)) continue;
        try into.symbols.put(allocator, tree.tokenSlice(@intCast(i)), {});
    }
}

/// True when an identifier's neighbours make it a name the tree knows: a
/// declaration keyword or a field-access `.` before it, or the `:` of a struct
/// field / declared type after it.
fn isName(prev: std.zig.Token.Tag, next: std.zig.Token.Tag) bool {
    if (next == .colon) return true;
    return switch (prev) {
        .keyword_const, .keyword_var, .keyword_fn, .period => true,
        else => false,
    };
}

/// Builds the tree-wide resolution context from the parsed source index.
/// `extra_paths` names resolvable files the index does not hold — the project's
/// root-level `build.zig` and friends, which comments legitimately point at.
pub fn buildResolver(
    allocator: Allocator,
    files: []const ast_index.Entry,
    extra_paths: []const []const u8,
) Allocator.Error!Resolver {
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.appendSlice(allocator, extra_paths);
    var out: Resolver = .{ .paths = &.{}, .modules = .empty, .symbols = .empty };
    for (files) |*entry| {
        try paths.append(allocator, entry.rel_path);
        try indexNames(allocator, entry, &out);
    }
    out.paths = try paths.toOwnedSlice(allocator);
    return out;
}

// ── Comment extraction ──────────────────────────────────────────────────

/// One comment line: where it is and what it says with the `//` prefix gone.
const CommentLine = struct {
    line: u32,
    text: []const u8,
};

/// Strips a leading `///`, `//!` or `//` and the one space that usually
/// follows it.
fn stripCommentPrefix(raw: []const u8) []const u8 {
    var s = raw;
    if (!std.mem.startsWith(u8, s, "//")) return std.mem.trimEnd(u8, s, &std.ascii.whitespace);
    s = s[2..];
    if (s.len > 0 and (s[0] == '/' or s[0] == '!')) s = s[1..];
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

/// Collects the `//` comment lines from a stretch of source between two tokens.
/// Everything the tokenizer consumed is a token, so a gap holds only whitespace
/// and comments — which is what keeps a `//` inside a string literal or a `\\`
/// multiline line from ever being read as a comment.
fn collectGapComments(
    allocator: Allocator,
    ctx: *ScanState,
    gap: []const u8,
    gap_start: usize,
) Allocator.Error!void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, gap, at, "//")) |found| {
        const end = std.mem.indexOfScalarPos(u8, gap, found, '\n') orelse gap.len;
        const line = ctx.cursor.at(ctx.content, gap_start + found);
        try ctx.lines.append(allocator, .{ .line = line, .text = stripCommentPrefix(gap[found..end]) });
        at = end;
        if (at >= gap.len) break;
    }
}

/// Shared state for one file's comment sweep: where the line cursor has
/// reached, and where the comment lines land.
const ScanState = struct {
    content: []const u8,
    cursor: LineCursor = .{},
    lines: *std.ArrayList(CommentLine),
};

/// Collects every comment line in one parsed file, in source order. Doc
/// comments arrive as tokens; ordinary `//` comments live in the gaps between
/// tokens.
fn collectComments(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    out: *std.ArrayList(CommentLine),
) Allocator.Error!void {
    const tree = &entry.tree;
    var ctx: ScanState = .{ .content = entry.content, .lines = out };
    var prev_end: usize = 0;
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        const start: usize = tree.tokenStart(@intCast(i));
        if (start > prev_end) try collectGapComments(allocator, &ctx, entry.content[prev_end..start], prev_end);
        if (tag == .eof) break;
        const slice = tree.tokenSlice(@intCast(i));
        if (tag == .doc_comment or tag == .container_doc_comment) {
            const line = ctx.cursor.at(entry.content, start);
            try out.append(allocator, .{ .line = line, .text = stripCommentPrefix(slice) });
        }
        prev_end = start + slice.len;
    }
}

/// A run of consecutive comment lines, joined with newlines so a claim and its
/// referent may sit on different lines of one comment block.
const Run = struct {
    line: u32,
    text: []const u8,
};

/// Groups comment lines into runs of consecutive source lines.
fn groupRuns(allocator: Allocator, lines: []const CommentLine) Allocator.Error![]const Run {
    var runs: std.ArrayList(Run) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    var start: u32 = 0;
    var prev: u32 = 0;
    for (lines) |entry| {
        if (buf.items.len > 0 and entry.line != prev + 1) {
            try runs.append(allocator, .{ .line = start, .text = try buf.toOwnedSlice(allocator) });
            buf = .empty;
        }
        if (buf.items.len == 0) start = entry.line else try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, entry.text);
        prev = entry.line;
    }
    if (buf.items.len > 0) try runs.append(allocator, .{ .line = start, .text = try buf.toOwnedSlice(allocator) });
    return runs.toOwnedSlice(allocator);
}

// ── Finding a claim and its referent ────────────────────────────────────

/// The offset just past the next claim phrase at or after `from`, or null.
/// The scan runs left to right, so the earliest phrase wins, and a match must
/// start at a word boundary — "rematches" is not "matches".
fn nextClaim(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (i > 0 and isWordByte(text[i - 1])) continue;
        for (claim_phrases) |phrase| {
            if (std.ascii.startsWithIgnoreCase(text[i..], phrase)) return i + phrase.len;
        }
    }
    return null;
}

/// True for the bytes that make up a word, so a phrase match can require a
/// boundary in front of it.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The rest of the sentence starting at `from`: up to a `.`, `!` or `?`
/// followed by whitespace, or the end of the comment run. `foo.zig` survives
/// because its period has no space after it.
fn sentenceAt(text: []const u8, from: usize) []const u8 {
    var i = from;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != '.' and c != '!' and c != '?') continue;
        if (i + 1 >= text.len or std.ascii.isWhitespace(text[i + 1])) return text[from..i];
    }
    return text[from..];
}

/// What a claim points at, and how it must be resolved.
const Referent = struct {
    text: []const u8,
    kind: enum { path, line_ref, chain },
};

/// Trims the prose punctuation around a candidate word, backticks included.
fn cleanWord(raw: []const u8) []const u8 {
    const front = std.mem.trimStart(u8, raw, lead_punctuation);
    return std.mem.trimEnd(u8, front, trail_punctuation);
}

/// Classifies one cleaned word as a referent, or null when it is ordinary
/// prose. A `*` or `?` marks a glob (a pattern, not a name) and an empty
/// basename marks a bare `.zig` mention; neither is a referent.
fn classifyWord(word: []const u8, resolver: *const Resolver) ?Referent {
    if (std.mem.indexOfAny(u8, word, "*?") != null) return null;
    if (std.mem.indexOf(u8, word, zig_ext)) |at| return classifyPath(word, at);
    if (!rootedInModule(word, resolver)) return null;
    return classifyChain(word);
}

/// Classifies a word carrying `.zig`: a bare `.zig`, or an extension in the
/// middle of the word (`build.zig.zon`), is not a referent; a `:12-40` tail
/// makes it a line reference rather than a path.
fn classifyPath(word: []const u8, at: usize) ?Referent {
    if (at == 0) return null;
    const rest = word[at + zig_ext.len ..];
    if (rest.len == 0) return .{ .text = word, .kind = .path };
    if (rest[0] != ':') return null;
    return .{ .text = word, .kind = .line_ref };
}

/// Classifies a dotted word as a `module.symbol` chain: at least two segments,
/// every segment a valid identifier, and a tail that is not a file extension.
fn classifyChain(word: []const u8) ?Referent {
    var segments: usize = 0;
    var iter = std.mem.splitScalar(u8, word, '.');
    while (iter.next()) |segment| {
        if (!isIdentifier(segment)) return null;
        segments += 1;
    }
    if (segments < 2) return null;
    const tail = word[std.mem.lastIndexOfScalar(u8, word, '.').? + 1 ..];
    for (non_symbol_tails) |ext| {
        if (std.ascii.eqlIgnoreCase(tail, ext)) return null;
    }
    return .{ .text = word, .kind = .chain };
}

/// True when the word's first dotted segment names a module in the tree — the
/// signal that `a.b` is code and not prose. A root this check has no index of
/// (`std`, `builtin`) is never a module here, whatever the project names its
/// own files.
fn rootedInModule(word: []const u8, resolver: *const Resolver) bool {
    const at = std.mem.indexOfScalar(u8, word, '.') orelse return false;
    const root = word[0..at];
    for (external_roots) |external| {
        if (std.mem.eql(u8, root, external)) return false;
    }
    return resolver.modules.contains(root);
}

/// True when `s` is a bare Zig identifier.
fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s) |c| {
        if (!isWordByte(c)) return false;
    }
    return true;
}

/// Every referent in one sentence, in order.
fn referentsIn(
    allocator: Allocator,
    sentence: []const u8,
    resolver: *const Resolver,
) Allocator.Error![]const Referent {
    var out: std.ArrayList(Referent) = .empty;
    var words = std.mem.tokenizeAny(u8, sentence, " \t\n");
    while (words.next()) |raw| {
        const word = cleanWord(raw);
        if (word.len == 0) continue;
        const referent = classifyWord(word, resolver) orelse continue;
        try out.append(allocator, referent);
    }
    return out.toOwnedSlice(allocator);
}

// ── Resolution ──────────────────────────────────────────────────────────

/// Why one referent fails to resolve, or null when it resolves. A line
/// reference always fails: the numbers move with the next edit above them.
fn resolutionFailure(referent: Referent, resolver: *const Resolver) ?[]const u8 {
    return switch (referent.kind) {
        .line_ref => "a hard-coded line reference rots on the next edit above it; name the symbol instead",
        .path => if (resolvesPath(referent.text, resolver.paths)) null else "no such file in the scanned source",
        .chain => if (resolvesSymbol(referent.text, resolver)) null else "symbol not found in the scanned source",
    };
}

/// True when a path referent names an indexed file, exactly or as a tail that
/// starts at a separator (so a bare `limits.zig` resolves against
/// `src/board/limits.zig`).
fn resolvesPath(referent: []const u8, paths: []const []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, referent)) return true;
        if (path.len <= referent.len) continue;
        if (!std.mem.endsWith(u8, path, referent)) continue;
        if (path[path.len - referent.len - 1] == '/') return true;
    }
    return false;
}

/// True when a chain's final segment is a name the tree knows.
fn resolvesSymbol(referent: []const u8, resolver: *const Resolver) bool {
    const at = std.mem.lastIndexOfScalar(u8, referent, '.') orelse return false;
    return resolver.symbols.contains(referent[at + 1 ..]);
}

// ── Per-file analysis ───────────────────────────────────────────────────

/// True when an `ignore` glob names this file or this referent text.
fn ignored(patterns: []const []const u8, rel_path: []const u8, referent: []const u8) bool {
    for (patterns) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
        if (walk.matchGlob(referent, pattern)) return true;
    }
    return false;
}

/// The per-file accumulator: what has already been reported here (so two claim
/// phrases in one sentence report the referent once) and where findings land.
const FileCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    resolver: *const Resolver,
    ignore: []const []const u8,
    seen: NameSet = .empty,
    out: std.ArrayList(reporter.Violation) = .empty,
};

/// Records one unresolved referent, skipping a repeat of one already reported
/// in this file.
fn record(ctx: *FileCtx, referent: Referent, why: []const u8, line: u32) Allocator.Error!void {
    if (ignored(ctx.ignore, ctx.rel_path, referent.text)) return;
    if ((try ctx.seen.getOrPut(ctx.allocator, referent.text)).found_existing) return;
    const message = try std.fmt.allocPrint(
        ctx.allocator,
        "comment claims a twin of {s}: {s}",
        .{ referent.text, why },
    );
    // Identity is the file plus the referent TEXT: the claim is what was
    // flagged, and it keeps its key when the comment is reworded around it or
    // moves down the file.
    const identity = try std.fmt.allocPrint(ctx.allocator, "{s}|{s}", .{ ctx.rel_path, referent.text });
    try ctx.out.append(ctx.allocator, .{
        .check = check_name,
        .file = ctx.rel_path,
        .line = line,
        .message = message,
        .fix_hint = fix_hint,
        .identity = identity,
    });
}

/// Scans one comment run for claims and reports every referent that fails to
/// resolve. Line numbers are the CLAIM's, not the referent's — the claim is
/// what a reader has to fix.
fn scanRun(ctx: *FileCtx, block: Run) Allocator.Error!void {
    var cursor: LineCursor = .{ .line = block.line };
    var at: usize = 0;
    while (nextClaim(block.text, at)) |claim_end| {
        const line = cursor.at(block.text, claim_end);
        const sentence = sentenceAt(block.text, claim_end);
        for (try referentsIn(ctx.allocator, sentence, ctx.resolver)) |referent| {
            const why = resolutionFailure(referent, ctx.resolver) orelse continue;
            try record(ctx, referent, why, line);
        }
        at = claim_end;
    }
}

/// Pure core: every unresolved twin claim in one parsed file, judged against
/// the tree-wide resolver.
pub fn analyzeFile(
    allocator: Allocator,
    entry: *const ast_index.Entry,
    resolver: *const Resolver,
    ignore: []const []const u8,
) Allocator.Error![]const reporter.Violation {
    var lines: std.ArrayList(CommentLine) = .empty;
    try collectComments(allocator, entry, &lines);
    var ctx: FileCtx = .{
        .allocator = allocator,
        .rel_path = entry.rel_path,
        .resolver = resolver,
        .ignore = ignore,
    };
    for (try groupRuns(allocator, lines.items)) |block| try scanRun(&ctx, block);
    return ctx.out.toOwnedSlice(allocator);
}

/// The project's root-level `.zig` files, which the `src/` index never holds
/// and comments routinely name (`build.zig`). An unreadable project directory
/// yields none rather than failing the run: the effect is a stricter scan, and
/// every other check would already have failed on the same directory.
fn rootZigFiles(allocator: Allocator, project_dir: []const u8) walk.WalkError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = fs.cwd().openDir(project_dir, .{ .iterate = true }) catch
        return out.toOwnedSlice(allocator);
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, zig_ext)) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return out.toOwnedSlice(allocator);
}

/// Entry point for the twin-referent check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    const roots = try rootZigFiles(allocator, ctx.project_dir);
    const resolver = try buildResolver(allocator, idx.files, roots);
    const ignore = try std.mem.concat(allocator, []const u8, &.{
        ctx.cfg.extraAllowed(check_name),
        ctx.cfg.twin_referent.ignore,
    });
    var found: std.ArrayList(reporter.Violation) = .empty;
    for (idx.files) |*entry| {
        try found.appendSlice(allocator, try analyzeFile(allocator, entry, &resolver, ignore));
    }
    if (found.items.len == 0) {
        reporter.ok("twin-referent: every mirrors/same-as claim resolves", .{});
        return;
    }
    reporter.fail("twin-referent FAILED ({d} claim(s))", .{found.items.len});
    for (found.items) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses one in-test source string into the index entry shape the pure core
/// consumes.
fn testEntry(a: Allocator, rel_path: []const u8, source: [:0]const u8) !ast_index.Entry {
    return .{ .rel_path = rel_path, .content = source, .tree = try Ast.parse(a, source, .{}) };
}

/// Builds a one-file resolver whose tree declares `known` and lives at
/// `src/known.zig`, which is enough context for the referent tests.
fn testResolver(a: Allocator) !Resolver {
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/known.zig", "pub const known_value = 1;\npub fn knownFn() void {}\n"),
    };
    return buildResolver(a, &files, &.{"build.zig"});
}

/// Runs the pure core over one source string against `testResolver`.
fn analyzeSource(a: Allocator, source: [:0]const u8) ![]const reporter.Violation {
    const resolver = try testResolver(a);
    const entry = try testEntry(a, "src/caller.zig", source);
    return analyzeFile(a, &entry, &resolver, &.{});
}

// spec: Twin Referent - Flags a claim naming a file that is not in the source tree

test "analyzeFile flags a mirrors claim naming a missing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeSource(a,
        \\// mirrors src/render_svg.zig
        \\pub const x = 1;
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/caller.zig|src/render_svg.zig", out[0].identity.?);
    try testing.expectEqualStrings(
        "src/caller.zig:1: comment claims a twin of src/render_svg.zig: no such file in the scanned source",
        try reporter.flatLine(a, out[0]),
    );
}

// spec: Twin Referent - Resolves a file referent by exact path or path tail

test "analyzeFile accepts a claim whose file resolves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Both the indexed spelling and a bare basename resolve.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\/// Verified against src/known.zig and again against known.zig.
        \\pub const x = 1;
        \\
    )).len);
}

// spec: Twin Referent - Ignores a claim phrase with no code-shaped referent

test "analyzeFile stays silent on prose claims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Plain English after the phrase, a glob pattern, and a bare mention of the
    // extension are all prose: no referent, so nothing to resolve.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\// Matches the filter the caller supplied, the same as before.
        \\// Matches *.zig and every other .zig file under the root.
        \\pub const x = 1;
        \\
    )).len);
}

// spec: Twin Referent - Flags a hard-coded line-range referent outright

test "analyzeFile rejects a line-range referent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeSource(a,
        \\// Verified against known.zig:120-160
        \\pub const x = 1;
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    // The file half exists; the line numbers are what makes it unresolvable.
    try testing.expect(std.mem.indexOf(u8, out[0].message, "hard-coded line reference") != null);
}

// spec: Twin Referent - Flags a dotted chain whose final symbol is not in the tree

test "analyzeFile resolves a module chain by its final symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `known` is a module here, so the chain is code-shaped; the casing is wrong,
    // which is exactly the eda finding this reproduces.
    const out = try analyzeSource(a,
        \\// same as known.KNOWN_VALUE
        \\pub const x = 1;
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.endsWith(u8, out[0].message, "symbol not found in the scanned source"));
    // The correctly spelled symbol resolves.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\// same as known.known_value
        \\pub const x = 1;
        \\
    )).len);
}

// spec: Twin Referent - Treats a dotted word as prose unless its root names a module

test "classifyWord needs a module root before reading a chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resolver = try testResolver(a);
    // No module named `service`: prose, backticks or not — `In*.Cu matches
    // In3.Cu` in a wildcard doc is the false positive this rule removes.
    try testing.expect(classifyWord("service.start", &resolver) == null);
    try testing.expect(classifyWord(cleanWord("`In3.Cu`"), &resolver) == null);
    // The module root is what makes it code.
    try testing.expect(classifyWord("known.known_value", &resolver).?.kind == .chain);
    // A file-extension tail is a filename, not a symbol.
    try testing.expect(classifyWord("known.toml", &resolver) == null);
    // A single identifier is too weak a claim to resolve.
    try testing.expect(classifyWord("start", &resolver) == null);
}

// spec: Twin Referent - Skips a chain rooted in a namespace it cannot index

test "rootedInModule refuses std and builtin roots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Guardian's own `i128` matches `std.time.nanoTimestamp`: a correct claim
    // about a library this scan never reads.
    const files = [_]ast_index.Entry{try testEntry(a, "src/std.zig", "pub const x = 1;\n")};
    const resolver = try buildResolver(a, &files, &.{});
    try testing.expect(!rootedInModule("std.time.nanoTimestamp", &resolver));
    try testing.expect(!rootedInModule("builtin.mode", &resolver));
    try testing.expect(rootedInModule("std.zig", &resolver) == false);
}

// spec: Twin Referent - Resolves a claim naming a root-level file outside the index

test "buildResolver resolves the extra paths it is handed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `build.zig` is never in the src index, and comments name it constantly.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\// mirrors build.zig
        \\pub const x = 1;
        \\
    )).len);
}

// spec: Twin Referent - Reads a claim spanning two lines of one comment block

test "groupRuns joins consecutive comment lines into one claim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeSource(a,
        \\// The table below mirrors
        \\// src/gone.zig
        \\pub const x = 1;
        \\
        \\// A separate block, mirrors
        \\pub const y = 2;
        \\
    );
    // One finding: the joined run carries the referent onto the claim's line,
    // and the second block's claim has no referent at all.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u32, 1), out[0].line.?);
}

// spec: Twin Referent - Never reads a comment marker inside a string literal

test "collectComments skips markers inside string and multiline literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The `//` inside both literal forms is data, not a claim about code.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\pub const url = "https://example.invalid mirrors src/gone.zig";
        \\pub const doc =
        \\    \\ mirrors src/gone.zig
        \\;
        \\
    )).len);
}

// spec: Twin Referent - Reports one claim once however many phrases introduce it

test "analyzeFile reports a repeated referent once per file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeSource(a,
        \\// mirrors src/gone.zig, same as src/gone.zig
        \\pub const x = 1;
        \\// twin of src/gone.zig
        \\pub const y = 2;
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Twin Referent - Skips a claim an ignore glob names

test "analyzeFile honors the ignore globs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resolver = try testResolver(a);
    const entry = try testEntry(a, "src/caller.zig",
        \\// mirrors src/gone.zig
        \\pub const x = 1;
        \\
    );
    // By referent text, and by the commenting file's path.
    try testing.expectEqual(@as(usize, 0), (try analyzeFile(a, &entry, &resolver, &.{"src/gone.zig"})).len);
    try testing.expectEqual(@as(usize, 0), (try analyzeFile(a, &entry, &resolver, &.{"src/caller*"})).len);
    try testing.expectEqual(@as(usize, 1), (try analyzeFile(a, &entry, &resolver, &.{"src/other.zig"})).len);
}

// spec: Twin Referent - Ends a claim sentence at a period that prose follows

test "sentenceAt stops at sentence punctuation but not inside a filename" {
    // The period in `known.zig` has no space after it, so the filename survives.
    try testing.expectEqualStrings(" known.zig", sentenceAt(" known.zig. Unrelated src/gone.zig", 0));
    // With no terminator the whole remainder is the sentence.
    try testing.expectEqualStrings(" known.zig", sentenceAt(" known.zig", 0));
}

// spec: Twin Referent - Matches a claim phrase only at a word boundary

test "nextClaim requires a word boundary before the phrase" {
    // "rematches" contains "matches" but claims nothing.
    try testing.expect(nextClaim("rematches the pattern", 0) == null);
    try testing.expectEqual(@as(?usize, 7), nextClaim("mirrors src/a.zig", 0));
    // The earliest phrase wins when several appear.
    try testing.expectEqual(@as(?usize, 7), nextClaim("mirrors and matches", 0));
}

// spec: Twin Referent - Indexes declared, field and dereferenced names as the tree's symbols

test "buildResolver records module basenames and known names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]ast_index.Entry{
        try testEntry(a, "src/board/limits.zig",
            \\pub const Opts = struct { max_bytes: usize = 1 };
            \\fn helper() void { other.field = 2; }
            \\
        ),
    };
    const resolver = try buildResolver(a, &files, &.{});
    try testing.expect(resolver.modules.contains("limits"));
    try testing.expect(resolver.symbols.contains("Opts"));
    try testing.expect(resolver.symbols.contains("helper"));
    // A struct field is a name a comment may legitimately point at.
    try testing.expect(resolver.symbols.contains("max_bytes"));
    // So is a dereferenced member.
    try testing.expect(resolver.symbols.contains("field"));
    try testing.expect(!resolver.symbols.contains("missing"));
}
