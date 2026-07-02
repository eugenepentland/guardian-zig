const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const config_mod = @import("../config.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Doc Quality - Rejects empty or stub doc comments on public declarations

const placeholder_phrases = [_][]const u8{
    "TODO",
    "FIXME",
    "todo",
    "fixme",
    "fill in",
    "Fill in",
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    cfg: config_mod.DocQualityCfg,
};

const Verdict = enum { ok, empty, placeholder, too_short };

fn judge(doc_text: ?[]const u8, min_chars: u32) Verdict {
    const text = doc_text orelse return .ok;
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return .empty;

    // Placeholder check applies first so messages stay specific.
    for (placeholder_phrases) |phr| {
        if (std.ascii.eqlIgnoreCase(trimmed, phr)) return .placeholder;
    }

    // Count non-whitespace chars.
    var count: u32 = 0;
    for (trimmed) |c| {
        if (!std.ascii.isWhitespace(c)) count += 1;
    }
    if (count < min_chars) return .too_short;
    return .ok;
}

fn verdictLabel(v: Verdict) []const u8 {
    return switch (v) {
        .ok => "",
        .empty => "doc comment is empty",
        .placeholder => "doc comment is a placeholder phrase",
        .too_short => "doc comment is shorter than the minimum",
    };
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        if (!f.has_doc_comment) continue;
        const v = judge(f.doc_text, ctx.cfg.min_chars);
        if (v == .ok) continue;
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: pub fn {s}: {s}",
            .{ entry.rel_path, f.name, verdictLabel(v) },
        );
        try ctx.violations.append(a, msg);
    }

    const consts = if (entry.tree) |t| try ast.pubConstsFromTree(a, t) else try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        switch (c.kind) {
            .struct_, .enum_, .union_, .opaque_ => {},
            else => continue,
        }
        if (!c.has_doc_comment) continue;
        const v = judge(c.doc_text, ctx.cfg.min_chars);
        if (v == .ok) continue;
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: pub const {s} ({s}): {s}",
            .{ entry.rel_path, c.name, @tagName(c.kind), verdictLabel(v) },
        );
        try ctx.violations.append(a, msg);
    }
}

/// Pure-function entry: scans `content` with the given config and
/// returns violation lines (allocator-owned). Empty slice = pass. Used
/// by the golden-file test harness.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
    cfg: config_mod.DocQualityCfg,
) std.mem.Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };
    // Test-harness entry (production walks via the shared index); terminate the
    // borrowed content so it fits FileEntry's [:0]const u8 contract.
    const z = try allocator.dupeZ(u8, content);
    visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = z }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return violations.toOwnedSlice(allocator);
}

/// Entry point for the doc-quality check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.doc_quality;

    if (!cfg.enabled) {
        ok("doc-quality disabled by config", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("doc comments meet quality bar (min_chars={d})", .{cfg.min_chars});
        return;
    }

    fail("doc quality FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: rewrite the /// comment with a real one-line description (>= {d} non-whitespace chars).\n", .{cfg.min_chars});
    return error.CheckFailed;
}

test "judge passes ok docs" {
    try std.testing.expectEqual(Verdict.ok, judge("Computes the result of x times y.", 12));
}

test "judge flags empty" {
    try std.testing.expectEqual(Verdict.empty, judge("", 12));
    try std.testing.expectEqual(Verdict.empty, judge("   \n  \t", 12));
}

test "judge flags placeholders" {
    try std.testing.expectEqual(Verdict.placeholder, judge("TODO", 12));
    try std.testing.expectEqual(Verdict.placeholder, judge("fixme", 12));
    try std.testing.expectEqual(Verdict.placeholder, judge("Fill in", 12));
}

test "judge flags too short" {
    try std.testing.expectEqual(Verdict.too_short, judge("hi", 12));
    try std.testing.expectEqual(Verdict.too_short, judge("a b c", 12)); // 3 non-ws chars
}

test "judge respects min_chars knob" {
    try std.testing.expectEqual(Verdict.ok, judge("hi", 2));
    try std.testing.expectEqual(Verdict.too_short, judge("hi there", 9));
}

test "visit flags empty doc on pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .min_chars = 12 },
    };
    const content =
        \\///
        \\pub fn empty() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows good docs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .min_chars = 12 },
    };
    const content =
        \\/// Adds two integers and returns the sum.
        \\pub fn add(x: i32, y: i32) i32 { return x + y; }
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

// ── Golden file scenarios ──────────────────────────────────────────────

const golden = @import("../testing/golden_runner.zig");

test "golden: empty-and-placeholder" {
    try golden.runWithCfg(std.testing.allocator, .{
        .check_name = "doc-quality",
        .name = "empty-and-placeholder",
        .input = @embedFile("../testing/golden/doc-quality/empty-and-placeholder/input.zig.in"),
        .expected = @embedFile("../testing/golden/doc-quality/empty-and-placeholder/expected.txt"),
        .expected_path = "src/testing/golden/doc-quality/empty-and-placeholder/expected.txt",
    }, analyzeContent, config_mod.DocQualityCfg{ .enabled = true, .min_chars = 12 });
}

test "golden: all-good" {
    try golden.runWithCfg(std.testing.allocator, .{
        .check_name = "doc-quality",
        .name = "all-good",
        .input = @embedFile("../testing/golden/doc-quality/all-good/input.zig.in"),
        .expected = @embedFile("../testing/golden/doc-quality/all-good/expected.txt"),
        .expected_path = "src/testing/golden/doc-quality/all-good/expected.txt",
    }, analyzeContent, config_mod.DocQualityCfg{ .enabled = true, .min_chars = 12 });
}

test "visit ignores undocumented decls (doc-comments enforces presence)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .min_chars = 12 },
    };
    const content =
        \\pub fn nodoc() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
