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
    violations: *std.ArrayList([]const u8),
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
    methods: std.ArrayList([]const u8) = .empty,
    last_closed: []const u8 = "",
    prev_tag: std.zig.Token.Tag = .invalid,
    prev_ident: []const u8 = "",
    // After a `catch` on an alloc call: 0 = not armed, 1 = seeking handler
    // (skipping an optional `|payload|`), 2 = saw `return`, inspect next token.
    phase: u8 = 0,
    // Set while inside the handler's `|payload|` capture, and the captured name
    // once seen — so `catch |e| return e` (propagation) is not mistaken for a
    // dropped `catch return <expr>`.
    in_capture: bool = false,
    payload: []const u8 = "",

    fn deinit(self: *ScanState, a: Allocator) void {
        self.methods.deinit(a);
    }
};

/// True when the token right after `return` *propagates* the caught error
/// rather than dropping it: `return error.X` (the `error` keyword) or
/// `return <payload>` where `<payload>` is the `|e|` capture name. Everything
/// else — `;`, a literal, `null`, `.{}`/`&.{}`, or any other identifier/expr
/// like `return c` / `return list.items` — is a dropped default.
fn isPropagatedReturn(t: std.zig.Token, z: [:0]const u8, payload: []const u8) bool {
    return switch (t.tag) {
        .keyword_error => true,
        .identifier => payload.len > 0 and std.mem.eql(u8, z[t.loc.start..t.loc.end], payload),
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
            s.in_capture = false;
            s.payload = "";
        },
        else => {},
    }
}

/// Inspects the tokens after an armed `catch`: record the `|payload|` capture
/// name, then flag if the handler drops the error (`continue`/`break`/`return
/// <default>`). A bare `catch <expr>` value handler (not a control keyword)
/// disarms without flagging.
fn handleHandler(
    ctx: *ScanCtx,
    s: *ScanState,
    t: std.zig.Token,
    z: [:0]const u8,
    catch_line: u32,
) Allocator.Error!void {
    if (s.phase == 2) {
        if (!isPropagatedReturn(t, z, s.payload)) try record(ctx, catch_line);
        s.phase = 0;
        return;
    }
    switch (t.tag) {
        .pipe => s.in_capture = !s.in_capture, // open/close the `|payload|`
        .identifier => if (s.in_capture) {
            if (s.payload.len == 0) s.payload = z[t.loc.start..t.loc.end];
        } else {
            // A value-expression handler (`catch fallback`) — not a drop.
            s.phase = 0;
        },
        .comma => {}, // keep seeking (defensive; a capture has no comma)
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
    var violations: std.ArrayList([]const u8) = .empty;
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

    var violations: std.ArrayList([]const u8) = .empty;
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

// spec: Oom Discipline - Flags a dropped allocation error returned as a value expression
test "flags catch-return of a value expression (identifier or field access)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Returning a plain identifier or a field — not the error — drops OOM just
    // like `return 0`; the old check only caught literals/null, these are new.
    const out = try analyzeContent(a, "src/x.zig",
        \\fn f(al: std.mem.Allocator, list: *L, self: *S) void {
        \\    const c: u32 = 0;
        \\    list.append(al, 1) catch return c;
        \\    _ = list.toOwnedSlice(al) catch return self.cached;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), out.len);
}

// spec: Oom Discipline - Allows returning the caught error payload or an error value
test "allows catch-return of the error payload or an error value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `catch |e| return e` and `catch return error.X` both re-raise the error.
    const out = try analyzeContent(a, "src/x.zig",
        \\fn g(al: std.mem.Allocator, list: *L) !void {
        \\    list.append(al, 1) catch |e| return e;
        \\    list.append(al, 2) catch return error.OutOfMemory;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
