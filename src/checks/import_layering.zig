//! The project-configurable import-DIRECTION check: enforces the
//! `[[layering]]` rules a project declares in its own guardian.toml — "a file
//! here may not import a file there, and here is why".
//!
//! **Boundary with the `imports` check, which shares this graph.** `imports`
//! detects CYCLES: a structural illness, always a defect, exempt from nothing,
//! and derivable from the graph alone with no configuration at all. This check
//! is the other half — DECLARED ARCHITECTURE. A layering edge is perfectly
//! acyclic and compiles fine; it is wrong only because the project said which
//! way its layers point. Nothing here reads a cycle and nothing there reads a
//! rule, so the two verdicts can never be confused for one another: a green
//! `imports` says the graph is sound, a green `import-layering` says it also
//! points the way the project meant.
//!
//! The two findings that motivated it, from an eda audit on 2026-08-14:
//!
//!   1. **One upward edge.** `src/kicad_pcb/import_layout_command.zig` — a
//!      core-layer file whose whole job is a file format — imports
//!      `src/serve/pcb_layout_import.zig`, reaching UP into the web layer,
//!      because the sidecar-persistence helper it wants happens to live in
//!      `serve/`. Nothing in the tree could say that was wrong: the edge is
//!      acyclic, so `imports` passes; `[[boundary]]` could name it, but its
//!      `forbidden` side is a bare substring with no allow list and no reason,
//!      so it cannot carve out the one sanctioned adapter that every real
//!      layering rule eventually needs.
//!   2. **A 38-file coupling surface to ratchet down.** `serve/` imports
//!      placement internals across 38 files — 35 of them reaching directly into
//!      a 12.3k-line `optimizer.zig` — because the solver and the data types it
//!      operates on share one file. The planned `placement/model.zig`
//!      extraction wants exactly this shape of gate: freeze today's 38 edges,
//!      fail the 39th, and let the count only fall as files move onto the
//!      extracted types. That is what per-edge baselining buys — see below.
//!
//! **One violation per (rule, source file, target file), identity
//! `<rule>|<from>|<to>`.** The identity is deliberately the EDGE and not the
//! file: a migration's whole value is that the frozen set shrinks one import at
//! a time, and a per-file key would freeze a file wholesale and hide the second
//! forbidden import it grew. `<rule>` leads so one file's debt under two rules
//! stays two rows, and so renaming a rule reads as "these edges moved" rather
//! than as brand-new debt. Because the key is content-derived (baseline v3 tier
//! 1), rewording this file's message never re-keys a consumer's baseline.
//!
//! **Matching is on RESOLVED, project-relative paths.** `import_graph` already
//! normalizes every edge against the importing file's directory, so the
//! `../serve/pcb_layout_import.zig` a core file actually writes is matched as
//! `src/serve/pcb_layout_import.zig` — which is the only spelling a `to` glob
//! could ever be written against, since the relative one depends on where the
//! importer happens to sit. `std`, `builtin`, `root` and package imports are
//! not paths and are never candidates.
//!
//! Zero `[[layering]]` entries is the zero-config default: the check passes
//! without walking a single file.

const std = @import("std");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const import_graph = @import("../ast/import_graph.zig");
const walk = @import("../walk.zig");
const config = @import("../config.zig");

const Allocator = std.mem.Allocator;

const check_name = "import-layering";

const fix_hint = "invert the dependency, or move the shared type into a module both layers may " ++
    "import; add the sanctioned adapter to that [[layering]] rule's allow list.";

/// The extension a resolved edge must carry to be a candidate target. An
/// `@import` of a package (`httpz`, `guardian`) is a MODULE name, not a path,
/// but the graph still normalizes it against the importing file's directory —
/// so `@import("httpz")` inside `src/serve/` arrives here as `src/serve/httpz`,
/// a string a `to = ["src/serve/*"]` glob would happily match. Layering rules
/// are about files, so an edge with no `.zig` suffix is dropped before any glob
/// sees it and a rule can never fire on a package name.
const zig_extension = ".zig";

/// True when a resolved import edge names a source file rather than a package
/// module (see `zig_extension`).
fn isPathImport(edge: []const u8) bool {
    return std.mem.endsWith(u8, edge, zig_extension);
}

/// True when any glob in `patterns` names `path`. Guardian's ordinary pattern
/// syntax: `*` is the wildcard, and a pattern without one is a plain substring
/// match (`walk.matchGlob`).
fn matchesAny(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        if (walk.matchGlob(path, pattern)) return true;
    }
    return false;
}

