//! Contract schemas and findings shared by the gates and the read-only audit.
const std = @import("std");
const config = @import("../config.zig");
const walk = @import("../walk.zig");

/// The five opt-in architectural contracts. The tags are the TOML kind spellings.
pub const Kind = enum {
    durable_write,
    persistent_read,
    transaction,
    decoder,
    identity,

    /// Registry name of the gate implementing this policy kind.
    pub fn checkName(self: Kind) []const u8 {
        return switch (self) {
            .durable_write => "durable-write-errors",
            .persistent_read => "persistent-read-errors",
            .transaction => "mutation-boundary",
            .decoder => "request-decoding",
            .identity => "edit-identity",
        };
    }
};

/// A policy violation is definite relative to its declared contract, not a
/// claim of reproduced data loss. Review rows explicitly require human work.
pub const Confidence = enum { violation, review };

/// One stable, independently actionable operation or declaration finding.
pub const Finding = struct {
    check: []const u8,
    rule: []const u8,
    file: []const u8,
    function: []const u8,
    line: u32,
    confidence: Confidence,
    code: []const u8,
    operation: []const u8,
    message: []const u8,
    reason: []const u8,
};

/// Reject inert or ambiguous configuration before inspecting a source tree.
pub fn invalidRule(rule: config.ContractRule) ?[]const u8 {
    if (rule.name.len == 0 or rule.reason.len == 0) return "name and reason must be nonempty";
    for (rule.name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return "name must use letters, digits or hyphens";
    }
    const kind = std.meta.stringToEnum(Kind, rule.kind) orelse return "unknown kind";
    if (rule.functions.len == 0) return "functions must select at least one declaration";
    for (rule.functions) |s| if (std.mem.indexOf(u8, s, "::") == null) return "functions require file::function selectors";
    for (rule.allow) |s| {
        if (std.mem.indexOf(u8, s, "::") == null or std.mem.indexOfAny(u8, s, "*?") != null)
            return "allow requires exact declarations, not wildcard or whole-file exemptions";
    }
    if (rule.operations.len == 0) return "operations must name at least one call boundary";
    if (kind == .identity and (rule.identity.len == 0 or rule.revision.len == 0 or rule.validators.len == 0))
        return "identity requires identity, revision and validators";
    inline for (.{ "functions", "operations", "allow", "validators", "identity", "revision" }) |field| {
        for (@field(rule, field)) |s| if (s.len == 0) return "empty selectors are invalid";
    }
    return null;
}

/// Match qualified declaration names or an explicitly scoped external method.
pub fn matches(selectors: []const []const u8, value: []const u8) bool {
    for (selectors) |selector| if (walk.matchGlob(value, selector)) return true;
    return false;
}

// spec: Operation Contracts - Rejects incomplete contracts and whole-file exemptions
test "contracts reject incomplete declarations and match scoped operations" {
    const rule: config.ContractRule = .{ .name = "save", .kind = "durable_write", .functions = &.{"src/store.zig::*"}, .operations = &.{"*.writeFile"}, .reason = "preserve write failure" };
    try std.testing.expect(invalidRule(rule) == null);
    var bad = rule;
    bad.allow = &.{"src/store.zig"};
    try std.testing.expect(invalidRule(bad) != null);
    bad.allow = &.{"src/store.zig::*"};
    try std.testing.expect(invalidRule(bad) != null);
    bad = rule;
    bad.kind = "identity";
    try std.testing.expect(invalidRule(bad) != null);
    try std.testing.expect(matches(rule.functions, "src/store.zig::save"));
    try std.testing.expect(!matches(rule.functions, "src/http.zig::save"));
    try std.testing.expectEqualStrings("edit-identity", Kind.identity.checkName());
}
