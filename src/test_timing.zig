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
//! Same constraint as the runner itself: this file is compiled into the root
//! module of a consumer's test binary, so `std` only, no Guardian imports.

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
