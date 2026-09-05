//! error-path-test: an error path added by this change must be named by a test,
//! or waived in writing. Diff-scoped sibling of `change-classification` — it
//! reuses the same base-ref plumbing (`--against` / `GUARDIAN_AGAINST` /
//! `[change_classification] against`, default HEAD) and the same
//! skip-outside-a-git-repository degradation.
//!
//! **Why.** From "Test Coverage Analysis of Agentic Pull Requests" (Dipongkor,
//! Baral, Lam, Moran; arXiv:2607.18057; accepted at ICSME 2026; 4,882 agent PRs
//! across Codex, Copilot, Cursor, Claude Code and Devin): "error-handling lines
//! are under-tested in both languages. Newly added Throw statements miss 67.5%
//! in Java and 82.3% of the time in Python; lines inside Try-Catch blocks miss
//! 86.0% and 81.0%, respectively." The authors' own conclusion: "Error handling
//! is the weakest spot in both languages, with most Throw statements and
//! Try-Catch bodies left unexercised."
//!
//! **Two qualifications that scope that number, and must not be dropped.**
//!
//!   1. The superlative is "most consistently under-tested across BOTH
//!      languages", not "highest single cell". Python `Continue` (90.2%) and
//!      `Switch` (100%) exceed Python Try-Catch, but rest on tiny samples.
//!   2. Table II's Miss% was measured with the agent's own test changes
//!      REMOVED. So 67.5–86% describes how badly EXISTING suites cover
//!      agent-added error paths — not total coverage. That is what makes the
//!      intervention worth having: the gap is exactly the one an added test in
//!      the same change closes.
//!
//! **The Zig bonus.** Zig's explicit, named error unions make error-identifier
//! extraction materially more tractable than Java `throw` or Python `except`:
//! `return error.OutOfRange` names its error in the token stream, so the
//! cross-reference is a lexical lookup rather than a type inference. This is a
//! case where the language helps the gate.
//!
//! **What it flags**, per line ADDED in the diff, in production code only
//! (test blocks are skipped):
//!
//!   * `return error.X` — subject is `X`.
//!   * a new member of an `error{ … }` set declaration — subject is the member.
//!   * a new `catch |e| { … }` block — subject is the ENCLOSING FUNCTION's name.
//!   * a new `errdefer` — subject is the enclosing function's name.
//!
//! A finding stands unless the subject is named by some test in the tree, or the
//! line carries a `// UNTESTED-ERROR: <reason>` waiver.
//!
//! **One lookup covers both "a test hunk in this diff" and "an existing test".**
//! The tested-name scan reads `src/` and `test/` FROM DISK — the new side — so a
//! test added in the very same change is already there, exactly as the spec
//! check's tag scan works. There is no separate diff-side test scan to drift.
//!
//! **Limitations, stated rather than papered over.**
//!
//!   * An error propagated with `try` and exercised only through an integration
//!     test that never names it false-positives. That is the acknowledged
//!     moderate-FP case; the waiver comment is the escape hatch.
//!   * Only a literal `return error.X` counts as a throw. `error.X` in a
//!     comparison (`if (e == error.X)`) is not a new error path and is ignored,
//!     and a `try` that merely propagates someone else's error is invisible.
//!   * The subject for a `catch` block or an `errdefer` is the enclosing
//!     function's NAME, because neither construct names an error identifier.
//!     That is a lexical proxy, not a coverage measurement.
//!   * A finding inside a function whose name cannot be resolved is dropped
//!     rather than reported against an empty subject.
//!   * No dataflow and no coverage instrumentation: git diff parsing, a token
//!     scan, and a lexical cross-reference. It cannot know that a test EXERCISES
//!     the path, only that some test NAMES it.
//!   * A clean working tree against HEAD is an empty diff and passes. Unlike
//!     change-classification there is no last-commit fallback: this check is
//!     about the change being written, and the `commit` gate runs it on a dirty
//!     tree.

