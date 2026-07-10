const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const allowed_paths = [_][]const u8{
    // Pure context-passing structs that borrow an allocator without
    // owning heap data. Detecting this distinction structurally is
    // out of scope; explicit exemption is cleaner.
    "src/cli/types.zig",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayList([]const u8),
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
    var violations: std.ArrayList([]const u8) = .empty;
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

    var structs: std.ArrayList(StructInfo) = .empty;
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

    if (!consumeStructOpen(ts)) return null;

    return .{ .name = name, .line = lineOf(ts.z, id.loc.start) };
}

// Consumes `= struct {` (allowing extern/packed before struct) starting
// right after the type name. Returns false at the first token that breaks
// the shape, matching the original short-circuit consumption order.
fn consumeStructOpen(ts: *TokenStream) bool {
    if (ts.next().tag != .equal) return false;

    var t = ts.next();
    while (t.tag == .keyword_extern or t.tag == .keyword_packed) t = ts.next();
    if (t.tag != .keyword_struct) return false;

    return ts.next().tag == .l_brace;
}

// Running parser state while walking a single struct body.
const BodyState = struct {
    depth: u32 = 1,
    paren_depth: u32 = 0,
    prev_pub: bool = false,
    prev_was_fn: bool = false,
};

fn collectStructBody(z: []const u8, ts: *TokenStream, head: StructHead) StructInfo {
    var info: StructInfo = .{ .name = head.name, .line = head.line };
    var st: BodyState = .{};

    while (st.depth > 0) {
        const t = ts.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .l_brace => st.depth += 1,
            .r_brace => st.depth -= 1,
            .l_paren => st.paren_depth += 1,
            .r_paren => st.paren_depth -|= 1,
            .keyword_pub => {
                st.prev_pub = true;
                st.prev_was_fn = false;
            },
            .keyword_fn => st.prev_was_fn = true,
            .identifier => classifyIdentifier(&info, &st, z[t.loc.start..t.loc.end]),
            .colon, .comma, .equal, .semicolon => {},
            else => {
                st.prev_was_fn = false;
                st.prev_pub = false;
            },
        }
    }
    return info;
}

// Updates struct flags for one identifier token and clears the pub/fn markers.
fn classifyIdentifier(info: *StructInfo, st: *BodyState, text: []const u8) void {
    if (st.prev_was_fn and st.prev_pub and std.mem.eql(u8, text, "deinit")) {
        info.has_pub_deinit = true;
    }
    // Only a real field counts — an `allocator`/`gpa` inside a method's
    // parameter list (paren_depth > 0) is a per-call allocator, not an
    // owned field.
    if (st.depth == 1 and st.paren_depth == 0 and isAllocatorName(text)) {
        info.has_allocator_field = true;
    }
    st.prev_was_fn = false;
    st.prev_pub = false;
}

fn isAllocatorName(text: []const u8) bool {
    return std.mem.eql(u8, text, "allocator") or std.mem.eql(u8, text, "gpa");
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
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
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("init-deinit-symmetry: every allocator-owning struct declares deinit", .{});
        return;
    }
    reporter.fail("init-deinit-symmetry FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: add `pub fn deinit(self: *Self) void` that frees the owned resources.\n", .{});
    return error.CheckFailed;
}

// spec: Constructor Hygiene - Requires structs that own an allocator field to declare a pub fn deinit

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
test "analyzeContent: a per-call allocator param is not an owned field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // clone takes an allocator per call but owns none — must not require deinit.
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\pub const Point = struct {
        \\    x: f32,
        \\    pub fn clone(self: Point, allocator: std.mem.Allocator) !Point {
        \\        _ = allocator;
        \\        return self;
        \\    }
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
