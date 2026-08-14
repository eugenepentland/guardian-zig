//! `debt` command — a non-gating report of Guardian's
//! accumulated ratchet debt: per-check baseline violation counts and per-
//! snapshot totals, sorted high-to-low, each with the delta vs the last
//! committed `.guardian/` state when inside a git repo. Makes debt growth a
//! visible decision instead of a side effect.
//!
//! Three properties make the report decidable rather than merely printed.
//! Rows are SPLIT BY WHAT THEY MEASURE: violation debt (lower is better) is not
//! listed beside an API-surface inventory or a mutation SCORE (higher is
//! better), because one sorted column put a 2830-symbol inventory on top of a
//! debt report and read as the worst debt in the tree. The worst-offender
//! column is LABELLED AS THE STORED BASELINE, since it reads like a live
//! measurement and is not — one consumer appended 300 lines to a file and
//! watched the number never move. And `--live` (the `--current` flag under the
//! name the report points at) measures the tree for the pre-flight question the
//! stored numbers cannot answer: what is nearest a limit that would block it.
//!
//! Like spec-init and mutate it is registered but never a gate: run_all's SKIP
//! list and build_helper exclude it from every `all` / build run, so it only
//! executes when invoked directly (`guardian-check debt [dir]`).

const std = @import("std");
const fs = @import("../fs.zig");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const walk = @import("../walk.zig");
const git = @import("../git.zig");
const ratchet = @import("../ratchet.zig");
const debt_current = @import("debt_current.zig");
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

/// What a row's number MEASURES. A single sorted column cannot be read: an
/// inventory and a score are not debt, and mixing them means the top line of a
/// "debt report" is whichever number happens to be biggest.
const RowKind = enum {
    /// Accepted violations — the debt the gate froze. Paying it down is work.
    violation,
    /// A tracked total that is not debt (the public API surface). It moves with
    /// the design, and a bigger number is not a worse one.
    inventory,
    /// A measured quality score, where higher is the good direction.
    score,
    /// A value measured from the tree right now against the limit that would
    /// block it (the `--live` headroom rows). Not accepted debt at all — most
    /// of these items are green — so it is never printed in the debt table;
    /// it exists so a machine reader of the JSON can tell the two apart.
    measurement,
};

/// Which way is better for a row's number, carried explicitly so a machine
/// reader never has to infer it from the label text.
const Direction = enum { lower_better, higher_better, neutral };

/// The row label of the mutation score. Named because the `--check mutate`
/// filter has to map the command name onto it.
const mutation_label = "mutation";

/// The worst entry of a per-item ratchet, split into its parts instead of a
/// preformatted string: `metric` is the frozen value, `file` the source file,
/// and `item` the function or type within it (null for a file-level metric).
/// This is the STORED ceiling, never a live measurement — see `worstText`.
const Worst = struct {
    metric: u64,
    file: []const u8,
    item: ?[]const u8,
};

/// One report line: a source label, what its number measures and which
/// direction is better, the unit it counts in, its current total, the change vs
/// the committed state (null when git can't supply it), and the ratchet's worst
/// stored offender when the source is a per-item ratchet.
const Row = struct {
    label: []const u8,
    kind: RowKind,
    direction: Direction,
    unit: []const u8,
    count: u64,
    delta: ?i64,
    worst: ?Worst = null,
};

/// A recognized snapshot file: its leaf name, report label, how its total is
/// summarized, what that total measures, and the unit it is counted in.
const SnapshotSpec = struct {
    leaf: []const u8,
    label: []const u8,
    kind: Kind,
    row: RowKind,
    unit: []const u8,
};

/// The unit of a baselined violation count — the implicit unit of every
/// `.guardian/baselines/` file.
const violation_unit = "violations";

/// The unit of a budget snapshot: how many times the counted construct appears.
const occurrence_unit = "occurrences";

/// The unit of the pub-api snapshot. It is an inventory of what the API
/// exposes, which is why it is not a debt row however large it gets.
const symbol_unit = "tracked symbols";

/// The unit of the mutation snapshot: a percentage of mutants killed.
const score_unit = "% killed";

