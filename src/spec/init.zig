const std = @import("std");

pub const ModuleInfo = struct {
    name: []const u8,
    pub_fns: []const []const u8,
};

pub fn collectModules(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    prefix: []const u8,
    modules: *std.ArrayListUnmanaged(ModuleInfo),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{entry.name});

        switch (entry.kind) {
            .directory => {
                const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                try collectModules(allocator, sub_path, rel, modules);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                const fns = extractPubFns(allocator, content);
                if (fns.len > 0) {
                    const stem = if (std.mem.endsWith(u8, rel, ".zig")) rel[0 .. rel.len - 4] else rel;
                    modules.append(allocator, .{
                        .name = stem,
                        .pub_fns = fns,
                    }) catch {};
                }
            },
            else => {},
        }
    }
}

pub fn extractPubFns(allocator: std.mem.Allocator, content: []const u8) []const []const u8 {
    var fns: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, "pub fn ")) {
            const after = trimmed[7..];
            if (std.mem.indexOfScalar(u8, after, '(')) |paren| {
                const name = after[0..paren];
                if (std.mem.eql(u8, name, "main")) continue;
                if (std.mem.eql(u8, name, "build")) continue;
                fns.append(allocator, name) catch {};
            }
        }
    }
    return fns.toOwnedSlice(allocator) catch &.{};
}

pub fn generateSpecContent(allocator: std.mem.Allocator, modules: []const ModuleInfo) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(allocator, "# Project Specification\n\n") catch {};
    buf.appendSlice(allocator, "## Overview\n\nDescribe the project here.\n\n") catch {};

    for (modules) |mod| {
        if (mod.pub_fns.len == 0) continue;
        const section = std.fmt.allocPrint(allocator, "## {s}\n", .{mod.name}) catch continue;
        buf.appendSlice(allocator, section) catch {};
        for (mod.pub_fns) |fn_name| {
            const behavior = std.fmt.allocPrint(allocator, "- {s} works correctly\n", .{fn_name}) catch continue;
            buf.appendSlice(allocator, behavior) catch {};
        }
        buf.appendSlice(allocator, "\n") catch {};
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
