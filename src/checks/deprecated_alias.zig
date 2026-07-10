//! deprecated-alias — token-level ban on pre-0.15 / soon-removed std spellings.
//!
//! Zig 0.15 renamed a batch of std containers and I/O idioms and left the old
//! names behind as `/// Deprecated` aliases (std.zig: `pub const
//! ArrayListUnmanaged = ArrayList;`). The alias compiles today and is a
//! no-op cost, but it is a guaranteed tree-wide breaking diff the day 0.16
//! drops it — and an AI agent trained on 0.13/0.14 corpora reaches for the old
//! spelling by reflex. This check freezes the modern spelling in place while
//! the rename is still `sed`-grade.
//!
//! Detection is purely lexical (a chain of identifier tokens via the shared
//! banned-symbol scanner), so string literals, comments, and doc-comments that
//! merely mention a banned name are never flagged. The table below documents
//! the 0.15/0.16 rationale for every entry.

const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");

// The versioned alias table. `require_call = true` matches only the
// `(`-application form (a generic instantiation / call); the default matches a
// bare or `std.`-qualified reference anywhere.
const rules = [_]helper.Rule{
    // `std.ArrayListUnmanaged` is a deprecated alias of `std.ArrayList` in 0.15
    // — std.zig literally reads `pub const ArrayListUnmanaged = ArrayList;`.
    // Identical type today; a whole-tree rename when 0.16 removes the alias.
    .{ .chain = &.{"ArrayListUnmanaged"}, .display = "std.ArrayListUnmanaged" },
    // `std.ArrayListAlignedUnmanaged` — same deprecation, vs `array_list.Aligned`.
    .{ .chain = &.{"ArrayListAlignedUnmanaged"}, .display = "std.ArrayListAlignedUnmanaged" },
    // `std.array_list.Managed` is the deprecated *managed* ArrayList
    // (array_list.zig: `/// Deprecated. pub fn Managed`). Prefer the unmanaged
    // `std.ArrayList`, which stores no allocator.
    .{ .chain = &.{ "std", "array_list", "Managed" }, .display = "std.array_list.Managed" },
    // Managed hashmap constructors. NOT deprecated in 0.15 — they still exist
    // and work — but discouraged: std has moved to the unmanaged maps, which
    // keep the allocator on the owning struct instead of inside every map. They
    // are included here (rather than left unenforced) because the generic
    // `[[allow]]` path machinery is a clean per-path escape hatch for a consumer
    // that keeps managed maps on purpose. Only the `(`-application form is a
    // type/construction, so `require_call`.
    .{ .chain = &.{ "std", "StringHashMap" }, .display = "std.StringHashMap (managed)", .require_call = true },
    .{ .chain = &.{ "std", "AutoHashMap" }, .display = "std.AutoHashMap (managed)", .require_call = true },
    .{ .chain = &.{ "std", "StringArrayHashMap" }, .display = "std.StringArrayHashMap", .require_call = true },
    .{ .chain = &.{ "std", "AutoArrayHashMap" }, .display = "std.AutoArrayHashMap", .require_call = true },
    // `usingnamespace` was removed from the language outright in 0.15 (the
    // tokenizer now lexes it as a bare identifier). Overlaps usingnamespace-ban
    // by design: that check argues symbol-hiding, this one argues "the keyword
    // no longer exists in the grammar."
    .{ .chain = &.{"usingnamespace"}, .display = "usingnamespace" },
    // Pre-0.15 stdout/stderr writer idioms. 0.15's "Writergate" replaced
    // `std.io.getStdOut().writer()` with `std.fs.File.stdout()` plus a buffered
    // `std.io.Writer` and an explicit `flush()`. `(`-application form.
    .{ .chain = &.{"getStdOut"}, .display = "getStdOut", .require_call = true },
    .{ .chain = &.{"getStdErr"}, .display = "getStdErr", .require_call = true },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    // A deprecated spelling breaks on 0.16 regardless of where it sits, so —
    // unlike the hidden-dependency bans — this check does NOT wave through
    // `test {…}` blocks or `pub fn main`. The only escape hatch is a `[[allow]]`
    // path glob, merged in from guardian.toml by helper.scan.
    .allow_in_tests = false,
    .allow_in_main = false,
    .fix_hint = "std.ArrayListUnmanaged -> std.ArrayList; managed std.*HashMap(...) -> the *Unmanaged map with " ++
        "an allocator-per-call; drop usingnamespace for explicit re-exports; getStdOut/getStdErr -> " ++
        "std.fs.File.stdout()/stderr().",
};

/// Pure-function entry: scans `content` for deprecated std spellings and returns
/// the violation lines (allocator-owned). Empty slice = pass. Used by the unit
/// tests; the production walker goes through `run` into the shared helper.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Entry point for the deprecated-alias check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    return helper.scan(ctx_param, "deprecated-alias", opts);
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Deprecated Alias - Flags the std.ArrayListUnmanaged deprecated 0.15 alias

test "analyzeContent flags std.ArrayListUnmanaged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f() void {
        \\    var xs: std.ArrayListUnmanaged(u8) = .empty;
        \\    _ = &xs;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Deprecated Alias - Flags a managed hashmap construction such as std.StringHashMap

test "analyzeContent flags managed std.StringHashMap construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f(alloc: std.mem.Allocator) void {
        \\    var m = std.StringHashMap(u32).init(alloc);
        \\    _ = &m;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Deprecated Alias - Flags the usingnamespace keyword removed in 0.15

test "analyzeContent flags usingnamespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const foo = @import("foo.zig");
        \\pub usingnamespace foo;
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Deprecated Alias - Flags the pre-0.15 getStdOut and getStdErr writer idioms

test "analyzeContent flags getStdOut and getStdErr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn out() void {
        \\    const o = std.io.getStdOut();
        \\    const e = std.io.getStdErr();
        \\    _ = o;
        \\    _ = e;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 2), out.len);
}

// spec: Deprecated Alias - Allows the unmanaged and 0.15 replacement spellings

test "analyzeContent allows the modern replacement spellings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const A = std.ArrayList(u8);
        \\const M = std.StringHashMapUnmanaged(u32);
        \\const N = std.AutoHashMapUnmanaged(u32, u32);
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores a banned spelling inside a string or comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\// std.ArrayListUnmanaged is deprecated
        \\const s = "std.ArrayListUnmanaged";
        \\fn f() void {}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "helper honors an allowed-path glob for deprecated-alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f() void {
        \\    var xs: std.ArrayListUnmanaged(u8) = .empty;
        \\    _ = &xs;
        \\}
    ;
    // A file matching an [[allow]] glob is skipped wholesale — the same
    // mechanism helper.scan feeds from guardian.toml's per-check allow rules.
    var exempt = opts;
    exempt.allowed_paths = &.{"src/vendor/*"};
    const flagged = try helper.analyzeContent(a, "src/x.zig", content, exempt);
    const skipped = try helper.analyzeContent(a, "src/vendor/lib.zig", content, exempt);
    try std.testing.expectEqual(@as(usize, 1), flagged.len);
    try std.testing.expectEqual(@as(usize, 0), skipped.len);
}
