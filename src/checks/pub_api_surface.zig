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

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const measurement = @import("../measurement.zig");

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
    return reportOutcome(try bridgeMeasured(ctx_param, allocator, outcome, lines.len));
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

fn reportOutcome(outcome: snapshot_helper.Outcome) registry.RunError!void {
    switch (outcome) {
        .created => |n| ok("pub-api snapshot created ({d} entries)", .{n}),
        .updated => |n| ok("pub-api snapshot updated ({d} entries)", .{n}),
        .unchanged => |n| ok("pub-api unchanged ({d} entries)", .{n}),
        .version_mismatch => {
            fail("pub-api snapshot version mismatch", .{});
            print("  fix: re-record the snapshot at the new format version:\n", .{});
            snapshot_helper.printAcceptPaths(check_name);
            return error.CheckFailed;
        },
        .drift => |d| return reportDrift(d),
    }
}

/// One symbol's classification within a surface diff (C3): the stable identity
/// is `<file>::<name>` — the line prefix up to the first space, before a fn's
/// ` | <proto>` or a const's ` <kind>`. A key on both sides is a signature
/// *change*; added-only is *new*; removed-only is a *removal*.
const Delta = struct { added: usize, changed: usize, removed: usize };

fn keyOf(line: []const u8) []const u8 {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return line;
    return line[0..sp];
}

fn keyInLines(lines: []const []const u8, key: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, keyOf(l), key)) return true;
    return false;
}

fn classifyDelta(added: []const []const u8, removed: []const []const u8) Delta {
    var new_syms: usize = 0;
    var changed: usize = 0;
    for (added) |a| {
        if (keyInLines(removed, keyOf(a))) changed += 1 else new_syms += 1;
    }
    var gone: usize = 0;
    for (removed) |r| {
        if (!keyInLines(added, keyOf(r))) gone += 1;
    }
    return .{ .added = new_syms, .changed = changed, .removed = gone };
}

fn reportDrift(d: @import("../snapshot.zig").Diff) registry.RunError!void {
    fail("pub-api FAILED — surface changed", .{});
    const delta = classifyDelta(d.added, d.removed);
    // A one-line delta classification so accept-vs-investigate is decidable
    // without diffing snapshots by hand (C3).
    if (delta.changed == 0 and delta.removed == 0) {
        print("  delta: {d} new symbol(s), 0 changed, 0 removed — pure additions, safe to accept\n", .{delta.added});
    } else {
        print(
            "  delta: {d} new, {d} changed, {d} removed — review changed/removed below before accepting\n",
            .{ delta.added, delta.changed, delta.removed },
        );
    }
    for (d.removed) |line| print("  - {s}\n", .{line});
    for (d.added) |line| print("  + {s}\n", .{line});
    print("  fix: if the change is intentional, accept the snapshot:\n", .{});
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
// spec: Pub Api Surface - Classifies surface drift as new, changed, and removed symbols

test "classifyDelta separates additions, signature changes, and removals" {
    // A pure addition, a signature change (same key on both sides), and a removal.
    const added = [_][]const u8{
        "src/x.zig::added | fn added() void", // new
        "src/x.zig::run | fn run(a: u8) void", // changed (new proto)
    };
    const removed = [_][]const u8{
        "src/x.zig::run | fn run() void", // changed (old proto)
        "src/x.zig::gone value", // removal
    };
    const d = classifyDelta(&added, &removed);
    try std.testing.expectEqual(@as(usize, 1), d.added);
    try std.testing.expectEqual(@as(usize, 1), d.changed);
    try std.testing.expectEqual(@as(usize, 1), d.removed);

    // Pure additions: nothing changed or removed.
    const pure = classifyDelta(&[_][]const u8{"src/x.zig::a | fn a() void"}, &.{});
    try std.testing.expectEqual(@as(usize, 1), pure.added);
    try std.testing.expectEqual(@as(usize, 0), pure.changed);
    try std.testing.expectEqual(@as(usize, 0), pure.removed);
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
