const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

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

// Mutable tokenizer bookkeeping for a single `scan` pass. `saw_const_decl`
// is true between `const`/`var` and its `=` (the name/type portion, e.g. the
// `1024` in `[1024]u8`); `in_const_init` is true between that `=` and the `;`
// (the whole initializer, so `const t = base * 30_000;` is exempt, not just
// the first token after `=`).
const ScanState = struct {
    in_test: bool = false,
    in_comptime: bool = false,
    depth: u32 = 0,
    test_depth: u32 = 0,
    comptime_depth: u32 = 0,
    saw_const_decl: bool = false,
    in_const_init: bool = false,

    // Advances scope/decl tracking for one non-number token.
    fn update(self: *ScanState, tag: std.zig.Token.Tag, prev_tag: std.zig.Token.Tag) void {
        switch (tag) {
            .keyword_test => {
                self.in_test = true;
                self.test_depth = self.depth + 1;
            },
            .l_brace => self.enterBrace(prev_tag),
            .r_brace => self.leaveBrace(),
            .keyword_const, .keyword_var => self.saw_const_decl = true,
            .equal => {
                if (self.saw_const_decl) {
                    self.in_const_init = true;
                    self.saw_const_decl = false;
                }
            },
            .semicolon => {
                self.saw_const_decl = false;
                self.in_const_init = false;
            },
            else => {},
        }
    }

    fn enterBrace(self: *ScanState, prev_tag: std.zig.Token.Tag) void {
        self.depth += 1;
        // Only a real `comptime { ... }` block exempts its body. A bare
        // `comptime` param modifier or expression prefix has no block —
        // treating it as one exempted every generic function entirely.
        if (prev_tag == .keyword_comptime) {
            self.in_comptime = true;
            self.comptime_depth = self.depth;
        }
    }

    fn leaveBrace(self: *ScanState) void {
        if (self.depth > 0) self.depth -= 1;
        if (self.in_test and self.depth < self.test_depth) self.in_test = false;
        if (self.in_comptime and self.depth < self.comptime_depth) self.in_comptime = false;
    }

    // A number literal is exempt inside test/comptime bodies and const decls,
    // or right after `=` (struct-field defaults, assignments).
    fn exemptsNumber(self: *const ScanState, prev_tag: std.zig.Token.Tag) bool {
        if (self.in_test or self.in_comptime) return true;
        if (self.saw_const_decl or self.in_const_init) return true;
        return prev_tag == .equal;
    }
};

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const z = try ctx.allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    var state: ScanState = .{};
    var prev_tag: std.zig.Token.Tag = .invalid;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .number_literal) {
            if (!state.exemptsNumber(prev_tag)) try recordIfMagic(ctx, z, t);
        } else {
            state.update(t.tag, prev_tag);
        }
        prev_tag = t.tag;
    }
}

// Appends a violation for `t` unless the literal is allowlisted or hex/oct/bin.
fn recordIfMagic(ctx: *ScanCtx, z: [:0]const u8, t: std.zig.Token) Allocator.Error!void {
    const text = z[t.loc.start..t.loc.end];
    if (isAllowed(text)) return;
    if (isHexOrOctOrBinary(text)) return;
    if (isFloatIdiom(text)) return;
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: magic number `{s}` (extract a named const)",
        .{ ctx.rel_path, lineOf(z, t.loc.start), text },
    );
    try ctx.violations.append(ctx.allocator, msg);
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

/// Self-documenting float idioms that aren't "magic": `0.5`, an allowlisted
/// int written as a float (`1.0`, `2.0`, `10.0`), and pure power-of-ten
/// scientific notation (`1e9`, `1e-9`, `1.0e-6` — SI scales name themselves).
/// Geometry/EE codebases are saturated with these, which is why the check is
/// pure noise there without this exemption.
fn isFloatIdiom(text: []const u8) bool {
    if (std.mem.eql(u8, text, "0.5")) return true;
    if (std.mem.endsWith(u8, text, ".0") and isAllowed(text[0 .. text.len - 2])) return true;
    const e = std.mem.indexOfScalar(u8, text, 'e') orelse
        std.mem.indexOfScalar(u8, text, 'E') orelse return false;
    const mant = text[0..e];
    return std.mem.eql(u8, mant, "1") or std.mem.eql(u8, mant, "1.0");
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

/// Entry point for the magic-number check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    if (!ctx.cfg.magic_number.enabled) {
        reporter.ok("magic-number disabled by config (opt-in via [magic_number] enabled = true)", .{});
        return;
    }
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

// spec: Tier 2 Anti-patterns - Rejects bare integer literals outside a small allowlist

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

test "analyzeContent allows float idioms but flags other floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1.0 / 1e-9 / 0.5 / 10.0 are self-documenting idioms → no violation.
    const ok_out = try analyzeContent(a, "src/x.zig",
        \\fn f(x: f64) f64 { return x * 1.0 + 1e-9 - 0.5 + 10.0; }
    );
    try std.testing.expectEqual(@as(usize, 0), ok_out.len);
    // A genuine magic float still flags.
    const bad_out = try analyzeContent(a, "src/x.zig",
        \\fn g(x: f64) f64 { return x * 3.7; }
    );
    try std.testing.expectEqual(@as(usize, 1), bad_out.len);
}
