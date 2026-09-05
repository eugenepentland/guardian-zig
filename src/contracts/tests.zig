//! Behavioral fixtures for configured operation contracts.
const std = @import("std");
const config = @import("../config.zig");
const parser = @import("../config_parser.zig");
const sources = @import("../ast/index.zig");
const index = @import("index.zig");
const analysis = @import("analyze.zig");

// spec: Operation Contracts - Follows imported aliases and recursive write effects
test "contracts trace imported aliases and wrappers without matching comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try a.dupeSentinel(u8,
        \\const store = @import("store.zig");
        \\const persist = store.save;
        \\fn bad() void { ((persist())) catch return; }
        \\fn good() !void { try persist(); }
        \\fn untouched() void { const s = "disk.writeFile() catch return"; _ = s; }
    , 0);
    const second = try a.dupeSentinel(u8,
        \\pub fn save() !void { try inner(); }
        \\fn inner() !void { try disk.writeFile(); }
    , 0);
    const entries = [_]sources.Entry{
        .{ .rel_path = "src/api.zig", .content = first, .tree = try std.zig.Ast.parse(a, first, .{}) },
        .{ .rel_path = "src/store.zig", .content = second, .tree = try std.zig.Ast.parse(a, second, .{}) },
    };
    const graph = try index.build(a, &.{ .files = &entries });
    const rules = [_]config.ContractRule{.{ .name = "write", .kind = "durable_write", .functions = &.{"src/api.zig::*"}, .operations = &.{"*.writeFile"}, .reason = "Writes must report failure" }};
    const marked = try graph.effects(a, rules[0].operations);
    try std.testing.expect(marked[graph.resolve("src/api.zig::good").?]);
    const rows = try analysis.run(a, &graph, &rules, null);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("src/api.zig::bad", rows[0].function);
    try std.testing.expectEqualStrings("failure-erased", rows[0].code);
    try std.testing.expectEqualStrings("no-write-result", rows[1].code);
}

// spec: Operation Contracts - Parses scoped policies and rejects malformed contracts
test "contracts parser accepts policies and rejects unknown kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parser.parse(a,
        \\[[contract]]
        \\name = "source"
        \\kind = "transaction"
        \\functions = ["src/api.zig::*"]
        \\operations = ["*.writeFile"]
        \\reason = "Use the transaction owner"
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.contracts.len);
    try std.testing.expectEqualStrings("source", cfg.contracts[0].name);
    try std.testing.expectError(error.InvalidConfig, parser.parse(a,
        \\[[contract]]
        \\name = "broken"
        \\kind = "typo"
        \\functions = ["src/api.zig::*"]
        \\operations = ["*.writeFile"]
        \\reason = "Must fail closed"
    ));
}

// spec: Operation Contracts - Checks raw boundaries and keeps identity evidence advisory
test "contracts boundaries allow only declared owners and identity remains reviewable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeSentinel(u8,
        \\fn owner() !void { try disk.writeFile(); }
        \\fn bypass() !void { try disk.writeFile(); try disk.writeFile(); }
        \\fn decoder() void { parseRaw(); }
        \\fn request() void { parseRaw(); }
        \\fn stale(id: u64, rev: u64) void { selectTarget(id); }
        \\fn checked(id: u64, rev: u64) void { validate(id, rev); selectTarget(id); }
        \\fn misleading(id: u64, rev: u64) void { log("validate(id, rev)"); selectTarget(id); }
    , 0);
    const entries = [_]sources.Entry{.{ .rel_path = "src/api.zig", .content = source, .tree = try std.zig.Ast.parse(a, source, .{}) }};
    const graph = try index.build(a, &.{ .files = &entries });
    const rules = [_]config.ContractRule{
        .{ .name = "mutation", .kind = "transaction", .functions = &.{"src/api.zig::*"}, .operations = &.{"*.writeFile"}, .allow = &.{"src/api.zig::owner"}, .reason = "Use owner" },
        .{ .name = "json", .kind = "decoder", .functions = &.{"src/api.zig::*"}, .operations = &.{"src/api.zig::parseRaw"}, .allow = &.{"src/api.zig::decoder"}, .reason = "Use decoder" },
        .{ .name = "target", .kind = "identity", .functions = &.{"src/api.zig::*"}, .operations = &.{"src/api.zig::selectTarget"}, .validators = &.{"src/api.zig::validate"}, .identity = &.{"id"}, .revision = &.{"rev"}, .reason = "Use validated target" },
    };
    const rows = try analysis.run(a, &graph, &rules, null);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqualStrings("src/api.zig::bypass", rows[0].function);
    try std.testing.expectEqualStrings("src/api.zig::request", rows[1].function);
    try std.testing.expectEqualStrings("identity-unverified", rows[2].code);
    try std.testing.expectEqualStrings("validator-unverified", rows[3].code);
    try std.testing.expectEqualStrings("identity-unverified", rows[4].code);
    try std.testing.expectEqual(.review, rows[3].confidence);
    const subset = try analysis.run(a, &graph, &rules, .decoder);
    try std.testing.expectEqual(@as(usize, 1), subset.len);
}

// spec: Operation Contracts - Reports missing declarations instead of silently disabling policies
test "contracts renamed declaration is a review finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try index.build(a, &.{ .files = &.{} });
    const rule: config.ContractRule = .{ .name = "missing", .kind = "transaction", .functions = &.{"src/api.zig::gone"}, .operations = &.{"*.writeFile"}, .reason = "Rename the policy with the owner" };
    const rows = try analysis.run(a, &graph, &.{rule}, null);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("unmatched-selector", rows[0].code);
    try std.testing.expectEqual(.review, rows[0].confidence);
}

// spec: Operation Contracts - Traces recursive effects and aliases of external operations
test "contracts recursion and external aliases retain error paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeSentinel(u8,
        \\const persist = disk.writeFile;
        \\fn entry() void { one() catch return; }
        \\fn one() !void { try two(); }
        \\fn two() !void { if (again) try one(); try persist(); }
        \\fn missing() void {}
    , 0);
    const entries = [_]sources.Entry{.{ .rel_path = "src/api.zig", .content = source, .tree = try std.zig.Ast.parse(a, source, .{}) }};
    const graph = try index.build(a, &.{ .files = &entries });
    const rule: config.ContractRule = .{ .name = "write", .kind = "durable_write", .functions = &.{"src/api.zig::entry"}, .operations = &.{"*.writeFile"}, .reason = "Report recursive write failures" };
    const rows = try analysis.run(a, &graph, &.{rule}, null);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("failure-erased", rows[0].code);
    var renamed = rule;
    renamed.functions = &.{"src/api.zig::missing"};
    const missing = try analysis.run(a, &graph, &.{renamed}, null);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("unmatched-operation", missing[0].code);
}
