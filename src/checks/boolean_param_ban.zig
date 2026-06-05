const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Tier 2 Anti-patterns - Rejects bool parameters in public functions

// Guardian's reporter.init(quiet), snapshot_helper.lifecycle(force_update),
// and baseline.lifecycle(force_refresh) take bool params. Refactor to enums
// is queued separately. Downstream consumers should leave this empty.
const allowed_paths = [_][]const u8{
    "src/reporter.zig",
    "src/snapshot_helper.zig",
    "src/baseline.zig",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for `pub fn` declarations whose
/// parameter list contains a `bool` parameter.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
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
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    var saw_pub = false;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_pub => saw_pub = true,
            .keyword_fn => {
                if (saw_pub) try checkParams(ctx, &tok, z, t.loc.start);
                saw_pub = false;
            },
            else => {
                if (t.tag != .doc_comment and t.tag != .container_doc_comment) saw_pub = false;
            },
        }
    }
}

fn checkParams(ctx: *ScanCtx, tok: *std.zig.Tokenizer, z: []const u8, fn_byte: usize) Allocator.Error!void {
    var saw_lparen = false;
    var depth: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return;
        if (!saw_lparen) {
            if (t.tag == .l_paren) {
                saw_lparen = true;
                depth = 1;
            }
            continue;
        }
        switch (t.tag) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return;
            },
            .identifier => {
                if (depth != 1) continue;
                const text = z[t.loc.start..t.loc.end];
                if (std.mem.eql(u8, text, "bool")) {
                    const line = lineOf(z, fn_byte);
                    const msg = try std.fmt.allocPrint(
                        ctx.allocator,
                        "{s}:{d}: pub fn has a `bool` parameter (replace with two named methods or an enum)",
                        .{ ctx.rel_path, line },
                    );
                    try ctx.violations.append(ctx.allocator, msg);
                    return;
                }
            },
            else => {},
        }
    }
}

fn lineOf(source: []const u8, byte_offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < byte_offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    for (allowed_paths) |pat| {
        if (walk.matchGlob(entry.rel_path, pat)) return;
    }
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the boolean-param-ban check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("boolean-param-ban: no bool parameters in pub fns", .{});
        return;
    }
    reporter.fail("boolean-param-ban FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: split into two named entry points, or introduce an enum that encodes intent.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags bool param in pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn render(verbose: bool) void { _ = verbose; }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows enum param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub fn render(mode: Mode) void { _ = mode; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores private fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn render(verbose: bool) void { _ = verbose; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
