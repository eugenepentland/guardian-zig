//! twin-parity: the registry of capabilities this project exposes on MORE THAN
//! ONE surface, and whether anything proves the surfaces still agree.
//!
//! A CLI subcommand, an HTTP route and an MCP tool that all "export the PDF"
//! are three implementations of one answer. Nothing in a compiler, and nothing
//! else in this suite, can see that they are supposed to be the same: they share
//! no type, no call, and often no file. So they drift — one gains a clamp, one
//! keeps an older merge rule, one spells a JSON field differently — and every
//! surface passes its own tests the whole time.
//!
//! The motivating audit (eda, 2026-08-14) counted **~19 capabilities on 2+
//! surfaces and exactly ONE with a test asserting the surfaces return the same
//! bytes**. The reimplemented pairs had already diverged measurably: different
//! BOM-merge gating, different clamps, different JSON for one field. None of it
//! was a bug anyone introduced knowingly; each was a change made on one surface
//! by someone who did not know a twin existed.
//!
//! **The registry is the deliverable, and the check is what keeps it honest.**
//! `[[twin]]` entries are a committed fact — "this capability is reachable
//! here, here and here" — and this check reads them two ways:
//!
//!   * a twin naming a `parity_test` must HAVE that test. This is the rule that
//!     always blocks: a test named in config and absent from the tree is either
//!     a rename nobody propagated or a deletion nobody noticed, and neither is
//!     ever intentional.
//!   * a twin naming none is reported as `twin-uncovered` — one row, keyed by
//!     the twin's name, so today's uncovered twins freeze in the baseline and
//!     the count can only shrink. Coverage becomes a RATCHET: rows start
//!     uncovered, each gains a `parity_test` over time, and a row that loses one
//!     is growth the gate refuses (`[baseline] deny_growth = ["twin-parity"]`).
//!
//! **Surfaces are documentation and nothing resolves them.** `"http:/api/x"`,
//! `"mcp:generate_fence"`, `"cli:export-pdf"` are free-form labels: this check
//! has no idea what an MCP tool is, and inventing a per-surface resolver would
//! make the registry unwritable for every project whose surfaces are shaped
//! differently. What the count buys is real, though — fewer than two surfaces is
//! a config error, because a capability with one implementation has nothing to
//! disagree with.
//!
//! **The two rows are keyed apart on purpose.** Both keys are built from the
//! twin's name, but a `parity` row and an `uncovered` row are different
//! subjects (`divergent-const` splits `const <name>` from `mirror <file>|<name>`
//! for the same reason). Sharing one key would let a FROZEN uncovered row
//! silently absorb the missing-test failure the moment someone adds a
//! `parity_test` pointing at a test that does not exist — turning the one rule
//! that must always block into the one that never does.
//!
//! Matching a `parity_test` is CONTAINMENT against declared test names, not
//! equality: a test name is prose that gets extended (`"pdf export matches the
//! HTTP body, including the cover page"`), and requiring the exact string would
//! make every clarifying rename a gate failure. The scan walks `src/` and
//! `test/` — the same two roots the `spec` check's tag scan reads, and for the
//! same reason: it is the tests ON DISK, never the compiled test set, so a
//! `-Dtest-filter` build sees exactly this list.
//!
//! Zero `[[twin]]` entries is the zero-config default: the check passes without
//! reading a file.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const test_decls = @import("../test_filter.zig");
const config = @import("../config.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const check_name = "twin-parity";

/// Directory walked in addition to the shared source index. `src/` arrives
/// pre-parsed through `RunCtx.source_index`; `test/` is not in that index at
/// all, and a project that keeps its suite there would otherwise read as having
/// no tests whatsoever.
const test_root = "test";

const fix_hint = "write the test named by `parity_test` (one call per surface, " ++
    "asserting the same bytes), or point `parity_test` at the test that already does.";

/// Which of the two rules produced a finding. Carried into the baseline key, so
/// a frozen `uncovered` row can never stand in for a `parity` failure.
const Kind = enum {
    /// `parity_test` is declared and no test in the tree answers to it.
    parity,
    /// No `parity_test` is declared at all — the coverage ratchet's row.
    uncovered,

    /// The word this kind is spelled with in a violation's identity, and hence
    /// in `.guardian/baselines/twin-parity.txt`.
    fn tag(self: Kind) []const u8 {
        return switch (self) {
            .parity => "parity",
            .uncovered => "uncovered",
        };
    }
};

// ── Pure core ───────────────────────────────────────────────────────────

/// True when some declared test name CONTAINS `wanted`.
///
/// Containment, not equality: a test name is prose and grows clarifying clauses,
/// and a config that had to track every rewording would be edited to silence the
/// gate rather than to say something true.
fn covered(test_names: []const []const u8, wanted: []const u8) bool {
    for (test_names) |name| {
        if (std.mem.indexOf(u8, name, wanted) != null) return true;
    }
    return false;
}

/// Renders a twin's surfaces as `a, b, c` — the half of the message that says
/// what is actually at stake, since the twin's name alone does not tell a reader
/// which two implementations are supposed to agree.
fn formatSurfaces(allocator: Allocator, rule: config.TwinRule) Allocator.Error![]const u8 {
    return std.mem.join(allocator, ", ", rule.surfaces);
}

/// Builds the one violation for a twin whose `parity_test` names no test.
fn missingTestViolation(
    allocator: Allocator,
    rule: config.TwinRule,
    wanted: []const u8,
) Allocator.Error!reporter.Violation {
    return .{
        .check = check_name,
        .message = try std.fmt.allocPrint(
            allocator,
            "twin '{s}' names parity_test \"{s}\" but no test declares a name containing it " ++
                "\u{2014} {d} surface(s): {s}",
            .{ rule.name, wanted, rule.surfaces.len, try formatSurfaces(allocator, rule) },
        ),
        .fix_hint = fix_hint,
        .identity = try identityFor(allocator, .parity, rule.name),
        .metric = rule.surfaces.len,
    };
}

/// Builds the one violation for a twin that declares no `parity_test`.
fn uncoveredViolation(allocator: Allocator, rule: config.TwinRule) Allocator.Error!reporter.Violation {
    return .{
        .check = check_name,
        .message = try std.fmt.allocPrint(
            allocator,
            "twin '{s}' declares no parity_test \u{2014} {d} surface(s) reimplement one capability " ++
                "with nothing asserting they agree: {s}",
            .{ rule.name, rule.surfaces.len, try formatSurfaces(allocator, rule) },
        ),
        .fix_hint = fix_hint,
        .identity = try identityFor(allocator, .uncovered, rule.name),
        .metric = rule.surfaces.len,
    };
}

/// The baseline identity for one finding: `<kind> <twin name>`. Rendering-
/// independent (the message may be rewritten word for word), and kind-qualified
/// so the two rules never share a row.
fn identityFor(allocator: Allocator, kind: Kind, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ kind.tag(), name });
}

