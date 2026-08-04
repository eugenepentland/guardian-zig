//! Current-value readout of the per-item ratchet metrics, shared by the `size`
//! command and `debt --current`.
//!
//! A ratchet freezes each item at the value guardian measured for it, but
//! nothing could report that value BACK: `debt` prints the frozen ceilings, and
//! a check prints a number only once an item is already over its cap. An agent
//! trimming a file toward a ceiling therefore had to re-run the whole gate to
//! read the number back — six ~90s cycles in one recorded case — and a
//! hand-rolled `grep -c` disagrees with guardian by design (the file-size metric
//! excludes `test { ... }` blocks, a 170-line gap in that same case).
//!
//! Every value below comes from the check's OWN measurement function
//! (`file_size.codeLines`, `line_length.analyzeContentWithLimit`,
//! `ast.fnDeclInfos`, `ast.allFns`, `ast.pubContainers`), so a number printed
//! here matches the gate byte for byte. Nothing is re-derived. The five
//! ratchets whose metric exists only inside a threshold scan (nesting-depth,
//! cognitive-complexity, struct-method-cap, optional-density,
//! bool-ops-per-condition) are deliberately absent rather than approximated,
//! and `unmeasured_checks` names them so a report can say so out loud.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const ratchet = @import("ratchet.zig");
const snapshot = @import("snapshot.zig");
const walk = @import("walk.zig");
const ast = @import("ast/parser.zig");
const file_size = @import("checks/file_size.zig");
const line_length = @import("checks/line_length.zig");

/// The ratcheted checks this module can report a current value for. Each one's
/// metric is produced by the check's own measurement function, so the number
/// matches what the gate would ratchet.
pub const measured_checks = [_][]const u8{
    "file-size",
    "line-length",
    "function-length",
    "function-size",
    "type-size",
};

/// The ratcheted checks whose metric is computed inside the check's threshold
/// scan and has no reusable measurement entry point. Reporting them would mean
/// re-implementing the count — the one thing this module must never do — so
/// they are named instead, and a report prints the list rather than letting
/// silence read as "within cap".
pub const unmeasured_checks = [_][]const u8{
    "nesting-depth",
    "cognitive-complexity",
    "struct-method-cap",
    "optional-density",
    "bool-ops-per-condition",
};

/// One measured subject: the check that would ratchet it, the ratchet key the
/// gate writes for it (so a ceiling lookup is an exact match, never a guess),
/// the human name of the subject within its file, the value measured right now,
/// and the check's two caps (`cap` == `hard_cap` for a single-limit check).
pub const Item = struct {
    check: []const u8,
    key: []const u8,
    subject: []const u8,
    value: u64,
    cap: u32,
    hard_cap: u32,
};

/// Measures every reportable ratchet metric for one already-read source file.
/// `rel_path` must be the walker-relative path (`src/foo.zig`) the checks use,
/// because it is half of every ratchet key. A check disabled in config is
/// skipped: guardian is not measuring it, so neither is this.
pub fn measureFile(
    arena: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
    cfg: *const config_mod.Config,
) Allocator.Error![]const Item {
    var items: std.ArrayList(Item) = .empty;
    try appendFileSize(arena, &items, rel_path, content, cfg);
    try appendLineLength(arena, &items, rel_path, content, cfg);
    try appendFunctionLength(arena, &items, rel_path, content, cfg);
    try appendFunctionSize(arena, &items, rel_path, content, cfg);
    try appendTypeSize(arena, &items, rel_path, content, cfg);
    return items.toOwnedSlice(arena);
}

/// file-size: production (non-test) line count, straight from the check's own
/// `codeLines` — the number a `grep -c` cannot reproduce.
fn appendFileSize(
    arena: Allocator,
    items: *std.ArrayList(Item),
    rel_path: []const u8,
    content: [:0]const u8,
    cfg: *const config_mod.Config,
) Allocator.Error!void {
    try items.append(arena, .{
        .check = "file-size",
        .key = rel_path,
        .subject = rel_path,
        .value = try file_size.codeLines(content),
        .cap = cfg.max_file_lines,
        .hard_cap = cfg.hard_max_file_lines,
    });
}

