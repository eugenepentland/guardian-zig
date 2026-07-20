//! `debt` command — a non-gating report of Guardian's
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
const file_size = @import("../checks/file_size.zig");

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
/// Lines per KLOC — the denominator scale for the assert-density metric.
const lines_per_kloc: u64 = 1000;

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
/// them by count descending, and prints the report. `--assert-density` adds the
/// informational per-module appendix. Reporting never gates; invalid filters
/// or a failed explicitly-confirmed prune return a maintenance error.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    if (ctx.check_filter) |name| {
        if (ctx.command_exists) |exists| {
            if (!exists(name)) {
                reporter.fail("debt: unknown check for --check: {s}", .{name});
                return error.CheckFailed;
            }
        }
    }
    if (ctx.prune_stale) try pruneStale(ctx);
    const all_rows = try collectRows(ctx.allocator, ctx.project_dir);
    sortByCountDesc(all_rows);
    const rows = try filterRows(ctx.allocator, all_rows, ctx.check_filter);
    const density = if (ctx.assert_density)
        try collectDensityRows(ctx.allocator, ctx.project_dir)
    else
        &.{};
    if (ctx.json) {
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, JsonReport{
            .project_dir = ctx.project_dir,
            .rows = rows,
            .assert_density = density,
        }, .{});
        print("{s}\n", .{json});
    } else {
        printReport(ctx.allocator, ctx.project_dir, rows);
        try reportFileSizes(ctx);
        if (ctx.assert_density) printDensityReport(density);
    }
}

/// Prints the file-size section: every source file over the recommended line
/// limit, its production-line count against both the recommended and hard
/// limits — so an "at the recommended cap" file reads as advisory, not blocked.
fn reportFileSizes(ctx: *types.RunCtx) types.RunError!void {
    const warning = ctx.cfg.max_file_lines;
    const hard = ctx.cfg.hard_max_file_lines;
    const raw = try collectFileSizeRows(ctx.allocator, ctx.project_dir, ctx.cfg.file_size_exclude);
    const rows = try fileSizeReport(ctx.allocator, raw, warning);
    printFileSizeReport(rows, warning, hard);
}

const JsonReport = struct {
    project_dir: []const u8,
    rows: []const Row,
    assert_density: []const DensityRow,
};

fn filterRows(allocator: Allocator, rows: []const Row, filter: ?[]const u8) Allocator.Error![]const Row {
    const name = filter orelse return rows;
    var out: std.ArrayList(Row) = .empty;
    for (rows) |row| if (rowMatches(row, name)) try out.append(allocator, row);
    return out.toOwnedSlice(allocator);
}

fn rowMatches(row: Row, check_name: []const u8) bool {
    if (std.mem.eql(u8, row.label, check_name)) return true;
    return std.mem.eql(u8, check_name, "mutate") and std.mem.eql(u8, row.label, "mutation (score %)");
}

/// Lists obsolete per-check baseline files, deleting them only when the user
/// supplied both `--prune-stale` and `--yes`.
fn pruneStale(ctx: *types.RunCtx) types.RunError!void {
    const exists = ctx.command_exists orelse {
        reporter.fail("debt: registry unavailable; stale baselines were not pruned", .{});
        return error.CheckFailed;
    };
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/baselines", .{ctx.project_dir});
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            reporter.ok("debt: no baseline directory to prune", .{});
            return;
        },
        else => {
            reporter.fail("debt: cannot inspect {s}: {s}", .{ dir_path, @errorName(e) });
            return error.CheckFailed;
        },
    };
    defer dir.close();
    var stale: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next() catch |e| {
        reporter.fail("debt: cannot enumerate {s}: {s}", .{ dir_path, @errorName(e) });
        return error.CheckFailed;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const check_name = entry.name[0 .. entry.name.len - ".txt".len];
        if (!exists(check_name)) try stale.append(ctx.allocator, try ctx.allocator.dupe(u8, entry.name));
    }
    if (stale.items.len == 0) {
        reporter.ok("debt: no stale baseline files", .{});
        return;
    }
    std.mem.sort([]const u8, stale.items, {}, stringLessThan);
    for (stale.items) |leaf| {
        const full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ dir_path, leaf });
        if (!mutationConfirmed(ctx.prune_stale, ctx.confirm)) {
            print("  would prune: {s}\n", .{full});
            continue;
        }
        std.fs.cwd().deleteFile(full) catch |e| {
            reporter.fail("debt: failed to prune {s}: {s}", .{ full, @errorName(e) });
            return error.CheckFailed;
        };
        print("  pruned: {s}\n", .{full});
    }
    if (!mutationConfirmed(ctx.prune_stale, ctx.confirm)) {
        reporter.ok("debt prune is a dry run; add --yes to delete {d} file(s)", .{stale.items.len});
    }
}

