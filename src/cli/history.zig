//! `history` command — the read surface over `.guardian/cache/dora.jsonl`.
//!
//! Guardian has appended one record per gated run since the DORA sink landed
//! (see `dora.zig`), and until now nothing read them back: one consumer had 429
//! records and 351 feedback entries without a single mention of the file. The
//! data was already paid for; this command spends it.
//!
//!   guardian-check history [project-dir] [--check <name>] [--json]
//!
//! It reports how often the gate is green, how long a run costs, which checks
//! actually block, and how bad the current red patch is — the questions an
//! agent otherwise answers by guessing. `--check <name>` narrows the report to
//! one check's failure history.
//!
//! Two properties are structural rather than incidental:
//!
//!   * **Streaming.** The sink is append-only and unbounded, so the file is
//!     read one line at a time and every remembered detail lives in a
//!     fixed-size buffer. Reading a million-run log costs the same memory as
//!     reading ten.
//!   * **`--json` goes to stdout.** The other maintenance commands render JSON
//!     through `reporter.detail`, which is stderr — a caller piping the output
//!     gets nothing. A machine-readable report belongs on the machine channel.
//!
//! Read-only and never a gate: it opens one file and prints. A missing sink is
//! an ordinary answer ("no runs recorded yet"), and an undecodable line is
//! counted and skipped rather than failing the report.

const std = @import("std");
const fs = @import("../fs.zig");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const dora = @import("../dora.zig");

const print = reporter.detail;

pub const command_name = "history";

/// How many of the most recent runs the duration statistics cover. Durations
/// need every sample kept to be ordered, so they are the one unbounded thing
/// here — capping the window bounds them, and the report always names the
/// window so a median is never mistaken for an all-time figure.
const duration_window = 512;
/// Runs on the recent side of the trend comparison.
const trend_recent_runs = 20;
/// Runs on the prior side of the trend comparison, ending where recent begins.
const trend_prior_runs = 100;
/// Distinct check names the failure leaderboard can track before it starts
/// counting the rest as overflow.
const max_tracked_checks = 64;
/// Rows of the leaderboard the human report prints.
const leaderboard_rows = 5;
/// Red runs remembered for the "last failures" list.
const red_samples = 5;
/// Longest line the reader accepts; anything longer is a corrupt record.
const max_line_bytes = 64 * 1024;
/// Bounded copy size for one remembered string (a sha, a branch, a check list).
const text_capacity = 128;
/// Percentile reported next to the median.
const upper_percentile = 90;
/// Whole-percent scale.
const percent_scale = 100;
/// Characters of a commit sha the human report shows.
const short_sha_len = 8;

/// A short string copied out of the stream into fixed storage. The reader keeps
/// only these, so its memory never grows with the file; an over-long value is
/// truncated rather than allocated.
const Text = struct {
    buf: [text_capacity]u8 = @splat(0),
    len: usize = 0,

    /// Replaces the contents with (a truncated prefix of) `bytes`.
    fn set(self: *Text, bytes: []const u8) void {
        const n = @min(bytes.len, self.buf.len);
        @memcpy(self.buf[0..n], bytes[0..n]);
        self.len = n;
    }

    /// Replaces the contents with `parts` joined by ", ".
    fn setJoined(self: *Text, parts: []const []const u8) void {
        self.len = 0;
        for (parts) |part| {
            if (self.len != 0) self.append(", ");
            self.append(part);
        }
    }

    /// Appends as much of `bytes` as still fits.
    fn append(self: *Text, bytes: []const u8) void {
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }
};

/// One remembered red run.
const RedRun = struct {
    commit: Text = .{},
    branch: Text = .{},
    checks: Text = .{},
};

/// The most recent `red_samples` red runs, oldest entry overwritten first.
const RedRing = struct {
    items: [red_samples]RedRun = @splat(.{}),
    count: usize = 0,
    next: usize = 0,

    /// Remembers one red run, evicting the oldest when full.
    fn push(self: *RedRing, rec: dora.RunRecord) void {
        const slot = &self.items[self.next];
        slot.commit.set(rec.commit orelse "");
        slot.branch.set(rec.branch orelse "");
        slot.checks.setJoined(rec.failed_checks);
        self.next = (self.next + 1) % self.items.len;
        self.count += 1;
    }

    /// The remembered runs, most recent first.
    fn newestFirst(self: *const RedRing, out: []RedRun) []const RedRun {
        const kept = @min(self.count, self.items.len);
        for (0..kept) |i| out[i] = self.items[(self.next + self.items.len - 1 - i) % self.items.len];
        return out[0..kept];
    }
};