const snapshot_specs = [_]SnapshotSpec{
    // An inventory, not debt: a 2830-symbol API surface used to head the debt
    // table purely for being the largest number in it.
    .{
        .leaf = "pub-api.txt",
        .label = "pub-api-surface",
        .kind = .lines,
        .row = .inventory,
        .unit = symbol_unit,
    },
    .{
        .leaf = "panic-budget.txt",
        .label = "panic-budget",
        .kind = .counts,
        .row = .violation,
        .unit = occurrence_unit,
    },
    .{
        .leaf = "int-from-float-budget.txt",
        .label = "int-from-float-budget",
        .kind = .counts,
        .row = .violation,
        .unit = occurrence_unit,
    },
    .{
        .leaf = "unsafe-ops-budget.txt",
        .label = "unsafe-ops-budget",
        .kind = .counts,
        .row = .violation,
        .unit = occurrence_unit,
    },
    // The one row where higher is better; it sat unmarked among lower-is-better
    // counts, so 32 read as small debt rather than a poor kill score.
    .{
        .leaf = "mutation.txt",
        .label = mutation_label,
        .kind = .mutation,
        .row = .score,
        .unit = score_unit,
    },
};

/// A `.guardian/` file routed to its report label, summary kind, row kind and
/// unit.
const Classified = struct {
    label: []const u8,
    kind: Kind,
    row: RowKind,
    unit: []const u8,
};

/// Everything one invocation gathered, in one value so the human report and the
/// JSON payload cannot describe different things.
const Gathered = struct {
    rows: []const Row,
    density: []const DensityRow,
    current: debt_current.Report,
};

/// Which way is better for each kind of number. One mapping, so a row can never
/// be printed under a section header that contradicts its JSON direction.
fn directionOf(kind: RowKind) Direction {
    return switch (kind) {
        // Every threshold metric a headroom row measures counts something a cap
        // limits, so less of it is the good direction — the same as debt.
        .violation, .measurement => .lower_better,
        .score => .higher_better,
        .inventory => .neutral,
    };
}

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
    // `--current` measures the tree so every frozen ceiling can be printed with
    // the value it faces today; opt-in because it re-parses src/ and test/.
    const current: debt_current.Report = if (ctx.current)
        try debt_current.collect(ctx)
    else
        .{ .summaries = &.{}, .rows = &.{} };
    const gathered: Gathered = .{ .rows = rows, .density = density, .current = current };
    // The JSON payload goes to STDOUT and the human report to stderr, because
    // they are different audiences on purpose: `debt --json | jq` used to
    // receive nothing at all, the payload having been printed to stderr with
    // the prose.
    if (ctx.json) return reporter.machine(try renderJson(ctx.allocator, ctx.project_dir, gathered));
    printReport(ctx.allocator, ctx.project_dir, gathered.rows);
    try reportFileSizes(ctx);
    reportCurrent(ctx, gathered.current);
    if (ctx.assert_density) printDensityReport(gathered.density);
}

/// Serializes the whole gathered report. Pure: the caller owns the stream, so
/// the payload's shape is provable without one.
fn renderJson(arena: Allocator, project_dir: []const u8, gathered: Gathered) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, JsonReport{
        .project_dir = project_dir,
        .rows = gathered.rows,
        .assert_density = gathered.density,
        .ratchet_ceilings = gathered.current.rows,
        .headroom = try headroomJson(arena, gathered.current.headroom),
    }, .{});
}

/// One measured headroom row as a machine reader gets it: the measurement plus
/// the three fields every other row in this report carries — what the number
/// measures, which way is better, and the unit it counts in — and the share of
/// the limit already consumed. Without them a caller has to infer "9983 of
/// 10000" from a check name, which is exactly the guessing `kind`/`direction`
/// were added to the debt rows to end.
const JsonHeadroomRow = struct {
    check: []const u8,
    key: []const u8,
    value: u64,
    limit: u64,
    limit_kind: debt_current.LimitKind,
    pct: u64,
    kind: RowKind,
    direction: Direction,
    unit: []const u8,
};

