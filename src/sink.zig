//! Machine-readable last-run sink. After an `all` / `nightly` run, guardian
//! writes one JSON object per line to `.guardian/cache/last-run.jsonl`: a
//! `violation` record per finding, then a `summary` record. It exists so the
//! agent fix loop, editor integrations, and the `debt` report can read
//! structured findings instead of re-parsing terminal prose.
//!
//! A row is only as useful as its fields. A check that emits structured
//! Violations fills them itself; a check that reports prose has its findings
//! scraped, and `scrapedRecord` recovers the same shape from that text — the
//! `<file>[:<line>]: ` prefix the check printed becomes `file`/`line`, and the
//! single trailing `fix:` line it prints beneath its findings becomes every
//! row's `fix_hint`. Baseline mode routes around both paths (it consumes a
//! check's records under a nested capture and prints its own summary), so
//! `baseline.zig` forwards the findings it reports through `reporter.sink`.
//!
//! The log lives under `cache/` deliberately: that subdir is git-ignored and
//! excluded from the skip-cache input digest (see `cache.zig`), so rewriting it
//! every run never churns git or invalidates the build cache. std.json does the
//! escaping — no hand-rolled JSON, and no timestamps (std.time is banned).

const std = @import("std");
const fs = @import("fs.zig");
const Allocator = std.mem.Allocator;
const reporter = @import("reporter.zig");

/// Cache subdirectory (relative to the project dir) that holds the sink log.
const cache_subdir = ".guardian/cache";
/// Basename of the machine-readable last-run log.
const log_name = "last-run.jsonl";

/// Wire form of one violation record. Private DTO: the field order here is the
/// emitted JSON key order, and `type` discriminates it from a summary line.
const ViolationLine = struct {
    type: []const u8 = "violation",
    check: []const u8,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    message: []const u8,
    fix_hint: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    ratchet_key: ?[]const u8 = null,
    metric: ?u64 = null,
};

/// Wire form of the run summary record. Private DTO (see `ViolationLine`).
const SummaryLine = struct {
    type: []const u8 = "summary",
    passed: u32,
    failed: u32,
    skipped: u32,
    filtered: bool,
};

/// Run-level tallies written as the final `summary` record. `skipped` is the
/// registry entries not executed this pass (built-in non-gates, disabled, and
/// filtered-out checks); `filtered` is true under an active `--only`/`--skip`.
pub const Summary = struct {
    passed: u32,
    failed: u32,
    skipped: u32,
    filtered: bool,
};

/// Serializes one violation Violation to a single JSON line (no trailing
/// newline). std.json escapes the message and path text.
pub fn violationJson(arena: Allocator, v: reporter.Violation) Allocator.Error![]u8 {
    const rec: ViolationLine = .{
        .check = v.check,
        .file = v.file,
        .line = v.line,
        .message = v.message,
        .fix_hint = v.fix_hint,
        .identity = v.identity,
        .ratchet_key = v.ratchet_key,
        .metric = v.metric,
    };
    return std.json.Stringify.valueAlloc(arena, rec, .{});
}

/// Serializes the run summary to a single JSON line (no trailing newline).
pub fn summaryJson(arena: Allocator, s: Summary) Allocator.Error![]u8 {
    const rec: SummaryLine = .{
        .passed = s.passed,
        .failed = s.failed,
        .skipped = s.skipped,
        .filtered = s.filtered,
    };
    return std.json.Stringify.valueAlloc(arena, rec, .{});
}

/// A scraped violation line split into the fields a sink record carries.
/// `message` is the tail after the location prefix — the same text a check that
/// emits structured records puts in `Violation.message`, so `reporter.flatLine`
/// renders the record back to the line it was scraped from.
pub const Location = struct {
    file: ?[]const u8 = null,
    line: ?u32 = null,
    message: []const u8,
};

/// Splits the `<file>[:<line>]: ` prefix a prose-reporting check printed inside
/// its own violation text, so its sink row carries `file`/`line` as fields
/// instead of burying them in the message. Recognizes the two canonical
/// spellings (`src/x.zig:12: msg` and `src/x.zig: msg`); any other shape that
/// still opens with a `.zig` path (guardian's own `src/x.zig::symbol: msg`)
/// contributes the file alone and keeps its message verbatim, and text with no
/// leading path is returned unchanged. Conservative on purpose: a mis-split
/// would corrupt a message, while a missed split only leaves today's behavior.
pub fn splitLocation(text: []const u8) Location {
    const path_end = zigPathEnd(text) orelse return .{ .message = text };
    const file = text[0..path_end];
    const rest = text[path_end..];
    if (rest.len == 0 or rest[0] != ':') return .{ .file = file, .message = text };
    const after = rest[1..];
    if (splitLineNumber(after)) |n| return .{ .file = file, .line = n.line, .message = n.rest };
    if (std.mem.startsWith(u8, after, " ")) return .{ .file = file, .message = after[1..] };
    return .{ .file = file, .message = text };
}

