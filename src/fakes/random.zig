//! SeededRandom — an explicitly seeded std.Random wrapper for tests.
//!
//! Guardian's `ban-rng` check forces RNG construction behind an injected
//! Random port (conventionally `infra/random`). SeededRandom is the
//! deterministic value a test puts behind that port: a thin, discoverable
//! wrapper over Zig's `std.Random.DefaultPrng` that *requires* an explicit
//! seed, so a "random" test's stream is fixed and reproducible.
//!
//! It deliberately adds nothing over `std.Random.DefaultPrng` — its whole job
//! is to be the documented, one-obvious-way pattern and the single place
//! `ban-rng` is intentionally satisfied (see guardian.toml's [[allow]] for
//! `src/fakes/*`: the fake IS the injection point the check exists to force).

const std = @import("std");

/// Deterministic RNG for tests: a `std.Random.DefaultPrng` behind a required
/// explicit seed, so the same seed always yields the same sequence.
pub const SeededRandom = struct {
    /// Backing pseudo-random generator, seeded once at init.
    prng: std.Random.DefaultPrng,

    /// Creates a generator seeded with `seed`. Two SeededRandoms built with
    /// the same seed produce identical sequences — that is the whole point.
    pub fn init(seed: u64) SeededRandom {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// Returns a `std.Random` interface backed by this seeded generator; call
    /// its `int` / `float` / `boolean` helpers as usual, deterministically.
    pub fn random(self: *SeededRandom) std.Random {
        return self.prng.random();
    }
};

// spec: Fakes - SeededRandom reproduces a sequence for a given seed
test "SeededRandom same seed yields same sequence" {
    var a = SeededRandom.init(42);
    var b = SeededRandom.init(42);
    const ra = a.random();
    const rb = b.random();
    try std.testing.expectEqual(ra.int(u64), rb.int(u64));
    try std.testing.expectEqual(ra.int(u64), rb.int(u64));
}

// spec: Fakes - SeededRandom diverges for different seeds
test "SeededRandom different seeds diverge" {
    var a = SeededRandom.init(1);
    var b = SeededRandom.init(2);
    const ra = a.random();
    const rb = b.random();
    try std.testing.expect(ra.int(u64) != rb.int(u64));
}