/// The most recent `duration_window` run durations, in arrival order.
const Window = struct {
    samples: [duration_window]u64 = @splat(0),
    count: usize = 0,
    next: usize = 0,

    fn push(self: *Window, ms: u64) void {
        self.samples[self.next] = ms;
        self.next = (self.next + 1) % self.samples.len;
        self.count += 1;
    }

    /// The kept durations oldest-first, written into `out`.
    fn chronological(self: *const Window, out: []u64) []u64 {
        const kept = @min(self.count, self.samples.len);
        const start = if (self.count <= self.samples.len) 0 else self.next;
        for (0..kept) |i| out[i] = self.samples[(start + i) % self.samples.len];
        return out[0..kept];
    }
};

/// A run of consecutive red runs: how long, and what the last of them failed.
const Streak = struct {
    len: usize = 0,
    checks: Text = .{},
};

/// The two streaks worth reporting: the one still open at the end of the
/// stream, and the worst one ever seen.
const Streaks = struct {
    current: Streak = .{},
    longest: Streak = .{},

    /// Extends the open streak with a red run.
    fn red(self: *Streaks, rec: dora.RunRecord) void {
        self.current.len += 1;
        self.current.checks.setJoined(rec.failed_checks);
        if (self.current.len > self.longest.len) self.longest = self.current;
    }

    /// Closes the open streak on a green run.
    fn green(self: *Streaks) void {
        self.current = .{};
    }
};

/// How often each check has failed. Bounded: past `max_tracked_checks` distinct
/// names the rest are counted as overflow rather than growing without limit.
const Tallies = struct {
    names: [max_tracked_checks][]const u8 = @splat(""),
    counts: [max_tracked_checks]usize = @splat(0),
    len: usize = 0,
    overflow: usize = 0,

    /// Counts one failure of `name`, duping it on first sight.
    fn bump(self: *Tallies, arena: Allocator, name: []const u8) Allocator.Error!void {
        for (self.names[0..self.len], 0..) |known, i| {
            if (std.mem.eql(u8, known, name)) {
                self.counts[i] += 1;
                return;
            }
        }
        if (self.len == self.names.len) {
            self.overflow += 1;
            return;
        }
        self.names[self.len] = try arena.dupe(u8, name);
        self.counts[self.len] = 1;
        self.len += 1;
    }

    /// The tracked names ordered by failure count, most frequent first.
    fn ranked(self: *const Tallies, arena: Allocator) Allocator.Error![]const Tally {
        const out = try arena.alloc(Tally, self.len);
        for (out, 0..) |*row, i| row.* = .{ .check = self.names[i], .failures = self.counts[i] };
        std.mem.sort(Tally, out, {}, moreFailures);
        return out;
    }
};

/// One leaderboard row (also the JSON shape).
const Tally = struct {
    check: []const u8,
    failures: usize,
};

fn moreFailures(_: void, a: Tally, b: Tally) bool {
    if (a.failures != b.failures) return a.failures > b.failures;
    return std.mem.lessThan(u8, a.check, b.check);
}

/// Run counts over the whole stream.
const Counts = struct {
    total: usize = 0,
    green: usize = 0,
    red: usize = 0,
    skipped: usize = 0,
};

/// The `--check <name>` view, accumulated only when a filter is active.
const CheckView = struct {
    name: ?[]const u8 = null,
    runs: usize = 0,
    recent: RedRing = .{},

    /// Folds a red run in when it names the filtered check.
    fn observe(self: *CheckView, rec: dora.RunRecord) void {
        const wanted = self.name orelse return;
        for (rec.failed_checks) |c| {
            if (!std.mem.eql(u8, c, wanted)) continue;
            self.runs += 1;
            self.recent.push(rec);
            return;
        }
    }
};

/// Everything one streaming pass over the sink accumulates.
const Stats = struct {
    counts: Counts = .{},
    durations: Window = .{},
    checks: Tallies = .{},
    streaks: Streaks = .{},
    recent_red: RedRing = .{},
    filter: CheckView = .{},

    /// Folds one decoded record in.
    fn observe(self: *Stats, arena: Allocator, rec: dora.RunRecord) Allocator.Error!void {
        self.counts.total += 1;
        self.durations.push(rec.duration_ms);
        self.filter.observe(rec);
        if (rec.outcome == .green) {
            self.counts.green += 1;
            self.streaks.green();
            return;
        }
        self.counts.red += 1;
        self.streaks.red(rec);
        self.recent_red.push(rec);
        for (rec.failed_checks) |name| try self.checks.bump(arena, name);
    }
};

/// Why a scan produced no statistics, or that it produced some.
const ScanResult = enum { ok, missing, unreadable };