/// End offset of a leading Zig source path (`src/x.zig`), or null when the text
/// does not open with one. The path must be the line's own first token — no
/// whitespace before the extension — so prose that merely mentions a file later
/// on is never mistaken for a location prefix.
fn zigPathEnd(text: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, text, ".zig") orelse return null;
    const end = idx + ".zig".len;
    if (std.mem.indexOfAny(u8, text[0..end], " \t") != null) return null;
    return end;
}

/// `<line>: <rest>` split of the text following a path's colon, or null when
/// what follows is not a line number (a symbol name, a bare message).
const NumberedLine = struct { line: u32, rest: []const u8 };

fn splitLineNumber(after: []const u8) ?NumberedLine {
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    if (colon == 0) return null;
    const n = std.fmt.parseInt(u32, after[0..colon], 10) catch return null;
    const rest = after[colon + 1 ..];
    return .{ .line = n, .rest = if (std.mem.startsWith(u8, rest, " ")) rest[1..] else rest };
}

/// The sink record for one violation line scraped from a check that reports
/// prose rather than structured Violations: the location it printed inside its
/// own text becomes `file`/`line`, and its single trailing `fix:` line — which
/// applies to every finding that check made — becomes the row's `fix_hint`.
/// That is what makes an unmigrated check's rows as actionable as a migrated
/// check's without touching the check itself.
pub fn scrapedRecord(check: []const u8, text: []const u8, fix_line: ?[]const u8) reporter.Violation {
    const loc = splitLocation(text);
    return .{
        .check = check,
        .file = loc.file,
        .line = loc.line,
        .message = loc.message,
        .fix_hint = hintText(fix_line),
    };
}

/// The actionable half of a check's `fix: <text>` line, or null when there is
/// none (or nothing but the label). Public because a check that emits
/// structured records reaches the same line the same way: the runner fills any
/// record that carries no hint of its own from it.
pub fn hintText(fix_line: ?[]const u8) ?[]const u8 {
    const raw = fix_line orelse return null;
    const tail = if (std.mem.startsWith(u8, raw, "fix:")) raw["fix:".len..] else raw;
    const body = std.mem.trim(u8, tail, " \t\r\n");
    return if (body.len == 0) null else body;
}

/// Path to the last-run log: `<project_dir>/.guardian/cache/last-run.jsonl`.
pub fn pathFor(arena: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ project_dir, cache_subdir, log_name });
}

/// Writes the last-run log: one violation record per entry, then a summary
/// record. Written on every real `all`/`nightly` run, including green ones (a
/// green run yields a summary-only log). Best-effort — any I/O error is
/// swallowed so the sink can never fail the build.
pub fn write(arena: Allocator, project_dir: []const u8, records: []const reporter.Violation, summary: Summary) void {
    writeInner(arena, project_dir, records, summary) catch |e|
        std.log.warn("guardian sink write failed: {s}", .{@errorName(e)});
}

fn writeInner(
    arena: Allocator,
    project_dir: []const u8,
    records: []const reporter.Violation,
    summary: Summary,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    for (records) |v| {
        try buf.appendSlice(arena, try violationJson(arena, v));
        try buf.append(arena, '\n');
    }
    try buf.appendSlice(arena, try summaryJson(arena, summary));
    try buf.append(arena, '\n');

    const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, cache_subdir });
    try fs.cwd().makePath(dir);
    const path = try pathFor(arena, project_dir);
    const f = try fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(buf.items);
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Machine-Readable Sink - Lifts a scraped line's file and line number into the record's own fields

test "splitLocation reads both canonical location prefixes and leaves prose alone" {
    // `<file>:<line>: <msg>` — what most prose checks print.
    const with_line = splitLocation("src/x.zig:12: catch block is empty");
    try std.testing.expectEqualStrings("src/x.zig", with_line.file.?);
    try std.testing.expectEqual(@as(u32, 12), with_line.line.?);
    try std.testing.expectEqualStrings("catch block is empty", with_line.message);

    // `<file>: <msg>` — a whole-file finding has no line to name.
    const file_only = splitLocation("src/x.zig: pub fn thing: has no /// doc comment");
    try std.testing.expectEqualStrings("src/x.zig", file_only.file.?);
    try std.testing.expectEqual(@as(?u32, null), file_only.line);
    try std.testing.expectEqualStrings("pub fn thing: has no /// doc comment", file_only.message);

    // A non-canonical shape (`<file>::<symbol>`) still yields the file, but its
    // message is kept verbatim rather than split at a guessed boundary.
    const symbol = splitLocation("src/x.zig::join: unused public declaration");
    try std.testing.expectEqualStrings("src/x.zig", symbol.file.?);
    try std.testing.expectEqualStrings("src/x.zig::join: unused public declaration", symbol.message);

    // Prose that merely mentions a file later on is not a location, and neither
    // is a bare behavior sentence: both pass through untouched.
    for ([_][]const u8{
        "unverified: Auth - Validates tokens",
        "cycle through src/a.zig",
    }) |prose| {
        const loc = splitLocation(prose);
        try std.testing.expectEqual(@as(?[]const u8, null), loc.file);
        try std.testing.expectEqualStrings(prose, loc.message);
    }
}

