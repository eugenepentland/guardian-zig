//! The three-way rules that resolve a `.guardian/` metadata conflict, one per
//! artifact format. Pure: rows in, merged rows out — no files, no git.
//!
//! Every rule shares one principle: **a merge may leave more debt than either
//! branch has, never less**. Too many entries reads as resolved debt on the next
//! run and auto-prunes itself away; too few reds a gate that should be green and
//! sends the agent hunting. The one place that principle is deliberately
//! inverted is a DELETION — an entry the base had and a side dropped is debt
//! somebody paid, and the merge keeps it paid.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ratchet = @import("../ratchet.zig");

/// One side's rows for a keyed format, already decoded to key → value.
const ValueMap = std.StringHashMapUnmanaged(u64);

/// A counter merge: the resolved rows, plus whether both sides moved the same
/// counter — in which case the value below is the larger of the two, a guess
/// that must be replaced by a regeneration before the file is trusted.
pub const CounterResult = struct {
    lines: []const []const u8,
    needs_regen: bool,
};

/// Multiset union of `ours` and `theirs`, minus every entry the base had that
/// either side deleted. Used for the formats whose rows are opaque text — v3
/// identity baselines, the legacy v1 text baseline, and the pub-api surface.
///
/// Counts, not a set: an identity baseline may legitimately hold one key N
/// times (N violations share it), and collapsing that to one row would report
/// the survivors as newly-added debt.
pub fn mergeRows(
    arena: Allocator,
    base: []const []const u8,
    ours: []const []const u8,
    theirs: []const []const u8,
) Allocator.Error![]const []const u8 {
    var counts: std.StringHashMapUnmanaged([3]usize) = .empty;
    try tally(arena, &counts, base, 0);
    try tally(arena, &counts, ours, 1);
    try tally(arena, &counts, theirs, 2);

    var out: std.ArrayList([]const u8) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| {
        const n = resolveCount(e.value_ptr.*);
        for (0..n) |_| try out.append(arena, e.key_ptr.*);
    }
    const owned = try out.toOwnedSlice(arena);
    std.mem.sort([]const u8, owned, {}, lessThan);
    return owned;
}

/// Adds one side's rows into the per-row `[base, ours, theirs]` count triple.
fn tally(
    arena: Allocator,
    counts: *std.StringHashMapUnmanaged([3]usize),
    rows: []const []const u8,
    side: usize,
) Allocator.Error!void {
    for (rows) |row| {
        const gop = try counts.getOrPut(arena, row);
        if (!gop.found_existing) gop.value_ptr.* = .{ 0, 0, 0 };
        gop.value_ptr.*[side] += 1;
    }
}

/// How many copies of one row the merge keeps, given its `[base, ours, theirs]`
/// counts: an agreed count stands, an untouched side yields to the changed one,
/// a deletion on either side wins, and two different additions union.
fn resolveCount(c: [3]usize) usize {
    const b, const o, const t = c;
    if (o == t) return o;
    if (b == o) return t;
    if (b == t) return o;
    if (o == 0 or t == 0) return 0; // deletion is debt paid — keep it paid
    return @max(o, t);
}

/// Per-key MIN of the two sides' ceilings, over the union of keys minus every
/// key the base had that a side deleted. Rendered back as `<value> <key>` rows,
/// sorted by KEY the way `ratchet.zig` writes them.
///
/// MIN even when only one side moved: a ratchet only ever tightens, so the
/// tighter ceiling is the honest one. If that under-states what the merged code
/// needs, the gate reds and `accept` replaces the guess with a MEASUREMENT —
/// the one resolution a merge of two frozen numbers cannot get wrong.
pub fn mergeRatchets(
    arena: Allocator,
    base: []const []const u8,
    ours: []const []const u8,
    theirs: []const []const u8,
) Allocator.Error![]const []const u8 {
    var b = try decode(arena, base);
    var o = try decode(arena, ours);
    var t = try decode(arena, theirs);

    var entries: std.ArrayList(ratchet.Entry) = .empty;
    var keys = try unionKeys(arena, &o, &t);
    var it = keys.iterator();
    while (it.next()) |k| {
        const key = k.key_ptr.*;
        const value = pickTighter(b.get(key), o.get(key), t.get(key)) orelse continue;
        try entries.append(arena, .{ .key = key, .value = value });
    }
    const owned = try entries.toOwnedSlice(arena);
    std.mem.sort(ratchet.Entry, owned, {}, byKey);

    const lines = try arena.alloc([]const u8, owned.len);
    for (owned, 0..) |e, i| lines[i] = try std.fmt.allocPrint(arena, "{d} {s}", .{ e.value, e.key });
    return lines;
}

