const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Tier 2 Anti-patterns - Caps the percentage of optional fields in a public struct

const min_fields: u32 = 4;
const max_density_pct: u32 = 50;

const allowed_paths = [_][]const u8{
    // Reporter's Violation is a builder-style record where missing data
    // is the natural representation. Refactor to a tagged union is queued
    // separately. New consumers should leave this empty.
    "src/reporter.zig",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for pub structs whose `?T`
/// field count exceeds `max_density_pct`% of total fields.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    for (allowed_paths) |pat| {
        if (walk.matchGlob(rel_path, pat)) return violations.toOwnedSlice(allocator);
    }
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_pub) continue;
        const next = tok.next();
        if (next.tag != .keyword_const) continue;
        if (parseHead(&tok, z)) |head| {
            const stats = collectFieldStats(&tok, z);
            if (stats.total >= min_fields) {
                const pct = (stats.optional * 100) / stats.total;
                if (pct > max_density_pct) {
                    const msg = try std.fmt.allocPrint(
                        a,
                        "{s}:{d}: pub struct '{s}' is {d}% optional ({d}/{d} fields)",
                        .{ ctx.rel_path, head.line, head.name, pct, stats.optional, stats.total },
                    );
                    try ctx.violations.append(a, msg);
                }
            }
        }
    }
}

const Head = struct { name: []const u8, line: u32 };

fn parseHead(tok: *std.zig.Tokenizer, z: []const u8) ?Head {
    const id = tok.next();
    if (id.tag != .identifier) return null;
    const name = z[id.loc.start..id.loc.end];
    const eq = tok.next();
    if (eq.tag != .equal) return null;
    var t = tok.next();
    while (t.tag == .keyword_extern or t.tag == .keyword_packed) t = tok.next();
    if (t.tag != .keyword_struct) return null;
    const lbrace = tok.next();
    if (lbrace.tag != .l_brace) return null;
    return .{ .name = name, .line = lineOf(z, id.loc.start) };
}

const Stats = struct {
    total: u32 = 0,
    optional: u32 = 0,
};

fn collectFieldStats(tok: *std.zig.Tokenizer, z: []const u8) Stats {
    var stats: Stats = .{};
    var depth: u32 = 1;
    var prev_was_field_name = false;
    var saw_decl_kw = false;

    while (depth > 0) {
        const t = tok.next();
        if (t.tag == .eof) return stats;
        switch (t.tag) {
            .l_brace, .l_paren => depth += 1,
            .r_brace, .r_paren => depth -= 1,
            .keyword_pub, .keyword_fn, .keyword_const, .keyword_var => saw_decl_kw = true,
            .identifier => {
                if (isFieldNameStart(depth, saw_decl_kw, prev_was_field_name)) {
                    prev_was_field_name = true;
                }
            },
            .colon => {
                if (depth == 1 and prev_was_field_name) {
                    stats.total += 1;
                    // Look ahead: next non-whitespace token; if it's `?`, count optional.
                    const next = tok.next();
                    if (next.tag == .question_mark) stats.optional += 1;
                    // Skip past field type until comma at depth 1.
                    var t2 = next;
                    while (t2.tag != .eof) {
                        if (t2.tag == .l_paren or t2.tag == .l_brace or t2.tag == .l_bracket) depth += 1;
                        if (t2.tag == .r_paren or t2.tag == .r_brace or t2.tag == .r_bracket) {
                            if (depth > 0) depth -= 1;
                            if (depth == 0) {
                                _ = z; // suppress unused
                                return stats;
                            }
                        }
                        if (t2.tag == .comma and depth == 1) break;
                        t2 = tok.next();
                    }
                    prev_was_field_name = false;
                    saw_decl_kw = false;
                }
            },
            .semicolon => {
                prev_was_field_name = false;
                saw_decl_kw = false;
            },
            else => {
                if (t.tag != .doc_comment and t.tag != .container_doc_comment) {
                    prev_was_field_name = false;
                    saw_decl_kw = false;
                }
            },
        }
    }
    return stats;
}

fn isFieldNameStart(depth: u32, saw_decl_kw: bool, prev_field_name: bool) bool {
    if (depth != 1) return false;
    if (saw_decl_kw) return false;
    return !prev_field_name;
}

fn lineOf(source: []const u8, byte_offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < byte_offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    for (allowed_paths) |pat| {
        if (walk.matchGlob(entry.rel_path, pat)) return;
    }
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the optional-density check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("optional-density: no pub struct exceeds {d}% optional fields", .{max_density_pct});
        return;
    }
    reporter.fail("optional-density FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: split the type into a 'maybe-built' phase and a 'fully-built' phase, or model the optionality as a tagged union.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags 75% optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Mostly = struct {
        \\    a: ?u32,
        \\    b: ?u32,
        \\    c: ?u32,
        \\    d: u32,
        \\};
    );
    try std.testing.expect(out.len >= 1);
}

test "analyzeContent allows 25% optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Mostly = struct {
        \\    a: u32,
        \\    b: u32,
        \\    c: u32,
        \\    d: ?u32,
        \\};
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
