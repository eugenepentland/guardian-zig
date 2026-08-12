//! Per-item ratchet lifecycle (baseline v2) for the threshold checks.
//!
//! v1 baselines diff by exact violation text (`baseline.zig`), which embeds the
//! metric in the line ("fn parse is 130 lines (cap 120)"). Any metric change on
//! a grandfathered offender — *including an improvement* 130→125 that is still
//! over cap — diffs as a new violation and reds the build, so consumers raise
//! global caps instead (see AUDIT-2026-07-08.md, Finding 2).
//!
//! This module replaces that failure mode for the ten checks that emit a stable
//! `ratchet_key` + a `metric`: each offender gets a personal, only-shrinks
//! ceiling. The baseline file (`.guardian/baselines/<check>.txt`) stores sorted
//! `<value> <key>` lines under a `# guardian-snapshot v2` header. A key that
//! exceeds its recorded value fails; a key that decreased auto-lowers; a key
//! that disappeared auto-prunes; a key not on file is a new offender that
//! already tripped the default cap and fails rather than being ratified.

const std = @import("std");
const fs = @import("fs.zig");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const reporter = @import("reporter.zig");

/// Ratchet baseline format version. Distinct from the v1 text baseline so an
/// existing v1 file read as v2 raises `VersionMismatch` and self-migrates.
pub const version: u32 = 2;

/// How a check's per-key ratchet value is derived when several violation records
/// share one `ratchet_key`. `max` takes the largest metric (function length,
/// nesting depth, field count, …). `count` takes the number of records —
/// line-length emits one record per over-limit line, all keyed by the file, and
/// a per-file "worst line length" is meaningless, so the ratchet holds the
/// *count* of over-limit lines instead.
pub const AggMode = enum { max, count };

/// How a ratcheted check's regression should be presented. A `shape`
/// regression (function length, nesting, complexity, …) is a structural smell
/// the fix guidance leads on. `volume` growth (file size, type size) usually
/// tracks legitimate feature growth — new code plus its tests landing in an
/// existing file — so the accept guidance leads instead and the tone drops
/// the alarm.
pub const GrowthClass = enum { shape, volume };

/// A threshold check routed to the ratchet lifecycle, with its aggregation
/// mode, how its regressions read (shape smell vs volume growth), and the
/// human unit its metric counts (`unit`) so a regression line names what a
/// bare number measures ("8" → "8 params") instead of leaving the reader to
/// guess line-count vs param-count vs field-count.
const MetricCheck = struct {
    name: []const u8,
    mode: AggMode,
    class: GrowthClass = .shape,
    unit: []const u8,
};

/// The ten threshold checks that emit `ratchet_key` + `metric`. Membership here
/// (not the presence of records in a given run) is what selects the ratchet
/// lifecycle, so a check with zero current violations still ratchets — it prunes
/// its whole baseline rather than being mistaken for a non-metric check.
const metric_checks = [_]MetricCheck{
    .{ .name = "function-length", .mode = .max, .unit = "lines" },
    .{ .name = "nesting-depth", .mode = .max, .unit = "nesting levels" },
    .{ .name = "cognitive-complexity", .mode = .max, .unit = "complexity points" },
    .{ .name = "function-size", .mode = .max, .unit = "params" },
    .{ .name = "type-size", .mode = .max, .class = .volume, .unit = "fields" },
    .{ .name = "file-size", .mode = .max, .class = .volume, .unit = "code lines" },
    .{ .name = "struct-method-cap", .mode = .max, .unit = "pub methods" },
    .{ .name = "optional-density", .mode = .max, .unit = "% optional fields" },
    .{ .name = "bool-ops-per-condition", .mode = .max, .unit = "boolean ops" },
    .{ .name = "line-length", .mode = .count, .unit = "over-length lines" },
};

/// The human unit for `check_name`'s ratchet metric ("params", "fields",
/// "over-length lines", …), used in the regression message so a bare measured
/// value names its dimension. Empty string for a non-ratchet name (callers only
/// consult it on the ratchet path, where the unit is always defined).
pub fn unitLabel(check_name: []const u8) []const u8 {
    for (metric_checks) |m| {
        if (std.mem.eql(u8, m.name, check_name)) return m.unit;
    }
    return "";
}

