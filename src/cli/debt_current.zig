//! `debt --current` — the current value beside every frozen ratchet ceiling.
//!
//! The plain debt report reads `.guardian/` only: it can say a check has 12
//! ratcheted keys and name the worst one, but not whether any of them still has
//! room. That is the question an agent actually has ("can this file grow?"), and
//! answering it meant running the whole gate and reading a failure. This section
//! measures the tree with the checks' own measurement functions
//! (`file_metrics.zig`) and prints, per ratcheted check, how many keys have
//! headroom, how many sit exactly on their ceiling, and how many are already
//! over — plus a line for each key in the last two groups.
//!
//! It is opt-in because it re-reads and re-parses `src/` and `test/`; a plain
//! metadata-only debt report should not pay for a source walk.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const walk = @import("../walk.zig");
const ratchet = @import("../ratchet.zig");
const file_metrics = @import("../file_metrics.zig");
const config_mod = @import("../config.zig");
const near_cap = @import("../near_cap.zig");
const hysteresis = @import("../hysteresis.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;

/// Source roots the threshold checks scan — the only files with ratchet keys.
const roots = [_][]const u8{ "src", "test" };

/// How many individual keys are listed per check before the tail is summarized.
/// Only zero-headroom and over-ceiling keys are listed at all, so a long list
/// means a genuinely stuck check rather than noise.
const max_detail_rows: usize = 10;

/// How much of its blocking limit an item must have consumed to make the
/// headroom list, as a percentage. 90% keeps the list to what the NEXT edit
/// could realistically cross — the question two consumers asked for after
/// discovering a hard-limit breach only once the feature was already written.
const near_limit_pct: u64 = 90;

/// Denominator of `near_limit_pct`, named so the comparison reads as a
/// percentage rather than an unexplained literal.
const percent: u64 = 100;

/// Which limit would actually block an item: the check's hard cap, or a frozen
/// ratchet ceiling that stops it sooner. Naming it keeps the report from
/// implying a file may grow to the hard cap when its ceiling bites first.
pub const LimitKind = enum { hard_cap, ceiling };

/// One measured item close to — or already past — the limit that would block
/// the gate. Unlike `Row`, this is not about accepted debt: an item with no
/// ratchet at all appears here as soon as it nears its check's hard cap.
pub const HeadroomRow = struct {
    check: []const u8,
    key: []const u8,
    value: u64,
    limit: u64,
    limit_kind: LimitKind,
};

/// A resolved blocking limit: its value and which of the two it is.
const Limit = struct { value: u64, kind: LimitKind };

/// One ratcheted key's standing right now: what the gate froze it at, what it
/// measures today, and which side of the ceiling that puts it on.
pub const Row = struct {
    check: []const u8,
    key: []const u8,
    /// Null when the ratchet names a key the tree no longer contains (a
    /// renamed function, a deleted file) — debt the next green run prunes.
    value: ?u64,
    ceiling: u64,
    standing: file_metrics.Standing,
    /// The recover line when `[hysteresis]` binds this key's check, else null.
    /// Non-null means TRIPPED: the entry only shrinks, it cannot be accepted
    /// upward, and it clears at this number rather than at the hard cap.
    recover: ?u64 = null,
};

/// One check's ratchet at a glance: how its frozen keys are distributed across
/// headroom / no headroom / already over.
pub const Summary = struct {
    check: []const u8,
    ratcheted: usize,
    headroom: usize,
    at_ceiling: usize,
    over: usize,
    /// Keys whose subject no longer exists in the tree.
    stale: usize,
};

/// The measured current-vs-ceiling state of every ratcheted key, plus the
/// items nearest a blocking limit whether or not they carry a ratchet.
pub const Report = struct {
    summaries: []const Summary,
    rows: []const Row,
    headroom: []const HeadroomRow = &.{},
};

/// Walk state: the config to measure with, the key -> current value map being
/// filled, every check's frozen ceilings (read once, so the visitor resolves a
/// binding limit without re-reading a ratchet file per source file), and the
/// near-limit rows collected so far.
const Measurer = struct {
    arena: Allocator,
    cfg: *const config_mod.Config,
    values: *std.StringHashMapUnmanaged(u64),
    ceilings: []const []const ratchet.Entry,
    headroom: *std.ArrayList(HeadroomRow),
};

/// One tree walk's output: current values by measurement key, and the
/// near-limit rows filtered during the walk (so a whole-tree scan holds only
/// what prints).
const TreeScan = struct {
    values: std.StringHashMapUnmanaged(u64),
    headroom: []const HeadroomRow,
};

/// Separator joining a check name to a ratchet key in the measurement map. Two
/// checks share a key SPELLING — `file-size` and `line-length` both key on the
/// file path, `function-length` and `function-size` both on `<file>|<fn>` — so a
/// map keyed on the ratchet key alone folded a function's line count and its
/// parameter count into one entry (the larger winning), and the report then
/// judged parameter ceilings against line counts: on one consumer that read as
/// 116 of 121 function-size keys "OVER by …; the gate blocks" on a green tree.
/// A NUL byte cannot occur in a check name or a ratchet key.
const check_key_sep = "\x00";

/// The map key for one check's measurement of one subject.
fn measurementKey(arena: Allocator, check_name: []const u8, key: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ check_name, check_key_sep, key });
}

