const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const factory_names = [_][]const u8{
    "getDefault",
    "getInstance",
    "getShared",
    "shared",
    "singleton",
    "instance",
    "global",
};

// Architectural defaults: factory/lookup patterns are legitimate in the
// composition root (main/wiring/cli). Guardian's own build integration and
// reporter singleton are exempted via [[allow]] in Guardian's guardian.toml.
const allowed_paths = [_][]const u8{
    "src/main*",
    "src/wiring*",
    "src/cli/*",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: scans `content` for `Foo.getDefault()` / `.singleton()` style calls.
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

fn matchFactory(text: []const u8) ?[]const u8 {
    for (factory_names) |fn_name| {
        if (std.mem.eql(u8, text, fn_name)) return fn_name;
    }
    return null;
}

const ScanState = struct {
    prev_was_period: bool = false,
    pending_factory: ?[]const u8 = null,
    pending_byte: usize = 0,
};

fn onIdentifier(state: *ScanState, text: []const u8, start: usize) void {
    if (state.prev_was_period) {
        if (matchFactory(text)) |fn_name| {
            state.pending_factory = fn_name;
            state.pending_byte = start;
        }
    }
    state.prev_was_period = false;
}

fn onLParen(ctx: *ScanCtx, z: []const u8, state: *ScanState) Allocator.Error!void {
    if (state.pending_factory) |fn_name| {
        try report(ctx, z, state.pending_byte, fn_name);
    }
    state.pending_factory = null;
    state.prev_was_period = false;
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const z = try ctx.allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var state: ScanState = .{};

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .period => {
                state.prev_was_period = true;
                state.pending_factory = null;
            },
            .identifier => onIdentifier(&state, z[t.loc.start..t.loc.end], t.loc.start),
            .l_paren => try onLParen(ctx, z, &state),
            else => {
                state.pending_factory = null;
                state.prev_was_period = false;
            },
        }
    }
}

fn report(ctx: *ScanCtx, z: []const u8, byte: usize, fn_name: []const u8) Allocator.Error!void {
    const line = lineOf(z, byte);
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: static factory call '.{s}()' (singleton/service-locator pattern)",
        .{ ctx.rel_path, line, fn_name },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    extra_allowed: []const []const u8 = &.{},
};

/// True if `rel_path` matches a compiled architectural default or a configured
/// [[allow]] path for this check.
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (allowed_paths) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.extra_allowed)) return;
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the static-factory-ban check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .extra_allowed = ctx.cfg.extraAllowed("static-factory-ban"),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("static-factory-ban: no static factory calls in business logic", .{});
        return;
    }
    reporter.fail("static-factory-ban FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: take the dependency as a constructor parameter; let main/wiring assemble it.\n", .{});
    return error.CheckFailed;
}

// spec: Constructor Hygiene - Rejects static factory / singleton patterns in business logic

test "analyzeContent flags getDefault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/domain/x.zig",
        \\fn use() void { _ = Database.getDefault(); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags singleton call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/domain/x.zig",
        \\fn use() void { _ = Logger.singleton(); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows getDefault inside main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/main.zig",
        \\pub fn main() !void { _ = Database.getDefault(); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores non-factory method calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn use(db: Database) void { _ = db.query("x"); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
