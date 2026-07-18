//! Applies the policy/doctor configuration groups, keeping optional workflow
//! features out of the already-dense core TOML parser.

const std = @import("std");
const config = @import("config.zig");
const value = @import("config_value.zig");

pub const lock_enabled_key = "lock_enabled";
pub const lock_against_key = "lock_against";

/// Applies one already-validated `[policy]` key/value pair.
pub fn applyPolicy(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    key: []const u8,
    val: []const u8,
) std.mem.Allocator.Error!void {
    const g = &cfg.policy;
    if (std.mem.eql(u8, key, "profile")) {
        const name = value.parseString(val) orelse return;
        if (std.mem.eql(u8, name, "strict")) g.profile = .strict;
        if (std.mem.eql(u8, name, "agent")) g.profile = .agent;
        if (std.mem.eql(u8, name, "safety")) g.profile = .safety;
    } else if (std.mem.eql(u8, key, "block")) {
        g.block = try value.toStrings(allocator, val);
    } else if (std.mem.eql(u8, key, "ratchet")) {
        g.ratchet = try value.toStrings(allocator, val);
    } else if (std.mem.eql(u8, key, "report")) {
        g.report = try value.toStrings(allocator, val);
    } else if (std.mem.eql(u8, key, lock_enabled_key)) {
        g.lock_enabled = value.parseBool(val) orelse g.lock_enabled;
    } else if (std.mem.eql(u8, key, lock_against_key)) {
        if (value.parseString(val)) |v| g.lock_against = v;
    } else if (std.mem.eql(u8, key, "protected_paths")) {
        g.protected_paths = try value.toStrings(allocator, val);
    }
}

/// True for the only accepted built-in profile names.
pub fn validProfile(name: []const u8) bool {
    return std.mem.eql(u8, name, "strict") or
        std.mem.eql(u8, name, "agent") or
        std.mem.eql(u8, name, "safety");
}

/// Applies one already-validated `[doctor]` threshold.
pub fn applyDoctor(cfg: *config.Config, key: []const u8, val: []const u8) void {
    const g = &cfg.doctor;
    if (std.mem.eql(u8, key, "zig_cache_warn_mib")) {
        g.zig_cache_warn_mib = value.parseU32(val, g.zig_cache_warn_mib);
    } else if (std.mem.eql(u8, key, "guardian_cache_warn_mib")) {
        g.guardian_cache_warn_mib = value.parseU32(val, g.guardian_cache_warn_mib);
    }
}

// spec: Configuration - Parses policy profiles, policy locks, doctor thresholds, and external argv gates

test "policy and doctor appliers update their isolated config groups" {
    var cfg: config.Config = .{};
    try applyPolicy(std.testing.allocator, &cfg, "profile", "\"agent\"");
    applyDoctor(&cfg, "zig_cache_warn_mib", "8192");
    try std.testing.expect(cfg.policy.profile == .agent);
    try std.testing.expectEqual(@as(u32, 8192), cfg.doctor.zig_cache_warn_mib);
    try std.testing.expect(validProfile("strict"));
    try std.testing.expect(!validProfile("casual"));
}
