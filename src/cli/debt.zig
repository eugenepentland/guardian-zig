//! `debt` command — a non-gating report (always exits 0) of Guardian's
//! accumulated ratchet debt: per-check baseline violation counts and per-
//! snapshot totals, sorted high-to-low, each with the delta vs the last
//! committed `.guardian/` state when inside a git repo. Makes debt growth a
//! visible decision instead of a side effect.
//!
//! Like spec-init and mutate it is registered but never a gate: run_all's SKIP
//! list and build_helper exclude it from every `all` / build run, so it only
//! executes when invoked directly (`guardian-check debt [dir]`).

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const walk = @import("../walk.zig");
const git = @import("../git.zig");
const ratchet = @import("../ratchet.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;

pub const command_name = "debt";

/// Leading marker of a snapshot/baseline header line (`# guardian-snapshot v…`).
const header_prefix = "#";
/// Path fragment identifying a per-check baseline file under `.guardian/`.
const baselines_marker = "/baselines/";
/// Header of a per-item ratchet (baseline v2) file, whose lines are `<value>
/// <key>` — the count still reads as one-per-line, and its worst offender
/// (highest value) is reported as a note.
const ratchet_header = "# guardian-snapshot v2";

/// How one `.guardian/` file's debt total is derived from its contents.
const Kind = enum {
    /// One unit per non-header line — baselines and pub-api entries.
    lines,
    /// Sum of `key value` counts, skipping magnitude keys (`*_max`).
    counts,
    /// The recorded mutation kill percentage (`score_pct=N`).
    mutation,
};

/// One report line: a source label, its current total, the change vs the
/// committed state (null when git can't supply it), and an optional note (the
/// worst offender for a per-item ratchet file).
const Row = struct {
    label: []const u8,
    count: u64,
    delta: ?i64,
    note: ?[]const u8 = null,
};

/// A recognized snapshot file: its leaf name, report label, and summary kind.
const SnapshotSpec = struct { leaf: []const u8, label: []const u8, kind: Kind };

const snapshot_specs = [_]SnapshotSpec{
    .{ .leaf = "pub-api.txt", .label = "pub-api-surface", .kind = .lines },
    .{ .leaf = "panic-budget.txt", .label = "panic-budget", .kind = .counts },
    .{ .leaf = "int-from-float-budget.txt", .label = "int-from-float-budget", .kind = .counts },
    .{ .leaf = "unsafe-ops-budget.txt", .label = "unsafe-ops-budget", .kind = .counts },
    .{ .leaf = "mutation.txt", .label = "mutation (score %)", .kind = .mutation },
};

/// A `.guardian/` file routed to its report label and summary kind.
const Classified = struct { label: []const u8, kind: Kind };

/// Entry point for the debt command: gathers baseline + snapshot rows, sorts
/// them by count descending, and prints the report. Never gates (exit 0).
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const rows = try collectRows(ctx.allocator, ctx.project_dir);
    sortByCountDesc(rows);
    printReport(ctx.allocator, ctx.project_dir, rows);
}

/// Walks `.guardian/` (minus the cache dir) and turns each recognized file into
/// a Row. Unknown files are skipped. A missing `.guardian/` yields no rows.
fn collectRows(allocator: Allocator, project_dir: []const u8) types.RunError![]Row {
    var rows: std.ArrayList(Row) = .empty;
    var ctx: Collector = .{ .arena = allocator, .project_dir = project_dir, .rows = &rows };
    const guardian_dir = try std.fmt.allocPrint(allocator, "{s}/.guardian", .{project_dir});
    try walk.walkZigFiles(allocator, guardian_dir, .{
        .display_root = ".guardian",
        .extension = "",
        .excludes = &.{"cache"},
    }, .{ .ctx = &ctx, .visit = visit });
    return rows.toOwnedSlice(allocator);
}

/// Per-walk state: the arena, the project dir (for git deltas), and the growing
/// row list.
const Collector = struct {
    arena: Allocator,
    project_dir: []const u8,
    rows: *std.ArrayList(Row),
};

/// Visitor: classify one `.guardian/` file, summarize its current total, attach
/// the git delta, and append a Row. Unrecognized files are ignored.
fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *Collector = @ptrCast(@alignCast(raw_ctx));
    const c = try classify(ctx.arena, entry.rel_path) orelse return;
    const current = summarize(c.kind, entry.content);
    const delta = deltaVsHead(ctx.arena, ctx.project_dir, entry.rel_path, c.kind, current);
    // A clean check (0 violations, unchanged) is not debt — dropping it keeps
    // the report to what's actually accumulated, even when every check has a
    // baseline file (baseline mode writes one per check, most at zero).
    if (reportable(current, delta)) {
        try ctx.rows.append(ctx.arena, .{
            .label = c.label,
            .count = current,
            .delta = delta,
            .note = ratchetNote(ctx.arena, entry.rel_path, entry.content),
        });
    }
}

