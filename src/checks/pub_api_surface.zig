//! pub-api-surface — the snapshot of every public declaration in `src/`.
//!
//! Each `pub fn` entry carries its full prototype (folding in the retired
//! spec-drift check), so one snapshot catches an added/removed/renamed symbol
//! AND a signature change on an existing one. Drift fails the check until the
//! snapshot is accepted, which is what makes every widening of the public
//! surface a deliberate, reviewable act.
//!
//! A live `[measurement]` path bridges its own drift to the non-blocking
//! MEASURE channel on a local run (a profiling counter another module reads has
//! to be `pub`); the stored snapshot is never rewritten from that filtered view,
//! because a refresh voids the bridge. See measurement.zig.
//!
//! Public-surface snapshot: every `pub fn` (with its full prototype) and every
//! `pub const` container in `src/` is recorded in `.guardian/pub-api.txt`, and
//! any addition, removal, or signature change fails until it is accepted. It is
//! the check that makes a widened API a deliberate act rather than a side
//! effect, and it also subsumes the retired spec-drift check.
//!
//! Removals are filtered first: a symbol whose file is missing from the working
//! tree AND gitignored is unbuilt generated output, not a removal, so it is
//! reported as skipped instead of counted (see `withoutPhantoms`).

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const measurement = @import("../measurement.zig");
const missing_inputs = @import("../missing_inputs.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const snapshot_leaf = "pub-api.txt";
const check_name = "pub-api-surface";
// v2: fn entries now include the full prototype (folded in spec-drift).
const snapshot_version: u32 = 2;

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    // fn entries carry the full prototype so this single snapshot catches both
    // surface changes (add/remove/rename) AND signature drift on an existing
    // pub fn — subsuming the former standalone spec-drift check.
    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        const line = try std.fmt.allocPrint(a, "{s}::{s} | {s}", .{ entry.rel_path, f.name, f.proto_span });
        try ctx.lines.append(a, line);
    }
    const consts = if (entry.tree) |t| try ast.pubConstsFromTree(a, t) else try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        const line = try std.fmt.allocPrint(a, "{s}::{s} {s}", .{ entry.rel_path, c.name, @tagName(c.kind) });
        try ctx.lines.append(a, line);
    }
}

fn collectLines(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    source_index: ?*const ast_index.Index,
) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var ctx: CollectCtx = .{ .allocator = allocator, .lines = &lines };
    try ast_index.runSrc(source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });
    return lines.toOwnedSlice(allocator);
}

/// Entry point for the pub-api-surface check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    const snap_path = try snapshot_helper.snapshotPath(allocator, project_dir, snapshot_leaf);
    const lines = try collectLines(allocator, project_dir, ctx_param.source_index);

    const force = snapshot_helper.shouldUpdateForCtx(ctx_param, check_name);
    const spec: snapshot_helper.SnapSpec = .{ .path = snap_path, .version = snapshot_version };
    const outcome = try snapshot_helper.lifecycle(allocator, spec, lines, force, ctx_param.metadata_writable);
    return reportOutcome(allocator, try bridgeMeasured(
        ctx_param,
        allocator,
        try withoutPhantoms(ctx_param, outcome, lines.len),
        lines.len,
    ));
}

/// Defers surface drift attributed to a live `[measurement]` path — a `pub var`
/// counter a second module reads, which drifts the snapshot for the lifetime of
/// the experiment — to the non-blocking MEASURE channel, and returns the outcome
/// for whatever real drift remains. The stored snapshot is never REWRITTEN from
/// this filtered view: a refresh (accept / GUARDIAN_UPDATE_SNAPSHOT) voids the
/// bridge, so the surface Guardian records is always the real one. Inert (an
/// identity function) unless the bridge is live for this run.
fn bridgeMeasured(
    ctx_param: *registry.RunCtx,
    allocator: std.mem.Allocator,
    outcome: snapshot_helper.Outcome,
    line_count: usize,
) registry.RunError!snapshot_helper.Outcome {
    if (outcome != .drift) return outcome;
    var exempt = measurement.forCheck(allocator, ctx_param, check_name);
    const added = try partitionDrift(allocator, &exempt, outcome.drift.added, "+");
    const removed = try partitionDrift(allocator, &exempt, outcome.drift.removed, "-");
    try exempt.report();
    if (added.len == 0 and removed.len == 0) return .{ .unchanged = line_count };
    return .{ .drift = .{ .added = added, .removed = removed } };
}