/// Types every headroom row for the JSON payload, taking each unit from the
/// ratchet registry so the JSON and the gate's own diagnostics name the metric
/// identically ("code lines", "params", "fields").
fn headroomJson(arena: Allocator, rows: []const debt_current.HeadroomRow) Allocator.Error![]const JsonHeadroomRow {
    const out = try arena.alloc(JsonHeadroomRow, rows.len);
    for (rows, out) |row, *slot| slot.* = .{
        .check = row.check,
        .key = row.key,
        .value = row.value,
        .limit = row.limit,
        .limit_kind = row.limit_kind,
        .pct = debt_current.pctOfLimit(row),
        .kind = .measurement,
        .direction = directionOf(.measurement),
        .unit = ratchet.unitLabel(row.check),
    };
    return out;
}

/// Prints the measured sections, or the one-line pointer to them. The pointer
/// matters: without it a reader sees frozen ceilings with no way to tell which
/// of them still has room, which is the state that cost one consumer six gate
/// runs to resolve by hand.
fn reportCurrent(ctx: *types.RunCtx, current: debt_current.Report) void {
    if (ctx.current) return debt_current.printReport(ctx.allocator, current);
    print("  add --live (or --current) to measure the tree now: every ratcheted item against its\n", .{});
    print("  frozen ceiling, plus what is nearest a blocking limit. `guardian-check size <file>`\n", .{});
    print("  answers the same for one file.\n", .{});
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
    /// Present (non-empty) only under `--live`/`--current`: one entry per
    /// ratcheted key with no headroom left, each with its measured value and
    /// frozen ceiling.
    ratchet_ceilings: []const debt_current.Row,
    /// Present (non-empty) only under `--live`/`--current`: the measured items
    /// nearest a limit that would block them, least room first.
    headroom: []const JsonHeadroomRow = &.{},
};

fn filterRows(allocator: Allocator, rows: []const Row, filter: ?[]const u8) Allocator.Error![]const Row {
    const name = filter orelse return rows;
    var out: std.ArrayList(Row) = .empty;
    for (rows) |row| if (rowMatches(row, name)) try out.append(allocator, row);
    return out.toOwnedSlice(allocator);
}

fn rowMatches(row: Row, check_name: []const u8) bool {
    if (std.mem.eql(u8, row.label, check_name)) return true;
    // `mutate` is the command name; the row is labelled after the metric.
    return std.mem.eql(u8, check_name, "mutate") and std.mem.eql(u8, row.label, mutation_label);
}

/// Lists obsolete per-check baseline files, deleting them only when the user
/// supplied both `--prune-stale` and `--yes`.
fn pruneStale(ctx: *types.RunCtx) types.RunError!void {
    const exists = ctx.command_exists orelse {
        reporter.fail("debt: registry unavailable; stale baselines were not pruned", .{});
        return error.CheckFailed;
    };
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/baselines", .{ctx.project_dir});
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
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
        fs.cwd().deleteFile(full) catch |e| {
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
            .kind = c.row,
            .direction = directionOf(c.row),
            .unit = c.unit,
            .count = current,
            .delta = delta,
            .worst = ratchetWorst(ctx.arena, entry.rel_path, entry.content),
        });
    }
}

/// The worst stored entry of a per-item ratchet (v2) baseline, or null for any
/// other file. The count column already reads the key count (one line per key);
/// this adds the single highest-value offender for context.
fn ratchetWorst(arena: Allocator, rel_path: []const u8, content: []const u8) ?Worst {
    if (std.mem.indexOf(u8, rel_path, baselines_marker) == null) return null;
    if (!std.mem.startsWith(u8, content, ratchet_header)) return null;
    const entries = ratchet.parse(arena, content) catch return null;
    const worst = ratchet.maxEntry(entries) orelse return null;
    return splitRatchetKey(worst.key, worst.value);
}

