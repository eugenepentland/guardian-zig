const std = @import("std");
const walk = @import("../walk.zig");
const ast = @import("../ast/parser.zig");

pub const ModuleInfo = struct {
    name: []const u8,
    pub_fns: []const []const u8,
};

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    modules: *std.ArrayListUnmanaged(ModuleInfo),
};

fn collectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const fns = extractPubFns(ctx.allocator, entry.content);
    if (fns.len == 0) return;
    const stem = if (std.mem.endsWith(u8, entry.rel_path, ".zig"))
        entry.rel_path[0 .. entry.rel_path.len - 4]
    else
        entry.rel_path;
    ctx.modules.append(ctx.allocator, .{
        .name = stem,
        .pub_fns = fns,
    }) catch {};
}

pub fn collectModules(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    prefix: []const u8,
    modules: *std.ArrayListUnmanaged(ModuleInfo),
) !void {
    var ctx: CollectCtx = .{ .allocator = allocator, .modules = modules };
    try walk.walkZigFiles(allocator, dir_path, prefix, .{}, .{ .ctx = &ctx, .visit = collectVisit });
}

pub fn extractPubFns(allocator: std.mem.Allocator, content: []const u8) []const []const u8 {
    const pubs = ast.pubFns(allocator, content) catch return &.{};
    var fns: std.ArrayListUnmanaged([]const u8) = .empty;
    for (pubs) |p| {
        if (std.mem.eql(u8, p.name, "main")) continue;
        if (std.mem.eql(u8, p.name, "build")) continue;
        fns.append(allocator, p.name) catch {};
    }
    return fns.toOwnedSlice(allocator) catch &.{};
}

pub fn generateSpecContent(allocator: std.mem.Allocator, modules: []const ModuleInfo) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(allocator, "# Project Specification\n\n") catch {};
    buf.appendSlice(allocator, "## Overview\n\nDescribe the project here.\n\n") catch {};

    for (modules) |mod| {
        if (mod.pub_fns.len == 0) continue;
        const section = std.fmt.allocPrint(allocator, "## {s}\n\n", .{mod.name}) catch continue;
        buf.appendSlice(allocator, section) catch {};
        // List functions as hints, user replaces with real behavior descriptions
        buf.appendSlice(allocator, "Public functions: ") catch {};
        for (mod.pub_fns, 0..) |fn_name, i| {
            if (i > 0) buf.appendSlice(allocator, ", ") catch {};
            buf.appendSlice(allocator, fn_name) catch {};
        }
        buf.appendSlice(allocator, "\n\n") catch {};
        // Placeholder behavior for user to fill in
        buf.appendSlice(allocator, "- TODO: describe behaviors\n\n") catch {};
    }

    return buf.toOwnedSlice(allocator) catch "";
}

test "extractPubFns finds public functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content =
        \\const std = @import("std");
        \\
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
        \\fn private_helper() void {}
        \\
        \\pub fn multiply(x: i32, y: i32) i32 {
        \\    return x * y;
        \\}
    ;

    const fns = extractPubFns(a, content);
    try std.testing.expectEqual(@as(usize, 2), fns.len);
    try std.testing.expectEqualStrings("add", fns[0]);
    try std.testing.expectEqualStrings("multiply", fns[1]);
}

test "extractPubFns skips main and build" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content =
        \\pub fn main() !void {}
        \\pub fn build(b: *std.Build) void {}
        \\pub fn realFunction() void {}
    ;

    const fns = extractPubFns(a, content);
    try std.testing.expectEqual(@as(usize, 1), fns.len);
    try std.testing.expectEqualStrings("realFunction", fns[0]);
}

test "extractPubFns ignores non-function pub declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content =
        \\pub const MyType = struct {};
        \\pub var global: i32 = 0;
        \\pub fn actual() void {}
    ;

    const fns = extractPubFns(a, content);
    try std.testing.expectEqual(@as(usize, 1), fns.len);
    try std.testing.expectEqualStrings("actual", fns[0]);
}
