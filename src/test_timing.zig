//! Everything Guardian's test runner prints after the last test: the run's
//! cost, the caps that guard it, and the one closing verdict line.
//!
//! The runner exists to make a run's honesty visible; this module makes its
//! COST visible the same way. Motivation (eda, 2026-08-10): a consumer suite's
//! run wall grew ~20x inside one week — 382 tests landed, a few of them
//! whole-board solver runs — and nothing in any output could name the tests
//! responsible short of hand-instrumenting the runner. So after the last test
//! the runner prints one `test wall` line and, under it, the slowest tests
//! over a floor, most expensive first. The floor keeps a healthy suite's
//! output unchanged except for the single wall line; `GUARDIAN_TEST_TIMINGS`
//! (read by the runner) lowers the floor and raises the cap for a full look.
//!
//! Reporting alone is passive, so this module also owns the SLOW-TEST GUARD in
//! two tiers. The always-on tier is a WARNING: a test that reaches
//! `slow_warn_ns` gets its own marked line the moment it finishes, so a
//! creeping hog is named on every run instead of only in a table someone has to
//! read. The opt-in tier is a hard cap — `GUARDIAN_TEST_MAX_TEST_SECS` per test
//! and `GUARDIAN_TEST_MAX_WALL_SECS` for the run's total test time — which
//! fails the run.
//!
//! The split is deliberate. Wall time on a shared developer box is not
//! deterministic: measured 2026-08-10, the same suite ran 2x slower while
//! concurrent builds were running. A cap that always applied would therefore
//! red the build for someone else's compile, so the always-on tier only warns
//! and the failing tier is something a project turns on knowingly (in CI, or in
//! its `[gate] test_command`) with a number it picked.
//!
//! A cap is NOT A WATCHDOG. It is measured from a test that FINISHED, so a test
//! that hangs still hangs forever and no cap fires — the caps catch a
//! regression in a test's cost, never a deadlock.
//!
//! Last comes the VERDICT (`Verdict`, `renderVerdict`): one PASS/FAIL line that
//! is the final thing the runner writes on every exit path. It exists because
//! nothing else in a `zig build test` transcript states the answer. Zig's build
//! runner records a run step's child argv as `failed command: …` BEFORE the
//! pass/fail verdict exists and only erases it on the success path, so under a
//! pipe (`| tail`, `| grep`) the pre-verdict line survives into the stream and a
//! GREEN run ends looking failed. Guardian cannot unprint another program's
//! line — fifteen-plus reports from six agents in two days say so — but it can
//! make the last Guardian line say what actually happened.
//!
//! Same constraint as the runner itself: this file is compiled into the root
//! module of a consumer's test binary, so `std` only, no Guardian imports. In
//! particular it reads no clock: the runner measures, this module only decides
//! and renders.

const std = @import("std");

/// Prefix on every runner line, owned here so both files print one spelling.
pub const prefix = "guardian/test: ";

/// One measured test: its fully qualified name and wall nanoseconds.
pub const Slow = struct {
    ns: u64,
    name: []const u8,
};

/// How much slow-test detail a run reports.
pub const Detail = enum { standard, wide };

/// Default reporting floor: a test cheaper than this is noise in a slow-test
/// list, and a suite where every test is cheap prints no list at all.
pub const default_floor_ns: u64 = 50 * std.time.ns_per_ms;
/// Default cap on listed tests — enough to name the hogs, short enough to scan.
pub const default_max_lines: usize = 10;
/// Floor when the verbosity flag asks for detail.
pub const wide_floor_ns: u64 = 1 * std.time.ns_per_ms;
/// Cap when the verbosity flag asks for detail.
pub const wide_max_lines: usize = 100;
/// Upper bound of either cap — the fixed storage a caller reserves.
pub const max_capacity = wide_max_lines;

/// Reporting shape for one run: floor + cap, derived from the env flag.
pub const Limits = struct {
    floor_ns: u64 = default_floor_ns,
    max_lines: usize = default_max_lines,

    /// The default limits, or the wider ones when the flag asks for detail.
    pub fn forDetail(detail: Detail) Limits {
        return switch (detail) {
            .standard => .{},
            .wide => .{ .floor_ns = wide_floor_ns, .max_lines = wide_max_lines },
        };
    }
};

