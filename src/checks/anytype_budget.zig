const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    max_per_file: u32,
    exclude: []const []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// True when `rel_path` matches any exclude pattern (a legitimate
/// variadic/formatting boundary exempt from the cap).
fn isExcluded(rel_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (walk.matchGlob(rel_path, p)) return true;
    }
    return false;
}

/// True for a `writer`/`w`/`*_writer` parameter name — the idiomatic Zig
/// generic format-target, which is polymorphism (many concrete Writer types)
/// rather than the untyped-generics smell the budget targets.
fn isWriterName(name: []const u8) bool {
    return std.mem.eql(u8, name, "w") or
        std.mem.eql(u8, name, "writer") or
        std.mem.endsWith(u8, name, "_writer");
}

/// Counts `anytype` parameter tokens in source, excluding writer-typed params
/// (`writer: anytype`). Tokenizer-based so it correctly skips strings/comments.
fn countAnytype(allocator: std.mem.Allocator, content: []const u8) u32 {
    const z = allocator.dupeZ(u8, content) catch return 0;
    var tok = std.zig.Tokenizer.init(z);
    var count: u32 = 0;
    var prev: std.zig.Token.Tag = .invalid;
    var name_before_colon: []const u8 = "";
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        // `<name> : anytype` — prev is the colon, name_before_colon the param.
        if (t.tag == .keyword_anytype and !(prev == .colon and isWriterName(name_before_colon))) {
            count += 1;
        }
        if (t.tag == .identifier) name_before_colon = z[t.loc.start..t.loc.end];
        // Keep the identifier alive across the single colon before `anytype`;
        // any other token resets it so only `ident : anytype` matches.
        if (t.tag != .identifier and t.tag != .colon) name_before_colon = "";
        prev = t.tag;
    }
    return count;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isExcluded(entry.rel_path, ctx.exclude)) return;
    const a = ctx.allocator;
    const count = countAnytype(a, entry.content);
    if (count > ctx.max_per_file) {
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: {d} `anytype` parameters (limit: {d})",
            .{ entry.rel_path, count, ctx.max_per_file },
        );
        try ctx.violations.append(a, msg);
    }
}

/// Entry point for the anytype-budget check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg;

    if (!cfg.anytype_budget.enabled) {
        ok("anytype budget skipped (disabled in config)", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .max_per_file = cfg.anytype_budget.max_per_file,
        .exclude = cfg.anytype_budget.exclude,
        .violations = &violations,
    };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("anytype budget within limit (max {d} per file)", .{ctx.max_per_file});
        return;
    }

    fail("anytype budget FAILED ({d} file(s) over limit)", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: replace anytype with comptime-typed generics where possible.\n", .{});
    return error.CheckFailed;
}

// spec: Anytype Budget - Caps anytype parameter count per file
test "countAnytype counts only the keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\pub fn one(args: anytype) void {}
        \\pub fn two(a: anytype, b: anytype) void {}
        \\const s = "anytype";
    ;
    // 3 anytype tokens total (1 + 2; string literal not counted)
    try std.testing.expectEqual(@as(u32, 3), countAnytype(a, content));
}

// spec: Anytype Budget - Excludes writer-typed anytype parameters
test "countAnytype skips writer-typed params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\pub fn a(w: anytype) void {}
        \\pub fn b(writer: anytype) void {}
        \\pub fn c(buf_writer: anytype) void {}
        \\pub fn d(x: anytype) void {}
    ;
    // 4 anytype params, 3 are writer-typed → only `x: anytype` counts.
    try std.testing.expectEqual(@as(u32, 1), countAnytype(a, content));
}

// spec: Anytype Budget - Skips files matching the exclude patterns
test "isExcluded matches files against the exclude patterns" {
    try std.testing.expect(isExcluded("src/reporter.zig", &.{"reporter.zig"}));
    try std.testing.expect(isExcluded("src/testing/golden_runner.zig", &.{"testing/golden_runner.zig"}));
    try std.testing.expect(!isExcluded("src/checks/spec.zig", &.{"reporter.zig"}));
    try std.testing.expect(!isExcluded("src/reporter.zig", &.{}));
}