fn mutationConfirmed(prune: bool, confirm: bool) bool {
    return prune and confirm;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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
fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
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
    // Best-effort debt delta: any failure (OOM or git-unavailable) just omits it.
    const head = (git.fileAtHead(arena, project_dir, rel_path) catch return null) orelse return null;
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

// ── File size (informational) ───────────────────────────────────────────
//
// The file-size check gates on a generous *hard* limit and only warns at the
// *recommended* limit, but a warning never lands in `.guardian/` — so debt
// (which reads `.guardian/`) never mentioned file size, and an agent could
// mistake an at-recommended-cap file for one that cannot grow. This section
// walks the source tree and lists each file's production-line count against
// both limits, making the advisory-vs-hard distinction concrete.

/// One source file's production-line count for the file-size debt section.
const FileSizeRow = struct { file: []const u8, lines: u32 };

/// Walk state: the arena and the growing row list.
const FileSizeCtx = struct {
    arena: Allocator,
    rows: *std.ArrayList(FileSizeRow),
};

/// Visitor: record one source file's production (non-test) line count.
fn fileSizeVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const ctx: *FileSizeCtx = @ptrCast(@alignCast(raw_ctx));
    const lines = try file_size.codeLines(entry.content);
    try ctx.rows.append(ctx.arena, .{ .file = try ctx.arena.dupe(u8, entry.rel_path), .lines = lines });
}

/// Walks `<project_dir>/src` and `/test`, returning every file's production
/// line count (before the recommended-limit filter, applied by `fileSizeReport`).
fn collectFileSizeRows(
    arena: Allocator,
    project_dir: []const u8,
    excludes: []const []const u8,
) types.RunError![]FileSizeRow {
    var rows: std.ArrayList(FileSizeRow) = .empty;
    var ctx: FileSizeCtx = .{ .arena = arena, .rows = &rows };
    for ([_][]const u8{ "src", "test" }) |dir| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, dir });
        const opts: walk.WalkOpts = .{ .display_root = dir, .excludes = excludes };
        try walk.walkZigFiles(arena, path, opts, .{ .ctx = &ctx, .visit = fileSizeVisit });
    }
    return rows.toOwnedSlice(arena);
}

/// The pure core of the section: keep only files over the recommended limit,
/// largest first (ties broken by path). The walk supplies `all`.
fn fileSizeReport(arena: Allocator, all: []const FileSizeRow, warning: u32) Allocator.Error![]FileSizeRow {
    var out: std.ArrayList(FileSizeRow) = .empty;
    for (all) |r| if (r.lines > warning) try out.append(arena, r);
    const slice = try out.toOwnedSlice(arena);
    std.mem.sort(FileSizeRow, slice, {}, fileSizeMoreThan);
    return slice;
}

/// Orders rows by descending line count, then ascending path for stable output.
fn fileSizeMoreThan(_: void, a: FileSizeRow, b: FileSizeRow) bool {
    if (a.lines != b.lines) return a.lines > b.lines;
    return std.mem.order(u8, a.file, b.file) == .lt;
}

