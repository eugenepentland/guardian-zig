//! `optimize-divergence` command — build and run the project's whole test
//! suite under BOTH `-Doptimize=safe` and `-Doptimize=fast`, then fail when the
//! two runs disagree about which tests pass.
//!
//! Why: Zig's safety-checked Illegal Behavior categories PANIC in Debug and
//! ReleaseSafe but are undefined behavior in ReleaseFast and ReleaseSmall, so a
//! suite that is green under one mode proves nothing about the other. Replicated
//! on this repo's pinned toolchain (0.17.0-dev.1683+5ceec001b):
//!
//!     var x: u32 = 300; _ = &x; const y: u8 = @intCast(x);
//!
//! panics with a stack trace and exit 134 under default safety, and SEGFAULTS
//! with exit 139 under `-O ReleaseFast`. The 0.15 `undefined`-operand rule
//! compounds it: reading `undefined` is a compile error only at comptime, IB at
//! runtime, and — as zlint's rationale for the rule puts it — "otherwise
//! undetectable ... will not cause panics in release builds".
//!
//! Why here: the live consumer `eda` is float-heavy geometry with a WASM
//! target, and Guardian itself ships `zig-out/bin/guardian-check` built `safe`
//! while its own test suite keeps the plain debug default (see CLAUDE.md). The
//! two modes already differ routinely in this ecosystem, and nothing else in
//! the gate looks at the difference.
//!
//! THE HONEST LIMIT: this catches only divergence that the SUITE EXERCISES. It
//! is a sampling technique, not a proof — an unexercised UB path stays invisible
//! exactly as it does under mutation testing, whose cost profile it shares
//! (build + run the whole suite, twice). That is precisely why it is a
//! nightly-tier step and never a member of `all`, never a dependency of
//! `zig build` or `zig build test`, and never part of `commit`.
//!
//! Legitimate divergence exists — a test that asserts panic behavior cannot
//! panic under `fast`, and a timing-sensitive test can flip on speed alone — so
//! `[optimize_divergence] exempt` is a per-test allowance list.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const walk = @import("../walk.zig");
const wiring = @import("../wiring.zig");
const dora = @import("../dora.zig");
const child_env = @import("../child_env.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

/// CLI name that check.zig dispatches to this command.
pub const command_name = "optimize-divergence";

/// Cap on the captured output of one child suite run.
const max_suite_output_bytes: u64 = 16 * 1024 * 1024;

/// Dedicated Zig cache for the child builds, so they neither contend with the
/// parent build's cache lock nor evict its artifacts. Kept between runs (it is
/// under the git-ignored, digest-excluded `.guardian/cache/`), so only the
/// first run of each mode pays a cold compile. It is disposable: deleting it
/// costs one cold compile per mode and nothing else, and its size counts toward
/// `doctor`'s `.guardian/cache` advisory (measured on Guardian's own suite:
/// ~533 MiB for both modes, against a 1024 MiB default warning).
const child_cache_dir = ".guardian/cache/zig-optimize-divergence";

/// The two optimize modes compared. Zig 0.17 spells them lowercase on the
/// command line, which is the mistake this file must not make.
const Mode = enum {
    safe,
    fast,

    /// The `-Doptimize=` argument that selects this mode.
    fn flag(self: Mode) []const u8 {
        return switch (self) {
            .safe => "-Doptimize=safe",
            .fast => "-Doptimize=fast",
        };
    }
};

/// What one mode did to one test. A test that does not appear in a run's list
/// passed there — runners report the exceptions, not the passes.
const Outcome = enum {
    /// The runner reported the test as failed (an assertion, a leak, an error).
    failed,
    /// The process died on a signal while running it (a panic, or a SEGV from
    /// unchecked IB — the divergence this command exists for).
    crashed,
};

/// One test's non-passing result in one mode.
const TestResult = struct {
    name: []const u8,
    outcome: Outcome,
};

/// One mode's finished suite run.
const SuiteRun = struct {
    mode: Mode,
    /// True when the child exited 0 (suite green, and it compiled at all).
    exit_ok: bool,
    /// Every test the run reported as not passing, in the order reported.
    results: []const TestResult = &.{},
    /// Wall time of this mode's build+run, for the cost line.
    elapsed_ms: u64 = 0,

    /// This test's outcome in this run, or null when it passed here.
    fn outcomeOf(self: SuiteRun, name: []const u8) ?Outcome {
        for (self.results) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.outcome;
        }
        return null;
    }
};

