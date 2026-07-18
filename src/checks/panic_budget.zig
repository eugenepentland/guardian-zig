//! panic-budget check: track counts of `@panic`, `unreachable`, the two
//! deferred-work comment markers, and `@setEvalBranchQuota` (call count + max
//! literal) against a committed snapshot, so each only grows deliberately.
//! Undercounting on OOM would fail open, so the tallying allocations propagate.
//! Folded-in comptime-quota.

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

const snapshot_leaf = "panic-budget.txt";
// v2: added comptime_calls / comptime_max (folded in comptime-quota).
const snapshot_version: u32 = 2;

const Counts = struct {
    panics: u32 = 0,
    unreachables: u32 = 0,
    todos: u32 = 0,
    fixmes: u32 = 0,
    // Folded-in comptime-quota metrics: @setEvalBranchQuota call count and the
    // largest quota value requested anywhere in the tree.
    comptime_calls: u32 = 0,
    comptime_max: u64 = 0,

    fn add(self: *Counts, other: Counts) void {
        self.panics += other.panics;
        self.unreachables += other.unreachables;
        self.todos += other.todos;
        self.fixmes += other.fixmes;
        self.comptime_calls += other.comptime_calls;
        if (other.comptime_max > self.comptime_max) self.comptime_max = other.comptime_max;
    }
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    totals: *Counts,
};

fn countTokens(z: [:0]const u8) std.mem.Allocator.Error!Counts {
    var c: Counts = .{};
    var tok = std.zig.Tokenizer.init(z);
    // Chain state for `std . debug . panic`: 0=none, 1=std, 2=std., 3=std.debug,
    // 4=std.debug. — so std.debug.panic doesn't escape the budget by not being
    // the @panic builtin.
    var chain: u8 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        chain = advancePanicChain(chain, t.tag, z[t.loc.start..t.loc.end], &c);
        switch (t.tag) {
            .keyword_unreachable => c.unreachables += 1,
            .builtin => {
                if (std.mem.eql(u8, z[t.loc.start..t.loc.end], "@panic")) c.panics += 1;
            },
            else => {},
        }
    }
    return c;
}

/// Advances the `std.debug.panic` recognizer and increments the panic count on
/// a full match. Returns the next chain state.
fn advancePanicChain(chain: u8, tag: std.zig.Token.Tag, text: []const u8, c: *Counts) u8 {
    const is = struct {
        fn ident(tg: std.zig.Token.Tag, txt: []const u8, want: []const u8) bool {
            return tg == .identifier and std.mem.eql(u8, txt, want);
        }
    };
    return switch (chain) {
        1 => if (tag == .period) 2 else start(tag, text),
        2 => if (is.ident(tag, text, "debug")) 3 else start(tag, text),
        3 => if (tag == .period) 4 else start(tag, text),
        4 => blk: {
            if (is.ident(tag, text, "panic")) c.panics += 1;
            break :blk start(tag, text);
        },
        else => start(tag, text),
    };
}

fn start(tag: std.zig.Token.Tag, text: []const u8) u8 {
    return if (tag == .identifier and std.mem.eql(u8, text, "std")) 1 else 0;
}

fn countCommentMarkers(content: []const u8) struct { todos: u32, fixmes: u32 } {
    var todos: u32 = 0;
    var fixmes: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const slash = std.mem.indexOf(u8, line, "//") orelse continue;
        const tail = line[slash..];
        if (containsWord(tail, "TODO")) todos += 1;
        if (containsWord(tail, "FIXME")) fixmes += 1;
    }
    return .{ .todos = todos, .fixmes = fixmes };
}

fn containsWord(text: []const u8, word: []const u8) bool {
    if (word.len == 0 or word.len > text.len) return false;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, word)) |idx| {
        const left_ok = idx == 0 or !std.ascii.isAlphanumeric(text[idx - 1]);
        const end = idx + word.len;
        const right_ok = end == text.len or !std.ascii.isAlphanumeric(text[end]);
        if (left_ok and right_ok) return true;
        search_start = idx + 1;
    }
    return false;
}

const QuotaCounts = struct { calls: u32 = 0, max_value: u64 = 0 };

/// Scans for `@setEvalBranchQuota(N)` calls: counts them and tracks the largest
/// literal N. Non-literal args (a const reference) bump the count but not the
/// max. Tokenizer skips strings/comments. (Folded in from comptime-quota.)
fn countQuotas(allocator: std.mem.Allocator, z: [:0]const u8) std.mem.Allocator.Error!QuotaCounts {
    var q: QuotaCounts = .{};
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .builtin) continue;
        if (!std.mem.eql(u8, z[t.loc.start..t.loc.end], "@setEvalBranchQuota")) continue;
        if (tok.next().tag != .l_paren) continue;
        const arg = tok.next();
        q.calls += 1;
        if (arg.tag == .number_literal) {
            // OOM propagates; only a malformed literal (parseUint) is skipped.
            const cleaned = try stripUnderscores(allocator, z[arg.loc.start..arg.loc.end]);
            const v = parseUint(cleaned) catch continue;
            if (v > q.max_value) q.max_value = v;
        }
    }
    return q;
}

