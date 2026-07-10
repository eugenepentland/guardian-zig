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

// Placeholder doc-comment bodies that pass presence but say nothing.
const placeholder_phrases = [_][]const u8{
    "TODO",
    "FIXME",
    "todo",
    "fixme",
    "fill in",
    "Fill in",
};

// Protocol/trivial method names exempt from the doc-comment *presence* rule by
// default: their contract is conventional (deinit frees, format writes, next
// advances an iterator, reset restores initial state), so a mandatory `///`
// there is boilerplate. A downstream project extends this via
// [doc_quality] exempt_names; the doc *quality* rule still applies when a doc
// is present.
const default_exempt_names = [_][]const u8{ "deinit", "format", "next", "reset" };

/// True when `name` is in the compiled protocol defaults or the caller's extra
/// exempt list — i.e. the presence rule should not fire for this decl.
fn isPresenceExempt(name: []const u8, extra: []const []const u8) bool {
    for (default_exempt_names) |n| if (std.mem.eql(u8, name, n)) return true;
    for (extra) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    // Quality sub-check config (min_chars, enabled). Presence is always
    // enforced; the empty/placeholder/too-short verdicts only apply when
    // `enabled` is true (folded in from the former doc-quality check).
    cfg: config_mod.DocQualityCfg,
};

const Verdict = enum { ok, empty, placeholder, too_short };

fn judge(doc_text: ?[]const u8, min_chars: u32) Verdict {
    const text = doc_text orelse return .ok;
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return .empty;
    // Placeholder check first so messages stay specific; otherwise fall back
    // to the non-whitespace length verdict.
    return if (isPlaceholder(trimmed)) .placeholder else lengthVerdict(trimmed, min_chars);
}

fn isPlaceholder(trimmed: []const u8) bool {
    for (placeholder_phrases) |phr| {
        if (std.ascii.eqlIgnoreCase(trimmed, phr)) return true;
    }
    return false;
}

fn lengthVerdict(trimmed: []const u8, min_chars: u32) Verdict {
    var count: u32 = 0;
    for (trimmed) |c| {
        if (!std.ascii.isWhitespace(c)) count += 1;
    }
    return if (count < min_chars) .too_short else .ok;
}

/// The single per-decl issue phrase (or null when the decl is fine): missing
/// presence fails unless `name` is exempt; the quality verdicts apply only
/// when enabled and are never suppressed by the presence exemption.
fn declIssue(name: []const u8, has_doc: bool, doc_text: ?[]const u8, cfg: config_mod.DocQualityCfg) ?[]const u8 {
    if (!has_doc) return if (isPresenceExempt(name, cfg.exempt_names)) null else "has no /// doc comment";
    if (!cfg.enabled) return null;
    return switch (judge(doc_text, cfg.min_chars)) {
        .ok => null,
        .empty => "doc comment is empty",
        .placeholder => "doc comment is a placeholder phrase",
        .too_short => "doc comment is shorter than the minimum",
    };
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        const issue = declIssue(f.name, f.has_doc_comment, f.doc_text, ctx.cfg) orelse continue;
        const msg = try std.fmt.allocPrint(a, "{s}: pub fn {s}: {s}", .{ entry.rel_path, f.name, issue });
        try ctx.violations.append(a, msg);
    }

    const consts = if (entry.tree) |t| try ast.pubConstsFromTree(a, t) else try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        switch (c.kind) {
            .struct_, .enum_, .union_, .opaque_ => {},
            else => continue,
        }
        const issue = declIssue(c.name, c.has_doc_comment, c.doc_text, ctx.cfg) orelse continue;
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: pub const {s} ({s}): {s}",
            .{ entry.rel_path, c.name, @tagName(c.kind), issue },
        );
        try ctx.violations.append(a, msg);
    }
}

/// Pure-function entry: scans `content` with the given quality config and
/// returns violation lines (allocator-owned). Empty slice = pass. Used by the
/// golden-file test harness.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
    cfg: config_mod.DocQualityCfg,
) std.mem.Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };
    const z = try allocator.dupeZ(u8, content);
    try visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = z });
    return violations.toOwnedSlice(allocator);
}

