//! Read-only introspection of ONE check's rows: `--list` and `--dry-run`.
//!
//! Baseline mode captures a check's output and REPLACES it with a summary
//! (`N resolved`, `N violation(s) grandfathered`), and `--verbose` prints the
//! byte-identical line — so a debt-cleanup campaign has no way to ask "which
//! frozen rows still fire?" and ends up re-implementing the check's own scan by
//! hand. These two flags answer that from the tool instead:
//!
//!   * `--list` runs the check and splits its findings against the stored
//!     baseline into NEW (firing, unrecorded — what would block), LIVE (firing
//!     AND frozen) and RESOLVED (recorded keys nothing fires behind any more).
//!   * `--dry-run` replays every current finding exactly as the check rendered
//!     it, with no baseline filtering at all — the "tune a new rule" loop, where
//!     the first run is otherwise the one that freezes what you wanted to read.
//!
//! Both are strictly read-only. That is enforced here by clearing the two write
//! switches before the check runs (`metadata_writable`, the accept-path
//! `refresh` set) rather than by trusting the invocation: no baseline is
//! created or pruned, no v1→v3 re-key is persisted, no snapshot is written, and
//! nothing stamps the green cache.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("../fs.zig");
const types = @import("types.zig");
const config_mod = @import("../config.zig");
const reporter = @import("../reporter.zig");
const baseline = @import("../baseline.zig");
const ratchet = @import("../ratchet.zig");
const snapshot = @import("../snapshot.zig");

/// Runs one check under capture and reports it read-only: `--dry-run` replays
/// every finding, `--list` splits them against the baseline. Both flags may be
/// given together — each prints its own section and its own summary line, so
/// neither is ever silently dropped in favour of the other.
pub fn run(ctx: *types.RunCtx, cmd: types.Command) types.RunError!void {
    // Read-only by construction: `metadata_writable` gates every baseline /
    // ratchet / snapshot write and `refresh` is the accept path's force-write
    // set, so clearing both means no code path below can persist anything.
    ctx.metadata_writable = false;
    ctx.refresh = &.{};

    var capture: reporter.Capture = .{ .allocator = ctx.allocator };
    defer capture.deinit();
    try captureRun(ctx, cmd, &capture);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (ctx.dry_run) try reportDryRun(a, cmd.name, &capture);
    if (ctx.list) try reportList(a, ctx, cmd.name, &capture);
}

/// Runs `cmd` with its output diverted into `capture`, swallowing the check's
/// own verdict: an introspection run reports rows, it never gates.
fn captureRun(ctx: *types.RunCtx, cmd: types.Command, capture: *reporter.Capture) types.RunError!void {
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = capture;
    cmd.run(ctx) catch |e| switch (e) {
        error.CheckFailed => {},
        else => return e,
    };
}

/// `--dry-run`: the check's own output verbatim — every current finding, in the
/// check's own rendering — then a closing line that says in words that nothing
/// was written. The wording is the point: the reported cost of the old first-run
/// behaviour was an agent unable to tell "the rule fired" from "the rule froze".
fn reportDryRun(a: Allocator, check_name: []const u8, capture: *const reporter.Capture) Allocator.Error!void {
    reporter.ok("{s}: dry run — every current finding, no baseline filtering", .{check_name});
    if (capture.buf.items.len > 0) reporter.detail("{s}", .{capture.buf.items});
    const rows = try baseline.keyedViolations(a, check_name, capture.buf.items, capture.records.items);
    reporter.ok(
        "{s}: {d} finding(s) — dry run: nothing created, pruned, re-keyed or stamped",
        .{ check_name, rows.len },
    );
}

