const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for `switch (...) { "..." => ... }`
/// patterns. A single string-literal case key is enough to flag (the case
/// might also be `"a", "b" =>` — both flag).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const z = try ctx.allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_switch) continue;
        const switch_byte = t.loc.start;
        // Skip the switch's expression: walk to matching r_paren after l_paren.
        if (tok.next().tag != .l_paren) continue;
        if (skipParenExpr(&tok)) return;
        if (tok.next().tag != .l_brace) continue;
        // Now scan case prongs; flag if any case key is a string literal.
        if (try scanProngs(ctx, z, switch_byte, &tok)) return;
    }
}

/// Consumes tokens up to and including the `r_paren` matching an already-seen
/// `l_paren`. Returns true if the tokenizer hit eof first (caller should stop).
fn skipParenExpr(tok: *std.zig.Tokenizer) bool {
    var paren_depth: u32 = 1;
    while (paren_depth > 0) {
        const ti = tok.next();
        if (ti.tag == .eof) return true;
        if (ti.tag == .l_paren) paren_depth += 1;
        if (ti.tag == .r_paren) paren_depth -= 1;
    }
    return false;
}

/// Running state while scanning a switch body's case prongs.
const ProngState = struct {
    brace_depth: u32 = 1,
    case_start: bool = true,
    flagged: bool = false,

    /// True while the tokenizer is at a top-level (unnested) case key.
    fn atTopLevelCase(self: ProngState) bool {
        return self.case_start and self.brace_depth == 1 and !self.flagged;
    }
};

/// Scans the case prongs of a switch body (after its opening `l_brace`).
/// Flags a single violation if any top-level case key is a string literal.
/// Returns true if the tokenizer hit eof first (caller should stop).
fn scanProngs(
    ctx: *ScanCtx,
    z: [:0]const u8,
    switch_byte: usize,
    tok: *std.zig.Tokenizer,
) Allocator.Error!bool {
    var state: ProngState = .{};
    while (state.brace_depth > 0) {
        const ti = tok.next();
        if (ti.tag == .eof) return true;
        if (ti.tag == .string_literal and state.atTopLevelCase()) {
            try flagStringCase(ctx, z, switch_byte);
            state.flagged = true;
            continue;
        }
        updateProngState(&state, ti.tag);
    }
    return false;
}

/// Advances the prong-scan `state` for one token tag (non-flagging tokens).
fn updateProngState(state: *ProngState, tag: std.zig.Token.Tag) void {
    switch (tag) {
        .l_brace, .l_paren, .l_bracket => state.brace_depth += 1,
        .r_brace, .r_paren, .r_bracket => state.brace_depth -= 1,
        .comma => if (state.brace_depth == 1) {
            state.case_start = true;
        },
        .equal_angle_bracket_right => state.case_start = false,
        .string_literal, .doc_comment => {},
        else => state.case_start = false,
    }
}

/// Appends the stringly-typed-switch violation for the switch at `switch_byte`.
fn flagStringCase(ctx: *ScanCtx, z: [:0]const u8, switch_byte: usize) Allocator.Error!void {
    const line = lineOf(z, switch_byte);
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: switch on string literals (use an enum / tagged union instead)",
        .{ ctx.rel_path, line },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the stringly-typed-switches check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("stringly-typed-switches: no switches over string literals", .{});
        return;
    }
    reporter.fail("stringly-typed-switches FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: model the cases as an enum or tagged union; let the type system enforce exhaustiveness.\n", .{});
    return error.CheckFailed;
}

// spec: Tier 2 Anti-patterns - Rejects switch expressions whose case keys are string literals

test "analyzeContent flags switch on string literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn route(s: []const u8) u32 {
        \\    return switch (s) {
        \\        "alpha" => 1,
        \\        "beta" => 2,
        \\        else => 0,
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows switch on enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const Mode = enum { alpha, beta };
        \\fn route(m: Mode) u32 {
        \\    return switch (m) {
        \\        .alpha => 1,
        \\        .beta => 2,
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