fn stripUnderscores(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| if (ch != '_') try out.append(allocator, ch);
    return out.toOwnedSlice(allocator);
}

const Radix = struct { prefix: []const u8, base: u8 };
const radix_prefixes = [_]Radix{
    .{ .prefix = "0x", .base = 16 },
    .{ .prefix = "0b", .base = 2 },
    .{ .prefix = "0o", .base = 8 },
};

fn parseUint(s: []const u8) !u64 {
    var digits = s;
    var base: u8 = 10;
    for (radix_prefixes) |r| {
        if (s.len >= r.prefix.len and std.ascii.eqlIgnoreCase(s[0..r.prefix.len], r.prefix)) {
            digits = s[2..];
            base = r.base;
        }
    }
    return std.fmt.parseInt(u64, digits, base);
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    var c = try countTokens(entry.content);
    const cm = countCommentMarkers(entry.content);
    c.todos = cm.todos;
    c.fixmes = cm.fixmes;
    const q = try countQuotas(ctx.allocator, entry.content);
    c.comptime_calls = q.calls;
    c.comptime_max = q.max_value;
    ctx.totals.add(c);
}

fn countsToLines(allocator: std.mem.Allocator, c: Counts) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "panics {d}", .{c.panics}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "unreachables {d}", .{c.unreachables}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "todos {d}", .{c.todos}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "fixmes {d}", .{c.fixmes}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "comptime_calls {d}", .{c.comptime_calls}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "comptime_max {d}", .{c.comptime_max}));
    return lines.toOwnedSlice(allocator);
}

fn linesToCounts(lines: []const []const u8) Counts {
    var c: Counts = .{};
    for (lines) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        const raw = line[sp + 1 ..];
        if (std.mem.eql(u8, key, "comptime_max")) {
            c.comptime_max = std.fmt.parseInt(u64, raw, 10) catch 0;
            continue;
        }
        const val = std.fmt.parseInt(u32, raw, 10) catch continue;
        if (std.mem.eql(u8, key, "panics")) c.panics = val;
        if (std.mem.eql(u8, key, "unreachables")) c.unreachables = val;
        if (std.mem.eql(u8, key, "todos")) c.todos = val;
        if (std.mem.eql(u8, key, "fixmes")) c.fixmes = val;
        if (std.mem.eql(u8, key, "comptime_calls")) c.comptime_calls = val;
    }
    return c;
}

const Metric = struct {
    name: []const u8,
    found: u64,
    budget: u64,
};

const metric_count = 6;

fn metrics(totals: Counts, budget: Counts) [metric_count]Metric {
    return .{
        .{ .name = "panics", .found = totals.panics, .budget = budget.panics },
        .{ .name = "unreachables", .found = totals.unreachables, .budget = budget.unreachables },
        .{ .name = "todos", .found = totals.todos, .budget = budget.todos },
        .{ .name = "fixmes", .found = totals.fixmes, .budget = budget.fixmes },
        .{ .name = "comptime_calls", .found = totals.comptime_calls, .budget = budget.comptime_calls },
        .{ .name = "comptime_max", .found = totals.comptime_max, .budget = budget.comptime_max },
    };
}

fn collectFailures(
    allocator: std.mem.Allocator,
    totals: Counts,
    budget: Counts,
) ![]const []const u8 {
    var failures: std.ArrayList([]const u8) = .empty;
    for (metrics(totals, budget)) |m| {
        if (m.found <= m.budget) continue;
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}: {d} found, {d} budgeted",
            .{ m.name, m.found, m.budget },
        );
        try failures.append(allocator, line);
    }
    return failures.toOwnedSlice(allocator);
}

fn reportFailures(failures: []const []const u8) registry.RunError!void {
    fail("panic budget FAILED", .{});
    for (failures) |line| print("  {s}\n", .{line});
    print(
        "  fix: reduce, OR re-run with {s}=panic-budget and commit .guardian/{s}\n",
        .{ snapshot_helper.update_env, snapshot_leaf },
    );
}

fn scanTotals(ctx_param: *registry.RunCtx) registry.RunError!Counts {
    const allocator = ctx_param.allocator;
    var totals: Counts = .{};
    var scan_ctx: ScanCtx = .{ .allocator = allocator, .totals = &totals };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{
        .ctx = &scan_ctx,
        .visit = visit,
    });
    return totals;
}

fn okCounts(comptime msg: []const u8, totals: Counts) void {
    ok(msg, .{ totals.panics, totals.unreachables, totals.todos, totals.fixmes });
}

