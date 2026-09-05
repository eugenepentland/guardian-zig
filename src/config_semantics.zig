//! Cross-field guardian.toml validation kept separate from the line-oriented
//! parser. It returns structured issues so the parser can attach source lines.

const std = @import("std");
const config = @import("config.zig");

/// Mutation field responsible for a cross-setting validation failure.
pub const Field = enum {
    hard_max_file_lines,
    function_hard_max_lines,
    line_hard_max_len,
    min_score_pct,
    min_mutants,
    max_mutants,
    fast_max_mutants,
    timeout_floor_secs,
    timeout_multiplier,
    timeout_retry_multiplier,
    timeout_secs,
};

/// The message spelling for `min_mutants`, named once because three separate
/// invariants below bound it and a rename must not half-apply.
const min_mutants_label = "mutation min_mutants";

/// Structured semantic failure with its source-field identity and message.
pub const Issue = struct {
    field: Field,
    message: []const u8,
};

/// Returns the first unsafe cross-field mutation configuration, if any.
///
/// The invariants are a table rather than a column of `if` arms so that the
/// order they are reported in is visible at a glance and the single allocation
/// happens in one place, after the decision is already made.
pub fn validate(allocator: std.mem.Allocator, cfg: *const config.Config) std.mem.Allocator.Error!?Issue {
    // Destructured so each rule below stays one readable line.
    const fl = cfg.function_length;
    const ll = cfg.line_length;
    const m = cfg.mutation;
    const rules = [_]Rule{
        cap(.hard_max_file_lines, "hard_max_file_lines", cfg.hard_max_file_lines, "max_file_lines", cfg.max_file_lines),
        cap(.function_hard_max_lines, "function_length hard_max_lines", fl.hard_max_lines, "max_lines", fl.max_lines),
        cap(.line_hard_max_len, "line_length hard_max_len", ll.hard_max_len, "max_len", ll.max_len),
        percent(.min_score_pct, "mutation min_score_pct", m.min_score_pct),
        nonzero(.min_mutants, min_mutants_label, m.min_mutants),
        nonzero(.max_mutants, "mutation max_mutants", m.max_mutants),
        nonzero(.fast_max_mutants, "mutation fast_max_mutants", m.fast_max_mutants),
        atMost(.min_mutants, min_mutants_label, m.min_mutants, "max_mutants", m.max_mutants),
        atMost(.fast_max_mutants, "mutation fast_max_mutants", m.fast_max_mutants, "max_mutants", m.max_mutants),
        atMost(.min_mutants, min_mutants_label, m.min_mutants, "fast_max_mutants", m.fast_max_mutants),
        nonzero(.timeout_floor_secs, "mutation timeout_floor_secs", m.timeout_floor_secs),
        nonzero(.timeout_multiplier, "mutation timeout_multiplier", m.timeout_multiplier),
        nonzero(.timeout_retry_multiplier, "mutation timeout_retry_multiplier", m.timeout_retry_multiplier),
        nonzero(.timeout_secs, "mutation timeout_secs", m.timeout_secs),
    };
    for (rules) |rule| {
        if (!rule.violated()) continue;
        const message = try rule.render(allocator);
        return Issue{ .field = rule.field, .message = message };
    }
    return null;
}

/// What breaks a rule, and therefore how its message reads.
const Kind = enum {
    /// A hard cap that must sit strictly above the threshold it backstops.
    must_exceed,
    /// A budget that must not be larger than the budget bounding it.
    must_not_exceed,
    /// A setting whose zero would disable the machinery it sizes.
    non_zero,
    /// A percentage that must land inside 0..limit.
    percent,
};

