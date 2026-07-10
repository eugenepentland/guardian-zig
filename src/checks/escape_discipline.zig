const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const lineOf = @import("../text.zig").lineOf;

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// True for a `print`/`allocPrint`/`bufPrint` call — the format-string sinks
/// that interpolate args into their output.
fn isPrintName(name: []const u8) bool {
    return std.mem.eql(u8, name, "print") or
        std.mem.eql(u8, name, "allocPrint") or
        std.mem.eql(u8, name, "bufPrint");
}

/// True for an arg expression that neutralizes an interpolated string:
/// an escape/encode helper call or `@tagName` (a closed enum name).
fn isEscapeLike(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "escap") != null or
        std.mem.indexOf(u8, name, "encode") != null or
        std.mem.eql(u8, name, "tagName");
}

/// True when a format literal interpolates a string (`{s}`) directly into
/// markup — an attribute (`="`) or an open tag (`<x` / `</`).
fn rawMarkupInterp(lit: []const u8) bool {
    if (std.mem.indexOf(u8, lit, "{s}") == null) return false;
    if (std.mem.indexOf(u8, lit, "=\"") != null) return true;
    return hasTagOpen(lit);
}

fn hasTagOpen(lit: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < lit.len) : (i += 1) {
        if (lit[i] != '<') continue;
        const c = lit[i + 1];
        if (std.ascii.isAlphabetic(c) or c == '/') return true;
    }
    return false;
}

// Tracks one print-family call: the paren depth its args live at, whether its
// format string interpolated a string into markup, and whether any arg is an
// escape helper (which makes the interpolation safe).
const ScanState = struct {
    paren: u32 = 0,
    pending_name: bool = false, // last identifier was a print-family name
    call_depth: ?u32 = null, // paren depth of the tracked call's args
    fmt_flagged: bool = false,
    escape_seen: bool = false,
};

fn scan(ctx: *ScanCtx, z: [:0]const u8) Allocator.Error!void {
    var tok = std.zig.Tokenizer.init(z);
    var s: ScanState = .{};
    var flag_line: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .identifier => s.pending_name = onIdentifier(&s, z[t.loc.start..t.loc.end]),
            .builtin => if (isEscapeLike(z[t.loc.start..t.loc.end]) and s.call_depth != null) {
                s.escape_seen = true;
            },
            .l_paren => onLParen(&s),
            .string_literal => if (inFmtPosition(&s) and rawMarkupInterp(z[t.loc.start..t.loc.end])) {
                s.fmt_flagged = true;
                flag_line = lineOf(z, t.loc.start);
            },
            .r_paren => try onRParen(ctx, &s, flag_line),
            else => s.pending_name = false,
        }
    }
}

/// Returns whether this identifier arms a print call; also marks an escape
/// helper seen inside the current call's args.
fn onIdentifier(s: *ScanState, name: []const u8) bool {
    if (s.call_depth != null and isEscapeLike(name)) s.escape_seen = true;
    return isPrintName(name);
}

fn onLParen(s: *ScanState) void {
    s.paren += 1;
    if (s.pending_name and s.call_depth == null) {
        s.call_depth = s.paren;
        s.fmt_flagged = false;
        s.escape_seen = false;
    }
    s.pending_name = false;
}

/// True when a string literal is a top-level argument of the tracked call
/// (its format string), not a nested sub-expression.
fn inFmtPosition(s: *const ScanState) bool {
    const cd = s.call_depth orelse return false;
    return s.paren == cd;
}

fn onRParen(ctx: *ScanCtx, s: *ScanState, flag_line: u32) Allocator.Error!void {
    if (s.call_depth) |cd| {
        if (s.paren == cd) {
            if (s.fmt_flagged and !s.escape_seen) try record(ctx, flag_line);
            s.call_depth = null;
        }
    }
    if (s.paren > 0) s.paren -= 1;
    s.pending_name = false;
}

fn record(ctx: *ScanCtx, line: u32) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: raw {{s}} interpolated into markup — escape the arg (unescaped injection risk)",
        .{ ctx.rel_path, line },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

/// Pure-function entry: violation lines for one file (allocator-owned).
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .rel_path = rel_path, .violations = &violations };
    const z = try allocator.dupeZ(u8, content);
    try scan(&ctx, z);
    return violations.toOwnedSlice(allocator);
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    ctx.rel_path = entry.rel_path;
    const z = try ctx.allocator.dupeZ(u8, entry.content);
    try scan(ctx, z);
}

/// Entry point for the escape-discipline check (opt-in).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    if (!cfg.escape_discipline.enabled) {
        ok("escape-discipline disabled by config (opt-in via [escape_discipline] enabled = true)", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .rel_path = "", .violations = &violations };
    const opts: walk.Visitor = .{ .ctx = &ctx, .visit = visit };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, opts);

    if (violations.items.len == 0) {
        ok("no raw markup interpolation found", .{});
        return;
    }
    fail("escape-discipline FAILED ({d} raw markup interpolation(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: route the arg through an escape helper (escape/encode/@tagName)" ++
        " or build the markup with separate escaped writes.\n", .{});
    return error.CheckFailed;
}

// spec: Escape Discipline - Flags raw {s} interpolation into HTML/SVG markup

test "flags raw {s} in markup, allows escaped or non-markup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Raw string interpolated into a tag / attribute → flagged (2 sinks).
    const bad = try analyzeContent(a, "src/x.zig",
        \\fn r(w: anytype, name: []const u8) !void {
        \\    try w.print("<h1>{s}</h1>", .{name});
        \\    try w.print("<a href=\"{s}\">x</a>", .{name});
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), bad.len);

    // Escaped arg, non-markup format, and numeric interpolation → no flags.
    const good = try analyzeContent(a, "src/x.zig",
        \\fn r(w: anytype, name: []const u8, n: u32) !void {
        \\    try w.print("<h1>{s}</h1>", .{escapeHtml(name)});
        \\    try w.print("plain {s} text", .{name});
        \\    try w.print("<td>{d}</td>", .{n});
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), good.len);
}