/// How two runs disagreed.
const DivergenceKind = enum {
    /// Passed under safe, not under fast — an optimizer-visible behavior change.
    fast_only,
    /// Passed under fast, not under safe — usually a safety check that only
    /// fires in `safe` (the shape a panic-asserting test takes).
    safe_only,
    /// Non-passing in both, but differently (reported failure vs. a signal).
    outcome_changed,
    /// The runs' overall exit status disagrees with no per-test difference to
    /// explain it: a build that only fails in one mode, an aborted runner, a
    /// leak or cap failure that named no test. Never exemptable — there is no
    /// test name to exempt.
    suite_outcome,
};

/// One disagreement between the two runs.
const Divergence = struct {
    kind: DivergenceKind,
    /// The test's name, or "" for a `suite_outcome` divergence.
    name: []const u8 = "",
    safe: ?Outcome = null,
    fast: ?Outcome = null,
};

/// Entry point for the optimize-divergence command: run the suite once per
/// mode, compare the two result sets, and fail on any non-exempt disagreement.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const cfg = ctx.cfg.optimize_divergence;
    if (!cfg.enabled) {
        reporter.ok("optimize-divergence: disabled ([optimize_divergence] enabled = false)", .{});
        return;
    }
    const argv = try splitCommand(ctx.allocator, cfg.test_command);
    if (argv.len == 0) {
        reporter.fail("optimize-divergence FAILED: [optimize_divergence] test_command is empty", .{});
        return error.CheckFailed;
    }
    reporter.ok("optimize-divergence: running `{s}` under safe and fast (the suite runs twice)", .{
        cfg.test_command,
    });
    const safe = try execute(ctx, argv, .safe);
    const fast = try execute(ctx, argv, .fast);
    return report(ctx, safe, fast);
}

/// Runs the suite once in `mode` and parses what the run reported. A child that
/// cannot be spawned at all fails the command — an unmeasurable mode must never
/// read as agreement.
fn execute(ctx: *types.RunCtx, base_argv: []const []const u8, mode: Mode) types.RunError!SuiteRun {
    const a = ctx.allocator;
    const argv = try modeArgv(a, base_argv, mode);
    var stopwatch = dora.startStopwatch();
    var env = wiring.cloneEnviron(a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return spawnFailed(mode, @errorName(e)),
    };
    defer env.deinit();
    // The tree is already gated; the child only has to compile and run the
    // tests, so its own wired Guardian gate no-ops (see child_env.zig).
    try env.put(child_env.skip_checks, "1");
    const res = std.process.run(a, wiring.io(), .{
        .argv = argv,
        .cwd = .{ .path = ctx.project_dir },
        .environ_map = &env,
        .stdout_limit = .limited64(max_suite_output_bytes),
        .stderr_limit = .limited64(max_suite_output_bytes),
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return spawnFailed(mode, @errorName(e)),
    };
    const elapsed = stopwatch.elapsedMs();
    const combined = try std.mem.concat(a, u8, &.{ res.stderr, res.stdout });
    const run_result: SuiteRun = .{
        .mode = mode,
        .exit_ok = res.term.success(),
        .results = try parseResults(a, combined),
        .elapsed_ms = elapsed,
    };
    reporter.ok("optimize-divergence: {s} finished in {d}s — {d} non-passing test(s), suite {s}", .{
        @tagName(mode),
        elapsed / std.time.ms_per_s,
        run_result.results.len,
        if (run_result.exit_ok) "green" else "red",
    });
    return run_result;
}

/// Reports a child that could not be run at all and fails the command.
fn spawnFailed(mode: Mode, name: []const u8) types.RunError {
    reporter.fail("optimize-divergence FAILED: could not run the {s} suite ({s})", .{ @tagName(mode), name });
    return error.CheckFailed;
}

/// The argv for one mode: the configured command, its own Zig cache, and the
/// `-Doptimize=` flag. Pure, so the flag spelling is asserted without a build.
fn modeArgv(a: Allocator, base_argv: []const []const u8, mode: Mode) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(a, base_argv);
    try list.appendSlice(a, &.{ "--cache-dir", child_cache_dir, mode.flag() });
    return list.toOwnedSlice(a);
}

