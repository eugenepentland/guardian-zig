//! unsafe-ops-budget check: track counts of the unsafe-cast builtins
//! (@ptrCast/@alignCast/@constCast/@bitCast/…) and `undefined` re-assignments
//! against a committed snapshot, so new unsafe surface is a deliberate, reviewed
//! bump. Declaration-init `undefined` and test blocks are excluded.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const text = @import("../text.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const snapshot_leaf = "unsafe-ops-budget.txt";
const check_name = "unsafe-ops-budget";
const snapshot_version: u32 = 1;

/// The unsafe-cast builtins tracked, each written as its own snapshot line so a
/// drift diff names exactly which op grew. `undefined` re-assignment is tracked
/// separately (it is an identifier token, not a builtin).
const unsafe_builtins = [_][]const u8{
    "@ptrCast",
    "@alignCast",
    "@bitCast",
    "@ptrFromInt",
    "@intFromPtr",
    "@constCast",
    "@volatileCast",
};

/// One count per tracked op. `undefined_reassign` counts `x = undefined;`
/// statements that re-poison a live lvalue (the risky pattern) while leaving
/// `var x: T = undefined;` declaration-init — the idiomatic buffer setup —
/// uncounted.
const Counts = struct {
    builtins: [unsafe_builtins.len]u32 = @splat(0),
    undefined_reassign: u32 = 0,

    fn add(self: *Counts, other: Counts) void {
        for (&self.builtins, other.builtins) |*slot, v| slot.* += v;
        self.undefined_reassign += other.undefined_reassign;
    }

    fn castTotal(self: Counts) u32 {
        var n: u32 = 0;
        for (self.builtins) |v| n += v;
        return n;
    }
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    totals: *Counts,
    sites: *SiteList,
};

/// The finding text under a blown `undefined_reassign` budget. One line per
/// site, so the failure is greppable.
const undefined_site_message = "undefined re-assigned to a live lvalue";

/// Collector for `undefined` re-assignment locations. The count used to be
/// reported as a bare total: a consumer that tripped it had nothing to grep for
/// and paid a full gate cycle plus a bisect to find the line. Every site is
/// recorded as a Violation instead, so the failure prints — and logs to
/// last-run.jsonl — a file:line like every other check.
const SiteList = struct {
    allocator: std.mem.Allocator,
    /// The file currently being scanned; set per visit before the token walk.
    rel_path: []const u8 = "",
    items: std.ArrayList(reporter.Violation) = .empty,

    /// Records one re-assignment site in the file being scanned.
    fn add(self: *SiteList, line: u32) std.mem.Allocator.Error!void {
        try self.items.append(self.allocator, .{
            .check = check_name,
            .file = self.rel_path,
            .line = line,
            .message = undefined_site_message,
        });
    }
};

/// Per-file token-walk state: the running counts, a forward-only line cursor
/// (the token walk visits ascending offsets), and the optional site collector.
const Scan = struct {
    counts: Counts = .{},
    cursor: text.LineCursor = .{},
    sites: ?*SiteList = null,
};

/// Per-statement state used to classify an `= undefined`: `is_decl` is true
/// while the current statement began with `var`/`const` (so its `= undefined`
/// is idiomatic declaration-init, not a re-assignment), and `prev_equal` marks
/// that the immediately preceding token was `=`.
const StmtState = struct {
    is_decl: bool = false,
    seen_first: bool = false,
    prev_equal: bool = false,

    /// Advances classification for one token. The first token of a statement
    /// decides `is_decl`; `;`, `{`, and `}` end the statement.
    fn advance(self: *StmtState, tag: std.zig.Token.Tag) void {
        switch (tag) {
            .semicolon, .l_brace, .r_brace => {
                self.* = .{};
                return;
            },
            // A `///` doc comment IS a token (a plain `//` comment is not), but
            // it never STARTS a statement. Letting it claim first-token position
            // set `is_decl = false` on the `var x: [N]T = undefined;` beneath it,
            // so documenting a buffer declaration turned it into a counted
            // re-assignment — the check silently rewarded the `//` spelling.
            .doc_comment, .container_doc_comment => return,
            else => {},
        }
        if (!self.seen_first) {
            self.seen_first = true;
            self.is_decl = tag == .keyword_var or tag == .keyword_const;
        }
    }
};