/// Pure core: one violation per twin that is either uncovered or names a test
/// the tree does not declare. Takes the declared test names as plain strings, so
/// the whole rule is testable without a tree on disk.
pub fn analyze(
    allocator: Allocator,
    rules: []const config.TwinRule,
    test_names: []const []const u8,
) Allocator.Error![]const reporter.Violation {
    var violations: std.ArrayList(reporter.Violation) = .empty;
    for (rules) |rule| {
        const wanted = rule.parity_test orelse {
            try violations.append(allocator, try uncoveredViolation(allocator, rule));
            continue;
        };
        if (covered(test_names, wanted)) continue;
        try violations.append(allocator, try missingTestViolation(allocator, rule, wanted));
    }
    return violations.toOwnedSlice(allocator);
}

// ── Collecting the tree's test names ────────────────────────────────────

/// Accumulates every declared test name across both scanned roots.
const NameCtx = struct {
    allocator: Allocator,
    names: *std.ArrayList([]const u8),

    fn add(self: *NameCtx, tree: *const Ast) Allocator.Error!void {
        const found = try test_decls.declaredTests(self.allocator, tree);
        try self.names.appendSlice(self.allocator, found.names);
    }
};

fn indexVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *NameCtx = @ptrCast(@alignCast(raw_ctx));
    const tree = entry.tree orelse return;
    try ctx.add(tree);
}

fn diskVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *NameCtx = @ptrCast(@alignCast(raw_ctx));
    // The bare walk yields no tree (only the shared index carries one), so a
    // `test/` file is parsed here — once, for this check alone.
    var tree = try Ast.parse(ctx.allocator, entry.content, .{});
    try ctx.add(&tree);
}

/// Every test name the project declares, from the shared `src/` index plus a
/// walk of `test/`. Unnamed `test { }` blocks are deliberately dropped by
/// `declaredTests`: there is no text a `parity_test` could ever match them by.
fn collectTestNames(ctx: *registry.RunCtx) walk.WalkError![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var name_ctx: NameCtx = .{ .allocator = ctx.allocator, .names = &names };
    try ast_index.runSrc(ctx.source_index, ctx.allocator, ctx.project_dir, .{
        .ctx = &name_ctx,
        .visit = indexVisit,
    });
    const test_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, test_root });
    try walk.walkZigFiles(ctx.allocator, test_path, .{
        .display_root = test_root,
        .excludes = ctx.cfg.exclude,
    }, .{ .ctx = &name_ctx, .visit = diskVisit });
    return names.toOwnedSlice(ctx.allocator);
}

