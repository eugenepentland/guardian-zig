const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const config_mod = @import("../config.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const Decl = struct {
    file: []const u8,
    name: []const u8,
};

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    decls: *std.ArrayList(Decl),
    exempt_names: []const []const u8,
};

fn isExempt(exempt: []const []const u8, name: []const u8) bool {
    for (exempt) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

fn collectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        if (isExempt(ctx.exempt_names, f.name)) continue;
        try ctx.decls.append(a, .{ .file = entry.rel_path, .name = f.name });
    }
}

const RefCtx = struct {
    allocator: std.mem.Allocator,
    counts: *std.StringHashMapUnmanaged(u32),
};

fn refVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *RefCtx = @ptrCast(@alignCast(raw_ctx));
    try tallyTestRefs(ctx.allocator, entry.content, ctx.counts);
}

/// Increments `counts[name]` for every identifier token that appears
/// inside a `test {…}` block. Tokens outside test blocks don't count —
/// that's the whole point of this check vs. dead-pub.
///
/// Tracks "inside a test" via a brace-depth stack: when we see
/// `keyword_test` we expect an `l_brace` (possibly preceded by a
/// string_literal); on that brace, push current depth. While the stack
/// is non-empty, identifier tokens are recorded.
const ScanState = struct {
    depth: u32 = 0,
    test_scopes: std.ArrayList(u32) = .empty,
    pending_test: bool = false,

    fn onLBrace(self: *ScanState, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.depth += 1;
        if (!self.pending_test) return;
        try self.test_scopes.append(allocator, self.depth);
        self.pending_test = false;
    }

    fn onRBrace(self: *ScanState) void {
        const items = self.test_scopes.items;
        if (items.len > 0 and items[items.len - 1] == self.depth) _ = self.test_scopes.pop();
        if (self.depth > 0) self.depth -= 1;
    }
};

fn tallyTestRefs(
    allocator: std.mem.Allocator,
    content: []const u8,
    counts: *std.StringHashMapUnmanaged(u32),
) std.mem.Allocator.Error!void {
    const z = try allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    var state: ScanState = .{};
    defer state.test_scopes.deinit(allocator);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_test => state.pending_test = true,
            .l_brace => try state.onLBrace(allocator),
            .r_brace => state.onRBrace(),
            .identifier => {
                if (state.test_scopes.items.len == 0) continue;
                const name = z[t.loc.start..t.loc.end];
                if (counts.getPtr(name)) |p| p.* += 1;
            },
            else => {},
        }
    }
}

/// Returns decls whose test-block reference count is zero.
fn findUntested(
    allocator: std.mem.Allocator,
    decls: []const Decl,
    counts: *std.StringHashMapUnmanaged(u32),
) std.mem.Allocator.Error![]const Decl {
    var untested: std.ArrayList(Decl) = .empty;
    for (decls) |d| {
        const c = counts.get(d.name) orelse 0;
        if (c == 0) try untested.append(allocator, d);
    }
    return untested.toOwnedSlice(allocator);
}

/// Entry point for the test-coverage check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.test_coverage;

    if (!cfg.enabled) {
        ok("test-coverage disabled by config (opt-in via [test_coverage] enabled = true)", .{});
        return;
    }

    // Pass 1: collect every pub fn in src/ (minus exempt names).
    var decls: std.ArrayList(Decl) = .empty;
    var collect_ctx: CollectCtx = .{
        .allocator = allocator,
        .decls = &decls,
        .exempt_names = cfg.exempt_names,
    };
    const collect_walk: walk.Visitor = .{ .ctx = &collect_ctx, .visit = collectVisit };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, collect_walk);

    if (decls.items.len == 0) {
        ok("no public functions to check", .{});
        return;
    }

    // Pass 2: tally test-block references across src/ and test/.
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    for (decls.items) |d| try counts.put(allocator, d.name, 0);
    var ref_ctx: RefCtx = .{ .allocator = allocator, .counts = &counts };
    // `src` reuses the shared index's cached file contents; `test` is not
    // indexed, so it still walks.
    const ref_walk: walk.Visitor = .{ .ctx = &ref_ctx, .visit = refVisit };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, ref_walk);
    const test_path = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    try walk.walkZigFiles(allocator, test_path, .{ .display_root = "test" }, ref_walk);

    const untested = try findUntested(allocator, decls.items, &counts);
    return reportCoverage(untested, decls.items.len);
}

/// Emits the pass/fail summary for the coverage result, returning
/// `error.CheckFailed` when any pub fn lacks a test reference.
fn reportCoverage(untested: []const Decl, total: usize) registry.RunError!void {
    if (untested.len == 0) {
        ok("all {d} pub fn(s) referenced from at least one test", .{total});
        return;
    }

    fail("test-coverage FAILED ({d} pub fn(s) without a test reference)", .{untested.len});
    for (untested) |d| print("  {s}::{s}: no test references this fn\n", .{ d.file, d.name });
    print("  fix: add a test that calls (or references) the fn, OR add the name" ++
        " to [test_coverage] exempt_names if it's an entry point.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Test Coverage - Requires every pub fn to be referenced from at least one test block

test "tallyTestRefs counts only inside test blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    try counts.put(a, "foo", 0);

    const content =
        \\fn caller() void {
        \\    foo();
        \\}
        \\test "x" {
        \\    foo();
        \\    foo();
        \\}
    ;
    try tallyTestRefs(a, content, &counts);
    // The caller() reference doesn't count; only the two inside the test.
    try testing.expectEqual(@as(u32, 2), counts.get("foo").?);
}

test "tallyTestRefs handles anonymous test block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    try counts.put(a, "bar", 0);

    const content =
        \\test {
        \\    _ = bar;
        \\}
    ;
    try tallyTestRefs(a, content, &counts);
    try testing.expectEqual(@as(u32, 1), counts.get("bar").?);
}

test "tallyTestRefs ignores braces in strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    try counts.put(a, "baz", 0);

    const content =
        \\test "fake test" {
        \\    const s = "{ baz }";
        \\    _ = s;
        \\    baz();
        \\}
    ;
    try tallyTestRefs(a, content, &counts);
    // Only the real `baz()` call counts; the one in the string doesn't.
    try testing.expectEqual(@as(u32, 1), counts.get("baz").?);
}

test "findUntested flags pub fn with zero test refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    try counts.put(a, "orphan", 0);

    const decls = [_]Decl{.{ .file = "src/x.zig", .name = "orphan" }};
    const untested = try findUntested(a, &decls, &counts);
    try testing.expectEqual(@as(usize, 1), untested.len);
}

test "findUntested allows pub fn with at least one test ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    try counts.put(a, "alive", 1);

    const decls = [_]Decl{.{ .file = "src/x.zig", .name = "alive" }};
    const untested = try findUntested(a, &decls, &counts);
    try testing.expectEqual(@as(usize, 0), untested.len);
}

test "isExempt matches by name" {
    const exempt = [_][]const u8{ "main", "run" };
    try testing.expect(isExempt(&exempt, "main"));
    try testing.expect(isExempt(&exempt, "run"));
    try testing.expect(!isExempt(&exempt, "other"));
}
