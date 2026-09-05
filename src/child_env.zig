//! The environment flag a Guardian-spawned child build carries.
//!
//! Two commands spawn `zig build` on a tree Guardian has ALREADY judged —
//! `commit` runs `[gate] test_command` after gating, and `optimize-divergence`
//! runs the suite once per optimize mode. Both children re-enter a build wired
//! to Guardian, and re-gating there would be at best duplicated work and at
//! worst a self-deadlock. `check.zig` reads this flag in `main` and no-ops
//! every command when it is set, while the child's real work — compiling and
//! running the tests — still happens.
//!
//! It lives in its own leaf module rather than in `cli/commit.zig` because a
//! second command needs it: `cli/optimize_divergence.zig` is reachable from
//! the registry, and importing `commit.zig` from there would close the
//! registry → command → run_all → registry cycle the `imports` check forbids.
//! Distinct from the mutation runner's `GUARDIAN_MUTATION_RUN`, which marks a
//! deliberately-broken tree; this one only says "already gated".

/// Set to "1" on a Guardian-spawned child build so its wired gate no-ops.
pub const skip_checks = "GUARDIAN_SKIP_CHECKS";