/// `--list`: route to the ratchet listing for a threshold check (whose stored
/// rows are per-item CEILINGS, not violations) and to the identity listing for
/// everything else.
fn reportList(
    a: Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    capture: *const reporter.Capture,
) types.RunError!void {
    const path = try baseline.pathFor(a, ctx.project_dir, check_name);
    if (!ctx.cfg.policy.usesBaselineFor(check_name, ctx.cfg.baseline)) reporter.detail(
        "  note: baseline mode is off for {s} in this project — every row below blocks\n",
        .{check_name},
    );
    if (ratchet.metricMode(check_name) != null) return listRatchet(a, check_name, path, capture);
    return listIdentity(a, check_name, path, capture);
}

/// The v3 identity path: key each current finding exactly the way the gate keys
/// it, read the stored keys, print the three-way split.
fn listIdentity(
    a: Allocator,
    check_name: []const u8,
    path: []const u8,
    capture: *const reporter.Capture,
) types.RunError!void {
    const keyed = try baseline.keyedViolations(a, check_name, capture.buf.items, capture.records.items);
    const stored = try readStored(a, path);
    const parts = try baseline.splitAgainst(a, stored.keys, try rowsFor(a, keyed, stored.match));
    reporter.ok("{s}: {s}", .{ check_name, try storedHeader(a, path, stored) });
    printRows("NEW", "firing and unrecorded — this is what would block", parts.added);
    printRows("LIVE", "firing AND frozen in the baseline", parts.live);
    printKeys("RESOLVED", "recorded keys with nothing firing behind them", parts.removed);
    reporter.ok(
        "{s}: {d} new, {d} live, {d} resolved (baseline unchanged)",
        .{ check_name, parts.added.len, parts.live.len, parts.removed.len },
    );
}

/// How a stored baseline's rows match current findings. A v3 file holds identity
/// keys; a not-yet-migrated v1 file holds the RENDERED violation lines, and
/// matching it by those lines is what lets a listing be honest without
/// persisting the re-key a read-only run must not perform.
const MatchBy = enum { key, line };

/// A stored baseline as the listing needs it: its rows, how to match them, and
/// whether the file existed at all (which changes what the header can claim).
const Stored = struct {
    keys: []const []const u8,
    match: MatchBy,
    present: bool,
};

/// Reads the stored baseline, falling back to the v1 text format when the file
/// is not v3. A missing file is not an error here — it is the state a brand-new
/// `[[ban]]` / `[[concept]]` rule is in, and the one this flag most exists for.
fn readStored(a: Allocator, path: []const u8) types.RunError!Stored {
    if (try snapshot.readOptional(a, path, baseline.version)) |snap| {
        return .{ .keys = snap.lines, .match = .key, .present = true };
    }
    if (try snapshot.readOptional(a, path, baseline.legacy_version)) |snap| {
        return .{ .keys = snap.lines, .match = .line, .present = true };
    }
    return .{ .keys = &.{}, .match = .key, .present = false };
}

/// The line naming WHAT the split is against: the file, how many rows it holds,
/// and — for a v1 file — that the match was by rendered text rather than key.
fn storedHeader(a: Allocator, path: []const u8, stored: Stored) Allocator.Error![]const u8 {
    if (!stored.present) return std.fmt.allocPrint(
        a,
        "no baseline file at {s} — every row below is unrecorded",
        .{path},
    );
    if (stored.match == .line) return std.fmt.allocPrint(
        a,
        "{s} is still v1 text-keyed ({d} row(s)); matched by rendered line — `guardian-check migrate .` re-keys it",
        .{ path, stored.keys.len },
    );
    return std.fmt.allocPrint(a, "{d} recorded key(s) in {s}", .{ stored.keys.len, path });
}

/// Pairs each current finding with the token it is matched by: its identity key
/// against a v3 baseline, its rendered line against a v1 one.
fn rowsFor(a: Allocator, keyed: []const baseline.Keyed, match: MatchBy) Allocator.Error![]baseline.Keyed {
    const out = try a.alloc(baseline.Keyed, keyed.len);
    for (keyed, 0..) |k, i| out[i] = .{
        .key = if (match == .line) k.line else k.key,
        .line = k.line,
    };
    return out;
}