const std = @import("std");
const git = @import("../git.zig");
const text = @import("../text.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const check_name = "error-path-test";
/// The comment that waives one added error path. The reason after the colon is
/// mandatory: a bare marker waives nothing, so "silence it" always costs a
/// sentence explaining why the path is untestable here.
const waiver_marker = "// UNTESTED-ERROR:";
const src_prefix = "src/";
const zig_ext = ".zig";
/// Directory of standalone test files scanned whole (not just its test blocks).
const test_dir = "test";
/// How many findings are listed before the report truncates.
const max_reported = 20;
/// Shortest word lifted out of a test's name string; below this a fragment is
/// noise ("of", "a") rather than an identifier a test could be naming.
const min_name_word = 3;

/// A whole-file span for untracked (brand new) files: every line is added.
const whole_file_span = [_]git.LineSpan{.{ .start = 1, .len = std.math.maxInt(u32) }};

/// What kind of error path one added line introduced.
pub const Kind = enum {
    returned_error,
    error_set_member,
    catch_block,
    errdefer_stmt,

    /// How this kind reads in a finding message.
    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .returned_error => "returned error",
            .error_set_member => "error-set member",
            .catch_block => "catch block",
            .errdefer_stmt => "errdefer",
        };
    }

    /// What a test must name to cover this kind: the error identifier itself,
    /// or — for the two constructs that name no error — the enclosing function.
    pub fn subjectNoun(self: Kind) []const u8 {
        return switch (self) {
            .returned_error, .error_set_member => "error",
            .catch_block, .errdefer_stmt => "enclosing fn",
        };
    }
};

/// One added error path: where it is, what it is, and the identifier a test has
/// to name for it to count as covered.
pub const Finding = struct {
    line: u32,
    kind: Kind,
    name: []const u8,
};

/// Which part of a file counts as test code when harvesting tested names.
/// An enum rather than a bool so the call site reads at the call site (and so
/// the signature does not trip boolean-param-ban).
pub const TestRegion = enum {
    /// A production file: only `test { … }` bodies are test code.
    test_blocks_only,
    /// A file under `test/`: helpers there are test code too.
    whole_file,
};

// ── Pure core: what the added lines introduced ─────────────────────────

/// Token-scan state for one file. Kept as a struct so the per-token handlers
/// stay small enough to read.
const Scan = struct {
    allocator: Allocator,
    z: [:0]const u8,
    lines: []const []const u8,
    spans: []const git.LineSpan,
    out: *std.ArrayList(Finding),
    scope: text.TestScope = .{},
    /// Forward-only line counter — tokens arrive in ascending byte order, so
    /// `lineOf`'s restart-from-zero would make the scan quadratic.
    cursor: text.LineCursor = .{},
    /// The three token tags before the current one. `return error . X` is a
    /// four-token shape, and carrying its history is what keeps the check from
    /// re-tokenizing the file at every field access.
    prev: std.zig.Token.Tag = .invalid,
    prev2: std.zig.Token.Tag = .invalid,
    prev3: std.zig.Token.Tag = .invalid,
    /// Inside the braces of an `error{ … }` set declaration.
    in_error_set: bool = false,
    /// Progress through `catch` `|` `e` `|` `{`.
    catch_state: CatchState = .none,
    catch_line: u32 = 0,
    /// Name of the most recent `fn <name>` seen — the subject a `catch` block
    /// or an `errdefer` is reported against.
    fn_name: []const u8 = "",

    /// The 1-indexed line of `byte`, advancing the forward-only cursor.
    fn lineAt(self: *Scan, byte: usize) u32 {
        return self.cursor.at(self.z, byte);
    }
};

/// Progress through the one shape that counts as a catch BLOCK:
/// `catch` `|` `<capture>` `|` `{`. Anything else resets to `.none`, so
/// `catch return err` and `catch null` are not error-handling bodies.
const CatchState = enum { none, after_catch, after_pipe, after_capture, after_close_pipe };

