//! Guardian's version string. Printed by the `version` command and the
//! `--version` flag, and useful in run headers so `.guardian/` snapshot diffs
//! are attributable to a guardian upgrade.
//!
//! IMPORTANT: keep `string` in sync with `build.zig.zon`'s `.version` field on
//! every release bump. Zig's module boundary blocks importing the manifest
//! from here (it sits outside `src/`), so the two are maintained by hand.

const std = @import("std");

/// The guardian release version, mirroring build.zig.zon `.version`.
pub const string: []const u8 = "0.1.0";

// spec: Versioning - Reports a non-empty dotted guardian version string

test "version string is non-empty and dotted" {
    try std.testing.expect(string.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, string, '.') != null);
}
