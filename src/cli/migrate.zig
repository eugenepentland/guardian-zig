//! `migrate` command — the deliberate one-shot that persists a metadata FORMAT
//! re-key (v1 text baseline → v3 identity baseline, v1 → v2 ratchet) and any
//! other deferred prune/first-record write across the whole suite. Ordinary
//! runs are read-only on `.guardian/` (see cli/run_all + baseline/ratchet
//! lifecycles), so a format bump no longer dribbles out as per-session churn:
//! it lands as one reviewed `guardian-check migrate .` + commit.
//!
//! It runs the full gate metadata-writable and blocking: a green tree re-keys
//! and the writes persist; a red tree rolls back (nothing half-migrated) and
//! reports the violations to fix first. Dispatched specially by check.zig (like
//! accept/doctor) — it composes run_all.run, which imports the registry, so a
//! registry entry would close an @import cycle.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const run_all = @import("run_all.zig");

/// CLI name that check.zig dispatches to this command.
pub const command_name = "migrate";

/// Runs the full suite metadata-writable so every deferred format re-key /
/// prune / first-record write is persisted, then points the user at the
/// resulting `.guardian/` diff to commit. A red gate rolls the writes back and
/// fails, so a format bump never rides an otherwise-broken tree.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    // Block + persist: the whole point is to write, and to write nothing on red.
    ctx.gate = true;
    ctx.metadata_writable = true;
    reporter.ok("migrate: re-keying committed .guardian metadata to the current format ...", .{});
    run_all.run(ctx) catch |e| switch (e) {
        error.CheckFailed => {
            reporter.fail("migrate: gate is red — fix the violations above, then re-run migrate", .{});
            return error.CheckFailed;
        },
        else => return e,
    };
    reporter.ok("migrate: metadata is at the current format; review and commit the .guardian/ diff", .{});
}

// spec: Migrate - Persists a deferred metadata format re-key as one deliberate step

test "migrate command name stays stable for dispatch" {
    try std.testing.expectEqualStrings("migrate", command_name);
}
