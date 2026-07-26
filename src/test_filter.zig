//! Diff-derived test-name filter: which of a project's tests a *local* edit
//! loop could run instead of the whole suite, and — just as important — what
//! such a run would not cover.
//!
//! Zig convention keeps a file's tests in the file itself, so "changed file →
//! the `test \"…\"` names it declares" is a reasonable first approximation of
//! the relevant tests. It is only an approximation: a change in one file
//! routinely breaks a test declared in another, and Zig's `--test-filter` is a
//! *compiler* flag, so unmatched tests are never analyzed — a filtered run
//! therefore cannot even prove the test binary still builds.
//!
//! That is why this module only ever *describes* a filter. Nothing here selects
//! what a gate runs: `commit`, the pre-commit hook, and CI keep running the
//! project's whole `[gate] test_command`. Every derivation carries its own
//! blind spots (unnamed test blocks, changed files with no tests, changed paths
//! that aren't indexed source, and the tests of every file that depends on a
//! changed one) so a green filtered run can never be mistaken for a green suite.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const ast_index = @import("ast/index.zig");
const decls = @import("ast/decls.zig");
const import_graph = @import("ast/import_graph.zig");

/// The tests one source file declares: the name-filterable ones, plus how many
/// unnamed `test { }` blocks it has. An unnamed block has no name to match, so
/// it runs under *every* filter and can never be selected by one.
pub const FileTests = struct {
    names: []const []const u8 = &.{},
    unnamed: usize = 0,
};

/// A derived filter together with everything it leaves out. The omissions are
/// part of the value: a caller that prints `names` without them would let a
/// developer read a green filtered run as a green suite.
pub const Derivation = struct {
    /// Test names declared by the changed files, in discovery order, deduped.
    names: []const []const u8 = &.{},
    /// Unnamed `test { }` blocks in the changed files — they always run and
    /// cannot be name-filtered.
    unnamed_blocks: usize = 0,
    /// Changed source files that declare no test at all: nothing about them is
    /// exercised by this filter.
    testless_files: []const []const u8 = &.{},
    /// Changed paths with no indexed source file — non-Zig assets, `build.zig`,
    /// tests living outside the scanned source root. Nothing can be derived.
    unindexed_paths: []const []const u8 = &.{},
    /// Indexed files that reach a changed file through `@import`, directly or
    /// transitively, and were not themselves changed.
    dependent_files: usize = 0,
    /// How many named tests those dependents declare — the blind spot's size.
    dependent_tests: usize = 0,

    /// True when no test name was derived. Callers must treat this as "run the
    /// whole suite", never as "run nothing".
    pub fn isEmpty(self: Derivation) bool {
        return self.names.len == 0;
    }
};

/// Inputs to `derive`, bundled so the signature stays one value: the changed
/// paths (walker-relative, as `scope.Plan.files` reports them), the parsed
/// source index, and the project's `@import` graph.
pub const Inputs = struct {
    changed: []const []const u8,
    index: *const ast_index.Index,
    graph: []const import_graph.Node,
};

/// Every test `tree` declares, descending into container members so a test
/// nested in a `struct` is found too. A name that is not a well-formed string
/// literal counts as unnamed: there is no text that would reliably match it.
pub fn declaredTests(arena: Allocator, tree: *const Ast) Allocator.Error!FileTests {
    var names: std.ArrayList([]const u8) = .empty;
    var unnamed: usize = 0;
    for (try decls.collectDecls(arena, tree)) |decl| {
        if (tree.nodeTag(decl) != .test_decl) continue;
        const opt_name, _ = tree.nodeData(decl).opt_token_and_node;
        const token = opt_name.unwrap() orelse {
            unnamed += 1;
            continue;
        };
        const name = try testName(arena, tree, token);
        if (name) |n| try names.append(arena, n) else unnamed += 1;
    }
    return .{ .names = try names.toOwnedSlice(arena), .unnamed = unnamed };
}