/// Measures the tree and pairs every recorded ceiling with its current value.
/// Checks with no ratchet file contribute no ceiling rows, so a project that
/// has never accepted debt gets an empty table rather than a wall of zeroes —
/// but it still gets the headroom list, which needs no accepted debt at all.
pub fn collect(ctx: *types.RunCtx) types.RunError!Report {
    const scan = try measureTree(ctx);
    var summaries: std.ArrayList(Summary) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    for (file_metrics.measured_checks) |check_name| {
        const recorded = try file_metrics.ceilings(ctx.allocator, ctx.project_dir, check_name);
        if (recorded.len == 0) continue;
        try summaries.append(ctx.allocator, try appendCheck(ctx.allocator, &rows, .{
            .check = check_name,
            .recorded = recorded,
            .values = scan.values,
            // A recorded entry of a hysteresis check IS a trip, so the recover
            // line it clears at is what the reader needs beside the ceiling.
            .recover = recoverLineFor(ctx.cfg, check_name),
        }));
    }
    return .{
        .summaries = try summaries.toOwnedSlice(ctx.allocator),
        .rows = try rows.toOwnedSlice(ctx.allocator),
        .headroom = scan.headroom,
    };
}

/// The recover line `[hysteresis]` clears `check_name`'s entries at, or null
/// when the policy does not bind it — the one place this report asks.
fn recoverLineFor(cfg: *const config_mod.Config, check_name: []const u8) ?u64 {
    const policy = hysteresis.policyFor(cfg, check_name) orelse return null;
    return policy.recover;
}

/// One check's ceiling table input: its name, what it has recorded, the
/// measured values, and its recover line when hysteresis binds it.
const CheckRows = struct {
    check: []const u8,
    recorded: []const ratchet.Entry,
    values: std.StringHashMapUnmanaged(u64),
    recover: ?u64,
};

/// Folds one check's recorded ceilings into a summary, appending a row for
/// every key that has no headroom left (at ceiling, over, or stale) — plus
/// every TRIPPED key, headroom or not: a hysteresis entry that is quietly
/// shrinking toward its recover line is exactly what the reader is tracking,
/// and it would otherwise be invisible until it stopped having headroom.
fn appendCheck(arena: Allocator, rows: *std.ArrayList(Row), in: CheckRows) Allocator.Error!Summary {
    var summary: Summary = .{
        .check = in.check,
        .ratcheted = in.recorded.len,
        .headroom = 0,
        .at_ceiling = 0,
        .over = 0,
        .stale = 0,
    };
    for (in.recorded) |entry| {
        const current = in.values.get(try measurementKey(arena, in.check, entry.key));
        const standing = file_metrics.standingOf(current orelse 0, entry.value);
        tally(&summary, current, standing);
        if (in.recover == null and current != null and standing == .headroom) continue;
        try rows.append(arena, .{
            .check = in.check,
            .key = entry.key,
            .value = current,
            .ceiling = entry.value,
            .standing = standing,
            .recover = in.recover,
        });
    }
    return summary;
}