/// Loads the budget snapshot. Returns the parsed budget, or null when the
/// snapshot was just (re)written — meaning the caller should report success and
/// stop.
fn loadBudget(
    ctx: *registry.RunCtx,
    snap_path: []const u8,
    totals: Counts,
    new_lines: [][]const u8,
) registry.RunError!?Counts {
    const allocator = ctx.allocator;
    if (snapshot_helper.shouldUpdateForCtx(ctx, "panic-budget")) {
        try snapshot.write(snap_path, snapshot_version, new_lines);
        okCounts("panic budget updated (panics={d}, unreachables={d}, todos={d}, fixmes={d})", totals);
        return null;
    }
    const old = snapshot.read(allocator, snap_path, snapshot_version) catch |e| {
        return handleReadError(e, snap_path, totals, new_lines);
    };
    return linesToCounts(old.lines);
}

fn handleReadError(
    e: snapshot.ReadError,
    snap_path: []const u8,
    totals: Counts,
    new_lines: [][]const u8,
) registry.RunError!?Counts {
    switch (e) {
        error.Missing => {
            try snapshot.write(snap_path, snapshot_version, new_lines);
            okCounts("panic budget created (panics={d}, unreachables={d}, todos={d}, fixmes={d})", totals);
            return null;
        },
        error.VersionMismatch => {
            fail(
                "panic budget version mismatch — re-run with {s}=panic-budget to migrate",
                .{snapshot_helper.update_env},
            );
            return error.CheckFailed;
        },
        else => return e,
    }
}

fn okWithinLimits(totals: Counts, budget: Counts) void {
    ok("panic budget within limits (panics={d}/{d}, unreachables={d}/{d}, todos={d}/{d}, fixmes={d}/{d})", .{
        totals.panics,       budget.panics,
        totals.unreachables, budget.unreachables,
        totals.todos,        budget.todos,
        totals.fixmes,       budget.fixmes,
    });
}

/// Entry point for the panic-budget check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const totals = try scanTotals(ctx_param);

    const snap_path = try snapshot_helper.snapshotPath(allocator, ctx_param.project_dir, snapshot_leaf);
    const new_lines = try countsToLines(allocator, totals);

    const budget = try loadBudget(ctx_param, snap_path, totals, new_lines) orelse return;

    const failures = try collectFailures(allocator, totals, budget);
    if (failures.len == 0) {
        okWithinLimits(totals, budget);
        return;
    }
    try reportFailures(failures);
    return error.CheckFailed;
}

// spec: Panic Budget - Tracks panic and unreachable token counts against a snapshot
// spec: Panic Budget - Tracks TODO and FIXME comment counts against a snapshot
// spec: Panic Budget - Tracks @setEvalBranchQuota call count and max value against a snapshot

test "countQuotas counts @setEvalBranchQuota calls and tracks the max literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = try countQuotas(arena.allocator(),
        \\fn x() void { @setEvalBranchQuota(1000); }
        \\fn y() void { @setEvalBranchQuota(50_000); }
        \\const s = "@setEvalBranchQuota(99999)";
    );
    // Two real calls (the string literal is skipped); max tracks 50_000.
    try std.testing.expectEqual(@as(u32, 2), q.calls);
    try std.testing.expectEqual(@as(u64, 50000), q.max_value);
}

test "countTokens counts panics and unreachables" {
    const content =
        \\fn x() void { @panic("a"); }
        \\fn y() void { unreachable; }
        \\fn z() void { unreachable; }
        \\const s = "@panic(\"in-string\")";
    ;
    const c = try countTokens(content);
    try std.testing.expectEqual(@as(u32, 1), c.panics);
    try std.testing.expectEqual(@as(u32, 2), c.unreachables);
}
test "countTokens counts std.debug.panic toward the panic budget" {
    const c = try countTokens(
        \\fn a() void { @panic("x"); }
        \\fn b() void { std.debug.panic("y {d}", .{1}); }
    );
    // Both the @panic builtin and std.debug.panic count.
    try std.testing.expectEqual(@as(u32, 2), c.panics);
}

test "countCommentMarkers finds TODO/FIXME in comments" {
    const content =
        \\// TODO: real
        \\const x = 1; // FIXME: inline
        \\const s = "// TODO not in comment";
    ;
    const r = countCommentMarkers(content);
    try std.testing.expect(r.todos >= 1);
    try std.testing.expect(r.fixmes >= 1);
}

test "linesToCounts round-trips countsToLines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original: Counts = .{
        .panics = 5,
        .unreachables = 3,
        .todos = 7,
        .fixmes = 1,
        .comptime_calls = 2,
        .comptime_max = 40000,
    };
    const lines = try countsToLines(a, original);
    const parsed = linesToCounts(lines);
    try std.testing.expectEqual(original.panics, parsed.panics);
    try std.testing.expectEqual(original.unreachables, parsed.unreachables);
    try std.testing.expectEqual(original.todos, parsed.todos);
    try std.testing.expectEqual(original.fixmes, parsed.fixmes);
    try std.testing.expectEqual(original.comptime_calls, parsed.comptime_calls);
    try std.testing.expectEqual(original.comptime_max, parsed.comptime_max);
}