// spec: Machine-Readable Sink - Attaches a prose check's own fix line to every row it scrapes

test "scrapedRecord carries the check's fix hint and re-renders its source line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = "src/x.zig:20: test has no assertion (expect*/assert*/try)";
    const v = scrapedRecord("test-has-assertion", line, "fix: add at least one `try std.testing.expect*` call.");
    try std.testing.expectEqualStrings("test-has-assertion", v.check);
    try std.testing.expectEqualStrings("src/x.zig", v.file.?);
    try std.testing.expectEqual(@as(u32, 20), v.line.?);
    // The `fix:` label is the marker, not part of the remedy.
    try std.testing.expectEqualStrings("add at least one `try std.testing.expect*` call.", v.fix_hint.?);
    // Splitting is lossless: the record renders back to the line it came from.
    try std.testing.expectEqualStrings(line, try reporter.flatLine(a, v));

    // A check that prints no fix line leaves the hint null rather than empty.
    try std.testing.expectEqual(@as(?[]const u8, null), scrapedRecord("spec", "unverified: X - Y", null).fix_hint);
    try std.testing.expectEqual(@as(?[]const u8, null), scrapedRecord("spec", "unverified: X - Y", "fix:  ").fix_hint);
    // The same reading serves a check that emitted records: the runner fills a
    // hintless record from the very same line.
    try std.testing.expectEqualStrings("do the thing", hintText("fix: do the thing").?);
    try std.testing.expectEqual(@as(?[]const u8, null), hintText(null));
}

// spec: Machine-Readable Sink - Serializes each violation as a JSON line escaping message and path text

test "violationJson emits the full record for a migrated check and escapes text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A migrated threshold check: file+line+ratchet_key+metric all present, and
    // a message containing a quote to prove std.json escaping (not hand-rolled).
    const v: reporter.Violation = .{
        .check = "function-length",
        .file = "src/x.zig",
        .line = 5,
        .message = "fn \"foo\" is 246 lines (cap 200)",
        .ratchet_key = "src/x.zig|foo",
        .metric = 246,
    };
    try std.testing.expectEqualStrings(
        "{\"type\":\"violation\",\"check\":\"function-length\",\"file\":\"src/x.zig\",\"line\":5," ++
            "\"message\":\"fn \\\"foo\\\" is 246 lines (cap 200)\",\"fix_hint\":null,\"identity\":null," ++
            "\"ratchet_key\":\"src/x.zig|foo\",\"metric\":246}",
        try violationJson(a, v),
    );

    // An unmigrated check contributes at least check+message; the rest are null.
    const u: reporter.Violation = .{ .check = "spec", .message = "unverified: Auth - Validates tokens" };
    try std.testing.expectEqualStrings(
        "{\"type\":\"violation\",\"check\":\"spec\",\"file\":null,\"line\":null," ++
            "\"message\":\"unverified: Auth - Validates tokens\",\"fix_hint\":null,\"identity\":null," ++
            "\"ratchet_key\":null,\"metric\":null}",
        try violationJson(a, u),
    );
}

// spec: Machine-Readable Sink - Appends a run summary record with pass fail skip counts

test "summaryJson emits the run tallies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "{\"type\":\"summary\",\"passed\":55,\"failed\":1,\"skipped\":3,\"filtered\":false}",
        try summaryJson(a, .{ .passed = 55, .failed = 1, .skipped = 3, .filtered = false }),
    );
}

// spec: Machine-Readable Sink - Writes the last-run log under the git-ignored guardian cache dir

test "pathFor targets the cache subdir so the log never churns git or the skip-cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "proj/.guardian/cache/last-run.jsonl",
        try pathFor(arena.allocator(), "proj"),
    );
}

// spec: Machine-Readable Sink - Writes a summary-only log when the run passes with no violations

test "write emits a summary-only log for a green run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/sink-green-proj";
    try fs.cwd().makePath(dir);
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("sink test cleanup: {s}", .{@errorName(e)});

    // A green run has zero violation records: the log is exactly the summary line.
    write(a, dir, &.{}, .{ .passed = 56, .failed = 0, .skipped = 3, .filtered = false });
    const raw = try fs.cwd().readFileAlloc(a, try pathFor(a, dir), 4096);
    try std.testing.expectEqualStrings(
        "{\"type\":\"summary\",\"passed\":56,\"failed\":0,\"skipped\":3,\"filtered\":false}\n",
        raw,
    );
}
