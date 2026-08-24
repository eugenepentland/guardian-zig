//! Cross-process exclusion for operations that write checked-in Guardian
//! metadata or temporarily rewrite source files. The lock is an advisory
//! kernel lock on a persistent pid file under `.guardian/cache`, so unrelated
//! read-only gates never contend and every process exit releases ownership.

const std = @import("std");
const fs = @import("fs.zig");

const Allocator = std.mem.Allocator;

pub const leaf = ".guardian/cache/writer.lock";
pub const AcquireError = fs.Dir.MakeError || fs.File.OpenError || fs.File.WriteError ||
    fs.File.SetLengthError || Allocator.Error || error{ Busy, LockRecordTooLong };

/// An acquired writer lock. Ownership is the open file description, not the
/// path, so no unlink/recreate takeover race exists.
pub const Lock = struct {
    allocator: Allocator,
    path: []const u8,
    file: ?fs.File,

    fn release(self: *Lock) void {
        const file = self.file orelse return;
        self.file = null;
        file.close();
    }

    /// Releases the lock and its owned path storage. Safe to call once on every
    /// successfully acquired lock, including after an earlier explicit release.
    pub fn deinit(self: *Lock) void {
        self.release();
        self.allocator.free(self.path);
    }
};

/// Acquires the project writer lock. A live owner returns `error.Busy`; kernel
/// ownership disappears automatically on crash, so an empty, malformed, stale,
/// or PID-reused record cannot strand the project.
pub fn acquire(allocator: Allocator, project_dir: []const u8) AcquireError!Lock {
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/.guardian/cache", .{project_dir});
    defer allocator.free(cache_dir);
    try fs.cwd().makePath(cache_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, leaf });
    errdefer allocator.free(path);
    const file = fs.cwd().createFile(path, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.Busy,
        else => return err,
    };
    errdefer file.close();
    try file.setLength(0);
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{std.posix.system.getpid()}) catch return error.LockRecordTooLong;
    try file.writeAll(text);
    return .{ .allocator = allocator, .path = path, .file = file };
}

// spec: Transactional Metadata - Excludes concurrent metadata writers and recovers a dead pid lock

test "writer lock excludes another writer and a stale pid file never strands it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = "zig-cache/writer-lock";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};

    var first = try acquire(allocator, dir);
    defer first.deinit();
    try std.testing.expectError(error.Busy, acquire(allocator, dir));
    first.release();
    try fs.cwd().writeFile(.{ .sub_path = dir ++ "/.guardian/cache/writer.lock", .data = "2147483647\n" });
    var recovered = try acquire(allocator, dir);
    defer recovered.deinit();
}

test "writer lock repairs an empty crash-window record after acquiring its kernel lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir = "zig-cache/writer-lock-malformed";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir ++ "/.guardian/cache");
    try fs.cwd().writeFile(.{ .sub_path = dir ++ "/.guardian/cache/writer.lock", .data = "" });
    var recovered = try acquire(allocator, dir);
    defer recovered.deinit();
    const raw = try fs.cwd().readFileAlloc(allocator, dir ++ "/.guardian/cache/writer.lock", 128);
    try std.testing.expect(std.mem.trim(u8, raw, &std.ascii.whitespace).len > 0);
}