/// True when `rule` constrains the file at `source`: covered by `from` and not
/// exempted by `allow`. `allow` wins, so the one sanctioned adapter can live
/// inside the constrained subtree — the carve-out `[[boundary]]` has no way to
/// express, and the reason a real layering rule can be written at all.
fn constrains(rule: config.LayeringRule, source: []const u8) bool {
    if (matchesAny(rule.allow, source)) return false;
    return matchesAny(rule.from, source);
}

/// The violation for one forbidden edge. `line` is deliberately absent: the
/// graph carries no import positions, and a line number is in no baseline key
/// tier anyway, so the record names the two files instead — which is what a
/// reader greps for.
fn violationFor(
    allocator: Allocator,
    rule: config.LayeringRule,
    source: []const u8,
    target: []const u8,
) Allocator.Error!reporter.Violation {
    const message = try std.fmt.allocPrint(
        allocator,
        "imports {s} — forbidden by layering rule '{s}' — {s}",
        .{ target, rule.name, rule.reason },
    );
    const identity = try std.fmt.allocPrint(
        allocator,
        "{s}|{s}|{s}",
        .{ rule.name, source, target },
    );
    return .{
        .check = check_name,
        .file = source,
        .message = message,
        .fix_hint = fix_hint,
        .identity = identity,
    };
}

/// Orders findings by their identity, so the report is stable across runs. The
/// walker hands files back in filesystem order, which differs between machines
/// and between checkouts of the same tree.
fn lessThan(_: void, a: reporter.Violation, b: reporter.Violation) bool {
    return std.mem.order(u8, a.identity.?, b.identity.?) == .lt;
}

/// Pure core: every forbidden edge in `nodes`, one violation per (rule, source,
/// target). Takes the already-built graph, so the same function judges the real
/// tree and a handful of synthetic nodes in a test.
pub fn analyzeGraph(
    allocator: Allocator,
    nodes: []const import_graph.Node,
    rules: []const config.LayeringRule,
) Allocator.Error![]const reporter.Violation {
    var found: std.ArrayList(reporter.Violation) = .empty;
    for (rules) |rule| {
        for (nodes) |node| {
            if (!constrains(rule, node.path)) continue;
            for (node.edges) |edge| {
                if (!isPathImport(edge) or !matchesAny(rule.to, edge)) continue;
                try found.append(allocator, try violationFor(allocator, rule, node.path, edge));
            }
        }
    }
    const slice = try found.toOwnedSlice(allocator);
    std.mem.sort(reporter.Violation, slice, {}, lessThan);
    return slice;
}

/// The findings whose source file no exemption glob names. Honors the per-check
/// `[[allow]] check = "import-layering"` channel and the top-level `exclude`
/// list — the latter because this check builds its own graph rather than
/// reading the shared source index that would have applied it.
fn retained(
    allocator: Allocator,
    violations: []const reporter.Violation,
    skip: []const []const u8,
) Allocator.Error![]const reporter.Violation {
    if (skip.len == 0) return violations;
    var kept: std.ArrayList(reporter.Violation) = .empty;
    for (violations) |v| {
        if (matchesAny(skip, v.file.?)) continue;
        try kept.append(allocator, v);
    }
    return kept.toOwnedSlice(allocator);
}

/// Entry point for the import-layering check (opt-in: declare `[[layering]]`
/// entries).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const rules = ctx_param.cfg.layering_rules;
    if (rules.len == 0) {
        reporter.ok("import-layering: no [[layering]] rules configured", .{});
        return;
    }

    const nodes = try import_graph.build(allocator, ctx_param.project_dir);
    const skip = try std.mem.concat(allocator, []const u8, &.{
        ctx_param.cfg.extraAllowed(check_name),
        ctx_param.cfg.exclude,
    });
    const found = try retained(allocator, try analyzeGraph(allocator, nodes, rules), skip);

    if (found.len == 0) {
        reporter.ok("import-layering: no forbidden edges ({d} rule(s), {d} files)", .{ rules.len, nodes.len });
        return;
    }
    reporter.fail("import-layering FAILED ({d} forbidden edge(s))", .{found.len});
    // emitQuiet, not emit: one shared `fix:` line closes the list below, and
    // repeating a near-identical remedy under every edge is console noise. The
    // hint still rides each record into last-run.jsonl, which has no "beneath
    // the list".
    for (found) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Removes a test artifact when it is there. Test-local, and the only reason
/// this file names the filesystem at all — the check itself reads the tree
/// exclusively through `import_graph`.
fn deleteIfExists(path: []const u8) void {
    const fs = @import("../fs.zig");
    fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => reporter.detail("  test cleanup {s}: {s}\n", .{ path, @errorName(e) }),
    };
}