/// Splits a ratchet key into its parts. A per-subject key is `<file>|<name>`; a
/// file-level metric has no `|` and therefore no item. Reporting the halves
/// separately is what lets a caller open the file without parsing prose.
fn splitRatchetKey(key: []const u8, metric: u64) Worst {
    const bar = std.mem.indexOfScalar(u8, key, '|') orelse
        return .{ .metric = metric, .file = key, .item = null };
    return .{ .metric = metric, .file = key[0..bar], .item = key[bar + 1 ..] };
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
        return .{
            .label = try arena.dupe(u8, stripTxt(base)),
            .kind = .lines,
            .row = .violation,
            .unit = violation_unit,
        };
    }
    for (snapshot_specs) |s| {
        if (std.mem.eql(u8, base, s.leaf)) {
            return .{ .label = s.label, .kind = s.kind, .row = s.row, .unit = s.unit };
        }
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

/// Prints the report in one section per kind, or a friendly note when nothing
/// is recorded. Sectioning is the whole point: a single count-sorted table put
/// the API-surface inventory and the mutation score in among the violation
/// counts, where the biggest number reads as the worst debt regardless of
/// whether it is debt at all, or whether big is even the bad direction.
fn printReport(allocator: Allocator, project_dir: []const u8, rows: []const Row) void {
    if (rows.len == 0) {
        reporter.ok("debt: nothing recorded under {s}/.guardian", .{project_dir});
        return;
    }
    printSection(allocator, rows, .violation, "debt — baselined violations, LOWER is better (delta vs HEAD)");
    printSection(allocator, rows, .inventory, "inventory — tracked totals, NOT debt (delta vs HEAD)");
    printSection(allocator, rows, .score, "scores — HIGHER is better (delta vs HEAD)");
}

/// Prints one kind's rows under its header, or nothing when that kind has none.
fn printSection(allocator: Allocator, rows: []const Row, kind: RowKind, header: []const u8) void {
    if (countOfKind(rows, kind) == 0) return;
    reporter.ok("{s}", .{header});
    for (rows) |r| {
        if (r.kind == kind) printRow(allocator, r);
    }
}

/// How many rows belong to `kind` — the empty-section test, kept apart so a
/// header is never printed above nothing.
fn countOfKind(rows: []const Row, kind: RowKind) usize {
    var n: usize = 0;
    for (rows) |r| n += @intFromBool(r.kind == kind);
    return n;
}

/// Prints one row: label, count with its unit, the committed-state delta, and
/// the ratchet's worst stored offender when there is one.
fn printRow(allocator: Allocator, r: Row) void {
    print("  {s:<24} {d:>6} {s:<16}{s}{s}\n", .{
        r.label,
        r.count,
        r.unit,
        deltaText(allocator, r.delta),
        worstText(allocator, r.worst),
    });
}

/// Renders the worst stored offender, labelled `worst (baselined)`. The label
/// is the point: the number reads like a live measurement and is not one — a
/// consumer appended 300 lines to the named file and watched it never move,
/// then wrote a three-line script to recover the live value. `--live` is where
/// the measured number lives.
fn worstText(allocator: Allocator, worst: ?Worst) []const u8 {
    const w = worst orelse return "";
    const item = w.item orelse
        return std.fmt.allocPrint(allocator, "  worst (baselined): {d} {s}", .{ w.metric, w.file }) catch "";
    return std.fmt.allocPrint(allocator, "  worst (baselined): {d} {s}|{s}", .{ w.metric, w.file, item }) catch "";
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
    const z = try arena.dupeSentinel(u8, content, 0);
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

/// A baselined-violation row, the shape most assertions below need.
fn violationRow(label: []const u8, count: u64) Row {
    return .{
        .label = label,
        .kind = .violation,
        .direction = directionOf(.violation),
        .unit = violation_unit,
        .count = count,
        .delta = null,
    };
}

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
    try testing.expect(base.row == .violation);

    const snap = (try classify(a, ".guardian/pub-api.txt")).?;
    try testing.expectEqualStrings("pub-api-surface", snap.label);
    // The API surface is an inventory, not debt — that is what kept it off the
    // top of the debt table.
    try testing.expect(snap.row == .inventory);
    try testing.expectEqualStrings("tracked symbols", snap.unit);

    const counts = (try classify(a, ".guardian/panic-budget.txt")).?;
    try testing.expect(counts.kind == .counts);
    try testing.expect(counts.row == .violation);

    // An unrecognized file is dropped.
    try testing.expect((try classify(a, ".guardian/notes.md")) == null);
}

// spec: Debt - Sorts the debt rows by count descending

test "sortByCountDesc orders by count then label" {
    var rows = [_]Row{
        violationRow("b", 5),
        violationRow("a", 130),
        violationRow("c", 130),
    };
    sortByCountDesc(&rows);
    try testing.expectEqualStrings("a", rows[0].label); // 130, label a first
    try testing.expectEqualStrings("c", rows[1].label); // 130, label c
    try testing.expectEqualStrings("b", rows[2].label); // 5 last
}

// spec: Debt - Notes a per-item ratchet's worst offender

test "ratchetWorst reports the worst offender of a v2 baseline as split parts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v2 = "# guardian-snapshot v2\n95 src/a.zig|f\n130 src/b.zig|g\n";
    const worst = ratchetWorst(a, ".guardian/baselines/function-length.txt", v2).?;
    // Structured, not a preformatted string: a consumer opens the file without
    // parsing prose (the old note carried its own padding, "  worst: 130 …").
    try testing.expectEqual(@as(u64, 130), worst.metric);
    try testing.expectEqualStrings("src/b.zig", worst.file);
    try testing.expectEqualStrings("g", worst.item.?);
    // A file-level metric has no item within the file.
    const file_level = splitRatchetKey("src/big.zig", 10_223);
    try testing.expectEqualStrings("src/big.zig", file_level.file);
    try testing.expect(file_level.item == null);
    // A v1 text baseline is not a ratchet — no worst entry.
    try testing.expect(ratchetWorst(a, ".guardian/baselines/spec.txt", "# guardian-snapshot v1\nfoo\n") == null);
    // A non-baseline file (a snapshot) is not a ratchet either.
    try testing.expect(ratchetWorst(a, ".guardian/pub-api.txt", v2) == null);
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
    try testing.expect(rowMatches(violationRow("spec", 1), "spec"));
    try testing.expect(rowMatches(violationRow(mutation_label, 80), "mutate"));
    try testing.expect(!rowMatches(violationRow("spec", 1), "file-size"));
}

