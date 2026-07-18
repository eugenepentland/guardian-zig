//! int-from-float-budget: snapshot-ratcheted count of `@intFromFloat` sites.
//! An unguarded float→int cast is a NaN/∞ time bomb — checked UB in safe
//! builds, silent memory unsafety in ReleaseFast/Small. The committed snapshot
//! only shrinks; growth fails the build. Two config refinements:
//! `[int_from_float] guard_fns` names sanctioned wrapper fns (e.g. a
//! `checkedInt` that validates finiteness/range in float space) whose bodies
//! are exempt — the wrapper IS the guard; `require_guard` path globs hard-fail
//! any cast outside a guard fn under those paths, independent of the budget.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const Allocator = std.mem.Allocator;
const lineOf = @import("../text.zig").lineOf;
const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const snapshot_leaf = "int-from-float-budget.txt";
const snapshot_version: u32 = 1;

const ScanCtx = struct {
    allocator: Allocator,
    total: *u32,
    guard_fns: []const []const u8,
    require_guard: []const []const u8,
    violations: *std.ArrayList([]const u8),
};

/// Brace/fn-aware scan state that recognizes a sanctioned guard-fn body. A
/// configured guard fn (e.g. eda's `numeric.checkedInt`, which validates
/// isFinite+range in float space before converting) IS the guard, so an
/// `@intFromFloat` in its body is exempt; casts anywhere else count. `paren_depth`
/// gates body detection so a `.{}` default in the param list can't be mistaken
/// for the opening body brace.
const GuardScan = struct {
    guard_fns: []const []const u8,
    depth: u32 = 0,
    paren_depth: u32 = 0,
    expect_name: bool = false,
    pending_guard: bool = false,
    in_guard: bool = false,
    guard_depth: u32 = 0,

    fn step(self: *GuardScan, z: [:0]const u8, t: std.zig.Token) void {
        switch (t.tag) {
            .keyword_fn => self.expect_name = true,
            .identifier => self.onIdent(z, t),
            .l_paren => self.paren_depth += 1,
            .r_paren => {
                if (self.paren_depth > 0) self.paren_depth -= 1;
            },
            .l_brace => self.onLBrace(),
            .r_brace => self.onRBrace(),
            else => {},
        }
        // The name latch survives only from `fn` to the next identifier; any
        // other token clears it (an anonymous `fn (…)` type has no name).
        if (t.tag != .keyword_fn and t.tag != .identifier) self.expect_name = false;
    }

    fn onIdent(self: *GuardScan, z: [:0]const u8, t: std.zig.Token) void {
        if (!self.expect_name) return;
        self.expect_name = false;
        if (inList(self.guard_fns, z[t.loc.start..t.loc.end])) self.pending_guard = true;
    }

    fn onLBrace(self: *GuardScan) void {
        self.depth += 1;
        // A guard fn's body opens at paren_depth 0 (not inside its param list).
        if (self.pending_guard and self.paren_depth == 0) {
            self.in_guard = true;
            self.guard_depth = self.depth;
            self.pending_guard = false;
        }
    }

    fn onRBrace(self: *GuardScan) void {
        if (self.in_guard and self.depth == self.guard_depth) self.in_guard = false;
        if (self.depth > 0) self.depth -= 1;
    }
};

/// True when `list` contains `name`.
fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// True when `path` matches any glob in `globs` (walk.matchGlob semantics).
fn matchesAny(path: []const u8, globs: []const []const u8) bool {
    for (globs) |g| if (walk.matchGlob(path, g)) return true;
    return false;
}

/// 1-indexed source lines of every `@intFromFloat` NOT inside a guard-fn body.
/// Float→int truncates toward zero and is UB on NaN / out-of-range in ReleaseFast
/// / ReleaseSmall, so each unguarded site needs a deliberate isFinite+range guard.
/// Token-based ⇒ strings/comments are skipped. Propagates OOM: undercounting on a
/// failed allocation would let the budget pass open.
fn unguardedCastLines(allocator: Allocator, content: []const u8, guard_fns: []const []const u8) Allocator.Error![]u32 {
    var lines: std.ArrayList(u32) = .empty;
    const z = try allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var st: GuardScan = .{ .guard_fns = guard_fns };
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        st.step(z, t);
        if (t.tag == .builtin and std.mem.eql(u8, z[t.loc.start..t.loc.end], "@intFromFloat")) {
            if (!st.in_guard) try lines.append(allocator, lineOf(z, t.loc.start));
        }
    }
    return lines.toOwnedSlice(allocator);
}

/// Non-guard `@intFromFloat` count for `content` — the budget metric.
fn countCasts(allocator: Allocator, content: []const u8, guard_fns: []const []const u8) Allocator.Error!u32 {
    const lines = try unguardedCastLines(allocator, content, guard_fns);
    return @intCast(lines.len);
}

