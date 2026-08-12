//! Runtime capabilities installed by the executable entry point.
//!
//! Zig 0.17 makes I/O an explicit capability. Guardian keeps its existing
//! filesystem boundary while routing every operation through the exact `Io`
//! supplied by `std.process.Init`. Unit tests use Zig's deterministic testing
//! I/O capability.

const std = @import("std");
const builtin = @import("builtin");

var runtime_io: std.Io = undefined;
var runtime_io_initialized = false;
var runtime_environ: *const std.process.Environ.Map = undefined;

/// Installs the process capabilities used by Guardian's compatibility boundaries.
pub fn init(process_init: std.process.Init) void {
    std.debug.assert(!runtime_io_initialized);
    runtime_io = process_init.io;
    runtime_environ = process_init.environ_map;
    runtime_io_initialized = true;
}

/// Returns the active process I/O capability, or Zig's test capability in tests.
pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    std.debug.assert(runtime_io_initialized);
    return runtime_io;
}

/// Copies one environment value from the active process or test environment.
pub fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) std.process.Environ.GetAllocError![]u8 {
    if (builtin.is_test) return std.process.Environ.getAlloc(std.testing.environ, allocator, name);
    std.debug.assert(runtime_io_initialized);
    const value = runtime_environ.get(name) orelse return error.EnvironmentVariableMissing;
    return allocator.dupe(u8, value);
}

/// Clones the active environment for a child process without consulting globals.
pub fn cloneEnviron(allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.Io.UnexpectedError)!std.process.Environ.Map {
    if (builtin.is_test) return std.process.Environ.createMap(std.testing.environ, allocator);
    std.debug.assert(runtime_io_initialized);
    return runtime_environ.clone(allocator);
}

test "test wiring uses Zig's explicit test capabilities" {
    try std.testing.expectEqual(std.testing.io.userdata, io().userdata);

    const missing = "GUARDIAN_WIRING_TEST_VALUE_THAT_MUST_NOT_EXIST";
    try std.testing.expectError(
        error.EnvironmentVariableMissing,
        getEnvOwned(std.testing.allocator, missing),
    );

    var environ = try cloneEnviron(std.testing.allocator);
    defer environ.deinit();
}
