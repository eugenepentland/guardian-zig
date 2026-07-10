const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

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
    violations: *std.ArrayList(reporter.Violation),
};

/// Pure-function entry: scans `content` for pub structs whose `?T`
/// field count exceeds `max_density_pct`% of total fields.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList(reporter.Violation) = .empty;
    for (allowed_paths) |pat| {
        if (walk.matchGlob(rel_path, pat)) return reporter.flatLines(allocator, violations.items);
    }
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return reporter.flatLines(allocator, violations.items);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const a = ctx.allocator;
    const z = try a.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_pub) continue;
        if (tok.next().tag != .keyword_const) continue;
        const head = parseHead(&tok, z) orelse continue;
        const stats = collectFieldStats(&tok);
        try recordDensity(ctx, head, stats);
    }
}

fn recordDensity(ctx: *ScanCtx, head: Head, stats: Stats) Allocator.Error!void {
    if (stats.total < min_fields) return;
    const pct = (stats.optional * 100) / stats.total;
    if (pct <= max_density_pct) return;
    try ctx.violations.append(ctx.allocator, .{
        .check = "optional-density",
        .file = ctx.rel_path,
        .line = head.line,
        .message = try std.fmt.allocPrint(
            ctx.allocator,
            "pub struct '{s}' is {d}% optional ({d}/{d} fields)",
            .{ head.name, pct, stats.optional, stats.total },
        ),
        .ratchet_key = try std.fmt.allocPrint(ctx.allocator, "{s}|{s}", .{ ctx.rel_path, head.name }),
        .metric = pct,
    });
}

const Head = struct { name: []const u8, line: u32 };

fn parseHead(tok: *std.zig.Tokenizer, z: []const u8) ?Head {
    const id = tok.next();
    if (id.tag != .identifier) return null;
    if (!isStructHead(tok)) return null;
    return .{ .name = z[id.loc.start..id.loc.end], .line = lineOf(z, id.loc.start) };
}

fn isStructHead(tok: *std.zig.Tokenizer) bool {
    if (tok.next().tag != .equal) return false;
    var t = tok.next();
    while (t.tag == .keyword_extern or t.tag == .keyword_packed) t = tok.next();
    if (t.tag != .keyword_struct) return false;
    return tok.next().tag == .l_brace;
}

const Stats = struct {
    total: u32 = 0,
    optional: u32 = 0,
};

const Tag = std.zig.Token.Tag;

// Running state while walking a struct body's tokens. `step` consumes one
// token and returns true once the struct's closing brace is reached.
const FieldState = struct {
    stats: Stats = .{},
    depth: u32 = 1,
    prev_was_field_name: bool = false,
    saw_decl_kw: bool = false,

    fn step(self: *FieldState, tok: *std.zig.Tokenizer, tag: Tag) bool {
        switch (tag) {
            .l_brace, .l_paren => self.depth += 1,
            .r_brace, .r_paren => self.depth -= 1,
            .keyword_pub, .keyword_fn, .keyword_const, .keyword_var => self.saw_decl_kw = true,
            .identifier => self.markIdentifier(),
            .colon => return self.handleColon(tok),
            .semicolon => self.reset(),
            else => self.handleOther(tag),
        }
        return false;
    }

    fn markIdentifier(self: *FieldState) void {
        if (isFieldNameStart(self.depth, self.saw_decl_kw, self.prev_was_field_name)) {
            self.prev_was_field_name = true;
        }
    }

    fn reset(self: *FieldState) void {
        self.prev_was_field_name = false;
        self.saw_decl_kw = false;
    }

    fn handleOther(self: *FieldState, tag: Tag) void {
        if (tag != .doc_comment and tag != .container_doc_comment) self.reset();
    }

    fn handleColon(self: *FieldState, tok: *std.zig.Tokenizer) bool {
        if (self.depth != 1 or !self.prev_was_field_name) return false;
        self.stats.total += 1;
        const closed = self.scanFieldType(tok);
        self.reset();
        return closed;
    }

    // Consumes the field type after a `:`, counting a leading `?` as optional
    // and stopping at the field-terminating comma. Returns true if the
    // struct's closing brace is reached mid-type.
    fn scanFieldType(self: *FieldState, tok: *std.zig.Tokenizer) bool {
        var t = tok.next();
        if (t.tag == .question_mark) self.stats.optional += 1;
        while (t.tag != .eof) {
            if (self.adjustTypeDepth(t.tag)) return true;
            if (t.tag == .comma and self.depth == 1) return false;
            t = tok.next();
        }
        return false;
    }

    fn adjustTypeDepth(self: *FieldState, tag: Tag) bool {
        if (isOpenBracket(tag)) self.depth += 1;
        if (!isCloseBracket(tag)) return false;
        if (self.depth > 0) self.depth -= 1;
        return self.depth == 0;
    }
};

fn collectFieldStats(tok: *std.zig.Tokenizer) Stats {
    var state: FieldState = .{};
    while (state.depth > 0) {
        const t = tok.next();
        if (t.tag == .eof) return state.stats;
        if (state.step(tok, t.tag)) return state.stats;
    }
    return state.stats;
}

fn isOpenBracket(tag: Tag) bool {
    return tag == .l_paren or tag == .l_brace or tag == .l_bracket;
}

fn isCloseBracket(tag: Tag) bool {
    return tag == .r_paren or tag == .r_brace or tag == .r_bracket;
}

fn isFieldNameStart(depth: u32, saw_decl_kw: bool, prev_field_name: bool) bool {
    if (depth != 1) return false;
    if (saw_decl_kw) return false;
    return !prev_field_name;
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList(reporter.Violation),
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
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("optional-density: no pub struct exceeds {d}% optional fields", .{max_density_pct});
        return;
    }
    reporter.fail("optional-density FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: split the type into a 'maybe-built' phase and a 'fully-built' phase, " ++
        "or model the optionality as a tagged union.\n", .{});
    return error.CheckFailed;
}

// spec: Tier 2 Anti-patterns - Caps the percentage of optional fields in a public struct

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
