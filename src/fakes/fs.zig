//! FakeFs — an in-memory filesystem double for tests.
//!
//! Guardian's `ban-fs` check forces real file I/O behind an injected
//! filesystem port (conventionally `infra/fs`). FakeFs is the deterministic
//! value a test puts behind that port: a string-keyed map of `path -> bytes`
//! with no `std.fs` call, so tests exercise read / write / exists / delete /
//! list without touching a real disk.
//!
//! Paths are opaque string keys — there is no normalization, so "a/b.txt" and
//! "./a/b.txt" are distinct files. Keys and contents are copied into the FakeFs
//! on write and freed on delete / deinit, so callers keep ownership of the
//! buffers they pass in.

const std = @import("std");
const owned_map = @import("owned_map.zig");

/// Errors returned by `FakeFs.readFile`: a missing key, or an allocation
/// failure while copying the stored bytes out to the caller's allocator.
pub const ReadError = error{ FileNotFound, OutOfMemory };

/// In-memory filesystem for tests: a `path -> bytes` map that owns its copies.
pub const FakeFs = struct {
    /// Allocator backing the map and every stored key / value copy.
    allocator: std.mem.Allocator,
    /// Path (key) -> file contents (value); both owned by `allocator`.
    files: std.StringHashMapUnmanaged([]const u8),

    /// Creates an empty in-memory filesystem backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) FakeFs {
        return .{ .allocator = allocator, .files = .empty };
    }

    /// Frees every stored path and its contents, then the map itself.
    pub fn deinit(self: *FakeFs) void {
        owned_map.deinit(&self.files, self.allocator);
    }

    /// Stores `bytes` at `path`, replacing any existing contents. Both the
    /// path and the bytes are copied, so the caller's buffers can be reused.
    pub fn writeFile(self: *FakeFs, path: []const u8, bytes: []const u8) std.mem.Allocator.Error!void {
        try owned_map.put(&self.files, self.allocator, path, bytes);
    }

    /// Returns a fresh `result_allocator`-owned copy of the bytes at `path`,
    /// or `error.FileNotFound` when nothing was written there.
    pub fn readFile(self: *const FakeFs, result_allocator: std.mem.Allocator, path: []const u8) ReadError![]const u8 {
        const stored = self.files.get(path) orelse return error.FileNotFound;
        const copy = try result_allocator.dupe(u8, stored);
        return copy;
    }

    /// Reports whether a file was written at `path`.
    pub fn exists(self: *const FakeFs, path: []const u8) bool {
        return self.files.contains(path);
    }

    /// Removes the file at `path` if present, freeing its stored copies; a
    /// path that was never written is a no-op.
    pub fn deleteFile(self: *FakeFs, path: []const u8) void {
        if (self.files.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Returns the stored paths sorted ascending, in a `result_allocator`-owned
    /// slice — the deterministic listing tests assert against. The path strings
    /// themselves stay owned by the FakeFs.
    pub fn listPaths(
        self: *const FakeFs,
        result_allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const []const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            try paths.append(result_allocator, entry.key_ptr.*);
        }
        const slice = try paths.toOwnedSlice(result_allocator);
        std.mem.sort([]const u8, slice, {}, lessThanPath);
        return slice;
    }
};

/// Orders two path keys lexicographically for `listPaths`' stable output.
fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// spec: Fakes - FakeFs round-trips bytes through writeFile and readFile
test "FakeFs writes then reads back file contents" {
    var fs = FakeFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("notes.txt", "hello world");
    const got = try fs.readFile(std.testing.allocator, "notes.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

// spec: Fakes - FakeFs reports existence of written paths
test "FakeFs exists reflects written paths" {
    var fs = FakeFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("present.txt", "x");
    try std.testing.expect(fs.exists("present.txt"));
    try std.testing.expect(!fs.exists("absent.txt"));
}

// spec: Fakes - FakeFs deleteFile removes a stored file
test "FakeFs deleteFile removes the entry" {
    var fs = FakeFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("doomed.txt", "bye");
    fs.deleteFile("doomed.txt");
    try std.testing.expect(!fs.exists("doomed.txt"));
}

// spec: Fakes - FakeFs readFile returns FileNotFound for a missing path
test "FakeFs readFile errors on a missing path" {
    var fs = FakeFs.init(std.testing.allocator);
    defer fs.deinit();
    try std.testing.expectError(error.FileNotFound, fs.readFile(std.testing.allocator, "nowhere.txt"));
}

// spec: Fakes - FakeFs listPaths returns paths sorted ascending
test "FakeFs listPaths is sorted ascending" {
    var fs = FakeFs.init(std.testing.allocator);
    defer fs.deinit();
    try fs.writeFile("charlie.txt", "3");
    try fs.writeFile("alpha.txt", "1");
    try fs.writeFile("bravo.txt", "2");
    const paths = try fs.listPaths(std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings("alpha.txt", paths[0]);
    try std.testing.expectEqualStrings("bravo.txt", paths[1]);
    try std.testing.expectEqualStrings("charlie.txt", paths[2]);
}