// spec: Maintenance - Debt previews stale baseline pruning before explicit confirmation

test "stale pruning requires both prune request and explicit confirmation" {
    try testing.expect(!mutationConfirmed(true, false));
    try testing.expect(!mutationConfirmed(false, true));
    try testing.expect(mutationConfirmed(true, true));
}

/// The three rows every sectioning assertion below shares: one of each kind.
fn mixedRows() [3]Row {
    return .{
        .{
            .label = "pub-api-surface",
            .kind = .inventory,
            .direction = directionOf(.inventory),
            .unit = symbol_unit,
            .count = 2830,
            .delta = 0,
        },
        .{
            .label = mutation_label,
            .kind = .score,
            .direction = directionOf(.score),
            .unit = score_unit,
            .count = 32,
            .delta = null,
        },
        .{
            .label = "file-size",
            .kind = .violation,
            .direction = directionOf(.violation),
            .unit = violation_unit,
            .count = 12,
            .delta = 1,
            .worst = .{ .metric = 10_223, .file = "src/placement/router.zig", .item = null },
        },
    };
}

// spec: Debt - Separates violation debt from inventories and scores into labelled sections

test "printReport sections each kind under its own direction-bearing header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const rows = mixedRows();
    printReport(a, ".", &rows);
    const out = cap.buf.items;
    // The 2830-symbol inventory is the biggest number in the report and must
    // NOT head it: each kind gets its own header naming its direction.
    const debt_at = std.mem.indexOf(u8, out, "debt — baselined violations, LOWER is better").?;
    const inventory_at = std.mem.indexOf(u8, out, "inventory — tracked totals, NOT debt").?;
    const score_at = std.mem.indexOf(u8, out, "scores — HIGHER is better").?;
    try testing.expect(debt_at < inventory_at);
    try testing.expect(inventory_at < score_at);
    // Every row sits under its own header, with its unit spelled out.
    try testing.expect(std.mem.indexOf(u8, out, "file-size").? < inventory_at);
    try testing.expect(std.mem.indexOf(u8, out, "2830 tracked symbols").? > inventory_at);
    try testing.expect(std.mem.indexOf(u8, out, "32 % killed").? > score_at);
    // A kind with no rows prints no header at all.
    cap.buf.clearRetainingCapacity();
    printReport(a, ".", &.{violationRow("spec", 3)});
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "inventory —") == null);
}