/// Adds one key to its check's tally. A key with no current value is stale —
/// counted apart from headroom so a vanished subject never reads as slack.
fn tally(summary: *Summary, current: ?u64, standing: file_metrics.Standing) void {
    if (current == null) {
        summary.stale += 1;
        return;
    }
    // Counted by equality rather than a switch: file_metrics owns the single
    // dispatch over Standing (see `ceilingPhrase`), and a second one here is
    // exactly the drift that keeps two reports from agreeing. `.none` cannot
    // occur — every key tallied here has a recorded ceiling.
    summary.over += @intFromBool(standing == .over);
    summary.at_ceiling += @intFromBool(standing == .at_ceiling);
    summary.headroom += @intFromBool(standing == .headroom);
}

/// Walks the source roots once, returning a ratchet-key -> current-value map
/// (duplicate keys folded to their maximum exactly as the ratchet does) and the
/// near-limit rows, sorted with the least room left first.
fn measureTree(ctx: *types.RunCtx) types.RunError!TreeScan {
    var values: std.StringHashMapUnmanaged(u64) = .empty;
    var headroom: std.ArrayList(HeadroomRow) = .empty;
    var measurer: Measurer = .{
        .arena = ctx.allocator,
        .cfg = ctx.cfg,
        .values = &values,
        .ceilings = try allCeilings(ctx),
        .headroom = &headroom,
    };
    for (roots) |root| {
        const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, root });
        try walk.walkZigFiles(ctx.allocator, path, .{ .display_root = root }, .{ .ctx = &measurer, .visit = visit });
    }
    const near = try headroom.toOwnedSlice(ctx.allocator);
    std.mem.sort(HeadroomRow, near, {}, byRoomLeft);
    return .{ .values = values, .headroom = near };
}

/// Every measurable check's frozen ceilings, in `measured_checks` order. Read
/// once up front: two checks key on the same path (`file-size` and
/// `line-length` both key on the file), so a ceiling lookup has to select the
/// check first, and doing that per source file would re-read five files each.
fn allCeilings(ctx: *types.RunCtx) types.RunError![]const []const ratchet.Entry {
    const out = try ctx.allocator.alloc([]const ratchet.Entry, file_metrics.measured_checks.len);
    for (file_metrics.measured_checks, out) |check_name, *slot| {
        slot.* = try file_metrics.ceilings(ctx.allocator, ctx.project_dir, check_name);
    }
    return out;
}

/// Visitor: measure one file, fold each item into the key map, and keep the
/// ones standing near a blocking limit.
fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const measurer: *Measurer = @ptrCast(@alignCast(raw_ctx));
    for (try file_metrics.measureFile(measurer.arena, entry.rel_path, entry.content, measurer.cfg)) |item| {
        const map_key = try measurementKey(measurer.arena, item.check, item.key);
        const gop = try measurer.values.getOrPut(measurer.arena, map_key);
        gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, item.value) else item.value;
        try noteHeadroom(measurer, item);
    }
}

/// Records `item` when it has consumed at least `near_limit_pct` of whatever
/// would block it. Filtering here rather than after the walk keeps a whole-tree
/// scan holding only the handful of rows the report prints.
fn noteHeadroom(measurer: *Measurer, item: file_metrics.Item) Allocator.Error!void {
    const limit = bindingLimit(item, ceilingOf(measurer.ceilings, item));
    if (!isNear(item.value, limit.value)) return;
    if (coveredByCeilingTable(item.value, limit)) return;
    try measurer.headroom.append(measurer.arena, .{
        .check = item.check,
        .key = item.key,
        .value = item.value,
        .limit = limit.value,
        .limit_kind = limit.kind,
    });
}

/// The limit that would actually block `item`. A frozen ceiling ALWAYS wins
/// when one is recorded, whichever side of the hard cap it falls: a ratchet
/// above the cap is accepted debt the gate no longer blocks on (so calling the
/// cap binding would report a green file as blocking), and a ratchet that
/// auto-lowered below the cap blocks sooner than the cap does. Only an
/// unratcheted item answers to its check's hard cap.
fn bindingLimit(item: file_metrics.Item, ceiling: ?u64) Limit {
    const c = ceiling orelse return .{ .value = item.hard_cap, .kind = .hard_cap };
    return .{ .value = c, .kind = .ceiling };
}