/// Entry point: stream the sink, then render. Never gates; the only failure is
/// a sink that exists but cannot be read, which is reported as a command error
/// rather than silently reported as an empty history.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const path = try dora.resolvePath(ctx.allocator, ctx.project_dir, ctx.cfg.dora.sink_path);
    const stats = try ctx.allocator.create(Stats);
    stats.* = .{ .filter = .{ .name = ctx.check_filter } };
    switch (try scan(ctx.allocator, path, stats)) {
        .missing => return reportMissing(ctx, path),
        .unreadable => {
            reporter.fail("history: cannot read the run log {s}", .{path});
            return error.CheckFailed;
        },
        .ok => {},
    }
    if (ctx.json) return writeJson(ctx, path, stats);
    try printReport(ctx, path, stats);
}

/// Reports an absent sink as the ordinary state it is: a project that has not
/// run a gate yet, or one with the sink switched off.
fn reportMissing(ctx: *types.RunCtx, path: []const u8) types.RunError!void {
    if (ctx.json) {
        var empty: Stats = .{};
        return writeJson(ctx, path, &empty);
    }
    reporter.ok("history: no runs recorded yet ({s} does not exist)", .{path});
    if (!ctx.cfg.dora.enabled) print("  the [dora] sink is disabled, so no run will be recorded\n", .{});
}

/// Streams `path` one line at a time, folding every run record into `stats`.
/// The line buffer and the per-line parse arena are both reused, so the whole
/// scan costs the same memory whatever the file's length.
fn scan(arena: Allocator, path: []const u8, stats: *Stats) types.RunError!ScanResult {
    const file = fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return .missing,
        else => return .unreadable,
    };
    defer file.close();
    var reader = file.reader(try arena.alloc(u8, max_line_bytes));
    var line_arena = std.heap.ArenaAllocator.init(arena);
    defer line_arena.deinit();
    while (true) {
        const line = (reader.interface.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                stats.counts.skipped += 1;
                _ = reader.interface.discardDelimiterInclusive('\n') catch return .ok;
                continue;
            },
            else => return .unreadable,
        }) orelse return .ok;
        _ = line_arena.reset(.retain_capacity);
        try observeLine(arena, line_arena.allocator(), stats, line);
    }
}

/// Folds one raw line in: a blank line is ignored, an undecodable one is
/// counted as skipped, and a record is handed to `Stats`. `arena` is the
/// long-lived one (tally names outlive the line); `line_arena` holds only the
/// parse and is reset before the next line.
fn observeLine(
    arena: Allocator,
    line_arena: Allocator,
    stats: *Stats,
    line: []const u8,
) Allocator.Error!void {
    if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) return;
    const rec = dora.parseRecord(line_arena, line) orelse {
        stats.counts.skipped += 1;
        return;
    };
    try stats.observe(arena, rec);
}

/// Durations as median and the upper percentile, over the kept window.
const Spread = struct {
    window: usize = 0,
    median_ms: u64 = 0,
    p90_ms: u64 = 0,
};

/// Sorted-copy percentile helpers over the duration window.
fn spreadOf(arena: Allocator, window: *const Window) Allocator.Error!Spread {
    const scratch = try arena.alloc(u64, @min(window.count, window.samples.len));
    const kept = window.chronological(scratch);
    if (kept.len == 0) return .{};
    std.mem.sort(u64, kept, {}, std.sort.asc(u64));
    return .{
        .window = kept.len,
        .median_ms = percentile(kept, percent_scale / 2),
        .p90_ms = percentile(kept, upper_percentile),
    };
}

/// The `pct`th percentile of an ascending slice (nearest-rank).
fn percentile(sorted: []const u64, pct: usize) u64 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * pct) / percent_scale;
    return sorted[@min(rank, sorted.len - 1)];
}

/// The median of an ascending copy of `values`; 0 for an empty slice.
fn medianOf(arena: Allocator, values: []const u64) Allocator.Error!u64 {
    if (values.len == 0) return 0;
    const copy = try arena.dupe(u64, values);
    std.mem.sort(u64, copy, {}, std.sort.asc(u64));
    return percentile(copy, percent_scale / 2);
}

/// The recent-vs-prior duration comparison.
const Trend = struct {
    recent_runs: usize = 0,
    recent_median_ms: u64 = 0,
    prior_runs: usize = 0,
    prior_median_ms: u64 = 0,
};

