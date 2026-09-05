//! Benchmark ledger format: the record shape stored in `.guardian/benchmarks.txt`
//! plus the pure policy over it (ratchet direction, gate membership, input
//! validation). Guardian never RUNS a benchmark — an agent measures something
//! expensive (a full-board route, a suite wall clock, a kill score) and records
//! the scalar here so the NEXT agent reads the number instead of re-measuring
//! it, and so a deliberately-accepted regression (or a negative experimental
//! result) lives next to the code it explains rather than in a lost report.
//!
//! One line per metric, sorted, under the shared `# guardian-snapshot v<N>`
//! header so `.guardian/` stays one readable, diff-friendly format:
//!
//!   <name> <value> <unit> <direction> <commit> <date> <note…>
//!   close_open_nets_wall_s 531 s min a3c81cd 2026-07-25 fixture B, 87/90 nets
//!
//! `-` is the placeholder for an omitted unit/commit/date; the note is the free
//! text tail and may be empty. Recording a metric again REPLACES its line —
//! history is git's job, not this file's.
//!
//! I/O and process state live elsewhere: `snapshot.zig` reads/writes the file,
//! `cli/bench.zig` owns the CLI, the clock, and the git head hash. This module
//! is pure so every rule below is unit-tested without touching disk.

const std = @import("std");
const fs = @import("fs.zig");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");

/// File name of the ledger inside a project's `.guardian/` directory.
pub const leaf = "benchmarks.txt";

/// Ledger format version stamped into the snapshot header.
pub const format_version: u32 = 1;

/// Placeholder stored for an omitted single-token field (unit/commit/date), so
/// every record keeps the same field count and stays parseable.
pub const empty_field = "-";

/// Characters of a commit hash shown in a summary line.
const short_commit_len = 8;

/// Buffer size for `isoDate` — a rendered `YYYY-MM-DD` needs 10 bytes; the
/// slack covers an absurd far-future year without a truncation branch.
pub const iso_date_buf_len = 16;

/// Which way a metric is allowed to move. `min` = lower is better (wall clock,
/// nanohenries), `max` = higher is better (nets routed, kill score), `info` =
/// no direction at all — the pure-documentation case, e.g. recording that an
/// experiment COST a net so nobody re-runs it.
pub const Direction = enum { min, max, info };

/// One recorded measurement. `value` is the scalar; `unit` is free-form and
/// short ("s", "nets", "%"); `commit`/`date` say where and when it was taken;
/// `note` is the one-line context that makes the number mean something
/// ("87/90 nets, DRC 11/8, fixture B").
pub const Record = struct {
    name: []const u8,
    value: f64,
    unit: []const u8 = empty_field,
    direction: Direction = .info,
    commit: []const u8 = empty_field,
    date: []const u8 = empty_field,
    note: []const u8 = "",
};

/// The `bench` command's parsed argv, filled by the CLI arg scanner and carried
/// on `RunCtx`. Absent flags are the empty string (not `?[]const u8`) so the
/// struct stays a flat, optional-free argument bag.
pub const Args = struct {
    /// `set` | `list` | `rm`.
    sub: []const u8 = "",
    /// Metric name positional (`set` / `rm`).
    name: []const u8 = "",
    /// Raw value positional (`set`), parsed by `parseValue`.
    value: []const u8 = "",
    /// `--unit <u>`.
    unit: []const u8 = "",
    /// `--dir min|max|info`.
    direction: []const u8 = "",
    /// `--note "…"`.
    note: []const u8 = "",
    /// `--force`: accept a gated metric's regression (requires a note).
    force: bool = false,

    /// Assigns `arg` to the next positional slot this subcommand still needs
    /// (subcommand, then name, then value), returning true when it was
    /// consumed. False means `bench` wants no further positional, so the
    /// caller keeps it as the project directory.
    pub fn takePositional(self: *Args, arg: []const u8) bool {
        if (self.sub.len == 0) {
            self.sub = arg;
            return true;
        }
        if (self.name.len == 0 and wantsName(self.sub)) {
            self.name = arg;
            return true;
        }
        if (self.value.len == 0 and wantsValue(self.sub)) {
            self.value = arg;
            return true;
        }
        return false;
    }
};

/// Subcommand name that records or replaces a metric.
pub const sub_set = "set";
/// Subcommand name that prints the ledger.
pub const sub_list = "list";
/// Subcommand name that drops a metric.
pub const sub_rm = "rm";

