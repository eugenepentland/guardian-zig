//! What shape a `.guardian/` metadata file is in, and how to read its rows.
//!
//! Four line formats live under `.guardian/`, and the version header alone does
//! not separate them (`panic-budget.txt` is a v2 counter file, `pub-api.txt` is
//! a v2 signature list, a ratchet baseline is v2 `<value> <key>`). Detection is
//! therefore the file's own header PLUS its row shape, with the repo-relative
//! path as a hint when the caller has one — a git merge driver is handed
//! temporary files, so the name is never guaranteed.
//!
//! Everything here is pure: bytes in, rows or a located `Problem` out. The
//! three-way rules live in `three_way.zig`, the command in `cli/merge_file.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const snapshot = @import("../snapshot.zig");
const baseline = @import("../baseline.zig");
const ratchet = @import("../ratchet.zig");

/// The `.guardian/` artifact formats, i.e. how a file's rows must be combined.
pub const Kind = enum {
    /// v3 identity baseline: `<check>|<identity>` rows (legacy files carry the
    /// 2-field `<check>|<Section: message>` spelling; both are opaque here).
    identity_baseline,
    /// v2 per-item ratchet: `<ceiling> <file>|<item>` rows.
    ratchet,
    /// v1/v2 budget counters: `<name> <count>` rows.
    counters,
    /// v2 public API surface: `<path>::<decl> | <signature>` rows.
    pub_api,
    /// No safe automatic resolution: the mutation cohort, the benchmark ledger,
    /// mismatched headers, or a format this Guardian does not know.
    unmergeable,
};

/// Why a file could not be read as an artifact, and where.
pub const ProblemKind = enum { conflict_markers, missing_header, malformed_row };

/// A located parse failure: the row that broke, numbered from 1 as an editor
/// counts, so a diagnostic can name `<path>:<line>`.
pub const Problem = struct {
    kind: ProblemKind,
    line: usize,
    text: []const u8,
};

/// One parsed metadata file: its header version, its entry rows in file order,
/// and whether a previous merge left it marked for regeneration.
pub const File = struct {
    version: u32,
    rows: []const []const u8,
    pending_regen: bool,

    /// The absent side of a three-way merge (git hands the driver an empty file
    /// for a path both branches added). Version 0 means "no header of my own".
    pub const empty: File = .{ .version = 0, .rows = &.{}, .pending_regen = false };
};

/// Either a parsed file or the located reason it could not be parsed.
pub const Parsed = union(enum) {
    ok: File,
    problem: Problem,

    /// The parsed file, or the empty one when parsing failed. Callers that
    /// report the failure separately (via `failure`) use this to keep going.
    pub fn value(self: Parsed) File {
        return switch (self) {
            .ok => |f| f,
            .problem => File.empty,
        };
    }

    /// The located failure, or null when the file parsed.
    pub fn failure(self: Parsed) ?Problem {
        return switch (self) {
            .ok => null,
            .problem => |p| p,
        };
    }
};

/// Splits `content` into header + entry rows. Blank and comment rows are
/// skipped (the regenerate marker is remembered rather than dropped); a
/// conflict marker or a missing header is a located `Problem`. Empty content is
/// `File.empty`, not a problem — that is git's spelling of "no base".
pub fn parse(arena: Allocator, content: []const u8) Allocator.Error!Parsed {
    if (std.mem.trim(u8, content, &std.ascii.whitespace).len == 0) return .{ .ok = File.empty };
    var rows: std.ArrayList([]const u8) = .empty;
    var version: ?u32 = null;
    var pending = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (snapshot.isConflictMarker(line))
            return .{ .problem = .{ .kind = .conflict_markers, .line = line_no, .text = line } };
        if (line.len == 0) continue;
        if (snapshot.isComment(line)) {
            if (std.mem.startsWith(u8, line, snapshot.regen_marker)) pending = true;
            if (version == null) version = versionOf(line);
            continue;
        }
        if (version == null)
            return .{ .problem = .{ .kind = .missing_header, .line = line_no, .text = line } };
        try rows.append(arena, line);
    }
    const v = version orelse
        return .{ .problem = .{ .kind = .missing_header, .line = 1, .text = "" } };
    return .{ .ok = .{ .version = v, .rows = try rows.toOwnedSlice(arena), .pending_regen = pending } };
}

