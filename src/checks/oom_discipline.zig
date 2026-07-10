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

/// Allocating methods whose `error.OutOfMemory` must not be silently dropped.
fn isAllocMethod(name: []const u8) bool {
    const names = [_][]const u8{
        "append",   "appendSlice",  "appendNTimes",        "allocPrint", "dupe",
        "dupeZ",    "toOwnedSlice", "alloc",               "create",     "put",
        "getOrPut", "insert",       "ensureTotalCapacity", "writer",
    };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

// Detects `<alloc-call>() catch <swallow>` where the handler drops the error
// instead of propagating it (`continue`/`break`/`return null`/`return;`/
// `return <literal>`). `catch return err` / `catch return error.X` propagate
// and are fine. Method name is tracked per open paren so we know what the
// caught call was.
const ScanState = struct {
    methods: std.ArrayListUnmanaged([]const u8) = .empty,
    last_closed: []const u8 = "",
    prev_tag: std.zig.Token.Tag = .invalid,
    prev_ident: []const u8 = "",
    // After a `catch` on an alloc call: 0 = not armed, 1 = seeking handler
    // (skipping an optional `|payload|`), 2 = saw `return`, inspect next token.
    phase: u8 = 0,

    fn deinit(self: *ScanState, a: Allocator) void {
        self.methods.deinit(a);
    }
};

/// The token right after `return` means a dropped default (not `return err`):
/// `;`, a literal, `&.{}`/`.{}` (`&`/`.`), or the identifier `null`.
fn isDroppedReturnTok(t: std.zig.Token, z: [:0]const u8) bool {
    return switch (t.tag) {
        .semicolon, .string_literal, .number_literal, .ampersand, .period => true,
        .identifier => std.mem.eql(u8, z[t.loc.start..t.loc.end], "null"),
        else => false,
    };
}

fn scan(ctx: *ScanCtx, z: [:0]const u8) Allocator.Error!void {
    var tok = std.zig.Tokenizer.init(z);
    var s: ScanState = .{};
    defer s.deinit(ctx.allocator);
    var catch_line: u32 = 0;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag == .keyword_catch) catch_line = lineOf(z, t.loc.start);
        try step(ctx, &s, t, z, catch_line);
        s.prev_tag = t.tag;
        if (t.tag == .identifier) s.prev_ident = z[t.loc.start..t.loc.end];
    }
}

fn step(ctx: *ScanCtx, s: *ScanState, t: std.zig.Token, z: [:0]const u8, catch_line: u32) Allocator.Error!void {
    if (s.phase != 0) return handleHandler(ctx, s, t, z, catch_line);
    switch (t.tag) {
        .l_paren => try s.methods.append(ctx.allocator, if (s.prev_tag == .identifier) s.prev_ident else ""),
        .r_paren => s.last_closed = if (s.methods.items.len > 0) s.methods.pop().? else "",
        .keyword_catch => if (s.prev_tag == .r_paren and isAllocMethod(s.last_closed)) {
            s.phase = 1;
        },
        else => {},
    }
}

/// Inspects the tokens after an armed `catch`: skip a `|payload|`, then flag if
/// the handler drops the error (`continue`/`break`/`return <default>`).
fn handleHandler(
    ctx: *ScanCtx,
    s: *ScanState,
    t: std.zig.Token,
    z: [:0]const u8,
    catch_line: u32,
) Allocator.Error!void {
    if (s.phase == 2) {
        if (isDroppedReturnTok(t, z)) try record(ctx, catch_line);
        s.phase = 0;
        return;
    }
    switch (t.tag) {
        .pipe, .identifier, .comma => {}, // `|e|` payload — keep seeking
        .keyword_return => s.phase = 2,
        .keyword_continue, .keyword_break => {
            try record(ctx, catch_line);
            s.phase = 0;
        },
        else => s.phase = 0,
    }
}

fn record(ctx: *ScanCtx, line: u32) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: allocation error dropped (OutOfMemory conflated with absence) — propagate it",
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

/// Entry point for the oom-discipline check (opt-in).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg;
    if (!cfg.oom_discipline.enabled) {
        ok("oom-discipline disabled by config (opt-in via [oom_discipline] enabled = true)", .{});
        return;
    }

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .rel_path = "", .violations = &violations };
    const opts: walk.Visitor = .{ .ctx = &ctx, .visit = visit };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, opts);

    if (violations.items.len == 0) {
        ok("no dropped allocation errors found", .{});
        return;
    }
    fail("oom-discipline FAILED ({d} dropped allocation error(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: propagate with `try` / `catch return error.OutOfMemory`," ++
        " or handle OOM explicitly (don't conflate it with 'not found').\n", .{});
    return error.CheckFailed;
}

// spec: Oom Discipline - Flags allocation errors dropped by a swallowing catch

test "flags swallowed alloc errors, allows propagation and non-alloc catches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Swallows on allocating calls → flagged (append/allocPrint/getOrPut).
    const bad = try analyzeContent(a, "src/x.zig",
        \\fn f(al: std.mem.Allocator, list: *L, m: *M) void {
        \\    list.append(al, 1) catch return;
        \\    _ = std.fmt.allocPrint(al, "{d}", .{1}) catch continue;
        \\    _ = m.getOrPut(al, "k") catch return null;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), bad.len);

    // Propagating the error, or catching a non-alloc call → not flagged.
    const good = try analyzeContent(a, "src/x.zig",
        \\fn g(al: std.mem.Allocator, list: *L) !void {
        \\    try list.append(al, 1);
        \\    list.append(al, 2) catch return error.OutOfMemory;
        \\    parseThing() catch return null;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), good.len);
}