/// Splits one side of a surface diff: entries whose file sits in a measurement
/// path are deferred to `exempt` (prefixed with the diff `sign` so the MEASURE
/// listing reads like the drift report), the rest are returned as real drift.
fn partitionDrift(
    allocator: std.mem.Allocator,
    exempt: *measurement.Exemption,
    entries: []const []const u8,
    sign: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (entries) |line| {
        const path = fileOf(line);
        if (exempt.covers(path)) {
            try exempt.record(path, try std.fmt.allocPrint(allocator, "{s} {s}", .{ sign, line }));
            continue;
        }
        try kept.append(allocator, line);
    }
    return kept.toOwnedSlice(allocator);
}

/// The source file a snapshot entry belongs to: the `<file>` of
/// `<file>::<name> …`. Whole line when the separator is absent (defensive — the
/// collector always emits it), which simply never matches a measurement path.
fn fileOf(line: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, line, "::") orelse return line;
    return line[0..sep];
}

/// Drops "removed" symbols whose file is missing from this worktree AND
/// gitignored — generated output nobody built here, not a real API removal.
/// A drift that consists only of those becomes `unchanged` (green, skipped with
/// a notice); anything else keeps failing. The narrow predicate is what keeps a
/// genuine removal — a tracked file, deleted — reporting exactly as before.
fn withoutPhantoms(
    ctx: *registry.RunCtx,
    outcome: snapshot_helper.Outcome,
    entries: usize,
) std.mem.Allocator.Error!snapshot_helper.Outcome {
    if (outcome != .drift) return outcome;
    const a = ctx.allocator;
    const d = outcome.drift;
    var files: std.ArrayList([]const u8) = .empty;
    for (d.removed) |line| {
        if (missing_inputs.pathFromLine(line)) |p| try files.append(a, p);
    }
    if (files.items.len == 0) return outcome;
    const phantoms = try missing_inputs.phantomPaths(a, ctx.project_dir, files.items);
    if (phantoms.len == 0) return outcome;

    var kept: std.ArrayList([]const u8) = .empty;
    for (d.removed) |line| {
        const p = missing_inputs.pathFromLine(line) orelse {
            try kept.append(a, line);
            continue;
        };
        if (!missing_inputs.contains(phantoms, p)) try kept.append(a, line);
    }
    try noticeSkipped(a, d.removed.len - kept.items.len, phantoms);
    if (kept.items.len == 0 and d.added.len == 0) return .{ .unchanged = entries };
    return .{ .drift = .{ .added = d.added, .removed = try kept.toOwnedSlice(a) } };
}

/// Reports skipped-because-unbuilt symbols on the advisory channel: visible
/// even under --quiet and inside baseline capture, but never a violation — so
/// nothing here is counted, and `accept` is never offered for it.
fn noticeSkipped(
    a: std.mem.Allocator,
    skipped: usize,
    phantoms: []const []const u8,
) std.mem.Allocator.Error!void {
    if (skipped == 0) return;
    const message = try std.fmt.allocPrint(
        a,
        "{d} symbol(s) skipped in {d} file(s) absent from this worktree (e.g. {s}) — {s}",
        .{ skipped, phantoms.len, phantoms[0], missing_inputs.hint },
    );
    reporter.warn(.{ .check = check_name, .message = message });
}

