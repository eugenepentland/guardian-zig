//! Per-mutant result cache for the `mutate` command. A mutant's outcome is a
//! pure function of the tree state and the mutant's identity, so once measured
//! it can be reused instead of paying another build + test cycle.
//!
//! Key: (suite digest, mutant identity). The suite digest (cache.suiteDigest)
//! hashes every src/ + test/ .zig file plus build.zig/.zon and guardian.toml —
//! ANY source or test edit changes it and invalidates every record (correctness
//! first: the cache never reuses an outcome that a change could have altered).
//! Mutant identity is (file, byte span, original token, replacement).
//!
//! Records live one-per-line in `.guardian/cache/mutants.jsonl` — the cache dir
//! is git-ignored and excluded from the skip-cache digest, so churn here never
//! touches git or the build cache. The file is append-only *during* a run (each
//! freshly-measured outcome is flushed immediately, so an interrupted run
//! resumes: the completed mutants are already on disk), and compacted *on load*
//! down to the current suite's deduped records (dropping stale-suite lines and
//! keeping the latest outcome per identity). A refresh
//! (GUARDIAN_UPDATE_SNAPSHOT covering `mutate`) bypasses reads entirely — a
//! fresh ratchet must be a fresh measurement, not a replay.

const std = @import("std");
const gen = @import("gen.zig");
const runner = @import("runner.zig");

const Allocator = std.mem.Allocator;
const Outcome = runner.Outcome;

/// Cache file leaf under the project dir. `cache/` is git-ignored and
/// digest-excluded, so rewriting it never churns git or the skip-cache.
const cache_leaf = ".guardian/cache/mutants.jsonl";
/// Read cap for the cache file (mirrors the other sinks' generous cap).
const max_cache_bytes = 64 * 1024 * 1024;

/// Maps a mutant identity key to its cached outcome for the current suite state.
pub const Map = std.StringHashMapUnmanaged(Outcome);

/// Whether `load` may reuse cached outcomes. `.fresh` (a snapshot refresh is in
/// effect) ignores the file entirely, so a fresh ratchet is a fresh measurement
/// rather than a replay of stored results.
pub const Reuse = enum { reuse, fresh };

/// Wire form of one cached outcome. Private DTO: field order here is the emitted
/// JSON key order. `suite` scopes the record to a tree state; the span + tokens
/// are the mutant identity; `outcome` is the reusable measurement.
const Record = struct {
    suite: []const u8,
    file: []const u8,
    start: usize,
    end: usize,
    original: []const u8,
    replacement: []const u8,
    outcome: []const u8,
};

/// Result of parsing the cache file: the identity→outcome reuse map plus the
/// compacted file text (current-suite records, deduped, latest-wins).
const Loaded = struct {
    map: Map,
    compacted: []const u8,
};

/// The cache file path: `<project_dir>/.guardian/cache/mutants.jsonl`.
fn path(arena: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, cache_leaf });
}

/// Parses an outcome name (an `@tagName` of `Outcome`) back to the enum, or null
/// when unrecognized (a record written by a newer guardian is skipped, not
/// misread). The round-trip test guards these strings against an enum rename.
fn parseOutcome(name: []const u8) ?Outcome {
    if (std.mem.eql(u8, name, "killed")) return .killed;
    if (std.mem.eql(u8, name, "survived")) return .survived;
    if (std.mem.eql(u8, name, "unviable")) return .unviable;
    if (std.mem.eql(u8, name, "timed_out")) return .timed_out;
    return null;
}

/// NUL-joined identity key for a mutant's parts. NUL can't appear in a path or
/// Zig token, so distinct identities never collide into one key.
fn identityKey(
    arena: Allocator,
    file: []const u8,
    start: usize,
    end: usize,
    original: []const u8,
    replacement: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{d}\x00{d}\x00{s}\x00{s}", .{ file, start, end, original, replacement });
}

/// Identity key for a generated mutant — the lookup key into a loaded `Map`.
pub fn keyFor(arena: Allocator, m: gen.Mutant) Allocator.Error![]u8 {
    return identityKey(arena, m.path, m.start, m.end, m.original, m.replacement);
}

/// Serializes one cached outcome to a single JSON line (no trailing newline).
/// The outcome is stored as its `@tagName`; std.json escapes path/token text.
fn recordJson(arena: Allocator, suite_hex: []const u8, m: gen.Mutant, outcome: Outcome) Allocator.Error![]u8 {
    const rec: Record = .{
        .suite = suite_hex,
        .file = m.path,
        .start = m.start,
        .end = m.end,
        .original = m.original,
        .replacement = m.replacement,
        .outcome = @tagName(outcome),
    };
    return std.json.Stringify.valueAlloc(arena, rec, .{});
}

