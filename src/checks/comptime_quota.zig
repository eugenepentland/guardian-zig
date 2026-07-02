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

const SNAPSHOT_LEAF = "comptime-quota.txt";
const SNAPSHOT_VERSION: u32 = 1;

const Counts = struct {
    calls: u32 = 0,
    max_value: u64 = 0,

    fn add(self: *Counts, other: Counts) void {
        self.calls += other.calls;
        if (other.max_value > self.max_value) self.max_value = other.max_value;
    }
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    totals: *Counts,
};

/// Scans `content` for `@setEvalBranchQuota(N)` calls. Tokenizer skips
/// strings/comments correctly. Pulls out the integer literal arg when
/// it's a plain decimal/hex literal; non-literal args (e.g. a const
/// reference) bump the call count but contribute 0 to max_value.
fn countQuotas(allocator: std.mem.Allocator, content: []const u8) Counts {
    var c: Counts = .{};
    const z = allocator.dupeZ(u8, content) catch return c;
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .builtin) continue;
        const text = z[t.loc.start..t.loc.end];
        if (!std.mem.eql(u8, text, "@setEvalBranchQuota")) continue;

        const lparen = tok.next();
        if (lparen.tag != .l_paren) continue;
        const arg = tok.next();
        c.calls += 1;
        if (arg.tag == .number_literal) {
            const arg_text = z[arg.loc.start..arg.loc.end];
            const cleaned = stripUnderscores(allocator, arg_text) catch continue;
            const v = parseUint(cleaned) catch continue;
            if (v > c.max_value) c.max_value = v;
        }
    }
    return c;
}

fn stripUnderscores(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |ch| if (ch != '_') try out.append(allocator, ch);
    return out.toOwnedSlice(allocator);
}

const Radix = struct {
    prefix: []const u8,
    base: u8,
};

const radix_prefixes = [_]Radix{
    .{ .prefix = "0x", .base = 16 },
    .{ .prefix = "0b", .base = 2 },
    .{ .prefix = "0o", .base = 8 },
};

fn parseUint(s: []const u8) !u64 {
    var digits = s;
    var base: u8 = 10;
    for (radix_prefixes) |r| {
        if (startsWithPrefixCaseInsensitive(s, r.prefix)) {
            digits = s[2..];
            base = r.base;
        }
    }
    return std.fmt.parseInt(u64, digits, base);
}

fn startsWithPrefixCaseInsensitive(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, s[0..prefix.len]) |p, c| {
        if (std.ascii.toLower(c) != std.ascii.toLower(p)) return false;
    }
    return true;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const c = countQuotas(ctx.allocator, entry.content);
    ctx.totals.add(c);
}

fn countsToLines(allocator: std.mem.Allocator, c: Counts) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "calls {d}", .{c.calls}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "max_value {d}", .{c.max_value}));
    return lines.toOwnedSlice(allocator);
}

fn linesToCounts(lines: []const []const u8) Counts {
    var c: Counts = .{};
    for (lines) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        if (std.mem.eql(u8, key, "calls")) {
            c.calls = std.fmt.parseInt(u32, line[sp + 1 ..], 10) catch 0;
        } else if (std.mem.eql(u8, key, "max_value")) {
            c.max_value = std.fmt.parseInt(u64, line[sp + 1 ..], 10) catch 0;
        }
    }
    return c;
}

/// Entry point for the comptime-quota check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var totals: Counts = .{};
    var scan_ctx: ScanCtx = .{ .allocator = allocator, .totals = &totals };
    const opts: walk.Visitor = .{ .ctx = &scan_ctx, .visit = visit };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, opts);

    const snap_path = try snapshot_helper.snapshotPath(allocator, project_dir, SNAPSHOT_LEAF);
    const new_lines = try countsToLines(allocator, totals);

    if (snapshot_helper.shouldUpdate(allocator)) {
        try snapshot.write(snap_path, SNAPSHOT_VERSION, new_lines);
        ok("comptime quota updated (calls={d}, max_value={d})", .{ totals.calls, totals.max_value });
        return;
    }

    const budget = try readBudget(allocator, snap_path, new_lines, totals) orelse return;
    return compareAndReport(allocator, totals, budget);
}