// ── Slow-test guard ────────────────────────────────────────────────────

/// Wall time at which a single test earns its own warning line, streamed the
/// moment it finishes. Always on, and only ever a warning — see the header for
/// why a hard default would be wrong on a shared box.
pub const slow_warn_ns: u64 = 5 * std.time.ns_per_s;

/// Environment variable naming the opt-in per-test cap, in whole seconds.
pub const max_test_env = "GUARDIAN_TEST_MAX_TEST_SECS";
/// Environment variable naming the opt-in whole-run cap, in whole seconds.
pub const max_wall_env = "GUARDIAN_TEST_MAX_WALL_SECS";

/// How many cap offenders the runner names individually. A fixed list because
/// `builtin.test_functions.len` is not comptime-known under `--test-runner`, so
/// no global array can be sized by it; the rest are counted, never dropped
/// silently (see `Over.dropped`).
pub const max_offenders: usize = 16;

/// True when a finished test is slow enough to earn its own warning line.
pub fn isSlow(ns: u64) bool {
    return ns >= slow_warn_ns;
}

/// Parses one cap variable's value into whole seconds. Absent, empty, blank,
/// unparseable, or zero all mean UNSET — the same forgiving spelling every
/// other GUARDIAN_* flag uses, so a typo disables the cap rather than failing
/// the suite for a reason that has nothing to do with the tests.
pub fn parseSeconds(value: ?[]const u8) ?u64 {
    const text = std.mem.trim(u8, value orelse return null, &std.ascii.whitespace);
    if (text.len == 0) return null;
    const secs = std.fmt.parseUnsigned(u64, text, 10) catch return null;
    return if (secs == 0) null else secs;
}

/// The opt-in hard caps for one run, in nanoseconds. Zero means unset, so the
/// default value of this struct is "no cap" and every predicate below is false.
pub const Caps = struct {
    per_test_ns: u64 = 0,
    wall_ns: u64 = 0,

    /// Builds caps from the two parsed environment values.
    pub fn fromSeconds(per_test_s: ?u64, wall_s: ?u64) Caps {
        return .{ .per_test_ns = toNs(per_test_s), .wall_ns = toNs(wall_s) };
    }

    /// True when one test's time broke the per-test cap. An unset cap is never
    /// broken, and a test exactly AT the cap is at it, not over it.
    pub fn overPerTest(self: Caps, ns: u64) bool {
        return self.per_test_ns != 0 and ns > self.per_test_ns;
    }

    /// True when the run's total test time broke the whole-run cap.
    pub fn overWall(self: Caps, total_ns: u64) bool {
        return self.wall_ns != 0 and total_ns > self.wall_ns;
    }
};

/// Seconds to nanoseconds, saturating — an absurd cap clamps to "never broken"
/// instead of wrapping to a tiny one.
fn toNs(secs: ?u64) u64 {
    return (secs orelse return 0) *| @as(u64, std.time.ns_per_s);
}

/// Tests that broke the per-test cap: how many there were in total, and how
/// many of them the fixed offender list could hold.
pub const Over = struct {
    count: usize = 0,
    stored: usize = 0,

    /// Offenders beyond the list's capacity — reported as a tail, so the count
    /// stays truthful even when the names do not fit.
    pub fn dropped(self: Over) usize {
        return self.count - self.stored;
    }
};

/// Records one cap offender: always counted, named while there is room.
pub fn recordOffender(list: []Slow, over: *Over, entry: Slow) void {
    over.count +|= 1;
    if (over.stored >= list.len) return;
    list[over.stored] = entry;
    over.stored += 1;
}

/// Renders the streamed warning for a test that reached the slow floor. Marked
/// distinctly so it reads as a finding among ordinary test output.
pub fn renderSlowWarning(buf: []u8, entry: Slow) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}SLOW  {d}.{d:0>2}s  {s}\n", .{
        prefix,
        entry.ns / std.time.ns_per_s,
        centis(entry.ns),
        entry.name,
    }) catch return w.buffered();
    return w.buffered();
}

