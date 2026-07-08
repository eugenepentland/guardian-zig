//! DORA delivery-metrics sink — a non-gating, append-only JSONL record of every
//! `all` / `nightly` gate run, ported from the Gleam and Rust guardians. After a
//! real (non cache-skipped) run, guardian appends one line:
//!
//!   {"type":"run","branch":..,"commit":..,"outcome":"green"|"red",
//!    "failed_checks":[..],"duration_ms":N}
//!
//! It never fails the build. Downstream aggregators compute deployment
//! frequency / lead time / change-failure-rate / MTTR from the stream. The
//! default sink is `.guardian/cache/dora.jsonl`: living under `cache/` keeps it
//! out of the skip-cache input digest (see cache.zig), so writing it every run
//! never invalidates the build cache. Configured via `[dora]` in guardian.toml
//! (`enabled`, `sink_path`).
//!
//! This module is guardian's one legitimate wall-clock consumer (run duration):
//! guardian.toml grants it a `ban-time` [[allow]] for `std.time.Timer`. std.json
//! does the escaping — no hand-rolled JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const git = @import("git.zig");

/// Outcome of a gate run: every check passed, or at least one failed.
pub const Outcome = enum { green, red };

/// The fields of one run record, resolved by `recordRun` before rendering.
pub const RunRecord = struct {
    branch: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    outcome: Outcome,
    failed_checks: []const []const u8 = &.{},
    duration_ms: u64 = 0,
};

/// Wire form of a run record. Private DTO: the field order here is the emitted
/// JSON key order, and `type` discriminates it in a mixed stream.
const RunLine = struct {
    type: []const u8 = "run",
    branch: ?[]const u8,
    commit: ?[]const u8,
    outcome: []const u8,
    failed_checks: []const []const u8,
    duration_ms: u64,
};

/// A wall-clock stopwatch for run duration. `inner` is null on a platform with
/// no monotonic clock, in which case the run reports `duration_ms = 0` —
/// telemetry degrades, never gates.
pub const Stopwatch = struct {
    inner: ?std.time.Timer,

    /// Elapsed whole milliseconds since `startStopwatch`, or 0 when the timer
    /// is unavailable. Monotonic, so repeated reads never decrease.
    pub fn elapsedMs(self: *Stopwatch) u64 {
        if (self.inner) |*t| return nsToMs(t.read());
        return 0;
    }
};

/// Starts a run-duration stopwatch (best-effort: a missing monotonic clock
/// yields a stopwatch that reports 0). std.time.Timer is allowed here via the
/// `ban-time` [[allow]] for this module in guardian.toml.
pub fn startStopwatch() Stopwatch {
    return .{ .inner = std.time.Timer.start() catch null };
}

/// Whole milliseconds in `ns` (floored). Pure, so the conversion is unit-tested
/// without touching a clock.
fn nsToMs(ns: u64) u64 {
    return ns / std.time.ns_per_ms;
}

fn outcomeStr(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .green => "green",
        .red => "red",
    };
}

/// Serializes one run record to a single JSON line (no trailing newline).
/// std.json escapes branch/commit/check text.
pub fn renderRecord(arena: Allocator, rec: RunRecord) Allocator.Error![]u8 {
    const line: RunLine = .{
        .branch = rec.branch,
        .commit = rec.commit,
        .outcome = outcomeStr(rec.outcome),
        .failed_checks = rec.failed_checks,
        .duration_ms = rec.duration_ms,
    };
    return std.json.Stringify.valueAlloc(arena, line, .{});
}

/// Records one gate run to the configured sink. No-op when `[dora] enabled =
/// false`. Resolves branch/commit via git (null outside a repo), renders, and
/// appends. Best-effort: any I/O failure is logged and swallowed so the sink
/// can never fail the build.
pub fn recordRun(
    arena: Allocator,
    project_dir: []const u8,
    cfg: config_mod.DoraCfg,
    outcome: Outcome,
    failed_checks: []const []const u8,
    duration_ms: u64,
) void {
    if (!cfg.enabled) return;
    recordInner(arena, project_dir, cfg.sink_path, .{
        .branch = git.currentBranch(arena, project_dir),
        .commit = git.headHash(arena, project_dir),
        .outcome = outcome,
        .failed_checks = failed_checks,
        .duration_ms = duration_ms,
    }) catch |e| std.log.warn("guardian dora sink write failed: {s}", .{@errorName(e)});
}

