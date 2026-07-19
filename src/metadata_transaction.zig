//! Transaction guard for checked-in `.guardian` metadata. A real gate may
//! auto-lower several baselines in parallel before a later check fails; this
//! module snapshots the non-cache tree and restores it on any red run so a
//! failed analysis never leaves partial acceptance or pruning behind.

const std = @import("std");
const walk = @import("walk.zig");

const Allocator = std.mem.Allocator;

const Original = struct {
    rel_path: []const u8,
    content: []const u8,
};

const CollectCtx = struct {
    allocator: Allocator,
    originals: *std.ArrayList(Original),
};

fn collectOriginal(raw_ctx: *anyopaque, entry: walk.FileEntry) Allocator.Error!void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    try ctx.originals.append(ctx.allocator, .{
        .rel_path = try ctx.allocator.dupe(u8, entry.rel_path),
        .content = try ctx.allocator.dupe(u8, entry.content),
    });
}

const PathCtx = struct {
    allocator: Allocator,
    paths: *std.ArrayList([]const u8),
};

fn collectPath(raw_ctx: *anyopaque, entry: walk.FileEntry) Allocator.Error!void {
    const ctx: *PathCtx = @ptrCast(@alignCast(raw_ctx));
    try ctx.paths.append(ctx.allocator, try ctx.allocator.dupe(u8, entry.rel_path));
}

/// Captured non-cache `.guardian` state for one real `all` pass.
pub const Transaction = struct {
    storage: std.heap.ArenaAllocator,
    project_dir: []const u8,
    originals: []const Original,

    /// Releases the captured path/content table. The project directory is
    /// copied into the transaction arena with the captured file state.
    pub fn deinit(self: *Transaction) void {
        self.storage.deinit();
    }

    /// Captures every metadata file except `.guardian/cache/**`. A missing
    /// `.guardian` directory is an empty, valid starting state.
    pub fn begin(allocator: Allocator, project_dir: []const u8) walk.WalkError!Transaction {
        var storage = std.heap.ArenaAllocator.init(allocator);
        errdefer storage.deinit();
        const a = storage.allocator();
        var originals: std.ArrayList(Original) = .empty;
        var ctx: CollectCtx = .{ .allocator = a, .originals = &originals };
        const root = try metadataRoot(a, project_dir);
        try walk.walkZigFiles(a, root, metadataWalkOpts(), .{
            .ctx = @ptrCast(&ctx),
            .visit = collectOriginal,
        });
        const project_copy = try a.dupe(u8, project_dir);
        const owned_originals = try originals.toOwnedSlice(a);
        return .{
            .storage = storage,
            .project_dir = project_copy,
            .originals = owned_originals,
        };
    }

    /// Restores original bytes and removes metadata files created during the
    /// run. Cache/log files are deliberately retained as operational evidence.
    pub fn rollback(self: *Transaction) RollbackError!void {
        const allocator = self.storage.allocator();
        var current: std.ArrayList([]const u8) = .empty;
        var ctx: PathCtx = .{ .allocator = allocator, .paths = &current };
        const root = try metadataRoot(allocator, self.project_dir);
        try walk.walkZigFiles(allocator, root, metadataWalkOpts(), .{
            .ctx = @ptrCast(&ctx),
            .visit = collectPath,
        });

        for (current.items) |rel_path| {
            if (self.had(rel_path)) continue;
            const path = try fullPath(allocator, self.project_dir, rel_path);
            std.fs.cwd().deleteFile(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        for (self.originals) |original| {
            const path = try fullPath(allocator, self.project_dir, original.rel_path);
            var buffer: [4096]u8 = undefined;
            var atomic = try std.fs.cwd().atomicFile(path, .{ .make_path = true, .write_buffer = &buffer });
            defer atomic.deinit();
            try atomic.file_writer.interface.writeAll(original.content);
            try atomic.finish();
        }
    }

    fn had(self: *const Transaction, rel_path: []const u8) bool {
        for (self.originals) |original| {
            if (std.mem.eql(u8, original.rel_path, rel_path)) return true;
        }
        return false;
    }
};

/// Filesystem/OOM surface of restoring the captured metadata tree.
pub const RollbackError = walk.WalkError ||
    std.fs.Dir.DeleteFileError ||
    std.fs.Dir.MakeError ||
    std.fs.AtomicFile.InitError ||
    std.fs.AtomicFile.FinishError ||
    error{WriteFailed};

fn metadataWalkOpts() walk.WalkOpts {
    return .{
        .display_root = "",
        .excludes = &.{"cache/"},
        .max_file_bytes = 16 * 1024 * 1024,
        .extension = "",
    };
}

fn metadataRoot(allocator: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.guardian", .{project_dir});
}

fn fullPath(allocator: Allocator, project_dir: []const u8, rel_path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.guardian/{s}", .{ project_dir, rel_path });
}

// spec: Transactional Metadata - Restores all non-cache Guardian metadata after a failed gate

test "rollback restores modified metadata and removes newly created files" {
    const dir = "zig-cache/test-metadata-transaction";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir ++ "/.guardian/baselines");
    try std.fs.cwd().makePath(dir ++ "/.guardian/cache");
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/.guardian/baselines/a.txt", .data = "old\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/.guardian/cache/log", .data = "before\n" });

    var txn = try Transaction.begin(std.testing.allocator, dir);
    defer txn.deinit();
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/.guardian/baselines/a.txt", .data = "new\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/.guardian/pub-api.txt", .data = "created\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/.guardian/cache/log", .data = "after\n" });

    try txn.rollback();
    const old = try std.fs.cwd().readFileAlloc(std.testing.allocator, dir ++ "/.guardian/baselines/a.txt", 100);
    defer std.testing.allocator.free(old);
    const log = try std.fs.cwd().readFileAlloc(std.testing.allocator, dir ++ "/.guardian/cache/log", 100);
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("old\n", old);
    try std.testing.expectEqualStrings("after\n", log);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(dir ++ "/.guardian/pub-api.txt", .{}));
}
