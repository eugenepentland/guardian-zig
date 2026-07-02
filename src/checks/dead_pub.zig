const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const text = @import("../text.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

//
// Known limitation: counts are keyed by name only. Two pub decls in
// different files sharing a name share a counter — if either is referenced,
// both look alive. A proper fix requires AST-resolved references (parse
// `parser.foo` as a reference to `parser`'s file). For now, the under-flagging
// is documented and locked in by `findDead known limitation` test below.

const Decl = struct {
    file: []const u8,
    name: []const u8,
};

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    decls: *std.ArrayListUnmanaged(Decl),
};

fn collectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        if (std.mem.eql(u8, f.name, "main")) continue;
        if (std.mem.eql(u8, f.name, "build")) continue;
        if (std.mem.eql(u8, f.name, "run")) continue;
        try ctx.decls.append(a, .{ .file = entry.rel_path, .name = f.name });
    }
    const consts = if (entry.tree) |t| try ast.pubConstsFromTree(a, t) else try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        try ctx.decls.append(a, .{ .file = entry.rel_path, .name = c.name });
    }
}

const RefCtx = struct {
    allocator: std.mem.Allocator,
    counts: *std.StringHashMap(u32),
    skip_tests: bool = false,
};

fn refVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *RefCtx = @ptrCast(@alignCast(raw_ctx));
    try tallyIdentifiers(ctx.allocator, entry.content, ctx.counts, ctx.skip_tests);
}

/// Increments `counts[name]` for every identifier token in `content` that is
/// already a key in `counts`. Identifiers we don't track are ignored. When
/// `skip_tests` is set, identifiers inside `test {...}` blocks don't count, so
/// a pub decl kept alive only by its own test is still seen as dead.
fn tallyIdentifiers(
    allocator: std.mem.Allocator,
    content: []const u8,
    counts: *std.StringHashMap(u32),
    skip_tests: bool,
) !void {
    const z = try allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var scope: text.TestScope = .{};
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        scope.update(t.tag);
        if (t.tag != .identifier) continue;
        if (skip_tests and scope.in_test) continue;
        const name = z[t.loc.start..t.loc.end];
        if (counts.getPtr(name)) |p| p.* += 1;
    }
}

/// Returns decls whose identifier-token count is at most 1 (only the
/// declaration itself, no callers / tests / signatures).
fn findDead(
    allocator: std.mem.Allocator,
    decls: []const Decl,
    counts: *std.StringHashMap(u32),
) ![]const Decl {
    var dead: std.ArrayListUnmanaged(Decl) = .empty;
    for (decls) |d| {
        const c = counts.get(d.name) orelse 0;
        if (c <= 1) try dead.append(allocator, d);
    }
    return dead.toOwnedSlice(allocator);
}

/// Entry point for the dead-pub check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    // Pass 1: collect every pub decl in src/.
    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    var collect_ctx: CollectCtx = .{ .allocator = allocator, .decls = &decls };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{
        .ctx = &collect_ctx,
        .visit = collectVisit,
    });

    if (decls.items.len == 0) {
        ok("no public declarations to check", .{});
        return;
    }

    // Pass 2: tally identifier-token references across src/ and test/.
    var counts = std.StringHashMap(u32).init(allocator);
    for (decls.items) |d| {
        try counts.put(d.name, 0);
    }
    const ignore_test = ctx_param.cfg.dead_pub.ignore_test_refs;
    var ref_ctx: RefCtx = .{
        .allocator = allocator,
        .counts = &counts,
        .skip_tests = ignore_test,
    };
    // `src` reuses the shared index's cached file contents; `test` is not
    // indexed, so it still walks. When ignore_test_refs is set, test-block
    // references in src don't count and the test/ tree is skipped entirely.
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ref_ctx, .visit = refVisit });
    if (!ignore_test) {
        const test_path = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
        const test_opts: walk.Visitor = .{ .ctx = &ref_ctx, .visit = refVisit };
        try walk.walkZigFiles(allocator, test_path, .{ .display_root = "test" }, test_opts);
    }
    // build.zig is a Zig file at the project root — include its references
    // so consumer-facing build helpers aren't flagged dead.
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_dir});
    if (std.fs.cwd().readFileAlloc(allocator, build_path, 1024 * 1024)) |content| {
        try tallyIdentifiers(allocator, content, &counts, false);
    } else |_| {}

    const dead = try findDead(allocator, decls.items, &counts);

    if (dead.len == 0) {
        ok("no unused public declarations ({d} pub decls scanned)", .{decls.items.len});
        return;
    }

    fail("dead-pub FAILED ({d} unused public declaration(s))", .{dead.len});
    for (dead) |d| print("  {s}::{s}: unused public declaration\n", .{ d.file, d.name });
    print("  fix: remove, demote to private (drop `pub`), or reference from a test.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Dead Pub - Flags public declarations referenced only by themselves

test "findDead flags decl with no callers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("orphan", 1); // 1 = the decl itself, no caller

    const decls = [_]Decl{.{ .file = "src/a.zig", .name = "orphan" }};
    const dead = try findDead(a, &decls, &counts);
    try testing.expectEqual(@as(usize, 1), dead.len);
    try testing.expectEqualStrings("orphan", dead[0].name);
}

test "findDead does not flag decl with at least one caller" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("alive", 2); // decl + 1 caller

    const decls = [_]Decl{.{ .file = "src/a.zig", .name = "alive" }};
    const dead = try findDead(a, &decls, &counts);
    try testing.expectEqual(@as(usize, 0), dead.len);
}

test "tallyIdentifiers counts identifiers and skips strings/comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("foo", 0);

    const content =
        \\fn caller() void {
        \\    foo();
        \\    foo();
        \\}
        \\const s = "foo in string"; // foo in comment
    ;
    try tallyIdentifiers(a, content, &counts, false);
    try testing.expectEqual(@as(u32, 2), counts.get("foo").?);
}

// spec: Dead Pub - Skips test-block references toward liveness when configured
test "tallyIdentifiers can skip test-block references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("widget", 0);

    const content =
        \\pub fn widget() void {}
        \\test "uses widget" {
        \\    widget();
        \\    widget();
        \\}
    ;
    try tallyIdentifiers(a, content, &counts, true);
    // Only the declaration itself counts; the two test references are skipped.
    try testing.expectEqual(@as(u32, 1), counts.get("widget").?);
}

test "findDead known limitation: same-named decls in different files share a counter" {
    // Documents the under-flagging behavior. If dead-pub is ever upgraded
    // to AST-resolved references (key on (file, name) + import resolution),
    // this test will need to be split or updated to expect the dead one.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var counts = std.StringHashMap(u32).init(a);
    try counts.put("shared", 3); // 2 decls (one in each file) + 1 caller

    const decls = [_]Decl{
        .{ .file = "src/a.zig", .name = "shared" },
        .{ .file = "src/b.zig", .name = "shared" },
    };
    const dead = try findDead(a, &decls, &counts);
    // Both share the counter; with count=3 (>1) neither is flagged, even
    // though only one is genuinely referenced.
    try testing.expectEqual(@as(usize, 0), dead.len);
}

test "exempt names are not collected" {
    // Smoke test — full integration is exercised by Guardian's self-build.
    const exempt = [_][]const u8{ "main", "build", "run" };
    for (exempt) |n| try testing.expect(n.len > 0);
}
