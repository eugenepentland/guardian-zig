//! init-hygiene check: an `init`/`create`/`make` body should be straight-line
//! field assignment, so constructing a value can't fail in surprising ways or
//! hide logic a caller cannot see. Any `if`/`while`/`for`/`switch` in such a
//! body is flagged, with one deliberate exemption: a non-pub init referenced
//! only from `test` blocks is a fixture builder, and filling a fixture array in
//! a loop is what it exists to do (see `isTestFixture`).

const std = @import("std");
const ast = @import("../ast/parser.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;
const TestScope = @import("../text.zig").TestScope;

const init_names = [_][]const u8{ "init", "create", "make" };

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayList([]const u8),
};

/// Pure-function entry: scans `content` for init-shaped fns whose body
/// contains control flow (if / while / for / switch).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    return analyzeWithTree(allocator, rel_path, content, null);
}

fn analyzeWithTree(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    tree: ?*const std.zig.Ast,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fns = if (tree) |t| try ast.fnDeclInfosFromTree(a, t) else try ast.fnDeclInfos(a, content);

    for (fns) |fn_info| {
        if (!isInitName(fn_info.name)) continue;
        const offender = (try scanBody(a, fn_info.body_text)) orelse continue;
        if (try isTestFixture(a, content, fn_info)) continue;
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}:{d}: init-shaped fn '{s}' contains '{s}' (constructors should be straight-line)",
            .{ rel_path, fn_info.start_line, fn_info.name, offender },
        );
        try violations.append(allocator, msg);
    }
    return violations.toOwnedSlice(allocator);
}

fn isInitName(name: []const u8) bool {
    for (init_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// True when this init-shaped fn is a test fixture builder rather than a
/// constructor the product uses: not `pub` (so no other file can reach it) and
/// referenced nowhere outside a `test` block in its own file. A loop that fills
/// a fixture array is exactly what a fixture builder is for, and the check used
/// to force a rename (`init` → `setupBoard`) that served only the checker.
/// Deliberately narrow: a `pub` init is still gated, because a caller anywhere
/// in the tree can construct with it.
fn isTestFixture(arena: Allocator, content: []const u8, fn_info: ast.FnDeclInfo) Allocator.Error!bool {
    if (fn_info.is_pub) return false;
    const z = try arena.dupeZ(u8, content);
    return !referencedOutsideTests(z, fn_info.name);
}

/// True when `name` appears as an identifier outside every `test { ... }` block
/// — production use. The declaration's own name token (the identifier right
/// after `fn`) never counts as a use of itself.
fn referencedOutsideTests(z: [:0]const u8, name: []const u8) bool {
    var tok = std.zig.Tokenizer.init(z);
    var scope = TestScope{};
    var prev: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return false;
        scope.update(t.tag);
        defer prev = t.tag;
        if (t.tag != .identifier or scope.in_test or prev == .keyword_fn) continue;
        if (std.mem.eql(u8, z[t.loc.start..t.loc.end], name)) return true;
    }
}

fn scanBody(arena: Allocator, body: []const u8) Allocator.Error!?[]const u8 {
    const z = try arena.dupeZ(u8, body);
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        const keyword: ?[]const u8 = switch (t.tag) {
            .keyword_if => "if",
            .keyword_while => "while",
            .keyword_for => "for",
            .keyword_switch => "switch",
            else => null,
        };
        if (keyword) |k| return k;
    }
    return null;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeWithTree(ctx.allocator, entry.rel_path, entry.content, entry.tree);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the init-hygiene check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("init-hygiene: every init/create/make body is straight-line", .{});
        return;
    }
    reporter.fail("init-hygiene FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: move conditional logic into a factory or builder; keep init field-assignment-only. " ++
        "A test fixture builder is already exempt when it is non-pub and used only from test blocks — " ++
        "no rename needed.\n", .{});
    return error.CheckFailed;
}

// spec: Constructor Hygiene - Rejects init bodies with loops, conditionals, or switch statements

test "analyzeContent flags init with if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(x: u32) Foo { if (x > 0) return .{}; return .{}; }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags init with for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(items: []u32) Foo { for (items) |i| { _ = i; } return .{}; }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows straight-line init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn init(a: u32, b: u32) Foo { return .{ .a = a, .b = b }; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Constructor Hygiene - Exempts a non-pub init used only from test blocks

test "analyzeContent exempts a test-only fixture builder but keeps a used one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The reported case: a fixture builder that fills a board array. Renaming it
    // to `setupBoard` was a rename for the checker's benefit, not the reader's.
    const fixture =
        \\const Board = struct {
        \\    cells: [9]u8,
        \\    fn init() Board { var b: Board = undefined; for (&b.cells) |*c| { c.* = 0; } return b; }
        \\};
        \\test "board starts empty" {
        \\    const b = Board.init();
        \\    try std.testing.expectEqual(@as(u8, 0), b.cells[0]);
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), (try analyzeContent(a, "src/x.zig", fixture)).len);

    // The same builder used by production code is a real constructor again.
    const used = fixture ++
        \\
        \\fn newGame() Board { return Board.init(); }
    ;
    try std.testing.expectEqual(@as(usize, 1), (try analyzeContent(a, "src/x.zig", used)).len);

    // And a `pub` init is always gated: any file in the tree can construct with it.
    const exported =
        \\pub fn init(items: []u32) Foo { for (items) |i| { _ = i; } return .{}; }
        \\test "unused here" { try std.testing.expect(true); }
    ;
    try std.testing.expectEqual(@as(usize, 1), (try analyzeContent(a, "src/x.zig", exported)).len);
}

test "analyzeContent ignores non-init fns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn process(x: u32) void { if (x > 0) return; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