/// One group of findings: a header carrying the count AND what the group means,
/// then the check's own line per row with the baseline key beneath it (the key
/// is what a reader greps `.guardian/` for). The key line is skipped when it
/// would merely repeat the finding, which is the v1 text-keyed case.
fn printRows(label: []const u8, meaning: []const u8, rows: []const baseline.Keyed) void {
    reporter.detail("  {s} ({d}) — {s}:\n", .{ label, rows.len, meaning });
    for (rows) |r| {
        reporter.detail("    {s}\n", .{r.line});
        if (!std.mem.eql(u8, r.key, r.line)) reporter.detail("      key: {s}\n", .{r.key});
    }
}

/// A group with no live finding behind it (resolved keys, ratchet rows): the
/// stored text is all there is to show.
fn printKeys(label: []const u8, meaning: []const u8, keys: []const []const u8) void {
    reporter.detail("  {s} ({d}) — {s}:\n", .{ label, keys.len, meaning });
    for (keys) |k| reporter.detail("    {s}\n", .{k});
}

/// The threshold-check (baseline v2) path. A ratchet stores a per-item CEILING
/// rather than a violation, so the equivalent listing is per key: the value
/// measured NOW against the value frozen for it. Advisory (recommended-limit)
/// findings are excluded here exactly as they are from the ratchet lifecycle.
fn listRatchet(
    a: Allocator,
    check_name: []const u8,
    path: []const u8,
    capture: *const reporter.Capture,
) types.RunError!void {
    const mode = ratchet.metricMode(check_name).?;
    const current = try ratchet.aggregate(a, capture.records.items, mode);
    const stored = try readCeilings(a, path);
    const parts = try splitCeilings(a, .{
        .stored = stored,
        .current = current,
        .unit = ratchet.unitLabel(check_name),
    });
    reporter.ok("{s}: {d} recorded ceiling(s) in {s}", .{ check_name, stored.len, path });
    printKeys("NEW", "measured now with no recorded ceiling — this is what would block", parts.new);
    printKeys("LIVE", "measured now against the ceiling frozen for it", parts.live);
    printKeys("RESOLVED", "recorded ceilings nothing measures any more", parts.resolved);
    reporter.ok(
        "{s}: {d} new, {d} live, {d} resolved (ratchet unchanged; `guardian-check debt . --live` for headroom)",
        .{ check_name, parts.new.len, parts.live.len, parts.resolved.len },
    );
}

/// The recorded per-item ceilings, or an empty set when the file is absent or
/// still in a pre-ratchet format. Empty reads as "nothing is frozen yet", which
/// is what a listing should say rather than inventing ceilings.
fn readCeilings(a: Allocator, path: []const u8) types.RunError![]const ratchet.Entry {
    const snap = try snapshot.readOptional(a, path, ratchet.version) orelse return &.{};
    return ratchet.decodeLines(a, snap.lines);
}

/// Inputs for the ceiling split, bundled so the renderer takes one argument
/// rather than three positionals of the same shape.
const CeilingInput = struct {
    stored: []const ratchet.Entry,
    current: []const ratchet.Entry,
    unit: []const u8,
};

/// Three pre-rendered groups of ratchet rows. Rendered here rather than by the
/// printer because each row's text depends on which group it landed in.
const CeilingSplit = struct {
    new: []const []const u8,
    live: []const []const u8,
    resolved: []const []const u8,
};