/// line-length: the ratchet counts records, and only hard-limit records reach
/// it, so the reported value is the number of lines over the HARD limit — the
/// recommended limit only ever warns and is never ratcheted.
fn appendLineLength(
    arena: Allocator,
    items: *std.ArrayList(Item),
    rel_path: []const u8,
    content: [:0]const u8,
    cfg: *const config_mod.Config,
) Allocator.Error!void {
    if (!cfg.line_length.enabled) return;
    const over = try line_length.analyzeContentWithLimit(arena, rel_path, content, cfg.line_length.hard_max_len);
    try items.append(arena, .{
        .check = "line-length",
        .key = rel_path,
        .subject = rel_path,
        .value = over.len,
        .cap = cfg.line_length.max_len,
        .hard_cap = cfg.line_length.hard_max_len,
    });
}

/// function-length: per-fn source-line span from the shared AST helper the
/// check itself consumes.
fn appendFunctionLength(
    arena: Allocator,
    items: *std.ArrayList(Item),
    rel_path: []const u8,
    content: [:0]const u8,
    cfg: *const config_mod.Config,
) Allocator.Error!void {
    if (!cfg.function_length.enabled) return;
    for (try ast.fnDeclInfos(arena, content)) |f| {
        try items.append(arena, .{
            .check = "function-length",
            .key = try subjectKey(arena, rel_path, f.name),
            .subject = f.name,
            .value = f.line_count,
            .cap = cfg.function_length.max_lines,
            .hard_cap = cfg.function_length.hard_max_lines,
        });
    }
}

/// function-size: runtime parameter count, with `comptime` specialization
/// inputs subtracted exactly as the check does.
fn appendFunctionSize(
    arena: Allocator,
    items: *std.ArrayList(Item),
    rel_path: []const u8,
    content: [:0]const u8,
    cfg: *const config_mod.Config,
) Allocator.Error!void {
    if (!cfg.function_size.enabled) return;
    for (try ast.allFns(arena, content)) |f| {
        try items.append(arena, .{
            .check = "function-size",
            .key = try subjectKey(arena, rel_path, f.name),
            .subject = f.name,
            .value = f.param_count - f.comptime_param_count,
            .cap = cfg.function_size.max_params,
            .hard_cap = cfg.function_size.max_params,
        });
    }
}

/// type-size: declared field count per pub container, skipping enums and
/// excluded paths the same way the check does.
fn appendTypeSize(
    arena: Allocator,
    items: *std.ArrayList(Item),
    rel_path: []const u8,
    content: [:0]const u8,
    cfg: *const config_mod.Config,
) Allocator.Error!void {
    if (!cfg.type_size.enabled or isExcluded(rel_path, cfg.type_size.exclude)) return;
    for (try ast.pubContainers(arena, content)) |c| {
        if (c.kind == .enum_) continue;
        try items.append(arena, .{
            .check = "type-size",
            .key = try subjectKey(arena, rel_path, c.name),
            .subject = c.name,
            .value = c.field_count,
            .cap = cfg.type_size.max_fields,
            .hard_cap = cfg.type_size.max_fields,
        });
    }
}

/// True when `rel_path` matches any exclude pattern — the type-size check's own
/// exemption rule, mirrored so an exempt file reports no field-count item.
fn isExcluded(rel_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (walk.matchGlob(rel_path, p)) return true;
    }
    return false;
}

/// The `<file>|<name>` ratchet key every per-subject threshold check writes.
fn subjectKey(arena: Allocator, rel_path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}|{s}", .{ rel_path, name });
}

/// The frozen ceilings recorded for `check_name`, read from its committed
/// per-item ratchet under `.guardian/baselines/`. A missing, legacy (v1), or
/// unreadable file means "no ceiling recorded" — an empty slice, never an
/// error — because a read-only report must not fail on absent metadata. Only
/// OOM propagates.
pub fn ceilings(
    arena: Allocator,
    project_dir: []const u8,
    check_name: []const u8,
) Allocator.Error![]const ratchet.Entry {
    const path = try std.fmt.allocPrint(arena, "{s}/.guardian/baselines/{s}.txt", .{ project_dir, check_name });
    const snap = snapshot.read(arena, path, ratchet.version) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    return ratchet.decodeLines(arena, snap.lines);
}