/// The version a `# guardian-snapshot v<N>` header declares, or null for any
/// other comment row.
fn versionOf(line: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, line, snapshot.magic_prefix)) return null;
    return std.fmt.parseInt(u32, line[snapshot.magic_prefix.len..], 10) catch null;
}

/// The format of a file at `path_hint` whose header says `version` and whose
/// rows (all three merge sides pooled, so an empty side cannot mislead) look
/// like `rows`. The path decides when it is known, because it is the only
/// signal that separates two formats sharing a version; otherwise the row shape
/// does, and anything unrecognized is `.unmergeable` rather than a guess.
pub fn classify(path_hint: ?[]const u8, version: u32, rows: []const []const u8) Kind {
    if (version == 0) return .unmergeable;
    if (path_hint) |p| {
        if (kindFromPath(p, version)) |k| return k;
    }
    return kindFromRows(version, rows);
}

/// The format implied by a repo-relative metadata path, or null when the path
/// says nothing (an unrecognized leaf under `.guardian/`).
fn kindFromPath(path: []const u8, version: u32) ?Kind {
    // The DIRECTORY decides first. A budget check owns two differently-shaped
    // files — `.guardian/<check>-budget.txt` counters and its
    // `.guardian/baselines/<check>-budget.txt` identity baseline — so reading
    // the leaf before the directory calls the second one a counter file and
    // flags every row in it (16 false findings on eda, caught on real metadata).
    if (std.mem.indexOf(u8, path, "baselines/") != null) return baselineKind(version);
    const leaf = std.fs.path.basename(path);
    if (std.mem.eql(u8, leaf, "pub-api.txt")) return .pub_api;
    if (std.mem.eql(u8, leaf, "mutation.txt")) return .unmergeable;
    if (std.mem.eql(u8, leaf, "benchmarks.txt")) return .unmergeable;
    // Every budget check writes `<name>-budget.txt` counters, and naming them by
    // suffix keeps a file with ONE broken row classified (and therefore
    // reported) instead of falling through to "unknown format".
    if (std.mem.endsWith(u8, leaf, "-budget.txt")) return .counters;
    return null;
}

/// The format of a file under `.guardian/baselines/`: v2 is a per-item ratchet,
/// while v3 identities and the v1 rendered-text baseline they replaced both
/// merge as opaque whole rows (a v1 file re-keys itself on the next run).
fn baselineKind(version: u32) ?Kind {
    if (version == ratchet.version) return .ratchet;
    if (version == baseline.version or version == baseline.legacy_version) return .identity_baseline;
    return null;
}

/// The format implied by the pooled row shapes alone — the path-less fallback a
/// merge driver usually runs on.
fn kindFromRows(version: u32, rows: []const []const u8) Kind {
    if (rows.len == 0) return .counters; // nothing to merge; any kind renders the header
    if (allRows(rows, isCounterRow)) return .counters;
    if (version == baseline.version) return .identity_baseline;
    if (allRows(rows, isPubApiRow)) return .pub_api;
    if (allRows(rows, isRatchetRow)) return .ratchet;
    return .unmergeable;
}

/// True when every row satisfies `pred` (vacuously true for no rows).
fn allRows(rows: []const []const u8, pred: *const fn ([]const u8) bool) bool {
    for (rows) |r| {
        if (!pred(r)) return false;
    }
    return true;
}