/// Prints the file-size section, or nothing when every file is within the
/// recommended limit.
fn printFileSizeReport(rows: []const FileSizeRow, warning: u32, hard: u32) void {
    if (rows.len == 0) return;
    reporter.ok(
        "file size — files over the {d} recommended line limit ({d} hard limit blocks; recommended only warns)",
        .{ warning, hard },
    );
    for (rows) |r| {
        print("  {s:<40} {d:>6} code lines   (recommended {d}, hard {d})\n", .{ r.file, r.lines, warning, hard });
    }
}

// ── Assert density (informational) ──────────────────────────────────────
//
// A non-gating companion to the debt table: assert calls per KLOC per top-level
// src/ module, sorted ascending so the most assert-starved modules surface
// first. It answers "where are invariants documented in prose but unchecked?"
// without ever failing the build — placement is a human judgment call, this
// only measures the current state (cf. the Zig core team's ~4 asserts/KLOC).

/// One module's assert density: its raw call and line counts (the per-KLOC rate
/// is derived at print time from these).
const DensityRow = struct { module: []const u8, asserts: u64, lines: u64 };

/// Per-module running totals during the src/ walk.
const Tally = struct { asserts: u64 = 0, lines: u64 = 0 };

/// Walk state: the arena and the module → totals map.
const DensityCtx = struct {
    arena: Allocator,
    tallies: *std.StringHashMapUnmanaged(Tally),
};

/// The top-level src/ module of `rel_path`: the first path segment under `src/`
/// (a subdir name like `ast`, or a loose file name like `snapshot.zig`) — the
/// same top-level structure the project's module layout is organized around.
fn moduleOf(rel_path: []const u8) []const u8 {
    const prefix = "src/";
    const rest = if (std.mem.startsWith(u8, rel_path, prefix)) rel_path[prefix.len..] else rel_path;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return rest;
    return rest[0..slash];
}

/// Counts real `assert(` call sites in `content` by tokenizing: an `assert`
/// identifier immediately followed by `(`. Tokenizing (not substring matching)
/// means an `assert(` inside a string or comment is not miscounted as a call.
fn countAssertCalls(arena: Allocator, content: []const u8) Allocator.Error!u64 {
    const z = try arena.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var count: u64 = 0;
    var prev_is_assert = false;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (prev_is_assert and t.tag == .l_paren) count += 1;
        prev_is_assert = t.tag == .identifier and std.mem.eql(u8, z[t.loc.start..t.loc.end], "assert");
    }
    return count;
}

/// Physical line count of `content` (newline terminators), the KLOC denominator.
fn physicalLines(content: []const u8) u64 {
    var n: u64 = 0;
    for (content) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Assert calls per KLOC for one module (0 when it has no lines).
fn perKloc(asserts: u64, lines: u64) u64 {
    if (lines == 0) return 0;
    return asserts * lines_per_kloc / lines;
}

/// Visitor: fold one src/ file's assert-call and line counts into its module.
fn densityVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const ctx: *DensityCtx = @ptrCast(@alignCast(raw_ctx));
    const gop = try ctx.tallies.getOrPut(ctx.arena, moduleOf(entry.rel_path));
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.asserts += try countAssertCalls(ctx.arena, entry.content);
    gop.value_ptr.lines += physicalLines(entry.content);
}

/// Walks `<project_dir>/src`, tallies assert-call density per top-level module,
/// and returns the rows sorted ascending (sparsest first).
fn collectDensityRows(arena: Allocator, project_dir: []const u8) types.RunError![]DensityRow {
    var tallies: std.StringHashMapUnmanaged(Tally) = .empty;
    var ctx: DensityCtx = .{ .arena = arena, .tallies = &tallies };
    const src_path = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    try walk.walkZigFiles(arena, src_path, .{ .display_root = "src" }, .{ .ctx = &ctx, .visit = densityVisit });

    var rows: std.ArrayList(DensityRow) = .empty;
    var it = tallies.iterator();
    while (it.next()) |e| {
        try rows.append(arena, .{ .module = e.key_ptr.*, .asserts = e.value_ptr.asserts, .lines = e.value_ptr.lines });
    }
    const slice = try rows.toOwnedSlice(arena);
    sortByDensityAsc(slice);
    return slice;
}

