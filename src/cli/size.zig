//! `size` command — "what is this file's number RIGHT NOW, by your metric?".
//!
//! Every threshold check reports a value only once an item is already over its
//! cap, and `debt` prints the frozen ceilings without the current value beside
//! them. Closing that loop cost one recorded consumer six ~90-second gate runs
//! for a single file trim, with a 170-line disagreement against `grep -c` that
//! was never resolved (guardian excludes `test { ... }` blocks from the
//! file-size metric; grep does not).
//!
//! `guardian-check size <path> [dir]` answers it in one command: the file's
//! current measurements, each against the check's caps and against its frozen
//! ratchet ceiling when one is recorded. It gates nothing, writes nothing, and
//! measures with the checks' own functions (see `file_metrics.zig`), so the
//! number it prints is the number the gate would ratchet.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const walk = @import("../walk.zig");
const ratchet = @import("../ratchet.zig");
const file_metrics = @import("../file_metrics.zig");
const config_mod = @import("../config.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;

pub const command_name = "size";

/// Source roots the threshold checks scan, and therefore the only paths that
/// carry a ratchet key.
const roots = [_][]const u8{ "src", "test" };

/// One printable measurement: what was measured and the ceiling recorded for
/// it, if any.
const Row = struct {
    item: file_metrics.Item,
    ceiling: ?u64,
};

/// The matched source file: its walker-relative path (half of every ratchet
/// key) and everything measured for it.
const Found = struct {
    rel_path: []const u8,
    items: []const file_metrics.Item,
};

/// Walk state: the request, and the matches found so far.
const Locator = struct {
    arena: Allocator,
    cfg: *const config_mod.Config,
    wanted: []const u8,
    matches: *std.ArrayList(Found),
};

/// Entry point: measure one file and print its current values against the
/// caps and ceilings. Never gates and never writes; a bad or ambiguous path is
/// the only failure, reported as a usage error.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const requested = ctx.target_path orelse {
        reporter.fail("size: name a file — `guardian-check size src/foo.zig [dir]`", .{});
        return error.CheckFailed;
    };
    const wanted = try walk.normalizePath(ctx.allocator, requested);
    const matches = try locate(ctx, wanted);
    if (matches.len != 1) return reportNoSingleMatch(requested, matches);
    try printReport(ctx, matches[0]);
}

/// Walks the source roots and returns every file whose path matches the
/// request, each already measured.
fn locate(ctx: *types.RunCtx, wanted: []const u8) types.RunError![]const Found {
    var matches: std.ArrayList(Found) = .empty;
    var locator: Locator = .{
        .arena = ctx.allocator,
        .cfg = ctx.cfg,
        .wanted = wanted,
        .matches = &matches,
    };
    for (roots) |root| {
        const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, root });
        try walk.walkZigFiles(ctx.allocator, path, .{ .display_root = root }, .{ .ctx = &locator, .visit = visit });
    }
    return matches.toOwnedSlice(ctx.allocator);
}

/// Visitor: measure the file when its path is the one asked for.
fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const locator: *Locator = @ptrCast(@alignCast(raw_ctx));
    if (!pathMatches(entry.rel_path, locator.wanted)) return;
    try locator.matches.append(locator.arena, .{
        .rel_path = entry.rel_path,
        .items = try file_metrics.measureFile(locator.arena, entry.rel_path, entry.content, locator.cfg),
    });
}

/// True when the walked `rel_path` is the file the user asked for: the exact
/// walker path (`src/check.zig`), or any trailing path segment of it
/// (`check.zig`, `cli/size.zig`) so a bare file name works. A partial segment
/// never matches — `size.zig` must not resolve `file_size.zig`.
fn pathMatches(rel_path: []const u8, wanted: []const u8) bool {
    if (std.mem.eql(u8, rel_path, wanted)) return true;
    if (rel_path.len <= wanted.len) return false;
    const tail_start = rel_path.len - wanted.len;
    return rel_path[tail_start - 1] == '/' and std.mem.eql(u8, rel_path[tail_start..], wanted);
}

/// Reports a request that named no file or more than one, listing the
/// candidates so the next invocation is unambiguous.
fn reportNoSingleMatch(requested: []const u8, matches: []const Found) types.RunError!void {
    if (matches.len == 0) {
        reporter.fail("size: no file matching '{s}' under src/ or test/", .{requested});
        print("  pass the path the checks use, e.g. `guardian-check size src/check.zig .`\n", .{});
        return error.CheckFailed;
    }
    reporter.fail("size: '{s}' matches {d} files — name one of them", .{ requested, matches.len });
    for (matches) |m| print("  {s}\n", .{m.rel_path});
    return error.CheckFailed;
}

/// Prints the measurement table: one section per measurable ratchet, then the
/// standing note naming the ratchets this command cannot measure.
fn printReport(ctx: *types.RunCtx, found: Found) types.RunError!void {
    reporter.ok("size — {s} (measured now; no gate, no writes)", .{found.rel_path});
    for (file_metrics.measured_checks) |check_name| {
        const rows = try rowsFor(ctx, found.items, check_name);
        for (try selectRows(ctx.allocator, rows)) |row| printRow(ctx.allocator, row);
    }
    print("  not measured here (metric lives inside the check's scan): {s}\n", .{
        try std.mem.join(ctx.allocator, ", ", &file_metrics.unmeasured_checks),
    });
}