/// Every error path the lines covered by `spans` introduce, in source order.
/// Pure: it reads `content` and nothing else, so the whole classification is
/// unit-testable without a filesystem or a repository.
///
/// Findings inside `test { … }` blocks are dropped (a test's own error path is
/// not production code), as are lines carrying a `// UNTESTED-ERROR: <reason>`
/// waiver and findings whose enclosing function cannot be named.
pub fn analyzeAdded(
    allocator: Allocator,
    content: [:0]const u8,
    spans: []const git.LineSpan,
) Allocator.Error![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    var scan: Scan = .{
        .allocator = allocator,
        .z = content,
        .lines = try splitLines(allocator, content),
        .spans = spans,
        .out = &out,
    };
    var tok = std.zig.Tokenizer.init(content);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        try step(&scan, t);
        scan.scope.update(t.tag);
        scan.prev3 = scan.prev2;
        scan.prev2 = scan.prev;
        scan.prev = t.tag;
    }
    return out.toOwnedSlice(allocator);
}

/// Advances the scan by one token, recording any error path it completes.
fn step(scan: *Scan, t: std.zig.Token) Allocator.Error!void {
    if (scan.prev == .keyword_fn and t.tag == .identifier) {
        scan.fn_name = scan.z[t.loc.start..t.loc.end];
    }
    if (scan.scope.in_test) {
        scan.in_error_set = false;
        scan.catch_state = .none;
        return;
    }
    if (scan.in_error_set) return stepErrorSet(scan, t);
    if (scan.prev == .keyword_error and t.tag == .l_brace) {
        scan.in_error_set = true;
        return;
    }
    if (stepCatch(scan, t)) |line| try record(scan, line, .catch_block, scan.fn_name);
    try stepReturnedError(scan, t);
    if (t.tag == .keyword_errdefer) {
        try record(scan, scan.lineAt(t.loc.start), .errdefer_stmt, scan.fn_name);
    }
}

/// Records `return error.X`. Only a literal return counts: `error.X` in a
/// comparison is a read of an error, not a new path that can fail.
fn stepReturnedError(scan: *Scan, t: std.zig.Token) Allocator.Error!void {
    if (t.tag != .identifier or scan.prev != .period) return;
    if (scan.prev2 != .keyword_error or scan.prev3 != .keyword_return) return;
    try record(scan, scan.lineAt(t.loc.start), .returned_error, scan.z[t.loc.start..t.loc.end]);
}

/// Records each member name inside an `error{ … }` declaration and closes the
/// set on its `}`.
fn stepErrorSet(scan: *Scan, t: std.zig.Token) Allocator.Error!void {
    switch (t.tag) {
        .r_brace => scan.in_error_set = false,
        .identifier => try record(
            scan,
            scan.lineAt(t.loc.start),
            .error_set_member,
            scan.z[t.loc.start..t.loc.end],
        ),
        else => {},
    }
}

/// Drives the `catch` `|` `capture` `|` `{` recognizer, returning the `catch`
/// keyword's line when the shape completes. Any other token resets the state,
/// so `catch null` and `catch return err` — handlers with no body a test could
/// exercise — never complete it.
fn stepCatch(scan: *Scan, t: std.zig.Token) ?u32 {
    switch (scan.catch_state) {
        .none => if (t.tag == .keyword_catch) {
            scan.catch_line = scan.lineAt(t.loc.start);
            scan.catch_state = .after_catch;
        },
        .after_catch => scan.catch_state = if (t.tag == .pipe) .after_pipe else .none,
        .after_pipe => scan.catch_state = if (t.tag == .identifier) .after_capture else .none,
        .after_capture => scan.catch_state = if (t.tag == .pipe) .after_close_pipe else .none,
        .after_close_pipe => {
            scan.catch_state = .none;
            if (t.tag == .l_brace) return scan.catch_line;
        },
    }
    return null;
}