fn reportOutcome(a: std.mem.Allocator, outcome: snapshot_helper.Outcome) registry.RunError!void {
    switch (outcome) {
        .created => |n| ok("pub-api snapshot created ({d} entries)", .{n}),
        .updated => |n| ok("pub-api snapshot updated ({d} entries)", .{n}),
        .unchanged => |n| ok("pub-api unchanged ({d} entries)", .{n}),
        .version_mismatch => {
            fail("pub-api snapshot version mismatch", .{});
            print("  fix: guardian-check accept {s} . after reviewing the complete surface diff\n", .{check_name});
            snapshot_helper.printAcceptPaths(check_name);
            return error.CheckFailed;
        },
        .drift => |d| return reportDrift(a, d),
    }
}

/// The stable identity of a snapshot entry (C3): `<file>::<name>` — the line
/// prefix up to the first space, before a fn's ` | <proto>` or a const's
/// ` <kind>`.
fn keyOf(line: []const u8) []const u8 {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return line;
    return line[0..sp];
}

/// The bare symbol name: the key with its `<file>::` prefix stripped.
fn nameOf(line: []const u8) []const u8 {
    const key = keyOf(line);
    const sep = std.mem.indexOf(u8, key, "::") orelse return key;
    return key[sep + name_sep.len ..];
}

const name_sep = "::";
/// A fn entry's separator between the key and its prototype.
const proto_sep = "| ";

/// The signature half of an entry: everything after the key, with a fn's `| `
/// separator stripped so a paired line reads `fn f() void -> fn f(a: u8) void`
/// instead of repeating the bar. Empty for a key-only line (defensive — the
/// collector always emits a signature).
fn sigOf(line: []const u8) []const u8 {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return "";
    const rest = line[sp + 1 ..];
    if (std.mem.startsWith(u8, rest, proto_sep)) return rest[proto_sep.len..];
    return rest;
}

/// A symbol present on both sides of the diff under the same key, with a
/// different signature — one edit, reported as one line rather than as a `+`
/// and a `-` at opposite ends of an alphabetical listing.
const Changed = struct { key: []const u8, old: []const u8, new: []const u8 };

/// A symbol whose signature text is byte-identical but whose file changed: a
/// relocation, not a widening or a shrinking of the surface.
const Moved = struct { from: []const u8, to: []const u8, name: []const u8 };

/// A surface diff partitioned for review: paired edits and relocations lifted
/// out, leaving only the genuinely one-sided entries under `new` / `removed`.
const Grouped = struct {
    new: []const []const u8,
    changed: []const Changed,
    moved: []const Moved,
    removed: []const []const u8,
};

/// True when two entries share a key — the same symbol in the same file, so the
/// difference between them is a signature change.
fn sameKey(old: []const u8, new: []const u8) bool {
    return std.mem.eql(u8, keyOf(old), keyOf(new));
}

/// True when `new` is `old` relocated: same bare name, byte-identical
/// signature, different file.
fn isRelocation(old: []const u8, new: []const u8) bool {
    if (std.mem.eql(u8, fileOf(old), fileOf(new))) return false;
    return std.mem.eql(u8, nameOf(old), nameOf(new)) and std.mem.eql(u8, sigOf(old), sigOf(new));
}

/// Index of the first not-yet-paired removed entry satisfying `pred` against
/// `line`. The `taken` flags make the pairing a greedy one-to-one match, so a
/// name that moved out of two files can never be consumed twice.
fn pairIndex(
    removed: []const []const u8,
    taken: []const bool,
    line: []const u8,
    pred: *const fn ([]const u8, []const u8) bool,
) ?usize {
    for (removed, taken, 0..) |old, used, i| {
        if (!used and pred(old, line)) return i;
    }
    return null;
}