/// Parses cache-file `content`, keeping only records whose `suite` matches
/// `suite_hex` (stale-suite lines are dropped) and deduping by identity with
/// latest-wins. Returns the reuse map and the compacted file text (the kept
/// records, one per line, insertion-ordered). Malformed lines are skipped.
fn buildMap(arena: Allocator, content: []const u8, suite_hex: []const u8) Allocator.Error!Loaded {
    var map: Map = .{};
    var order: std.ArrayList([]const u8) = .empty; // unique keys, insertion order
    var latest: std.StringHashMapUnmanaged([]const u8) = .{}; // key -> latest raw JSON line
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0) continue;
        const rec = std.json.parseFromSliceLeaky(Record, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        if (!std.mem.eql(u8, rec.suite, suite_hex)) continue; // stale tree state
        const outcome = parseOutcome(rec.outcome) orelse continue;
        const key = try identityKey(arena, rec.file, rec.start, rec.end, rec.original, rec.replacement);
        const gop = try latest.getOrPut(arena, key);
        if (!gop.found_existing) try order.append(arena, key);
        gop.value_ptr.* = line; // latest wins
        try map.put(arena, key, outcome);
    }
    // Every unique identity is appended to `order` exactly once (the
    // !found_existing branch) and put into `map`, so the compaction below has one
    // reuse entry per emitted line.
    std.debug.assert(order.items.len == map.count());
    var buf: std.ArrayList(u8) = .empty;
    for (order.items) |k| {
        try buf.appendSlice(arena, latest.get(k).?);
        try buf.append(arena, '\n');
    }
    return .{ .map = map, .compacted = try buf.toOwnedSlice(arena) };
}

/// Overwrites the cache file with `data`, creating the cache dir. Used to
/// compact the file to the current suite's deduped records after a load.
fn overwrite(p: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(p)) |dir| try std.fs.cwd().makePath(dir);
    const f = try std.fs.cwd().createFile(p, .{});
    defer f.close();
    try f.writeAll(data);
}

/// Loads the reuse map for `suite_hex` and compacts the cache file to that
/// suite's deduped records. `.fresh` mode (a refresh is in effect) returns an
/// empty map and touches nothing — a fresh ratchet must not replay cached
/// outcomes. Best-effort: a missing/unreadable/corrupt file yields an empty map,
/// and a failed compaction rewrite is logged and swallowed (the map stays valid).
pub fn load(arena: Allocator, project_dir: []const u8, suite_hex: []const u8, mode: Reuse) Map {
    if (mode == .fresh) return .{};
    const p = path(arena, project_dir) catch return .{};
    const content = std.fs.cwd().readFileAlloc(arena, p, max_cache_bytes) catch return .{};
    const loaded = buildMap(arena, content, suite_hex) catch return .{};
    overwrite(p, loaded.compacted) catch |e|
        std.log.warn("guardian mutate cache compaction failed: {s}", .{@errorName(e)});
    return loaded.map;
}

/// Appends one freshly-measured outcome to the cache file (creating it). Called
/// immediately after each non-cached mutant runs, so an interrupted run's
/// completed work survives to be reused on resume. Best-effort: any I/O error is
/// logged and swallowed so the cache can never fail the run.
pub fn append(
    arena: Allocator,
    project_dir: []const u8,
    suite_hex: []const u8,
    m: gen.Mutant,
    outcome: Outcome,
) void {
    appendInner(arena, project_dir, suite_hex, m, outcome) catch |e|
        std.log.warn("guardian mutate cache append failed: {s}", .{@errorName(e)});
}