/// Appends one finding when its line was actually added, is not waived, and has
/// a nameable subject.
fn record(scan: *Scan, line: u32, kind: Kind, name: []const u8) Allocator.Error!void {
    if (name.len == 0) return;
    if (!covers(scan.spans, line)) return;
    if (waiverFor(scan.lines, line) != null) return;
    try scan.out.append(scan.allocator, .{ .line = line, .kind = kind, .name = name });
}

/// True when 1-indexed `line` falls inside any added-line span.
fn covers(spans: []const git.LineSpan, line: u32) bool {
    for (spans) |s| if (s.contains(line)) return true;
    return false;
}

/// The reason text of the `// UNTESTED-ERROR: <reason>` waiver covering
/// 1-indexed `line`, or null when there is none.
///
/// A waiver may sit at the end of the line itself, or anywhere in the
/// contiguous comment block directly above it — the two places a reader would
/// look. A marker with nothing after the colon returns null: waiving an error
/// path costs a reason, or it costs nothing and means nothing.
pub fn waiverFor(lines: []const []const u8, line: u32) ?[]const u8 {
    if (line == 0 or line > lines.len) return null;
    if (reasonIn(lines[line - 1])) |r| return r;
    var i = line - 1;
    while (i > 0) : (i -= 1) {
        const above = std.mem.trim(u8, lines[i - 1], &std.ascii.whitespace);
        if (!std.mem.startsWith(u8, above, "//")) return null;
        if (reasonIn(above)) |r| return r;
    }
    return null;
}

/// The non-empty reason following a waiver marker on one line, or null.
fn reasonIn(raw: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, raw, waiver_marker) orelse return null;
    const reason = std.mem.trim(u8, raw[at + waiver_marker.len ..], &std.ascii.whitespace);
    return if (reason.len == 0) null else reason;
}

fn splitLines(allocator: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    return lines.toOwnedSlice(allocator);
}

// ── Pure core: what the tests already name ─────────────────────────────

/// Adds every identifier a test in `content` names to `out`, plus the
/// identifier-shaped words of any string literal inside a test (a test called
/// `"rejects error.OutOfRange"` names that error as surely as a call would).
///
/// `region` decides what counts as test code: a production file contributes its
/// `test { … }` bodies only, while a file under `test/` contributes everything,
/// because its helpers are test code as much as its assertions are.
pub fn collectTestedNames(
    allocator: Allocator,
    content: [:0]const u8,
    region: TestRegion,
    out: *std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
    var tok = std.zig.Tokenizer.init(content);
    var scope: text.TestScope = .{};
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        scope.update(t.tag);
        // `pending` covers the header — `test "rejects EmptyInput"` — whose name
        // string is consumed before the opening brace makes `in_test` true. A
        // test's TITLE is where an error is most often named, so losing it would
        // cost the check most of its recall.
        const in_test_code = scope.in_test or scope.pending;
        if (region == .test_blocks_only and !in_test_code) continue;
        const raw = content[t.loc.start..t.loc.end];
        switch (t.tag) {
            .identifier => try out.put(allocator, raw, {}),
            .string_literal => try putWords(allocator, raw, out),
            else => {},
        }
    }
}

/// Adds every identifier-shaped word of a string literal to `out`.
fn putWords(allocator: Allocator, raw: []const u8, out: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= raw.len) : (i += 1) {
        const is_word = i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '_');
        if (is_word) continue;
        if (i - start >= min_name_word) try out.put(allocator, raw[start..i], {});
        start = i + 1;
    }
}

// ── Run entry ──────────────────────────────────────────────────────────

