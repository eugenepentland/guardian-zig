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
    violations: *std.ArrayList([]const u8),
};

/// True when `rel_path` matches any exclude pattern (a legitimate
/// variadic/formatting boundary exempt from the cap).
fn isExcluded(rel_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (walk.matchGlob(rel_path, p)) return true;
    }
    return false;
}

// Exact format-target param names (case-insensitive) — the idiomatic Zig
// generic sinks. The old list matched only `writer`/`w`/`*_writer`, so a
// codebase using `out`/`stream`/`sink` (or a camelCase `htmlWriter`) still
// tripped the budget despite writing to a format target; these broaden it.
const writer_names = [_][]const u8{ "writer", "w", "out", "out_stream", "stream", "sink" };

/// True for a generic format-target parameter name — an exact match against
/// the known sink names, or any name ending in `writer` (case-insensitive, so
/// `html_writer`, `htmlWriter`, and `bufWriter` all qualify). Such params are
/// polymorphism over concrete Writer types, not the untyped-generics smell the
/// budget targets.
fn isWriterName(name: []const u8) bool {
    for (writer_names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return endsWithIgnoreCase(name, "writer");
}

/// Case-insensitive `endsWith`.
fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

/// Counts `anytype` parameter tokens in a pre-parsed tree, excluding
/// writer-typed params (`writer: anytype`). Iterates the shared token stream;
/// only identifiers need their text, so `tokenSlice` is called only for those.
fn countAnytypeTree(tree: *const std.zig.Ast) u32 {
    const tags = tree.tokens.items(.tag);
    var count: u32 = 0;
    var prev: std.zig.Token.Tag = .invalid;
    var name_before_colon: []const u8 = "";
    for (tags, 0..) |tag, i| {
        if (tag == .eof) break;
        // `<name> : anytype` — prev is the colon, name_before_colon the param.
        if (tag == .keyword_anytype and !(prev == .colon and isWriterName(name_before_colon))) {
            count += 1;
        }
        if (tag == .identifier) name_before_colon = tree.tokenSlice(@intCast(i));
        // Keep the identifier alive across the single colon before `anytype`;
        // any other token resets it so only `ident : anytype` matches.
        if (tag != .identifier and tag != .colon) name_before_colon = "";
        prev = tag;
    }
    return count;
}

/// Content entry (tests / standalone with no shared tree): parse once, count.
fn countAnytype(allocator: std.mem.Allocator, content: [:0]const u8) std.mem.Allocator.Error!u32 {
    // Propagate OOM: a zero count on allocation failure would let anytype params
    // slip past the per-file cap.
    var tree = try std.zig.Ast.parse(allocator, content, .{});
    return countAnytypeTree(&tree);
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isExcluded(entry.rel_path, ctx.exclude)) return;
    const a = ctx.allocator;
    const count = if (entry.tree) |t| countAnytypeTree(t) else try countAnytype(a, entry.content);
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

    var violations: std.ArrayList([]const u8) = .empty;
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
    try std.testing.expectEqual(@as(u32, 3), try countAnytype(a, content));
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
    try std.testing.expectEqual(@as(u32, 1), try countAnytype(a, content));

    // The broadened format-target idiom: exact sink names plus a
    // case-insensitive `writer` suffix. None of these count.
    const sinks =
        \\pub fn render0(w: anytype) void {}
        \\pub fn render1(out: anytype) void {}
        \\pub fn render2(stream: anytype) void {}
        \\pub fn render3(sink: anytype) void {}
        \\pub fn render4(out_stream: anytype) void {}
        \\pub fn render5(html_writer: anytype) void {}
        \\pub fn render6(htmlWriter: anytype) void {}
    ;
    try std.testing.expectEqual(@as(u32, 0), try countAnytype(a, sinks));
}

// spec: Anytype Budget - Skips files matching the exclude patterns
test "isExcluded matches files against the exclude patterns" {
    try std.testing.expect(isExcluded("src/reporter.zig", &.{"reporter.zig"}));
    try std.testing.expect(isExcluded("src/testing/golden_runner.zig", &.{"testing/golden_runner.zig"}));
    try std.testing.expect(!isExcluded("src/checks/spec.zig", &.{"reporter.zig"}));
    try std.testing.expect(!isExcluded("src/reporter.zig", &.{}));
}