/// The ceiling recorded for `key`, or null when this item has never been
/// ratcheted (so its only limit is the check's cap).
pub fn ceilingFor(entries: []const ratchet.Entry, key: []const u8) ?u64 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

/// How a measured value sits against its frozen ceiling. `none` means no
/// ceiling is recorded; `over` is the state that fails a gate run.
pub const Standing = enum { none, headroom, at_ceiling, over };

/// Classifies `value` against `ceiling` — the one comparison every current-vs-
/// ceiling report renders, kept pure so both the size command and the debt
/// section agree on what "at ceiling" means (no headroom left, not yet failing).
pub fn standingOf(value: u64, ceiling: ?u64) Standing {
    const c = ceiling orelse return .none;
    if (value > c) return .over;
    if (value == c) return .at_ceiling;
    return .headroom;
}

/// Renders the current-vs-ceiling verdict both reports print. It lives here,
/// not in either caller, so `size` and `debt --current` cannot drift on the one
/// sentence that matters — and so "at ceiling" is always spelled out: it is
/// green, but the next added line reds the gate, which the numbers alone hide.
pub fn ceilingPhrase(arena: Allocator, value: u64, ceiling: ?u64) Allocator.Error![]const u8 {
    const c = ceiling orelse return "no ratchet ceiling recorded";
    return switch (standingOf(value, c)) {
        .over => std.fmt.allocPrint(arena, "{d} vs ceiling {d} — OVER by {d}; the gate blocks", .{
            value,
            c,
            value - c,
        }),
        .at_ceiling => std.fmt.allocPrint(arena, "{d} vs ceiling {d} — AT CEILING, 0 headroom", .{ value, c }),
        .none, .headroom => std.fmt.allocPrint(arena, "{d} vs ceiling {d} — {d} of headroom", .{ value, c, c - value }),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const sample_source =
    \\//! header
    \\const std = @import("std");
    \\
    \\pub const Wide = struct {
    \\    a: u8,
    \\    b: u8,
    \\    c: u8,
    \\};
    \\
    \\pub fn wideFn(a: u8, b: u8, c: u8, d: u8) u8 {
    \\    return a + b + c + d;
    \\}
    \\
    \\test "t" {
    \\    _ = wideFn(1, 2, 3, 4);
    \\}
    \\
;

/// The measured item for `check_name`, or null. Test-local lookup so each
/// assertion below reads as a per-check statement.
fn itemFor(items: []const Item, check_name: []const u8, subject: []const u8) ?Item {
    for (items) |it| {
        if (std.mem.eql(u8, it.check, check_name) and std.mem.eql(u8, it.subject, subject)) return it;
    }
    return null;
}

// spec: size introspection - Measures a file's ratcheted metrics with the checks' own measurement code

test "measureFile reports file, function, and type metrics for one file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config_mod.Config = .{};
    const items = try measureFile(a, "src/sample.zig", sample_source, &cfg);

    // file-size counts production lines only: the 3-line test block is excluded
    // exactly as the gate excludes it (16 total - 3 in the test block).
    const fs_item = itemFor(items, "file-size", "src/sample.zig").?;
    try testing.expectEqual(@as(u64, 13), fs_item.value);
    try testing.expectEqual(@as(u32, 1000), fs_item.cap);
    try testing.expectEqual(@as(u32, 10_000), fs_item.hard_cap);
    // The key is the ratchet key the gate writes, so a ceiling lookup matches.
    try testing.expectEqualStrings("src/sample.zig", fs_item.key);

    const len_item = itemFor(items, "function-length", "wideFn").?;
    try testing.expectEqual(@as(u64, 3), len_item.value);
    try testing.expectEqualStrings("src/sample.zig|wideFn", len_item.key);

    const params = itemFor(items, "function-size", "wideFn").?;
    try testing.expectEqual(@as(u64, 4), params.value);

    const fields = itemFor(items, "type-size", "Wide").?;
    try testing.expectEqual(@as(u64, 3), fields.value);
    try testing.expectEqualStrings("src/sample.zig|Wide", fields.key);

    // line-length reports the count of lines over the HARD limit — the only
    // tier the ratchet ever records.
    const lines = itemFor(items, "line-length", "src/sample.zig").?;
    try testing.expectEqual(@as(u64, 0), lines.value);
    try testing.expectEqual(@as(u32, 240), lines.hard_cap);
}

// spec: size introspection - Skips a disabled or excluded check when measuring a file

test "measureFile honors disabled checks and type-size excludes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config_mod.Config = .{
        .line_length = .{ .enabled = false },
        .type_size = .{ .exclude = &.{"src/sample.zig"} },
    };
    const items = try measureFile(a, "src/sample.zig", sample_source, &cfg);
    // Not measured: guardian isn't ratcheting them for this file either.
    try testing.expect(itemFor(items, "line-length", "src/sample.zig") == null);
    try testing.expect(itemFor(items, "type-size", "Wide") == null);
    // file-size has no enable flag and is always reported.
    try testing.expect(itemFor(items, "file-size", "src/sample.zig") != null);
}

