const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// Architectural defaults: mutable globals live in main/wiring. Guardian's own
// reporter singleton (a `threadlocal var`) is exempted via [[allow]] in
// Guardian's guardian.toml. zig-core's 400k-LOC library core has ~zero
// file-scope `var`s — they exist only in main.zig as process-lifetime
// singletons — so this default holds any global mutable state to the entry/
// wiring layer.
const allowed_paths = [_][]const u8{
    "src/main*",
    "src/wiring*",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayList([]const u8),
};

/// Pure-function entry: scans `content` for mutable global `var` declarations —
/// every file-scope `var` (pub or not, `threadlocal` included) plus any `pub
/// var` at container scope. Function-local `var`s are ignored; a struct-scope
/// non-pub container `var` is out of scope (see `scan`).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    for (allowed_paths) |pat| {
        if (walk.matchGlob(rel_path, pat)) return violations.toOwnedSlice(allocator);
    }
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const z = try ctx.allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var saw_pub = false;
    var in_test = false;
    var depth: u32 = 0;
    var test_depth: u32 = 0;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;

        switch (t.tag) {
            .keyword_test => {
                in_test = true;
                test_depth = depth + 1;
            },
            .l_brace => depth += 1,
            .r_brace => {
                if (depth > 0) depth -= 1;
                if (in_test and depth < test_depth) in_test = false;
            },
            .keyword_pub => saw_pub = true,
            .keyword_var => {
                // Flag a mutable global: any file-scope `var` (depth 0 — pub or
                // not, `threadlocal` included) or any `pub var` at container
                // scope. A function-local `var` (depth > 0, no `pub`) is fine. A
                // struct-scope non-pub container `var` is out of scope: telling
                // it apart from a fn-local needs brace-kind tracking, it's rare,
                // and zig-core has ~zero of it — file-scope is the S9 target.
                if (!in_test and (saw_pub or depth == 0)) try report(ctx, z, t.loc.start);
                saw_pub = false;
            },
            .keyword_const, .keyword_fn => saw_pub = false,
            else => {},
        }
    }
}

fn report(ctx: *ScanCtx, z: []const u8, byte: usize) Allocator.Error!void {
    const line = lineOf(z, byte);
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: mutable global var outside wiring/main",
        .{ ctx.rel_path, line },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
    extra_allowed: []const []const u8 = &.{},
};

/// True if `rel_path` matches a compiled architectural default or a configured
/// [[allow]] path for this check.
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (allowed_paths) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.extra_allowed)) return;
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the ban-globals check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .extra_allowed = ctx.cfg.extraAllowed("ban-globals"),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("ban-globals: no mutable global var declarations outside wiring/main", .{});
        return;
    }
    reporter.fail("ban-globals FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: scope mutable state to a struct field, or move to wiring/main.\n", .{});
    return error.CheckFailed;
}

// spec: Hidden Dependency Bans - Rejects mutable pub var globals outside wiring/main

test "analyzeContent flags pub var at file scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub var counter: u32 = 0;
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows pub const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Limit: u32 = 100;
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows pub var in main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/main.zig",
        \\pub var registry: Registry = .{};
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows pub var inside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "x" { pub var local: u32 = 0; _ = local; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Hidden Dependency Bans - Rejects non-pub file-scope var globals outside wiring/main

test "analyzeContent flags a non-pub file-scope var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\var local_state: u32 = 0;
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags a threadlocal file-scope var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\threadlocal var counter: u32 = 0;
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent ignores a function-local var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A `var` inside a fn body (depth > 0, no pub) is a local, not a global.
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn f() void {
        \\    var local: u32 = 0;
        \\    _ = &local;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
