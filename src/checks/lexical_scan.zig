//! The machinery two text-level checks share: the contexts a plain-text scan
//! must NOT judge, and the file walk that reaches the languages no Zig parser
//! sees.
//!
//! `concept` and `canonical-idiom` are Guardian's two RELATIONAL checks, and
//! both match LEXICALLY on purpose — the drift they exist for crosses languages
//! (Zig, JS, CSS, TOML) and there is no parser that spans them. That shared
//! decision drags two shared obligations with it, and this module is where they
//! live so the two checks can never answer them differently:
//!
//! 1. **What is blanked before matching.** A comment line cannot disagree with
//!    the canonical form at runtime, and a Zig `test` block's literal is the
//!    independent golden a sync-triangle test is supposed to spell — deriving
//!    the expectation from the owner would make the test circular. Counting
//!    either forced whole files into the frozen ledger, and because both checks
//!    key a violation by `<file>` × `<rule>`, a file frozen over a doc comment
//!    is a file whose REAL drift the gate can never see again.
//! 2. **Which files a glob may reach.** A `files` glob names any extension, so
//!    the walk is a plain recursive directory walk rather than the parsed
//!    `.zig` source index — and it must prune the same build output and
//!    dot-directories in both checks, or one of them reports `.git` objects and
//!    a vendored `node_modules` as project drift.
//!
//! Exactly what is blanked: a line whose first non-whitespace opens `//` (so
//! `///` and `//!` too), in every file; a line-leading `/* … */` block through
//! its closing delimiter, in `.css` files; and a Zig `test` declaration's whole
//! span, wherever a parse tree was available. Nothing else. A TRAILING comment
//! of either shape shares a code line, and judging one needs the per-language
//! string lexer these checks refuse to be (`"https://…"`), so a code line always
//! counts whole. Blanking writes spaces over the bytes and never over a newline,
//! so every surviving occurrence keeps its exact offset AND its exact source
//! line — a reported line is one a reader can jump to, not one they have to
//! re-grep for.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const decls = @import("../ast/decls.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// Read cap for a file pulled in by a `files` glob. Above this the read fails
/// loud (as the source walker does) rather than skipping the file: a silently
/// unscanned file is exempt from the gate, which is the failure a relational
/// check is least able to afford.
pub const read_limit = 10 * 1024 * 1024;

/// Paths exempt from every relational rule, always. The declaration names its
/// own literals and fragments, and Guardian's own metadata records the
/// violations verbatim — a rule that flagged either would flag the act of
/// declaring or recording it.
const always_exempt = [_][]const u8{ "guardian.toml", ".guardian/" };

/// Directory names a `files` glob never descends into: dot-directories (VCS
/// metadata, Guardian state, editor and agent scratch) and build output. None
/// of them is project source, and on a real repo `.git` / `.zig-cache` /
/// `zig-out` dwarf everything a rule could legitimately name.
const skip_dir_names = [_][]const u8{ "zig-out", "zig-cache", "node_modules" };

// ── Scrubbing: the contexts a lexical scan must not judge ───────────────

