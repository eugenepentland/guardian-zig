//! Two-tier source-file size guidance: warn on maintainability growth while
//! retaining a generous hard stop for genuinely extreme production modules.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const near_cap = @import("../near_cap.zig");
const hysteresis = @import("../hysteresis.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// This check's registry name, used for its own violation records and to ask
/// whether hysteresis binds it.
const check_name = "file-size";

/// What the alert line tells a file to do about its remaining runway.
const split_remedy = "split at a cohesive module boundary now";

/// What the metric counts, in the check's own words. Printed rather than
/// implied: an agent that believes comments count spends its trim budget
/// deleting them for zero movement.
const metric_definition = "non-blank, non-comment line outside test blocks";

const FileSizeCtx = struct {
    allocator: std.mem.Allocator,
    warning_limit: u32,
    hard_limit: u32,
    warnings: *std.ArrayList(reporter.Violation),
    violations: *std.ArrayList(reporter.Violation),
    /// What the pre-trip alert says a crossing would cost. `.unacceptable`
    /// when `[hysteresis]` binds this check — there is then no accept on the
    /// other side of the cap, only a shrink back to the recover line.
    crossing: near_cap.Crossing = .blocks,
};

/// True when `line` counts toward the metric: it carries something other than
/// whitespace, and it is not a whole-line comment.
///
/// Comments and blanks are excluded because counting them makes DELETING
/// EXPLANATION the cheapest way to buy headroom — four recorded sessions in one
/// week trimmed doc comments or merged readable lines to keep a file under its
/// ceiling. A gate that rewards removing the docs is worse than no gate.
///
/// The `//` test covers `///` and `//!` as well. Zig has no block comments, and
/// a multiline-string line opens with `\\`, so a string body can never be
/// mistaken for a comment.
fn isCodeLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    return !std.mem.startsWith(u8, trimmed, "//");
}

/// Code lines within `text`. A trailing newline yields a final empty segment,
/// which is not a code line — so an N-line file that `zig fmt` newline-
/// terminated measures N, never N+1.
fn codeLinesIn(text: []const u8) u32 {
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isCodeLine(line)) n += 1;
    }
    return n;
}

/// The whole source lines spanned by the byte range `[start, end]` — expanded
/// out to the enclosing line boundaries so a partially covered first/last line
/// is classified from its full text.
fn lineSpan(z: []const u8, start: usize, end: usize) []const u8 {
    const from = if (std.mem.lastIndexOfScalar(u8, z[0..start], '\n')) |i| i + 1 else 0;
    const to = std.mem.indexOfScalarPos(u8, z, end, '\n') orelse z.len;
    return z[from..to];
}

/// Running state for the test-block line scan.
const TestLineScan = struct {
    depth: u32 = 0,
    test_depth: u32 = 0,
    in_test: bool = false,
    pending: bool = false,
    start_byte: usize = 0,
    total: u32 = 0,
};

/// Number of CODE lines occupied by top-level `test {...}` blocks. The
/// file-size cap measures production code, so a heavily-tested module isn't
/// forced over the same limit as a genuine god-file by its own test suite
/// (audit: erc.zig was 62% test code). Counted with the same blank/comment rule
/// as the file total, so subtracting one from the other can never over- or
/// under-count a test block's own comments. Tokenizer skips strings/comments, so
/// a `test` word inside a literal never opens a phantom block.
fn testBlockLines(z: [:0]const u8) std.mem.Allocator.Error!u32 {
    var tok = std.zig.Tokenizer.init(z);
    var s: TestLineScan = .{};
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        stepTestScan(&s, t, z);
    }
    return s.total;
}

fn stepTestScan(s: *TestLineScan, t: std.zig.Token, z: [:0]const u8) void {
    switch (t.tag) {
        .keyword_test => {
            s.pending = true;
            s.start_byte = t.loc.start;
        },
        .l_brace => {
            s.depth += 1;
            if (s.pending) {
                s.in_test = true;
                s.test_depth = s.depth;
                s.pending = false;
            }
        },
        .r_brace => closeBrace(s, z, t.loc.start),
        else => {},
    }
}

fn closeBrace(s: *TestLineScan, z: [:0]const u8, byte: usize) void {
    if (s.in_test and s.depth == s.test_depth) {
        s.total += codeLinesIn(lineSpan(z, s.start_byte, byte));
        s.in_test = false;
    }
    if (s.depth > 0) s.depth -= 1;
}

/// Production code lines: non-blank, non-comment lines outside `test {...}`
/// blocks. Public so the `size` command and the debt report list the same
/// number this check gates on — a `grep -c` cannot reproduce it.
pub fn codeLines(content: [:0]const u8) std.mem.Allocator.Error!u32 {
    const total = codeLinesIn(content);
    const test_lines = try testBlockLines(content);
    return if (test_lines <= total) total - test_lines else total;
}

