//! The project-configurable banned-symbol check: enforces the `[[ban]]` rules a
//! project declares in its own guardian.toml, on the same engine the compiled
//! ban-* checks use (banned_symbol_helper).
//!
//! The compiled bans encode Guardian's architectural opinions — wall clock, RNG,
//! filesystem — and their rule tables are comptime data, so a project had no way
//! to say "this call may not appear in this layer" about a symbol of its own. A
//! typical case: endpoints were refactored onto a mandatory wrapper API, and the
//! gate should stop a future endpoint from calling the underlying function
//! directly. Making a struct field non-defaulted covers that only when you own
//! the callee's signature; a third-party or cross-layer symbol had no
//! config-side path at all.
//!
//! Zero `[[ban]]` entries is the zero-config default: the check passes without
//! reading a single file.

const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");
const reporter = @import("../reporter.zig");
const walk = @import("../walk.zig");
const ast_index = @import("../ast/index.zig");
const config = @import("../config.zig");

const Allocator = std.mem.Allocator;

const check_name = "ban";

/// Stands in for a rule's `reason` when the project didn't give one. The
/// sanctioned alternative is the most useful half of a ban message, so its
/// absence says so out loud instead of printing a bare "this is forbidden".
const no_reason = "no reason given (add reason = \"...\" to the [[ban]] rule)";

const fix_hint = "use the alternative named in the rule's reason, " ++
    "or add this path to that [[ban]] rule's allow list.";

/// Compiles one configured rule into the engine rule that matches it. `display`
/// is the dotted chain, which is also what the violation identity keys on
/// (`<file>|<chain>`), so rewording a `reason` never re-keys a baseline.
fn engineRule(allocator: Allocator, rule: config.BanRule) Allocator.Error!helper.Rule {
    return .{
        .chain = rule.chain,
        .display = try std.mem.join(allocator, ".", rule.chain),
        .note = rule.reason orelse no_reason,
    };
}

/// True when `rule` governs `rel_path`: covered by `paths` (empty = the whole
/// tree) and not exempted by `allow`. `allow` wins, so the sanctioned wrapper's
/// own file can sit inside the banned subtree.
fn covers(rule: config.BanRule, rel_path: []const u8) bool {
    for (rule.allow) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return false;
    }
    if (rule.paths.len == 0) return true;
    for (rule.paths) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// Pure core: every `[[ban]]` violation in one file. Rules that don't govern the
/// file are dropped before the scan, so a file no rule reaches is never even
/// parsed — the reason a whole-tree default scope stays cheap. Takes a
/// `FileEntry` so the walker's already-parsed tree is reused when there is one.
pub fn analyzeFile(
    allocator: Allocator,
    entry: walk.FileEntry,
    rules: []const config.BanRule,
) Allocator.Error![]const reporter.Violation {
    var applicable: std.ArrayList(helper.Rule) = .empty;
    for (rules) |rule| {
        if (!covers(rule, entry.rel_path)) continue;
        try applicable.append(allocator, try engineRule(allocator, rule));
    }
    if (applicable.items.len == 0) return &.{};
    const opts: helper.ScanOpts = .{ .rules = applicable.items, .fix_hint = fix_hint };
    const found = if (entry.tree) |tree|
        try helper.analyzeTree(allocator, entry.rel_path, tree, opts)
    else
        try helper.analyzeRecords(allocator, entry.rel_path, entry.content, opts);
    // Stamp the owning check on each record: the engine leaves it blank for its
    // pure-function entry point, and the JSONL sink reads it.
    const stamped = try allocator.alloc(reporter.Violation, found.len);
    for (found, stamped) |record, *out| {
        out.* = record;
        out.check = check_name;
    }
    return stamped;
}

const FileCtx = struct {
    allocator: Allocator,
    rules: []const config.BanRule,
    violations: *std.ArrayList(reporter.Violation),
    /// Paths exempted from every rule at once via `[[allow]] check = "ban"`,
    /// the same per-check exemption channel the other checks honor.
    exempt: []const []const u8,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileCtx = @ptrCast(@alignCast(raw_ctx));
    for (ctx.exempt) |pattern| {
        if (walk.matchGlob(entry.rel_path, pattern)) return;
    }
    const found = try analyzeFile(ctx.allocator, entry, ctx.rules);
    try ctx.violations.appendSlice(ctx.allocator, found);
}

