//! One compatibility ledger for removed and folded commands/checks. Config
//! validation, doctor, and migration notices all consult this table so an
//! upgrade cannot be accepted in one surface and rejected in another.

const std = @import("std");

/// One retired spelling and the live mechanism that supersedes it.
pub const Info = struct { name: []const u8, folded_into: []const u8 };
/// Shared wording for checks retired as advisory style opinions.
pub const style_tier = "retired style tier";

/// Complete compatibility ledger for all retired check and command names.
pub const all = [_]Info{
    .{ .name = "spec-drift", .folded_into = "pub-api-surface" },
    .{ .name = "comptime-quota", .folded_into = "panic-budget" },
    .{ .name = "doc-quality", .folded_into = "doc-comments" },
    .{ .name = "vague-name-blacklist", .folded_into = "naming" },
    .{ .name = "dup-const", .folded_into = "repeated-string-literal" },
    .{ .name = "returns-per-function", .folded_into = "cognitive-complexity" },
    .{ .name = "usingnamespace-ban", .folded_into = "deprecated-alias/compiler" },
    .{ .name = "magic-number", .folded_into = style_tier },
    .{ .name = "stringly-typed-switches", .folded_into = "concept" },
    .{ .name = "boolean-param-ban", .folded_into = style_tier },
    .{ .name = "struct-method-cap", .folded_into = "file-size/type-size" },
    .{ .name = "optional-density", .folded_into = style_tier },
    .{ .name = "repeated-switch-on-enum", .folded_into = style_tier },
    .{ .name = "static-factory-ban", .folded_into = "ban-globals" },
    .{ .name = "init-hygiene", .folded_into = "init-deinit-symmetry/errdefer-in-init" },
    .{ .name = "compile-error-explanation", .folded_into = "compiler diagnostics" },
    .{ .name = "escape-discipline", .folded_into = "retired opt-in" },
    .{ .name = "stdout-flush", .folded_into = "retired Zig transition" },
    .{ .name = "history", .folded_into = "the dora.jsonl sink and external analysis" },
};

/// Returns migration information for a retired name, or null for a typo/live name.
pub fn find(name: []const u8) ?Info {
    for (all) |item| if (std.mem.eql(u8, item.name, name)) return item;
    return null;
}

test "compatibility ledger includes removed checks and commands" {
    try std.testing.expect(find("magic-number") != null);
    try std.testing.expect(find("history") != null);
    try std.testing.expect(find("not-retired") == null);
}
