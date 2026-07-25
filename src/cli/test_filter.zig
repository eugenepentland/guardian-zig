//! `test-filter`: report the test-name filter a local edit loop could use, and
//! everything that filter would miss. Read-only and non-gating by construction
//! — it runs no tests, writes nothing, and is dispatched outside the check
//! registry so it can never join the `all` suite or narrow a gate.
//!
//! The split is deliberate. Zig passes `--test-filter` to the *compiler*, so a
//! filtered build never analyzes the tests it skipped: it cannot prove the test
//! binary compiles, which is exactly how a call-site change can ship green
//! against a suite that no longer builds. `commit`, the pre-commit hook, and CI
//! therefore keep running the project's whole `[gate] test_command`; this
//! command only ever prints a suggestion for the human or agent in the loop.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const scope = @import("../scope.zig");
const ast_index = @import("../ast/index.zig");
const import_graph = @import("../ast/import_graph.zig");
const test_filter = @import("../test_filter.zig");

/// CLI name, dispatched by check.zig outside the registry.
pub const command_name = "test-filter";

const notice = "a filtered build never analyzes the tests it skipped, so it cannot prove the " ++
    "test binary compiles — gate with the whole test_command";

const JsonReport = struct {
    base: []const u8,
    changed_files: usize,
    names: []const []const u8,
    unnamed_blocks: usize,
    testless_files: []const []const u8,
    unindexed_paths: []const []const u8,
    dependent_files: usize,
    dependent_tests: usize,
    args: []const u8,
    gate_command: []const u8,
    notice: []const u8 = notice,
};

/// Derives the filter for the current diff and reports it. Never fails a build:
/// an underivable filter is reported as "run the whole suite", which is always
/// the correct answer.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const decision = try scope.resolve(ctx.allocator, ctx.project_dir, ctx.against, .{});
    if (decision.wholeTree()) |reason| return reportUnscoped(ctx, reason);
    const plan = decision.plan().?;
    const index = try ast_index.build(ctx.allocator, ctx.project_dir, ctx.cfg.exclude);
    const graph = try import_graph.build(ctx.allocator, ctx.project_dir);
    const derivation = try test_filter.derive(ctx.allocator, .{
        .changed = plan.files,
        .index = &index,
        .graph = graph,
    });
    const args = try test_filter.renderArgs(ctx.allocator, derivation.names, ctx.cfg.test_filter.flag);
    if (ctx.json) return reportJson(ctx, plan, derivation, args);
    reportText(ctx, plan, derivation);
    if (ctx.args_only) try writeArgs(args);
}

/// Reports that no filter could be derived because the run could not be
/// diff-scoped at all (no base ref, no git, or guardian's own config moved).
fn reportUnscoped(ctx: *types.RunCtx, reason: []const u8) types.RunError!void {
    if (ctx.json) {
        return reportJson(ctx, .{ .base = "", .files = &.{} }, .{}, "");
    }
    reporter.ok("test-filter: no filter derived — run the whole suite (`{s}`)", .{ctx.cfg.gate.test_command});
    reporter.detail("  reason: {s}\n", .{reason});
    if (ctx.args_only) try writeArgs("");
}

/// Prints the human report: the derived names, the ready-to-paste arguments,
/// and every reason the filtered run is not the suite. The caveats are printed
/// unconditionally — including in `--args` mode, where they go to stderr while
/// the arguments go to stdout — so a filtered green can't be read as a suite
/// green.
fn reportText(ctx: *types.RunCtx, plan: scope.Plan, d: test_filter.Derivation) void {
    if (d.isEmpty()) {
        reporter.ok("test-filter: no test names derived — run the whole suite (`{s}`)", .{ctx.cfg.gate.test_command});
    } else {
        reporter.ok("test-filter: {d} test name(s) from {d} changed path(s) since {s}", .{
            d.names.len,
            plan.files.len,
            plan.base,
        });
        reportNames(d.names);
        // `eval`, not bare $(...): command substitution word-splits but does not
        // process quotes, so a test name containing spaces would be torn into
        // separate arguments (and a name containing `--x` would reach the build
        // as a flag). The names are POSIX single-quoted, which is what makes
        // handing them to `eval` safe.
        reporter.detail("  run: eval \"{s} $(guardian-check test-filter {s} --args)\"\n", .{
            ctx.cfg.gate.test_command,
            ctx.project_dir,
        });
    }
    reporter.detail("  NOT a substitute for the suite:\n", .{});
    reportGaps(d);
    reporter.detail("    - {s} (`{s}`)\n", .{ notice, ctx.cfg.gate.test_command });
}