/// True when `sub` takes a metric-name positional.
fn wantsName(sub: []const u8) bool {
    return std.mem.eql(u8, sub, sub_set) or std.mem.eql(u8, sub, sub_rm);
}

/// True when `sub` takes a value positional.
fn wantsValue(sub: []const u8) bool {
    return std.mem.eql(u8, sub, sub_set);
}

/// Parses a `--dir` token; null when it names no known direction.
pub fn parseDirection(text: []const u8) ?Direction {
    return std.meta.stringToEnum(Direction, text);
}

/// Parses a metric value, rejecting anything that is not a finite number —
/// a NaN or infinity would compare false against every ratchet and print as
/// garbage, so it never enters the ledger.
pub fn parseValue(text: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

/// True when `text` is a valid single-token field (metric name, unit): at
/// least one character, no whitespace, no control characters, and never the
/// `-` placeholder itself.
pub fn validToken(text: []const u8) bool {
    if (text.len == 0 or std.mem.eql(u8, text, empty_field)) return false;
    for (text) |c| {
        if (!std.ascii.isPrint(c) or c == ' ') return false;
    }
    return true;
}

/// True when `text` is storable as a note: one line, printable. Empty is
/// valid — a note is optional except where the CLI demands one.
pub fn validNote(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isPrint(c)) return false;
    }
    return true;
}

/// Parses one stored ledger line into a Record; null when the line is not a
/// well-formed record (too few fields, unparseable value, unknown direction).
/// Slices point into `line`.
pub fn parseLine(line: []const u8) ?Record {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const name = it.next() orelse return null;
    const value_text = it.next() orelse return null;
    const unit = it.next() orelse return null;
    const direction_text = it.next() orelse return null;
    const commit = it.next() orelse return null;
    const date = it.next() orelse return null;
    return .{
        .name = name,
        .value = parseValue(value_text) orelse return null,
        .unit = unit,
        .direction = parseDirection(direction_text) orelse return null,
        .commit = commit,
        .date = date,
        .note = std.mem.trim(u8, it.rest(), &std.ascii.whitespace),
    };
}

/// Renders a Record to its stored line. Omitted single-token fields become the
/// `-` placeholder and an empty note leaves no trailing whitespace, so the
/// output round-trips through `parseLine` unchanged.
pub fn renderLine(arena: Allocator, rec: Record) Allocator.Error![]const u8 {
    const line = try std.fmt.allocPrint(arena, "{s} {d} {s} {s} {s} {s} {s}", .{
        rec.name,
        rec.value,
        fieldOr(rec.unit),
        @tagName(rec.direction),
        fieldOr(rec.commit),
        fieldOr(rec.date),
        rec.note,
    });
    return std.mem.trimEnd(u8, line, " ");
}

/// Renders the compact one-line form printed by `bench list` and by every gate
/// run: `bench <name> = <value> <unit> (<dir>, @<commit> <date>: "<note>")`.
pub fn summaryLine(arena: Allocator, rec: Record) Allocator.Error![]const u8 {
    const unit_part = if (hasField(rec.unit)) try std.fmt.allocPrint(arena, " {s}", .{rec.unit}) else "";
    const note_part = if (rec.note.len == 0) "" else try std.fmt.allocPrint(arena, ": \"{s}\"", .{rec.note});
    return std.fmt.allocPrint(arena, "bench {s} = {d}{s} ({s}, @{s} {s}{s})", .{
        rec.name,
        rec.value,
        unit_part,
        @tagName(rec.direction),
        shortCommit(fieldOr(rec.commit)),
        fieldOr(rec.date),
        note_part,
    });
}

/// The leading `short_commit_len` characters of a commit hash (all of it when
/// shorter) — what a summary line shows.
pub fn shortCommit(hash: []const u8) []const u8 {
    return hash[0..@min(hash.len, short_commit_len)];
}

/// Reads the ledger at `path`. A missing file is an EMPTY ledger (recording the
/// first metric creates it); a present-but-corrupt one is `error.BadFormat`, so
/// a damaged ledger is never silently rewritten from scratch.
pub fn read(arena: Allocator, path: []const u8) snapshot.ReadError![]const Record {
    const snap = snapshot.read(arena, path, format_version) catch |e| switch (e) {
        error.Missing => return &.{},
        else => return e,
    };
    var out: std.ArrayList(Record) = .empty;
    for (snap.lines) |line| {
        const rec = parseLine(line) orelse return error.BadFormat;
        try out.append(arena, rec);
    }
    return out.toOwnedSlice(arena);
}