/// The filter text for a test's name token: the unescaped literal for
/// `test "name"`, the identifier for a decltest. Null when the literal cannot
/// be decoded, so the caller counts it among the unfilterable tests instead of
/// emitting a filter that would match the wrong thing.
fn testName(arena: Allocator, tree: *const Ast, token: Ast.TokenIndex) Allocator.Error!?[]const u8 {
    const slice = tree.tokenSlice(token);
    if (tree.tokenTag(token) != .string_literal) return slice;
    return std.zig.string_literal.parseAlloc(arena, slice) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// Derives the filter for one changed-file set and measures what it misses.
/// OOM propagates: a truncated derivation would understate the blind spot,
/// which is the one error this module must never make.
pub fn derive(arena: Allocator, in: Inputs) Allocator.Error!Derivation {
    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var testless: std.ArrayList([]const u8) = .empty;
    var unnamed: usize = 0;

    for (in.changed) |path| {
        const entry = findEntry(in.index, path) orelse continue;
        const tests = try declaredTests(arena, &entry.tree);
        unnamed += tests.unnamed;
        if (tests.names.len == 0 and tests.unnamed == 0) try testless.append(arena, path);
        for (tests.names) |name| {
            const prior = try seen.fetchPut(arena, name, {});
            if (prior != null) continue;
            try names.append(arena, name);
        }
    }

    const dependents = try dependentFiles(arena, in);
    return .{
        .names = try names.toOwnedSlice(arena),
        .unnamed_blocks = unnamed,
        .testless_files = try testless.toOwnedSlice(arena),
        .unindexed_paths = try unindexedPaths(arena, in),
        .dependent_files = dependents.len,
        .dependent_tests = try countTests(arena, in.index, dependents),
    };
}

/// The indexed entry for a walker-relative path, or null when the path is not
/// scanned source (a doc, a config file, `build.zig`, a test outside the root).
fn findEntry(index: *const ast_index.Index, path: []const u8) ?*const ast_index.Entry {
    for (index.files) |*entry| {
        if (std.mem.eql(u8, entry.rel_path, path)) return entry;
    }
    return null;
}

/// Changed paths that no indexed source file corresponds to.
fn unindexedPaths(arena: Allocator, in: Inputs) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (in.changed) |path| {
        if (findEntry(in.index, path) != null) continue;
        try out.append(arena, path);
    }
    return out.toOwnedSlice(arena);
}

/// Unchanged files that reach a changed file through `@import`, transitively.
/// This is the honest upper bound on "tests the filter omits but the change
/// could break", and it is usually large — which is the point.
fn dependentFiles(arena: Allocator, in: Inputs) Allocator.Error![]const []const u8 {
    var affected: std.StringHashMapUnmanaged(void) = .empty;
    for (in.changed) |path| try affected.put(arena, path, {});

    var grew = true;
    while (grew) {
        grew = false;
        for (in.graph) |node| {
            if (affected.contains(node.path)) continue;
            if (!importsAffected(node, affected)) continue;
            try affected.put(arena, node.path, {});
            grew = true;
        }
    }

    var out: std.ArrayList([]const u8) = .empty;
    for (in.index.files) |entry| {
        if (!affected.contains(entry.rel_path)) continue;
        if (contains(in.changed, entry.rel_path)) continue;
        try out.append(arena, entry.rel_path);
    }
    return out.toOwnedSlice(arena);
}

/// True when any of `node`'s import edges names an already-affected file.
fn importsAffected(node: import_graph.Node, affected: std.StringHashMapUnmanaged(void)) bool {
    for (node.edges) |edge| {
        if (affected.contains(edge)) return true;
    }
    return false;
}

/// True when `paths` contains `needle` exactly.
fn contains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

/// How many named tests `paths` declare in total.
fn countTests(arena: Allocator, index: *const ast_index.Index, paths: []const []const u8) Allocator.Error!usize {
    var total: usize = 0;
    for (paths) |path| {
        const entry = findEntry(index, path) orelse continue;
        total += (try declaredTests(arena, &entry.tree)).names.len;
    }
    return total;
}

/// Renders `names` as shell-ready arguments, one `<flag><name>` per name,
/// single-quoted so a name containing spaces or shell metacharacters survives
/// command substitution. An empty derivation renders the empty string, so a
/// pipeline that interpolates it falls back to the project's whole suite
/// rather than to a filter that matches nothing.
pub fn renderArgs(arena: Allocator, names: []const []const u8, flag: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names) |name| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, flag);
        try shellQuote(arena, &out, name);
    }
    return out.toOwnedSlice(arena);
}

/// Appends `text` POSIX single-quoted, closing and reopening the quote around
/// each embedded apostrophe (`'` → `'\''`).
fn shellQuote(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(arena, '\'');
    for (text) |c| {
        if (c != '\'') {
            try out.append(arena, c);
            continue;
        }
        try out.appendSlice(arena, "'\\''");
    }
    try out.append(arena, '\'');
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses `source` into an arena-owned index entry for the derivation tests.
fn entryFor(arena: Allocator, rel_path: []const u8, source: []const u8) !ast_index.Entry {
    const z = try arena.dupeZ(u8, source);
    return .{ .rel_path = rel_path, .content = z, .tree = try Ast.parse(arena, z, .zig) };
}

// spec: Test Filter - Derives the test names declared by each changed file

test "declaredTests reads named tests including ones nested in a container" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry = try entryFor(a, "src/a.zig",
        \\test "alpha" {}
        \\const S = struct {
        \\    test "beta" {}
        \\};
        \\test "gamma\ttabbed" {}
    );
    const got = try declaredTests(a, &entry.tree);
    try testing.expectEqual(@as(usize, 3), got.names.len);
    try testing.expectEqualStrings("alpha", got.names[0]);
    try testing.expectEqualStrings("beta", got.names[1]);
    // The escape is decoded, so the emitted filter is the runtime test name.
    try testing.expectEqualStrings("gamma\ttabbed", got.names[2]);
    try testing.expectEqual(@as(usize, 0), got.unnamed);
}