/// A `worst: <value> <key>` note for a per-item ratchet (v2) baseline, or null
/// for any other file. The count column already reads the key count (one line
/// per key); this adds the single highest-value offender for context.
fn ratchetNote(arena: Allocator, rel_path: []const u8, content: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, rel_path, baselines_marker) == null) return null;
    if (!std.mem.startsWith(u8, content, ratchet_header)) return null;
    const entries = ratchet.parse(arena, content) catch return null;
    const worst = ratchet.maxEntry(entries) orelse return null;
    return std.fmt.allocPrint(arena, "  worst: {d} {s}", .{ worst.value, worst.key }) catch null;
}

/// True when a source is worth listing: it carries debt now, or its committed
/// count changed — so debt paid down to zero still shows (as 0 with a negative
/// delta) while a check that has always been clean is omitted.
fn reportable(count: u64, delta: ?i64) bool {
    return count > 0 or (delta orelse 0) != 0;
}

/// Routes a `.guardian/` path to its report label + summary kind: a baselines/
/// file is labelled by its check name; a known snapshot leaf uses its spec.
/// Returns null for anything else (the cache dir is already excluded).
fn classify(arena: Allocator, rel_path: []const u8) Allocator.Error!?Classified {
    const base = baseName(rel_path);
    if (std.mem.indexOf(u8, rel_path, baselines_marker) != null) {
        return .{ .label = try arena.dupe(u8, stripTxt(base)), .kind = .lines };
    }
    for (snapshot_specs) |s| {
        if (std.mem.eql(u8, base, s.leaf)) return .{ .label = s.label, .kind = s.kind };
    }
    return null;
}

/// Current-minus-committed total for `rel_path`, or null when the committed
/// state can't be read (outside git, untracked file, git missing).
fn deltaVsHead(
    arena: Allocator,
    project_dir: []const u8,
    rel_path: []const u8,
    kind: Kind,
    current: u64,
) ?i64 {
    const head = git.fileAtHead(arena, project_dir, rel_path) orelse return null;
    const before = summarize(kind, head);
    return @as(i64, @intCast(current)) - @as(i64, @intCast(before));
}

/// Reduces a file's contents to its single debt total per `kind`.
fn summarize(kind: Kind, content: []const u8) u64 {
    return switch (kind) {
        .lines => countLines(content),
        .counts => sumCounts(content),
        .mutation => scoreOf(content),
    };
}

/// Counts content lines that are neither blank nor the snapshot header — one
/// baselined violation / pub-api entry per line.
fn countLines(content: []const u8) u64 {
    var n: u64 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (!isSkippable(line)) n += 1;
    }
    return n;
}

/// Sums the integer value of each `key value` line, skipping magnitude keys
/// (those ending in `_max`, e.g. panic-budget's comptime_max) so a large cap
/// magnitude doesn't swamp the count-of-occurrences it reports alongside.
fn sumCounts(content: []const u8) u64 {
    var total: u64 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (isSkippable(line)) continue;
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.endsWith(u8, line[0..sp], "_max")) continue;
        const val = std.mem.trim(u8, line[sp + 1 ..], &std.ascii.whitespace);
        total += std.fmt.parseInt(u64, val, 10) catch 0;
    }
    return total;
}

/// Reads the mutation kill percentage from a `score_pct=N` line; 0 when absent.
/// The key is a function-local const: mutate.zig owns the write format, and the
/// debt reader stays intentionally loosely coupled to it (no shared file-scope
/// const, which would read as duplicated knowledge across the two files).
fn scoreOf(content: []const u8) u64 {
    const score_key = "score_pct=";
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, score_key)) {
            return std.fmt.parseInt(u64, trimmed[score_key.len..], 10) catch 0;
        }
    }
    return 0;
}

/// True for a blank line or a snapshot header line (never a real entry).
fn isSkippable(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    return trimmed.len == 0 or std.mem.startsWith(u8, trimmed, header_prefix);
}

/// The final path segment after the last `/` (the whole string if none).
fn baseName(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

/// Drops a trailing `.txt` so `magic-number.txt` reads as `magic-number`.
fn stripTxt(name: []const u8) []const u8 {
    const suffix = ".txt";
    if (std.mem.endsWith(u8, name, suffix)) return name[0 .. name.len - suffix.len];
    return name;
}

/// Sorts rows by count descending, breaking ties by label for stable output.
fn sortByCountDesc(rows: []Row) void {
    std.mem.sort(Row, rows, {}, moreThan);
}

/// Orders rows by descending count, then ascending label.
fn moreThan(_: void, a: Row, b: Row) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.label, b.label) == .lt;
}

/// Prints the sorted report, or a friendly note when nothing is recorded.
fn printReport(allocator: Allocator, project_dir: []const u8, rows: []const Row) void {
    if (rows.len == 0) {
        reporter.ok("debt: nothing recorded under {s}/.guardian", .{project_dir});
        return;
    }
    reporter.ok("debt report — {d} tracked source(s), sorted by count (delta vs HEAD)", .{rows.len});
    for (rows) |r| {
        print("  {s:<28} {d:>6}{s}{s}\n", .{ r.label, r.count, deltaText(allocator, r.delta), r.note orelse "" });
    }
}