fn splitCeilings(a: Allocator, in: CeilingInput) Allocator.Error!CeilingSplit {
    var new_rows: std.ArrayList([]const u8) = .empty;
    var live_rows: std.ArrayList([]const u8) = .empty;
    var resolved: std.ArrayList([]const u8) = .empty;
    for (in.current) |e| {
        const ceiling = valueFor(in.stored, e.key) orelse {
            const text = "{s} — {d} {s} now, no recorded ceiling";
            try new_rows.append(a, try std.fmt.allocPrint(a, text, .{ e.key, e.value, in.unit }));
            continue;
        };
        const text = "{s} — {d} {s} now, frozen ceiling {d}{s}";
        const over = overMark(e.value, ceiling);
        try live_rows.append(a, try std.fmt.allocPrint(a, text, .{ e.key, e.value, in.unit, ceiling, over }));
    }
    for (in.stored) |e| {
        if (valueFor(in.current, e.key) != null) continue;
        const text = "{s} — frozen at {d} {s}, nothing measures it now";
        try resolved.append(a, try std.fmt.allocPrint(a, text, .{ e.key, e.value, in.unit }));
    }
    return .{
        .new = try new_rows.toOwnedSlice(a),
        .live = try live_rows.toOwnedSlice(a),
        .resolved = try resolved.toOwnedSlice(a),
    };
}

/// The value recorded for `key`, or null when that key is absent.
fn valueFor(entries: []const ratchet.Entry, key: []const u8) ?u64 {
    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

/// Marks a live row already past its own frozen ceiling — the row that fails a
/// gate run — so it is visible without reading two numbers per line.
fn overMark(value: u64, ceiling: u64) []const u8 {
    return if (value > ceiling) " — OVER" else "";
}

// ── Tests ──────────────────────────────────────────────────────────────

fn deleteIfExists(path: []const u8) void {
    fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) }),
    };
}

/// A stand-in check for the read-only test: two findings and a failing verdict,
/// which `run` must swallow — introspection reports rows, it never gates.
fn twoFindings(_: *types.RunCtx) types.RunError!void {
    reporter.emit(.{ .check = "demo", .file = "src/a.zig", .line = 1, .message = "first" });
    reporter.emit(.{ .check = "demo", .file = "src/b.zig", .line = 2, .message = "second" });
    return error.CheckFailed;
}

// spec: Baseline Introspection - Writes no baseline ratchet or snapshot on an introspection run

test "run lists a check's rows and leaves the project metadata untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg: config_mod.Config = .{};
    var ctx: types.RunCtx = .{
        .allocator = arena.allocator(),
        .project_dir = "zig-cache/introspect-readonly",
        .cfg = &cfg,
        .quiet = false,
        .list = true,
        // An accept-shaped invocation must STILL write nothing: `run` clears
        // both write switches itself rather than trusting how it was reached.
        .metadata_writable = true,
        .refresh = &.{"demo"},
    };
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default;
    defer reporter.default = prior;
    reporter.default = .{ .capture = &cap };

    try run(&ctx, .{ .name = "demo", .summary = "", .scope = .per_file, .run = twoFindings });

    // With no baseline file every row is NEW — the state a brand-new rule is
    // in, and the run that used to read as "2 violation(s) grandfathered".
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "demo: 2 new, 0 live, 0 resolved") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "no baseline file") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "src/b.zig:2: second") != null);
    // Read-only: the run may not even have created the metadata directory.
    try std.testing.expectError(error.FileNotFound, fs.cwd().access(ctx.project_dir, .{}));
    try std.testing.expect(!ctx.metadata_writable);
}

// spec: Baseline Introspection - Reads a stored metadata file as absent when it is missing or in another format version

test "readStored reports an absent file, a v1 file, and a v3 file distinctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/test-introspect-stored.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // Absent: `snapshot.readOptional` is what makes "nothing recorded" and
    // "recorded in a format I don't speak" the same non-error answer for a
    // read-only reader, so neither can fail a listing.
    try std.testing.expect((try snapshot.readOptional(a, path, baseline.version)) == null);
    try std.testing.expect(!(try readStored(a, path)).present);

    // A v1 text baseline is READ, not re-keyed: the re-key is a write, and this
    // command may not perform one — so it is matched by rendered line instead.
    var v1_lines = [_][]const u8{"a.zig:1: one"};
    try snapshot.write(path, baseline.legacy_version, &v1_lines);
    const legacy = try readStored(a, path);
    try std.testing.expectEqual(MatchBy.line, legacy.match);
    try std.testing.expectEqualStrings("a.zig:1: one", legacy.keys[0]);

    var v3_lines = [_][]const u8{"c|a.zig|one"};
    try snapshot.write(path, baseline.version, &v3_lines);
    const current = try readStored(a, path);
    try std.testing.expectEqual(MatchBy.key, current.match);
    try std.testing.expectEqualStrings("c|a.zig|one", current.keys[0]);
}