/// One cross-field invariant as data: whom to blame, what the test is, and the
/// TOML spellings the message names the two operands with. `name` is carried
/// rather than derived from `field` because several settings read differently
/// in a message than their enum tag does (`function_length hard_max_lines`).
const Rule = struct {
    field: Field,
    kind: Kind,
    name: []const u8,
    value: u32,
    limit_name: []const u8 = "",
    limit: u32 = 0,

    /// Whether the values this rule captured break it.
    fn violated(rule: Rule) bool {
        return switch (rule.kind) {
            .must_exceed => rule.value <= rule.limit,
            .must_not_exceed, .percent => rule.value > rule.limit,
            .non_zero => rule.value == 0,
        };
    }

    /// The operator-facing message for a broken rule.
    fn render(rule: Rule, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const both = .{ rule.name, rule.value, rule.limit_name, rule.limit };
        return switch (rule.kind) {
            .must_exceed => std.fmt.allocPrint(allocator, "{s} ({d}) must exceed {s} ({d})", both),
            .must_not_exceed => std.fmt.allocPrint(allocator, "{s} ({d}) must not exceed {s} ({d})", both),
            .non_zero => std.fmt.allocPrint(allocator, "{s} must be non-zero", .{rule.name}),
            .percent => std.fmt.allocPrint(allocator, "{s} must be between 0 and {d}", .{ rule.name, rule.limit }),
        };
    }
};

/// Builds a two-operand rule. `cap` and `atMost` differ only in the direction
/// the comparison has to hold, so they share this constructor.
fn ordered(kind: Kind, field: Field, name: []const u8, value: u32, limit_name: []const u8, limit: u32) Rule {
    return .{
        .field = field,
        .kind = kind,
        .name = name,
        .value = value,
        .limit_name = limit_name,
        .limit = limit,
    };
}

/// A hard cap that must exceed the warning threshold it backstops.
fn cap(field: Field, name: []const u8, value: u32, limit_name: []const u8, limit: u32) Rule {
    return ordered(.must_exceed, field, name, value, limit_name, limit);
}

/// A budget that must not exceed the budget bounding it.
fn atMost(field: Field, name: []const u8, value: u32, limit_name: []const u8, limit: u32) Rule {
    return ordered(.must_not_exceed, field, name, value, limit_name, limit);
}

/// A setting whose zero would disable the machinery it sizes.
fn nonzero(field: Field, name: []const u8, value: u32) Rule {
    return .{ .field = field, .kind = .non_zero, .name = name, .value = value };
}

/// A percentage that must land inside 0..100.
fn percent(field: Field, name: []const u8, value: u32) Rule {
    return .{ .field = field, .kind = .percent, .name = name, .value = value, .limit = 100 };
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

test "validate rejects hard thresholds at or below warning thresholds" {
    var cfg: config.Config = .{};
    cfg.line_length.hard_max_len = cfg.line_length.max_len;
    const got = (try validate(std.testing.allocator, &cfg)).?;
    defer std.testing.allocator.free(got.message);
    try std.testing.expect(got.field == .line_hard_max_len);
}

test "validate spells each rule shape with its exact message" {
    const a = std.testing.allocator;

    var caps: config.Config = .{};
    caps.hard_max_file_lines = caps.max_file_lines;
    const cap_msg = (try validate(a, &caps)).?.message;
    defer a.free(cap_msg);
    try std.testing.expectEqualStrings("hard_max_file_lines (1000) must exceed max_file_lines (1000)", cap_msg);

    var pct: config.Config = .{};
    pct.mutation.min_score_pct = 101;
    const pct_msg = (try validate(a, &pct)).?.message;
    defer a.free(pct_msg);
    try std.testing.expectEqualStrings("mutation min_score_pct must be between 0 and 100", pct_msg);

    var budgets: config.Config = .{};
    budgets.mutation.fast_max_mutants = budgets.mutation.max_mutants + 1;
    const budget_msg = (try validate(a, &budgets)).?.message;
    defer a.free(budget_msg);
    try std.testing.expectEqualStrings("mutation fast_max_mutants (101) must not exceed max_mutants (100)", budget_msg);

    var zeroed: config.Config = .{};
    zeroed.mutation.timeout_secs = 0;
    const zero_msg = (try validate(a, &zeroed)).?.message;
    defer a.free(zero_msg);
    try std.testing.expectEqualStrings("mutation timeout_secs must be non-zero", zero_msg);
}
