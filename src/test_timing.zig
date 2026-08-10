//! Per-test wall-time reporting for Guardian's test runner.
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