// spec: size introspection - Classifies a measured value against its frozen ceiling

test "standingOf separates headroom, at-ceiling, and over-ceiling" {
    try testing.expect(standingOf(100, null) == .none);
    try testing.expect(standingOf(90, 100) == .headroom);
    // The case a ratchet makes invisible: sitting exactly ON the ceiling is
    // green but has zero room, so the next added line reds the gate.
    try testing.expect(standingOf(100, 100) == .at_ceiling);
    try testing.expect(standingOf(101, 100) == .over);
}

// spec: size introspection - Looks up a frozen ceiling by the gate's own ratchet key

test "ceilingFor matches a recorded key and reports none for an unratcheted one" {
    const entries = [_]ratchet.Entry{
        .{ .key = "src/a.zig", .value = 10_005 },
        .{ .key = "src/b.zig|parse", .value = 130 },
    };
    try testing.expectEqual(@as(?u64, 10_005), ceilingFor(&entries, "src/a.zig"));
    try testing.expectEqual(@as(?u64, 130), ceilingFor(&entries, "src/b.zig|parse"));
    try testing.expect(ceilingFor(&entries, "src/c.zig") == null);
}

// spec: size introspection - Reads a check's frozen ceilings and tolerates a missing ratchet

test "ceilings reads a committed ratchet file and returns empty when absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No .guardian/baselines/ in this repo: an absent ratchet is "no ceiling
    // recorded", never an error — a read-only report must not fail on it.
    const absent = try ceilings(a, ".", "file-size");
    try testing.expectEqual(@as(usize, 0), absent.len);
    const missing_dir = try ceilings(a, "zig-cache/no-such-project", "file-size");
    try testing.expectEqual(@as(usize, 0), missing_dir.len);
}

// spec: size introspection - Names the ratchets it cannot measure without re-implementing them

test "the measured and unmeasured check lists together cover every ratchet" {
    // Every name in both lists must be a real ratchet, and together they must
    // account for all ten — otherwise a report silently omits a ratchet.
    const every = measured_checks ++ unmeasured_checks;
    try testing.expectEqual(@as(usize, 10), every.len);
    for (every) |name| try testing.expect(ratchet.metricMode(name) != null);
}

// spec: size introspection - Reports a measured value against its ceiling with the headroom left

test "ceilingPhrase names headroom, the zero-headroom ceiling, and an overage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("no ratchet ceiling recorded", try ceilingPhrase(a, 900, null));
    try testing.expectEqualStrings("900 vs ceiling 1000 — 100 of headroom", try ceilingPhrase(a, 900, 1000));
    // The case the numbers alone hide: green, but the next line reds the gate.
    try testing.expectEqualStrings("1000 vs ceiling 1000 — AT CEILING, 0 headroom", try ceilingPhrase(a, 1000, 1000));
    try testing.expectEqualStrings(
        "10005 vs ceiling 10000 — OVER by 5; the gate blocks",
        try ceilingPhrase(a, 10_005, 10_000),
    );
}
