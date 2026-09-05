//! Guardian's filesystem compatibility boundary for Zig's explicit-I/O API.
//!
//! Call sites retain their small, synchronous filesystem surface while every
//! operation is forwarded to the process `Io` capability installed in
//! `wiring.zig`. No error is swallowed or translated here.

const std = @import("std");
const wiring = @import("wiring.zig");

pub const path = std.fs.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;

/// Returns Guardian's explicit-I/O wrapper around the current working directory.
pub fn cwd() Dir {
    return .{ .inner = .cwd() };
}

/// Allocates the running executable's path through the installed I/O capability.
pub fn selfExePathAlloc(allocator: std.mem.Allocator) std.process.ExecutablePathAllocError![:0]u8 {
    return std.process.executablePathAlloc(wiring.io(), allocator);
}

/// A file handle that forwards every operation through Guardian's active I/O.
pub const File = struct {
    inner: std.Io.File,

    pub const OpenError = std.Io.File.OpenError;
    pub const ReadError = std.Io.File.Reader.Error;
    pub const WriteError = std.Io.File.Writer.Error;
    pub const StatError = std.Io.File.StatError;
    /// Errors propagated while resizing a file.
    pub const SetLengthError = std.Io.File.SetLengthError;
    pub const PReadError = std.Io.File.ReadPositionalError;
    pub const GetSeekPosError = std.Io.File.StatError || std.Io.File.SeekError;
    pub const Stat = std.Io.File.Stat;

    /// Returns the process standard-input handle.
    pub fn stdin() File {
        return .{ .inner = .stdin() };
    }

    /// Returns the process standard-output handle.
    pub fn stdout() File {
        return .{ .inner = .stdout() };
    }

    /// Returns the process standard-error handle.
    pub fn stderr() File {
        return .{ .inner = .stderr() };
    }

    /// Closes this file through the active I/O capability.
    pub fn close(self: File) void {
        self.inner.close(wiring.io());
    }

    /// Streams all bytes to the file or returns the underlying writer error.
    pub fn writeAll(self: File, bytes: []const u8) WriteError!void {
        return self.inner.writeStreamingAll(wiring.io(), bytes);
    }

    /// Reads the file metadata through the active I/O capability.
    pub fn stat(self: File) StatError!Stat {
        return self.inner.stat(wiring.io());
    }

    /// Resizes the file through the active I/O capability.
    pub fn setLength(self: File, length: u64) SetLengthError!void {
        return self.inner.setLength(wiring.io(), length);
    }

    /// Reads positionally into `buffer` without changing the file's seek position.
    pub fn preadAll(self: File, buffer: []u8, offset: u64) PReadError!usize {
        return self.inner.readPositionalAll(wiring.io(), buffer, offset);
    }

    /// Creates a buffered reader for this file.
    pub fn reader(self: File, buffer: []u8) std.Io.File.Reader {
        return self.inner.reader(wiring.io(), buffer);
    }

    /// Creates a streaming buffered reader for this file.
    pub fn readerStreaming(self: File, buffer: []u8) std.Io.File.Reader {
        return self.inner.readerStreaming(wiring.io(), buffer);
    }

    /// Creates a buffered writer for this file.
    pub fn writer(self: File, buffer: []u8) std.Io.File.Writer {
        return self.inner.writer(wiring.io(), buffer);
    }

    /// Creates a streaming buffered writer for this file.
    pub fn writerStreaming(self: File, buffer: []u8) std.Io.File.Writer {
        return self.inner.writerStreaming(wiring.io(), buffer);
    }

    /// Reports whether the file is a terminal, preserving cancellation errors.
    pub fn isTty(self: File) std.Io.Cancelable!bool {
        return self.inner.isTty(wiring.io());
    }

    /// Seeks to a checked signed offset relative to the current file size.
    pub fn seekFromEnd(self: File, offset: i64) (StatError || std.Io.File.SeekError || error{Overflow})!void {
        const size = (try self.inner.stat(wiring.io())).size;
        const target = std.math.add(i128, @as(i128, @intCast(size)), offset) catch return error.Overflow;
        if (target < 0 or target > std.math.maxInt(u64)) return error.Overflow;
        return wiring.io().vtable.fileSeekTo(wiring.io().userdata, self.inner, @intCast(target));
    }
};