/// Renders the per-test cap verdict: how many tests were over, the cap, and the
/// variable that set it. The offenders themselves follow as `renderSlowLine`s.
pub fn renderTestCapFailure(buf: []u8, over: Over, cap_ns: u64) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}FAILED: {d} test(s) over the {d}s per-test cap ({s})", .{
        prefix,
        over.count,
        cap_ns / std.time.ns_per_s,
        max_test_env,
    }) catch return w.buffered();
    if (over.dropped() > 0) {
        w.print(", first {d} shown", .{over.stored}) catch return w.buffered();
    }
    w.writeAll(":\n") catch return w.buffered();
    return w.buffered();
}

/// Renders the whole-run cap verdict: the total test time against its cap.
pub fn renderWallCapFailure(buf: []u8, total_ns: u64, cap_ns: u64) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}FAILED: test wall {d}.{d:0>2}s over the {d}s cap ({s})\n", .{
        prefix,
        total_ns / std.time.ns_per_s,
        centis(total_ns),
        cap_ns / std.time.ns_per_s,
        max_wall_env,
    }) catch return w.buffered();
    return w.buffered();
}

// ── Slow-test reporting ────────────────────────────────────────────────

/// Inserts `entry` into `list` kept sorted descending by ns, holding at most
/// `cap` entries — the cheapest falls off the end when the list is full.
/// `len` is the live length, updated in place. Filtering below-floor entries
/// is the caller's job; this function only orders and truncates.
pub fn insertSlow(list: []Slow, len: *usize, cap: usize, entry: Slow) void {
    const bound = @min(cap, list.len);
    if (bound == 0) return;
    var pos: usize = len.*;
    for (list[0..len.*], 0..) |held, i| {
        if (entry.ns > held.ns) {
            pos = i;
            break;
        }
    }
    if (pos >= bound) return;
    const new_len = @min(len.* + 1, bound);
    var i: usize = new_len - 1;
    while (i > pos) : (i -= 1) list[i] = list[i - 1];
    list[pos] = entry;
    len.* = new_len;
}

/// Renders the closing wall line into `buf`: the run's total test time, plus
/// the slowest-list header when anything cleared the floor. A line that
/// overflows `buf` is truncated rather than dropped — a diagnostic should
/// degrade, never disappear.
pub fn renderWall(buf: []u8, total_ns: u64, slow_count: usize, floor_ns: u64) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}test wall {d}.{d:0>2}s", .{
        prefix,
        total_ns / std.time.ns_per_s,
        centis(total_ns),
    }) catch return w.buffered();
    if (slow_count == 0) {
        w.writeByte('\n') catch return w.buffered();
        return w.buffered();
    }
    w.print("; slowest over {d}ms:\n", .{floor_ns / std.time.ns_per_ms}) catch return w.buffered();
    return w.buffered();
}

/// Renders one slow-test line into `buf`, seconds first so the column scans.
/// Overflow truncates, as in `renderWall`.
pub fn renderSlowLine(buf: []u8, entry: Slow) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}  {d}.{d:0>2}s  {s}\n", .{
        prefix,
        entry.ns / std.time.ns_per_s,
        centis(entry.ns),
        entry.name,
    }) catch return w.buffered();
    return w.buffered();
}

// ── Run verdict ────────────────────────────────────────────────────────

/// What one finished test reported — the same three outcomes the build
/// system's test protocol carries, so both of the runner's modes fold their
/// results in through one shape.
pub const Status = enum { pass, skip, fail };

/// What a whole run produced. `leak` counts the TESTS that leaked rather than
/// the allocations they leaked (matching the terminal summary's wording), and
/// `log_err` is the run's total logged-error count, because a test that only
/// logged an error still fails.
pub const Tally = struct {
    ok: usize = 0,
    skip: usize = 0,
    fail: usize = 0,
    leak: usize = 0,
    log_err: usize = 0,

    /// Folds one finished test's status in. Saturating: a counter that wrapped
    /// could turn a red run green, which is the one bug this file exists to
    /// prevent.
    pub fn record(self: *Tally, status: Status) void {
        switch (status) {
            .pass => self.ok +|= 1,
            .skip => self.skip +|= 1,
            .fail => self.fail +|= 1,
        }
    }

    /// Tests that reported a result, whatever it was.
    pub fn total(self: Tally) usize {
        return self.ok +| self.skip +| self.fail;
    }

    /// True when the tests themselves were not all clean — the same three
    /// conditions the stock runner exits nonzero on.
    pub fn failed(self: Tally) bool {
        return self.fail != 0 or self.leak != 0 or self.log_err != 0;
    }
};