/// The motivating eda rule, spelled exactly as a project would declare it.
const core_rule = config.LayeringRule{
    .name = "core-no-serve",
    .from = &.{ "src/kicad_pcb/*", "src/placement/*" },
    .to = &.{"src/serve/*"},
    .allow = &.{"src/kicad_pcb/serve_adapter.zig"},
    .reason = "the format layer must not reach up into the web layer",
};

const test_rules = [_]config.LayeringRule{core_rule};

// spec: Import Layering - Flags an import from a rule's from set into its to set

test "analyzeGraph flags a forbidden edge and names both files in its identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]import_graph.Node{
        .{
            .path = "src/kicad_pcb/import_layout_command.zig",
            .edges = &.{ "src/serve/pcb_layout_import.zig", "src/walk.zig" },
        },
    };
    const out = try analyzeGraph(a, nodes, &test_rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(check_name, out[0].check);
    // Identity is the EDGE — rule, source, target — so a migration's frozen set
    // shrinks one import at a time instead of freezing a file wholesale.
    try testing.expectEqualStrings(
        "core-no-serve|src/kicad_pcb/import_layout_command.zig|src/serve/pcb_layout_import.zig",
        out[0].identity.?,
    );
    try testing.expectEqualStrings(
        "src/kicad_pcb/import_layout_command.zig: imports src/serve/pcb_layout_import.zig — " ++
            "forbidden by layering rule 'core-no-serve' — " ++
            "the format layer must not reach up into the web layer",
        try reporter.flatLine(a, out[0]),
    );
}

// spec: Import Layering - Ignores a forbidden import from a file the rule's allow list exempts

test "analyzeGraph exempts the sanctioned adapter inside the constrained subtree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The adapter lives inside `from`, imports straight into `to`, and is the
    // whole reason `allow` exists: without it a layering rule can only be
    // all-or-nothing, which is why [[boundary]] never fit this job.
    const nodes = &[_]import_graph.Node{
        .{
            .path = "src/kicad_pcb/serve_adapter.zig",
            .edges = &.{"src/serve/pcb_layout_import.zig"},
        },
    };
    const out = try analyzeGraph(arena.allocator(), nodes, &test_rules);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Import Layering - Ignores an edge outside the rule's from or to sets

test "analyzeGraph ignores edges either side of the rule misses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = &[_]import_graph.Node{
        // Wrong source layer: serve/ importing serve/ is not this rule's business.
        .{ .path = "src/serve/routes.zig", .edges = &.{"src/serve/pcb_layout_import.zig"} },
        // Right source layer, target nowhere near `to`.
        .{ .path = "src/kicad_pcb/writer.zig", .edges = &.{"src/walk.zig"} },
        // The DOWNWARD edge — serve/ into kicad_pcb/ — is the direction the
        // rule declares as legal, and a substring matcher run over the pair
        // without regard for which side is which would flag it.
        .{ .path = "src/serve/pcb_layout_import.zig", .edges = &.{"src/kicad_pcb/writer.zig"} },
        // A package import (`@import("httpz")`) resolves against the importer's
        // own directory, so it arrives as a `to`-matching string with no .zig
        // suffix — dropped, because layering rules are about files.
        .{ .path = "src/kicad_pcb/reader.zig", .edges = &.{"src/serve/httpz"} },
    };
    const out = try analyzeGraph(arena.allocator(), nodes, &test_rules);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Import Layering - Matches a relative import against its resolved project-relative path

test "analyzeGraph matches the resolved path of a relative import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The fixture's core module writes `@import("../utils/helpers.zig")`. No
    // `src/utils/*` glob can name that raw string — only the resolved,
    // project-relative form it normalizes to, which is the whole reason a rule
    // is written against resolved paths.
    const rules = [_]config.LayeringRule{.{
        .name = "core-no-utils",
        .from = &.{"src/core/*"},
        .to = &.{"src/utils/*"},
        .reason = "core is the leaf layer",
    }};
    const nodes = try import_graph.build(a, "test-project");
    const out = try analyzeGraph(a, nodes, &rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(
        "core-no-utils|src/core/math.zig|src/utils/helpers.zig",
        out[0].identity.?,
    );
}

// spec: Import Layering - Passes trivially when no layering rules are configured

test "analyzeGraph finds nothing when no rules are configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = &[_]import_graph.Node{
        .{
            .path = "src/kicad_pcb/import_layout_command.zig",
            .edges = &.{"src/serve/pcb_layout_import.zig"},
        },
    };
    const out = try analyzeGraph(arena.allocator(), nodes, &.{});
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Import Layering - Reports one violation per rule, source file, and target file