/// The frozen ceiling recorded for `item`, looked up in its OWN check's
/// ratchet — two checks share a key spelling, so the check selects first.
fn ceilingOf(all: []const []const ratchet.Entry, item: file_metrics.Item) ?u64 {
    for (file_metrics.measured_checks, all) |check_name, entries| {
        if (std.mem.eql(u8, check_name, item.check)) return file_metrics.ceilingFor(entries, item.key);
    }
    return null;
}

/// True when the ceiling table above already accounts for this item: a
/// ratcheted key sitting exactly ON its frozen ceiling. Baseline mode freezes
/// every offender at its measured value, so on an adopted project that is
/// EVERY ratcheted key — repeating them here would bury the rows only this
/// section can show (an unratcheted item nearing its hard cap, or a ratchet
/// that auto-lowered and still has a few lines of room).
fn coveredByCeilingTable(value: u64, limit: Limit) bool {
    return limit.kind == .ceiling and value == limit.value;
}

/// True when `value` has consumed at least `near_limit_pct` of `limit`.
/// Proportional rather than a fixed N because the limits differ by three orders
/// of magnitude (10000 file lines vs 6 parameters), so one N cannot serve both.
fn isNear(value: u64, limit: u64) bool {
    return value * percent >= limit * near_limit_pct;
}

/// Room left before the limit blocks, saturating at zero — an item already at
/// or past its limit has none, and `roomText` says which of the two it is.
fn roomLeft(row: HeadroomRow) u64 {
    return if (row.value >= row.limit) 0 else row.limit - row.value;
}

/// The share of its blocking limit this item has consumed, as a whole percent.
/// Printed because "9983 of 10000" and "6 of 7" are the same standing and do
/// not read as one: the percentage is the column a reader can scan for the file
/// that is about to cross, which is the question this whole section answers.
/// Shared with the gate's own near-hard-cap alert so both report one number.
pub fn pctOfLimit(row: HeadroomRow) u64 {
    return near_cap.pctOf(row.value, row.limit);
}

/// Orders headroom rows by least room left, breaking ties with the larger
/// measured value (so an overage leads its own zero-room group) and then the
/// check and key, which keeps the list stable across runs.
fn byRoomLeft(_: void, a: HeadroomRow, b: HeadroomRow) bool {
    const left_a = roomLeft(a);
    const left_b = roomLeft(b);
    if (left_a != left_b) return left_a < left_b;
    if (a.value != b.value) return a.value > b.value;
    if (!std.mem.eql(u8, a.check, b.check)) return std.mem.order(u8, a.check, b.check) == .lt;
    return std.mem.order(u8, a.key, b.key) == .lt;
}

/// Prints both measured sections: the frozen-ceiling table, then the items
/// nearest a limit that would block them.
pub fn printReport(arena: Allocator, report: Report) void {
    printCeilings(arena, report);
    printHeadroom(arena, report.headroom);
}

/// Prints the ceiling section, or a single line when no ratchet file exists yet.
fn printCeilings(arena: Allocator, report: Report) void {
    if (report.summaries.len == 0) {
        reporter.ok("ratchet ceilings — no per-item ratchet recorded under .guardian/baselines", .{});
        return;
    }
    reporter.ok("ratchet ceilings — current value vs frozen ceiling (measured now)", .{});
    for (report.summaries) |s| {
        print("  {s:<24} {d:>4} ratcheted: {d} with headroom, {d} at ceiling, {d} over{s}\n", .{
            s.check, s.ratcheted, s.headroom, s.at_ceiling, s.over, staleText(arena, s.stale),
        });
        printRows(arena, report.rows, s.check);
    }
}

/// Prints the headroom section: what is closest to blocking, worst first. This
/// is the pre-flight view — it answers "can this grow?" BEFORE the edit, which
/// the ceiling table above cannot (it lists only items already out of room).
fn printHeadroom(arena: Allocator, rows: []const HeadroomRow) void {
    if (rows.len == 0) {
        reporter.ok("headroom — nothing else within {d}% of a blocking limit (measured now)", .{near_limit_pct});
        return;
    }
    reporter.ok(
        "headroom — within {d}% of the limit that blocks them, least room first " ++
            "(keys already at a frozen ceiling are counted above)",
        .{near_limit_pct},
    );
    for (file_metrics.measured_checks) |check_name| printHeadroomFor(arena, rows, check_name);
}