/// The aggregation mode for `check_name`, or null when it is not a ratchet
/// (threshold) check — baseline mode then uses the v1 text-diff lifecycle.
pub fn metricMode(check_name: []const u8) ?AggMode {
    for (metric_checks) |m| {
        if (std.mem.eql(u8, m.name, check_name)) return m.mode;
    }
    return null;
}

/// The presentation class for `check_name`'s regressions; `.shape` for any
/// non-ratchet name (callers only consult it on the ratchet path).
pub fn growthClass(check_name: []const u8) GrowthClass {
    for (metric_checks) |m| {
        if (std.mem.eql(u8, m.name, check_name)) return m.class;
    }
    return .shape;
}

/// One ratcheted subject: its stable key and the recorded ceiling value.
pub const Entry = struct { key: []const u8, value: u64 };

/// A key whose current value rose above its recorded ceiling.
pub const GrownKey = struct { key: []const u8, old: u64, new: u64 };

/// The set of keys that fail a run: those that grew and those seen for the first
/// time (already over the default cap, hence flagged) — never silently added.
pub const Regression = struct {
    grown: []const GrownKey,
    new_offenders: []const Entry,
    /// Total current keys (context for the failure message).
    remaining: usize,
};

/// Counts of keys the auto-lower write path touched on a green run.
pub const Improved = struct { lowered: usize, pruned: usize, remaining: usize };

/// Outcome of one check's ratchet lifecycle. `created`/`migrated`/`matched`/
/// `improved`/`refreshed` are green; `regressed` fails the build.
pub const Outcome = union(enum) {
    /// No prior ratchet existed; one was written.
    created: usize,
    /// A stale-version (v1 text) baseline was re-recorded as a v2 ratchet.
    migrated: usize,
    /// Every key holds its recorded value; no write.
    matched: usize,
    /// Some keys shrank or vanished; the file was rewritten to the smaller set.
    improved: Improved,
    /// A refresh (`GUARDIAN_UPDATE_SNAPSHOT`) rewrote the ratchet.
    refreshed: usize,
    /// One or more keys grew or newly appeared; the run fails and the file is
    /// left untouched (a later green run captures any concurrent improvement).
    regressed: Regression,
};

/// Reduces a check's violation records to one `Entry` per `ratchet_key`, folding
/// duplicates by `mode` (`max` metric, or `count` of records). Records missing a
/// key or metric are skipped defensively. Result is sorted by key for
/// deterministic output.
pub fn aggregate(arena: Allocator, records: []const reporter.Violation, mode: AggMode) Allocator.Error![]Entry {
    var map: std.StringHashMapUnmanaged(u64) = .empty;
    for (records) |v| {
        const key = v.ratchet_key orelse continue;
        const metric = v.metric orelse continue;
        const gop = try map.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = switch (mode) {
                .max => metric,
                .count => 1,
            };
        } else switch (mode) {
            .max => gop.value_ptr.* = @max(gop.value_ptr.*, metric),
            .count => gop.value_ptr.* += 1,
        }
    }
    return mapToSortedEntries(arena, &map);
}

/// Drains a key→value map into an Entry slice sorted by key.
fn mapToSortedEntries(arena: Allocator, map: *std.StringHashMapUnmanaged(u64)) Allocator.Error![]Entry {
    var out = try arena.alloc(Entry, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = .{ .key = e.key_ptr.*, .value = e.value_ptr.* };
    // The map isn't mutated during iteration, so the drain fills exactly the
    // preallocated slice — a mismatch would mean a stale count() or a leaked slot.
    std.debug.assert(i == out.len);
    std.mem.sort(Entry, out, {}, byKey);
    return out;
}

fn byKey(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

/// Encodes an entry as its stored `<value> <key>` line. Value first so a key
/// containing spaces still parses (split on the first space).
fn encode(arena: Allocator, e: Entry) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d} {s}", .{ e.value, e.key });
}

/// Parses a stored `<value> <key>` line, or null when it is blank / malformed.
pub fn decodeLine(line: []const u8) ?Entry {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const value = std.fmt.parseInt(u64, line[0..sp], 10) catch return null;
    const key = line[sp + 1 ..];
    if (key.len == 0) return null;
    return .{ .key = key, .value = value };
}

