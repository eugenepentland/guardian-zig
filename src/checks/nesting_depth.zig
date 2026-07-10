const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const config_mod = @import("../config.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged(reporter.Violation),
    cfg: config_mod.NestingDepthCfg,
};

// A `{` that does NOT add a control-flow nesting level:
//  - data literals (`.{…}`, `Foo{…}`, `[_]u8{…}`) — declarative data, prev is
//    `.`/identifier/`]`;
//  - switch-prong bodies (`=> {…}`) — the prong inherits the switch's level, so
//    `switch { .a => { … } }` costs one level, not two (Sonar-style).
fn braceAddsNoDepth(prev_tag: std.zig.Token.Tag) bool {
    return switch (prev_tag) {
        .period, .identifier, .r_bracket, .equal_angle_bracket_right => true,
        else => false,
    };
}

// Track, per open brace, whether it counted, so the matching close stays
// balanced even when non-counting braces and real blocks nest inside each other.
const DepthState = struct {
    counted: std.ArrayListUnmanaged(bool) = .empty,
    depth: u32 = 0,
    max_depth: u32 = 0,

    fn openBrace(self: *DepthState, allocator: std.mem.Allocator, prev_tag: std.zig.Token.Tag) !void {
        const skip = braceAddsNoDepth(prev_tag);
        try self.counted.append(allocator, !skip);
        if (skip) return;
        self.depth += 1;
        if (self.depth > self.max_depth) self.max_depth = self.depth;
    }

    fn closeBrace(self: *DepthState) void {
        const was_counted = self.counted.pop() orelse return;
        if (was_counted and self.depth > 0) self.depth -= 1;
    }
};

/// Returns the maximum brace depth observed inside `body_text`. The
/// caller passes the body slice including the outer `{` and `}` from
/// `ast.fnDeclInfos.body_text`. The body's own opening `{` is depth 1;
/// each nested block adds 1.
///
/// Tokenizer-based to skip strings and comments correctly. Allocator failure
/// propagates: returning depth 0 on OOM would fail open (a deeply nested fn
/// would silently pass the cap).
fn maxNestingDepth(allocator: std.mem.Allocator, body_text: []const u8) std.mem.Allocator.Error!u32 {
    const z = try allocator.dupeZ(u8, body_text);
    defer allocator.free(z);
    var tok = std.zig.Tokenizer.init(z);
    var state: DepthState = .{};
    defer state.counted.deinit(allocator);
    var prev_tag: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .l_brace => try state.openBrace(allocator, prev_tag),
            .r_brace => state.closeBrace(),
            else => {},
        }
        prev_tag = t.tag;
    }
    return state.max_depth;
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.fnDeclInfosFromTree(a, t) else try ast.fnDeclInfos(a, entry.content);
    for (fns) |f| {
        const depth = try maxNestingDepth(a, f.body_text);
        if (depth <= ctx.cfg.max_depth) continue;
        try ctx.violations.append(a, .{
            .check = "nesting-depth",
            .file = entry.rel_path,
            .line = f.start_line,
            .message = try std.fmt.allocPrint(
                a,
                "fn {s} reaches nesting depth {d} (cap {d})",
                .{ f.name, depth, ctx.cfg.max_depth },
            ),
            .ratchet_key = try std.fmt.allocPrint(a, "{s}|{s}", .{ entry.rel_path, f.name }),
            .metric = depth,
        });
    }
}

/// Pure-function entry: scans `content` and returns violation lines
/// (allocator-owned). Empty slice = pass.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
    cfg: config_mod.NestingDepthCfg,
) std.mem.Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };
    try visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = content });
    return reporter.flatLines(allocator, violations.items);
}

/// Entry point for the nesting-depth check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.nesting_depth;

    if (!cfg.enabled) {
        ok("nesting-depth disabled by config", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations, .cfg = cfg };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("all functions within nesting depth {d}", .{cfg.max_depth});
        return;
    }

    fail("nesting depth FAILED ({d} fn(s) over depth {d})", .{ violations.items.len, cfg.max_depth });
    for (violations.items) |v| reporter.emit(v);
    print("  fix: extract nested blocks into helper fns, invert conditions to " ++
        "early-return, or raise [nesting_depth] max_depth.\n", .{});
    return error.CheckFailed;
}

// spec: Nesting Depth - Caps brace-nesting depth inside fn bodies

test "maxNestingDepth flat body is depth 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 1), try maxNestingDepth(arena.allocator(), "{ return; }"));
}

test "maxNestingDepth nested if reaches 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u32, 2), try maxNestingDepth(arena.allocator(), "{ if (x) { return; } }"));
}
test "maxNestingDepth ignores data-literal braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A nested anonymous struct literal is data, not control-flow nesting.
    try std.testing.expectEqual(@as(u32, 1), try maxNestingDepth(a, "{ const c = .{ .a = .{ .b = 1 } }; }"));
    // Typed struct/array literals likewise don't add depth.
    try std.testing.expectEqual(@as(u32, 1), try maxNestingDepth(a, "{ const c = Foo{ .a = 1 }; }"));
    // Control-flow still counts through/around a literal.
    try std.testing.expectEqual(@as(u32, 2), try maxNestingDepth(a, "{ if (x) { const c = .{ .a = 1 }; } }"));
}

test "maxNestingDepth deeply nested reaches 4" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = "{ if (a) { while (b) { for (c) |_| { return; } } } }";
    try std.testing.expectEqual(@as(u32, 4), try maxNestingDepth(arena.allocator(), body));
}

test "maxNestingDepth: switch-prong body inherits the switch level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // body(1) -> switch(2) -> prong `{` inherits 2 -> inner if(3). Without the
    // prong discount this would read as depth 4.
    const body = "{ switch (x) { .a => { if (y) { z(); } }, else => {} } }";
    try std.testing.expectEqual(@as(u32, 3), try maxNestingDepth(a, body));
}

test "maxNestingDepth ignores braces in strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const depth = try maxNestingDepth(arena.allocator(), "{ const s = \"{{nope}}\"; _ = s; }");
    try std.testing.expectEqual(@as(u32, 1), depth);
}

test "visit flags fn over depth cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_depth = 2 },
    };
    const content =
        \\fn deep() void {
        \\    if (true) {
        \\        if (false) {
        \\            return;
        \\        }
        \\    }
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows fn at the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_depth = 3 },
    };
    const content =
        \\fn ok_fn() void {
        \\    if (true) {
        \\        if (false) {
        \\            return;
        \\        }
        \\    }
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