/// Partitions a raw added/removed diff into the four review categories. Both
/// the delta summary and the listing read from this one pass, so the counts a
/// reviewer sees always describe the lines printed underneath them.
fn group(
    a: std.mem.Allocator,
    added: []const []const u8,
    removed: []const []const u8,
) std.mem.Allocator.Error!Grouped {
    const taken = try a.alloc(bool, removed.len);
    @memset(taken, false);
    var new_syms: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList(Changed) = .empty;
    var moved: std.ArrayList(Moved) = .empty;
    for (added) |line| {
        if (pairIndex(removed, taken, line, sameKey)) |i| {
            taken[i] = true;
            try changed.append(a, .{ .key = keyOf(line), .old = sigOf(removed[i]), .new = sigOf(line) });
        } else if (pairIndex(removed, taken, line, isRelocation)) |i| {
            taken[i] = true;
            try moved.append(a, .{ .from = fileOf(removed[i]), .to = fileOf(line), .name = nameOf(line) });
        } else try new_syms.append(a, line);
    }
    var gone: std.ArrayList([]const u8) = .empty;
    for (removed, taken) |line, used| if (!used) try gone.append(a, line);
    return .{
        .new = try new_syms.toOwnedSlice(a),
        .changed = try changed.toOwnedSlice(a),
        .moved = try moved.toOwnedSlice(a),
        .removed = try gone.toOwnedSlice(a),
    };
}

/// The verdict clause of the delta line: what the reviewer has to do about it.
fn deltaVerdict(g: Grouped) []const u8 {
    if (g.changed.len == 0 and g.removed.len == 0 and g.new.len == 0)
        return "relocation only, signatures identical";
    return "review changed/removed below before accepting";
}

/// The one-line delta classification, so accept-vs-investigate is decidable
/// without diffing snapshots by hand (C3). An additions-only delta carries the
/// accept commands on the next line: nothing changed or vanished, so the review
/// and the fix are the same step.
fn printDelta(g: Grouped) void {
    if (g.changed.len == 0 and g.removed.len == 0 and g.moved.len == 0) {
        print("  delta: {d} new symbol(s), 0 changed, 0 removed — pure additions, safe to accept\n", .{g.new.len});
        print(
            "    accept: guardian-check accept {s} .   (or {s}={s} zig build)\n",
            .{ check_name, snapshot_helper.update_env, check_name },
        );
        return;
    }
    print(
        "  delta: {d} new, {d} changed, {d} removed, {d} moved — {s}\n",
        .{ g.new.len, g.changed.len, g.removed.len, g.moved.len, deltaVerdict(g) },
    );
}

/// The grouped listing: paired signature edits first (the whole edit on one
/// line), then relocations, then the genuinely one-sided entries.
fn printGroups(g: Grouped) void {
    if (g.changed.len > 0) print("  changed:\n", .{});
    for (g.changed) |c| print("    ~ {s} | {s} -> {s}\n", .{ c.key, c.old, c.new });
    for (g.moved) |m| print("  moved: {s} -> {s} :: {s}\n", .{ m.from, m.to, m.name });
    for (g.removed) |line| print("  - {s}\n", .{line});
    for (g.new) |line| print("  + {s}\n", .{line});
}

fn reportDrift(a: std.mem.Allocator, d: @import("../snapshot.zig").Diff) registry.RunError!void {
    fail("pub-api FAILED — surface changed", .{});
    const g = try group(a, d.added, d.removed);
    printDelta(g);
    printGroups(g);
    print("  fix: guardian-check accept {s} . after reviewing the complete surface diff\n", .{check_name});
    snapshot_helper.printAcceptPaths(check_name);
    return error.CheckFailed;
}

// spec: Measurement Mode - Defers public-surface drift inside a measurement path

test "bridgeMeasured defers a measurement path's drift and keeps real drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const config = @import("../config.zig");
    const cfg: config.Config = .{ .measurement = .{ .paths = &.{"src/hot.zig"} } };
    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };

    // A counter in the measurement path plus a genuine new export elsewhere:
    // only the second is real drift, and the check still fails on it.
    const mixed: snapshot_helper.Outcome = .{ .drift = .{
        .added = &.{ "src/hot.zig::dbg_hits value", "src/other.zig::run | fn run() void" },
        .removed = &.{},
    } };
    const kept = try bridgeMeasured(&ctx, a, mixed, 2);
    try std.testing.expect(kept == .drift);
    try std.testing.expectEqual(@as(usize, 1), kept.drift.added.len);
    try std.testing.expectEqualStrings("src/other.zig::run | fn run() void", kept.drift.added[0]);

    // Drift confined to the measurement path leaves nothing to report.
    const only_counter: snapshot_helper.Outcome = .{ .drift = .{
        .added = &.{"src/hot.zig::dbg_hits value"},
        .removed = &.{},
    } };
    try std.testing.expect((try bridgeMeasured(&ctx, a, only_counter, 1)) == .unchanged);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "MEASURE pub-api-surface") != null);

    // A gating run sees it as drift again — the bridge is void.
    ctx.gate = true;
    try std.testing.expect((try bridgeMeasured(&ctx, a, only_counter, 1)) == .drift);
}

