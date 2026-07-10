//! module-doc-header check: every src/**.zig file over the line threshold must
//! open with a `//!` module doc block. Not an every-file rule — calibrated to
//! zig-core reality (its own tree carries `//!` on only ~25-28% of files, but
//! consistently on the large, load-bearing ones), so the gate targets exactly
//! the modules where a reader arriving cold needs orientation.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// Files at or below this many total lines are exempt: a short module reads at
/// a glance, so an orientation header would be noise. Hardcoded this wave — a
/// config knob would collide with the config-owning agent (follow-up).
const line_threshold: u32 = 200;

/// A header qualifies once it reaches either bound: two `//!` lines, or a
/// single substantive line (>= 60 bytes). One terse `//! wip` line does not
/// orient a reader of a 400-line module.
const min_header_lines: u32 = 2;
const min_header_bytes: usize = 60;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    allowed_paths: []const []const u8,
    violations: *std.ArrayList([]const u8),
};

/// The leading `//!` block, measured in lines and total byte span.
const Header = struct { lines: u32, bytes: usize };

/// Total physical lines: newline count, plus one for a final unterminated line.
fn totalLines(content: []const u8) u32 {
    var newlines: u32 = 0;
    for (content) |c| {
        if (c == '\n') newlines += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') return newlines + 1;
    return newlines;
}

/// Measures the file's leading `//!` block. `//!` tokenizes as
/// `.container_doc_comment` and Zig requires it before any declaration, so a
/// module header — when present — is always the first token(s); one token per
/// line. A leading `///` (`.doc_comment`) is a declaration's doc, not a module
/// header, and does not count. Returns zero lines when the first token is
/// anything else.
fn leadingHeader(z: [:0]const u8) Header {
    var tok = std.zig.Tokenizer.init(z);
    var lines: u32 = 0;
    var start: usize = 0;
    var end: usize = 0;
    while (true) {
        const t = tok.next();
        if (t.tag != .container_doc_comment) break;
        if (lines == 0) start = t.loc.start;
        end = t.loc.end;
        lines += 1;
    }
    return .{ .lines = lines, .bytes = if (lines == 0) 0 else end - start };
}

/// Whether `content` satisfies the header requirement (measured only for files
/// already known to exceed the line threshold).
fn hasQualifyingHeader(content: [:0]const u8) bool {
    const h = leadingHeader(content);
    if (h.lines == 0) return false;
    return h.lines >= min_header_lines or h.bytes >= min_header_bytes;
}

fn isAllowed(rel_path: []const u8, allowed: []const []const u8) bool {
    for (allowed) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.allowed_paths)) return;
    const lines = totalLines(entry.content);
    if (lines <= line_threshold) return;
    if (hasQualifyingHeader(entry.content)) return;
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}: {d}-line module has no `//!` header (over {d} lines needs a 2+-line or 60+-char module doc)",
        .{ entry.rel_path, lines, line_threshold },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

/// Entry point for the module-doc-header check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .allowed_paths = ctx_param.cfg.extraAllowed("module-doc-header"),
        .violations = &violations,
    };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all modules over {d} lines carry a //! header", .{line_threshold});
        return;
    }

    fail(
        "module-doc-header FAILED ({d} module(s) over {d} lines lack a //! header)",
        .{ violations.items.len, line_threshold },
    );
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: add a `//!` block (2+ lines or 60+ chars) at line 1 for the module.\n", .{});
    print("  exempt: add a [[allow]] entry with check = \"module-doc-header\".\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Builds a module: `header` verbatim, then enough filler lines to push the
/// total past `line_threshold`. The filler is code so the file is realistic;
/// the header measurement only reads the leading `//!` block.
fn overThreshold(a: std.mem.Allocator, header: []const u8) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, header);
    var i: u32 = 0;
    while (i <= line_threshold) : (i += 1) try buf.appendSlice(a, "const filler = 0;\n");
    return buf.toOwnedSliceSentinel(a, 0);
}

fn violationCount(
    a: std.mem.Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
    allowed: []const []const u8,
) !usize {
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .allowed_paths = allowed, .violations = &violations };
    try visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = content });
    return violations.items.len;
}

// spec: Module Doc Header - Flags a module over the line threshold with no module doc header
test "over-threshold module without a //! header is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try overThreshold(a, "const std = @import(\"std\");\n");
    try testing.expectEqual(@as(usize, 1), try violationCount(a, "src/big.zig", content, &.{}));
}

// spec: Module Doc Header - Accepts an over-threshold module opening with a multi-line module doc
test "over-threshold module with a two-line //! header passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try overThreshold(a, "//! Line one.\n//! Line two.\n");
    try testing.expectEqual(@as(usize, 0), try violationCount(a, "src/big.zig", content, &.{}));
}

// spec: Module Doc Header - Accepts a single module-doc line meeting the character minimum
test "single long //! line meeting the byte minimum passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try overThreshold(a, "//! A single padded header line kept just past the sixty-byte floor.\n");
    try testing.expectEqual(@as(usize, 0), try violationCount(a, "src/big.zig", content, &.{}));
}

// spec: Module Doc Header - Rejects an over-threshold module whose lone header line is too short
test "single short //! line below the byte minimum is flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try overThreshold(a, "//! wip\n");
    try testing.expectEqual(@as(usize, 1), try violationCount(a, "src/big.zig", content, &.{}));
}

// spec: Module Doc Header - Exempts a module at or below the line threshold
test "short module without a header is exempt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const small: [:0]const u8 = "const x = 1;\nfn f() void {}\n";
    try testing.expectEqual(@as(usize, 0), try violationCount(a, "src/small.zig", small, &.{}));
}

// spec: Module Doc Header - Skips a file matching a configured allow path
test "an allowed path escapes the header requirement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try overThreshold(a, "const std = @import(\"std\");\n");
    const allowed: []const []const u8 = &.{"src/generated/*"};
    try testing.expectEqual(@as(usize, 0), try violationCount(a, "src/generated/big.zig", content, allowed));
}