/// Loads the budget snapshot. Returns `null` when the snapshot was just
/// created (a success path that needs no further comparison).
fn readBudget(
    allocator: std.mem.Allocator,
    snap_path: []const u8,
    new_lines: [][]const u8,
    totals: Counts,
) registry.RunError!?Counts {
    const old = snapshot.read(allocator, snap_path, SNAPSHOT_VERSION) catch |e| {
        if (e == error.Missing) {
            try snapshot.write(snap_path, SNAPSHOT_VERSION, new_lines);
            ok("comptime quota created (calls={d}, max_value={d})", .{ totals.calls, totals.max_value });
            return null;
        }
        if (e == error.VersionMismatch) {
            fail("comptime quota version mismatch — re-run with {s}=1 to migrate", .{snapshot_helper.UPDATE_ENV});
        }
        return remapReadError(e);
    };
    return linesToCounts(old.lines);
}

fn remapReadError(e: anyerror) anyerror {
    if (e == error.VersionMismatch) return error.CheckFailed;
    return e;
}

fn compareAndReport(allocator: std.mem.Allocator, totals: Counts, budget: Counts) registry.RunError!void {
    var failures: std.ArrayListUnmanaged([]const u8) = .empty;
    if (totals.calls > budget.calls) {
        const args = .{ totals.calls, budget.calls };
        const msg = try std.fmt.allocPrint(allocator, "calls: {d} found, {d} budgeted", args);
        try failures.append(allocator, msg);
    }
    if (totals.max_value > budget.max_value) {
        const args = .{ totals.max_value, budget.max_value };
        const msg = try std.fmt.allocPrint(allocator, "max_value: {d} found, {d} budgeted", args);
        try failures.append(allocator, msg);
    }

    if (failures.items.len == 0) {
        ok("comptime quota within limits (calls={d}/{d}, max_value={d}/{d})", .{
            totals.calls,     budget.calls,
            totals.max_value, budget.max_value,
        });
        return;
    }

    fail("comptime quota FAILED", .{});
    for (failures.items) |line| print("  {s}\n", .{line});
    const env = snapshot_helper.UPDATE_ENV;
    print("  fix: reduce, OR re-run with {s}=1 and commit .guardian/{s}\n", .{ env, SNAPSHOT_LEAF });
    return error.CheckFailed;
}

// spec: Comptime Quota - Tracks @setEvalBranchQuota call count and max value against a snapshot

test "countQuotas counts calls and tracks max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn x() void { @setEvalBranchQuota(1000); }
        \\fn y() void { @setEvalBranchQuota(50_000); }
        \\fn z() void { @setEvalBranchQuota(0x1000); }
    ;
    const c = countQuotas(a, content);
    try std.testing.expectEqual(@as(u32, 3), c.calls);
    try std.testing.expectEqual(@as(u64, 50000), c.max_value);
}

test "countQuotas ignores @setEvalBranchQuota in strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const s = "@setEvalBranchQuota(99999)";
        \\fn x() void { @setEvalBranchQuota(100); }
    ;
    const c = countQuotas(a, content);
    try std.testing.expectEqual(@as(u32, 1), c.calls);
    try std.testing.expectEqual(@as(u64, 100), c.max_value);
}

test "countQuotas counts non-literal args without contributing to max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const N = 999;
        \\fn x() void { @setEvalBranchQuota(N); }
    ;
    const c = countQuotas(a, content);
    try std.testing.expectEqual(@as(u32, 1), c.calls);
    try std.testing.expectEqual(@as(u64, 0), c.max_value);
}

test "linesToCounts round-trips countsToLines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Counts = .{ .calls = 5, .max_value = 12345 };
    const lines = try countsToLines(a, original);
    const parsed = linesToCounts(lines);
    try std.testing.expectEqual(original.calls, parsed.calls);
    try std.testing.expectEqual(original.max_value, parsed.max_value);
}
