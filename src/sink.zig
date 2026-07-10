//! Machine-readable last-run sink. After an `all` / `nightly` run, guardian
//! writes one JSON object per line to `.guardian/cache/last-run.jsonl`: a
//! `violation` record per finding, then a `summary` record. It exists so the
//! agent fix loop, editor integrations, and the `debt` report can read
//! structured findings instead of re-parsing terminal prose.
//!
//! The log lives under `cache/` deliberately: that subdir is git-ignored and
//! excluded from the skip-cache input digest (see `cache.zig`), so rewriting it
//! every run never churns git or invalidates the build cache. std.json does the
//! escaping — no hand-rolled JSON, and no timestamps (std.time is banned).

const std = @import("std");
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
    try std.fs.cwd().makePath(dir);
    const path = try pathFor(arena, project_dir);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(buf.items);
}

// ── Tests ──────────────────────────────────────────────────────────────

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
            "\"message\":\"fn \\\"foo\\\" is 246 lines (cap 200)\",\"fix_hint\":null," ++
            "\"ratchet_key\":\"src/x.zig|foo\",\"metric\":246}",
        try violationJson(a, v),
    );

    // An unmigrated check contributes at least check+message; the rest are null.
    const u: reporter.Violation = .{ .check = "spec", .message = "unverified: Auth - Validates tokens" };
    try std.testing.expectEqualStrings(
        "{\"type\":\"violation\",\"check\":\"spec\",\"file\":null,\"line\":null," ++
            "\"message\":\"unverified: Auth - Validates tokens\",\"fix_hint\":null," ++
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
    try std.fs.cwd().makePath(dir);
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("sink test cleanup: {s}", .{@errorName(e)});

    // A green run has zero violation records: the log is exactly the summary line.
    write(a, dir, &.{}, .{ .passed = 56, .failed = 0, .skipped = 3, .filtered = false });
    const raw = try std.fs.cwd().readFileAlloc(a, try pathFor(a, dir), 4096);
    try std.testing.expectEqualStrings(
        "{\"type\":\"summary\",\"passed\":56,\"failed\":0,\"skipped\":3,\"filtered\":false}\n",
        raw,
    );
}