/// Counts unsafe casts and `undefined` re-assignments by iterating the shared
/// pre-parsed token stream, skipping tokens inside `test { ... }` bodies
/// (tests legitimately poke unsafe corners). Token-based ⇒ strings and
/// comments never match; `tokenSlice` is called only for builtins and the
/// few identifiers that follow an `=`.
fn countFromTree(tree: *const std.zig.Ast, scan: *Scan) std.mem.Allocator.Error!void {
    var scope: text.TestScope = .{};
    var stmt: StmtState = .{};
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag == .eof) break;
        scope.update(tag);
        stmt.advance(tag);
        if (!scope.in_test) try tallyToken(scan, tree, @intCast(i), stmt);
        stmt.prev_equal = tag == .equal;
    }
}

/// Tallies one non-test token: a tracked builtin, or `undefined` assigned to
/// an existing lvalue.
fn tallyToken(scan: *Scan, tree: *const std.zig.Ast, i: u32, stmt: StmtState) std.mem.Allocator.Error!void {
    switch (tree.tokens.items(.tag)[i]) {
        .builtin => tallyBuiltin(&scan.counts, tree.tokenSlice(i)),
        .identifier => try tallyUndefined(scan, tree, i, stmt),
        else => {},
    }
}

/// Counts an `undefined` that re-poisons a live lvalue and records where it is.
/// Declaration-init (`var x: T = undefined;`) never reaches here — `stmt.is_decl`
/// excludes it.
fn tallyUndefined(scan: *Scan, tree: *const std.zig.Ast, i: u32, stmt: StmtState) std.mem.Allocator.Error!void {
    if (!stmt.prev_equal or stmt.is_decl) return;
    if (!std.mem.eql(u8, tree.tokenSlice(i), "undefined")) return;
    scan.counts.undefined_reassign += 1;
    const sites = scan.sites orelse return;
    try sites.add(scan.cursor.at(tree.source, tree.tokenStart(i)));
}

/// Increments the matching builtin counter when `slice` names a tracked op.
fn tallyBuiltin(c: *Counts, slice: []const u8) void {
    for (unsafe_builtins, 0..) |name, i| {
        if (std.mem.eql(u8, slice, name)) {
            c.builtins[i] += 1;
            return;
        }
    }
}

/// Content entry (tests / standalone with no shared tree): parse once, count.
fn countFromContent(allocator: std.mem.Allocator, content: [:0]const u8) std.mem.Allocator.Error!Counts {
    // Propagate OOM: zeroed counts on allocation failure would let a new unsafe
    // op or undefined re-assignment slip past the snapshot budget.
    var tree = try std.zig.Ast.parse(allocator, content, .{});
    var scan: Scan = .{};
    try countFromTree(&tree, &scan);
    return scan.counts;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    ctx.sites.rel_path = entry.rel_path;
    var scan: Scan = .{ .sites = ctx.sites };
    if (entry.tree) |t| {
        try countFromTree(t, &scan);
    } else {
        var tree = try std.zig.Ast.parse(ctx.allocator, entry.content, .{});
        try countFromTree(&tree, &scan);
    }
    ctx.totals.add(scan.counts);
}

fn countsToLines(allocator: std.mem.Allocator, c: Counts) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (unsafe_builtins, c.builtins) |name, n| {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s} {d}", .{ name, n }));
    }
    const reassign_line = try std.fmt.allocPrint(allocator, "undefined_reassign {d}", .{c.undefined_reassign});
    try lines.append(allocator, reassign_line);
    return lines.toOwnedSlice(allocator);
}

