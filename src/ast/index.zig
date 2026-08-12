//! The parse-once source index: reads and parses every src file exactly once
//! per run so the AST-based checks share a single read+parse instead of each
//! repeating it. Built once and handed to checks via `RunCtx.source_index`;
//! `runSrc` falls back to a private index for a standalone single-check run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const walk = @import("../walk.zig");

/// One source file parsed exactly once: its display path, null-terminated
/// content, and syntax tree. The index lets every AST-based check in a run
/// share a single read+parse per file instead of repeating it per check.
pub const Entry = struct {
    rel_path: []const u8,
    content: [:0]const u8,
    tree: Ast,
};

/// An immutable, run-scoped set of parsed source files. Built once by
/// `build` (or `resolve`) and handed to checks through `RunCtx.source_index`.
pub const Index = struct {
    files: []const Entry,

    /// Invokes `visitor` for every indexed file, passing a `FileEntry` whose
    /// `tree` points at the file's pre-parsed syntax tree. Lets a check reuse
    /// its existing walker-style visitor while skipping the per-file parse.
    pub fn forEach(self: *const Index, visitor: walk.Visitor) walk.WalkError!void {
        for (self.files) |*f| {
            try visitor.visit(visitor.ctx, .{
                .rel_path = f.rel_path,
                .content = f.content,
                .tree = &f.tree,
            });
        }
    }
};

const BuildCtx = struct {
    arena: Allocator,
    files: *std.ArrayList(Entry),
};

fn collect(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *BuildCtx = @ptrCast(@alignCast(raw_ctx));
    // entry.content is already null-terminated by the walker — parse it in
    // place instead of copying the whole file again for the sentinel.
    const tree = try Ast.parse(ctx.arena, entry.content, .{});
    try ctx.files.append(ctx.arena, .{ .rel_path = entry.rel_path, .content = entry.content, .tree = tree });
}

/// Walks `<project_dir>/src` once, reading and parsing every `.zig` file
/// into an `Index`. `arena` must outlive every check that consumes the
/// returned index — the run-wide arena in check.zig satisfies this.
/// `excludes` are walker-relative path globs (config `exclude`) dropped from
/// the scan, so a file matching one never reaches any check that reads the
/// shared index (see Config.exclude, walk.matchGlob).
pub fn build(arena: Allocator, project_dir: []const u8, excludes: []const []const u8) walk.WalkError!Index {
    var files: std.ArrayList(Entry) = .empty;
    var ctx: BuildCtx = .{ .arena = arena, .files = &files };
    const src_path = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    const opts: walk.WalkOpts = .{ .display_root = "src", .excludes = excludes };
    try walk.walkZigFiles(arena, src_path, opts, .{ .ctx = &ctx, .visit = collect });
    return .{ .files = try files.toOwnedSlice(arena) };
}

/// Returns the shared index when one is present, otherwise builds a private
/// one into `storage` — for standalone single-check runs that bypass the
/// shared `all` build. The returned pointer is valid for `storage`'s scope.
/// The private build is unfiltered (empty excludes): config `exclude` is
/// applied where the shared index is built (cli/run_all.zig), which every
/// `all` run — the build/CI gate that generates baselines — goes through. A
/// standalone single-check invocation scans the whole tree by design.
pub fn resolve(
    shared: ?*const Index,
    arena: Allocator,
    project_dir: []const u8,
    storage: *Index,
) walk.WalkError!*const Index {
    if (shared) |idx| return idx;
    storage.* = try build(arena, project_dir, &.{});
    return storage;
}

/// Resolves the shared index (or builds a private one) and iterates it with
/// `visitor`. A migrated check replaces its `src` walk with this one call,
/// so the per-file parse is shared in `all` runs and built on demand for a
/// standalone single-check run.
pub fn runSrc(
    shared: ?*const Index,
    arena: Allocator,
    project_dir: []const u8,
    visitor: walk.Visitor,
) walk.WalkError!void {
    var storage: Index = undefined;
    const idx = try resolve(shared, arena, project_dir, &storage);
    try idx.forEach(visitor);
}

// ── Tests ──────────────────────────────────────────────────────────────

const CountCtx = struct {
    seen: usize = 0,
    all_have_tree: bool = true,
};

fn countVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *CountCtx = @ptrCast(@alignCast(raw_ctx));
    ctx.seen += 1;
    if (entry.tree == null) ctx.all_have_tree = false;
}

// spec: AST Index - Builds a parsed-source index by reading and parsing each file once
// spec: AST Index - Iterates the index exposing each file's pre-parsed syntax tree to a visitor
// spec: AST Index - Returns the shared index when present and builds a private one otherwise

test "build reads and parses every src file once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try build(a, "test-project", &.{});
    try std.testing.expect(idx.files.len > 0);
    // Every entry carries a parsed tree over null-terminated content.
    for (idx.files) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f.rel_path, ".zig"));
        try std.testing.expectEqual(@as(u8, 0), f.content[f.content.len]);
    }
}

// spec: AST Index - Drops files matching a config exclude glob from the built index
test "build honors exclude globs, dropping matching files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const all = try build(a, "test-project", &.{});
    const filtered = try build(a, "test-project", &.{"core/"});
    // Excluding the core/ subtree drops files without touching the rest.
    try std.testing.expect(filtered.files.len < all.files.len);
    for (filtered.files) |f| {
        try std.testing.expect(std.mem.indexOf(u8, f.rel_path, "core/") == null);
    }
}

test "forEach hands each file's parsed tree to the visitor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const z = try a.dupeSentinel(u8, "pub fn foo() void {}\n", 0);
    const tree = try Ast.parse(a, z, .{});
    var entries = [_]Entry{.{ .rel_path = "src/x.zig", .content = z, .tree = tree }};
    const idx: Index = .{ .files = &entries };

    var ctx: CountCtx = .{};
    try idx.forEach(.{ .ctx = @ptrCast(&ctx), .visit = countVisit });
    try std.testing.expectEqual(@as(usize, 1), ctx.seen);
    try std.testing.expect(ctx.all_have_tree);
}

test "runSrc iterates a freshly built index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: CountCtx = .{};
    try runSrc(null, a, "test-project", .{ .ctx = @ptrCast(&ctx), .visit = countVisit });
    try std.testing.expect(ctx.seen > 0);
    try std.testing.expect(ctx.all_have_tree);
}

test "resolve returns the shared index when present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var shared: Index = .{ .files = &.{} };
    var storage: Index = undefined;
    const got = try resolve(&shared, a, "test-project", &storage);
    try std.testing.expectEqual(@as(*const Index, &shared), got);

    // With no shared index, a private one is built into storage.
    const built = try resolve(null, a, "test-project", &storage);
    try std.testing.expectEqual(@as(*const Index, &storage), built);
    try std.testing.expect(built.files.len > 0);
}