/// Sorts rows ascending by assert density (sparsest module first).
fn sortByDensityAsc(rows: []DensityRow) void {
    std.mem.sort(DensityRow, rows, {}, densityLessThan);
}

/// Orders rows by ascending asserts/lines (cross-multiplied to stay exact and
/// integer), breaking ties by module name for stable output.
fn densityLessThan(_: void, a: DensityRow, b: DensityRow) bool {
    const lhs = a.asserts * b.lines;
    const rhs = b.asserts * a.lines;
    if (lhs != rhs) return lhs < rhs;
    return std.mem.order(u8, a.module, b.module) == .lt;
}

/// Prints the ascending assert-density table under a clearly non-gating header.
fn printDensityReport(rows: []const DensityRow) void {
    if (rows.len == 0) return;
    reporter.ok("assert density — assert() calls per KLOC by src module, ascending (informational, non-gating)", .{});
    for (rows) |r| {
        print("  {s:<24} {d:>4} /KLOC   ({d} assert(s) / {d} line(s))\n", .{
            r.module, perKloc(r.asserts, r.lines), r.asserts, r.lines,
        });
    }
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

// spec: Maintenance - Debt emits JSON and filters by check

test "debt check filter matches check labels and the mutation command name" {
    try testing.expect(rowMatches(.{ .label = "spec", .count = 1, .delta = null }, "spec"));
    try testing.expect(rowMatches(.{ .label = "mutation (score %)", .count = 80, .delta = null }, "mutate"));
    try testing.expect(!rowMatches(.{ .label = "spec", .count = 1, .delta = null }, "file-size"));
}

// spec: Maintenance - Debt previews stale baseline pruning before explicit confirmation

test "stale pruning requires both prune request and explicit confirmation" {
    try testing.expect(!mutationConfirmed(true, false));
    try testing.expect(!mutationConfirmed(false, true));
    try testing.expect(mutationConfirmed(true, true));
}

// spec: Debt - Reports source files over the recommended size against both limits

test "fileSizeReport keeps files over the recommended limit, largest first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_]FileSizeRow{
        .{ .file = "src/small.zig", .lines = 50 }, // under the recommended limit
        .{ .file = "src/big.zig", .lines = 1200 },
        .{ .file = "src/mid.zig", .lines = 1100 },
    };
    const out = try fileSizeReport(a, &all, 1000);
    // Only the two over the recommended 1000, sorted largest-first.
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("src/big.zig", out[0].file);
    try testing.expectEqual(@as(u32, 1200), out[0].lines);
    try testing.expectEqualStrings("src/mid.zig", out[1].file);
}

// spec: Debt - Reports assert-call density per top-level src module sorted ascending

test "assert density groups modules, counts real calls, and sorts sparsest first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // moduleOf collapses a subdir to its name and keeps a loose file's name.
    try testing.expectEqualStrings("ast", moduleOf("src/ast/parser.zig"));
    try testing.expectEqualStrings("snapshot.zig", moduleOf("src/snapshot.zig"));
    // countAssertCalls tokenizes: the two real calls count, the `assert(` inside
    // a string literal and the one in a line comment do not.
    const src =
        \\fn f(x: u32) void {
        \\    std.debug.assert(x > 0);
        \\    assert(x < 9);
        \\    const s = "assert(nope)"; // assert( here is not a call either
        \\    _ = s;
        \\}
    ;
    try testing.expectEqual(@as(u64, 2), try countAssertCalls(a, src));
    // perKloc is asserts per 1000 lines; ascending sort puts the sparser first.
    try testing.expectEqual(@as(u64, 5), perKloc(2, 400));
    var rows = [_]DensityRow{
        .{ .module = "dense", .asserts = 8, .lines = 1000 },
        .{ .module = "sparse", .asserts = 1, .lines = 1000 },
    };
    sortByDensityAsc(&rows);
    try testing.expectEqualStrings("sparse", rows[0].module);
    try testing.expectEqualStrings("dense", rows[1].module);
}