fn linesToCounts(lines: []const []const u8) Counts {
    var c: Counts = .{};
    for (lines) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        const val = std.fmt.parseInt(u32, line[sp + 1 ..], 10) catch continue;
        if (std.mem.eql(u8, key, "undefined_reassign")) {
            c.undefined_reassign = val;
            continue;
        }
        for (unsafe_builtins, 0..) |name, i| {
            if (std.mem.eql(u8, key, name)) c.builtins[i] = val;
        }
    }
    return c;
}

/// Builds one "name: N found, M budgeted" line per op whose count rose above
/// its budget, so the failure names exactly which op increased.
fn collectFailures(allocator: std.mem.Allocator, totals: Counts, budget: Counts) ![]const []const u8 {
    var failures: std.ArrayList([]const u8) = .empty;
    for (unsafe_builtins, totals.builtins, budget.builtins) |name, found, cap| {
        if (found <= cap) continue;
        try failures.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}: {d} found, {d} budgeted",
            .{ name, found, cap },
        ));
    }
    if (totals.undefined_reassign > budget.undefined_reassign) {
        try failures.append(allocator, try std.fmt.allocPrint(
            allocator,
            "undefined_reassign: {d} found, {d} budgeted",
            .{ totals.undefined_reassign, budget.undefined_reassign },
        ));
    }
    return failures.toOwnedSlice(allocator);
}

/// Prints the blown budgets, then every `undefined` re-assignment site when
/// that is one of them — a bare "N found, M budgeted" total is the one finding
/// in the suite a reader cannot grep for.
fn reportFailures(failures: []const []const u8, sites: []const reporter.Violation) void {
    fail("unsafe-ops budget FAILED", .{});
    for (failures) |line| print("  {s}\n", .{line});
    for (sites) |v| reporter.emit(v);
    print("  fix: justify the new unsafe op, or accept the new budget:\n", .{});
    snapshot_helper.printAcceptPaths(check_name);
}

/// The re-assignment sites to print: the whole list when that budget is the one
/// that broke, nothing when only a cast budget did (an unrelated wall of lines).
fn sitesFor(over_budget: bool, sites: []const reporter.Violation) []const reporter.Violation {
    return if (over_budget) sites else &.{};
}

fn scanTotals(ctx_param: *registry.RunCtx, sites: *SiteList) registry.RunError!Counts {
    const allocator = ctx_param.allocator;
    var totals: Counts = .{};
    var scan_ctx: ScanCtx = .{ .allocator = allocator, .totals = &totals, .sites = sites };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{
        .ctx = &scan_ctx,
        .visit = visit,
    });
    return totals;
}

/// Loads the budget snapshot. Returns the parsed budget, or null when the
/// snapshot was just (re)written — meaning the caller should report success
/// and stop.
fn loadBudget(
    ctx: *registry.RunCtx,
    snap_path: []const u8,
    totals: Counts,
    new_lines: [][]const u8,
) registry.RunError!?Counts {
    const allocator = ctx.allocator;
    if (snapshot_helper.shouldUpdateForCtx(ctx, check_name)) {
        try snapshot.write(snap_path, snapshot_version, new_lines);
        ok("unsafe-ops budget updated (casts={d}, undefined_reassign={d})", .{
            totals.castTotal(), totals.undefined_reassign,
        });
        return null;
    }
    const old = snapshot.read(allocator, snap_path, snapshot_version) catch |e| {
        return handleReadError(allocator, e, snap_path, totals, new_lines, ctx.metadata_writable);
    };
    return linesToCounts(old.lines);
}

fn handleReadError(
    allocator: std.mem.Allocator,
    e: snapshot.ReadError,
    snap_path: []const u8,
    totals: Counts,
    new_lines: [][]const u8,
    write_allowed: bool,
) registry.RunError!?Counts {
    switch (e) {
        error.Missing => {
            // Persist the first sighting only on a metadata-writable run;
            // an ordinary run grandfathers it green but stays read-only.
            if (write_allowed) _ = try snapshot.writeChecked(allocator, snap_path, snapshot_version, new_lines);
            ok("unsafe-ops budget created (casts={d}, undefined_reassign={d})", .{
                totals.castTotal(), totals.undefined_reassign,
            });
            return null;
        },
        error.VersionMismatch => {
            fail("unsafe-ops budget: stale snapshot", .{});
            print("  fix: re-record the snapshot at the new format version:\n", .{});
            snapshot_helper.printAcceptPaths(check_name);
            return error.CheckFailed;
        },
        else => return e,
    }
}