fn fileSizeVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileSizeCtx = @ptrCast(@alignCast(raw_ctx));
    const lines = try codeLines(entry.content);
    try noteNearHardCap(ctx, entry.rel_path, lines);
    if (lines <= ctx.warning_limit) return;
    const is_hard = lines > ctx.hard_limit;
    const destination = if (is_hard) ctx.violations else ctx.warnings;
    try destination.append(ctx.allocator, .{
        .check = check_name,
        .file = entry.rel_path,
        .message = if (is_hard)
            try std.fmt.allocPrint(ctx.allocator, "{d} code lines (hard limit: {d})", .{ lines, ctx.hard_limit })
        else
            try std.fmt.allocPrint(
                ctx.allocator,
                "{d} code lines (recommended: {d}; hard limit: {d})",
                .{ lines, ctx.warning_limit, ctx.hard_limit },
            ),
        .fix_hint = if (is_hard) null else "consider splitting the file at a cohesive module boundary",
        // File-level metric: the ratchet subject is the file itself.
        .ratchet_key = try ctx.allocator.dupe(u8, entry.rel_path),
        .metric = lines,
    });
}

/// Appends the pre-trip alert for a file that has reached 95% of the hard
/// limit. It is a SECOND advisory finding, alongside the ordinary
/// recommended-limit warning, and carries no ratchet key: the recommended-tier
/// warning owns this file's advisory ratchet entry, and an alert must never add
/// or preserve one of its own. Nothing is appended below the band or above the
/// cap (over the cap the check already blocks).
fn noteNearHardCap(ctx: *FileSizeCtx, rel_path: []const u8, lines: u32) std.mem.Allocator.Error!void {
    if (!near_cap.isNearHardCap(lines, ctx.hard_limit)) return;
    try ctx.warnings.append(ctx.allocator, .{
        .check = check_name,
        .file = rel_path,
        .alert = true,
        .message = try near_cap.alertMessage(ctx.allocator, .{
            .value = lines,
            .hard_cap = ctx.hard_limit,
            .unit = "code lines",
            .remedy = split_remedy,
            .crossing = ctx.crossing,
        }),
    });
}

/// Entry point for the file-size check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayList(reporter.Violation) = .empty;
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var ctx: FileSizeCtx = .{
        .allocator = allocator,
        .warning_limit = cfg.max_file_lines,
        .hard_limit = cfg.hard_max_file_lines,
        .warnings = &warnings,
        .violations = &violations,
        .crossing = hysteresis.crossingFor(cfg, check_name),
    };

    const dirs_to_check = [_][]const u8{ "src", "test" };
    for (&dirs_to_check) |dir_name| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir_name });
        try walk.walkZigFiles(
            allocator,
            dir_path,
            .{ .display_root = dir_name, .excludes = cfg.file_size_exclude },
            .{ .ctx = &ctx, .visit = fileSizeVisit },
        );
    }

    for (warnings.items) |warning| reporter.warn(warning);
    if (violations.items.len == 0 and warnings.items.len == 0) {
        ok("all files within {d} recommended code lines (a code line is a {s})", .{
            cfg.max_file_lines,
            metric_definition,
        });
        return;
    }
    if (violations.items.len == 0) return;

    fail("file size FAILED ({d} file(s) over {d} hard code-line limit)", .{
        violations.items.len,
        cfg.hard_max_file_lines,
    });
    for (violations.items) |v| reporter.emit(v);
    // Distinguish the two limits: only the hard limit blocks. A file merely over
    // the recommended limit warns (advisory, never ratcheted) and can still grow
    // up to the hard limit — so "at the recommended cap" is not "cannot grow".
    print(
        "  note: only the {d} hard limit blocks; the {d} recommended limit warns " ++
            "(advisory, never ratcheted) — a file between them can still grow.\n",
        .{ cfg.hard_max_file_lines, cfg.max_file_lines },
    );
    // Say what is counted, because the alternative is agents guessing: deleting
    // a doc comment moves this number by nothing at all.
    print("  note: a code line is a {s}.\n", .{metric_definition});
    print("  fix: split the file at a cohesive module boundary.\n", .{});
    return error.CheckFailed;
}

// spec: File Size - Warns above a configurable recommended line limit and fails above a generous hard limit
// spec: File Size - Respects file_size_exclude patterns
// spec: File Size - Excludes test-block lines from the line count
// spec: File Size - Excludes blank and comment-only lines from the code-line metric
// spec: File Size - Warns prominently when a file has reached 95% of the hard limit