/// Decodes every stored line into an Entry, dropping any that don't parse.
pub fn decodeLines(arena: Allocator, lines: []const []const u8) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (lines) |l| {
        if (decodeLine(l)) |e| try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

/// Parses a ratchet file's raw contents (header skipped) into entries. Used by
/// the debt report to summarize a committed ratchet file.
pub fn parse(arena: Allocator, content: []const u8) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
        if (decodeLine(line)) |e| try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

/// The highest-value entry (worst offender) among `entries`, or null when empty.
pub fn maxEntry(entries: []const Entry) ?Entry {
    if (entries.len == 0) return null;
    var worst = entries[0];
    for (entries[1..]) |e| {
        if (e.value > worst.value) worst = e;
    }
    return worst;
}

/// Writes `entries` as sorted-by-key `<value> <key>` lines. Sorting by key (not
/// by the value-first line text) keeps a value change a one-line diff instead of
/// reordering the file — the whole point of the ratchet over v1 text baselines.
fn writeEntries(arena: Allocator, path: []const u8, entries: []const Entry) snapshot.WriteError!void {
    const sorted = try arena.dupe(Entry, entries);
    std.mem.sort(Entry, sorted, {}, byKey);
    const lines = try arena.alloc([]const u8, sorted.len);
    for (sorted, 0..) |e, i| lines[i] = try encode(arena, e);
    // Content-identical short-circuit: re-emitting the same ratchet leaves the
    // committed file (and the diff) untouched.
    _ = try snapshot.writePresortedChecked(arena, path, version, lines);
}

pub const LifecycleError = snapshot.WriteError || snapshot.ReadError;

/// Runs the ratchet lifecycle for one check. `entries` is the aggregated current
/// state. `force_refresh` re-records unconditionally (the deny-growth guard runs
/// in the caller, before this). A missing file creates; a stale-version file
/// migrates; otherwise the current state is compared against the recorded one.
///
/// `write_allowed` gates the non-refresh writes — first-record creation, v1→v2
/// migration, and auto-lower/prune: an ordinary (read-only) run classifies the
/// outcome but leaves the file untouched, so a source-only diff never carries an
/// incidental ratchet rewrite; `commit`/`migrate` flip it to persist.
pub fn lifecycle(
    arena: Allocator,
    path: []const u8,
    entries: []const Entry,
    force_refresh: bool,
    write_allowed: bool,
) LifecycleError!Outcome {
    if (force_refresh) {
        try writeEntries(arena, path, entries);
        return .{ .refreshed = entries.len };
    }
    const snap = snapshot.read(arena, path, version) catch |e| switch (e) {
        error.Missing => {
            if (write_allowed) try writeEntries(arena, path, entries);
            return .{ .created = entries.len };
        },
        // A v1 text baseline read as v2 mismatches → re-record as a ratchet.
        error.VersionMismatch => {
            if (write_allowed) try writeEntries(arena, path, entries);
            return .{ .migrated = entries.len };
        },
        else => return e,
    };
    const old = try decodeLines(arena, snap.lines);
    const outcome = try classify(arena, old, entries);
    // Auto-lower/prune: a green run whose keys only shrank or vanished rewrites
    // the file to the smaller set — but only on a metadata-writable run, so an
    // ordinary run reports the improvement without persisting it.
    switch (outcome) {
        .improved => if (write_allowed) try writeEntries(arena, path, entries),
        else => {},
    }
    return outcome;
}

/// Pure comparison of the recorded ratchet (`old`) against the current state
/// (`new`): a raised value grows, an unseen key is a new offender (either fails
/// the run), a lowered value or a vanished key improves it, else it matches.
pub fn classify(arena: Allocator, old: []const Entry, new: []const Entry) Allocator.Error!Outcome {
    var old_map: std.StringHashMapUnmanaged(u64) = .empty;
    for (old) |e| try old_map.put(arena, e.key, e.value);
    var new_keys: std.StringHashMapUnmanaged(void) = .empty;
    for (new) |e| try new_keys.put(arena, e.key, {});

    var grown: std.ArrayList(GrownKey) = .empty;
    var new_offenders: std.ArrayList(Entry) = .empty;
    var lowered: usize = 0;
    for (new) |e| {
        if (old_map.get(e.key)) |ov| {
            if (e.value > ov) {
                try grown.append(arena, .{ .key = e.key, .old = ov, .new = e.value });
            } else if (e.value < ov) {
                lowered += 1;
            }
        } else {
            try new_offenders.append(arena, e);
        }
    }
    var pruned: usize = 0;
    for (old) |e| {
        if (!new_keys.contains(e.key)) pruned += 1;
    }

    if (grown.items.len > 0 or new_offenders.items.len > 0) {
        return .{ .regressed = .{
            .grown = try grown.toOwnedSlice(arena),
            .new_offenders = try new_offenders.toOwnedSlice(arena),
            .remaining = new.len,
        } };
    }
    if (lowered > 0 or pruned > 0) {
        return .{ .improved = .{ .lowered = lowered, .pruned = pruned, .remaining = new.len } };
    }
    return .{ .matched = new.len };
}

/// True when replacing recorded `old` with `new` would raise any key's value or
/// add a key — the refusal condition for a `deny_growth` ratchet refresh. A
/// refresh that only holds, lowers, or prunes values is allowed.
pub fn wouldGrow(arena: Allocator, old: []const Entry, new: []const Entry) Allocator.Error!bool {
    var old_map: std.StringHashMapUnmanaged(u64) = .empty;
    for (old) |e| try old_map.put(arena, e.key, e.value);
    for (new) |e| {
        const ov = old_map.get(e.key) orelse return true; // new key
        if (e.value > ov) return true; // raised value
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn deleteIfExists(path: []const u8) void {
    fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) }),
    };
}