/// True for a `<name> <count>` budget row: exactly two fields, the second an
/// integer. Disjoint from `isRatchetRow`, which puts the integer FIRST.
pub fn isCounterRow(row: []const u8) bool {
    const sp = std.mem.indexOfScalar(u8, row, ' ') orelse return false;
    const name = row[0..sp];
    const count = row[sp + 1 ..];
    if (name.len == 0 or count.len == 0) return false;
    if (std.mem.indexOfScalar(u8, count, ' ') != null) return false;
    _ = std.fmt.parseInt(u64, count, 10) catch return false;
    // A leading integer would make this a ratchet row too; keep them disjoint.
    _ = std.fmt.parseInt(u64, name, 10) catch return true;
    return false;
}

/// True for a `<ceiling> <key>` ratchet row: an integer, a space, a key.
pub fn isRatchetRow(row: []const u8) bool {
    return ratchet.decodeLine(row) != null;
}

/// True for a `<path>::<decl> | <signature>` public-API row. Either half
/// identifies it: a `value`/`type` entry carries the `::` but no signature
/// column, and both spellings are absent from every other format's rows.
pub fn isPubApiRow(row: []const u8) bool {
    if (std.mem.indexOf(u8, row, " | ") != null) return true;
    return std.mem.indexOf(u8, row, "::") != null;
}

/// The rows of `content` that do not parse as `kind` expects — the "genuinely
/// malformed" set, each carrying its true line number in the file (the walk is
/// re-run over the bytes so comments and blanks cannot shift the count).
/// Formats whose rows are opaque text (identity baselines, pub-api, and any
/// unmergeable file) have nothing to validate and never report a row.
pub fn malformedRows(arena: Allocator, content: []const u8, kind: Kind) Allocator.Error![]const Problem {
    const pred = rowPredicate(kind) orelse return &.{};
    var out: std.ArrayList(Problem) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line.len == 0 or snapshot.isComment(line) or pred(line)) continue;
        try out.append(arena, .{ .kind = .malformed_row, .line = line_no, .text = line });
    }
    return out.toOwnedSlice(arena);
}

/// The formats whose rows have a checkable shape, and the predicate that checks
/// one. A table rather than a switch: `cli/merge_file.zig` owns the one
/// exhaustive `Kind` switch (which merge rule to apply), and a second one here
/// would be the same dispatch written twice.
const row_validators = [_]struct { kind: Kind, pred: *const fn ([]const u8) bool }{
    .{ .kind = .counters, .pred = isCounterRow },
    .{ .kind = .ratchet, .pred = isRatchetRow },
};