test "fileSizeVisit is not off-by-one on the trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: FileSizeCtx = .{
        .allocator = a,
        .warning_limit = 2,
        .hard_limit = 4,
        .warnings = &warnings,
        .violations = &violations,
    };
    // Exactly 2 lines with the fmt-mandated trailing newline: at the cap, ok.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "x.zig", .content = "a\nb\n" });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    // 3 lines: over the recommendation but below the hard limit.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "y.zig", .content = "a\nb\nc\n" });
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    // 5 lines: a hard failure.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "z.zig", .content = "a\nb\nc\nd\ne\n" });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "fileSizeVisit accumulates warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: FileSizeCtx = .{
        .allocator = a,
        // 5, not 10: the fixture's files are 4-11 CODE lines once their headers,
        // blank lines and test blocks come out of the count.
        .warning_limit = 5,
        .hard_limit = 10_000,
        .warnings = &warnings,
        .violations = &violations,
    };
    try walk.walkZigFiles(a, "test-project/src", .{ .display_root = "src" }, .{ .ctx = &ctx, .visit = fileSizeVisit });
    try std.testing.expect(warnings.items.len >= 3);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "testBlockLines excludes test bodies from the count" {
    const content =
        \\const x = 1;
        \\fn f() void {}
        \\test "t" {
        \\    const y = 2;
        \\    _ = y;
        \\}
    ;
    // 6 total lines; the test block spans lines 3-6 (4 lines) → 2 code lines.
    try std.testing.expectEqual(@as(u32, 4), try testBlockLines(content));
    try std.testing.expectEqual(@as(u32, 2), try codeLines(content));
}

test "codeLines counts neither blank lines nor whole-line comments" {
    const content =
        \\//! module header
        \\
        \\/// doc comment
        \\const x = 1; // trailing comment still counts
        \\
        \\    // indented comment
        \\const s =
        \\    \\// this is string content, not a comment
        \\;
        \\test "t" {
        \\    // a comment inside a test block is already excluded with it
        \\    _ = x;
        \\}
    ;
    // Code: `const x = 1;` (its trailing comment does not disqualify the line),
    // `const s =`, the `\\…` multiline-string line (its `\\` can never read as
    // `//`), and the closing `;`. Everything else is a comment, a blank, or
    // inside the test block. Deleting the three comment lines would move this
    // number by nothing — which is the entire point.
    try std.testing.expectEqual(@as(u32, 4), try codeLines(content));
    // The rule itself, on the shapes that decide it.
    try std.testing.expect(isCodeLine("const x = 1;"));
    try std.testing.expect(isCodeLine("    \\\\// string body"));
    try std.testing.expect(!isCodeLine(""));
    try std.testing.expect(!isCodeLine("   \t "));
    try std.testing.expect(!isCodeLine("  // comment"));
    try std.testing.expect(!isCodeLine("/// doc"));
    try std.testing.expect(!isCodeLine("//! header"));
}

/// `n` one-character code lines, for the threshold tests below. Built by loop
/// rather than by repeating a literal because Zig 0.17 removed the `**` repeat
/// operator — `"x\n" ** n` now tokenizes as a multiply against a pointer type.
fn codeLineText(a: std.mem.Allocator, n: usize) std.mem.Allocator.Error![:0]const u8 {
    const buf = try a.allocSentinel(u8, n * 2, 0);
    for (0..n) |i| {
        buf[i * 2] = 'x';
        buf[i * 2 + 1] = '\n';
    }
    return buf;
}

test "a file at 95% of the hard limit draws one un-collapsible alert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: FileSizeCtx = .{
        .allocator = a,
        .warning_limit = 2,
        .hard_limit = 20,
        .warnings = &warnings,
        .violations = &violations,
    };
    // 19 of 20 code lines: one line from a blocking crossing. The recorded
    // failure this exists for is a file that crossed from ONE line under, with
    // its warning buried among 45 report-only findings.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "src/big.zig", .content = try codeLineText(a, 19) });
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
    const alert = warnings.items[0];
    try std.testing.expect(alert.alert);
    try std.testing.expectEqualStrings("src/big.zig", alert.file.?);
    try std.testing.expectEqualStrings(
        "NEAR HARD CAP  19 of 20 code lines (95%) — crossing blocks the gate; " ++ split_remedy,
        alert.message,
    );
    // The alert carries no ratchet key: the recommended-tier warning beside it
    // owns this file's advisory entry, and an alert must add none of its own.
    try std.testing.expect(alert.ratchet_key == null);
    // Below the band, only the ordinary recommended-limit warning is raised...
    warnings.clearRetainingCapacity();
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "src/mid.zig", .content = try codeLineText(a, 10) });
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expect(!warnings.items[0].alert);
    // ...and past the cap the check blocks, so there is nothing left to pre-warn.
    warnings.clearRetainingCapacity();
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "src/over.zig", .content = try codeLineText(a, 21) });
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