/// Renders `rec` and appends it (plus a newline) to `sink_path`, resolved
/// relative to `project_dir` unless absolute. Creates the parent dir. Separated
/// from `recordRun` (which resolves git) so the render + append path is testable
/// with explicit branch/commit values.
fn recordInner(arena: Allocator, project_dir: []const u8, sink_path: []const u8, rec: RunRecord) !void {
    const line = try renderRecord(arena, rec);
    const resolved = try resolvePath(arena, project_dir, sink_path);
    try appendLine(resolved, line);
}

/// Resolves `sink_path` against `project_dir` (absolute paths pass through).
fn resolvePath(arena: Allocator, project_dir: []const u8, sink_path: []const u8) Allocator.Error![]const u8 {
    if (sink_path.len > 0 and sink_path[0] == '/') return arena.dupe(u8, sink_path);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, sink_path });
}

/// Appends `line` + newline to `path`, creating the file and any parent dirs.
fn appendLine(path: []const u8, line: []const u8) !void {
    if (parentDir(path)) |parent| try std.fs.cwd().makePath(parent);
    const f = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(line);
    try f.writeAll("\n");
}

/// The directory portion of `path`, or null when it has no separator (a bare
/// filename) or is a root-level entry.
fn parentDir(path: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (idx == 0) return null;
    return path[0..idx];
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Delivery Metrics - Renders a run record as one JSON line with outcome and failed checks

test "renderRecord emits the run record with outcome and failed checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderRecord(a, .{
        .branch = "main",
        .commit = "abc123",
        .outcome = .red,
        .failed_checks = &.{ "spec", "file-size" },
        .duration_ms = 42,
    });
    try std.testing.expectEqualStrings(
        "{\"type\":\"run\",\"branch\":\"main\",\"commit\":\"abc123\",\"outcome\":\"red\"," ++
            "\"failed_checks\":[\"spec\",\"file-size\"],\"duration_ms\":42}",
        out,
    );
}

// spec: Delivery Metrics - Includes the git branch and commit or null when absent

test "renderRecord writes null branch and commit outside a repo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderRecord(a, .{ .branch = null, .commit = null, .outcome = .green });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"branch\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"commit\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"outcome\":\"green\"") != null);
}

// spec: Delivery Metrics - Appends a run record to the sink without overwriting

test "recordInner appends each record as its own line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/dora-append-proj";
    try std.fs.cwd().makePath(dir);
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("dora test cleanup: {s}", .{@errorName(e)});

    try recordInner(a, dir, ".guardian/cache/dora.jsonl", .{ .outcome = .green });
    try recordInner(a, dir, ".guardian/cache/dora.jsonl", .{ .outcome = .red, .failed_checks = &.{"spec"} });

    const raw = try std.fs.cwd().readFileAlloc(a, dir ++ "/.guardian/cache/dora.jsonl", 4096);
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    const first = lines.next().?;
    const second = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, first, "\"outcome\":\"green\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"outcome\":\"red\"") != null);
    try std.testing.expect(lines.next() == null);
}

// spec: Delivery Metrics - Writes nothing when the dora sink is disabled

test "recordRun is a no-op when disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/dora-disabled-proj";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("dora test cleanup: {s}", .{@errorName(e)});

    // enabled = false short-circuits before any git or filesystem work.
    recordRun(a, dir, .{ .enabled = false }, .red, &.{"spec"}, 5);
    // The sink file was never created, so accessing it fails as not-found.
    try std.testing.expectError(
        error.FileNotFound,
        std.fs.cwd().access(dir ++ "/.guardian/cache/dora.jsonl", .{}),
    );
}

// spec: Delivery Metrics - Converts elapsed nanoseconds to whole milliseconds

test "nsToMs floors nanoseconds to milliseconds" {
    try std.testing.expectEqual(@as(u64, 0), nsToMs(0));
    try std.testing.expectEqual(@as(u64, 1), nsToMs(1_500_000));
    try std.testing.expectEqual(@as(u64, 2), nsToMs(2_000_000));
}

// spec: Delivery Metrics - Reads zero elapsed for an unavailable stopwatch and a non-decreasing value otherwise

test "elapsedMs is zero when unavailable and non-decreasing otherwise" {
    var off: Stopwatch = .{ .inner = null };
    try std.testing.expectEqual(@as(u64, 0), off.elapsedMs());

    var sw = startStopwatch();
    const first = sw.elapsedMs();
    const second = sw.elapsedMs();
    try std.testing.expect(second >= first);
}