/// Entry point for the twin-parity check (opt-in: declare `[[twin]]` entries).
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const rules = ctx.cfg.twin_rules;
    if (rules.len == 0) {
        reporter.ok("twin-parity: no [[twin]] rules configured", .{});
        return;
    }
    const test_names = try collectTestNames(ctx);
    const found = try analyze(ctx.allocator, rules, test_names);
    if (found.len == 0) {
        reporter.ok("twin-parity: every twin has a parity test ({d} rule(s))", .{rules.len});
        return;
    }
    reporter.fail("twin-parity FAILED ({d} of {d} twin(s) unproven)", .{ found.len, rules.len });
    // emitQuiet, not emit: one shared `fix:` line closes the list below, and
    // repeating it under every finding is console noise. The hint still rides
    // each record into last-run.jsonl, which has no "beneath the list".
    for (found) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const pdf_twin = config.TwinRule{
    .name = "export-pdf",
    .surfaces = &.{ "cli:export-pdf", "http:/api/schematic-pdf", "mcp:export_pdf" },
    .parity_test = "pdf export matches",
};

// spec: Twin Parity - Passes a twin whose parity test exists in the tree

test "analyze accepts a twin whose parity_test names a declared test" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Containment, not equality: the declared name carries a clarifying tail the
    // config does not track, which is how test names actually evolve.
    const names = [_][]const u8{ "unrelated", "pdf export matches the HTTP body byte for byte" };
    const out = try analyze(a, &.{pdf_twin}, &names);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Twin Parity - Flags a twin whose named parity test is absent from the tree

test "analyze flags a parity_test no declared test answers to" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{"pdf export writes a cover page"};
    const out = try analyze(a, &.{pdf_twin}, &names);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(check_name, out[0].check);
    // Kind-qualified, so a frozen `uncovered export-pdf` row can never absorb
    // this one — the failure mode that would silence the always-blocking rule.
    try testing.expectEqualStrings("parity export-pdf", out[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "pdf export matches") != null);
    // The surfaces ride along: the twin's name alone does not tell a reader
    // which implementations are supposed to agree.
    try testing.expect(std.mem.indexOf(u8, out[0].message, "mcp:export_pdf") != null);
}

// spec: Twin Parity - Reports a twin that declares no parity test as uncovered

test "analyze reports an uncovered twin under its own baseline key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bare = config.TwinRule{
        .name = "fab-package",
        .surfaces = &.{ "http:/api/pcb-gerbers", "cli:export-gerbers" },
    };
    const out = try analyze(a, &.{bare}, &.{});
    try testing.expectEqual(@as(usize, 1), out.len);
    // The ratchet row: keyed by the twin, so it freezes today's uncovered set
    // and `[baseline] deny_growth` makes the count only shrink.
    try testing.expectEqualStrings("uncovered fab-package", out[0].identity.?);
    try testing.expectEqual(@as(u64, 2), out[0].metric.?);
    try testing.expect(std.mem.indexOf(u8, out[0].message, "declares no parity_test") != null);
}

// spec: Twin Parity - Passes trivially when no twin rules are configured

test "analyze finds nothing when no twins are declared" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyze(arena.allocator(), &.{}, &.{"some test"});
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Twin Parity - Keeps each twin's finding to its own rule

test "analyze judges each twin independently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.TwinRule{
        pdf_twin,
        .{ .name = "fence", .surfaces = &.{ "http:/api/pcb-fence", "mcp:generate_fence" } },
    };
    const names = [_][]const u8{"pdf export matches the HTTP body"};
    const out = try analyze(a, &rules, &names);
    // The covered twin is silent; only the uncovered one is reported.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("uncovered fence", out[0].identity.?);
}

// spec: Twin Parity - Collects declared test names from the source index and the test directory

test "collectTestNames reads every named test the project declares" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config.Config = .{};
    var ctx: registry.RunCtx = .{
        .allocator = a,
        .project_dir = "test-project",
        .cfg = &cfg,
        .quiet = true,
    };
    const names = try collectTestNames(&ctx);
    // The fixture declares `test "join"` in src/main.zig. Reading the tree —
    // not the compiled test set — is what makes a -Dtest-filter build see the
    // same list, exactly as the spec check's tag scan does.
    try testing.expect(covered(names, "join"));
    try testing.expect(!covered(names, "no test is named this"));
}