/// Splits the window into its newest `trend_recent_runs` and the
/// `trend_prior_runs` before them, and medians each side.
fn trendOf(arena: Allocator, window: *const Window) Allocator.Error!Trend {
    const scratch = try arena.alloc(u64, @min(window.count, window.samples.len));
    const kept = window.chronological(scratch);
    if (kept.len < trend_recent_runs * 2) return .{};
    const split = kept.len - trend_recent_runs;
    const prior_start = if (split > trend_prior_runs) split - trend_prior_runs else 0;
    const recent = kept[split..];
    const prior = kept[prior_start..split];
    return .{
        .recent_runs = recent.len,
        .recent_median_ms = try medianOf(arena, recent),
        .prior_runs = prior.len,
        .prior_median_ms = try medianOf(arena, prior),
    };
}

/// Percentage of `total` that `part` is; 0 when nothing was measured.
fn ratePct(part: usize, total: usize) f64 {
    if (total == 0) return 0;
    const scale: f64 = @floatFromInt(percent_scale);
    return @as(f64, @floatFromInt(part)) * scale / @as(f64, @floatFromInt(total));
}

// ── Human report ───────────────────────────────────────────────────────

/// Prints the whole report, or the single-check view when `--check` names one.
fn printReport(ctx: *types.RunCtx, path: []const u8, stats: *const Stats) types.RunError!void {
    const a = ctx.allocator;
    const c = stats.counts;
    reporter.ok("history: {d} run(s) recorded in {s}", .{ c.total, path });
    if (c.total == 0) {
        print("  the log holds no run records yet\n", .{});
        return reportSkipped(c.skipped);
    }
    print("  outcome    {d} green / {d} red — {d:.1}% pass rate\n", .{ c.green, c.red, ratePct(c.green, c.total) });
    printStreaks(&stats.streaks);
    try printDurations(a, &stats.durations);
    try printLeaderboard(a, &stats.checks);
    printRecentRed(&stats.recent_red);
    if (stats.filter.name) |name| printCheckView(&stats.filter, name, c.total);
    reportSkipped(c.skipped);
}

/// Notes undecodable lines, and stays silent when there were none.
fn reportSkipped(skipped: usize) void {
    if (skipped == 0) return;
    print("  note       {d} line(s) were not decodable run records and were skipped\n", .{skipped});
}

fn printStreaks(streaks: *const Streaks) void {
    if (streaks.current.len == 0) {
        print("  streak     current: none — the last run was green\n", .{});
    } else {
        print("  streak     current: {d} red — failing {s}\n", .{
            streaks.current.len,
            streaks.current.checks.slice(),
        });
    }
    if (streaks.longest.len == 0) return;
    print("             longest: {d} red — last failing {s}\n", .{
        streaks.longest.len,
        streaks.longest.checks.slice(),
    });
}

fn printDurations(a: Allocator, window: *const Window) Allocator.Error!void {
    const spread = try spreadOf(a, window);
    if (spread.window == 0) return;
    print("  duration   median {d} ms · p{d} {d} ms (last {d} run(s))\n", .{
        spread.median_ms,
        upper_percentile,
        spread.p90_ms,
        spread.window,
    });
    const trend = try trendOf(a, window);
    if (trend.recent_runs == 0) return;
    print("  trend      last {d}: {d} ms · prior {d}: {d} ms{s}\n", .{
        trend.recent_runs,
        trend.recent_median_ms,
        trend.prior_runs,
        trend.prior_median_ms,
        trendNote(trend),
    });
}

/// The " — N% slower/faster" tail of the trend line, empty when the prior side
/// measured zero (nothing to compare against).
fn trendNote(trend: Trend) []const u8 {
    if (trend.prior_median_ms == 0) return "";
    if (trend.recent_median_ms > trend.prior_median_ms) return " — slower than before";
    if (trend.recent_median_ms < trend.prior_median_ms) return " — faster than before";
    return " — unchanged";
}

fn printLeaderboard(a: Allocator, checks: *const Tallies) Allocator.Error!void {
    const ranked = try checks.ranked(a);
    if (ranked.len == 0) return;
    print("  failures   check                     runs\n", .{});
    for (ranked[0..@min(ranked.len, leaderboard_rows)]) |row| {
        print("             {s: <24} {d}\n", .{ row.check, row.failures });
    }
    if (ranked.len > leaderboard_rows)
        print("             (+{d} more check(s) have failed at least once)\n", .{ranked.len - leaderboard_rows});
    if (checks.overflow > 0)
        print("             ({d} failure(s) beyond the {d} tracked names)\n", .{ checks.overflow, max_tracked_checks });
}

fn printRecentRed(ring: *const RedRing) void {
    var scratch: [red_samples]RedRun = undefined;
    const runs = ring.newestFirst(&scratch);
    if (runs.len == 0) return;
    print("  last red   commit    branch            checks\n", .{});
    for (runs) |red| {
        print("             {s: <9} {s: <17} {s}\n", .{
            shortSha(red.commit.slice()),
            red.branch.slice(),
            red.checks.slice(),
        });
    }
}