// spec: Pub Api Surface - Snapshots every public declaration
// spec: Pub Api Surface - Diff fails on unexpected pub additions or removals
// spec: Pub Api Surface - Diff fails when an existing pub fn signature changes
// spec: Pub Api Surface - Skips removed symbols whose file is unbuilt generated output

test "withoutPhantoms drops symbols from unbuilt files but keeps real removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const cfg: @import("../config.zig").Config = .{};
    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };

    // A worktree that never ran its codegen: the snapshot's symbols for the
    // gitignored generated file are unreadable, not removed. That alone is not
    // drift — the run reports it skipped and stays green.
    const only_phantom: snapshot_helper.Outcome = .{ .drift = .{
        .added = &.{},
        .removed = &.{"zig-out/generated/page.zig::render | fn render() void"},
    } };
    const filtered = try withoutPhantoms(&ctx, only_phantom, 7);
    try std.testing.expect(filtered == .unchanged);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "skipped") != null);

    // A tracked file's symbol going missing is a real removal and still fails.
    const real: snapshot_helper.Outcome = .{ .drift = .{
        .added = &.{},
        .removed = &.{"src/gone.zig::render | fn render() void"},
    } };
    const kept = try withoutPhantoms(&ctx, real, 7);
    try std.testing.expect(kept == .drift);
    try std.testing.expectEqual(@as(usize, 1), kept.drift.removed.len);
}

// spec: Pub Api Surface - Classifies surface drift as new, changed, and removed symbols

test "group separates additions, signature changes, and removals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A pure addition, a signature change (same key on both sides), and a removal.
    const added = [_][]const u8{
        "src/x.zig::added | fn added() void", // new
        "src/x.zig::run | fn run(a: u8) void", // changed (new proto)
    };
    const removed = [_][]const u8{
        "src/x.zig::run | fn run() void", // changed (old proto)
        "src/x.zig::gone value", // removal
    };
    const d = try group(a, &added, &removed);
    try std.testing.expectEqual(@as(usize, 1), d.new.len);
    try std.testing.expectEqual(@as(usize, 1), d.changed.len);
    try std.testing.expectEqual(@as(usize, 1), d.removed.len);
    try std.testing.expectEqual(@as(usize, 0), d.moved.len);

    // Pure additions: nothing changed or removed.
    const pure = try group(a, &[_][]const u8{"src/x.zig::a | fn a() void"}, &.{});
    try std.testing.expectEqual(@as(usize, 1), pure.new.len);
    try std.testing.expectEqual(@as(usize, 0), pure.changed.len);
    try std.testing.expectEqual(@as(usize, 0), pure.removed.len);
}

// spec: Pub Api Surface - Pairs a changed signature into one line instead of a separate addition and removal