/// Entry point for the unsafe-ops-budget check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    var sites: SiteList = .{ .allocator = allocator };
    const totals = try scanTotals(ctx_param, &sites);

    const snap_path = try snapshot_helper.snapshotPath(allocator, ctx_param.project_dir, snapshot_leaf);
    const new_lines = try countsToLines(allocator, totals);

    const budget = try loadBudget(ctx_param, snap_path, totals, new_lines) orelse return;

    const failures = try collectFailures(allocator, totals, budget);
    if (failures.len == 0) {
        ok("unsafe-ops budget within limits (casts={d}/{d}, undefined_reassign={d}/{d})", .{
            totals.castTotal(),        budget.castTotal(),
            totals.undefined_reassign, budget.undefined_reassign,
        });
        return;
    }
    reportFailures(failures, sitesFor(totals.undefined_reassign > budget.undefined_reassign, sites.items.items));
    return error.CheckFailed;
}

fn builtinIndex(comptime name: []const u8) usize {
    return comptime blk: {
        for (unsafe_builtins, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) break :blk i;
        }
        @compileError("unknown unsafe builtin name: " ++ name);
    };
}

// spec: Unsafe Ops Budget - Tracks unsafe-cast builtin counts against a snapshot
// spec: Unsafe Ops Budget - Tracks undefined re-assignment count against a snapshot
// spec: Unsafe Ops Budget - Excludes declaration-init undefined and test blocks from counts

test "countFromContent counts each unsafe-cast builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\fn a(p: *u8) usize { return @intFromPtr(p); }
        \\fn b(x: usize) *u8 { return @ptrFromInt(x); }
        \\fn c(p: *const u8) *u8 { return @constCast(p); }
        \\fn d(p: *volatile u8) *u8 { return @volatileCast(p); }
        \\fn e(p: *u8) *u32 { return @alignCast(@ptrCast(p)); }
        \\fn f(x: u32) f32 { return @bitCast(x); }
    ;
    const c = try countFromContent(arena.allocator(), content);
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@ptrCast")]);
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@alignCast")]);
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@bitCast")]);
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@ptrFromInt")]);
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@intFromPtr")]);
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@constCast")]);
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@volatileCast")]);
}

test "countFromContent skips declaration-init undefined but counts re-assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\fn f() void {
        \\    var buf: [16]u8 = undefined;
        \\    const other: u8 = undefined;
        \\    buf[0] = undefined;
        \\    x = undefined;
        \\}
    ;
    const c = try countFromContent(arena.allocator(), content);
    // The two declaration-inits are exempt; the two lvalue re-assignments count.
    try std.testing.expectEqual(@as(u32, 2), c.undefined_reassign);
}

// spec: Unsafe Ops Budget - Counts a doc-commented declaration init as a declaration

test "countFromContent exempts a declaration init carrying a /// doc comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The reported repro: `///` is a TOKEN, so it used to claim the statement's
    // first-token slot and cost the declaration its exemption. `//` never did,
    // which meant the check rewarded the less documented spelling.
    const documented =
        \\/// Scratch space reused across calls.
        \\var buf: [16]u8 = undefined;
    ;
    const doc_counts = try countFromContent(a, documented);
    try std.testing.expectEqual(@as(u32, 0), doc_counts.undefined_reassign);
    // The same declaration under a plain comment always passed; both spellings
    // now agree, and a real re-assignment beneath one still counts.
    const mixed =
        \\// Scratch space reused across calls.
        \\var buf: [16]u8 = undefined;
        \\/// Doc on the next declaration.
        \\var other: [4]u8 = undefined;
        \\fn reset() void { buf[0] = undefined; }
    ;
    const mixed_counts = try countFromContent(a, mixed);
    try std.testing.expectEqual(@as(u32, 1), mixed_counts.undefined_reassign);
}