fn printCheckView(view: *const CheckView, name: []const u8, total: usize) void {
    print("  check      '{s}' failed {d} of {d} run(s) — {d:.1}%\n", .{
        name,
        view.runs,
        total,
        ratePct(view.runs, total),
    });
    // A never-failing check and a mistyped name print the same 0, so say which
    // question was asked. The name is deliberately NOT validated against the
    // registry: a log records checks that have since been renamed or retired,
    // and those are exactly the ones worth asking about.
    if (view.runs == 0)
        print("             no run in this log recorded it as failing — verify the spelling\n", .{});
    var scratch: [red_samples]RedRun = undefined;
    for (view.recent.newestFirst(&scratch)) |red| {
        print("             {s: <9} {s: <17} {s}\n", .{
            shortSha(red.commit.slice()),
            red.branch.slice(),
            red.checks.slice(),
        });
    }
}

/// The leading `short_sha_len` characters of a commit hash.
fn shortSha(sha: []const u8) []const u8 {
    return sha[0..@min(sha.len, short_sha_len)];
}

// ── Machine-readable report ────────────────────────────────────────────

/// `runs` object of the JSON report.
const RunsJson = struct {
    total: usize,
    green: usize,
    red: usize,
    pass_rate_pct: f64,
    skipped_lines: usize,
};

/// `streaks` object of the JSON report.
const StreaksJson = struct {
    current_red: usize,
    current_checks: []const u8,
    longest_red: usize,
    longest_checks: []const u8,
};

/// `durations` object of the JSON report; every figure is milliseconds over the
/// `window` most recent runs.
const DurationsJson = struct {
    window: usize,
    median_ms: u64,
    p90_ms: u64,
    trend: Trend,
};

/// One remembered red run in the JSON report.
const RedJson = struct {
    commit: []const u8,
    branch: []const u8,
    checks: []const []const u8,
};

/// The `--check` view in the JSON report.
const CheckJson = struct {
    name: []const u8,
    failed_runs: usize,
    failure_rate_pct: f64,
    recent: []const RedJson,
};

/// The whole report, as one JSON object.
const JsonReport = struct {
    path: []const u8,
    runs: RunsJson,
    streaks: StreaksJson,
    durations: DurationsJson,
    top_failures: []const Tally,
    recent_red: []const RedJson,
    check: ?CheckJson,
};

/// Renders the report to stdout as one JSON object. Stdout, not the reporter's
/// stderr: a caller that pipes `--json` must receive the document.
fn writeJson(ctx: *types.RunCtx, path: []const u8, stats: *const Stats) types.RunError!void {
    const a = ctx.allocator;
    const report = try buildJson(a, path, stats);
    const text = try std.json.Stringify.valueAlloc(a, report, .{});
    var buf: [max_line_bytes]u8 = undefined;
    var out = fs.File.stdout().writer(&buf);
    try out.interface.print("{s}\n", .{text});
    try out.interface.flush();
}

/// Assembles the JSON value from the accumulated statistics.
fn buildJson(a: Allocator, path: []const u8, stats: *const Stats) Allocator.Error!JsonReport {
    const spread = try spreadOf(a, &stats.durations);
    const c = stats.counts;
    return .{
        .path = path,
        .runs = .{
            .total = c.total,
            .green = c.green,
            .red = c.red,
            .pass_rate_pct = ratePct(c.green, c.total),
            .skipped_lines = c.skipped,
        },
        .streaks = .{
            .current_red = stats.streaks.current.len,
            .current_checks = stats.streaks.current.checks.slice(),
            .longest_red = stats.streaks.longest.len,
            .longest_checks = stats.streaks.longest.checks.slice(),
        },
        .durations = .{
            .window = spread.window,
            .median_ms = spread.median_ms,
            .p90_ms = spread.p90_ms,
            .trend = try trendOf(a, &stats.durations),
        },
        .top_failures = try stats.checks.ranked(a),
        .recent_red = try redJson(a, &stats.recent_red),
        .check = try checkJson(a, &stats.filter, c.total),
    };
}

/// The remembered red runs as JSON records, most recent first.
fn redJson(a: Allocator, ring: *const RedRing) Allocator.Error![]const RedJson {
    var scratch: [red_samples]RedRun = undefined;
    const runs = ring.newestFirst(&scratch);
    const out = try a.alloc(RedJson, runs.len);
    for (out, runs) |*row, red| row.* = .{
        .commit = try a.dupe(u8, red.commit.slice()),
        .branch = try a.dupe(u8, red.branch.slice()),
        .checks = try splitChecks(a, red.checks.slice()),
    };
    return out;
}

