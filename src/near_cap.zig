//! The pre-trip alert the two-tier volume checks share: one loud line for an
//! item that has reached 95% of its HARD cap without crossing it yet.
//!
//! Why it exists. A two-tier check warns at its recommended limit and blocks
//! only at a generous hard one, so on a real project the advisory tier is dozens
//! of findings deep (measured on one consumer: 45 file-size warnings, every one
//! report-only). The single file about to cross the *blocking* limit is
//! invisible inside that pile — twice recorded, a file crossed the 10000-line
//! hard cap from ONE line under it, and the crossing landed mid-feature on
//! whichever session happened to add the line. This is the separate channel for
//! that case.
//!
//! Two properties make it un-missable without making it debt. The finding is
//! flagged `alert`, so the run summary replays it even when the check's own
//! output is collapsed to a count by `--summary` or by diff scoping (see
//! `cli/run_view.zig`). And it is a WARNING, so no baseline, ratchet or
//! snapshot ever records it: crossing the cap is what the gate blocks on, and a
//! pre-trip notice must never become something to accept.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Share of the hard cap a measurement must reach to draw the alert. 95% is
/// near enough that one ordinary edit can cross it, and far enough to leave a
/// real runway to act in (500 of 10000 code lines; 20 of 400 function lines).
const alert_pct: u64 = 95;

/// Denominator of `alert_pct`, named so every comparison below reads as a
/// percentage rather than an unexplained literal.
const percent: u64 = 100;

/// The grep-stable opener of every alert line. Uppercase and fixed so an agent
/// can match one token across a collapsed summary and a full replay alike.
const marker = "NEAR HARD CAP";

/// One measurement standing near its hard cap: the value and the cap it is
/// approaching, the unit they are counted in, the remedy the line ends on, and
/// the subject within the file when the file path alone doesn't name it (a
/// function); null for a whole-file metric, whose file is the subject.
pub const Measurement = struct {
    value: u64,
    hard_cap: u64,
    unit: []const u8,
    remedy: []const u8,
    subject: ?[]const u8 = null,
};

/// True when `value` has reached the alert share of `hard_cap` without passing
/// it. A value already over the cap is the check's own blocking finding, not a
/// pre-trip warning, so it draws none — the alert exists for the band where
/// acting is still cheap.
pub fn isNearHardCap(value: u64, hard_cap: u64) bool {
    if (hard_cap == 0 or value > hard_cap) return false;
    return value * percent >= hard_cap * alert_pct;
}

/// The whole-percent share of `limit` that `value` has consumed. Shared with
/// the debt headroom list so "96%" means the same thing in both reports.
pub fn pctOf(value: u64, limit: u64) u64 {
    if (limit == 0) return 0;
    return value * percent / limit;
}

/// The alert line: the marker, the subject when there is one, the value against
/// the cap with the share consumed, and what to do before the crossing lands on
/// someone. Deliberately one line — it has to survive being read in a wall of
/// advisory output.
pub fn alertMessage(arena: Allocator, m: Measurement) Allocator.Error![]const u8 {
    // The subject and its separator are formatted rather than branched so the
    // sentence exists exactly once: two near-identical format strings are how
    // the two shapes of this line would drift apart.
    const subject = m.subject orelse "";
    const gap = if (m.subject == null) "" else "  ";
    return std.fmt.allocPrint(
        arena,
        "{s}  {s}{s}{d} of {d} {s} ({d}%) — crossing blocks the gate; {s}",
        .{ marker, subject, gap, m.value, m.hard_cap, m.unit, pctOf(m.value, m.hard_cap), m.remedy },
    );
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Near Hard Cap - Flags a measurement that has reached 95% of its hard cap without crossing it

test "the alert band opens at 95% of the cap and closes once the cap is crossed" {
    // The eda case: 9983 of 10000 code lines is 17 lines from a blocking
    // crossing, and nothing in the gate said so.
    try testing.expect(isNearHardCap(9983, 10_000));
    try testing.expectEqual(@as(u64, 99), pctOf(9983, 10_000));
    // Exactly on the band edge counts; one line below it does not.
    try testing.expect(isNearHardCap(9500, 10_000));
    try testing.expect(!isNearHardCap(9499, 10_000));
    // Sitting exactly on the cap is still an alert — it is the last moment the
    // warning can be acted on before the gate blocks.
    try testing.expect(isNearHardCap(10_000, 10_000));
    // Over the cap is the check's own blocking finding, not a pre-trip warning.
    try testing.expect(!isNearHardCap(10_001, 10_000));
    // The band is proportional, so the 400-line function cap works the same way.
    try testing.expect(isNearHardCap(381, 400));
    try testing.expect(!isNearHardCap(379, 400));
    // A missing cap can never produce a percentage or an alert (no divide).
    try testing.expect(!isNearHardCap(5, 0));
    try testing.expectEqual(@as(u64, 0), pctOf(5, 0));
}

// spec: Near Hard Cap - Renders one alert line naming the value, the cap, the share, and the remedy

test "alertMessage names the marker, the numbers, the share, and what to do" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A whole-file metric: the violation carries the path, so the line does not
    // repeat it.
    try testing.expectEqualStrings(
        "NEAR HARD CAP  9612 of 10000 code lines (96%) — crossing blocks the gate; " ++
            "split at a cohesive module boundary now",
        try alertMessage(a, .{
            .value = 9612,
            .hard_cap = 10_000,
            .unit = "code lines",
            .remedy = "split at a cohesive module boundary now",
        }),
    );
    // A per-subject metric names the subject inside the file.
    try testing.expectEqualStrings(
        "NEAR HARD CAP  fn route  381 of 400 lines (95%) — crossing blocks the gate; extract a helper now",
        try alertMessage(a, .{
            .value = 381,
            .hard_cap = 400,
            .unit = "lines",
            .remedy = "extract a helper now",
            .subject = "fn route",
        }),
    );
}