fn appendInner(
    arena: Allocator,
    project_dir: []const u8,
    suite_hex: []const u8,
    m: gen.Mutant,
    outcome: Outcome,
) !void {
    const line = try recordJson(arena, suite_hex, m, outcome);
    const p = try path(arena, project_dir);
    if (std.fs.path.dirname(p)) |dir| try std.fs.cwd().makePath(dir);
    const f = try std.fs.cwd().createFile(p, .{ .truncate = false, .read = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(line);
    try f.writeAll("\n");
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Builds a mutant with a fixed line (identity ignores the line number).
fn mk(path_: []const u8, start: usize, end: usize, original: []const u8, replacement: []const u8) gen.Mutant {
    return .{ .path = path_, .start = start, .end = end, .original = original, .replacement = replacement, .line = 1 };
}

// spec: Mutation Testing - Serializes and reparses a cached mutant outcome name

test "the outcome tag name round-trips through parseOutcome" {
    for ([_]Outcome{ .killed, .survived, .unviable, .timed_out }) |o| {
        // recordJson stores @tagName(o); parseOutcome reads it back — this pins
        // the two together, so an enum rename that broke the format fails here.
        try testing.expectEqual(o, parseOutcome(@tagName(o)).?);
    }
    // An unknown name (e.g. from a newer guardian) is skipped, not misread.
    try testing.expect(parseOutcome("teleported") == null);
}

// spec: Mutation Testing - Builds a stable mutant identity key from its file span and operator

test "keyFor distinguishes identities and matches equal ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m1 = mk("src/x.zig", 9, 10, "<", "<=");
    var same = m1;
    same.line = 99; // a formatting shift changes the line, not the identity
    const diff = mk("src/x.zig", 9, 10, "<", "<");
    try testing.expectEqualStrings(try keyFor(a, m1), try keyFor(a, same));
    // A different replacement is a different mutant.
    try testing.expect(!std.mem.eql(u8, try keyFor(a, m1), try keyFor(a, diff)));
}

// spec: Mutation Testing - Renders a cached mutant outcome as one JSON record

test "recordJson emits the suite, identity, and outcome" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = mk("src/x.zig", 9, 10, "<", "<=");
    try testing.expectEqualStrings(
        "{\"suite\":\"aa\",\"file\":\"src/x.zig\",\"start\":9,\"end\":10," ++
            "\"original\":\"<\",\"replacement\":\"<=\",\"outcome\":\"survived\"}",
        try recordJson(a, "aa", m, .survived),
    );
}

// spec: Mutation Testing - Loads matching-suite outcomes dropping stale and duplicate records

test "buildMap keeps the current suite, drops stale, and dedups latest-wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two "aa" records for x.zig|9 (re-run: survived then killed → killed wins),
    // one "aa" record for y.zig, and one stale "bb" record.
    const content =
        \\{"suite":"aa","file":"src/x.zig","start":9,"end":10,"original":"<","replacement":"<=","outcome":"survived"}
        \\{"suite":"bb","file":"src/x.zig","start":9,"end":10,"original":"<","replacement":"<=","outcome":"killed"}
        \\{"suite":"aa","file":"src/y.zig","start":3,"end":4,"original":">","replacement":">=","outcome":"killed"}
        \\{"suite":"aa","file":"src/x.zig","start":9,"end":10,"original":"<","replacement":"<=","outcome":"killed"}
    ;
    const loaded = try buildMap(a, content, "aa");
    const kx = try identityKey(a, "src/x.zig", 9, 10, "<", "<=");
    const ky = try identityKey(a, "src/y.zig", 3, 4, ">", ">=");
    // Reuse map: x dedups to the latest (killed), y is killed, stale bb is gone.
    try testing.expectEqual(Outcome.killed, loaded.map.get(kx).?);
    try testing.expectEqual(Outcome.killed, loaded.map.get(ky).?);
    try testing.expectEqual(@as(usize, 2), loaded.map.count());
    // Compaction: exactly the two deduped current-suite records, no stale suite.
    var lines = std.mem.tokenizeScalar(u8, loaded.compacted, '\n');
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.indexOf(u8, loaded.compacted, "\"bb\"") == null);
}

// spec: Mutation Testing - Reuses appended outcomes on load and bypasses the cache under refresh

test "append then load round-trips outcomes and bypass returns an empty map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/mutant-cache-proj";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("mutate cache cleanup: {s}", .{@errorName(e)});

    const m1 = mk("src/x.zig", 9, 10, "<", "<=");
    const m2 = mk("src/x.zig", 20, 21, ">", ">=");
    append(a, dir, "aa", m1, .survived);
    append(a, dir, "aa", m2, .killed);

    const map = load(a, dir, "aa", .reuse);
    try testing.expectEqual(Outcome.survived, map.get(try keyFor(a, m1)).?);
    try testing.expectEqual(Outcome.killed, map.get(try keyFor(a, m2)).?);

    // Under a refresh (.fresh), load returns an empty map without reusing what's
    // on disk — a fresh ratchet is a fresh measurement.
    const fresh = load(a, dir, "aa", .fresh);
    try testing.expectEqual(@as(usize, 0), fresh.count());
}