/// The `--check` view as JSON, or null when no filter was active.
fn checkJson(a: Allocator, view: *const CheckView, total: usize) Allocator.Error!?CheckJson {
    const name = view.name orelse return null;
    return .{
        .name = name,
        .failed_runs = view.runs,
        .failure_rate_pct = ratePct(view.runs, total),
        .recent = try redJson(a, &view.recent),
    };
}

/// Splits a stored ", "-joined check list back into its names.
fn splitChecks(a: Allocator, joined: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, joined, ", ");
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try out.append(a, try a.dupe(u8, name));
    }
    return out.items;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const config_mod = @import("../config.zig");

/// A test project directory holding a synthetic run log, plus the captured
/// reporter and a context pointed at it.
const Fixture = struct {
    arena: Allocator,
    dir: []const u8,
    cap: reporter.Capture,
    cfg: config_mod.Config = .{},
    prior: reporter.Reporter,

    /// Creates `dir` with `log` as its run log (no log at all when null) and
    /// redirects the reporter into the capture.
    fn build(arena: Allocator, dir: []const u8, log: ?[]const u8) !Fixture {
        try resetDir(dir);
        const self: Fixture = .{
            .arena = arena,
            .dir = dir,
            .cap = .{ .allocator = arena },
            .prior = reporter.default,
        };
        try writeLog(arena, dir, self.cfg, log);
        return self;
    }

    fn ctx(self: *Fixture) types.RunCtx {
        reporter.default = .{ .capture = &self.cap };
        return .{ .allocator = self.arena, .project_dir = self.dir, .cfg = &self.cfg, .quiet = true };
    }

    fn output(self: *const Fixture) []const u8 {
        return self.cap.buf.items;
    }

    fn deinit(self: *Fixture) void {
        reporter.default = self.prior;
        self.cap.deinit();
        fs.cwd().deleteTree(self.dir) catch |e| noteCleanup(e);
    }
};

/// Empties and recreates a fixture directory.
fn resetDir(dir: []const u8) !void {
    fs.cwd().deleteTree(dir) catch |e| noteCleanup(e);
    try fs.cwd().makePath(dir);
}

/// Writes `log` as the fixture's run log; a null log leaves no file at all.
fn writeLog(arena: Allocator, dir: []const u8, cfg: config_mod.Config, log: ?[]const u8) !void {
    const text = log orelse return;
    const path = try dora.resolvePath(arena, dir, cfg.dora.sink_path);
    try fs.cwd().makePath(std.fs.path.dirname(path).?);
    try fs.cwd().writeFile(.{ .sub_path = path, .data = text });
}

/// A fixture-cleanup failure is not the test's subject, but it is worth seeing.
fn noteCleanup(e: anyerror) void {
    std.log.warn("history fixture cleanup: {s}", .{@errorName(e)});
}

/// Pushes `count` samples of `ms` — a loop a test body may not spell twice.
fn pushSamples(window: *Window, count: usize, ms: u64) void {
    for (0..count) |_| window.push(ms);
}

/// Counts `times` failures of `name`, for the same reason as `pushSamples`.
fn bumpTimes(tallies: *Tallies, arena: Allocator, name: []const u8, times: usize) !void {
    for (0..times) |_| try tallies.bump(arena, name);
}

/// One synthetic record, rendered by the sink's own writer so a fixture can
/// never encode a line the real sink would not have written.
fn record(arena: Allocator, outcome: dora.Outcome, checks: []const []const u8, ms: u64) ![]const u8 {
    return dora.renderRecord(arena, .{
        .branch = "main",
        .commit = "3c81cd90ffee",
        .outcome = outcome,
        .failed_checks = checks,
        .duration_ms = ms,
    });
}

// spec: History - Streams the run log and reports green, red, and the pass rate

test "history counts outcomes over a whole log" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.join(a, "\n", &.{
        try record(a, .green, &.{}, 300),
        try record(a, .red, &.{"spec"}, 400),
        try record(a, .green, &.{}, 350),
        try record(a, .green, &.{}, 380),
        "",
    });
    var fx = try Fixture.build(a, "zig-cache/history-counts", log);
    defer fx.deinit();
    var ctx = fx.ctx();
    try run(&ctx);
    try testing.expect(std.mem.indexOf(u8, fx.output(), "4 run(s) recorded") != null);
    try testing.expect(std.mem.indexOf(u8, fx.output(), "3 green / 1 red — 75.0% pass rate") != null);
}

// spec: History - Reports the current and the longest red streak with what failed