/// How many derived names the human report shows before summarizing the rest.
/// The full list is one `--args` (or `--json`) away; a wall of 150 names would
/// bury the coverage caveats printed under it, which are the point.
const preview_names: usize = 5;

/// Prints a short preview of the derived names.
fn reportNames(names: []const []const u8) void {
    for (names[0..@min(preview_names, names.len)]) |name| reporter.detail("    {s}\n", .{name});
    if (names.len > preview_names) {
        reporter.detail("    ... and {d} more\n", .{names.len - preview_names});
    }
}

/// Prints the coverage gaps that apply to this derivation, skipping the ones
/// that are empty so the report stays readable.
fn reportGaps(d: test_filter.Derivation) void {
    if (d.unnamed_blocks > 0) {
        reporter.detail("    - {d} unnamed `test {{ }}` block(s) in the changed files always run and cannot be filtered by name\n", .{d.unnamed_blocks});
    }
    if (d.testless_files.len > 0) {
        reporter.detail("    - {d} changed file(s) declare no test at all: {s}\n", .{ d.testless_files.len, d.testless_files[0] });
    }
    if (d.unindexed_paths.len > 0) {
        reporter.detail("    - {d} changed path(s) are not indexed source, so nothing is derived from them: {s}\n", .{ d.unindexed_paths.len, d.unindexed_paths[0] });
    }
    if (d.dependent_tests > 0) {
        reporter.detail("    - {d} test(s) in {d} unchanged file(s) that import a changed one are NOT in this filter\n", .{ d.dependent_tests, d.dependent_files });
    }
}

/// Emits the machine-readable report, always carrying the `notice` so a tool
/// consuming it cannot lose the incompleteness warning.
fn reportJson(ctx: *types.RunCtx, plan: scope.Plan, d: test_filter.Derivation, args: []const u8) types.RunError!void {
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, JsonReport{
        .base = plan.base,
        .changed_files = plan.files.len,
        .names = d.names,
        .unnamed_blocks = d.unnamed_blocks,
        .testless_files = d.testless_files,
        .unindexed_paths = d.unindexed_paths,
        .dependent_files = d.dependent_files,
        .dependent_tests = d.dependent_tests,
        .args = args,
        .gate_command = ctx.cfg.gate.test_command,
    }, .{});
    reporter.detail("{s}\n", .{json});
}

/// Writes the argument string to stdout so `--args` can be interpolated into a
/// command — `eval "<test_command> $(guardian-check test-filter . --args)"`,
/// since command substitution word-splits without processing quotes. Stdout is
/// deliberately separate from the report on stderr: a caller that captures the
/// arguments still sees the coverage caveats.
///
/// An empty derivation writes an empty line, which interpolates to no arguments
/// at all — the caller then runs its whole suite, never zero tests.
fn writeArgs(args: []const u8) types.RunError!void {
    var buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    try out.interface.print("{s}\n", .{args});
    try out.interface.flush();
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Test Filter - Reports no filter when the run cannot be diff-scoped

test "an unscoped run reports the whole test command instead of a filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const cfg: @import("../config.zig").Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };
    // A ref git cannot resolve is a whole-tree decision, so no filter exists.
    ctx.against = "guardian-no-such-ref-zzz";
    try run(&ctx);

    // The report names the project's whole suite, never a narrowed command.
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "run the whole suite") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "zig build test") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "-Dtest-filter") == null);
}