fn rec(key: []const u8, metric: u64) reporter.Violation {
    return .{ .check = "function-length", .message = "x", .ratchet_key = key, .metric = metric };
}

// spec: Per-Item Ratchets - Selects the ratchet lifecycle only for threshold checks

test "metricMode routes the ten threshold checks and rejects others" {
    try testing.expect(metricMode("function-length").? == .max);
    try testing.expect(metricMode("line-length").? == .count);
    try testing.expect(metricMode("type-size").? == .max);
    // A non-threshold check keeps the v1 text-diff lifecycle.
    try testing.expect(metricMode("ban-fs") == null);
    try testing.expect(metricMode("spec") == null);
    // Growth class: file/type size read as volume growth; everything else
    // (including non-ratchet names, defensively) reads as a shape regression.
    try testing.expect(growthClass("file-size") == .volume);
    try testing.expect(growthClass("type-size") == .volume);
    try testing.expect(growthClass("function-length") == .shape);
    try testing.expect(growthClass("ban-fs") == .shape);
}

// spec: Per-Item Ratchets - Names each threshold check's metric unit for regression messages

test "unitLabel names the dimension a ratchet metric measures" {
    // Distinct units so a bare "measured 8" reads as "8 params" / "8 fields".
    try testing.expectEqualStrings("params", unitLabel("function-size"));
    try testing.expectEqualStrings("fields", unitLabel("type-size"));
    try testing.expectEqualStrings("over-length lines", unitLabel("line-length"));
    try testing.expectEqualStrings("code lines", unitLabel("file-size"));
    // A non-ratchet name has no unit (callers only read it on the ratchet path).
    try testing.expectEqualStrings("", unitLabel("ban-fs"));
}

// spec: Per-Item Ratchets - Aggregates violation records to the max metric per key

test "aggregate folds duplicate keys to their max in max mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const records = [_]reporter.Violation{ rec("src/a.zig|f", 130), rec("src/a.zig|f", 118), rec("src/b.zig|g", 90) };
    const es = try aggregate(a, &records, .max);
    try testing.expectEqual(@as(usize, 2), es.len);
    // Sorted by key: a before b; a's value is the max (130), not the later 118.
    try testing.expectEqualStrings("src/a.zig|f", es[0].key);
    try testing.expectEqual(@as(u64, 130), es[0].value);
    try testing.expectEqual(@as(u64, 90), es[1].value);
}

// spec: Per-Item Ratchets - Counts over-limit records per key in count mode