/// Entry point for the error-path-test check. Diffs the working tree against
/// the effective ref, classifies the added error paths in every changed src
/// file, and fails on any whose subject no test names and no waiver covers.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const a = ctx.allocator;
    const effective = ctx.against orelse ctx.cfg.change_classification.against;
    const wt = switch (try git.diffAgainst(a, ctx.project_dir, effective)) {
        .unavailable => |reason| {
            reporter.ok("{s}: skipped — {s}", .{ check_name, reason });
            return;
        },
        .ok => |fds| fds,
    };
    var span_map: std.StringHashMapUnmanaged([]const git.LineSpan) = .empty;
    for (wt) |fd| {
        if (isSrcZig(fd.path)) try span_map.put(a, fd.path, fd.spans);
    }
    for (try git.untrackedFiles(a, ctx.project_dir)) |p| {
        if (isSrcZig(p)) try span_map.put(a, p, &whole_file_span);
    }

    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, a, ctx.project_dir, &storage);
    const tested = try testedNames(a, ctx.project_dir, idx);
    var uncovered: std.ArrayList(reporter.Violation) = .empty;
    try collectUncovered(a, idx, &span_map, tested, &uncovered);
    return report(effective, uncovered.items);
}

/// Every identifier the tree's tests name: the `test { … }` bodies of every
/// indexed src file, plus every token of every file under `test/`.
fn testedNames(
    a: Allocator,
    project_dir: []const u8,
    idx: *const ast_index.Index,
) walk.WalkError!std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    for (idx.files) |entry| try collectTestedNames(a, entry.content, .test_blocks_only, &out);
    var visit_ctx: TestDirCtx = .{ .allocator = a, .out = &out };
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ project_dir, test_dir });
    // A project with no test/ directory is not an error — walkZigFiles treats a
    // missing root as nothing to scan.
    try walk.walkZigFiles(a, path, .{ .display_root = test_dir }, .{ .ctx = &visit_ctx, .visit = visitTestFile });
    return out;
}

const TestDirCtx = struct {
    allocator: Allocator,
    out: *std.StringHashMapUnmanaged(void),
};

fn visitTestFile(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const ctx: *TestDirCtx = @ptrCast(@alignCast(raw_ctx));
    try collectTestedNames(ctx.allocator, entry.content, .whole_file, ctx.out);
}

/// Turns each changed file's added error paths into violations, keeping only
/// the ones whose subject no test names.
fn collectUncovered(
    a: Allocator,
    idx: *const ast_index.Index,
    span_map: *const std.StringHashMapUnmanaged([]const git.LineSpan),
    tested: std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(reporter.Violation),
) Allocator.Error!void {
    for (idx.files) |entry| {
        const spans = span_map.get(entry.rel_path) orelse continue;
        for (try analyzeAdded(a, entry.content, spans)) |f| {
            if (tested.contains(f.name)) continue;
            try out.append(a, .{
                .check = check_name,
                .file = entry.rel_path,
                .line = f.line,
                .identity = f.name,
                .message = try std.fmt.allocPrint(a, "new {s} — no test names {s} `{s}`", .{
                    f.kind.label(), f.kind.subjectNoun(), f.name,
                }),
            });
        }
    }
}

/// Prints the verdict; fails the build on any uncovered added error path.
fn report(against: []const u8, uncovered: []const reporter.Violation) registry.RunError!void {
    if (uncovered.len == 0) {
        reporter.ok("{s}: every error path added vs {s} is named by a test", .{ check_name, against });
        return;
    }
    reporter.fail("{s} FAILED ({d} added error path(s) no test names)", .{ check_name, uncovered.len });
    for (uncovered, 0..) |v, i| {
        if (i >= max_reported) break;
        reporter.emitQuiet(v);
    }
    if (uncovered.len > max_reported) {
        detail("  ... and {d} more\n", .{uncovered.len - max_reported});
    }
    detail("  fix: add (or extend) a test that names the error identifier — " ++
        "`try testing.expectError(error.X, …)` is enough — in this same change.\n", .{});
    detail("  waive: put `// UNTESTED-ERROR: <reason>` on the line or in the comment " ++
        "block above it. The reason is mandatory; a bare marker waives nothing.\n", .{});
    detail("  not that: this check judges the CHANGE, so it has no baseline — " ++
        "`guardian-check accept {s} .` and `GUARDIAN_UPDATE_SNAPSHOT={s}` do NOT clear it.\n", .{ check_name, check_name });
    detail("  wrong base? the diff is against {s}: pass `--against <ref>` " ++
        "(or GUARDIAN_AGAINST=<ref>) when your change spans more than that.\n", .{against});
    return error.CheckFailed;
}

