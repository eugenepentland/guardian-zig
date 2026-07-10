//! allocator-hygiene check: reject a hardcoded global allocator
//! (page_allocator, smp_allocator, a GeneralPurposeAllocator literal, …)
//! outside `pub fn main` and test blocks — allocators belong in the wiring
//! layer and get threaded down. A `// allocator-ok` comment waives a site.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
};

const ChainState = enum {
    none,
    saw_std,
    after_std_dot,
    saw_std_heap,
    after_std_heap_dot,
    saw_std_testing,
    after_std_testing_dot,
};

fn isForbiddenHeap(name: []const u8) bool {
    const forbidden = [_][]const u8{
        "page_allocator",
        "c_allocator",
        "smp_allocator",
        "GeneralPurposeAllocator",
    };
    for (forbidden) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

// Loop-local mutable state for the token scan in `visit`. Bundled so the
// per-tag handlers can be private helpers instead of nested blocks.
const ScanState = struct {
    depth: u32 = 0,
    permissive: std.ArrayList(u32) = .empty,
    pending_permissive: bool = false,
    saw_fn: bool = false,
    // Previous token, so an `error{...}` set in `pub fn main()`'s return type
    // doesn't steal the permissive scope from the actual body brace.
    prev_tag: std.zig.Token.Tag = .invalid,
    chain: ChainState = .none,
    chain_start: usize = 0,
};

fn handleLBrace(a: std.mem.Allocator, state: *ScanState) !void {
    state.depth += 1;
    // Skip an `error{...}` return-set brace so the permissive scope
    // latches onto the real body brace instead.
    if (state.pending_permissive and state.prev_tag != .keyword_error) {
        try state.permissive.append(a, state.depth);
        state.pending_permissive = false;
    }
    state.chain = .none;
}

fn handleRBrace(state: *ScanState) void {
    const items = state.permissive.items;
    if (items.len > 0 and items[items.len - 1] == state.depth) {
        _ = state.permissive.pop();
    }
    if (state.depth > 0) state.depth -= 1;
    state.chain = .none;
}

// Advance the `std`-chain state machine for an identifier and, when a
// forbidden chain completes outside a permissive scope, record a violation.
fn handleIdentifier(ctx: *ScanCtx, entry: walk.FileEntry, state: *ScanState, loc: std.zig.Token.Loc) !void {
    const text = entry.content[loc.start..loc.end];
    if (state.saw_fn) {
        if (std.mem.eql(u8, text, "main")) state.pending_permissive = true;
        state.saw_fn = false;
    }
    const in_permissive = state.permissive.items.len > 0;
    switch (state.chain) {
        .none, .saw_std, .saw_std_heap, .saw_std_testing => {
            if (std.mem.eql(u8, text, "std")) {
                state.chain_start = loc.start;
                state.chain = .saw_std;
            } else state.chain = .none;
        },
        .after_std_dot => state.chain = afterStdDot(text),
        .after_std_heap_dot => {
            const hit = !in_permissive and isForbiddenHeap(text);
            if (hit and !suppressed(entry.content, state.chain_start)) try appendHeap(ctx, entry, state, text);
            state.chain = .none;
        },
        .after_std_testing_dot => {
            const hit = !in_permissive and std.mem.eql(u8, text, "allocator");
            if (hit and !suppressed(entry.content, state.chain_start)) try appendTesting(ctx, entry, state);
            state.chain = .none;
        },
    }
}

fn afterStdDot(text: []const u8) ChainState {
    if (std.mem.eql(u8, text, "heap")) return .saw_std_heap;
    if (std.mem.eql(u8, text, "testing")) return .saw_std_testing;
    return .none;
}

fn appendHeap(ctx: *ScanCtx, entry: walk.FileEntry, state: *ScanState, text: []const u8) !void {
    const a = ctx.allocator;
    const line = lineOf(entry.content, state.chain_start);
    const msg = try std.fmt.allocPrint(
        a,
        "{s}:{d}: hardcoded std.heap.{s} outside main/test",
        .{ entry.rel_path, line, text },
    );
    try ctx.violations.append(a, msg);
}

fn appendTesting(ctx: *ScanCtx, entry: walk.FileEntry, state: *ScanState) !void {
    const a = ctx.allocator;
    const line = lineOf(entry.content, state.chain_start);
    const msg = try std.fmt.allocPrint(
        a,
        "{s}:{d}: hardcoded std.testing.allocator outside test block",
        .{ entry.rel_path, line },
    );
    try ctx.violations.append(a, msg);
}

/// True when a `// allocator-ok` justification comment sits on the offending
/// line or the line directly above it. The tokenizer drops comments, so this
/// re-reads the raw source around the flagged byte. Lets a deliberate
/// process-lifetime store (e.g. an HTTP server's page_allocator) opt out with a
/// documented reason instead of forcing a project-wide baseline.
fn suppressed(content: []const u8, byte: usize) bool {
    const marker = "// allocator-ok";
    const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..byte], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, content, byte, '\n') orelse content.len;
    if (std.mem.indexOf(u8, content[line_start..line_end], marker) != null) return true;
    if (line_start == 0) return false;
    const prev_end = line_start - 1;
    const prev_start = if (std.mem.lastIndexOfScalar(u8, content[0..prev_end], '\n')) |i| i + 1 else 0;
    return std.mem.indexOf(u8, content[prev_start..prev_end], marker) != null;
}

