//! FakeClock — a deterministic, std.time-free wall-clock double for tests.
//!
//! Guardian's `ban-time` check forces every wall-clock read behind an injected
//! Clock port (conventionally `infra/clock`). FakeClock is the deterministic
//! value a test puts behind that port: a hand-cranked nanosecond counter with
//! no `std.time` call anywhere, so a test that "reads the clock" or "sleeps" is
//! instant and reproducible run to run.
//!
//! Intended port shape — the seam production defines and injects. Any struct
//! with a `now() i128` method fits; FakeClock is one such implementation:
//!
//! ```zig
//! fn Clock(comptime Backing: type) type {
//!     return struct {
//!         backing: *Backing,
//!         pub fn now(self: @This()) i128 { return self.backing.now(); }
//!     };
//! }
//! // production: Clock(SystemClock); tests: Clock(FakeClock)
//! ```
//!
//! `now` returns `i128` nanoseconds — the same type `std.time.nanoTimestamp`
//! returns — so production code can read the real clock while tests drive a
//! FakeClock through the identical port.

const std = @import("std");

/// Deterministic monotonic clock for tests: a manually advanced nanosecond
/// counter with no `std.time` dependency, so injected time is reproducible.
pub const FakeClock = struct {
    /// Current time in nanoseconds; `i128` matches `std.time.nanoTimestamp`.
    nanos: i128,

    /// Creates a clock fixed at `start_nanos` nanoseconds. It never moves on
    /// its own — drive it forward with `advance` or `sleep`.
    pub fn init(start_nanos: i128) FakeClock {
        return .{ .nanos = start_nanos };
    }

    /// Returns the current time in nanoseconds — the drop-in stand-in for a
    /// real `std.time.nanoTimestamp()` read behind an injected Clock port.
    pub fn now(self: *const FakeClock) i128 {
        return self.nanos;
    }

    /// Moves the clock forward by `delta_nanos`. This is the only way the
    /// clock changes, so every advance in a test is explicit and visible.
    pub fn advance(self: *FakeClock, delta_nanos: i128) void {
        self.nanos += delta_nanos;
    }

    /// Deterministic stand-in for a real sleep: advances the clock by
    /// `delta_nanos` and returns immediately, so injected waits are instant.
    pub fn sleep(self: *FakeClock, delta_nanos: i128) void {
        self.advance(delta_nanos);
    }
};

// spec: Fakes - FakeClock reads back its start time
test "FakeClock reads back its start time" {
    var clock = FakeClock.init(1_000);
    try std.testing.expectEqual(@as(i128, 1_000), clock.now());
}

// spec: Fakes - FakeClock advance accumulates elapsed nanoseconds
test "FakeClock advance accumulates" {
    var clock = FakeClock.init(0);
    clock.advance(7_000);
    clock.advance(500);
    try std.testing.expectEqual(@as(i128, 7_500), clock.now());
}

// spec: Fakes - FakeClock sleep advances the clock instead of blocking
test "FakeClock sleep advances instead of blocking" {
    var clock = FakeClock.init(100);
    clock.sleep(900);
    try std.testing.expectEqual(@as(i128, 1_000), clock.now());
}

// spec: Fakes - FakeClock reads through an injected Clock port
test "FakeClock drives an injected Clock port" {
    // A minimal Clock port: production depends on this seam; the test injects
    // a FakeClock so the "current time" is fixed and hand-advanced.
    const Clock = struct {
        backing: *FakeClock,
        fn now(self: @This()) i128 {
            return self.backing.now();
        }
    };
    var fake = FakeClock.init(500);
    const port = Clock{ .backing = &fake };
    fake.advance(500);
    try std.testing.expectEqual(@as(i128, 1_000), port.now());
}
