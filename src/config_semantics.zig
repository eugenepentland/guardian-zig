//! Cross-field guardian.toml validation kept separate from the line-oriented
//! parser. It returns structured issues so the parser can attach source lines.

const std = @import("std");
const config = @import("config.zig");

/// Mutation field responsible for a cross-setting validation failure.
pub const Field = enum {
    min_score_pct,
    min_mutants,
    max_mutants,
    fast_max_mutants,
    timeout_floor_secs,
    timeout_multiplier,
    timeout_retry_multiplier,
    timeout_secs,
};

/// Structured semantic failure with its source-field identity and message.
pub const Issue = struct {
    field: Field,
    message: []const u8,
};

/// Returns the first unsafe cross-field mutation configuration, if any.
pub fn validate(allocator: std.mem.Allocator, cfg: *const config.Config) std.mem.Allocator.Error!?Issue {
    const m = cfg.mutation;
    if (m.min_score_pct > 100) return try issue(
        allocator,
        .min_score_pct,
        "mutation min_score_pct must be between 0 and 100",
        .{},
    );
    if (m.min_mutants == 0) return try issue(allocator, .min_mutants, "mutation min_mutants must be non-zero", .{});
    if (m.max_mutants == 0) return try issue(allocator, .max_mutants, "mutation max_mutants must be non-zero", .{});
    if (m.fast_max_mutants == 0) return try issue(
        allocator,
        .fast_max_mutants,
        "mutation fast_max_mutants must be non-zero",
        .{},
    );
    if (m.min_mutants > m.max_mutants) return try issue(
        allocator,
        .min_mutants,
        "mutation min_mutants ({d}) must not exceed max_mutants ({d})",
        .{ m.min_mutants, m.max_mutants },
    );
    if (m.fast_max_mutants > m.max_mutants) return try issue(
        allocator,
        .fast_max_mutants,
        "mutation fast_max_mutants ({d}) must not exceed max_mutants ({d})",
        .{ m.fast_max_mutants, m.max_mutants },
    );
    if (m.min_mutants > m.fast_max_mutants) return try issue(
        allocator,
        .min_mutants,
        "mutation min_mutants ({d}) must not exceed fast_max_mutants ({d})",
        .{ m.min_mutants, m.fast_max_mutants },
    );
    const timeouts = .{
        .{ Field.timeout_floor_secs, m.timeout_floor_secs },
        .{ Field.timeout_multiplier, m.timeout_multiplier },
        .{ Field.timeout_retry_multiplier, m.timeout_retry_multiplier },
        .{ Field.timeout_secs, m.timeout_secs },
    };
    inline for (timeouts) |entry| {
        if (entry[1] == 0) return try issue(
            allocator,
            entry[0],
            "mutation {s} must be non-zero",
            .{@tagName(entry[0])},
        );
    }
    return null;
}

fn issue(
    allocator: std.mem.Allocator,
    field: Field,
    comptime format: []const u8,
    args: anytype,
) std.mem.Allocator.Error!Issue {
    return .{ .field = field, .message = try std.fmt.allocPrint(allocator, format, args) };
}

// spec: Configuration - Rejects unsafe mutation ranges and zero timeouts

test "validate reports unsafe mutation relationships" {
    var cfg: config.Config = .{};
    cfg.mutation.min_mutants = 9;
    cfg.mutation.fast_max_mutants = 8;
    const got = (try validate(std.testing.allocator, &cfg)).?;
    defer std.testing.allocator.free(got.message);
    try std.testing.expect(got.field == .min_mutants);
}