/// Splits a command string into an argv vector on ASCII whitespace. No shell
/// semantics — the argv runs directly, exactly like `[gate] test_command`.
fn splitCommand(a: Allocator, cmd: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    while (it.next()) |tok| try list.append(a, tok);
    return list.toOwnedSlice(a);
}

// ── Parsing what a run reported ────────────────────────────────────────

/// Zig's build runner names a non-passing test on its own line:
/// `error: 'root.test.foo' failed:` (or `failed without output`), and
/// `error: 'root.test.foo' terminated with signal SEGV` for a crash. Guardian's
/// own runner prints `<n> <name>...FAIL (<error>)` in its terminal mode. Both
/// spellings are read here, so the comparison works whichever runner a project
/// wired — and the two runs being compared always speak the same one.
const build_runner_prefix = "error: '";
const guardian_fail_marker = "...FAIL";
const signal_marker = "terminated with signal";

/// Collects every non-passing test named anywhere in one run's output,
/// first occurrence wins. Pure over the captured text.
fn parseResults(a: Allocator, output: []const u8) Allocator.Error![]const TestResult {
    var list: std.ArrayList(TestResult) = .empty;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const found = parseLine(line) orelse continue;
        if (contains(list.items, found.name)) continue;
        try list.append(a, found);
    }
    return list.toOwnedSlice(a);
}

/// One line's non-passing test, or null when the line reports none.
fn parseLine(line: []const u8) ?TestResult {
    if (std.mem.startsWith(u8, line, build_runner_prefix)) {
        const rest = line[build_runner_prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, '\'') orelse return null;
        const name = rest[0..end];
        if (name.len == 0) return null;
        const crashed = std.mem.indexOf(u8, rest[end..], signal_marker) != null;
        return .{ .name = name, .outcome = if (crashed) .crashed else .failed };
    }
    return guardianRunnerLine(line);
}

/// A `<n> <name>...FAIL (<error>)` line from Guardian's own test runner.
fn guardianRunnerLine(line: []const u8) ?TestResult {
    const marker = std.mem.indexOf(u8, line, guardian_fail_marker) orelse return null;
    const space = std.mem.indexOfScalar(u8, line[0..marker], ' ') orelse return null;
    const index_text = line[0..space];
    _ = std.fmt.parseInt(u32, index_text, 10) catch return null;
    const name = line[space + 1 .. marker];
    if (name.len == 0) return null;
    return .{ .name = name, .outcome = .failed };
}

fn contains(results: []const TestResult, name: []const u8) bool {
    for (results) |r| {
        if (std.mem.eql(u8, r.name, name)) return true;
    }
    return false;
}

// ── Comparing the two result sets ──────────────────────────────────────