/// Writes `records` to `path`, one rendered line each. The snapshot writer
/// sorts, and a record line starts with its metric name, so the file is always
/// name-sorted — a re-record moves no other line.
pub fn write(arena: Allocator, path: []const u8, records: []const Record) snapshot.WriteError!void {
    const lines = try arena.alloc([]const u8, records.len);
    for (records, 0..) |rec, i| lines[i] = try renderLine(arena, rec);
    try snapshot.write(path, format_version, lines);
}

/// The record named `name`, or null when the ledger has none.
pub fn find(records: []const Record, name: []const u8) ?Record {
    for (records) |rec| {
        if (std.mem.eql(u8, rec.name, name)) return rec;
    }
    return null;
}

/// Returns `records` with `rec` replacing the same-named entry, or appended
/// when the metric is new — one line per metric, always.
pub fn upsert(arena: Allocator, records: []const Record, rec: Record) Allocator.Error![]const Record {
    var out: std.ArrayList(Record) = .empty;
    var replaced = false;
    for (records) |existing| {
        const same = std.mem.eql(u8, existing.name, rec.name);
        try out.append(arena, if (same) rec else existing);
        replaced = replaced or same;
    }
    if (!replaced) try out.append(arena, rec);
    return out.toOwnedSlice(arena);
}

/// Returns `records` without the entry named `name`, or null when no such
/// metric exists (so the caller can report a no-op instead of rewriting).
pub fn without(arena: Allocator, records: []const Record, name: []const u8) Allocator.Error!?[]const Record {
    if (find(records, name) == null) return null;
    var out: std.ArrayList(Record) = .empty;
    for (records) |existing| {
        if (std.mem.eql(u8, existing.name, name)) continue;
        try out.append(arena, existing);
    }
    const kept = try out.toOwnedSlice(arena);
    return kept;
}

/// True when re-recording `new_value` over `old_value` is a REGRESSION under
/// `direction`: higher is worse for `min`, lower is worse for `max`. An `info`
/// metric has no direction, so it never regresses — holding equal never does
/// either (a ratchet may hold).
pub fn regresses(direction: Direction, old_value: f64, new_value: f64) bool {
    return switch (direction) {
        .min => new_value > old_value,
        .max => new_value < old_value,
        .info => false,
    };
}

/// True when `name` is listed in `[benchmark] gate` — the opt-in per-metric
/// ratchet. Nothing is gated by default: the ledger records, it does not block.
pub fn gated(gate_list: []const []const u8, name: []const u8) bool {
    for (gate_list) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Formats `epoch_secs` (seconds since the Unix epoch) as an ISO `YYYY-MM-DD`
/// calendar date in `buf`. Pure: the caller reads the clock, this converts, so
/// the date arithmetic is unit-tested without one.
pub fn isoDate(buf: *[iso_date_buf_len]u8, epoch_secs: u64) []const u8 {
    const epoch_day = (std.time.epoch.EpochSeconds{ .secs = epoch_secs }).getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const printed = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    });
    // NoSpaceLeft is unreachable for any representable year in `iso_date_buf_len`
    // bytes; degrade to "no date" rather than failing a recording over a date.
    return printed catch empty_field;
}

/// The stored spelling of a single-token field: the value itself, or the `-`
/// placeholder when the caller left it empty.
fn fieldOr(text: []const u8) []const u8 {
    return if (text.len == 0) empty_field else text;
}

/// True when a single-token field carries real content (not empty, not `-`).
fn hasField(text: []const u8) bool {
    return text.len != 0 and !std.mem.eql(u8, text, empty_field);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Benchmark Ledger - Round-trips a recorded metric through its stored line

test "renderLine and parseLine round-trip a record with and without a note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec: Record = .{
        .name = "close_open_nets_wall_s",
        .value = 531,
        .unit = "s",
        .direction = .min,
        .commit = "a3c81cd9",
        .date = "2026-07-25",
        .note = "fixture B, 87/90 nets",
    };
    const line = try renderLine(a, rec);
    try testing.expectEqualStrings(
        "close_open_nets_wall_s 531 s min a3c81cd9 2026-07-25 fixture B, 87/90 nets",
        line,
    );
    const back = parseLine(line).?;
    try testing.expectEqualStrings(rec.name, back.name);
    try testing.expectEqual(rec.value, back.value);
    try testing.expectEqualStrings(rec.unit, back.unit);
    try testing.expect(back.direction == .min);
    try testing.expectEqualStrings(rec.note, back.note);
    // An omitted unit/commit/date stores the placeholder, and an empty note
    // leaves no trailing whitespace to churn the diff.
    const bare = try renderLine(a, .{ .name = "experiment", .value = -1, .unit = "", .commit = "", .date = "" });
    try testing.expectEqualStrings("experiment -1 - info - -", bare);
    try testing.expectEqualStrings("", parseLine(bare).?.note);
}