/// Renders a delta suffix: `(+N vs HEAD)` / `(-N vs HEAD)`, `(unchanged)` at
/// zero, and empty when git couldn't supply a committed baseline (null).
fn deltaText(allocator: Allocator, delta: ?i64) []const u8 {
    const d = delta orelse return "";
    if (d == 0) return "  (unchanged)";
    const sign: u8 = if (d > 0) '+' else '-';
    return std.fmt.allocPrint(allocator, "  ({c}{d} vs HEAD)", .{ sign, @abs(d) }) catch "";
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Debt - Counts non-header lines for baseline and pub-api debt

test "countLines ignores the header and blank lines" {
    const content =
        "# guardian-snapshot v1\n" ++
        "src/a.zig: fn foo is 210 lines (cap 120)\n" ++
        "\n" ++
        "src/b.zig: fn bar is 140 lines (cap 120)\n";
    try testing.expectEqual(@as(u64, 2), countLines(content));
}

// spec: Debt - Sums snapshot counts while ignoring magnitude keys

test "sumCounts adds occurrence counts but skips *_max magnitudes" {
    const content =
        "# guardian-snapshot v1\n" ++
        "panics 3\n" ++
        "unreachables 2\n" ++
        "comptime_calls 1\n" ++
        "comptime_max 40000\n";
    // 3 + 2 + 1 = 6; the 40000 magnitude is excluded.
    try testing.expectEqual(@as(u64, 6), sumCounts(content));
}

// spec: Debt - Reads the mutation kill score from its snapshot

test "scoreOf reads the score_pct line" {
    try testing.expectEqual(@as(u64, 87), scoreOf("# guardian-snapshot v1\nscore_pct=87\n"));
    try testing.expectEqual(@as(u64, 0), scoreOf("# guardian-snapshot v1\n"));
}

// spec: Debt - Classifies each .guardian file into a labelled debt source

test "classify labels baselines by check name and snapshots by spec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = (try classify(a, ".guardian/baselines/spec.txt")).?;
    try testing.expectEqualStrings("spec", base.label);
    try testing.expect(base.kind == .lines);

    const snap = (try classify(a, ".guardian/pub-api.txt")).?;
    try testing.expectEqualStrings("pub-api-surface", snap.label);

    const counts = (try classify(a, ".guardian/panic-budget.txt")).?;
    try testing.expect(counts.kind == .counts);

    // An unrecognized file is dropped.
    try testing.expect((try classify(a, ".guardian/notes.md")) == null);
}

// spec: Debt - Sorts the debt rows by count descending

test "sortByCountDesc orders by count then label" {
    var rows = [_]Row{
        .{ .label = "b", .count = 5, .delta = null },
        .{ .label = "a", .count = 130, .delta = null },
        .{ .label = "c", .count = 130, .delta = null },
    };
    sortByCountDesc(&rows);
    try testing.expectEqualStrings("a", rows[0].label); // 130, label a first
    try testing.expectEqualStrings("c", rows[1].label); // 130, label c
    try testing.expectEqualStrings("b", rows[2].label); // 5 last
}

// spec: Debt - Notes a per-item ratchet's worst offender

test "ratchetNote reports the worst offender of a v2 baseline only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v2 = "# guardian-snapshot v2\n95 src/a.zig|f\n130 src/b.zig|g\n";
    try testing.expectEqualStrings(
        "  worst: 130 src/b.zig|g",
        ratchetNote(a, ".guardian/baselines/function-length.txt", v2).?,
    );
    // A v1 text baseline is not a ratchet — no note.
    try testing.expect(ratchetNote(a, ".guardian/baselines/spec.txt", "# guardian-snapshot v1\nfoo\n") == null);
    // A non-baseline file (a snapshot) is not a ratchet either.
    try testing.expect(ratchetNote(a, ".guardian/pub-api.txt", v2) == null);
}

// spec: Debt - Formats a committed-state delta and omits it when unchanged or absent

test "deltaText signs a change, marks unchanged, and blanks a null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("  (+5 vs HEAD)", deltaText(a, 5));
    try testing.expectEqualStrings("  (-2 vs HEAD)", deltaText(a, -2));
    try testing.expectEqualStrings("  (unchanged)", deltaText(a, 0));
    try testing.expectEqualStrings("", deltaText(a, null));
}

// spec: Debt - Omits a clean source with zero debt and no committed change

test "reportable keeps debt and paid-down sources but drops always-clean ones" {
    try testing.expect(reportable(3, null)); // carries debt now
    try testing.expect(reportable(0, -5)); // paid down to zero — worth showing
    try testing.expect(reportable(2, 0)); // debt held steady
    try testing.expect(!reportable(0, null)); // always clean, no git delta
    try testing.expect(!reportable(0, 0)); // clean and unchanged
}