/// A copy of `content` with the exempt contexts blanked to spaces: every line
/// whose first non-whitespace bytes open a `//` comment, every line-leading
/// `/* … */` block in a `.css` file, and — when a Zig parse `tree` is supplied
/// — every `test` declaration's span. Bytes are replaced, never removed, and a
/// newline is never one of them, so each surviving occurrence keeps its exact
/// offset AND its exact source line.
pub fn scrubbed(
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
/// lexer these checks refuse to be.
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

// ── Path policy shared by both relational checks ────────────────────────

/// True when a configured path glob names `rel_path`. Both skip lists these
/// checks honor — a `[[allow]] check = "<name>"` entry and the top-level
/// `exclude` list — are path globs of the same shape, so they share one matcher.
pub fn skipPath(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// True when `rel_path` is exempt from every rule by construction — the
/// guardian.toml that declares the spellings, or Guardian's own `.guardian/`
/// state that records the findings.
pub fn selfExempt(rel_path: []const u8) bool {
    for (always_exempt) |prefix| {
        if (std.mem.startsWith(u8, rel_path, prefix)) return true;
    }
    return false;
}

/// True when a directory is never descended into while expanding a `files`
/// glob (see `skip_dir_names`; every dot-directory is skipped too).
pub fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dir_names) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

// ── The glob walk ───────────────────────────────────────────────────────

/// Function signature of a `walkFiles` callback. It receives the open directory
/// and the file's own name (so it can read without re-resolving a path) plus
/// the project-relative path a glob is matched against. The error set is
/// `walk.WalkError` rather than `walk.VisitError`, because unlike the parsed
/// source walk this visitor does the READING itself and so owns the file
/// errors too.
pub const VisitFn = *const fn (
    ctx: *anyopaque,
    dir: fs.Dir,
    name: []const u8,
    rel_path: []const u8,
) walk.WalkError!void;

/// Bundle of (context pointer, callback) supplied to `walkFiles`.
pub const Visitor = struct {
    ctx: *anyopaque,
    visit: VisitFn,
};

/// Walks `dir` recursively, invoking `visitor` for every file, with `prefix`
/// prepended to each project-relative path. Every extension is yielded — the
/// caller decides which of them a rule names, and doing that BEFORE reading is
/// what keeps a `*.css` rule from opening the repository's binaries. A glob
/// matching nothing is silence, not an error: a project may declare a rule
/// before the canonical home or the drifting asset exists.
// twin-drift-ok: `walk.walkRecursive` is the other directory walk and the two
// policies are deliberately opposite. That one filters by extension and READS
// each file for the Zig checks; this one yields every extension and reads
// nothing, which is what keeps a `*.css` rule from opening the repository's
// binaries. Merging them would mean one walker carrying both policies as flags,
// and the flag that matters here is the one a caller would get wrong.
pub fn walkFiles(
    allocator: Allocator,
    dir: fs.Dir,
    prefix: []const u8,
    visitor: Visitor,
) walk.WalkError!void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        switch (entry.kind) {
            .directory => {
                if (skipDir(entry.name)) continue;
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkFiles(allocator, sub, rel, visitor);
            },
            .file => try visitor.visit(visitor.ctx, dir, entry.name, rel),
            else => {},
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Lexical Scan - Blanks a comment line to spaces without moving any later byte

test "scrubbed blanks a line-leading comment and keeps every offset exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\// F.Cu is the front copper layer
        \\const front = "F.Cu";
    ;
    const out = try scrubbed(arena.allocator(), "src/render.zig", source, null);
    // Same length, same newlines: the second line still starts where it did, so
    // a reported line number is the source line a reader can jump to.
    try testing.expectEqual(source.len, out.len);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfPos(u8, out, 0, "front copper"));
    // Only the comment went; the code line is untouched, offset for offset.
    try testing.expectEqual(std.mem.indexOf(u8, source, "const front"), std.mem.indexOf(u8, out, "const front"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
}

// spec: Lexical Scan - Blanks a line-leading CSS block comment only in a css file

test "scrubbed blanks a css block comment but leaves the same bytes in a zig file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\/* the front copper
        \\   layer is F.Cu */ .front { color: #c83434; }
    ;
    const css = try scrubbed(a, "assets/theme.css", source, null);
    try testing.expect(std.mem.indexOf(u8, css, "F.Cu") == null);
    // The code sharing the closing line still counts, unshifted.
    try testing.expect(std.mem.indexOf(u8, css, "#c83434") != null);
    // A `/* … */` block is CSS syntax, so the same bytes in a .zig file are not
    // a comment and are never blanked — the extension is what decides.
    const zig = try scrubbed(a, "src/render.zig", source, null);
    try testing.expect(std.mem.indexOf(u8, zig, "F.Cu") != null);
}

// spec: Lexical Scan - Blanks a Zig test declaration's whole span when a parse tree is supplied

test "scrubbed blanks a test block and leaves the code around it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeSentinel(u8,
        \\const top = "F.Cu";
        \\test "golden pins the wire format" {
        \\    const want = "B.Cu";
        \\    _ = want;
        \\}
        \\const bottom = "In1.Cu";
    , 0);
    var tree = try Ast.parse(a, source, .{});
    const out = try scrubbed(a, "src/render.zig", source, &tree);
    // The golden inside the test is gone; the two consts around it are not.
    try testing.expect(std.mem.indexOf(u8, out, "B.Cu") == null);
    try testing.expect(std.mem.indexOf(u8, out, "F.Cu") != null);
    // And the last line is still the last line: blanking never ate a newline.
    try testing.expectEqual(std.mem.indexOf(u8, source, "In1.Cu"), std.mem.indexOf(u8, out, "In1.Cu"));
    // With no tree the same bytes are left whole — the exemption needs a parse.
    const unparsed = try scrubbed(a, "src/render.zig", source, null);
    try testing.expect(std.mem.indexOf(u8, unparsed, "B.Cu") != null);
}

