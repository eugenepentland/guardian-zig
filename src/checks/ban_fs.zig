const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

// spec: Hidden Dependency Bans - Rejects std.fs I/O calls outside infra/fs

const rules = [_]helper.Rule{
    .{ .chain = &.{ "std", "fs", "cwd" }, .display = "std.fs.cwd" },
    .{ .chain = &.{ "std", "fs", "openFileAbsolute" }, .display = "std.fs.openFileAbsolute" },
    .{ .chain = &.{ "std", "fs", "createFileAbsolute" }, .display = "std.fs.createFileAbsolute" },
    .{ .chain = &.{ "std", "fs", "openDirAbsolute" }, .display = "std.fs.openDirAbsolute" },
    .{ .chain = &.{ "std", "fs", "deleteFileAbsolute" }, .display = "std.fs.deleteFileAbsolute" },
    .{ .chain = &.{ "std", "fs", "deleteDirAbsolute" }, .display = "std.fs.deleteDirAbsolute" },
    .{ .chain = &.{ "std", "fs", "renameAbsolute" }, .display = "std.fs.renameAbsolute" },
    .{ .chain = &.{ "std", "fs", "selfExeDirPath" }, .display = "std.fs.selfExeDirPath" },
    .{ .chain = &.{ "std", "fs", "realpath" }, .display = "std.fs.realpath" },
};

// Guardian itself is a static analyzer that walks filesystems by design,
// so its own infrastructure files are exempt. Downstream consumers should
// keep just `src/infra/fs*` and route filesystem access through that port.
const opts: helper.ScanOpts = .{
    .rules = &rules,
    .allowed_paths = &.{
        "src/infra/fs*",
        "infra/fs*",
        // Guardian-internal exemptions:
        "src/walk*",
        "src/cache*",
        "src/snapshot*",
        "src/snapshot_helper*",
        "src/config*",
        "src/spec/parser*",
        "src/checks/spec_init*",
        "src/checks/dead_pub*",
        "src/testing/*",
        "src/baseline.zig",
    },
    .fix_hint = "inject a Filesystem port from infra/fs and call its read/write methods.",
};

/// Pure-function entry: scans `content` for banned `std.fs.*` I/O calls.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the ban-fs check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx, "ban-fs", opts);
}

test "analyzeContent flags std.fs.cwd outside infra" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/domain/foo.zig",
        \\fn r() !void { _ = try std.fs.cwd().openFile("a", .{}); }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows std.fs.cwd inside infra/fs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/infra/fs.zig",
        \\pub fn open() !void { _ = try std.fs.cwd().openFile("a", .{}); }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