fn advanceOnPeriod(chain: ChainState) ChainState {
    return switch (chain) {
        .saw_std => .after_std_dot,
        .saw_std_heap => .after_std_heap_dot,
        .saw_std_testing => .after_std_testing_dot,
        else => .none,
    };
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    // entry.content is already null-terminated by the walker.
    const z = entry.content;
    var tok = std.zig.Tokenizer.init(z);

    // Permissive-scope tracking: when we enter a `test {…}` block or a
    // `pub fn main(…) … {…}`, push the current brace depth. While the
    // stack is non-empty, the file is exempt. The Zig tokenizer skips
    // string literals and comments, so forbidden text inside strings or
    // doc-comments never reaches us.
    var state: ScanState = .{};
    defer state.permissive.deinit(a);

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        defer state.prev_tag = t.tag;

        switch (t.tag) {
            .keyword_test => {
                state.pending_permissive = true;
                state.saw_fn = false;
                state.chain = .none;
            },
            .keyword_fn => {
                state.saw_fn = true;
                state.chain = .none;
            },
            .l_brace => try handleLBrace(a, &state),
            .r_brace => handleRBrace(&state),
            .identifier => try handleIdentifier(ctx, entry, &state, t.loc),
            .period => state.chain = advanceOnPeriod(state.chain),
            else => {
                // Don't clear `pending_permissive` here — it must survive
                // intermediate tokens (paren list, return type, the string
                // literal after `test`) and only get consumed by the next
                // `l_brace`.
                state.chain = .none;
                state.saw_fn = false;
            },
        }
    }
}

const lineOf = @import("../text.zig").lineOf;

/// Entry point for the allocator-hygiene check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no hardcoded global allocators in production code", .{});
        return;
    }

    fail("allocator hygiene FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: thread the allocator through as a parameter instead of hardcoding a global.\n", .{});
    return error.CheckFailed;
}

// spec: Allocator Hygiene - Rejects hardcoded global allocators outside test blocks and pub fn main
// spec: Allocator Hygiene - Honors a // allocator-ok justification comment to suppress a site

test "visit honors an allocator-ok justification comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    // Comment on the line above, and same-line — both suppress.
    const content =
        \\fn server() void {
        \\    // allocator-ok: process-lifetime store, freed at exit
        \\    const g = std.heap.page_allocator;
        \\    const h = std.heap.c_allocator; // allocator-ok: same reason
        \\    _ = g;
        \\    _ = h;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit flags page_allocator outside main and test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper() void {
        \\    const v = std.heap.page_allocator;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows page_allocator inside pub fn main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn main() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    _ = arena;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
test "visit allows page_allocator in main with an explicit error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    // The error{...} return set used to consume the permissive scope, leaving
    // the real body non-permissive and flagging page_allocator.
    const content =
        \\pub fn main() error{Oops}!void {
        \\    const p = std.heap.page_allocator;
        \\    _ = p;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit allows testing.allocator inside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\test "uses testing allocator" {
        \\    var x = std.testing.allocator;
        \\    _ = x;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit flags testing.allocator outside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper() void {
        \\    const v = std.testing.allocator;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit ignores std.heap.ArenaAllocator (not a forbidden chain)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper(parent: std.mem.Allocator) void {
        \\    var arena = std.heap.ArenaAllocator.init(parent);
        \\    _ = arena;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit ignores forbidden chain inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "const s = \"std.heap.page_allocator\";\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit flags GeneralPurposeAllocator outside main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn helper() void {
        \\    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
        \\    _ = gpa;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit handles non-main fn followed by allocator pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn run() !void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    _ = arena;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