/// A directory handle that forwards every operation through Guardian's active I/O.
pub const Dir = struct {
    inner: std.Io.Dir,

    pub const OpenError = std.Io.Dir.OpenError;
    /// An explicit-I/O directory iterator.
    pub const Iterator = struct {
        inner: std.Io.Dir.Iterator,

        pub const Error = std.Io.Dir.Iterator.Error;

        /// Returns the next directory entry, or null at the end.
        pub fn next(self: *Iterator) Error!?std.Io.Dir.Entry {
            return self.inner.next(wiring.io());
        }
    };
    /// A recursive directory walker that retains its allocator-owned state.
    pub const Walker = struct {
        inner: std.Io.Dir.Walker,

        pub const Error = std.Io.Dir.SelectiveWalker.Error || std.Io.Dir.OpenError;
        pub const Entry = std.Io.Dir.Walker.Entry;

        /// Returns the next recursive entry, or null at the end.
        pub fn next(self: *Walker) Error!?Entry {
            return self.inner.next(wiring.io());
        }

        pub fn deinit(self: *Walker) void {
            self.inner.deinit();
        }
    };
    pub const DeleteFileError = std.Io.Dir.DeleteFileError;
    pub const MakeError = std.Io.Dir.CreateDirPathError;
    pub const Stat = std.Io.Dir.Stat;

    /// Closes this directory through the active I/O capability.
    pub fn close(self: Dir) void {
        self.inner.close(wiring.io());
    }

    /// Creates a non-recursive iterator over this directory.
    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    /// Creates an allocator-backed recursive walker over this directory.
    pub fn walk(self: Dir, allocator: std.mem.Allocator) std.mem.Allocator.Error!Walker {
        return .{ .inner = try self.inner.walk(allocator) };
    }

    /// Opens a child directory with the requested options.
    pub fn openDir(self: Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) OpenError!Dir {
        return .{ .inner = try self.inner.openDir(wiring.io(), sub_path, options) };
    }

    /// Reads a bounded file into newly allocated memory.
    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8, max_bytes: usize) std.Io.Dir.ReadFileAllocError![]u8 {
        return self.inner.readFileAlloc(wiring.io(), sub_path, allocator, .limited64(max_bytes));
    }

    /// Reads a bounded file with explicit alignment and sentinel options.
    pub fn readFileAllocOptions(
        self: Dir,
        allocator: std.mem.Allocator,
        sub_path: []const u8,
        max_bytes: usize,
        size_hint: ?usize,
        comptime alignment: std.mem.Alignment,
        comptime sentinel: ?u8,
    ) std.Io.Dir.ReadFileAllocError!(if (sentinel) |s| [:s]align(alignment.toByteUnits()) u8 else []align(alignment.toByteUnits()) u8) {
        _ = size_hint;
        return self.inner.readFileAllocOptions(wiring.io(), sub_path, allocator, .limited64(max_bytes), alignment, sentinel);
    }

    /// Checks access to a child path with the requested options.
    pub fn access(self: Dir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
        return self.inner.access(wiring.io(), sub_path, options);
    }

    /// Creates a directory path, including missing parents.
    pub fn makePath(self: Dir, sub_path: []const u8) MakeError!void {
        return self.inner.createDirPath(wiring.io(), sub_path);
    }

    /// Creates a directory path and opens its final component.
    pub fn makeOpenPath(self: Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.CreateDirPathOpenError!Dir {
        return .{ .inner = try self.inner.createDirPathOpen(wiring.io(), sub_path, .{ .open_options = options }) };
    }

    /// Recursively deletes a child tree.
    pub fn deleteTree(self: Dir, sub_path: []const u8) std.Io.Dir.DeleteTreeError!void {
        return self.inner.deleteTree(wiring.io(), sub_path);
    }

    /// Deletes one child file.
    pub fn deleteFile(self: Dir, sub_path: []const u8) DeleteFileError!void {
        return self.inner.deleteFile(wiring.io(), sub_path);
    }

    /// Writes a complete child file with the supplied options.
    pub fn writeFile(self: Dir, options: std.Io.Dir.WriteFileOptions) std.Io.Dir.WriteFileError!void {
        return self.inner.writeFile(wiring.io(), options);
    }

    /// Compatibility options for creating a child file.
    pub const CreateFileOptions = struct {
        read: bool = false,
        truncate: bool = true,
        exclusive: bool = false,
        lock: std.Io.File.Lock = .none,
        lock_nonblocking: bool = false,
        mode: ?u32 = null,
    };

    /// Creates a child file and returns its wrapped handle.
    pub fn createFile(self: Dir, sub_path: []const u8, options: CreateFileOptions) File.OpenError!File {
        return .{ .inner = try self.inner.createFile(wiring.io(), sub_path, .{
            .read = options.read,
            .truncate = options.truncate,
            .exclusive = options.exclusive,
            .lock = options.lock,
            .lock_nonblocking = options.lock_nonblocking,
            .permissions = if (options.mode) |mode| @fromBackingInt(@intCast(mode)) else .default_file,
        }) };
    }

    /// Opens a child file and returns its wrapped handle.
    pub fn openFile(self: Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) File.OpenError!File {
        return .{ .inner = try self.inner.openFile(wiring.io(), sub_path, options) };
    }

    /// Reads metadata for one child path.
    pub fn statFile(self: Dir, sub_path: []const u8) std.Io.Dir.StatFileError!Stat {
        return self.inner.statFile(wiring.io(), sub_path, .{});
    }

    /// Reads metadata for one child path WITHOUT following a final symlink, so
    /// the answer describes the entry itself (`kind == .sym_link`) rather than
    /// whatever it points at. `import-resolution` needs this distinction: a
    /// symlinked module is a legitimate import, and following the link would
    /// turn a dangling or directory-targeted link into a verdict about a file
    /// this project does not own.
    pub fn statFileNoFollow(self: Dir, sub_path: []const u8) std.Io.Dir.StatFileError!Stat {
        return self.inner.statFile(wiring.io(), sub_path, .{ .follow_symlinks = false });
    }

    /// Allocates the canonical absolute path for a child file.
    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8) std.Io.Dir.RealPathFileAllocError![:0]u8 {
        return self.inner.realPathFileAlloc(wiring.io(), sub_path, allocator);
    }

    /// Compatibility options for an atomic replacement file.
    pub const AtomicFileOptions = struct {
        mode: ?u32 = null,
        make_path: bool = false,
        write_buffer: []u8,
    };

    /// Creates a buffered atomic replacement for a child path.
    pub fn atomicFile(self: Dir, sub_path: []const u8, options: AtomicFileOptions) std.Io.Dir.CreateFileAtomicError!AtomicFile {
        var inner = try self.inner.createFileAtomic(wiring.io(), sub_path, .{
            .permissions = if (options.mode) |mode| @fromBackingInt(@intCast(mode)) else .default_file,
            .make_path = options.make_path,
            .replace = true,
        });
        return .{
            .inner = inner,
            .file_writer = inner.file.writer(wiring.io(), options.write_buffer),
        };
    }
};