// spec: Debt - Labels the worst offender as the stored baseline rather than a live measurement

test "worstText marks the ratchet's worst entry as baselined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "(baselined)" is load-bearing: the unlabelled number reads as a live
    // measurement, and a consumer appended 300 lines to this very file and
    // watched it never move before working out that it is the frozen value.
    try testing.expectEqualStrings(
        "  worst (baselined): 10223 src/placement/router.zig",
        worstText(a, .{ .metric = 10_223, .file = "src/placement/router.zig", .item = null }),
    );
    try testing.expectEqualStrings(
        "  worst (baselined): 12 src/placement/optimizer.zig|assignSides",
        worstText(a, .{ .metric = 12, .file = "src/placement/optimizer.zig", .item = "assignSides" }),
    );
    // A source with no ratchet contributes no column at all.
    try testing.expectEqualStrings("", worstText(a, null));
}

// spec: Debt - Renders JSON rows carrying a kind, a direction, and a structured worst offender

test "renderJson emits typed rows and the measured headroom list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = mixedRows();
    const json = try renderJson(a, "/repo", .{
        .rows = &rows,
        .density = &.{},
        .current = .{
            .summaries = &.{},
            .rows = &.{},
            .headroom = &.{.{
                .check = "file-size",
                .key = "src/placement/router.zig",
                .value = 10_223,
                .limit = 10_227,
                .limit_kind = .ceiling,
            }},
        },
    });
    // The top-level shape consumers already parse is unchanged.
    try testing.expect(std.mem.indexOf(u8, json, "\"project_dir\":\"/repo\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"rows\":[") != null);
    // A machine reader gets the kind and direction as fields, never inferred
    // from label text.
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"inventory\",\"direction\":\"neutral\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"score\",\"direction\":\"higher_better\"") != null);
    // The worst offender is structured, not a padded string.
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"worst\":{\"metric\":10223,\"file\":\"src/placement/router.zig\",\"item\":null}",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"headroom\":[{\"check\":\"file-size\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"limit_kind\":\"ceiling\"") != null);
}

// spec: Debt - Renders JSON headroom rows carrying a kind, a direction, and a unit

test "headroomJson types each measured row with its kind, direction, unit and share" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The audit case: an un-ratcheted file 17 lines under the 10000 hard cap.
    // It was already in the headroom list; what a machine reader could not get
    // from it was what the number measures, which way is better, and its unit.
    const rows = try headroomJson(a, &.{.{
        .check = "file-size",
        .key = "src/placement/optimizer.zig",
        .value = 9983,
        .limit = 10_000,
        .limit_kind = .hard_cap,
    }});
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(u64, 99), rows[0].pct);
    try testing.expectEqualStrings("code lines", rows[0].unit);
    // A live measurement is NOT accepted debt — most rows here are green files —
    // so it carries its own kind rather than being filed under violations.
    try testing.expect(rows[0].kind == .measurement);
    try testing.expect(rows[0].direction == .lower_better);
    // The unit comes from the ratchet registry, so it matches what the gate
    // calls the metric for every check that can appear here.
    const params = try headroomJson(a, &.{.{
        .check = "function-size",
        .key = "src/x.zig|f",
        .value = 6,
        .limit = 6,
        .limit_kind = .hard_cap,
    }});
    try testing.expectEqualStrings("params", params[0].unit);
    try testing.expectEqual(@as(u64, 100), params[0].pct);
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
