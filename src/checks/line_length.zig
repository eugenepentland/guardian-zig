//! Two-tier source-line length guidance: ordinary readability findings warn,
//! while only extreme lines retain a blocking upper bound.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

/// Pure-function entry: scans `content` for any line whose codepoint
/// length exceeds `max_len`.
pub fn analyzeContentWithLimit(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    max_len: u32,
) Allocator.Error![]const []const u8 {
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    try scanLines(
        allocator,
        rel_path,
        content,
        .{ .warning = max_len, .hard = max_len },
        .{ .warnings = &warnings, .violations = &violations },
    );
    return reporter.flatLines(allocator, violations.items);
}

/// Structured scan: one Violation per over-limit line. The per-line human
/// message is unchanged; each record carries the file as its `ratchet_key` so
/// item 5 can derive a per-file over-limit count, and the line's length as the
/// metric.
fn scanLines(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    limits: Limits,
    findings: FindingLists,
) Allocator.Error!void {
    var line_num: u32 = 1;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| : (line_num += 1) {
        const trimmed = std.mem.trimStart(u8, line, &std.ascii.whitespace);
        // A multiline-string (`\\...`) line is emitted verbatim — its length is
        // template data (HTML/SVG/KiCad), not code, and it cannot be wrapped
        // without changing the output bytes. Skip it.
        if (std.mem.startsWith(u8, trimmed, "\\\\")) continue;
        // A `// spec:` / `// spec-case:` tag mirrors a SPEC.md bullet
        // verbatim — its length is dictated by the spec text, not code style,
        // and the tag matcher needs it on one line. Capping it would force
        // rewording the spec to satisfy a source-column rule. Skip it.
        if (std.mem.startsWith(u8, trimmed, "// spec:") or
            std.mem.startsWith(u8, trimmed, "// spec-case:")) continue;
        const codepoint_len = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (codepoint_len > limits.warning) {
            const is_hard = codepoint_len > limits.hard;
            const destination = if (is_hard) findings.violations else findings.warnings;
            const message = if (is_hard)
                try std.fmt.allocPrint(allocator, "line is {d} chars (hard limit {d})", .{
                    codepoint_len,
                    limits.hard,
                })
            else
                try std.fmt.allocPrint(
                    allocator,
                    "line is {d} chars (recommended {d}; hard limit {d})",
                    .{ codepoint_len, limits.warning, limits.hard },
                );
            try destination.append(allocator, .{
                .check = "line-length",
                .file = rel_path,
                .line = line_num,
                .message = message,
                .fix_hint = if (is_hard) null else "split the expression when doing so improves readability",
                .ratchet_key = try allocator.dupe(u8, rel_path),
                .metric = codepoint_len,
            });
        }
    }
}

const Limits = struct { warning: u32, hard: u32 };
const FindingLists = struct {
    warnings: *std.ArrayList(reporter.Violation),
    violations: *std.ArrayList(reporter.Violation),
};

/// Pure-function entry using the framework default (120) for tests.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    return analyzeContentWithLimit(allocator, rel_path, content, 120);
}

const FileScanCtx = struct {
    allocator: Allocator,
    warnings: *std.ArrayList(reporter.Violation),
    violations: *std.ArrayList(reporter.Violation),
    warning_limit: u32,
    hard_limit: u32,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    try scanLines(
        ctx.allocator,
        entry.rel_path,
        entry.content,
        .{ .warning = ctx.warning_limit, .hard = ctx.hard_limit },
        .{ .warnings = ctx.warnings, .violations = ctx.violations },
    );
}

/// Entry point for the line-length check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const warning_limit = ctx.cfg.line_length.max_len;
    const hard_limit = ctx.cfg.line_length.hard_max_len;
    if (!ctx.cfg.line_length.enabled) {
        reporter.ok("line-length disabled by config", .{});
        return;
    }
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .warnings = &warnings,
        .violations = &violations,
        .warning_limit = warning_limit,
        .hard_limit = hard_limit,
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    for (warnings.items) |warning| reporter.warn(warning);
    if (violations.items.len == 0 and warnings.items.len == 0) {
        reporter.ok("line-length: every line is <= {d} recommended chars", .{warning_limit});
        return;
    }
    if (violations.items.len == 0) return;
    reporter.fail("line-length FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: split long expressions; introduce intermediate names.\n", .{});
    return error.CheckFailed;
}

// spec: Tier 2 Anti-patterns - Warns on long source lines and fails only above a configurable hard length

test "analyzeContent flags overlong line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [200]u8 = undefined;
    @memset(&buf, 'x');
    const out = try analyzeContent(arena.allocator(), "src/x.zig", buf[0..150]);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContentWithLimit honors a custom cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [200]u8 = undefined;
    @memset(&buf, 'x');
    // 50 chars: under the default 120, but over a tightened cap of 40.
    const out = try analyzeContentWithLimit(arena.allocator(), "src/x.zig", buf[0..50], 40);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "scanLines separates warnings from hard failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    const short: [50]u8 = @splat('x');
    const long: [90]u8 = @splat('x');
    const content = short ++ "\n" ++ long;
    try scanLines(
        a,
        "src/x.zig",
        content,
        .{ .warning = 40, .hard = 80 },
        .{ .warnings = &warnings, .violations = &violations },
    );
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "analyzeContent allows short lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const x = 1;
        \\const y = 2;
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Tier 2 Anti-patterns - Exempts spec tag comment lines from the length cap
test "analyzeContent skips overlong spec tag lines but caps ordinary comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pad: [130]u8 = @splat('x');
    // Spec tags (plain and spec-case, any indentation) are exempt; an
    // ordinary comment of the same length still trips the cap.
    const content = "// spec: Section - " ++ pad ++ "\n" ++
        "    // spec-case: Section - " ++ pad ++ "\n" ++
        "// ordinary comment " ++ pad ++ "\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "src/x.zig:3:") != null);
}

// spec: Tier 2 Anti-patterns - Skips multiline-string literal lines from the length cap
test "analyzeContent skips overlong multiline-string lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const long: [130]u8 = @splat('x');
    // A `\\`-prefixed template line over the cap; the code lines are short.
    const content = "const s =\n    \\\\" ++ long ++ "\n;\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
