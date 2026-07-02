const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAGIC_PREFIX = "# guardian-snapshot v";

/// A read snapshot file, parsed into version + sorted lines.
pub const Snapshot = struct {
    version: u32,
    lines: []const []const u8,
};

/// Set difference between an old snapshot and a new sorted-lines slice.
pub const Diff = struct {
    added: []const []const u8,
    removed: []const []const u8,

    /// True when nothing was added or removed — the snapshot is unchanged.
    pub fn isEmpty(self: Diff) bool {
        return self.added.len == 0 and self.removed.len == 0;
    }
};

pub const ReadError = error{
    Missing,
    BadFormat,
    VersionMismatch,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.posix.ReadError;

/// Parses the magic header line, validating the prefix and version.
/// Returns BadFormat on a missing/malformed header and VersionMismatch
/// when the parsed version doesn't equal expected_version.
fn parseHeader(header: ?[]const u8, expected_version: u32) ReadError!u32 {
    const version = try parseVersion(header);
    if (version != expected_version) return error.VersionMismatch;
    return version;
}

/// Extracts the version integer from a header line, or BadFormat if the
/// line is missing, lacks the magic prefix, or has a non-integer version.
fn parseVersion(header: ?[]const u8) ReadError!u32 {
    const line = header orelse return error.BadFormat;
    if (!std.mem.startsWith(u8, line, MAGIC_PREFIX)) return error.BadFormat;
    const ver_str = line[MAGIC_PREFIX.len..];
    return std.fmt.parseInt(u32, ver_str, 10) catch error.BadFormat;
}

/// Reads a snapshot file. Returns Missing if the file does not exist,
/// BadFormat if the magic header is missing or malformed, VersionMismatch
/// if the version doesn't match expected_version.
pub fn read(arena: Allocator, path: []const u8, expected_version: u32) ReadError!Snapshot {
    const content = std.fs.cwd().readFileAlloc(arena, path, 16 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return error.Missing,
        // Pass through real I/O / OOM errors — only a bad header is BadFormat,
        // so "your snapshot is corrupt" isn't reported for a permission error.
        else => |err| return err,
    };

    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    const version = try parseHeader(lines_iter.next(), expected_version);

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    while (lines_iter.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(arena, line);
    }
    return .{
        .version = version,
        .lines = try lines.toOwnedSlice(arena),
    };
}

/// Errors that `write` may propagate.
pub const WriteError = std.fs.File.OpenError || std.fs.File.WriteError || std.mem.Allocator.Error || error{WriteFailed};

/// Writes a snapshot file. Lines are sorted in place for deterministic output.
pub fn write(path: []const u8, version: u32, lines: [][]const u8) WriteError!void {
    std.mem.sort([]const u8, lines, {}, lessThan);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |e| std.log.warn("snapshot makePath {s}: {s}", .{ dir, @errorName(e) });
    }
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    var w = &fw.interface;
    try w.print("{s}{d}\n", .{ MAGIC_PREFIX, version });
    for (lines) |line| {
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    try w.flush();
}

/// Compute added/removed sets between sorted snapshot lines and a new sorted slice.
pub fn diff(arena: Allocator, old: Snapshot, new_lines: []const []const u8) std.mem.Allocator.Error!Diff {
    var added: std.ArrayListUnmanaged([]const u8) = .empty;
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 0;
    var j: usize = 0;
    while (i < old.lines.len and j < new_lines.len) {
        const cmp = std.mem.order(u8, old.lines[i], new_lines[j]);
        switch (cmp) {
            .eq => {
                i += 1;
                j += 1;
            },
            .lt => {
                try removed.append(arena, old.lines[i]);
                i += 1;
            },
            .gt => {
                try added.append(arena, new_lines[j]);
                j += 1;
            },
        }
    }
    while (i < old.lines.len) : (i += 1) try removed.append(arena, old.lines[i]);
    while (j < new_lines.len) : (j += 1) try added.append(arena, new_lines[j]);

    return .{
        .added = try added.toOwnedSlice(arena),
        .removed = try removed.toOwnedSlice(arena),
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "write then read round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_path = "zig-cache/test-snapshot.txt";
    var lines = [_][]const u8{ "zebra", "apple", "mango" };
    try write(tmp_path, 1, &lines);
    defer std.fs.cwd().deleteFile(tmp_path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ tmp_path, @errorName(e) });

    const snap = try read(a, tmp_path, 1);
    try std.testing.expectEqual(@as(u32, 1), snap.version);
    try std.testing.expectEqual(@as(usize, 3), snap.lines.len);
    // Sorted on write
    try std.testing.expectEqualStrings("apple", snap.lines[0]);
    try std.testing.expectEqualStrings("mango", snap.lines[1]);
    try std.testing.expectEqualStrings("zebra", snap.lines[2]);
}

test "read returns Missing for missing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.Missing, read(a, "/tmp/does-not-exist-guardian.txt", 1));
}

test "read returns VersionMismatch on wrong version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_path = "zig-cache/test-snapshot-ver.txt";
    var lines = [_][]const u8{"x"};
    try write(tmp_path, 1, &lines);
    defer std.fs.cwd().deleteFile(tmp_path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ tmp_path, @errorName(e) });

    try std.testing.expectError(error.VersionMismatch, read(a, tmp_path, 2));
}

test "diff finds added and removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old: Snapshot = .{
        .version = 1,
        .lines = &.{ "apple", "banana", "cherry" },
    };
    const new_lines = [_][]const u8{ "apple", "cherry", "date" };
    const d = try diff(a, old, &new_lines);

    try std.testing.expectEqual(@as(usize, 1), d.removed.len);
    try std.testing.expectEqualStrings("banana", d.removed[0]);
    try std.testing.expectEqual(@as(usize, 1), d.added.len);
    try std.testing.expectEqualStrings("date", d.added[0]);
}

test "diff identical snapshots returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old: Snapshot = .{
        .version = 1,
        .lines = &.{ "apple", "banana" },
    };
    const new_lines = [_][]const u8{ "apple", "banana" };
    const d = try diff(a, old, &new_lines);
    try std.testing.expect(d.isEmpty());
}
