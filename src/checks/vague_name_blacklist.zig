const std = @import("std");
const ast = @import("../ast/parser.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// spec: Tier 2 Anti-patterns - Rejects vague identifier names on public declarations

const blacklist = [_][]const u8{
    "tmp",
    "data",
    "info",
    "obj",
    "foo",
    "bar",
    "baz",
    "mgr",
    "Helper",
    "Util",
    "Manager",
    "Processor",
    "Handler",
    "Wrapper",
};

/// Pure-function entry: scans `content` for pub fn / pub const names
/// matching the blacklist.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fns = ast.pubFns(a, content) catch return violations.toOwnedSlice(allocator);
    for (fns) |f| {
        if (matches(f.name)) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}: pub fn '{s}' uses a vague name",
                .{ rel_path, f.name },
            );
            try violations.append(allocator, msg);
        }
    }

    const consts = ast.pubConsts(a, content) catch return violations.toOwnedSlice(allocator);
    for (consts) |c| {
        if (matches(c.name)) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}: pub const '{s}' uses a vague name",
                .{ rel_path, c.name },
            );
            try violations.append(allocator, msg);
        }
    }

    return violations.toOwnedSlice(allocator);
}

fn matches(name: []const u8) bool {
    for (blacklist) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeContent(ctx.allocator, entry.rel_path, entry.content);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
}

/// Entry point for the vague-name-blacklist check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{ .allocator = allocator, .violations = &violations };
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{ctx.project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("vague-name-blacklist: every pub identifier names something concrete", .{});
        return;
    }
    reporter.fail("vague-name-blacklist FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: rename to describe what the value/fn represents in this domain.\n", .{});
    return error.CheckFailed;
}

test "analyzeContent flags pub fn named Manager" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\/// Vague name.
        \\pub const Manager = struct { x: u32 };
    );
    try std.testing.expectGreaterThanOrEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows specific names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\/// Specific name.
        \\pub const HttpClient = struct { x: u32 };
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
