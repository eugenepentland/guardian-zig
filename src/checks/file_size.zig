const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const lineOf = @import("../text.zig").lineOf;

const FileSizeCtx = struct {
    allocator: std.mem.Allocator,
    max_lines: u32,
    violations: *std.ArrayList(reporter.Violation),
};

/// Total source lines. Counts newlines, adding 1 only for a final unterminated
/// line. `zig fmt` always emits a trailing newline, so counting 1 + newlines
/// would report an N-line file as N+1 and fail files exactly at the cap.
fn totalLines(content: []const u8) u32 {
    var newlines: u32 = 0;
    for (content) |c| {
        if (c == '\n') newlines += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') return newlines + 1;
    return newlines;
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

/// Number of source lines occupied by top-level `test {...}` blocks. The
/// file-size cap measures production code, so a heavily-tested module isn't
/// forced over the same limit as a genuine god-file by its own test suite
/// (audit: erc.zig was 62% test code). Tokenizer skips strings/comments, so a
/// `test` word inside a literal never opens a phantom block.
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
        s.total += lineOf(z, byte) - lineOf(z, s.start_byte) + 1;
        s.in_test = false;
    }
    if (s.depth > 0) s.depth -= 1;
}

/// Production line count: total lines minus lines inside `test {...}` blocks.
fn codeLines(content: [:0]const u8) std.mem.Allocator.Error!u32 {
    const total = totalLines(content);
    const test_lines = try testBlockLines(content);
    return if (test_lines <= total) total - test_lines else total;
}

fn fileSizeVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileSizeCtx = @ptrCast(@alignCast(raw_ctx));
    const lines = try codeLines(entry.content);
    if (lines > ctx.max_lines) {
        try ctx.violations.append(ctx.allocator, .{
            .check = "file-size",
            .file = entry.rel_path,
            .message = try std.fmt.allocPrint(ctx.allocator, "{d} code lines (limit: {d})", .{ lines, ctx.max_lines }),
            // File-level metric: the ratchet subject is the file itself.
            .ratchet_key = try ctx.allocator.dupe(u8, entry.rel_path),
            .metric = lines,
        });
    }
}

/// Entry point for the file-size check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: FileSizeCtx = .{
        .allocator = allocator,
        .max_lines = cfg.max_file_lines,
        .violations = &violations,
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

    if (violations.items.len == 0) {
        ok("all files within {d} code-line limit", .{cfg.max_file_lines});
        return;
    }

    fail("file size FAILED ({d} file(s) over {d} code-line limit)", .{ violations.items.len, cfg.max_file_lines });
    for (violations.items) |v| reporter.emit(v);
    return error.CheckFailed;
}

// spec: File Size - Checks source files against configurable line limit
// spec: File Size - Respects file_size_exclude patterns
// spec: File Size - Excludes test-block lines from the line count

test "fileSizeVisit is not off-by-one on the trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: FileSizeCtx = .{ .allocator = a, .max_lines = 2, .violations = &violations };
    // Exactly 2 lines with the fmt-mandated trailing newline: at the cap, ok.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "x.zig", .content = "a\nb\n" });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    // 3 lines: over the cap.
    try fileSizeVisit(@ptrCast(&ctx), .{ .rel_path = "y.zig", .content = "a\nb\nc\n" });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "fileSizeVisit accumulates violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: FileSizeCtx = .{ .allocator = a, .max_lines = 10, .violations = &violations };
    try walk.walkZigFiles(a, "test-project/src", .{ .display_root = "src" }, .{ .ctx = &ctx, .visit = fileSizeVisit });
    try std.testing.expect(violations.items.len >= 3);
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