/// A buffered atomic file replacement whose finish step flushes before rename.
pub const AtomicFile = struct {
    inner: std.Io.File.Atomic,
    file_writer: std.Io.File.Writer,

    pub const InitError = std.Io.Dir.CreateFileAtomicError;
    pub const FinishError = std.Io.File.Writer.Error || std.Io.File.Atomic.ReplaceError;

    pub fn deinit(self: *AtomicFile) void {
        self.inner.deinit(wiring.io());
    }

    /// Flushes buffered bytes and atomically replaces the destination.
    pub fn finish(self: *AtomicFile) FinishError!void {
        self.file_writer.interface.flush() catch |err| switch (err) {
            error.WriteFailed => return self.file_writer.err.?,
        };
        return self.inner.replace(wiring.io());
    }
};

test "filesystem boundary forwards file and directory operations" {
    const testing = std.testing;
    const root = cwd();
    const test_dir = "zig-cache/fs-boundary-test";
    root.deleteTree(test_dir) catch {};
    try root.makePath(test_dir);
    defer root.deleteTree(test_dir) catch {};
    var dir = try root.openDir(test_dir, .{ .iterate = true });
    defer dir.close();

    try dir.makePath("nested");
    var nested = try dir.makeOpenPath("nested/child", .{});
    nested.close();
    try dir.access("nested/child", .{});

    try dir.writeFile(.{ .sub_path = "source.txt", .data = "guardian" });
    const read = try dir.readFileAlloc(testing.allocator, "source.txt", 64);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("guardian", read);

    const aligned = try dir.readFileAllocOptions(
        testing.allocator,
        "source.txt",
        64,
        null,
        .of(u8),
        0,
    );
    defer testing.allocator.free(aligned);
    try testing.expectEqualStrings("guardian", aligned);

    var file = try dir.openFile("source.txt", .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expectEqual(@as(u64, "guardian".len), stat.size);
    var positional: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, positional.len), try file.preadAll(&positional, 0));
    try testing.expectEqualStrings("guardian", &positional);
    var read_buffer: [32]u8 = undefined;
    _ = file.reader(&read_buffer);
    _ = file.readerStreaming(&read_buffer);
    try file.seekFromEnd(-1);

    var output = try dir.createFile("output.txt", .{ .read = true });
    defer output.close();
    try output.writeAll("output");
    try output.setLength(3);
    try testing.expectEqual(@as(u64, 3), (try output.stat()).size);
    var write_buffer: [32]u8 = undefined;
    _ = output.writer(&write_buffer);
    _ = output.writerStreaming(&write_buffer);

    _ = try dir.statFile("source.txt");
    const canonical = try dir.realpathAlloc(testing.allocator, "source.txt");
    defer testing.allocator.free(canonical);
    try testing.expect(canonical.len > "source.txt".len);

    var atomic_buffer: [32]u8 = undefined;
    var atomic = try dir.atomicFile("atomic.txt", .{ .write_buffer = &atomic_buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll("atomic");
    try atomic.finish();

    var iterator = dir.iterate();
    try testing.expect((try iterator.next()) != null);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    try testing.expect((try walker.next()) != null);

    try dir.deleteFile("output.txt");
    try dir.deleteTree("nested");

    _ = File.stdin();
    _ = File.stdout();
    _ = File.stderr();
    _ = try File.stderr().isTty();
}