// spec: Test Filter - Counts unnamed test blocks as tests no name filter can select

test "declaredTests counts unnamed test blocks separately from named ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry = try entryFor(a, "src/a.zig",
        \\test { _ = @import("b.zig"); }
        \\test "named" {}
        \\test {}
    );
    const got = try declaredTests(a, &entry.tree);
    try testing.expectEqual(@as(usize, 1), got.names.len);
    try testing.expectEqualStrings("named", got.names[0]);
    // Both anonymous blocks are unfilterable and always run.
    try testing.expectEqual(@as(usize, 2), got.unnamed);
}

// spec: Test Filter - Derives names only from changed files and deduplicates them

test "derive takes names from the changed files alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries = [_]ast_index.Entry{
        try entryFor(a, "src/a.zig", "test \"a one\" {}\ntest \"shared\" {}\n"),
        try entryFor(a, "src/b.zig", "test \"b one\" {}\ntest \"shared\" {}\n"),
        try entryFor(a, "src/c.zig", "test \"c one\" {}\n"),
    };
    const index: ast_index.Index = .{ .files = &entries };
    const got = try derive(a, .{
        .changed = &.{ "src/a.zig", "src/b.zig" },
        .index = &index,
        .graph = &.{},
    });
    // a's two names, plus b's one new one: "shared" is not emitted twice.
    try testing.expectEqual(@as(usize, 3), got.names.len);
    try testing.expectEqualStrings("a one", got.names[0]);
    try testing.expectEqualStrings("shared", got.names[1]);
    try testing.expectEqualStrings("b one", got.names[2]);
}

// spec: Test Filter - Reports changed files that declare no test and changed paths that are not indexed source

test "derive reports testless changed files and unindexed changed paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries = [_]ast_index.Entry{
        try entryFor(a, "src/a.zig", "pub fn f() void {}\n"),
    };
    const index: ast_index.Index = .{ .files = &entries };
    const got = try derive(a, .{
        .changed = &.{ "src/a.zig", "SPEC.md", "build.zig" },
        .index = &index,
        .graph = &.{},
    });
    // Nothing to run, and the caller must be told why rather than shown "0".
    try testing.expect(got.isEmpty());
    try testing.expectEqual(@as(usize, 1), got.testless_files.len);
    try testing.expectEqualStrings("src/a.zig", got.testless_files[0]);
    try testing.expectEqual(@as(usize, 2), got.unindexed_paths.len);
    try testing.expectEqualStrings("SPEC.md", got.unindexed_paths[0]);
    try testing.expectEqualStrings("build.zig", got.unindexed_paths[1]);
}

// spec: Test Filter - Reports the tests of every unchanged file that transitively imports a changed one

test "derive counts the tests of transitive dependents of a changed file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries = [_]ast_index.Entry{
        try entryFor(a, "src/core.zig", "test \"core one\" {}\n"),
        try entryFor(a, "src/mid.zig", "test \"mid one\" {}\ntest \"mid two\" {}\n"),
        try entryFor(a, "src/top.zig", "test \"top one\" {}\n"),
        try entryFor(a, "src/other.zig", "test \"other one\" {}\n"),
    };
    const index: ast_index.Index = .{ .files = &entries };
    const graph = [_]import_graph.Node{
        .{ .path = "src/core.zig", .edges = &.{} },
        .{ .path = "src/mid.zig", .edges = &.{"src/core.zig"} },
        .{ .path = "src/top.zig", .edges = &.{"src/mid.zig"} },
        .{ .path = "src/other.zig", .edges = &.{} },
    };
    const got = try derive(a, .{
        .changed = &.{"src/core.zig"},
        .index = &index,
        .graph = &graph,
    });
    try testing.expectEqual(@as(usize, 1), got.names.len);
    // mid imports core and top imports mid — both are downstream of the edit
    // and neither of their three tests is in the filter. other.zig is not.
    try testing.expectEqual(@as(usize, 2), got.dependent_files);
    try testing.expectEqual(@as(usize, 3), got.dependent_tests);
}

// spec: Test Filter - Emits no filter arguments when no test name was derived

test "renderArgs quotes each name and renders nothing for an empty derivation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try renderArgs(a, &.{ "has spaces", "it's quoted" }, "-Dtest-filter=");
    try testing.expectEqualStrings(
        "-Dtest-filter='has spaces' -Dtest-filter='it'\\''s quoted'",
        args,
    );
    // The fail-safe: nothing derived renders no arguments at all, so a caller
    // interpolating this runs its whole suite instead of zero tests.
    try testing.expectEqualStrings("", try renderArgs(a, &.{}, "-Dtest-filter="));
}