/// The ceiling one key keeps: the tighter of two present values, the surviving
/// side's value when the other never had the key, and nothing when a side
/// deleted a key the base had (that item stopped being an offender).
fn pickTighter(b: ?u64, o: ?u64, t: ?u64) ?u64 {
    if (o) |ov| {
        if (t) |tv| return @min(ov, tv);
        return if (b == null) ov else null;
    }
    if (t) |tv| return if (b == null) tv else null;
    return null;
}

/// Per-name three-way merge of `<name> <count>` budget rows. A counter both
/// sides moved resolves to the larger value AND sets `needs_regen`: the real
/// count is a property of the merged tree, which neither branch measured.
pub fn mergeCounters(
    arena: Allocator,
    base: []const []const u8,
    ours: []const []const u8,
    theirs: []const []const u8,
) Allocator.Error!CounterResult {
    var b = try decodeCounters(arena, base);
    var o = try decodeCounters(arena, ours);
    var t = try decodeCounters(arena, theirs);

    var lines: std.ArrayList([]const u8) = .empty;
    var needs_regen = false;
    var keys = try unionKeys(arena, &o, &t);
    var it = keys.iterator();
    while (it.next()) |k| {
        const name = k.key_ptr.*;
        const picked = pickCount(b.get(name), o.get(name), t.get(name));
        const value = picked.value orelse continue;
        if (picked.contested) needs_regen = true;
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s} {d}", .{ name, value }));
    }
    const owned = try lines.toOwnedSlice(arena);
    std.mem.sort([]const u8, owned, {}, lessThan);
    return .{ .lines = owned, .needs_regen = needs_regen };
}

/// One counter's resolution: the value to keep (null drops the row) and whether
/// both sides moved it, which is what marks the whole file for regeneration.
const Picked = struct { value: ?u64, contested: bool };

/// Resolves one counter: agreement stands, a single-sided change wins outright,
/// two different changes take the larger and report themselves contested, and a
/// deletion of a base key wins (as everywhere else here).
fn pickCount(b: ?u64, o: ?u64, t: ?u64) Picked {
    const ov = o orelse return .{ .value = if (b == null) t else null, .contested = false };
    const tv = t orelse return .{ .value = if (b == null) ov else null, .contested = false };
    if (ov == tv) return .{ .value = ov, .contested = false };
    if (b) |bv| {
        if (bv == ov) return .{ .value = tv, .contested = false };
        if (bv == tv) return .{ .value = ov, .contested = false };
    }
    return .{ .value = @max(ov, tv), .contested = true };
}

/// Every key held by either side (the base contributes no keys of its own — a
/// key only both sides dropped is gone).
fn unionKeys(
    arena: Allocator,
    ours: *const ValueMap,
    theirs: *const ValueMap,
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    var oit = ours.keyIterator();
    while (oit.next()) |k| try keys.put(arena, k.*, {});
    var tit = theirs.keyIterator();
    while (tit.next()) |k| try keys.put(arena, k.*, {});
    return keys;
}

/// Decodes `<value> <key>` ratchet rows; an unparseable row is skipped, exactly
/// as `ratchet.decodeLines` skips it (the row validator names it separately).
fn decode(arena: Allocator, rows: []const []const u8) Allocator.Error!ValueMap {
    var map: ValueMap = .empty;
    for (rows) |row| {
        const e = ratchet.decodeLine(row) orelse continue;
        try map.put(arena, e.key, e.value);
    }
    return map;
}

/// Decodes `<name> <count>` counter rows (value LAST, unlike a ratchet row).
fn decodeCounters(arena: Allocator, rows: []const []const u8) Allocator.Error!ValueMap {
    var map: ValueMap = .empty;
    for (rows) |row| {
        const sp = std.mem.lastIndexOfScalar(u8, row, ' ') orelse continue;
        const value = std.fmt.parseInt(u64, row[sp + 1 ..], 10) catch continue;
        try map.put(arena, row[0..sp], value);
    }
    return map;
}

fn byKey(_: void, a: ratchet.Entry, b: ratchet.Entry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Merge - Unions opaque baseline rows and honors either side's deletion

test "mergeRows keeps both additions and drops what either side resolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // base holds two entries; each side resolves one of them and adds its own.
    const base = [_][]const u8{ "spec|old-a", "spec|old-b" };
    const ours = [_][]const u8{ "spec|old-b", "spec|new-ours" };
    const theirs = [_][]const u8{ "spec|old-a", "spec|new-theirs" };
    const merged = try mergeRows(a, &base, &ours, &theirs);

    // Both new entries survive; both paid-off entries stay paid off.
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("spec|new-ours", merged[0]);
    try testing.expectEqualStrings("spec|new-theirs", merged[1]);
}