/// Prints one check's near-limit rows, capped per check rather than across the
/// whole list. A tree can hold dozens of types sitting exactly on a 7-field cap,
/// all tied at zero room; capping globally would bury the one file approaching
/// a 10000-line hard limit under them, which is the row the reader came for.
fn printHeadroomFor(arena: Allocator, rows: []const HeadroomRow, check_name: []const u8) void {
    var shown: usize = 0;
    var skipped: usize = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.check, check_name)) continue;
        if (shown == max_detail_rows) {
            skipped += 1;
            continue;
        }
        print("  {s:<16} {s:<44} {d:>6} of {d} {s} ({d}%) — {s}\n", .{
            row.check,
            row.key,
            row.value,
            row.limit,
            limitLabel(row.limit_kind),
            pctOfLimit(row),
            roomText(arena, row),
        });
        shown += 1;
    }
    if (skipped > 0) print("    … and {d} more {s} item(s) in the band\n", .{ skipped, check_name });
}

/// Names which limit is binding, so "of 10000" is never read as the hard cap
/// when a frozen ceiling is what actually stops the item.
fn limitLabel(kind: LimitKind) []const u8 {
    return switch (kind) {
        .hard_cap => "hard cap",
        .ceiling => "frozen ceiling",
    };
}

/// How much room is left before this item blocks, or how far past it already is.
fn roomText(arena: Allocator, row: HeadroomRow) []const u8 {
    if (row.value > row.limit) {
        return std.fmt.allocPrint(arena, "OVER by {d}; the gate blocks", .{row.value - row.limit}) catch "OVER";
    }
    return std.fmt.allocPrint(arena, "{d} left", .{roomLeft(row)}) catch "?";
}

/// Prints the zero-headroom keys of one check, truncated past `max_detail_rows`.
fn printRows(arena: Allocator, rows: []const Row, check_name: []const u8) void {
    var shown: usize = 0;
    var skipped: usize = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.check, check_name)) continue;
        if (shown == max_detail_rows) {
            skipped += 1;
            continue;
        }
        print("    {s:<44} {s}{s}\n", .{ row.key, standingText(arena, row), tripText(arena, row) });
        shown += 1;
    }
    if (skipped > 0) print("    … and {d} more with no headroom\n", .{skipped});
}

/// The grep-stable opener of a tripped row's trailing column, with the two
/// spaces that separate it from the standing phrase before it.
const trip_marker = "  TRIPPED";

/// The trip half of a ceiling row: empty for an ordinary ratchet, and for a
/// hysteresis one the word TRIPPED plus how far the subject still has to fall.
/// Without it a recovering key reads as a comfortable ceiling with headroom,
/// when in fact it may not grow by one line and clears only at the recover
/// number.
fn tripText(arena: Allocator, row: Row) []const u8 {
    const recover = row.recover orelse return "";
    const value = row.value orelse
        return std.fmt.allocPrint(arena, "{s} — recover at <={d}", .{ trip_marker, recover }) catch trip_marker;
    if (value <= recover) {
        return std.fmt.allocPrint(
            arena,
            "{s} — at the recover line {d}; the next writing run clears it",
            .{ trip_marker, recover },
        ) catch trip_marker;
    }
    return std.fmt.allocPrint(
        arena,
        "{s} — recover at <={d} ({d} to go)",
        .{ trip_marker, recover, value - recover },
    ) catch trip_marker;
}

/// `  (N stale)` when a ratchet names keys the tree no longer has, else empty.
fn staleText(arena: Allocator, stale: usize) []const u8 {
    if (stale == 0) return "";
    return std.fmt.allocPrint(arena, ", {d} stale", .{stale}) catch "";
}

/// Renders one key's current-vs-ceiling verdict, deferring to the shared
/// phrase so this section and `size` can never word the same standing
/// differently. A stale key has no current value to compare and says so.
fn standingText(arena: Allocator, row: Row) []const u8 {
    const value = row.value orelse
        return std.fmt.allocPrint(arena, "ceiling {d} — subject no longer in the tree", .{row.ceiling}) catch "stale";
    return file_metrics.ceilingPhrase(arena, value, row.ceiling) catch "?";
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: size introspection - Reports no ceiling section for a project that has accepted no debt

test "collect walks a project and reports nothing when no ratchet is recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg: config_mod.Config = .{};
    var ctx: types.RunCtx = .{
        .allocator = arena.allocator(),
        .project_dir = "test-project",
        .cfg = &cfg,
        .quiet = true,
    };
    // test-project has sources but no .guardian/baselines: a project that has
    // never accepted debt gets an empty report, not a wall of zeroes.
    const report = try collect(&ctx);
    try testing.expectEqual(@as(usize, 0), report.summaries.len);
    try testing.expectEqual(@as(usize, 0), report.rows.len);
}

