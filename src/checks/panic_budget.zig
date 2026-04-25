const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Panic Budget - Tracks panic and unreachable token counts against a snapshot
// spec: Panic Budget - Tracks TODO and FIXME comment counts against a snapshot

const SNAPSHOT_LEAF = "panic-budget.txt";
const SNAPSHOT_VERSION: u32 = 1;

const Counts = struct {
    panics: u32 = 0,
    unreachables: u32 = 0,
    todos: u32 = 0,
    fixmes: u32 = 0,

    fn add(self: *Counts, other: Counts) void {
        self.panics += other.panics;
        self.unreachables += other.unreachables;
        self.todos += other.todos;
        self.fixmes += other.fixmes;
    }
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    totals: *Counts,
};

fn countTokens(allocator: std.mem.Allocator, content: []const u8) Counts {
    var c: Counts = .{};
    const z = allocator.dupeZ(u8, content) catch return c;
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_unreachable => c.unreachables += 1,
            .builtin => {
                const text = z[t.loc.start..t.loc.end];
                if (std.mem.eql(u8, text, "@panic")) c.panics += 1;
            },
            else => {},
        }
    }
    return c;
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

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    var c = countTokens(ctx.allocator, entry.content);
    const cm = countCommentMarkers(entry.content);
    c.todos = cm.todos;
    c.fixmes = cm.fixmes;
    ctx.totals.add(c);
}

fn countsToLines(allocator: std.mem.Allocator, c: Counts) ![][]const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "panics {d}", .{c.panics}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "unreachables {d}", .{c.unreachables}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "todos {d}", .{c.todos}));
    try lines.append(allocator, try std.fmt.allocPrint(allocator, "fixmes {d}", .{c.fixmes}));
    return lines.toOwnedSlice(allocator);
}

fn linesToCounts(lines: []const []const u8) Counts {
    var c: Counts = .{};
    for (lines) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        const val = std.fmt.parseInt(u32, line[sp + 1 ..], 10) catch continue;
        if (std.mem.eql(u8, key, "panics")) c.panics = val;
        if (std.mem.eql(u8, key, "unreachables")) c.unreachables = val;
        if (std.mem.eql(u8, key, "todos")) c.todos = val;
        if (std.mem.eql(u8, key, "fixmes")) c.fixmes = val;
    }
    return c;
}

/// Entry point for the panic-budget check.
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
        ok("panic budget updated (panics={d}, unreachables={d}, todos={d}, fixmes={d})", .{
            totals.panics, totals.unreachables, totals.todos, totals.fixmes,
        });
        return;
    }

    const old = snapshot.read(allocator, snap_path, SNAPSHOT_VERSION) catch |e| switch (e) {
        error.Missing => {
            try snapshot.write(snap_path, SNAPSHOT_VERSION, new_lines);
            ok("panic budget created (panics={d}, unreachables={d}, todos={d}, fixmes={d})", .{
                totals.panics, totals.unreachables, totals.todos, totals.fixmes,
            });
            return;
        },
        error.VersionMismatch => {
            fail("panic budget version mismatch — re-run with {s}=1 to migrate", .{snapshot_helper.UPDATE_ENV});
            return error.CheckFailed;
        },
        else => return e,
    };

    const budget = linesToCounts(old.lines);

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;
    if (totals.panics > budget.panics) {
        try failures.append(allocator, try std.fmt.allocPrint(allocator, "panics: {d} found, {d} budgeted", .{ totals.panics, budget.panics }));
    }
    if (totals.unreachables > budget.unreachables) {
        try failures.append(allocator, try std.fmt.allocPrint(allocator, "unreachables: {d} found, {d} budgeted", .{ totals.unreachables, budget.unreachables }));
    }
    if (totals.todos > budget.todos) {
        try failures.append(allocator, try std.fmt.allocPrint(allocator, "todos: {d} found, {d} budgeted", .{ totals.todos, budget.todos }));
    }
    if (totals.fixmes > budget.fixmes) {
        try failures.append(allocator, try std.fmt.allocPrint(allocator, "fixmes: {d} found, {d} budgeted", .{ totals.fixmes, budget.fixmes }));
    }

    if (failures.items.len == 0) {
        ok("panic budget within limits (panics={d}/{d}, unreachables={d}/{d}, todos={d}/{d}, fixmes={d}/{d})", .{
            totals.panics,       budget.panics,
            totals.unreachables, budget.unreachables,
            totals.todos,        budget.todos,
            totals.fixmes,       budget.fixmes,
        });
        return;
    }

    fail("panic budget FAILED", .{});
    for (failures.items) |line| print("  {s}\n", .{line});
    print("  fix: reduce, OR re-run with {s}=1 and commit .guardian/{s}\n", .{ snapshot_helper.UPDATE_ENV, SNAPSHOT_LEAF });
    return error.CheckFailed;
}

test "countTokens counts panics and unreachables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn x() void { @panic("a"); }
        \\fn y() void { unreachable; }
        \\fn z() void { unreachable; }
        \\const s = "@panic(\"in-string\")";
    ;
    const c = countTokens(a, content);
    try std.testing.expectEqual(@as(u32, 1), c.panics);
    try std.testing.expectEqual(@as(u32, 2), c.unreachables);
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
    const original: Counts = .{ .panics = 5, .unreachables = 3, .todos = 7, .fixmes = 1 };
    const lines = try countsToLines(a, original);
    const parsed = linesToCounts(lines);
    try std.testing.expectEqual(original.panics, parsed.panics);
    try std.testing.expectEqual(original.unreachables, parsed.unreachables);
    try std.testing.expectEqual(original.todos, parsed.todos);
    try std.testing.expectEqual(original.fixmes, parsed.fixmes);
}