// spec: Unsafe Ops Budget - Reports the file and line of each undefined re-assignment

test "the scan records a file and line for every undefined re-assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f() void {
        \\    var buf: [16]u8 = undefined;
        \\    buf[0] = undefined;
        \\}
    ;
    var tree = try std.zig.Ast.parse(a, content, .{});
    var sites: SiteList = .{ .allocator = a, .rel_path = "src/x.zig" };
    var scan: Scan = .{ .sites = &sites };
    try countFromTree(&tree, &scan);
    // One re-assignment, located: the totals-only report cost a reporter a full
    // gate cycle plus a bisect because there was nothing to grep for.
    try std.testing.expectEqual(@as(usize, 1), sites.items.items.len);
    try std.testing.expectEqualStrings("src/x.zig", sites.items.items[0].file.?);
    try std.testing.expectEqual(@as(?u32, 3), sites.items.items[0].line);
    // A cast-only budget failure prints no site list — those lines would be
    // about a different counter entirely.
    try std.testing.expectEqual(@as(usize, 0), sitesFor(false, sites.items.items).len);
    try std.testing.expectEqual(@as(usize, 1), sitesFor(true, sites.items.items).len);
}

test "countFromContent excludes unsafe ops inside test blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\fn prod(x: u32) f32 { return @bitCast(x); }
        \\test "poke unsafe" {
        \\    const y = @bitCast(@as(u32, 1));
        \\    z = undefined;
        \\}
    ;
    const c = try countFromContent(arena.allocator(), content);
    // Only the production @bitCast counts; the test-block ops are excluded.
    try std.testing.expectEqual(@as(u32, 1), c.builtins[builtinIndex("@bitCast")]);
    try std.testing.expectEqual(@as(u32, 0), c.undefined_reassign);
}

test "countFromContent ignores builtins and undefined inside strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\const s = "@ptrCast and x = undefined";
    ;
    const c = try countFromContent(arena.allocator(), content);
    try std.testing.expectEqual(@as(u32, 0), c.undefined_reassign);
    for (c.builtins) |n| try std.testing.expectEqual(@as(u32, 0), n);
}

test "linesToCounts round-trips countsToLines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var original: Counts = .{ .undefined_reassign = 4 };
    original.builtins[0] = 3;
    original.builtins[3] = 9;
    const lines = try countsToLines(a, original);
    const parsed = linesToCounts(lines);
    try std.testing.expectEqual(original.undefined_reassign, parsed.undefined_reassign);
    try std.testing.expectEqual(original.builtins[0], parsed.builtins[0]);
    try std.testing.expectEqual(original.builtins[3], parsed.builtins[3]);
}

test "collectFailures names the op that increased over budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var totals: Counts = .{ .undefined_reassign = 2 };
    totals.builtins[builtinIndex("@ptrCast")] = 5;
    var budget: Counts = .{ .undefined_reassign = 2 };
    budget.builtins[builtinIndex("@ptrCast")] = 4;
    const failures = try collectFailures(a, totals, budget);
    // ptrCast rose (5>4); undefined_reassign held steady (2==2) so is not listed.
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expect(std.mem.indexOf(u8, failures[0], "@ptrCast") != null);
    try std.testing.expect(std.mem.indexOf(u8, failures[0], "5 found") != null);
    try std.testing.expect(std.mem.indexOf(u8, failures[0], "4 budgeted") != null);
}

test "collectFailures empty when all counts within budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var totals: Counts = .{ .undefined_reassign = 1 };
    totals.builtins[builtinIndex("@bitCast")] = 3;
    var budget: Counts = .{ .undefined_reassign = 2 };
    budget.builtins[builtinIndex("@bitCast")] = 3;
    const failures = try collectFailures(a, totals, budget);
    try std.testing.expectEqual(@as(usize, 0), failures.len);
}