test "history separates the open red streak from the worst one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.join(a, "\n", &.{
        try record(a, .red, &.{"spec"}, 300),
        try record(a, .red, &.{ "spec", "file-size" }, 300),
        try record(a, .red, &.{"spec"}, 300),
        try record(a, .green, &.{}, 300),
        try record(a, .red, &.{"line-length"}, 300),
        "",
    });
    var fx = try Fixture.build(a, "zig-cache/history-streaks", log);
    defer fx.deinit();
    var ctx = fx.ctx();
    try run(&ctx);
    // The open streak is the trailing one, not the longest.
    try testing.expect(std.mem.indexOf(u8, fx.output(), "current: 1 red — failing line-length") != null);
    try testing.expect(std.mem.indexOf(u8, fx.output(), "longest: 3 red") != null);
}

// spec: History - Reports duration median and upper percentile over the recent window

test "spreadOf medians the window and reports its size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var window: Window = .{};
    for ([_]u64{ 10, 20, 30, 40, 100 }) |ms| window.push(ms);
    const spread = try spreadOf(a, &window);
    try testing.expectEqual(@as(usize, 5), spread.window);
    try testing.expectEqual(@as(u64, 30), spread.median_ms);
    try testing.expectEqual(@as(u64, 100), spread.p90_ms);
    // An empty window measures nothing rather than reporting a zero median.
    var fresh: Window = .{};
    try testing.expectEqual(@as(usize, 0), (try spreadOf(a, &fresh)).window);
}

// spec: History - Bounds the duration window so an unbounded log costs bounded memory

test "the duration window keeps only the newest samples in order" {
    var window: Window = .{};
    for (0..duration_window + 3) |i| window.push(@intCast(i));
    var scratch: [duration_window]u64 = @splat(0);
    const kept = window.chronological(&scratch);
    try testing.expectEqual(@as(usize, duration_window), kept.len);
    // The three oldest fell off the front; the newest is still last.
    try testing.expectEqual(@as(u64, 3), kept[0]);
    try testing.expectEqual(@as(u64, duration_window + 2), kept[kept.len - 1]);
}

// spec: History - Compares the newest runs' duration against the runs before them

test "trendOf splits the window into a recent and a prior side" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var window: Window = .{};
    pushSamples(&window, trend_prior_runs, 100);
    pushSamples(&window, trend_recent_runs, 200);
    const trend = try trendOf(a, &window);
    try testing.expectEqual(@as(usize, trend_recent_runs), trend.recent_runs);
    try testing.expectEqual(@as(u64, 200), trend.recent_median_ms);
    try testing.expectEqual(@as(u64, 100), trend.prior_median_ms);
    try testing.expectEqualStrings(" — slower than before", trendNote(trend));
    // Too few runs to compare is reported as no trend at all.
    var thin: Window = .{};
    thin.push(100);
    try testing.expectEqual(@as(usize, 0), (try trendOf(a, &thin)).recent_runs);
}

// spec: History - Ranks the checks that fail most often

test "the leaderboard orders checks by failure count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tallies: Tallies = .{};
    try bumpTimes(&tallies, a, "spec", 3);
    try tallies.bump(a, "file-size");
    try bumpTimes(&tallies, a, "line-length", 2);
    const ranked = try tallies.ranked(a);
    try testing.expectEqualStrings("spec", ranked[0].check);
    try testing.expectEqual(@as(usize, 3), ranked[0].failures);
    try testing.expectEqualStrings("line-length", ranked[1].check);
    try testing.expectEqualStrings("file-size", ranked[2].check);
}

// spec: History - Counts failures beyond the tracked names as overflow

test "the leaderboard stops growing at its tracked-name cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tallies: Tallies = .{};
    for (0..max_tracked_checks + 5) |i| {
        try tallies.bump(a, try std.fmt.allocPrint(a, "check-{d}", .{i}));
    }
    try testing.expectEqual(@as(usize, max_tracked_checks), tallies.len);
    try testing.expectEqual(@as(usize, 5), tallies.overflow);
}

// spec: History - Lists the most recent red runs with their commit, branch, and checks

test "history shows the newest red runs first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ring: RedRing = .{};
    for (0..red_samples + 2) |i| {
        var checks: [1][]const u8 = .{try std.fmt.allocPrint(a, "check-{d}", .{i})};
        ring.push(.{ .commit = "abcdef1234", .branch = "main", .outcome = .red, .failed_checks = &checks });
    }
    var scratch: [red_samples]RedRun = undefined;
    const newest = ring.newestFirst(&scratch);
    try testing.expectEqual(@as(usize, red_samples), newest.len);
    try testing.expectEqualStrings("check-6", newest[0].checks.slice());
    try testing.expectEqualStrings("check-2", newest[newest.len - 1].checks.slice());
    try testing.expectEqualStrings("abcdef12", shortSha(newest[0].commit.slice()));
}

