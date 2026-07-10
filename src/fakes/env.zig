//! FakeEnv — an in-memory environment-variable map for tests.
//!
//! Guardian's `ban-env` check forces environment reads behind `config` or
//! `main`. FakeEnv is the deterministic value a test puts behind a config
//! port: a string map of `name -> value` with no `std.process` call, so tests
//! set / read / clear "env" without touching the real process environment.
//!
//! Names and values are copied in on `set` and freed on `unset` / `deinit`, so
//! callers keep ownership of the buffers they pass in.

const std = @import("std");

/// In-memory environment for tests: a `name -> value` map that owns its copies.
pub const FakeEnv = struct {
    /// Allocator backing the map and every stored key / value copy.
    allocator: std.mem.Allocator,
    /// Variable name (key) -> value; both owned by `allocator`.
    vars: std.StringHashMapUnmanaged([]const u8),

    /// Creates an empty environment backed by `allocator`.
    pub fn init(allocator: std.mem.Allocator) FakeEnv {
        return .{ .allocator = allocator, .vars = .empty };
    }

    /// Frees every stored name and value, then the map itself.
    pub fn deinit(self: *FakeEnv) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit(self.allocator);
    }

    /// Sets `key` to `value`, replacing any current value. Both are copied,
    /// so the caller keeps ownership of the buffers it passes in.
    pub fn set(self: *FakeEnv, key: []const u8, value: []const u8) std.mem.Allocator.Error!void {
        const value_copy = try self.allocator.dupe(u8, value);
        if (self.vars.getPtr(key)) |slot| {
            self.allocator.free(slot.*);
            slot.* = value_copy;
            return;
        }
        const key_copy = self.allocator.dupe(u8, key) catch |err| {
            self.allocator.free(value_copy);
            return err;
        };
        self.vars.put(self.allocator, key_copy, value_copy) catch |err| {
            self.allocator.free(key_copy);
            self.allocator.free(value_copy);
            return err;
        };
    }

    /// Returns the value set for `key`, or null when it is unset. The slice is
    /// owned by the FakeEnv and valid until the key is changed or removed.
    pub fn get(self: *const FakeEnv, key: []const u8) ?[]const u8 {
        return self.vars.get(key);
    }

    /// Removes `key` if present, freeing its stored copies; an unset key is a
    /// no-op.
    pub fn unset(self: *FakeEnv, key: []const u8) void {
        if (self.vars.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }
};

// spec: Fakes - FakeEnv get returns a set value
test "FakeEnv get returns a set value" {
    var env = FakeEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.set("HOME", "/home/agent");
    try std.testing.expectEqualStrings("/home/agent", env.get("HOME").?);
}

// spec: Fakes - FakeEnv get returns null for an unset key
test "FakeEnv get is null when unset" {
    var env = FakeEnv.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(env.get("NEVER_SET") == null);
}

// spec: Fakes - FakeEnv unset removes a variable
test "FakeEnv unset clears a variable" {
    var env = FakeEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.set("TOKEN", "abc123xyz");
    env.unset("TOKEN");
    try std.testing.expect(env.get("TOKEN") == null);
}