/// A run's closing verdict: what ran, whether an opt-in time cap broke, and —
/// when the run ended before its suite finished — the reason that replaces the
/// counts. One value, so the line the reader sees and the status the runner
/// exits with are read off the same thing and cannot disagree.
pub const Verdict = struct {
    tally: Tally = .{},
    /// An opt-in time cap was broken: the run fails though every test passed.
    caps_broken: bool = false,
    /// Why the run ended without a finished suite — the zero-match filter
    /// guard, or a runner that aborted. Null for an ordinary run.
    aborted: ?[]const u8 = null,

    /// True when this run must not be reported as green.
    pub fn failed(self: Verdict) bool {
        return self.aborted != null or self.caps_broken or self.tally.failed();
    }
};

/// Renders the two lines every run ends with, whichever way it ended: the
/// human verdict line, then the machine-readable RESULT line. Overflow
/// truncates rather than dropping a line, as everywhere else here: a verdict
/// that disappeared would be worse than a short one.
pub fn renderVerdict(buf: []u8, verdict: Verdict) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeVerdictLine(&w, verdict) catch return w.buffered();
    writeResultLine(&w, verdict) catch return w.buffered();
    return w.buffered();
}

/// The verdict's wording. An aborted run states its reason instead of counts,
/// which would read as a meaningless `0 failed of 0`; a failing run names every
/// reason it failed, since a leak or a logged error can red a run in which no
/// test failed at all.
fn writeVerdictLine(w: *std.Io.Writer, verdict: Verdict) std.Io.Writer.Error!void {
    const tally = verdict.tally;
    if (verdict.aborted) |reason| return w.print("{s}FAIL — {s}\n", .{ prefix, reason });
    if (!verdict.failed()) {
        try w.print("{s}PASS — {d} passed", .{ prefix, tally.ok });
        if (tally.skip != 0) try w.print(", {d} skipped", .{tally.skip});
        return w.writeByte('\n');
    }
    try w.print("{s}FAIL — {d} failed of {d}", .{ prefix, tally.fail, tally.total() });
    if (tally.leak != 0) try w.print(", {d} leaked", .{tally.leak});
    if (tally.log_err != 0) try w.print(", {d} error(s) logged", .{tally.log_err});
    if (verdict.caps_broken) try w.writeAll(", over an opt-in time cap");
    try w.writeByte('\n');
}

/// The machine-readable result line printed after the verdict: one stable,
/// grep-able line carrying the tally, so a multi-shard run's totals can be
/// summed by a script instead of re-parsed from prose. Same `guardian/test:`
/// prefix as the verdict, so one grep finds both; the JSON object is
/// hand-assembled (only integers, so no escaping) and deliberately minimal:
/// passed/failed/skipped are the fields a shard total needs, and `aborted`
/// marks a run that ended before its suite finished. A consumer sums these
/// lines across shards; `commit` already does (see cli/commit.zig).
fn writeResultLine(w: *std.Io.Writer, verdict: Verdict) std.Io.Writer.Error!void {
    const tally = verdict.tally;
    try w.print("{s}RESULT {{\"passed\":{d},\"failed\":{d},\"skipped\":{d}", .{
        prefix, tally.ok, tally.fail, tally.skip,
    });
    if (verdict.aborted != null) try w.writeAll(",\"aborted\":true");
    try w.writeAll("}\n");
}

