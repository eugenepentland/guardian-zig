const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const min_occurrences: u32 = 3;
// Length threshold tuned above 7 chars to skip common short identifiers
// ("init", "time", "enabled") that happen to recur as token literals in
// rule definitions or TOML keys without representing duplicated knowledge.
const min_length: usize = 8;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for string literals that occur
/// `min_occurrences` or more times within a single file.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try a.dupeZ(u8, content);

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(a);

    var tok = std.zig.Tokenizer.init(z);
    var depth: u32 = 0;
    var in_test = false;
    var test_depth: u32 = 0;
    var pending_test = false;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_test => pending_test = true,
            .l_brace => {
                depth += 1;
                if (pending_test) {
                    in_test = true;
                    test_depth = depth;
                    pending_test = false;
                }
            },
            .r_brace => {
                if (depth > 0) depth -= 1;
                if (in_test and depth < test_depth) in_test = false;
            },
            .string_literal => {
                if (in_test) continue;
                const raw = z[t.loc.start..t.loc.end];
                if (raw.len < min_length + 2) continue;
                const inner = raw[1 .. raw.len - 1];
                if (inner.len < min_length) continue;
                const gop = try counts.getOrPut(a, inner);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            },
            else => {},
        }
    }

    var iter = counts.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.* < min_occurrences) continue;
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}: string literal {s} appears {d} times — extract a const",
            .{ rel_path, e.key_ptr.*, e.value_ptr.* },
        );
        try violations.append(allocator, msg);
    }
    return violations.toOwnedSlice(allocator);
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeContent(ctx.allocator, entry.rel_path, entry.content);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the repeated-string-literal check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    _ = &@as(ScanCtx, undefined);
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("repeated-string-literal: no string literal appears 3+ times in a file", .{});
        return;
    }
    reporter.fail("repeated-string-literal FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: extract the literal to a file-scope `const NAME = \"...\";`.\n", .{});
    return error.CheckFailed;
}

// spec: Tier 2 Anti-patterns - Rejects identical string literals appearing 3 or more times in a single file

test "analyzeContent flags 3 copies of the same literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn a() []const u8 { return "/etc/something"; }
        \\fn b() []const u8 { return "/etc/something"; }
        \\fn c() []const u8 { return "/etc/something"; }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows 2 copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn a() []const u8 { return "abcd"; }
        \\fn b() []const u8 { return "abcd"; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