// spec: Baseline Introspection - Matches a v1 text baseline by rendered line instead of identity key

test "rowsFor keys rows by identity for v3 and by rendered line for v1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keyed = [_]baseline.Keyed{.{ .key = "c|a.zig|one", .line = "a.zig:1: one" }};
    // v3: the identity key is what the file stores, so it is what matches.
    const v3 = try rowsFor(a, &keyed, .key);
    try std.testing.expectEqualStrings("c|a.zig|one", v3[0].key);
    // v1 stores the rendered text; matching by it is what makes a listing
    // honest on a consumer that has not run `migrate` yet — the re-key is a
    // WRITE, and this command may not perform one.
    const v1 = try rowsFor(a, &keyed, .line);
    try std.testing.expectEqualStrings("a.zig:1: one", v1[0].key);
    try std.testing.expectEqualStrings("a.zig:1: one", v1[0].line);
}

// spec: Baseline Introspection - Lists a threshold check's keys with each live value against its frozen ceiling

test "splitCeilings reports live values against ceilings and marks the ones over" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored = [_]ratchet.Entry{
        .{ .key = "src/big.zig", .value = 1200 },
        .{ .key = "src/held.zig", .value = 900 },
        .{ .key = "src/gone.zig", .value = 700 },
    };
    const current = [_]ratchet.Entry{
        .{ .key = "src/big.zig", .value = 1300 },
        .{ .key = "src/held.zig", .value = 900 },
        .{ .key = "src/fresh.zig", .value = 1100 },
    };
    const parts = try splitCeilings(a, .{ .stored = &stored, .current = &current, .unit = "code lines" });
    try std.testing.expectEqual(@as(usize, 1), parts.new.len);
    try std.testing.expectEqual(@as(usize, 2), parts.live.len);
    try std.testing.expectEqual(@as(usize, 1), parts.resolved.len);
    // A key past its own frozen ceiling is the row that fails a gate run, so it
    // is marked rather than left to a reader comparing two numbers per line.
    try std.testing.expect(std.mem.indexOf(u8, parts.live[0], "1300 code lines now, frozen ceiling 1200") != null);
    try std.testing.expect(std.mem.endsWith(u8, parts.live[0], " — OVER"));
    try std.testing.expect(!std.mem.endsWith(u8, parts.live[1], " — OVER"));
    try std.testing.expect(std.mem.indexOf(u8, parts.new[0], "no recorded ceiling") != null);
}

// spec: Baseline Introspection - Names the baseline file a listing is split against

test "storedHeader distinguishes an absent, a v1, and a v3 baseline file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = ".guardian/baselines/concept.txt";
    // Absent is the state a brand-new rule is in — the header must say so
    // rather than implying an empty baseline was consulted.
    const absent = try storedHeader(a, path, .{ .keys = &.{}, .match = .key, .present = false });
    try std.testing.expect(std.mem.indexOf(u8, absent, "no baseline file") != null);
    const rows = [_][]const u8{"a.zig:1: one"};
    const legacy = try storedHeader(a, path, .{ .keys = &rows, .match = .line, .present = true });
    try std.testing.expect(std.mem.indexOf(u8, legacy, "v1 text-keyed") != null);
    const current = try storedHeader(a, path, .{ .keys = &rows, .match = .key, .present = true });
    try std.testing.expect(std.mem.indexOf(u8, current, "1 recorded key(s)") != null);
}
