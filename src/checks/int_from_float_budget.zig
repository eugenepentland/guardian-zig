const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const SNAPSHOT_LEAF = "int-from-float-budget.txt";
const SNAPSHOT_VERSION: u32 = 1;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    total: *u32,
};

/// Counts `@intFromFloat` builtin calls. Float→int conversion truncates toward
/// zero and is undefined behavior on NaN / out-of-range input in ReleaseFast
/// and ReleaseSmall (the shipped server modes), so every site needs a
/// deliberate isFinite + range guard. Token-based ⇒ zero false positives; the
/// tokenizer skips strings and comments. New sites drift the snapshot, forcing
/// a review — it does not judge existing ones.
fn countCasts(allocator: std.mem.Allocator, content: []const u8) u32 {
    var n: u32 = 0;
    const z = allocator.dupeZ(u8, content) catch return 0;
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .builtin) continue;
        if (std.mem.eql(u8, z[t.loc.start..t.loc.end], "@intFromFloat")) n += 1;
    }
    return n;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    ctx.total.* += countCasts(ctx.allocator, entry.content);
}

fn countToLines(allocator: std.mem.Allocator, n: u32) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "casts {d}", .{n}));
    return lines.toOwnedSlice(allocator);
}

fn linesToCount(lines: []const []const u8) u32 {
    for (lines) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[0..sp], "casts")) {
            return std.fmt.parseInt(u32, line[sp + 1 ..], 10) catch 0;
        }
    }
    return 0;
}

/// Entry point for the int-from-float-budget check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var total: u32 = 0;
    var scan_ctx: ScanCtx = .{ .allocator = allocator, .total = &total };
    const opts: walk.Visitor = .{ .ctx = &scan_ctx, .visit = visit };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, opts);

    const snap_path = try snapshot_helper.snapshotPath(allocator, project_dir, SNAPSHOT_LEAF);
    const new_lines = try countToLines(allocator, total);

    if (snapshot_helper.shouldUpdateFor(allocator, "int-from-float-budget")) {
        try snapshot.write(snap_path, SNAPSHOT_VERSION, new_lines);
        ok("int-from-float budget updated (casts={d})", .{total});
        return;
    }

    const budget = try readBudget(allocator, snap_path, new_lines, total) orelse return;
    return compareAndReport(total, budget);
}

/// Loads the budget snapshot. Returns `null` when the snapshot was just created
/// (a success path needing no comparison).
fn readBudget(
    allocator: std.mem.Allocator,
    snap_path: []const u8,
    new_lines: [][]const u8,
    total: u32,
) registry.RunError!?u32 {
    const old = snapshot.read(allocator, snap_path, SNAPSHOT_VERSION) catch |e| {
        if (e == error.Missing) {
            try snapshot.write(snap_path, SNAPSHOT_VERSION, new_lines);
            ok("int-from-float budget created (casts={d})", .{total});
            return null;
        }
        if (e == error.VersionMismatch) {
            fail("int-from-float budget: stale snapshot, re-run {s}=1", .{snapshot_helper.UPDATE_ENV});
            return error.CheckFailed;
        }
        return e;
    };
    return linesToCount(old.lines);
}

fn compareAndReport(total: u32, budget: u32) registry.RunError!void {
    if (total <= budget) {
        ok("int-from-float budget within limits (casts={d}/{d})", .{ total, budget });
        return;
    }
    fail("int-from-float budget FAILED (casts: {d} found, {d} budgeted)", .{ total, budget });
    print("  fix: guard the new @intFromFloat (isFinite + range check, see numeric.checkedInt),\n", .{});
    print("       or re-run with {s}=1 and commit .guardian/{s}\n", .{ snapshot_helper.UPDATE_ENV, SNAPSHOT_LEAF });
    return error.CheckFailed;
}

// spec: Int From Float Budget - Tracks @intFromFloat call count against a snapshot

test "countCasts counts @intFromFloat and skips strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn a(x: f64) i64 { return @intFromFloat(x); }
        \\fn b(y: f32) i32 { return @intFromFloat(y); }
        \\const s = "@intFromFloat(z)";
    ;
    try std.testing.expectEqual(@as(u32, 2), countCasts(a, content));
}

test "linesToCount round-trips countToLines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try countToLines(a, 7);
    try std.testing.expectEqual(@as(u32, 7), linesToCount(lines));
}