test "reportDrift renders a changed signature as one paired line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // The rename-in-place from the feedback: one parameter added. Alphabetical
    // sorting would file the `+` and the `-` at opposite ends of the listing.
    const d: @import("../snapshot.zig").Diff = .{
        .added = &.{
            "src/router.zig::alpha | fn alpha() void",
            "src/router.zig::claimed | fn claimed(lane: u8, cls: u8) bool",
        },
        .removed = &.{"src/router.zig::claimed | fn claimed(lane: u8) bool"},
    };
    try std.testing.expectError(error.CheckFailed, reportDrift(a, d));
    const out = cap.buf.items;

    // One `~` line carries the whole edit; the addition stays a plain `+`.
    try std.testing.expect(std.mem.indexOf(u8, out, "  changed:\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "    ~ src/router.zig::claimed | fn claimed(lane: u8) bool -> fn claimed(lane: u8, cls: u8) bool\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  + src/router.zig::alpha | fn alpha() void\n") != null);
    // The paired symbol appears in neither one-sided list.
    try std.testing.expect(std.mem.indexOf(u8, out, "  - src/router.zig::claimed") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  + src/router.zig::claimed") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "delta: 1 new, 1 changed, 0 removed, 0 moved") != null);
}

// spec: Pub Api Surface - Reports a symbol whose file changed with an identical signature as moved

test "reportDrift classifies an identical signature under a new file as moved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // Two cohesive symbols lifted out of router.zig into gap_policy.zig,
    // signatures untouched: the surface neither grew nor shrank.
    const d: @import("../snapshot.zig").Diff = .{
        .added = &.{
            "src/gap_policy.zig::claimed | fn claimed(lane: u8) bool",
            "src/gap_policy.zig::width value",
        },
        .removed = &.{
            "src/router.zig::claimed | fn claimed(lane: u8) bool",
            "src/router.zig::width value",
        },
    };
    try std.testing.expectError(error.CheckFailed, reportDrift(a, d));
    const out = cap.buf.items;

    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "  moved: src/router.zig -> src/gap_policy.zig :: claimed\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "  moved: src/router.zig -> src/gap_policy.zig :: width\n",
    ) != null);
    // Moved symbols count as neither new nor removed, and the summary says so.
    try std.testing.expect(std.mem.indexOf(u8, out, "delta: 0 new, 0 changed, 0 removed, 2 moved") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "relocation only, signatures identical") != null);
    // A relocation is still drift: the check blocks until the snapshot is accepted.
    try std.testing.expect(std.mem.indexOf(u8, out, "pub-api FAILED") != null);

    // Same name, same file, different signature is a change — not a move.
    const edited = try group(
        a,
        &[_][]const u8{"src/router.zig::claimed | fn claimed(lane: u16) bool"},
        &[_][]const u8{"src/router.zig::claimed | fn claimed(lane: u8) bool"},
    );
    try std.testing.expectEqual(@as(usize, 0), edited.moved.len);
    try std.testing.expectEqual(@as(usize, 1), edited.changed.len);
}

// spec: Pub Api Surface - Offers the accept commands inline when the delta is additions only

test "reportDrift prints the accept commands beside an additions-only delta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const d: @import("../snapshot.zig").Diff = .{
        .added = &.{"src/x.zig::added | fn added() void"},
        .removed = &.{},
    };
    try std.testing.expectError(error.CheckFailed, reportDrift(a, d));
    const out = cap.buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "pure additions, safe to accept") != null);
    // Both spellings sit directly under the verdict, so accepting is one step.
    try std.testing.expect(std.mem.indexOf(u8, out, "guardian-check accept pub-api-surface .") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "GUARDIAN_UPDATE_SNAPSHOT=pub-api-surface zig build") != null);

    // A delta with a removal gets no inline accept — it has to be reviewed first.
    cap.buf.clearRetainingCapacity();
    const shrink: @import("../snapshot.zig").Diff = .{
        .added = &.{},
        .removed = &.{"src/x.zig::gone | fn gone() void"},
    };
    try std.testing.expectError(error.CheckFailed, reportDrift(a, shrink));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "    accept: guardian-check") == null);
}

test "visit emits fn and struct entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var ctx: CollectCtx = .{ .allocator = a, .lines = &lines };
    const content =
        \\pub fn run() void {}
        \\pub const X = struct { x: i32 };
        \\pub const Y = 42;
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("src/x.zig::run | fn run() void", lines.items[0]);
    try std.testing.expectEqualStrings("src/x.zig::X struct_", lines.items[1]);
    try std.testing.expectEqualStrings("src/x.zig::Y value", lines.items[2]);
}