// spec: Benchmark Ledger - Rejects a malformed stored line rather than guessing

test "parseLine rejects short, non-numeric, and unknown-direction lines" {
    try testing.expect(parseLine("only three fields here") == null);
    try testing.expect(parseLine("name notanumber s min abc 2026-07-25") == null);
    try testing.expect(parseLine("name 1 s sideways abc 2026-07-25") == null);
    try testing.expect(parseLine("name nan s min abc 2026-07-25") == null);
    try testing.expect(parseLine("name 1 s min abc 2026-07-25") != null);
}

// spec: Benchmark Ledger - Refuses a value that is not a finite number

test "parseValue accepts finite decimals and rejects NaN and infinity" {
    try testing.expectEqual(@as(?f64, 1.54), parseValue("1.54"));
    try testing.expectEqual(@as(?f64, -1), parseValue("-1"));
    try testing.expect(parseValue("nan") == null);
    try testing.expect(parseValue("inf") == null);
    try testing.expect(parseValue("-inf") == null);
    try testing.expect(parseValue("") == null);
    try testing.expect(parseValue("12s") == null);
}

// spec: Benchmark Ledger - Validates metric names, units, and notes as storable text

test "validToken rejects blanks and separators while validNote allows spaces" {
    try testing.expect(validToken("close_open_nets_wall_s"));
    try testing.expect(validToken("%"));
    try testing.expect(!validToken(""));
    try testing.expect(!validToken("two words"));
    try testing.expect(!validToken(empty_field));
    try testing.expect(!validToken("tab\there"));
    try testing.expect(validNote("87/90 nets, DRC 11/8"));
    try testing.expect(validNote(""));
    try testing.expect(!validNote("two\nlines"));
    // A direction token is parsed from the same argv surface.
    try testing.expect(parseDirection("max").? == .max);
    try testing.expect(parseDirection("lower") == null);
}

// spec: Benchmark Ledger - Prints one compact summary line per recorded metric

test "summaryLine renders value, unit, direction, commit, date, and note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try summaryLine(a, .{
        .name = "close_open_nets_wall_s",
        .value = 531,
        .unit = "s",
        .direction = .min,
        .commit = "a3c81cd9ffff",
        .date = "2026-07-25",
        .note = "fixture B",
    });
    try testing.expectEqualStrings(
        "bench close_open_nets_wall_s = 531 s (min, @a3c81cd9 2026-07-25: \"fixture B\")",
        line,
    );
    // The negative-result case: no unit, no direction, a note that IS the point.
    const doc = try summaryLine(a, .{
        .name = "terminal_via_default_smd_cost_nets",
        .value = -1,
        .unit = empty_field,
        .commit = "a3c81cd9",
        .date = "2026-07-25",
        .note = "defaulting smd_ok: 87->86 on fixture B",
    });
    try testing.expectEqualStrings(
        "bench terminal_via_default_smd_cost_nets = -1 (info, @a3c81cd9 2026-07-25: " ++
            "\"defaulting smd_ok: 87->86 on fixture B\")",
        doc,
    );
}

// spec: Benchmark Ledger - Replaces an existing metric's line instead of appending a duplicate

test "upsert replaces by name and appends an unknown metric" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const start = [_]Record{
        .{ .name = "alpha", .value = 1 },
        .{ .name = "beta", .value = 2 },
    };
    const replaced = try upsert(a, &start, .{ .name = "alpha", .value = 9, .note = "re-measured" });
    try testing.expectEqual(@as(usize, 2), replaced.len);
    try testing.expectEqual(@as(f64, 9), find(replaced, "alpha").?.value);
    try testing.expectEqualStrings("re-measured", find(replaced, "alpha").?.note);
    const appended = try upsert(a, &start, .{ .name = "gamma", .value = 3 });
    try testing.expectEqual(@as(usize, 3), appended.len);
    try testing.expectEqual(@as(f64, 3), find(appended, "gamma").?.value);
}

// spec: Benchmark Ledger - Removes a named metric and reports an unknown one