/// Pairs every item of one check with its recorded ceiling, reading that
/// check's ratchet file once.
fn rowsFor(ctx: *types.RunCtx, items: []const file_metrics.Item, check_name: []const u8) types.RunError![]Row {
    const recorded = try file_metrics.ceilings(ctx.allocator, ctx.project_dir, check_name);
    var rows: std.ArrayList(Row) = .empty;
    for (items) |item| {
        if (!std.mem.eql(u8, item.check, check_name)) continue;
        try rows.append(ctx.allocator, .{ .item = item, .ceiling = file_metrics.ceilingFor(recorded, item.key) });
    }
    return rows.toOwnedSlice(ctx.allocator);
}

/// Keeps the rows worth printing for one check, largest value first: every
/// ratcheted item (its ceiling is the number the caller came for), every item
/// over its recommended cap, and — when neither applies — the single largest
/// item, so the report always names the file's leader instead of going silent.
fn selectRows(arena: Allocator, rows: []Row) Allocator.Error![]const Row {
    std.mem.sort(Row, rows, {}, byValueDesc);
    var kept: std.ArrayList(Row) = .empty;
    for (rows) |row| {
        if (row.ceiling != null or row.item.value > row.item.cap) try kept.append(arena, row);
    }
    if (kept.items.len == 0 and rows.len > 0) try kept.append(arena, rows[0]);
    return kept.toOwnedSlice(arena);
}

/// Orders rows by descending measured value, breaking ties by subject name so
/// the output is stable across runs.
fn byValueDesc(_: void, a: Row, b: Row) bool {
    if (a.item.value != b.item.value) return a.item.value > b.item.value;
    return std.mem.order(u8, a.item.subject, b.item.subject) == .lt;
}

/// Prints one measurement line: check, subject, current value with its unit,
/// the caps, and how the value sits against its frozen ceiling.
fn printRow(arena: Allocator, row: Row) void {
    print("  {s:<16} {s:<32} {d:>6} {s:<18} {s:<26} {s}\n", .{
        row.item.check,
        row.item.subject,
        row.item.value,
        ratchet.unitLabel(row.item.check),
        capText(arena, row.item),
        file_metrics.ceilingPhrase(arena, row.item.value, row.ceiling) catch "ceiling ?",
    });
}

/// Renders a check's limits: one cap for a single-limit check, both tiers when
/// the recommended limit only warns and the hard limit blocks.
fn capText(arena: Allocator, item: file_metrics.Item) []const u8 {
    if (item.cap == item.hard_cap) return std.fmt.allocPrint(arena, "cap {d}", .{item.cap}) catch "cap ?";
    return std.fmt.allocPrint(arena, "cap {d} rec / {d} hard", .{ item.cap, item.hard_cap }) catch "cap ?";
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn testItem(check_name: []const u8, subject: []const u8, value: u64, cap: u32) file_metrics.Item {
    return .{
        .check = check_name,
        .key = subject,
        .subject = subject,
        .value = value,
        .cap = cap,
        .hard_cap = cap,
    };
}

// spec: size introspection - Resolves a requested path to the walker path the checks use

test "pathMatches accepts the exact path and a whole trailing segment" {
    try testing.expect(pathMatches("src/check.zig", "src/check.zig"));
    try testing.expect(pathMatches("src/check.zig", "check.zig"));
    try testing.expect(pathMatches("src/cli/size.zig", "cli/size.zig"));
    // A partial segment must not match, or `size.zig` would resolve
    // `file_size.zig` and report another file's numbers.
    try testing.expect(!pathMatches("src/checks/file_size.zig", "size.zig"));
    try testing.expect(!pathMatches("src/check.zig", "src/other.zig"));
    // The wanted path can't be longer than the walked one.
    try testing.expect(!pathMatches("check.zig", "src/check.zig"));
}

// spec: size introspection - Prints every ratcheted item and the largest unratcheted one

test "selectRows keeps ratcheted and over-cap rows, else the largest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Nothing ratcheted and nothing over cap: the leader still prints, so the
    // reader always sees the file's current worst number.
    var quiet_rows = [_]Row{
        .{ .item = testItem("function-length", "small", 10, 120), .ceiling = null },
        .{ .item = testItem("function-length", "biggest", 40, 120), .ceiling = null },
    };
    const leader = try selectRows(a, &quiet_rows);
    try testing.expectEqual(@as(usize, 1), leader.len);
    try testing.expectEqualStrings("biggest", leader[0].item.subject);

    // A ratcheted item always prints (that ceiling is the number asked for),
    // as does an item over its cap, largest first.
    var mixed = [_]Row{
        .{ .item = testItem("function-length", "ratcheted", 12, 120), .ceiling = 12 },
        .{ .item = testItem("function-length", "over", 130, 120), .ceiling = null },
        .{ .item = testItem("function-length", "ordinary", 30, 120), .ceiling = null },
    };
    const kept = try selectRows(a, &mixed);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("over", kept[0].item.subject);
    try testing.expectEqualStrings("ratcheted", kept[1].item.subject);
}

// spec: size introspection - Renders one cap for a single-limit check and both tiers otherwise

test "capText distinguishes a single cap from a recommended/hard pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("cap 6", capText(a, testItem("function-size", "f", 3, 6)));
    try testing.expectEqualStrings("cap 1000 rec / 10000 hard", capText(a, .{
        .check = "file-size",
        .key = "src/a.zig",
        .subject = "src/a.zig",
        .value = 900,
        .cap = 1000,
        .hard_cap = 10_000,
    }));
}