// spec: size introspection - Summarizes each ratchet as keys with headroom, at ceiling, and over

test "appendCheck tallies standings and rows only the keys without headroom" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var values: std.StringHashMapUnmanaged(u64) = .empty;
    try values.put(a, try measurementKey(a, "file-size", "src/roomy.zig"), 800); // ceiling 1000 → headroom
    try values.put(a, try measurementKey(a, "file-size", "src/tight.zig"), 1000); // ceiling 1000 → at ceiling
    try values.put(a, try measurementKey(a, "file-size", "src/over.zig"), 1005); // ceiling 1000 → over
    // "src/gone.zig" is recorded but absent from the tree → stale.
    const recorded = [_]ratchet.Entry{
        .{ .key = "src/roomy.zig", .value = 1000 },
        .{ .key = "src/tight.zig", .value = 1000 },
        .{ .key = "src/over.zig", .value = 1000 },
        .{ .key = "src/gone.zig", .value = 1000 },
    };
    var rows: std.ArrayList(Row) = .empty;
    const summary = try appendCheck(a, &rows, .{
        .check = "file-size",
        .recorded = &recorded,
        .values = values,
        .recover = null,
    });

    try testing.expectEqual(@as(usize, 4), summary.ratcheted);
    try testing.expectEqual(@as(usize, 1), summary.headroom);
    try testing.expectEqual(@as(usize, 1), summary.at_ceiling);
    try testing.expectEqual(@as(usize, 1), summary.over);
    try testing.expectEqual(@as(usize, 1), summary.stale);
    // Only the three keys with no headroom left are listed individually.
    try testing.expectEqual(@as(usize, 3), rows.items.len);
    try testing.expectEqualStrings("src/tight.zig", rows.items[0].key);
    try testing.expectEqual(@as(?u64, null), rows.items[2].value);
}

// spec: Hysteresis - Marks a tripped key and its recover line in the live debt report

test "a hysteresis check's rows say TRIPPED and how far there is left to fall" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var values: std.StringHashMapUnmanaged(u64) = .empty;
    // A tripped file still shrinking (8900 of a 10000 cap, clears at 8000) and
    // one that has arrived. Neither is at its ceiling, so without the trip
    // column both would be filtered out as "has headroom" — exactly the rows a
    // reader paying down a trip is watching.
    try values.put(a, try measurementKey(a, "file-size", "src/big.zig"), 8900);
    try values.put(a, try measurementKey(a, "file-size", "src/done.zig"), 7990);
    const recorded = [_]ratchet.Entry{
        .{ .key = "src/big.zig", .value = 9200 },
        .{ .key = "src/done.zig", .value = 8100 },
    };
    var rows: std.ArrayList(Row) = .empty;
    const summary = try appendCheck(a, &rows, .{
        .check = "file-size",
        .recorded = &recorded,
        .values = values,
        .recover = 8000,
    });
    try testing.expectEqual(@as(usize, 2), summary.headroom);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("  TRIPPED — recover at <=8000 (900 to go)", tripText(a, rows.items[0]));
    try testing.expectEqualStrings(
        "  TRIPPED — at the recover line 8000; the next writing run clears it",
        tripText(a, rows.items[1]),
    );
    // An ordinary ratchet says nothing extra — the column exists only where a
    // trip does.
    try testing.expectEqualStrings("", tripText(a, .{
        .check = "type-size",
        .key = "src/x.zig|Wide",
        .value = 8,
        .ceiling = 8,
        .standing = .at_ceiling,
    }));
    // The default config binds file-size and function-length, nothing else.
    const cfg: config_mod.Config = .{};
    try testing.expectEqual(@as(?u64, 8000), recoverLineFor(&cfg, "file-size"));
    try testing.expectEqual(@as(?u64, 320), recoverLineFor(&cfg, "function-length"));
    try testing.expect(recoverLineFor(&cfg, "type-size") == null);
}

