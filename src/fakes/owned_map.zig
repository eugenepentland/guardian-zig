//! The one copy of "store an owned key and an owned value in a string map".
//!
//! `FakeFs` (path -> bytes) and `FakeEnv` (name -> value) are different ports
//! with different vocabularies, but the insert underneath them is the same
//! thing three times over: copy the value, replace an existing entry in place
//! (freeing the old value, keeping the old key), and on a fresh key free every
//! copy already made if the next allocation fails. Written twice, that
//! three-branch cleanup is where one fake silently grows a leak the other does
//! not — so it lives here once and both call it.

const std = @import("std");

/// Sets `key` to a private copy of `value` in `map`, replacing any current
/// entry. `map` owns both copies; the caller keeps ownership of what it passed
/// in. On failure nothing is stored and nothing is leaked.
pub fn put(
    map: *std.StringHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) std.mem.Allocator.Error!void {
    const value_copy = try allocator.dupe(u8, value);
    if (map.getPtr(key)) |slot| {
        allocator.free(slot.*);
        slot.* = value_copy;
        return;
    }
    const key_copy = allocator.dupe(u8, key) catch |err| {
        allocator.free(value_copy);
        return err;
    };
    map.put(allocator, key_copy, value_copy) catch |err| {
        allocator.free(key_copy);
        allocator.free(value_copy);
        return err;
    };
}

/// Frees every key and value the map owns and the map's own storage.
pub fn deinit(map: *std.StringHashMapUnmanaged([]const u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit(allocator);
}

const testing = std.testing;

// spec: Fakes - Stores an owned key and value once and replaces a value in place

test "owned_map: put copies both sides and replaces a value without re-keying" {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer deinit(&map, testing.allocator);

    var key_buf = [_]u8{ 'K', '1' };
    var value_buf = [_]u8{ 'v', '1' };
    try put(&map, testing.allocator, &key_buf, &value_buf);
    // The caller's buffers are its own: scribbling on them cannot reach the map.
    key_buf[1] = '9';
    value_buf[1] = '9';
    try testing.expectEqualStrings("v1", map.get("K1").?);

    try put(&map, testing.allocator, "K1", "v2");
    try testing.expectEqualStrings("v2", map.get("K1").?);
    try testing.expectEqual(@as(usize, 1), map.count());
}