test "aggregate counts records per key in count mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Three over-limit lines in one file, one in another → per-file counts 3 and 1.
    const records = [_]reporter.Violation{
        rec("src/a.zig", 140), rec("src/a.zig", 200), rec("src/a.zig", 121), rec("src/b.zig", 130),
    };
    const es = try aggregate(a, &records, .count);
    try testing.expectEqual(@as(usize, 2), es.len);
    try testing.expectEqual(@as(u64, 3), es[0].value); // src/a.zig: 3 over-limit lines
    try testing.expectEqual(@as(u64, 1), es[1].value); // src/b.zig: 1
}

// spec: Per-Item Ratchets - Encodes and decodes a value key line

test "encode and decodeLine round-trip, tolerating keys with spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try encode(a, .{ .key = "src/a b.zig|f", .value = 130 });
    try testing.expectEqualStrings("130 src/a b.zig|f", line);
    const back = decodeLine(line).?;
    try testing.expectEqualStrings("src/a b.zig|f", back.key); // split on FIRST space
    try testing.expectEqual(@as(u64, 130), back.value);
    try testing.expect(decodeLine("garbage") == null);
}

// spec: Per-Item Ratchets - Fails when a key value exceeds its recorded ceiling

test "classify reports a grown key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const new = [_]Entry{.{ .key = "src/a.zig|f", .value = 140 }};
    const out = try classify(a, &old, &new);
    try testing.expect(out == .regressed);
    try testing.expectEqual(@as(usize, 1), out.regressed.grown.len);
    try testing.expectEqual(@as(u64, 130), out.regressed.grown[0].old);
    try testing.expectEqual(@as(u64, 140), out.regressed.grown[0].new);
    try testing.expectEqual(@as(usize, 0), out.regressed.new_offenders.len);
}

// spec: Per-Item Ratchets - Fails an unrecorded key as a new offender over the default cap

test "classify reports an unseen key as a new offender" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const new = [_]Entry{ .{ .key = "src/a.zig|f", .value = 130 }, .{ .key = "src/b.zig|g", .value = 125 } };
    const out = try classify(a, &old, &new);
    try testing.expect(out == .regressed);
    try testing.expectEqual(@as(usize, 0), out.regressed.grown.len);
    try testing.expectEqual(@as(usize, 1), out.regressed.new_offenders.len);
    try testing.expectEqualStrings("src/b.zig|g", out.regressed.new_offenders[0].key);
}

// spec: Per-Item Ratchets - Lowers a key whose value decreased and stays green

test "classify lowers a shrunk key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const new = [_]Entry{.{ .key = "src/a.zig|f", .value = 125 }};
    const out = try classify(a, &old, &new);
    try testing.expect(out == .improved);
    try testing.expectEqual(@as(usize, 1), out.improved.lowered);
    try testing.expectEqual(@as(usize, 0), out.improved.pruned);
}

// spec: Per-Item Ratchets - Prunes keys absent from the current violations

test "classify prunes a vanished key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Entry{ .{ .key = "src/a.zig|f", .value = 130 }, .{ .key = "src/b.zig|g", .value = 90 } };
    const new = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const out = try classify(a, &old, &new);
    try testing.expect(out == .improved);
    try testing.expectEqual(@as(usize, 0), out.improved.lowered);
    try testing.expectEqual(@as(usize, 1), out.improved.pruned);
}

// spec: Per-Item Ratchets - Matches when every key holds its recorded value

test "classify matches when nothing changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const new = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const out = try classify(a, &old, &new);
    try testing.expect(out == .matched);
    try testing.expectEqual(@as(usize, 1), out.matched);
}

// spec: Per-Item Ratchets - Creates then auto-lowers a ratchet file across runs

test "lifecycle creates, matches, and auto-lowers a ratchet file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/test-ratchet-lifecycle.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    const at130 = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    try testing.expect((try lifecycle(a, path, &at130, false, true)) == .created);
    try testing.expect((try lifecycle(a, path, &at130, false, true)) == .matched);

    // Shrinking rewrites the file to 125; a re-run then matches at the new floor.
    const at125 = [_]Entry{.{ .key = "src/a.zig|f", .value = 125 }};
    try testing.expect((try lifecycle(a, path, &at125, false, true)) == .improved);
    const reread = try lifecycle(a, path, &at125, false, true);
    try testing.expect(reread == .matched);

    // A later growth beyond the lowered floor now fails.
    const at140 = [_]Entry{.{ .key = "src/a.zig|f", .value = 140 }};
    const grew = try lifecycle(a, path, &at140, false, true);
    try testing.expect(grew == .regressed);
    try testing.expectEqual(@as(u64, 125), grew.regressed.grown[0].old);
}