// spec: size introspection - Keeps two checks' measurements of the same subject apart

test "appendCheck reads the measurement of its own check, not another's on the same key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One function carries two measurements under the SAME ratchet key: 37
    // source lines and 9 parameters. Keyed on the subject alone they folded to
    // the larger, and a 9-parameter ceiling was then judged against 37.
    var values: std.StringHashMapUnmanaged(u64) = .empty;
    const subject = "src/convert/footprint.zig|emitCustomPolyPad";
    try values.put(a, try measurementKey(a, "function-length", subject), 37);
    try values.put(a, try measurementKey(a, "function-size", subject), 9);

    var rows: std.ArrayList(Row) = .empty;
    const summary = try appendCheck(a, &rows, .{
        .check = "function-size",
        .recorded = &.{.{ .key = subject, .value = 9 }},
        .values = values,
        .recover = null,
    });
    // 9 against a ceiling of 9 is at ceiling, not "OVER by 28".
    try testing.expectEqual(@as(usize, 1), summary.at_ceiling);
    try testing.expectEqual(@as(usize, 0), summary.over);
    try testing.expectEqual(@as(?u64, 9), rows.items[0].value);
}

// spec: size introspection - Prints each ratchet's headroom split and its stuck keys

test "printReport prints the per-check split and the keys with no headroom" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // Nothing recorded: one line saying so, never an empty table.
    printReport(a, .{ .summaries = &.{}, .rows = &.{} });
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "no per-item ratchet recorded") != null);

    cap.buf.clearRetainingCapacity();
    const split: Summary = .{
        .check = "file-size",
        .ratcheted = 3,
        .headroom = 1,
        .at_ceiling = 1,
        .over = 1,
        .stale = 0,
    };
    printReport(a, .{
        .summaries = &.{split},
        .rows = &.{
            .{ .check = "file-size", .key = "src/tight.zig", .value = 1000, .ceiling = 1000, .standing = .at_ceiling },
            .{ .check = "file-size", .key = "src/over.zig", .value = 1005, .ceiling = 1000, .standing = .over },
        },
    });
    const out = cap.buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "3 ratcheted: 1 with headroom, 1 at ceiling, 1 over") != null);
    try testing.expect(std.mem.indexOf(u8, out, "src/tight.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "OVER by 5") != null);
}

// spec: size introspection - Picks the limit that would block an item and bands it by room left

test "bindingLimit prefers a ceiling under the hard cap and isNear keeps the near band" {
    const roomy: file_metrics.Item = .{
        .check = "file-size",
        .key = "src/a.zig",
        .subject = "src/a.zig",
        .value = 9000,
        .cap = 1000,
        .hard_cap = 10_000,
    };
    // No ratchet: the hard cap is the only thing that blocks.
    const capped = bindingLimit(roomy, null);
    try testing.expectEqual(@as(u64, 10_000), capped.value);
    try testing.expect(capped.kind == .hard_cap);
    // A ceiling below the cap bites first and must be the one reported.
    const frozen = bindingLimit(roomy, 9100);
    try testing.expectEqual(@as(u64, 9100), frozen.value);
    try testing.expect(frozen.kind == .ceiling);
    // And a ceiling ABOVE the cap is accepted debt the gate no longer blocks
    // on: reporting the cap there would call a green file blocking.
    const accepted = bindingLimit(roomy, 10_296);
    try testing.expectEqual(@as(u64, 10_296), accepted.value);
    try testing.expect(accepted.kind == .ceiling);

    // The band is proportional: one fixed N cannot serve a 10000-line cap and a
    // 6-parameter cap at once.
    try testing.expect(isNear(9000, 10_000));
    try testing.expect(!isNear(8999, 10_000));
    try testing.expect(isNear(6, 6));
    try testing.expect(!isNear(5, 6));
    // Room saturates at zero, and an overage is worded rather than negated.
    try testing.expectEqual(@as(u64, 0), roomLeft(.{
        .check = "file-size",
        .key = "src/a.zig",
        .value = 10_005,
        .limit = 10_000,
        .limit_kind = .hard_cap,
    }));
}

// spec: size introspection - Lists the items nearest a blocking limit with the least room first

test "printHeadroom orders by room left and names which limit binds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // Nothing near a limit says so out loud: silence would read as "no data".
    printHeadroom(a, &.{});
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "nothing else within 90%") != null);

    cap.buf.clearRetainingCapacity();
    var rows = [_]HeadroomRow{
        .{ .check = "file-size", .key = "src/roomy.zig", .value = 9200, .limit = 10_000, .limit_kind = .hard_cap },
        .{ .check = "file-size", .key = "src/tight.zig", .value = 10_223, .limit = 10_227, .limit_kind = .ceiling },
    };
    // A key sitting exactly on its ceiling is the ceiling table's row, not this
    // section's — repeated here it would be every ratcheted key on the project.
    try testing.expect(coveredByCeilingTable(10_227, .{ .value = 10_227, .kind = .ceiling }));
    try testing.expect(!coveredByCeilingTable(10_223, .{ .value = 10_227, .kind = .ceiling }));
    try testing.expect(!coveredByCeilingTable(7, .{ .value = 7, .kind = .hard_cap }));
    std.mem.sort(HeadroomRow, &rows, {}, byRoomLeft);
    printHeadroom(a, &rows);
    const out = cap.buf.items;
    // The 4-line item leads the 800-line one, and its line says the frozen
    // ceiling is what stops it — not the 10000 hard cap.
    const tight = std.mem.indexOf(u8, out, "src/tight.zig").?;
    try testing.expect(tight < std.mem.indexOf(u8, out, "src/roomy.zig").?);
    try testing.expect(std.mem.indexOf(u8, out, "10223 of 10227 frozen ceiling (99%) — 4 left") != null);
    try testing.expect(std.mem.indexOf(u8, out, "9200 of 10000 hard cap (92%) — 800 left") != null);
}

