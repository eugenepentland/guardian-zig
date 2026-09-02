//! guardian.fakes — deterministic test doubles for the ports Guardian's ban-*
//! checks force you to inject.
//!
//! Guardian bans acquiring nondeterminism directly (`ban-time`, `ban-rng`,
//! `ban-fs`, `ban-env`): production code must take a Clock / Random /
//! filesystem / config port and call through it. This module supplies the
//! deterministic value you put behind each of those ports in a TEST:
//!
//!   - FakeClock    — a manually advanced, `std.time`-free nanosecond clock
//!   - SeededRandom — an explicitly seeded `std.Random` wrapper
//!   - FakeFs       — an in-memory `path -> bytes` filesystem
//!   - FakeEnv      — an in-memory `name -> value` environment
//!
//! Everything here is dependency-free (only `std`), in-memory, and
//! deterministic. Wire it into your `build.zig` as the `guardian-fakes` module
//! (see README), then `const fakes = @import("guardian_fakes");` in your tests.

const clock = @import("clock.zig");
const random = @import("random.zig");
const fs = @import("fs.zig");
const env = @import("env.zig");
const owned_map = @import("owned_map.zig");

/// Deterministic, `std.time`-free clock double (see `fakes/clock.zig`).
pub const FakeClock = clock.FakeClock;

/// Explicitly seeded `std.Random` wrapper double (see `fakes/random.zig`).
pub const SeededRandom = random.SeededRandom;

/// In-memory `path -> bytes` filesystem double (see `fakes/fs.zig`).
pub const FakeFs = fs.FakeFs;

/// Error set returned by `FakeFs.readFile` (missing file / OOM copy).
pub const ReadError = fs.ReadError;

/// In-memory `name -> value` environment double (see `fakes/env.zig`).
pub const FakeEnv = env.FakeEnv;

test {
    // Pull the sub-module tests into any compilation that imports the root
    // (e.g. a consumer running the fakes' own suite); guardian's own test root
    // also imports each file directly and guards against drift.
    _ = clock;
    _ = random;
    _ = fs;
    _ = env;
    _ = owned_map;
}