/// Pure comparison of two finished runs: every test whose result differs
/// between the modes, minus the exempt names, plus a whole-suite divergence
/// when the exit statuses disagree with nothing per-test to explain it.
///
/// A test that is non-passing in BOTH modes in the same way is not divergence —
/// it is a red suite, which `zig build test` already reports.
///
/// The whole-suite fallback fires only when NOTHING per-test differed even
/// before exemptions: an exempt test that reds one mode's suite already
/// explains the exit-status difference, and reporting it again would make the
/// exemption unusable.
fn compare(
    a: Allocator,
    safe: SuiteRun,
    fast: SuiteRun,
    exempt: []const []const u8,
) Allocator.Error![]const Divergence {
    var list: std.ArrayList(Divergence) = .empty;
    var per_test: usize = 0;
    for (safe.results) |r| {
        const other = fast.outcomeOf(r.name);
        per_test += try appendDivergence(a, &list, r.name, r.outcome, other, exempt);
    }
    for (fast.results) |r| {
        const mine = safe.outcomeOf(r.name);
        per_test += try appendDivergence(a, &list, r.name, mine, r.outcome, exempt);
    }
    if (per_test == 0 and safe.exit_ok != fast.exit_ok) {
        try list.append(a, .{ .kind = .suite_outcome });
    }
    return list.toOwnedSlice(a);
}

/// Appends one test's divergence when its two outcomes differ, it is not
/// exempt, and it was not already recorded from the other side. Returns 1 when
/// the two outcomes differed AT ALL (exempt or not), so the caller can tell a
/// suite-level disagreement that nothing explains from one an exemption covers.
fn appendDivergence(
    a: Allocator,
    list: *std.ArrayList(Divergence),
    name: []const u8,
    safe: ?Outcome,
    fast: ?Outcome,
    exempt: []const []const u8,
) Allocator.Error!usize {
    const kind = kindOf(safe, fast) orelse return 0;
    if (recorded(list.items, name)) return 0;
    if (isExempt(name, exempt)) return 1;
    try list.append(a, .{ .kind = kind, .name = name, .safe = safe, .fast = fast });
    return 1;
}

/// The divergence kind for one test's two outcomes, or null when they agree.
fn kindOf(safe: ?Outcome, fast: ?Outcome) ?DivergenceKind {
    const s = safe orelse return if (fast == null) null else .fast_only;
    const f = fast orelse return .safe_only;
    return if (s == f) null else .outcome_changed;
}

/// True when `name` matches any exemption pattern (`*` globs, else substring).
fn isExempt(name: []const u8, exempt: []const []const u8) bool {
    for (exempt) |pattern| {
        if (walk.matchGlob(name, pattern)) return true;
    }
    return false;
}

fn recorded(found: []const Divergence, name: []const u8) bool {
    for (found) |d| {
        if (std.mem.eql(u8, d.name, name)) return true;
    }
    return false;
}

// ── Verdict ────────────────────────────────────────────────────────────

/// Prints the comparison and gates on it.
fn report(ctx: *types.RunCtx, safe: SuiteRun, fast: SuiteRun) types.RunError!void {
    const a = ctx.allocator;
    if (unusable(safe, fast)) {
        reporter.fail(
            "optimize-divergence FAILED: neither mode reported any test result — " ++
                "is `{s}` a working whole-suite command?",
            .{ctx.cfg.optimize_divergence.test_command},
        );
        return error.CheckFailed;
    }
    const found = try compare(a, safe, fast, ctx.cfg.optimize_divergence.exempt);
    if (found.len == 0) {
        reporter.ok("optimize-divergence: safe and fast agree on every test ({d}s + {d}s)", .{
            safe.elapsed_ms / std.time.ms_per_s,
            fast.elapsed_ms / std.time.ms_per_s,
        });
        return;
    }
    reporter.fail("optimize-divergence FAILED: {d} test(s) behave differently under safe and fast", .{found.len});
    for (found) |d| {
        reporter.emit(.{
            .check = command_name,
            .message = try describe(a, d),
            .identity = d.name,
            .fix_hint = "fix the behavior difference, or list the test in [optimize_divergence] exempt " ++
                "with the reason (panic assertion, timing sensitivity)",
        });
    }
    detail("  note: this samples only what the suite exercises — agreement is not a proof.\n", .{});
    return error.CheckFailed;
}

/// True when neither run produced a single test result AND both were red: the
/// two suites are then not comparable (a compile failure, a missing step, a
/// command that runs no tests), which must fail loudly rather than read green.
fn unusable(safe: SuiteRun, fast: SuiteRun) bool {
    return safe.results.len == 0 and fast.results.len == 0 and !safe.exit_ok and !fast.exit_ok;
}