// spec: Lexical Scan - Skips a path an allow entry or a top-level exclude glob names

test "skipPath drops a path either skip list names" {
    // Both lists reaching a relational check are ordinary path globs: an
    // `[[allow]] check = "<name>"` entry (that check's own exemptions) and the
    // top-level `exclude` (files no check may see at all), concatenated by `run`.
    const skip = [_][]const u8{ "src/vendor/*", "src/generated/*" };
    try testing.expect(skipPath(&skip, "src/vendor/theirs.zig"));
    try testing.expect(skipPath(&skip, "src/generated/tables.zig"));
    try testing.expect(!skipPath(&skip, "src/render.zig"));
    // An empty list — the zero-config default — skips nothing.
    try testing.expect(!skipPath(&.{}, "src/render.zig"));
}

// spec: Lexical Scan - Exempts guardian.toml and the .guardian directory from every relational rule

test "selfExempt covers the declaration and Guardian's own metadata" {
    try testing.expect(selfExempt("guardian.toml"));
    try testing.expect(selfExempt(".guardian/baselines/concept.txt"));
    try testing.expect(!selfExempt("src/render.zig"));
}

// spec: Lexical Scan - Skips build output and dot directories when expanding a files glob

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

const CollectCtx = struct {
    allocator: Allocator,
    seen: std.ArrayList([]const u8) = .empty,

    fn visit(raw_ctx: *anyopaque, _: fs.Dir, _: []const u8, rel_path: []const u8) walk.WalkError!void {
        const self: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
        try self.seen.append(self.allocator, rel_path);
    }
};

/// True when the walk yielded exactly this project-relative path.
fn sawPath(seen: []const []const u8, want: []const u8) bool {
    for (seen) |rel| {
        if (std.mem.eql(u8, rel, want)) return true;
    }
    return false;
}

// spec: Lexical Scan - Yields every extension under a walked directory and prunes skipped ones

test "walkFiles reaches assets no Zig walker sees and skips build output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx: CollectCtx = .{ .allocator = arena.allocator() };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try walkFiles(arena.allocator(), root, "", .{ .ctx = &ctx, .visit = CollectCtx.visit });
    // The stylesheet is why this walk exists at all: no Zig source walker yields
    // it, and the drift a relational rule chases crosses into it.
    try testing.expect(sawPath(ctx.seen.items, "assets/theme.css"));
    try testing.expect(sawPath(ctx.seen.items, "src/main.zig"));
    // Nested directories are descended; pruned ones are not.
    try testing.expect(sawPath(ctx.seen.items, "src/core/math.zig"));
    for (ctx.seen.items) |rel| {
        try testing.expect(std.mem.indexOf(u8, rel, "zig-out/") == null);
        try testing.expect(std.mem.indexOf(u8, rel, ".zig-cache/") == null);
    }
}