test "without drops the named record and returns null when it is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const start = [_]Record{
        .{ .name = "alpha", .value = 1 },
        .{ .name = "beta", .value = 2 },
    };
    const dropped = (try without(a, &start, "alpha")).?;
    try testing.expectEqual(@as(usize, 1), dropped.len);
    try testing.expect(find(dropped, "alpha") == null);
    try testing.expect(try without(a, &start, "missing") == null);
}

// spec: Benchmark Ledger - Treats only a worsening move as a regression for a directional metric

test "regresses follows the metric direction and never fires for info" {
    // min: lower is better, so a higher re-measurement regresses.
    try testing.expect(regresses(.min, 531, 818));
    try testing.expect(!regresses(.min, 531, 400));
    try testing.expect(!regresses(.min, 531, 531));
    // max: higher is better.
    try testing.expect(regresses(.max, 87, 86));
    try testing.expect(!regresses(.max, 87, 90));
    // info records a fact, not a target.
    try testing.expect(!regresses(.info, 1, -1000));
}

// spec: Benchmark Ledger - Gates only the metrics named in the benchmark gate list

test "gated matches configured metric names and defaults to nothing" {
    const list = [_][]const u8{ "kill_score", "close_open_nets_wall_s" };
    try testing.expect(gated(&list, "kill_score"));
    try testing.expect(!gated(&list, "kill_scores"));
    try testing.expect(!gated(&.{}, "kill_score"));
}

// spec: Benchmark Ledger - Formats a measurement date as an ISO calendar day

test "isoDate converts epoch seconds to a YYYY-MM-DD day" {
    var buf: [iso_date_buf_len]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", isoDate(&buf, 0));
    // 2026-07-25T00:00:00Z, and the same calendar day an hour later.
    try testing.expectEqualStrings("2026-07-25", isoDate(&buf, 1784937600));
    try testing.expectEqualStrings("2026-07-25", isoDate(&buf, 1784937600 + 3600));
    try testing.expectEqualStrings("a3c81cd9", shortCommit("a3c81cd9ffffffff"));
    try testing.expectEqualStrings("abc", shortCommit("abc"));
}

// spec: Benchmark Ledger - Assigns bench positionals per subcommand before the project directory

test "takePositional fills subcommand, name, and value only where the subcommand needs them" {
    var set_args: Args = .{};
    try testing.expect(set_args.takePositional(sub_set));
    try testing.expect(set_args.takePositional("kill_score"));
    try testing.expect(set_args.takePositional("81"));
    // The fourth positional is the project directory, not a bench slot.
    try testing.expect(!set_args.takePositional("/tmp/project"));
    try testing.expectEqualStrings("kill_score", set_args.name);
    try testing.expectEqualStrings("81", set_args.value);

    var list_args: Args = .{};
    try testing.expect(list_args.takePositional(sub_list));
    try testing.expect(!list_args.takePositional("/tmp/project"));
    try testing.expectEqualStrings("", list_args.name);

    var rm_args: Args = .{};
    try testing.expect(rm_args.takePositional(sub_rm));
    try testing.expect(rm_args.takePositional("kill_score"));
    try testing.expect(!rm_args.takePositional("/tmp/project"));
    try testing.expectEqualStrings("kill_score", rm_args.name);
}

// spec: Benchmark Ledger - Persists the ledger sorted by metric name

test "write sorts records by name and read parses them back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/test-benchmarks.txt";
    defer fs.cwd().deleteFile(path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) });
    const records = [_]Record{
        .{ .name = "zeta_wall_s", .value = 12.5, .unit = "s", .direction = .min },
        .{ .name = "alpha_nets", .value = 87, .unit = "nets", .direction = .max, .note = "fixture B" },
    };
    try write(a, path, &records);
    const back = try read(a, path);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("alpha_nets", back[0].name);
    try testing.expectEqualStrings("zeta_wall_s", back[1].name);
    try testing.expectEqualStrings("fixture B", back[0].note);
    try testing.expectEqual(@as(f64, 12.5), back[1].value);
    // A ledger that does not exist yet is an empty one, not an error.
    try testing.expectEqual(@as(usize, 0), (try read(a, "zig-cache/no-such-benchmarks.txt")).len);
}

// spec: Benchmark Ledger - Fails closed on a corrupt ledger instead of rewriting it

test "read surfaces BadFormat for a ledger line that is not a record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/test-benchmarks-corrupt.txt";
    defer fs.cwd().deleteFile(path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) });
    var lines = [_][]const u8{"garbage line"};
    try snapshot.write(path, format_version, &lines);
    try testing.expectError(error.BadFormat, read(a, path));
}