/// One divergence rendered as its own line.
fn describe(a: Allocator, d: Divergence) Allocator.Error![]const u8 {
    if (d.kind == .suite_outcome) {
        return a.dupe(u8, "the two suites disagree on overall outcome with no test named — " ++
            "one mode failed to build, aborted, or failed a whole-run check");
    }
    return std.fmt.allocPrint(a, "{s}: safe={s} fast={s}", .{
        d.name,
        statusText(d.safe),
        statusText(d.fast),
    });
}

fn statusText(outcome: ?Outcome) []const u8 {
    const o = outcome orelse return "pass";
    return @tagName(o);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Optimize Divergence - Spells the two optimize modes in Zig 0.17 lowercase form

test "the mode flags use the lowercase 0.17 optimize spellings" {
    // The single most common mistake in this repo: `-Doptimize=ReleaseSafe`
    // is a Zig 0.16 spelling and fails the child build outright.
    try testing.expectEqualStrings("-Doptimize=safe", Mode.safe.flag());
    try testing.expectEqualStrings("-Doptimize=fast", Mode.fast.flag());
}

// spec: Optimize Divergence - Appends the optimize flag and an isolated cache to the configured command

test "modeArgv keeps the command and adds the cache dir and optimize flag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try splitCommand(a, "zig build test");
    const argv = try modeArgv(a, base, .fast);
    try testing.expectEqual(@as(usize, 6), argv.len);
    try testing.expectEqualStrings("zig", argv[0]);
    try testing.expectEqualStrings("test", argv[2]);
    // A private cache keeps the child builds off the parent build's cache lock.
    try testing.expectEqualStrings("--cache-dir", argv[3]);
    try testing.expectEqualStrings(child_cache_dir, argv[4]);
    try testing.expectEqualStrings("-Doptimize=fast", argv[5]);
}

// spec: Optimize Divergence - Reads non-passing test names from build runner and Guardian runner output

test "parseResults names failed and crashed tests from either runner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Captured verbatim from this toolchain (see the module header): a failed
    // test, a test the process died on, and Guardian's own runner line.
    const results = try parseResults(arena.allocator(),
        \\test
        \\+- run test 1 pass, 1 fail, 1 crash (3 total)
        \\error: 'root.test.failing one' failed without output
        \\error: 'root.test.cast probe' terminated with signal SEGV
        \\3 root.test.guardian mode...FAIL (TestUnexpectedResult)
        \\4 root.test.skipped one...SKIP
    );
    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqualStrings("root.test.failing one", results[0].name);
    try testing.expectEqual(Outcome.failed, results[0].outcome);
    try testing.expectEqualStrings("root.test.cast probe", results[1].name);
    try testing.expectEqual(Outcome.crashed, results[1].outcome);
    try testing.expectEqualStrings("root.test.guardian mode", results[2].name);
    try testing.expectEqual(Outcome.failed, results[2].outcome);
}

// spec: Optimize Divergence - Reports no divergence when both modes agree on every test

test "compare stays silent when the two runs agree, red or green" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const green_safe: SuiteRun = .{ .mode = .safe, .exit_ok = true };
    const green_fast: SuiteRun = .{ .mode = .fast, .exit_ok = true };
    try testing.expectEqual(@as(usize, 0), (try compare(a, green_safe, green_fast, &.{})).len);
    // Identically red is a red suite, not divergence: `zig build test` owns it.
    const failing = [_]TestResult{.{ .name = "root.test.a", .outcome = .failed }};
    const red_safe: SuiteRun = .{ .mode = .safe, .exit_ok = false, .results = &failing };
    const red_fast: SuiteRun = .{ .mode = .fast, .exit_ok = false, .results = &failing };
    try testing.expectEqual(@as(usize, 0), (try compare(a, red_safe, red_fast, &.{})).len);
}

// spec: Optimize Divergence - Fails a test that passes under one optimize mode and not the other

