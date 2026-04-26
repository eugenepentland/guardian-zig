const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Comptime Quota - Tracks @setEvalBranchQuota call count and max value against a snapshot

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

fn parseUint(s: []const u8) !u64 {
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        return std.fmt.parseInt(u64, s[2..], 16);
    }
    if (std.mem.startsWith(u8, s, "0b") or std.mem.startsWith(u8, s, "0B")) {
        return std.fmt.parseInt(u64, s[2..], 2);
    }
    if (std.mem.startsWith(u8, s, "0o") or std.mem.startsWith(u8, s, "0O")) {
        return std.fmt.parseInt(u64, s[2..], 8);
    }
    return std.fmt.parseInt(u64, s, 10);
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
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &scan_ctx, .visit = visit });

    const snap_path = try snapshot_helper.snapshotPath(allocator, project_dir, SNAPSHOT_LEAF);
    const new_lines = try countsToLines(allocator, totals);

    if (snapshot_helper.shouldUpdate(allocator)) {
        try snapshot.write(snap_path, SNAPSHOT_VERSION, new_lines);
        ok("comptime quota updated (calls={d}, max_value={d})", .{ totals.calls, totals.max_value });
        return;
    }

    const old = snapshot.read(allocator, snap_path, SNAPSHOT_VERSION) catch |e| switch (e) {
        error.Missing => {
            try snapshot.write(snap_path, SNAPSHOT_VERSION, new_lines);
            ok("comptime quota created (calls={d}, max_value={d})", .{ totals.calls, totals.max_value });
            return;
        },
        error.VersionMismatch => {
            fail("comptime quota version mismatch — re-run with {s}=1 to migrate", .{snapshot_helper.UPDATE_ENV});
            return error.CheckFailed;
        },
        else => return e,
    };

    const budget = linesToCounts(old.lines);

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;
    if (totals.calls > budget.calls) {
        try failures.append(allocator, try std.fmt.allocPrint(allocator, "calls: {d} found, {d} budgeted", .{ totals.calls, budget.calls }));
    }
    if (totals.max_value > budget.max_value) {
        try failures.append(allocator, try std.fmt.allocPrint(allocator, "max_value: {d} found, {d} budgeted", .{ totals.max_value, budget.max_value }));
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
    print("  fix: reduce, OR re-run with {s}=1 and commit .guardian/{s}\n", .{ snapshot_helper.UPDATE_ENV, SNAPSHOT_LEAF });
    return error.CheckFailed;
}

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