/// Hundredths of a second below the whole seconds already printed.
fn centis(ns: u64) u64 {
    return (ns % std.time.ns_per_s) / (std.time.ns_per_s / 100);
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// Collected via the unnamed reference block at the bottom of test_runner.zig,
// which is its own test root (see the note there).

const testing = std.testing;

// spec: Test Runner - Reports the run's total test wall time after the last test

test "the wall line states the run's total test time" {
    var buf: [128]u8 = undefined;
    const line = renderWall(&buf, 3 * std.time.ns_per_s + 500 * std.time.ns_per_ms, 0, default_floor_ns);
    try testing.expectEqualStrings("guardian/test: test wall 3.50s\n", line);
}

// spec: Test Runner - Lists the slowest tests over the reporting floor, most expensive first

test "slow tests are ordered most expensive first and capped" {
    var list: [3]Slow = undefined;
    var len: usize = 0;
    insertSlow(&list, &len, 3, .{ .ns = 200, .name = "b" });
    insertSlow(&list, &len, 3, .{ .ns = 900, .name = "a" });
    insertSlow(&list, &len, 3, .{ .ns = 50, .name = "d" });
    insertSlow(&list, &len, 3, .{ .ns = 400, .name = "c" });
    // Capacity 3: the cheapest ("d") fell off; order is descending.
    try testing.expectEqual(@as(usize, 3), len);
    try testing.expectEqualStrings("a", list[0].name);
    try testing.expectEqualStrings("c", list[1].name);
    try testing.expectEqualStrings("b", list[2].name);

    // The header names the floor, and a line renders seconds then the name.
    var head: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "guardian/test: test wall 12.00s; slowest over 50ms:\n",
        renderWall(&head, 12 * std.time.ns_per_s, len, default_floor_ns),
    );
    var line: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "guardian/test:   12.31s  router.test.full board\n",
        renderSlowLine(&line, .{
            .ns = 12 * std.time.ns_per_s + 310 * std.time.ns_per_ms,
            .name = "router.test.full board",
        }),
    );
}

// spec: Test Runner - Raises the slow-test detail cap when the timing verbosity flag is set

test "the verbosity flag lowers the floor and raises the cap" {
    const quiet = Limits.forDetail(.standard);
    try testing.expectEqual(default_floor_ns, quiet.floor_ns);
    try testing.expectEqual(default_max_lines, quiet.max_lines);

    const loud = Limits.forDetail(.wide);
    try testing.expectEqual(wide_floor_ns, loud.floor_ns);
    try testing.expectEqual(wide_max_lines, loud.max_lines);
    try testing.expect(loud.max_lines <= max_capacity);
}

// spec: Test Runner - Warns on its own marked line as soon as a test reaches the slow floor

test "a test at the slow floor renders its own SLOW warning" {
    // The floor is reached, not merely exceeded — a test sitting exactly on it
    // is already the kind of hog this warns about.
    try testing.expect(isSlow(slow_warn_ns));
    try testing.expect(isSlow(slow_warn_ns + 1));
    try testing.expect(!isSlow(slow_warn_ns - 1));

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "guardian/test: SLOW  7.31s  router.test.full board\n",
        renderSlowWarning(&buf, .{
            .ns = 7 * std.time.ns_per_s + 310 * std.time.ns_per_ms,
            .name = "router.test.full board",
        }),
    );
}

// spec: Test Runner - Fails the run after every test has finished when one exceeded the opt-in per-test cap

test "the per-test cap names its offenders and counts the ones that do not fit" {
    const caps = Caps.fromSeconds(2, null);
    try testing.expect(caps.overPerTest(3 * std.time.ns_per_s));
    // At the cap is not over it, and the unset wall cap stays unset.
    try testing.expect(!caps.overPerTest(2 * std.time.ns_per_s));
    try testing.expect(!caps.overWall(std.math.maxInt(u64)));

    // The offender list is fixed-capacity; everything past it is still counted.
    var list: [2]Slow = undefined;
    var over: Over = .{};
    recordOffender(&list, &over, .{ .ns = 9 * std.time.ns_per_s, .name = "a" });
    recordOffender(&list, &over, .{ .ns = 8 * std.time.ns_per_s, .name = "b" });
    recordOffender(&list, &over, .{ .ns = 7 * std.time.ns_per_s, .name = "c" });
    try testing.expectEqual(@as(usize, 3), over.count);
    try testing.expectEqual(@as(usize, 2), over.stored);
    try testing.expectEqual(@as(usize, 1), over.dropped());
    try testing.expectEqualStrings("a", list[0].name);

    var head: [160]u8 = undefined;
    try testing.expectEqualStrings(
        "guardian/test: FAILED: 3 test(s) over the 2s per-test cap (GUARDIAN_TEST_MAX_TEST_SECS), first 2 shown:\n",
        renderTestCapFailure(&head, over, caps.per_test_ns),
    );
    // Nothing truncated: no "first N shown" clause.
    try testing.expectEqualStrings(
        "guardian/test: FAILED: 1 test(s) over the 2s per-test cap (GUARDIAN_TEST_MAX_TEST_SECS):\n",
        renderTestCapFailure(&head, .{ .count = 1, .stored = 1 }, caps.per_test_ns),
    );
    try testing.expect(max_offenders > 0);
}