test "compare reports each one-sided result with the side it came from" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The headline case: an unchecked cast panics under safe and is undefined
    // behavior under fast, where the test sails past it.
    const safe_only = [_]TestResult{.{ .name = "root.test.cast", .outcome = .crashed }};
    // ...and the reverse: the optimizer exploits the UB and the test breaks.
    const fast_only = [_]TestResult{.{ .name = "root.test.geometry", .outcome = .failed }};
    const found = try compare(
        a,
        .{ .mode = .safe, .exit_ok = false, .results = &safe_only },
        .{ .mode = .fast, .exit_ok = false, .results = &fast_only },
        &.{},
    );
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(DivergenceKind.safe_only, found[0].kind);
    try testing.expectEqualStrings("root.test.cast", found[0].name);
    try testing.expectEqual(DivergenceKind.fast_only, found[1].kind);
    try testing.expectEqualStrings("root.test.geometry", found[1].name);
    try testing.expectEqualStrings("root.test.geometry: safe=pass fast=failed", try describe(a, found[1]));
}

// spec: Optimize Divergence - Exempts named tests whose divergence is legitimate

test "compare drops divergences whose test name is exempt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const safe_only = [_]TestResult{
        .{ .name = "root.test.panics on overflow", .outcome = .crashed },
        .{ .name = "root.test.slow timing budget", .outcome = .failed },
        .{ .name = "root.test.real regression", .outcome = .failed },
    };
    const found = try compare(
        a,
        .{ .mode = .safe, .exit_ok = false, .results = &safe_only },
        .{ .mode = .fast, .exit_ok = true },
        // A panic assertion cannot panic under fast; a timing test can flip on
        // speed alone. Both are named; the third divergence is not.
        &.{ "root.test.panics on overflow", "*timing*" },
    );
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("root.test.real regression", found[0].name);
    // Glob and substring matching are the same syntax the rest of the config uses.
    try testing.expect(isExempt("root.test.slow timing budget", &.{"*timing*"}));
    try testing.expect(!isExempt("root.test.other", &.{"*timing*"}));
    // With every diverging test exempt the run is clean, even though the exempt
    // test reds one mode's suite: the exit-status fallback must not re-report
    // what an exemption just covered, or exemptions would be unusable.
    const covered = try compare(
        a,
        .{ .mode = .safe, .exit_ok = false, .results = safe_only[0..1] },
        .{ .mode = .fast, .exit_ok = true },
        &.{"root.test.panics on overflow"},
    );
    try testing.expectEqual(@as(usize, 0), covered.len);
}

// spec: Optimize Divergence - Fails when the two runs disagree with no test named

test "compare reports a whole-suite disagreement nothing per-test explains" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // One mode failed to build, or aborted before naming a test. Silence here
    // would report "the modes agree" about a mode that never ran.
    const found = try compare(a, .{ .mode = .safe, .exit_ok = true }, .{ .mode = .fast, .exit_ok = false }, &.{});
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(DivergenceKind.suite_outcome, found[0].kind);
    try testing.expect(std.mem.indexOf(u8, try describe(a, found[0]), "no test named") != null);
    // An exemption list cannot silence it: there is no test name to exempt.
    const still = try compare(a, .{ .mode = .safe, .exit_ok = true }, .{ .mode = .fast, .exit_ok = false }, &.{"*"});
    try testing.expectEqual(@as(usize, 1), still.len);
}

// spec: Optimize Divergence - Refuses to call two unusable runs an agreement

test "unusable is true only when both runs are red and named no test" {
    const red: SuiteRun = .{ .mode = .safe, .exit_ok = false };
    const green: SuiteRun = .{ .mode = .fast, .exit_ok = true };
    try testing.expect(unusable(red, .{ .mode = .fast, .exit_ok = false }));
    try testing.expect(!unusable(red, green));
    const named = [_]TestResult{.{ .name = "root.test.a", .outcome = .failed }};
    try testing.expect(!unusable(.{ .mode = .safe, .exit_ok = false, .results = &named }, red));
}