fn isSrcZig(path: []const u8) bool {
    return std.mem.startsWith(u8, path, src_prefix) and std.mem.endsWith(u8, path, zig_ext);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Every line of the sample counts as added, which is what a brand-new file
/// gets anyway.
const all_lines = [_]git.LineSpan{.{ .start = 1, .len = std.math.maxInt(u32) }};

fn analyze(arena: Allocator, comptime src: [:0]const u8) ![]const Finding {
    return analyzeAdded(arena, src, &all_lines);
}

// spec: Error Path Test - Flags a newly returned error whose identifier no test names

test "analyzeAdded reports a return error.X on an added line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyze(arena.allocator(),
        \\fn parse(s: []const u8) !u32 {
        \\    if (s.len == 0) return error.EmptyInput;
        \\    return 1;
        \\}
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(Kind.returned_error, out[0].kind);
    try testing.expectEqualStrings("EmptyInput", out[0].name);
    try testing.expectEqual(@as(u32, 2), out[0].line);
}

// spec: Error Path Test - Ignores an error identifier that is only compared rather than returned

test "analyzeAdded ignores error.X in a comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Reading an error is not a new path that can fail; only a literal return is.
    const out = try analyze(arena.allocator(),
        \\fn classify(e: anyerror) u8 {
        \\    if (e == error.OutOfMemory) return 1;
        \\    return 0;
        \\}
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Error Path Test - Flags each newly added member of an error set declaration

test "analyzeAdded reports every member of an error set declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyze(arena.allocator(),
        \\pub const ParseError = error{
        \\    Truncated,
        \\    BadMagic,
        \\};
    );
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(Kind.error_set_member, out[0].kind);
    try testing.expectEqualStrings("Truncated", out[0].name);
    try testing.expectEqualStrings("BadMagic", out[1].name);
}

// spec: Error Path Test - Reports a new catch block and errdefer against the enclosing function

test "analyzeAdded attributes a catch block and an errdefer to their function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyze(arena.allocator(),
        \\fn load(a: Allocator) !void {
        \\    const buf = try a.alloc(u8, 4);
        \\    errdefer a.free(buf);
        \\    fill(buf) catch |e| {
        \\        report(e);
        \\    };
        \\}
    );
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(Kind.errdefer_stmt, out[0].kind);
    try testing.expectEqualStrings("load", out[0].name);
    try testing.expectEqual(Kind.catch_block, out[1].kind);
    try testing.expectEqualStrings("load", out[1].name);
    // Both constructs name no error, so the subject noun says which it is.
    try testing.expectEqualStrings("enclosing fn", out[1].kind.subjectNoun());
    try testing.expectEqualStrings("catch block", out[1].kind.label());
}

// spec: Error Path Test - Treats a catch without a captured block body as no new handler

test "analyzeAdded ignores a catch with no captured block body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `catch null` and `catch return err` handle nothing a test could exercise
    // as a body; only `catch |e| { … }` is a handler with a body.
    const out = try analyze(arena.allocator(),
        \\fn read(p: []const u8) ?u32 {
        \\    return parse(p) catch null;
        \\}
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Error Path Test - Skips error paths inside test blocks and outside the added lines

test "analyzeAdded skips test blocks and unchanged lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\fn parse() !void {
        \\    return error.Untouched;
        \\}
        \\test "parses" {
        \\    return error.SkipZigTest;
        \\}
    ;
    // Whole file added: only the production return counts, never the test's.
    const full = try analyzeAdded(arena.allocator(), src, &all_lines);
    try testing.expectEqual(@as(usize, 1), full.len);
    try testing.expectEqualStrings("Untouched", full[0].name);
    // Line 2 not in the added span: an untouched error path is not this
    // change's business.
    const narrowed = try analyzeAdded(arena.allocator(), src, &.{.{ .start = 3, .len = 1 }});
    try testing.expectEqual(@as(usize, 0), narrowed.len);
}

