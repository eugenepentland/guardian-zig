const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Constructor Hygiene - Requires structs that own an allocator field to declare a pub fn deinit

const allowed_paths = [_][]const u8{
    // Pure context-passing structs that borrow an allocator without
    // owning heap data. Detecting this distinction structurally is
    // out of scope; explicit exemption is cleaner.
    "src/cli/types.zig",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

const StructInfo = struct {
    name: []const u8,
    line: u32,
    has_allocator_field: bool = false,
    has_pub_deinit: bool = false,
};

/// Pure-function entry: scans `content` for pub structs whose field set
/// owns an allocator but lack a matching `pub fn deinit`.
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

    var structs: std.ArrayListUnmanaged(StructInfo) = .empty;
    defer structs.deinit(a);

    var ts: TokenStream = .{ .tok = &tok, .z = z };
    while (true) {
        const t = ts.next();
        if (t.tag == .eof) break;
        if (t.tag == .keyword_pub) {
            const next = ts.next();
            if (next.tag != .keyword_const) continue;
            if (parseStructHead(&ts)) |head| {
                const info = collectStructBody(z, &ts, head);
                try structs.append(a, info);
            }
        }
    }

    for (structs.items) |s| {
        if (s.has_allocator_field and !s.has_pub_deinit) {
            const msg = try std.fmt.allocPrint(
                a,
                "{s}:{d}: pub struct '{s}' owns an allocator field but has no pub fn deinit",
                .{ ctx.rel_path, s.line, s.name },
            );
            try ctx.violations.append(a, msg);
        }
    }
}

const TokenStream = struct {
    tok: *std.zig.Tokenizer,
    z: []const u8,

    fn next(self: *TokenStream) std.zig.Token {
        return self.tok.next();
    }

    fn peekText(self: TokenStream, t: std.zig.Token) []const u8 {
        return self.z[t.loc.start..t.loc.end];
    }
};

const StructHead = struct {
    name: []const u8,
    line: u32,
};

fn parseStructHead(ts: *TokenStream) ?StructHead {
    const id = ts.next();
    if (id.tag != .identifier) return null;
    const name = ts.peekText(id);

    const eq = ts.next();
    if (eq.tag != .equal) return null;

    var t = ts.next();
    while (t.tag == .keyword_extern or t.tag == .keyword_packed) t = ts.next();
    if (t.tag != .keyword_struct) return null;

    const lbrace = ts.next();
    if (lbrace.tag != .l_brace) return null;

    return .{ .name = name, .line = lineOf(ts.z, id.loc.start) };
}

fn collectStructBody(z: []const u8, ts: *TokenStream, head: StructHead) StructInfo {
    var info: StructInfo = .{ .name = head.name, .line = head.line };
    var depth: u32 = 1;
    var prev_pub = false;
    var prev_was_fn = false;

    while (depth > 0) {
        const t = ts.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            .keyword_pub => {
                prev_pub = true;
                prev_was_fn = false;
            },
            .keyword_fn => {
                prev_was_fn = true;
            },
            .identifier => {
                const text = z[t.loc.start..t.loc.end];
                if (prev_was_fn and prev_pub and std.mem.eql(u8, text, "deinit")) {
                    info.has_pub_deinit = true;
                }
                if (depth == 1 and (std.mem.eql(u8, text, "allocator") or std.mem.eql(u8, text, "gpa"))) {
                    info.has_allocator_field = true;
                }
                prev_was_fn = false;
                prev_pub = false;
            },
            .colon, .comma, .equal, .semicolon => {},
            else => {
                prev_was_fn = false;
                prev_pub = false;
            },
        }
    }
    return info;
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

/// Entry point for the init-deinit-symmetry check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{ctx.project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("init-deinit-symmetry: every allocator-owning struct declares deinit", .{});
        return;
    }
    reporter.fail("init-deinit-symmetry FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: add `pub fn deinit(self: *Self) void` that frees the owned resources.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags struct with allocator and no deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Foo = struct {
        \\    allocator: std.mem.Allocator,
        \\    items: []u32,
        \\};
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows struct with allocator and deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Foo = struct {
        \\    allocator: std.mem.Allocator,
        \\    items: []u32,
        \\
        \\    pub fn deinit(self: *Foo) void {
        \\        self.allocator.free(self.items);
        \\    }
        \\};
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows struct without allocator field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Point = struct {
        \\    x: f32,
        \\    y: f32,
        \\};
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags struct with gpa field and no deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Bar = struct {
        \\    gpa: std.mem.Allocator,
        \\    cache: ?[]u32,
        \\};
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