// spec: Merge - Preserves the multiplicity of a repeated baseline entry

test "mergeRows keeps duplicate identities instead of collapsing them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Three violations share one identity on both sides: the count must survive,
    // or the survivors read as newly-added debt on the next run.
    const same = [_][]const u8{ "ban|src/a.zig", "ban|src/a.zig", "ban|src/a.zig" };
    try testing.expectEqual(@as(usize, 3), (try mergeRows(a, &same, &same, &same)).len);

    // Both sides independently added the same NEW row: union, so one copy.
    const one = [_][]const u8{"ban|src/b.zig"};
    try testing.expectEqual(@as(usize, 1), (try mergeRows(a, &.{}, &one, &one)).len);

    // Ours added a second copy while theirs stood still: the larger count wins.
    const two = [_][]const u8{ "ban|src/b.zig", "ban|src/b.zig" };
    try testing.expectEqual(@as(usize, 2), (try mergeRows(a, &one, &two, &one)).len);
}

// spec: Merge - Resolves a per-item ratchet to the tighter ceiling per key

test "mergeRatchets takes the minimum ceiling and keeps each side's new keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The real case from the field: both branches extracted modules out of one
    // huge file and froze DIFFERENT ceilings for it.
    const base = [_][]const u8{ "10400 src/router.zig", "130 src/a.zig|f" };
    const ours = [_][]const u8{ "10360 src/router.zig", "130 src/a.zig|f", "90 src/new-ours.zig|g" };
    const theirs = [_][]const u8{ "10398 src/router.zig", "95 src/new-theirs.zig|h" };
    const merged = try mergeRatchets(a, &base, &ours, &theirs);

    // Tightest ceiling for the shared key, both new keys kept, and the key
    // theirs resolved away (`src/a.zig|f`) stays resolved. Rows come out sorted
    // by KEY (not by the value-first text), the order ratchet.zig writes.
    try testing.expectEqual(@as(usize, 3), merged.len);
    try testing.expectEqualStrings("90 src/new-ours.zig|g", merged[0]);
    try testing.expectEqualStrings("95 src/new-theirs.zig|h", merged[1]);
    try testing.expectEqualStrings("10360 src/router.zig", merged[2]);
}

// spec: Merge - Marks a counter both sides moved for regeneration

test "mergeCounters takes the max of two changed counts and flags the file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // @alignCast grew on both branches — the exact hand-merge that silently
    // lost a count in the field. @constCast moved on one side only.
    const base = [_][]const u8{ "@alignCast 65", "@bitCast 0", "@constCast 47" };
    const ours = [_][]const u8{ "@alignCast 66", "@bitCast 0", "@constCast 47" };
    const theirs = [_][]const u8{ "@alignCast 67", "@bitCast 0", "@constCast 50" };
    const merged = try mergeCounters(a, &base, &ours, &theirs);

    try testing.expect(merged.needs_regen);
    try testing.expectEqual(@as(usize, 3), merged.lines.len);
    try testing.expectEqualStrings("@alignCast 67", merged.lines[0]);
    try testing.expectEqualStrings("@bitCast 0", merged.lines[1]);
    try testing.expectEqualStrings("@constCast 50", merged.lines[2]);
}

// spec: Merge - Leaves an uncontested counter merge unmarked

test "mergeCounters stays clean when only one side moved each counter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = [_][]const u8{ "casts 3", "panics 1" };
    const ours = [_][]const u8{ "casts 4", "panics 1" };
    const theirs = [_][]const u8{ "casts 3", "panics 2" };
    const merged = try mergeCounters(a, &base, &ours, &theirs);

    // Each side's single-handed change is adopted verbatim, so nothing is a
    // guess and the file needs no regeneration.
    try testing.expect(!merged.needs_regen);
    try testing.expectEqualStrings("casts 4", merged.lines[0]);
    try testing.expectEqualStrings("panics 2", merged.lines[1]);
}

fn fuzzThreeWay(backing: Allocator, smith: *std.testing.Smith) anyerror!void {
    var bytes: [64 * 1024]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    var rows: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| try rows.append(arena.allocator(), line);
    _ = try mergeRows(arena.allocator(), rows.items, rows.items, rows.items);
    _ = try mergeRatchets(arena.allocator(), rows.items, rows.items, rows.items);
    _ = try mergeCounters(arena.allocator(), rows.items, rows.items, rows.items);
}

test "fuzz: three-way metadata mergers tolerate arbitrary rows" {
    try testing.fuzz(testing.allocator, fuzzThreeWay, .{ .corpus = &.{ "", "1 key\n2 other", "name 3\nmalformed" } });
}