// spec: Test Runner - Fails the run when the total test time exceeds the opt-in wall cap

test "the wall cap failure states the run's total against the cap" {
    const caps = Caps.fromSeconds(null, 120);
    try testing.expect(caps.overWall(121 * std.time.ns_per_s));
    try testing.expect(!caps.overWall(120 * std.time.ns_per_s));
    // Only the wall cap is set, so no per-test time can break the other one.
    try testing.expect(!caps.overPerTest(std.math.maxInt(u64)));

    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings(
        "guardian/test: FAILED: test wall 130.40s over the 120s cap (GUARDIAN_TEST_MAX_WALL_SECS)\n",
        renderWallCapFailure(&buf, 130 * std.time.ns_per_s + 400 * std.time.ns_per_ms, caps.wall_ns),
    );
}

// spec: Test Runner - Leaves both caps disabled when their variables are absent, empty, or zero

test "an absent, blank, zero or unparseable cap variable is no cap at all" {
    try testing.expectEqual(@as(?u64, null), parseSeconds(null));
    try testing.expectEqual(@as(?u64, null), parseSeconds(""));
    try testing.expectEqual(@as(?u64, null), parseSeconds("   "));
    try testing.expectEqual(@as(?u64, null), parseSeconds("0"));
    try testing.expectEqual(@as(?u64, null), parseSeconds("later"));
    try testing.expectEqual(@as(?u64, null), parseSeconds("-5"));
    try testing.expectEqual(@as(?u64, 120), parseSeconds(" 120 "));

    // Which is what the default Caps means: nothing can break an unset cap.
    const none: Caps = .{};
    try testing.expectEqual(none, Caps.fromSeconds(parseSeconds(null), parseSeconds("0")));
    try testing.expect(!none.overPerTest(std.math.maxInt(u64)));
    try testing.expect(!none.overWall(std.math.maxInt(u64)));

    // A cap so large it would overflow nanoseconds saturates rather than wrapping.
    const huge = Caps.fromSeconds(std.math.maxInt(u64), null);
    try testing.expect(!huge.overPerTest(std.math.maxInt(u64) - 1));
}

// spec: Test Runner Verdict - Ends a green run with a PASS line stating the passed count, and the skipped count when any were skipped
// spec: Test Runner Verdict - Prints a machine-readable result line after the verdict, carrying the passed failed and skipped counts

test "the green verdict states the passed count and any skips" {
    var tally: Tally = .{};
    for (0..3) |_| tally.record(.pass);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "guardian/test: PASS — 3 passed\n" ++
            "guardian/test: RESULT {\"passed\":3,\"failed\":0,\"skipped\":0}\n",
        renderVerdict(&buf, .{ .tally = tally }),
    );

    // A skip is not a failure, but a green line that hid them would overstate
    // what the run proved.
    tally.record(.skip);
    tally.record(.skip);
    try testing.expectEqual(@as(usize, 5), tally.total());
    try testing.expectEqualStrings(
        "guardian/test: PASS — 3 passed, 2 skipped\n" ++
            "guardian/test: RESULT {\"passed\":3,\"failed\":0,\"skipped\":2}\n",
        renderVerdict(&buf, .{ .tally = tally }),
    );
}

// spec: Test Runner Verdict - Ends a failing run with a FAIL line stating how many tests failed of how many ran