// spec: History - Skips lines that are not run records and reports how many

test "history counts undecodable lines and keeps reporting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.join(a, "\n", &.{
        try record(a, .green, &.{}, 300),
        "{ truncated json",
        "",
        "  ",
        try record(a, .red, &.{"spec"}, 900),
        "",
    });
    var fx = try Fixture.build(a, "zig-cache/history-corrupt", log);
    defer fx.deinit();
    var ctx = fx.ctx();
    try run(&ctx);
    try testing.expect(std.mem.indexOf(u8, fx.output(), "2 run(s) recorded") != null);
    // Only the malformed line counts; blank lines are not corruption.
    try testing.expect(std.mem.indexOf(u8, fx.output(), "1 line(s) were not decodable") != null);
}

// spec: History - Reports an absent run log as no runs recorded rather than an error

test "history is a plain answer when nothing has been recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.build(a, "zig-cache/history-empty", null);
    defer fx.deinit();
    var ctx = fx.ctx();
    try run(&ctx);
    try testing.expect(std.mem.indexOf(u8, fx.output(), "no runs recorded yet") != null);
    // An empty file is a log with no records, and is equally not an error.
    var written = try Fixture.build(a, "zig-cache/history-blank", "");
    defer written.deinit();
    var blank_ctx = written.ctx();
    try run(&blank_ctx);
    try testing.expect(std.mem.indexOf(u8, written.output(), "holds no run records yet") != null);
}

// spec: History - Narrows the report to one named check's failure history

test "history --check reports one check's share of the failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.join(a, "\n", &.{
        try record(a, .red, &.{ "spec", "file-size" }, 300),
        try record(a, .green, &.{}, 300),
        try record(a, .red, &.{"line-length"}, 300),
        try record(a, .red, &.{"spec"}, 300),
        "",
    });
    var fx = try Fixture.build(a, "zig-cache/history-filter", log);
    defer fx.deinit();
    var ctx = fx.ctx();
    ctx.check_filter = "spec";
    try run(&ctx);
    try testing.expect(std.mem.indexOf(u8, fx.output(), "'spec' failed 2 of 4 run(s) — 50.0%") != null);

    // A name no run ever failed says so, rather than printing a bare 0 that a
    // typo and a never-failing check would share.
    var quiet = try Fixture.build(a, "zig-cache/history-filter-miss", log);
    defer quiet.deinit();
    var miss = quiet.ctx();
    miss.check_filter = "no-such-chekc";
    try run(&miss);
    try testing.expect(std.mem.indexOf(u8, quiet.output(), "no run in this log recorded it as failing") != null);
}

// spec: History - Renders the whole report as one JSON object

test "buildJson carries every reported figure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.join(a, "\n", &.{
        try record(a, .green, &.{}, 300),
        try record(a, .red, &.{ "spec", "file-size" }, 500),
        "",
    });
    var fx = try Fixture.build(a, "zig-cache/history-json", log);
    defer fx.deinit();
    var ctx = fx.ctx();
    ctx.check_filter = "spec";
    const stats = try a.create(Stats);
    stats.* = .{ .filter = .{ .name = ctx.check_filter } };
    try testing.expect(try scan(a, try dora.resolvePath(a, fx.dir, fx.cfg.dora.sink_path), stats) == .ok);
    const text = try std.json.Stringify.valueAlloc(a, try buildJson(a, "log.jsonl", stats), .{});
    try testing.expect(std.mem.indexOf(u8, text, "\"total\":2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"red\":1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"pass_rate_pct\":5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"current_red\":1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"check\":\"spec\",\"failures\":1") != null);
    // The remembered checks come back as a list, not the joined display string.
    try testing.expect(std.mem.indexOf(u8, text, "\"checks\":[\"spec\",\"file-size\"]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"name\":\"spec\",\"failed_runs\":1") != null);
}

// spec: History - Reports a run log it cannot read instead of an empty history

test "an unreadable run log fails the command rather than reading as empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.build(a, "zig-cache/history-unreadable", null);
    defer fx.deinit();
    // A directory where the log should be: it exists, and it is not readable
    // as a file — the case that must never be mistaken for "no runs yet".
    const path = try dora.resolvePath(a, fx.dir, fx.cfg.dora.sink_path);
    try fs.cwd().makePath(path);
    var ctx = fx.ctx();
    try testing.expectError(error.CheckFailed, run(&ctx));
    try testing.expect(std.mem.indexOf(u8, fx.output(), "cannot read the run log") != null);
}