// spec: Per-Item Ratchets - Defers the auto-lower write to a metadata-writable run

test "lifecycle defers create and auto-lower on a read-only run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/test-ratchet-readonly.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // write_allowed = false: a missing ratchet is grandfathered green but NOT
    // written, so an ordinary run leaves the tree clean.
    const at130 = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    try testing.expect((try lifecycle(a, path, &at130, false, false)) == .created);
    try testing.expectError(error.FileNotFound, fs.cwd().access(path, .{}));

    // Record it writably, then improve on a read-only run: the auto-lower is
    // reported but the committed ratchet keeps its higher ceiling untouched.
    _ = try lifecycle(a, path, &at130, false, true);
    const at125 = [_]Entry{.{ .key = "src/a.zig|f", .value = 125 }};
    try testing.expect((try lifecycle(a, path, &at125, false, false)) == .improved);
    const snap = try snapshot.read(a, path, version);
    const kept = try decodeLines(a, snap.lines);
    try testing.expectEqual(@as(u64, 130), kept[0].value);
}

// spec: Per-Item Ratchets - Re-records a stale-version baseline as a ratchet

test "lifecycle migrates a v1 text baseline without failing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/test-ratchet-migrate.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // Hand-write a v1 text baseline (the pre-upgrade format).
    var v1_lines = [_][]const u8{"src/a.zig:5: fn f is 130 lines (cap 120)"};
    try snapshot.write(path, 1, &v1_lines);

    // First v2 run re-records without red...
    const at130 = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    try testing.expect((try lifecycle(a, path, &at130, false, true)) == .migrated);
    // ...and the migrated ratchet then enforces growth.
    const at140 = [_]Entry{.{ .key = "src/a.zig|f", .value = 140 }};
    try testing.expect((try lifecycle(a, path, &at140, false, true)) == .regressed);
}

// spec: Per-Item Ratchets - Refuses a deny_growth refresh that raises a value or adds a key

test "wouldGrow flags a raised value or an added key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const raised = [_]Entry{.{ .key = "src/a.zig|f", .value = 131 }};
    const added = [_]Entry{ .{ .key = "src/a.zig|f", .value = 130 }, .{ .key = "src/b.zig|g", .value = 10 } };
    const held = [_]Entry{.{ .key = "src/a.zig|f", .value = 130 }};
    const lowered = [_]Entry{.{ .key = "src/a.zig|f", .value = 120 }};
    try testing.expect(try wouldGrow(a, &old, &raised)); // raised value
    try testing.expect(try wouldGrow(a, &old, &added)); // added key
    try testing.expect(!try wouldGrow(a, &old, &held)); // holding is allowed
    try testing.expect(!try wouldGrow(a, &old, &lowered)); // lowering is allowed
}

test "decodeLines skips malformed lines and keeps valid entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{ "130 src/a.zig|f", "garbage-no-value", "95 src/b.zig|g" };
    const es = try decodeLines(a, &lines);
    try testing.expectEqual(@as(usize, 2), es.len);
    try testing.expectEqualStrings("src/a.zig|f", es[0].key);
    try testing.expectEqualStrings("src/b.zig|g", es[1].key);
}

// spec: Per-Item Ratchets - Summarizes a ratchet file's worst offender

test "parse and maxEntry surface the worst offender" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "# guardian-snapshot v2\n95 src/a.zig|f\n130 src/b.zig|g\n";
    const es = try parse(a, content);
    try testing.expectEqual(@as(usize, 2), es.len);
    const worst = maxEntry(es).?;
    try testing.expectEqualStrings("src/b.zig|g", worst.key);
    try testing.expectEqual(@as(u64, 130), worst.value);
    try testing.expect(maxEntry(&[_]Entry{}) == null);
}