// spec: Error Path Test - Waives an added error path carrying a reasoned UNTESTED-ERROR comment

test "waiverFor accepts a reasoned waiver above or on the line and rejects a bare marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = [_][]const u8{
        "// UNTESTED-ERROR: only reachable when the kernel refuses a valid fd",
        "    return error.Unreachable;",
        "    return error.Other; // UNTESTED-ERROR: same",
        "// UNTESTED-ERROR:",
        "    return error.Bare;",
    };
    try testing.expectEqualStrings(
        "only reachable when the kernel refuses a valid fd",
        waiverFor(&lines, 2).?,
    );
    try testing.expectEqualStrings("same", waiverFor(&lines, 3).?);
    // A marker with no reason waives nothing.
    try testing.expect(waiverFor(&lines, 5) == null);
    try testing.expect(waiverFor(&lines, 0) == null);

    // …and the scan honours it: the waived return is not a finding.
    const out = try analyze(arena.allocator(),
        \\fn open() !void {
        \\    // UNTESTED-ERROR: only reachable when the kernel refuses a valid fd
        \\    return error.Impossible;
        \\}
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Error Path Test - Counts an error named by a test in the same change as covered

test "collectTestedNames harvests identifiers and test-name words from test blocks only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names: std.StringHashMapUnmanaged(void) = .empty;
    try collectTestedNames(a,
        \\fn production() void {
        \\    const ProductionOnly = 1;
        \\    _ = ProductionOnly;
        \\}
        \\test "rejects EmptyInput" {
        \\    try expectError(error.Truncated, parse(""));
        \\}
    , .test_blocks_only, &names);
    // Named inside the test body, and named in the test's own title.
    try testing.expect(names.contains("Truncated"));
    try testing.expect(names.contains("EmptyInput"));
    // Production identifiers are not evidence that anything is tested.
    try testing.expect(!names.contains("ProductionOnly"));

    // A file under test/ contributes its helpers too, so a helper that names
    // the error still counts as coverage.
    var whole: std.StringHashMapUnmanaged(void) = .empty;
    try collectTestedNames(a, "fn helper() void { _ = error.Truncated; }", .whole_file, &whole);
    try testing.expect(whole.contains("Truncated"));
}

// spec: Error Path Test - Names the actions that clear an uncovered error path

test "report names the test, the waiver, and refuses the accept flow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cap: reporter.Capture = .{ .allocator = arena.allocator() };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    try testing.expectError(error.CheckFailed, report("HEAD", &.{.{
        .check = check_name,
        .file = "src/a.zig",
        .line = 12,
        .message = "new returned error — no test names error `Truncated`",
    }}));
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "src/a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "UNTESTED-ERROR") != null);
    // The subject is the change, so there is nothing to accept — say so, the
    // way change-classification does.
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "do NOT clear it") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "--against") != null);
    // A green run says which base it judged.
    try report("origin/main", &.{});
}

// spec: Error Path Test - Restricts the scan to source files the diff touched

test "isSrcZig admits only src Zig files" {
    try testing.expect(isSrcZig("src/checks/error_path_test.zig"));
    try testing.expect(!isSrcZig("test/golden.zig"));
    try testing.expect(!isSrcZig("src/SPEC.md"));
    try testing.expect(!isSrcZig("build.zig"));
}

fn fuzzErrorPaths(backing: Allocator, smith: *std.testing.Smith) anyerror!void {
    var bytes: [32 * 1024]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try a.dupeSentinel(u8, input, 0);
    _ = try analyzeAdded(a, z, &all_lines);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    try collectTestedNames(a, z, .whole_file, &names);
}

test "fuzz: the error-path scanners tolerate arbitrary bytes" {
    try testing.fuzz(testing.allocator, fuzzErrorPaths, .{
        .corpus = &.{ "", "return error.X;", "error{A,B}", "x catch |e| {}" },
    });
}