/// Entry point for the ban check (opt-in: declare `[[ban]]` entries).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const rules = ctx_param.cfg.ban_rules;
    if (rules.len == 0) {
        reporter.ok("ban: no [[ban]] rules configured", .{});
        return;
    }

    var found: std.ArrayList(reporter.Violation) = .empty;
    var fs_ctx: FileCtx = .{
        .allocator = allocator,
        .rules = rules,
        .violations = &found,
        .exempt = ctx_param.cfg.extraAllowed(check_name),
    };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{
        .ctx = &fs_ctx,
        .visit = fileVisit,
    });

    if (found.items.len == 0) {
        reporter.ok("ban: no banned symbols ({d} rule(s))", .{rules.len});
        return;
    }
    reporter.fail("ban FAILED ({d} occurrence(s))", .{found.items.len});
    for (found.items) |violation| reporter.emit(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const test_rules = [_]config.BanRule{.{
    .chain = &.{ "optimizer", "placeFromPoses" },
    .paths = &.{"src/serve/*"},
    .allow = &.{"src/serve/route_seed.zig"},
    .reason = "call through RouteSeed instead",
}};

/// A walker entry for a file the test supplies inline, with no pre-parsed tree
/// (the standalone path — `analyzeFile` parses it itself).
fn entryOf(rel_path: []const u8, content: [:0]const u8) walk.FileEntry {
    return .{ .rel_path = rel_path, .content = content };
}

// spec: Ban - Flags a configured symbol chain used inside the rule's path scope

test "analyzeFile flags a banned chain inside the configured paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\fn handle() void { optimizer.placeFromPoses(board); }
    ;
    const out = try analyzeFile(a, entryOf("src/serve/routes.zig", source), &test_rules);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("ban", out[0].check);
    // Identity is content-derived and carries its own file: `<file>|<chain>`.
    try std.testing.expectEqualStrings("src/serve/routes.zig|optimizer.placeFromPoses", out[0].identity.?);

    // Same verdict through the walker's pre-parsed tree, which is what the real
    // run hands over — the scan must never depend on re-parsing the file.
    var tree = try std.zig.Ast.parse(a, source, .{});
    const reused = try analyzeFile(a, .{
        .rel_path = "src/serve/routes.zig",
        .content = source,
        .tree = &tree,
    }, &test_rules);
    try std.testing.expectEqual(@as(usize, 1), reused.len);
    try std.testing.expectEqualStrings(out[0].message, reused[0].message);
}

// spec: Ban - Ignores a use outside the rule's path scope

test "analyzeFile ignores a banned chain outside the configured paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), entryOf("src/tools/bench.zig",
        \\fn run() void { optimizer.placeFromPoses(board); }
    ), &test_rules);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Ban - Ignores a use in a file the rule's allow list exempts

test "analyzeFile ignores a banned chain in an allowed file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The sanctioned wrapper lives inside the banned subtree and must still be
    // able to make the call it wraps.
    const out = try analyzeFile(arena.allocator(), entryOf("src/serve/route_seed.zig",
        \\pub fn place() void { optimizer.placeFromPoses(board); }
    ), &test_rules);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Ban - Ends the violation message with the rule's reason

test "analyzeFile ends the message with the configured reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, entryOf("src/serve/routes.zig",
        \\fn handle() void { optimizer.placeFromPoses(board); }
    ), &test_rules);
    try std.testing.expectEqualStrings(
        "src/serve/routes.zig:1: optimizer.placeFromPoses is banned here — call through RouteSeed instead",
        try reporter.flatLine(a, out[0]),
    );

    // With no reason the message says the rule is missing one, rather than
    // printing a forbidden symbol with no alternative.
    const bare = [_]config.BanRule{.{ .chain = &.{ "optimizer", "placeFromPoses" } }};
    const plain = try analyzeFile(a, entryOf("src/serve/routes.zig",
        \\fn handle() void { optimizer.placeFromPoses(board); }
    ), &bare);
    try std.testing.expect(std.mem.endsWith(u8, plain[0].message, no_reason));
}

// spec: Ban - Passes trivially when no ban rules are configured

test "analyzeFile finds nothing when no rules are configured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), entryOf("src/serve/routes.zig",
        \\fn handle() void { optimizer.placeFromPoses(board); }
    ), &.{});
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Ban - Applies a rule with no paths to the whole source tree

test "analyzeFile applies a rule without paths everywhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rules = [_]config.BanRule{.{ .chain = &.{"gethostbyname"} }};
    const out = try analyzeFile(arena.allocator(), entryOf("src/anywhere/deep/file.zig",
        \\fn lookup() void { _ = gethostbyname(host); }
    ), &rules);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