/// Entry point for the doc-comments check (presence + quality).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.doc_quality;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all public declarations have real doc comments", .{});
        return;
    }

    fail("doc comments FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    print("  fix: add a real /// doc comment above each public declaration " ++
        "(>= {d} non-whitespace chars, no TODO/FIXME).\n", .{cfg.min_chars});
    return error.CheckFailed;
}

// spec: Doc Comments - Requires /// on every pub fn
// spec: Doc Comments - Requires /// on every pub struct/enum/union/opaque
// spec: Doc Comments - Rejects empty or stub doc comments on public declarations

test "judge classifies doc bodies" {
    try std.testing.expectEqual(Verdict.ok, judge("Computes x times y and returns it.", 12));
    try std.testing.expectEqual(Verdict.empty, judge("   \n  \t", 12));
    try std.testing.expectEqual(Verdict.placeholder, judge("TODO", 12));
    try std.testing.expectEqual(Verdict.too_short, judge("hi", 12));
}

// spec: Doc Comments - Exempts protocol and trivial method names from the presence requirement
test "presence exemption spares protocol names but quality still applies" {
    // Undocumented protocol names are exempt from the presence rule; a real
    // name still fails; a present-but-too-short doc still fails on quality.
    const cfg: config_mod.DocQualityCfg = .{ .enabled = true, .min_chars = 12 };
    try std.testing.expect(declIssue("deinit", false, null, cfg) == null);
    try std.testing.expect(declIssue("next", false, null, cfg) == null);
    try std.testing.expect(declIssue("compute", false, null, cfg) != null);
    // A documented `deinit` with a too-short body still trips the quality rule.
    try std.testing.expect(declIssue("deinit", true, "x", cfg) != null);
    // An extra configured exempt name is honored.
    const with_extra: config_mod.DocQualityCfg = .{ .enabled = true, .exempt_names = &.{"drain"} };
    try std.testing.expect(declIssue("drain", false, null, with_extra) == null);
}

test "visit flags missing doc comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    // Quality off so this isolates the presence rule.
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations, .cfg = .{ .enabled = false } };
    const content =
        \\/// Documented.
        \\pub fn doc_fn() void {}
        \\
        \\pub fn nodoc_fn() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit flags missing doc comment on pub struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations, .cfg = .{} };
    const content =
        \\pub const X = struct { x: i32 };
        \\pub const Y = 42;
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    // X has no /// → flag. Y is a value, exempt.
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit flags empty and placeholder doc on documented decls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations, .cfg = .{ .enabled = true, .min_chars = 12 } };
    const content =
        \\///
        \\pub fn empty() void {}
        \\/// Adds two integers and returns the sum value.
        \\pub fn add(x: i32, y: i32) i32 { return x + y; }
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "quality verdicts are skipped when disabled but presence still enforced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations, .cfg = .{ .enabled = false, .min_chars = 12 } };
    const content =
        \\/// hi
        \\pub fn shortDoc() void {}
        \\pub fn noDoc() void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    // shortDoc passes (quality off); noDoc still flagged (presence always on).
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

// ── Golden file scenarios ──────────────────────────────────────────────

const golden = @import("../testing/golden_runner.zig");

test "golden: empty-and-placeholder" {
    try golden.runWithCfg(std.testing.allocator, .{
        .check_name = "doc-comments",
        .name = "empty-and-placeholder",
        .input = @embedFile("../testing/golden/doc-comments/empty-and-placeholder/input.zig.in"),
        .expected = @embedFile("../testing/golden/doc-comments/empty-and-placeholder/expected.txt"),
        .expected_path = "src/testing/golden/doc-comments/empty-and-placeholder/expected.txt",
    }, analyzeContent, config_mod.DocQualityCfg{ .enabled = true, .min_chars = 12 });
}

test "golden: all-good" {
    try golden.runWithCfg(std.testing.allocator, .{
        .check_name = "doc-comments",
        .name = "all-good",
        .input = @embedFile("../testing/golden/doc-comments/all-good/input.zig.in"),
        .expected = @embedFile("../testing/golden/doc-comments/all-good/expected.txt"),
        .expected_path = "src/testing/golden/doc-comments/all-good/expected.txt",
    }, analyzeContent, config_mod.DocQualityCfg{ .enabled = true, .min_chars = 12 });
}
