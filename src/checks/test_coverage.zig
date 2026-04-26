const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const config_mod = @import("../config.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Test Coverage - Requires every pub fn to be referenced from at least one test block

const Decl = struct {
    file: []const u8,
    name: []const u8,
};

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    decls: *std.ArrayListUnmanaged(Decl),
    exempt_names: []const []const u8,
};

fn isExempt(exempt: []const []const u8, name: []const u8) bool {
    for (exempt) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

fn collectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const fns = try ast.pubFns(a, entry.content);
    for (fns) |f| {
        if (isExempt(ctx.exempt_names, f.name)) continue;
        try ctx.decls.append(a, .{ .file = entry.rel_path, .name = f.name });
    }
}

const RefCtx = struct {
    allocator: std.mem.Allocator,
    counts: *std.StringHashMap(u32),
};

fn refVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
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
fn tallyTestRefs(
    allocator: std.mem.Allocator,
    content: []const u8,
    counts: *std.StringHashMap(u32),
) std.mem.Allocator.Error!void {
    const z = try allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    var depth: u32 = 0;
    var test_scopes: std.ArrayListUnmanaged(u32) = .empty;
    defer test_scopes.deinit(allocator);
    var pending_test = false;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_test => pending_test = true,
            .l_brace => {
                depth += 1;
                if (pending_test) {
                    try test_scopes.append(allocator, depth);
                    pending_test = false;
                }
            },
            .r_brace => {
                if (test_scopes.items.len > 0 and test_scopes.items[test_scopes.items.len - 1] == depth) {
                    _ = test_scopes.pop();
                }
                if (depth > 0) depth -= 1;
            },
            .identifier => {
                if (test_scopes.items.len == 0) continue;
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
    counts: *std.StringHashMap(u32),
) std.mem.Allocator.Error![]const Decl {
    var untested: std.ArrayListUnmanaged(Decl) = .empty;
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
    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    var collect_ctx: CollectCtx = .{
        .allocator = allocator,
        .decls = &decls,
        .exempt_names = cfg.exempt_names,
    };
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &collect_ctx, .visit = collectVisit });

    if (decls.items.len == 0) {
        ok("no public functions to check", .{});
        return;
    }

    // Pass 2: tally test-block references across src/ and test/.
    var counts = std.StringHashMap(u32).init(allocator);
    for (decls.items) |d| try counts.put(d.name, 0);
    var ref_ctx: RefCtx = .{ .allocator = allocator, .counts = &counts };
    const dirs = [_][]const u8{ "src", "test" };
    for (&dirs) |dir| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir });
        try walk.walkZigFiles(allocator, dir_path, dir, .{}, .{ .ctx = &ref_ctx, .visit = refVisit });
    }

    const untested = try findUntested(allocator, decls.items, &counts);

    if (untested.len == 0) {
        ok("all {d} pub fn(s) referenced from at least one test", .{decls.items.len});
        return;
    }

    fail("test-coverage FAILED ({d} pub fn(s) without a test reference)", .{untested.len});
    for (untested) |d| print("  {s}::{s}: no test references this fn\n", .{ d.file, d.name });
    print("  fix: add a test that calls (or references) the fn, OR add the name to [test_coverage] exempt_names if it's an entry point.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "tallyTestRefs counts only inside test blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("foo", 0);

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

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("bar", 0);

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

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("baz", 0);

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

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("orphan", 0);

    const decls = [_]Decl{.{ .file = "src/x.zig", .name = "orphan" }};
    const untested = try findUntested(a, &decls, &counts);
    try testing.expectEqual(@as(usize, 1), untested.len);
}

test "findUntested allows pub fn with at least one test ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("alive", 1);

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