/// One violation line per unguarded cast site in a require_guard file.
fn requireGuardViolations(
    allocator: Allocator,
    rel_path: []const u8,
    lines: []const u32,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |ln| {
        try out.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}:{d}: unguarded @intFromFloat under require_guard — wrap it in a guard fn",
            .{ rel_path, ln },
        ));
    }
    return out.toOwnedSlice(allocator);
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const lines = try unguardedCastLines(ctx.allocator, entry.content, ctx.guard_fns);
    ctx.total.* += @intCast(lines.len);
    if (ctx.require_guard.len == 0 or !matchesAny(entry.rel_path, ctx.require_guard)) return;
    const viols = try requireGuardViolations(ctx.allocator, entry.rel_path, lines);
    try ctx.violations.appendSlice(ctx.allocator, viols);
}

fn countToLines(allocator: std.mem.Allocator, n: u32) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
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
    const cfg = ctx_param.cfg.int_from_float;

    var total: u32 = 0;
    var violations: std.ArrayList([]const u8) = .empty;
    var scan_ctx: ScanCtx = .{
        .allocator = allocator,
        .total = &total,
        .guard_fns = cfg.guard_fns,
        .require_guard = cfg.require_guard,
        .violations = &violations,
    };
    const opts: walk.Visitor = .{ .ctx = &scan_ctx, .visit = visit };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, opts);

    // Strict mode: any unguarded cast under a require_guard path hard-fails,
    // independent of the snapshot budget — a stricter, path-scoped gate.
    if (violations.items.len > 0) return reportRequireGuard(violations.items);

    const snap_path = try snapshot_helper.snapshotPath(allocator, project_dir, snapshot_leaf);
    const new_lines = try countToLines(allocator, total);

    if (snapshot_helper.shouldUpdateForCtx(ctx_param, "int-from-float-budget")) {
        try snapshot.write(snap_path, snapshot_version, new_lines);
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
    const old = snapshot.read(allocator, snap_path, snapshot_version) catch |e| {
        if (e == error.Missing) {
            try snapshot.write(snap_path, snapshot_version, new_lines);
            ok("int-from-float budget created (casts={d})", .{total});
            return null;
        }
        if (e == error.VersionMismatch) {
            fail("int-from-float budget: stale snapshot, re-run {s}=1", .{snapshot_helper.update_env});
            return error.CheckFailed;
        }
        return e;
    };
    return linesToCount(old.lines);
}

fn reportRequireGuard(violations: []const []const u8) registry.RunError!void {
    fail("int-from-float require_guard FAILED ({d} unguarded cast(s))", .{violations.len});
    for (violations) |v| print("  {s}\n", .{v});
    print("  fix: wrap each site in a configured guard fn (isFinite + range check,\n", .{});
    print("       see numeric.checkedInt), or drop the path from [int_from_float] require_guard.\n", .{});
    return error.CheckFailed;
}

fn compareAndReport(total: u32, budget: u32) registry.RunError!void {
    if (total <= budget) {
        ok("int-from-float budget within limits (casts={d}/{d})", .{ total, budget });
        return;
    }
    fail("int-from-float budget FAILED (casts: {d} found, {d} budgeted)", .{ total, budget });
    print("  fix: guard the new @intFromFloat (isFinite + range check, see numeric.checkedInt),\n", .{});
    print("       or re-run with {s}=1 and commit .guardian/{s}\n", .{ snapshot_helper.update_env, snapshot_leaf });
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
    // No guard fns configured → every site counts, as before.
    try std.testing.expectEqual(@as(u32, 2), try countCasts(a, content, &.{}));
}

test "linesToCount round-trips countToLines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try countToLines(a, 7);
    try std.testing.expectEqual(@as(u32, 7), linesToCount(lines));
}

// spec: Int From Float Budget - Exempts an @intFromFloat inside a configured guard function body

test "countCasts exempts a cast inside a guard fn body and counts the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn checkedInt(x: f64) i64 { return @intFromFloat(x); }
        \\fn raw(y: f64) i64 { return @intFromFloat(y); }
    ;
    // The checkedInt-body cast is the sanctioned guard → excluded; raw's counts.
    try std.testing.expectEqual(@as(u32, 1), try countCasts(a, content, &.{"checkedInt"}));
    const lines = try unguardedCastLines(a, content, &.{"checkedInt"});
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(u32, 2), lines[0]);
    // With no guard fns, both sites count.
    try std.testing.expectEqual(@as(u32, 2), try countCasts(a, content, &.{}));
}

// spec: Int From Float Budget - Flags each unguarded cast under a require_guard path

test "requireGuardViolations reports each unguarded cast line and skips guarded ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn checkedInt(x: f64) i64 { return @intFromFloat(x); }
        \\fn draw(y: f64) i64 { return @intFromFloat(y); }
    ;
    const lines = try unguardedCastLines(a, content, &.{"checkedInt"});
    const viols = try requireGuardViolations(a, "src/render/grid.zig", lines);
    try std.testing.expectEqual(@as(usize, 1), viols.len);
    try std.testing.expect(std.mem.indexOf(u8, viols[0], "src/render/grid.zig:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, viols[0], "unguarded @intFromFloat") != null);
}