/// The row validator for a structured format, or null when its rows are opaque.
fn rowPredicate(kind: Kind) ?*const fn ([]const u8) bool {
    for (row_validators) |v| {
        if (v.kind == kind) return v.pred;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Merge - Detects each metadata format from its header, rows, and path

test "classify separates the four artifact formats" {
    // A v2 header covers three different formats; the row shape splits them.
    const counters = [_][]const u8{ "@alignCast 68", "@bitCast 0" };
    const ratchets = [_][]const u8{ "130 src/a.zig|f", "10274 src/b.zig" };
    const api = [_][]const u8{"src/a.zig::f | fn f() void"};
    const identities = [_][]const u8{"spec|unlinked tag: X in ./src/a.zig"};
    try testing.expect(classify(null, 2, &counters) == .counters);
    try testing.expect(classify(null, 2, &ratchets) == .ratchet);
    try testing.expect(classify(null, 2, &api) == .pub_api);
    try testing.expect(classify(null, 3, &identities) == .identity_baseline);

    // The path wins when it is known: pub-api.txt is a surface list even though
    // its rows would also pass as free text, and the ledgers never auto-merge.
    try testing.expect(classify(".guardian/pub-api.txt", 2, &api) == .pub_api);
    try testing.expect(classify(".guardian/mutation.txt", 2, &counters) == .unmergeable);
    try testing.expect(classify(".guardian/benchmarks.txt", 1, &.{}) == .unmergeable);
    try testing.expect(classify(".guardian/baselines/file-size.txt", 2, &.{}) == .ratchet);
    try testing.expect(classify(".guardian/baselines/spec.txt", 3, &.{}) == .identity_baseline);

    // A budget check owns BOTH a counter snapshot and an identity baseline, and
    // they share a leaf name — the directory has to win, or every row of the
    // baseline reads as a broken counter.
    try testing.expect(classify(".guardian/int-from-float-budget.txt", 1, &counters) == .counters);
    const budget_ids = [_][]const u8{"int-from-float-budget|src/a.zig|unguarded @intFromFloat"};
    try testing.expect(classify(".guardian/baselines/int-from-float-budget.txt", 3, &budget_ids) == .identity_baseline);

    // An unknown shape, and a file with no header at all, are never guessed at.
    const odd = [_][]const u8{"cohort=25bf32a3d7cf83d9"};
    try testing.expect(classify(null, 2, &odd) == .unmergeable);
    try testing.expect(classify(null, 0, &counters) == .unmergeable);
}

// spec: Merge - Tells the row shapes of the four formats apart

test "the row predicates stay disjoint across formats" {
    // The two integer-bearing formats differ only in WHICH end the number is on,
    // so each must reject the other's rows or detection collapses.
    try testing.expect(isCounterRow("@alignCast 68"));
    try testing.expect(!isCounterRow("130 src/a.zig|f"));
    try testing.expect(isRatchetRow("130 src/a.zig|f"));
    try testing.expect(!isRatchetRow("@alignCast 68"));
    // Neither shape claims a surface row, and a surface row is recognized by
    // its signature column or its `::` alone (a value entry has no signature).
    try testing.expect(isPubApiRow("src/a.zig::f | fn f() void"));
    try testing.expect(isPubApiRow("src/a.zig::version value"));
    try testing.expect(!isPubApiRow("@alignCast 68"));
    try testing.expect(!isCounterRow("src/a.zig::f | fn f() void"));
}

// spec: Merge - Parses a metadata file into version, rows, and merge state

test "parse reads rows, remembers the regenerate marker, and locates failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const marked = "# guardian-snapshot v1\n" ++ snapshot.regen_marker ++ " (X)\n@alignCast 68\n";
    const file = (try parse(a, marked)).value();
    try testing.expectEqual(@as(u32, 1), file.version);
    try testing.expectEqual(@as(usize, 1), file.rows.len);
    try testing.expect(file.pending_regen);

    // git's "no base" side is empty, not broken.
    try testing.expectEqual(@as(u32, 0), (try parse(a, "")).value().version);
    try testing.expect((try parse(a, "")).failure() == null);

    // An unresolved conflict and a headerless file are located problems.
    const conflicted = try parse(a, "# guardian-snapshot v2\napple\n<<<<<<< HEAD\nbanana\n");
    try testing.expect(conflicted.failure().?.kind == .conflict_markers);
    try testing.expectEqual(@as(usize, 3), conflicted.failure().?.line);
    const headerless = try parse(a, "apple\nbanana\n");
    try testing.expect(headerless.failure().?.kind == .missing_header);
    try testing.expectEqual(@as(usize, 1), headerless.failure().?.line);
    // A failed parse still yields a usable (empty) file for callers that report
    // the problem separately.
    try testing.expectEqual(@as(usize, 0), headerless.value().rows.len);
}

// spec: Merge - Reports a structured row that does not parse as its format

test "malformedRows names the offending line of a structured file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content = "# guardian-snapshot v1\n@alignCast 68\ngarbage row with words\n@bitCast 0\n";
    const bad = try malformedRows(a, content, .counters);
    try testing.expectEqual(@as(usize, 1), bad.len);
    try testing.expectEqual(@as(usize, 3), bad[0].line);
    try testing.expectEqualStrings("garbage row with words", bad[0].text);

    // The same rows are opaque text to an identity baseline, so nothing is bad.
    try testing.expectEqual(@as(usize, 0), (try malformedRows(a, content, .identity_baseline)).len);
}
