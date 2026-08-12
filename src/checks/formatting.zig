//! Formatting gate: every `src/` file must already be what `zig fmt` would
//! write. It is by far the cheapest check in the suite (one parse + render per
//! file, no cross-file analysis), so the runner runs it FIRST and flushes its
//! output before the expensive gates start — a hand-edited file that lost its
//! indentation is reported in the first seconds instead of after a full run.
//!
//! The message names the first line that differs and prints the exact fix
//! command (`zig fmt <file>`); `zig fmt --check` names only the file, which was
//! the reported friction. A file with a syntax error is skipped: it cannot be
//! rendered, and the compiler already reports it far better than a gate can.

const std = @import("std");
const Allocator = std.mem.Allocator;
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const types = @import("../cli/types.zig");

/// Registry name, shared with the runner that schedules this check first.
pub const check_name = "formatting";

/// 1-indexed line at which `formatted` first differs from `source`, or null
/// when the two are byte-identical (the file is already canonical). A pure
/// prefix that then ends early reports the line the truncation happens on, so
/// a missing trailing newline still points somewhere useful.
pub fn firstDifferingLine(source: []const u8, formatted: []const u8) ?u32 {
    const shared = @min(source.len, formatted.len);
    var line: u32 = 1;
    var i: usize = 0;
    while (i < shared) : (i += 1) {
        if (source[i] != formatted[i]) return line;
        if (source[i] == '\n') line += 1;
    }
    if (source.len == formatted.len) return null;
    return line;
}

/// The formatting finding for one file, or null when it already matches
/// `zig fmt` (or cannot be parsed, which is the compiler's to report).
fn fileViolation(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error!?reporter.Violation {
    var tree = try std.zig.Ast.parse(allocator, content, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len > 0) return null;
    const formatted = try tree.renderAlloc(allocator);
    const line = firstDifferingLine(content, formatted) orelse return null;
    return .{
        .check = check_name,
        .file = rel_path,
        .line = line,
        .message = "non-conforming formatting (first difference on this line)",
        .fix_hint = try std.fmt.allocPrint(allocator, "zig fmt {s}", .{rel_path}),
        // Keyed on the file: rewording the message must not re-key a consumer's
        // baseline, and one file is one finding.
        .identity = rel_path,
    };
}

const ScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList(reporter.Violation),
};

fn visitFile(raw_ctx: *anyopaque, entry: walk.FileEntry) walk.VisitError!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const v = try fileViolation(ctx.allocator, entry.rel_path, entry.content) orelse return;
    try ctx.violations.append(ctx.allocator, v);
}

/// Entry point for the formatting check: walks `src/` (honoring the config
/// `exclude` globs) and fails when any file differs from `zig fmt` output.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var scan: ScanCtx = .{ .allocator = ctx.allocator, .violations = &violations };
    const src = try std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.project_dir});
    try walk.walkZigFiles(
        ctx.allocator,
        src,
        .{ .display_root = "src", .excludes = ctx.cfg.exclude },
        .{ .ctx = &scan, .visit = visitFile },
    );

    if (violations.items.len == 0) {
        reporter.ok("formatting: every source file matches zig fmt", .{});
        return;
    }
    reporter.fail("formatting FAILED ({d} file(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    reporter.detail(
        "  fix: run the `zig fmt` command shown above for each file, then re-run — " ++
            "formatting is checked before the expensive gates so this costs seconds, not a full run\n",
        .{},
    );
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Formatting - Reports the first line where a file diverges from zig fmt output

test "firstDifferingLine points at the first divergent line" {
    // Identical content is canonical: no finding.
    try std.testing.expect(firstDifferingLine("const a = 1;\n", "const a = 1;\n") == null);
    // The divergence is on the third line, and that is the line reported —
    // `zig fmt --check` names only the file, which is the friction this fixes.
    const source = "const a = 1;\nconst b = 2;\nconst  c = 3;\n";
    const formatted = "const a = 1;\nconst b = 2;\nconst c = 3;\n";
    try std.testing.expectEqual(@as(u32, 3), firstDifferingLine(source, formatted).?);
    // A missing trailing newline still resolves to a line number.
    try std.testing.expectEqual(@as(u32, 2), firstDifferingLine("a\nb", "a\nb\n").?);
}

// spec: Formatting - Names the file and the exact zig fmt command that fixes it

test "a misformatted file yields one violation carrying its zig fmt command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Canonical source produces no finding at all.
    const clean: [:0]const u8 = "const std = @import(\"std\");\n";
    try std.testing.expect(try fileViolation(a, "src/clean.zig", clean) == null);

    // A file zig fmt would rewrite reports its file:line plus the fix command.
    const messy: [:0]const u8 = "const std   =    @import(\"std\");\n";
    const v = (try fileViolation(a, "src/messy.zig", messy)).?;
    try std.testing.expectEqualStrings("src/messy.zig", v.file.?);
    try std.testing.expectEqual(@as(u32, 1), v.line.?);
    try std.testing.expectEqualStrings("zig fmt src/messy.zig", v.fix_hint.?);

    // A file that does not parse is the compiler's to report, not this gate's.
    const broken: [:0]const u8 = "const std = @import(\n";
    try std.testing.expect(try fileViolation(a, "src/broken.zig", broken) == null);
}
