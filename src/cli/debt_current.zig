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

const Allocator = std.mem.Allocator;
const print = reporter.detail;

/// Source roots the threshold checks scan — the only files with ratchet keys.
const roots = [_][]const u8{ "src", "test" };

/// How many individual keys are listed per check before the tail is summarized.
/// Only zero-headroom and over-ceiling keys are listed at all, so a long list
/// means a genuinely stuck check rather than noise.
const max_detail_rows: usize = 10;

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

/// The measured current-vs-ceiling state of every ratcheted key.
pub const Report = struct {
    summaries: []const Summary,
    rows: []const Row,
};

/// Walk state: the config to measure with, and the key -> current value map
/// being filled.
const Measurer = struct {
    arena: Allocator,
    cfg: *const config_mod.Config,
    values: *std.StringHashMapUnmanaged(u64),
};

/// Measures the tree and pairs every recorded ceiling with its current value.
/// Checks with no ratchet file contribute nothing, so a project that has never
/// accepted debt gets an empty report rather than a wall of zeroes.
pub fn collect(ctx: *types.RunCtx) types.RunError!Report {
    const values = try measureTree(ctx);
    var summaries: std.ArrayList(Summary) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    for (file_metrics.measured_checks) |check_name| {
        const recorded = try file_metrics.ceilings(ctx.allocator, ctx.project_dir, check_name);
        if (recorded.len == 0) continue;
        try summaries.append(ctx.allocator, try appendCheck(ctx.allocator, &rows, check_name, recorded, values));
    }
    return .{
        .summaries = try summaries.toOwnedSlice(ctx.allocator),
        .rows = try rows.toOwnedSlice(ctx.allocator),
    };
}

/// Folds one check's recorded ceilings into a summary, appending a row for
/// every key that has no headroom left (at ceiling, over, or stale).
fn appendCheck(
    arena: Allocator,
    rows: *std.ArrayList(Row),
    check_name: []const u8,
    recorded: []const ratchet.Entry,
    values: std.StringHashMapUnmanaged(u64),
) Allocator.Error!Summary {
    var summary: Summary = .{
        .check = check_name,
        .ratcheted = recorded.len,
        .headroom = 0,
        .at_ceiling = 0,
        .over = 0,
        .stale = 0,
    };
    for (recorded) |entry| {
        const current = values.get(entry.key);
        const standing = file_metrics.standingOf(current orelse 0, entry.value);
        tally(&summary, current, standing);
        if (current != null and standing == .headroom) continue;
        try rows.append(arena, .{
            .check = check_name,
            .key = entry.key,
            .value = current,
            .ceiling = entry.value,
            .standing = standing,
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

/// Walks the source roots and returns a ratchet-key -> current-value map,
/// folding duplicate keys to their maximum exactly as the ratchet does.
fn measureTree(ctx: *types.RunCtx) types.RunError!std.StringHashMapUnmanaged(u64) {
    var values: std.StringHashMapUnmanaged(u64) = .empty;
    var measurer: Measurer = .{ .arena = ctx.allocator, .cfg = ctx.cfg, .values = &values };
    for (roots) |root| {
        const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, root });
        try walk.walkZigFiles(ctx.allocator, path, .{ .display_root = root }, .{ .ctx = &measurer, .visit = visit });
    }
    return values;
}

/// Visitor: measure one file and fold each item into the key map.
fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const measurer: *Measurer = @ptrCast(@alignCast(raw_ctx));
    for (try file_metrics.measureFile(measurer.arena, entry.rel_path, entry.content, measurer.cfg)) |item| {
        const gop = try measurer.values.getOrPut(measurer.arena, item.key);
        gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, item.value) else item.value;
    }
}

/// Prints the section, or a single line when no ratchet file exists yet.
pub fn printReport(arena: Allocator, report: Report) void {
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
        print("    {s:<44} {s}\n", .{ row.key, standingText(arena, row) });
        shown += 1;
    }
    if (skipped > 0) print("    … and {d} more with no headroom\n", .{skipped});
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
    try values.put(a, "src/roomy.zig", 800); // ceiling 1000 → headroom
    try values.put(a, "src/tight.zig", 1000); // ceiling 1000 → at ceiling
    try values.put(a, "src/over.zig", 1005); // ceiling 1000 → over
    // "src/gone.zig" is recorded but absent from the tree → stale.
    const recorded = [_]ratchet.Entry{
        .{ .key = "src/roomy.zig", .value = 1000 },
        .{ .key = "src/tight.zig", .value = 1000 },
        .{ .key = "src/over.zig", .value = 1000 },
        .{ .key = "src/gone.zig", .value = 1000 },
    };
    var rows: std.ArrayList(Row) = .empty;
    const summary = try appendCheck(a, &rows, "file-size", &recorded, values);

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