test "analyzeGraph reports each forbidden edge separately and in a stable order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two forbidden targets from one file, plus a second constrained file whose
    // walk order is deliberately reversed against the sorted output — a
    // migration reads this list as "38 edges left", so each one is its own row
    // and the rows do not shuffle between runs.
    const nodes = &[_]import_graph.Node{
        .{
            .path = "src/placement/solver.zig",
            .edges = &.{"src/serve/pcb_layout_import.zig"},
        },
        .{
            .path = "src/kicad_pcb/import_layout_command.zig",
            .edges = &.{ "src/serve/routes.zig", "src/serve/pcb_layout_import.zig" },
        },
    };
    const out = try analyzeGraph(a, nodes, &test_rules);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings(
        "core-no-serve|src/kicad_pcb/import_layout_command.zig|src/serve/pcb_layout_import.zig",
        out[0].identity.?,
    );
    try testing.expectEqualStrings(
        "core-no-serve|src/kicad_pcb/import_layout_command.zig|src/serve/routes.zig",
        out[1].identity.?,
    );
    try testing.expectEqualStrings(
        "core-no-serve|src/placement/solver.zig|src/serve/pcb_layout_import.zig",
        out[2].identity.?,
    );
}

// spec: Import Layering - Freezes each forbidden edge separately so only a new one fails

test "an existing forbidden edge baselines while a new one grows the ledger" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const baseline = @import("../baseline.zig");

    const path = "zig-cache/test-import-layering-baseline.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    const before = &[_]import_graph.Node{
        .{
            .path = "src/kicad_pcb/import_layout_command.zig",
            .edges = &.{"src/serve/pcb_layout_import.zig"},
        },
        .{ .path = "src/placement/solver.zig", .edges = &.{"src/serve/routes.zig"} },
    };
    const recorded = try baseline.keyedViolations(a, check_name, "", try analyzeGraph(a, before, &test_rules));
    try testing.expect((try baseline.lifecycle(a, path, recorded, false, true)) == .created);
    // Frozen debt: the same two edges are matched, so the gate stays green on
    // a tree that has not moved.
    try testing.expect((try baseline.lifecycle(a, path, recorded, false, true)) == .matched);

    // A THIRD edge fails, and the ledger reports exactly it — not the file, and
    // not the two edges already accepted.
    const grew = &[_]import_graph.Node{
        .{
            .path = "src/kicad_pcb/import_layout_command.zig",
            .edges = &.{ "src/serve/pcb_layout_import.zig", "src/serve/routes.zig" },
        },
        .{ .path = "src/placement/solver.zig", .edges = &.{"src/serve/routes.zig"} },
    };
    const after = try baseline.keyedViolations(a, check_name, "", try analyzeGraph(a, grew, &test_rules));
    const outcome = try baseline.lifecycle(a, path, after, false, true);
    try testing.expect(outcome == .grown);
    try testing.expectEqual(@as(usize, 1), outcome.grown.new_lines.len);
    try testing.expect(std.mem.indexOf(u8, outcome.grown.new_lines[0], "imports src/serve/routes.zig") != null);

    // And the per-EDGE key is what lets a 38-edge coupling surface fall one
    // import at a time: dropping ONE of the frozen pair is a clean shrink, not
    // a re-accept of the file's remaining debt.
    const fixed = &[_]import_graph.Node{
        .{
            .path = "src/kicad_pcb/import_layout_command.zig",
            .edges = &.{"src/serve/pcb_layout_import.zig"},
        },
        .{ .path = "src/placement/solver.zig", .edges = &.{} },
    };
    const shrunk = try baseline.keyedViolations(a, check_name, "", try analyzeGraph(a, fixed, &test_rules));
    try testing.expect((try baseline.lifecycle(a, path, shrunk, false, true)) == .shrunk);
}

// spec: Import Layering - Skips a finding whose source file an allow entry or top-level exclude glob names

test "retained drops findings from an exempted source path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = &[_]import_graph.Node{
        .{
            .path = "src/kicad_pcb/import_layout_command.zig",
            .edges = &.{"src/serve/pcb_layout_import.zig"},
        },
    };
    const found = try analyzeGraph(a, nodes, &test_rules);
    // No exemptions: the finding stands, and the slice is handed back untouched.
    try testing.expectEqual(@as(usize, 1), (try retained(a, found, &.{})).len);
    // A `[[allow]] check = "import-layering"` path (or a top-level `exclude`
    // glob) drops it, exactly as it drops the file from every other check.
    try testing.expectEqual(@as(usize, 0), (try retained(a, found, &.{"src/kicad_pcb/*"})).len);
}