// spec: size introspection - Names the share of its blocking limit each headroom item has consumed

test "pctOfLimit reports how much of the blocking limit an item has consumed" {
    // The audit case: an un-ratcheted file 17 lines from the 10000 hard cap. It
    // was in this list all along, but "9983 of 10000" reads like slack next to
    // "6 of 7" — the percentage is what makes the two comparable at a glance.
    try testing.expectEqual(@as(u64, 99), pctOfLimit(.{
        .check = "file-size",
        .key = "src/placement/optimizer.zig",
        .value = 9983,
        .limit = 10_000,
        .limit_kind = .hard_cap,
    }));
    // A row already over its limit reads past 100% rather than wrapping.
    try testing.expectEqual(@as(u64, 100), pctOfLimit(.{
        .check = "type-size",
        .key = "src/x.zig|Wide",
        .value = 7,
        .limit = 7,
        .limit_kind = .hard_cap,
    }));
    try testing.expectEqual(@as(u64, 105), pctOfLimit(.{
        .check = "file-size",
        .key = "src/over.zig",
        .value = 10_500,
        .limit = 10_000,
        .limit_kind = .ceiling,
    }));
}

// spec: size introspection - Renders a ratcheted key's current value against its ceiling

test "standingText words headroom, a zero-headroom ceiling, an overage, and a stale key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: Row = .{
        .check = "file-size",
        .key = "src/a.zig",
        .value = 990,
        .ceiling = 1000,
        .standing = .headroom,
    };
    try testing.expectEqualStrings("990 vs ceiling 1000 — 10 of headroom", standingText(a, base));
    var row = base;
    row.value = 1000;
    row.standing = .at_ceiling;
    try testing.expectEqualStrings("1000 vs ceiling 1000 — AT CEILING, 0 headroom", standingText(a, row));
    row.value = 10_005;
    row.ceiling = 10_000;
    row.standing = .over;
    try testing.expectEqualStrings("10005 vs ceiling 10000 — OVER by 5; the gate blocks", standingText(a, row));
    // A ratchet key whose subject is gone has no current value to compare.
    row.value = null;
    row.standing = .none;
    try testing.expectEqualStrings("ceiling 10000 — subject no longer in the tree", standingText(a, row));
    // The stale count only appears when there is one.
    try testing.expectEqualStrings("", staleText(a, 0));
    try testing.expectEqualStrings(", 2 stale", staleText(a, 2));
}
