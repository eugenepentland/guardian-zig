const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Tier 2 Anti-patterns - Rejects bare integer literals outside a small allowlist

// Allowlist covers the framework's recommended {-1, 0, 1, 2} plus
// pervasive idiom values that are not "magic" in practice: radix `10`
// (parseInt), `16` (hex), and common power-of-two sizes that read
// clearly to any Zig developer.
const allowlist = [_][]const u8{
    "0",
    "1",
    "2",
    "-1",
    "3",
    "4",
    "8",
    "10",
    "16",
    "32",
    "64",
    "100",
    "128",
    "256",
    "512",
    "1024",
    "4096",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for integer-literal tokens that
/// aren't in the small allowlist, aren't preceded by an `=` (likely
/// a const/var initializer), and aren't inside test or comptime blocks.
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
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    var in_test = false;
    var in_comptime = false;
    var depth: u32 = 0;
    var test_depth: u32 = 0;
    var comptime_depth: u32 = 0;
    var prev_tag: std.zig.Token.Tag = .invalid;
    // saw_const_decl: between `const`/`var` and its `=` (the name/type portion,
    // e.g. the `1024` in `[1024]u8`). in_const_init: between that `=` and the
    // `;` (the whole initializer, so `const t = base * 30_000;` is exempt, not
    // just the first token after `=`).
    var saw_const_decl: bool = false;
    var in_const_init: bool = false;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .keyword_test => {
                in_test = true;
                test_depth = depth + 1;
            },
            .l_brace => {
                depth += 1;
                // Only a real `comptime { ... }` block exempts its body. A bare
                // `comptime` param modifier or expression prefix has no block —
                // treating it as one exempted every generic function entirely.
                if (prev_tag == .keyword_comptime) {
                    in_comptime = true;
                    comptime_depth = depth;
                }
            },
            .r_brace => {
                if (depth > 0) depth -= 1;
                if (in_test and depth < test_depth) in_test = false;
                if (in_comptime and depth < comptime_depth) in_comptime = false;
            },
            .keyword_const, .keyword_var => saw_const_decl = true,
            .equal => {
                if (saw_const_decl) {
                    in_const_init = true;
                    saw_const_decl = false;
                }
            },
            .semicolon => {
                saw_const_decl = false;
                in_const_init = false;
            },
            .number_literal => {
                if (in_test or in_comptime) continue;
                if (saw_const_decl or in_const_init) continue;
                if (prev_tag == .equal) continue; // struct-field defaults, assignments
                const text = z[t.loc.start..t.loc.end];
                if (isAllowed(text)) continue;
                if (isHexOrOctOrBinary(text)) continue;
                const line = lineOf(z, t.loc.start);
                const msg = try std.fmt.allocPrint(
                    a,
                    "{s}:{d}: magic number `{s}` (extract a named const)",
                    .{ ctx.rel_path, line, text },
                );
                try ctx.violations.append(a, msg);
            },
            else => {},
        }
        prev_tag = t.tag;
    }
}

fn isAllowed(text: []const u8) bool {
    for (allowlist) |a| {
        if (std.mem.eql(u8, text, a)) return true;
    }
    return false;
}

fn isHexOrOctOrBinary(text: []const u8) bool {
    if (text.len < 2) return false;
    if (text[0] != '0') return false;
    return text[1] == 'x' or text[1] == 'X' or text[1] == 'o' or text[1] == 'b';
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
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the magic-number check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("magic-number: every numeric literal is named or in the allowlist", .{});
        return;
    }
    reporter.fail("magic-number FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: extract the value to `const NAME: T = ...;` so the meaning is documented.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags magic in expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn budget(n: u32) u32 { return n * 8675309; }
    );
    try std.testing.expect(out.len >= 1);
}

test "analyzeContent allows const initializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const max_count: u32 = 8675309;
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows a whole const initializer expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The magic number is past the `=`, in a compound expression.
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const budget = base * 8675309;
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags magic in a generic (comptime-param) function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A `comptime` param modifier must not exempt the whole function.
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn scale(comptime T: type, n: T) T { return n * 8675309; }
    );
    try std.testing.expect(out.len >= 1);
}

test "analyzeContent allows allowlisted values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn pick(items: []u32) u32 { return items[0] + 1; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
