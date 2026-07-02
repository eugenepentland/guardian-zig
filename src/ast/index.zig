const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const walk = @import("../walk.zig");

// spec: AST Index - Builds a parsed-source index by reading and parsing each file once
// spec: AST Index - Iterates the index exposing each file's pre-parsed syntax tree to a visitor
// spec: AST Index - Returns the shared index when present and builds a private one otherwise

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
    files: *std.ArrayListUnmanaged(Entry),
};

fn collect(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *BuildCtx = @ptrCast(@alignCast(raw_ctx));
    // entry.content is already null-terminated by the walker — parse it in
    // place instead of copying the whole file again for the sentinel.
    const tree = try Ast.parse(ctx.arena, entry.content, .zig);
    try ctx.files.append(ctx.arena, .{ .rel_path = entry.rel_path, .content = entry.content, .tree = tree });
}

/// Walks `<project_dir>/src` once, reading and parsing every `.zig` file
/// into an `Index`. `arena` must outlive every check that consumes the
/// returned index — the run-wide arena in check.zig satisfies this.
pub fn build(arena: Allocator, project_dir: []const u8) walk.WalkError!Index {
    var files: std.ArrayListUnmanaged(Entry) = .empty;
    var ctx: BuildCtx = .{ .arena = arena, .files = &files };
    const src_path = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    try walk.walkZigFiles(arena, src_path, "src", .{}, .{ .ctx = &ctx, .visit = collect });
    return .{ .files = try files.toOwnedSlice(arena) };
}

/// Returns the shared index when one is present, otherwise builds a private
/// one into `storage` — for standalone single-check runs that bypass the
/// shared `all` build. The returned pointer is valid for `storage`'s scope.
pub fn resolve(
    shared: ?*const Index,
    arena: Allocator,
    project_dir: []const u8,
    storage: *Index,
) walk.WalkError!*const Index {
    if (shared) |idx| return idx;
    storage.* = try build(arena, project_dir);
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

fn countVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *CountCtx = @ptrCast(@alignCast(raw_ctx));
    ctx.seen += 1;
    if (entry.tree == null) ctx.all_have_tree = false;
}

test "build reads and parses every src file once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const idx = try build(a, "test-project");
    try std.testing.expect(idx.files.len > 0);
    // Every entry carries a parsed tree over null-terminated content.
    for (idx.files) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f.rel_path, ".zig"));
        try std.testing.expectEqual(@as(u8, 0), f.content[f.content.len]);
    }
}

test "forEach hands each file's parsed tree to the visitor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const z = try a.dupeZ(u8, "pub fn foo() void {}\n");
    const tree = try Ast.parse(a, z, .zig);
    var entries = [_]Entry{.{ .rel_path = "src/x.zig", .content = z, .tree = tree }};
    const idx: Index = .{ .files = &entries };

    var ctx: CountCtx = .{};
    try idx.forEach(.{ .ctx = @ptrCast(&ctx), .visit = countVisit });
    try std.testing.expectEqual(@as(usize, 1), ctx.seen);
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