test "the failing verdict states the failures against the total" {
    var tally: Tally = .{};
    for (0..7) |_| tally.record(.pass);
    tally.record(.fail);
    tally.record(.fail);
    var buf: [128]u8 = undefined;
    try testing.expect(tally.failed());
    try testing.expectEqualStrings(
        "guardian/test: FAIL — 2 failed of 9\n" ++
            "guardian/test: RESULT {\"passed\":7,\"failed\":2,\"skipped\":0}\n",
        renderVerdict(&buf, .{ .tally = tally }),
    );
}

// spec: Test Runner Verdict - Adds a leak count, a logged-error count, or a broken time cap to the failing verdict

test "leaks, logged errors and a broken cap each red an otherwise-passing run" {
    var buf: [160]u8 = undefined;
    // Every test passed in all three cases: without the extra clause the line
    // would read `0 failed of 4` and leave the reader guessing why it is FAIL.
    var leaked: Tally = .{ .ok = 4, .leak = 1 };
    try testing.expect(leaked.failed());
    try testing.expectEqualStrings(
        "guardian/test: FAIL — 0 failed of 4, 1 leaked\n" ++
            "guardian/test: RESULT {\"passed\":4,\"failed\":0,\"skipped\":0}\n",
        renderVerdict(&buf, .{ .tally = leaked }),
    );
    const logged: Tally = .{ .ok = 4, .log_err = 3 };
    try testing.expectEqualStrings(
        "guardian/test: FAIL — 0 failed of 4, 3 error(s) logged\n" ++
            "guardian/test: RESULT {\"passed\":4,\"failed\":0,\"skipped\":0}\n",
        renderVerdict(&buf, .{ .tally = logged }),
    );
    // A broken cap fails a tally that is itself entirely clean.
    const clean: Tally = .{ .ok = 4 };
    try testing.expect(!clean.failed());
    try testing.expectEqualStrings(
        "guardian/test: FAIL — 0 failed of 4, over an opt-in time cap\n" ++
            "guardian/test: RESULT {\"passed\":4,\"failed\":0,\"skipped\":0}\n",
        renderVerdict(&buf, .{ .tally = clean, .caps_broken = true }),
    );
    // All of them at once, in one line.
    leaked.log_err = 3;
    try testing.expectEqualStrings(
        "guardian/test: FAIL — 0 failed of 4, 1 leaked, 3 error(s) logged, over an opt-in time cap\n" ++
            "guardian/test: RESULT {\"passed\":4,\"failed\":0,\"skipped\":0}\n",
        renderVerdict(&buf, .{ .tally = leaked, .caps_broken = true }),
    );
}

// spec: Test Runner Verdict - States the reason instead of the counts when a run ends before its suite finished

test "an aborted run states its reason in place of counts" {
    var buf: [160]u8 = undefined;
    // The zero-match filter guard exits before a single test runs, so
    // `0 failed of 0` would be true and useless.
    try testing.expectEqualStrings(
        "guardian/test: FAIL — nothing the filter named ran\n" ++
            "guardian/test: RESULT {\"passed\":0,\"failed\":0,\"skipped\":0,\"aborted\":true}\n",
        renderVerdict(&buf, .{ .aborted = "nothing the filter named ran" }),
    );
}

// spec: Test Runner Verdict - Reads the printed verdict and the run's exit status off one predicate

test "the verdict's pass/fail is the single predicate the exit status uses" {
    // Green only when nothing at all went wrong: this is the predicate the
    // runner exits on, so a PASS line can never accompany a nonzero status.
    try testing.expect(!(Verdict{ .tally = .{ .ok = 9, .skip = 2 } }).failed());
    try testing.expect((Verdict{ .tally = .{ .ok = 9, .fail = 1 } }).failed());
    try testing.expect((Verdict{ .tally = .{ .ok = 9, .leak = 1 } }).failed());
    try testing.expect((Verdict{ .tally = .{ .ok = 9, .log_err = 1 } }).failed());
    try testing.expect((Verdict{ .tally = .{ .ok = 9 }, .caps_broken = true }).failed());
    try testing.expect((Verdict{ .aborted = "the runner aborted" }).failed());
    // An empty run is not a failure here: the zero-match guard decides that
    // upstream and hands down an `aborted` reason when it applies.
    try testing.expect(!(Verdict{}).failed());
}
