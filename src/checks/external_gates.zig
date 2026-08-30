//! Project-defined non-Zig gates. Commands execute directly as argv arrays in
//! the project directory (never through a shell), and their declared input
//! files participate in Guardian's green-run cache digest.

const std = @import("std");
const wiring = @import("../wiring.zig");
const fs = @import("../fs.zig");
const config = @import("../config.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const external_inputs = @import("../external_inputs.zig");
const benchmark = @import("../benchmark.zig");
const budget_runner = @import("../budget_runner.zig");
const scope = @import("../scope.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const max_output_bytes: usize = 4 * 1024 * 1024;

const check_name = "external-gates";

/// Detail line naming the `[benchmark]` record a misconfigured gate points at.
const benchmark_detail = "benchmark: {s}";

/// One failing invocation, held until the whole set has run.
///
/// Failures are COLLECTED rather than printed as they happen, because the
/// baseline layer reconstructs a check's findings from its output and only an
/// indented line under a header counts (`baseline.extract`). Reporting each
/// failure as its own `reporter.fail` header — which is what this check used to
/// do — produced a check that printed "FAILED" and yielded ZERO keyed
/// violations, so a failing gate was recorded as nothing, compared against a
/// baseline of nothing, and passed. Every `[[external]]` in every project was
/// advisory as a result. See the tests at the bottom of this file.
const Failure = struct {
    violation: reporter.Violation,
    /// Child output or a resource measurement, rendered under the violation.
    detail: []const u8 = "",
};

const Failures = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Failure) = .empty,

    /// Record one failing invocation. `identity` keys it independently of the
    /// message wording, so rephrasing a diagnostic never re-keys a baseline.
    fn add(
        self: *Failures,
        gate: config.ExternalGate,
        input: ?[]const u8,
        message: []const u8,
        detail: []const u8,
    ) std.mem.Allocator.Error!void {
        try self.items.append(self.allocator, .{
            .violation = .{
                .check = check_name,
                .file = input orelse gate.name,
                .identity = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}|{s}",
                    .{ gate.name, input orelse "" },
                ),
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "external gate '{s}' {s}{s}{s}",
                    .{ gate.name, message, if (input != null) " for " else "", input orelse "" },
                ),
            },
            .detail = detail,
        });
    }

    fn addFmt(
        self: *Failures,
        gate: config.ExternalGate,
        input: ?[]const u8,
        message: []const u8,
        comptime detail_fmt: []const u8,
        detail_args: anytype,
    ) std.mem.Allocator.Error!void {
        const detail = try std.fmt.allocPrint(self.allocator, detail_fmt, detail_args);
        return self.add(gate, input, message, detail);
    }
};

/// Runs every configured `[[external]]` command and blocks on spawn/nonzero.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    if (ctx.cfg.external_gates.len == 0) {
        reporter.ok("external-gates: none configured", .{});
        return;
    }
    var failures: Failures = .{ .allocator = ctx.allocator };
    var invocations: usize = 0;
    var skipped: usize = 0;
    var changed: ?scope.Decision = null;
    for (ctx.cfg.external_gates) |gate| {
        if (gate.paths.len > 0) {
            if (changed == null) changed = try scope.resolve(ctx.allocator, ctx.project_dir, ctx.against, .{});
            if (!runsForChanges(changed.?, gate.paths) and !runsForChanges(changed.?, gate.inputs)) {
                skipped += 1;
                reporter.detail("  external gate '{s}' skipped: no configured path changed\n", .{gate.name});
                continue;
            }
        }
        const inputs = external_inputs.expand(ctx.allocator, ctx.project_dir, gate.inputs) catch |e| {
            try failures.add(gate, null, "could not expand inputs", @errorName(e));
            continue;
        };
        const missing = try external_inputs.unmatched(ctx.allocator, gate.inputs, inputs);
        if (missing.len > 0) {
            try failures.addFmt(gate, null, "has unmatched input pattern(s)", "missing: {s}", .{
                try std.mem.join(ctx.allocator, ", ", missing),
            });
            continue;
        }
        if (external_inputs.usesPlaceholder(gate.command)) {
            if (inputs.len == 0) {
                try failures.addFmt(gate, null, "declares no inputs", "uses {s} but matched no file", .{
                    external_inputs.placeholder,
                });
                continue;
            }
            for (inputs) |input| {
                invocations += 1;
                const argv = try external_inputs.argvForInput(ctx.allocator, gate.command, input);
                try runOne(ctx, &failures, gate, argv, input);
            }
        } else {
            invocations += 1;
            try runOne(ctx, &failures, gate, gate.command, null);
        }
    }
    if (failures.items.items.len > 0) return reportFailures(failures.items.items);
    reporter.ok("external-gates: {d} configured gate(s), {d} invocation(s) passed, {d} path-scoped skip(s)", .{
        ctx.cfg.external_gates.len,
        invocations,
        skipped,
    });
}

/// Header, then one structured violation per failing invocation. The header is
/// what a reader sees first; the emitted records are what the baseline layer
/// keys, so this is the shape that makes a failing gate actually block.
fn reportFailures(items: []const Failure) registry.RunError!void {
    reporter.fail("external-gates FAILED ({d} invocation(s))", .{items.len});
    for (items) |failure| {
        reporter.emit(failure.violation);
        if (failure.detail.len > 0) reporter.detail("    {s}\n", .{failure.detail});
    }
    return error.CheckFailed;
}

fn runOne(
    ctx: *registry.RunCtx,
    failures: *Failures,
    gate: config.ExternalGate,
    argv: []const []const u8,
    input: ?[]const u8,
) registry.RunError!void {
    if (gate.benchmark != null or gate.timeout_secs > 0 or gate.max_rss_mib > 0)
        return runBudgeted(ctx, failures, gate, argv, input);
    const result = std.process.run(ctx.allocator, wiring.io(), .{
        .argv = argv,
        .cwd = .{ .path = ctx.project_dir },
        .stdout_limit = .limited64(max_output_bytes),
        .stderr_limit = .limited64(max_output_bytes),
    }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return failures.add(gate, input, "could not start", @errorName(e));
    };
    if (result.term.success()) return;
    return failures.add(gate, input, "exited unsuccessfully", childOutput(ctx.allocator, result.stdout, result.stderr));
}

/// The child's output, trimmed and labelled, for the line under the violation.
/// stderr first — a failing gate's diagnostic almost always lives there — and
/// the two are joined so one failure stays one detail line.
fn childOutput(allocator: std.mem.Allocator, stdout_raw: []const u8, stderr_raw: []const u8) []const u8 {
    const stderr = std.mem.trim(u8, stderr_raw, &std.ascii.whitespace);
    const stdout = std.mem.trim(u8, stdout_raw, &std.ascii.whitespace);
    if (stderr.len > 0 and stdout.len > 0)
        return std.fmt.allocPrint(allocator, "stderr: {s} | stdout: {s}", .{ stderr, stdout }) catch stderr;
    if (stderr.len > 0) return std.fmt.allocPrint(allocator, "stderr: {s}", .{stderr}) catch stderr;
    if (stdout.len > 0) return std.fmt.allocPrint(allocator, "stdout: {s}", .{stdout}) catch stdout;
    return "";
}

const second_ns = std.time.ns_per_s;
const mib_bytes: u64 = 1024 * 1024;

fn runBudgeted(
    ctx: *registry.RunCtx,
    failures: *Failures,
    gate: config.ExternalGate,
    argv: []const []const u8,
    input: ?[]const u8,
) registry.RunError!void {
    const elapsed_limit = try benchmarkLimit(ctx, failures, gate) orelse
        if (gate.benchmark != null) return else null;
    const configured_timeout = if (gate.timeout_secs == 0) @as(u64, 0) else @as(u64, gate.timeout_secs) * second_ns;
    const timeout_ns = minNonzero(configured_timeout, elapsed_limit orelse 0);
    const result = budget_runner.run(ctx.allocator, argv, ctx.project_dir, timeout_ns) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return failures.add(gate, input, "could not run under resource supervision", @errorName(e));
    };
    const seconds = @as(f64, @floatFromInt(timeout_ns)) / @as(f64, second_ns);
    if (!result.term.success()) {
        if (result.timed_out)
            return failures.addFmt(gate, input, "exceeded its wall-time ceiling", "elapsed ceiling: {d:.3}s", .{seconds});
        return failures.add(gate, input, "exited unsuccessfully", "");
    }
    const max_rss_bytes = @as(u64, gate.max_rss_mib) * mib_bytes;
    if (resourceViolation(result.timed_out, result.elapsed_ns, result.max_rss_bytes, elapsed_limit, max_rss_bytes)) |violation| {
        switch (violation) {
            .timeout => try failures.addFmt(gate, input, "exceeded its wall-time ceiling", "elapsed ceiling: {d:.3}s", .{seconds}),
            .benchmark => try failures.addFmt(
                gate,
                input,
                "regressed beyond its recorded benchmark ceiling",
                "elapsed: {d:.3}s; ceiling: {d:.3}s",
                .{
                    @as(f64, @floatFromInt(result.elapsed_ns)) / @as(f64, second_ns),
                    @as(f64, @floatFromInt(elapsed_limit.?)) / @as(f64, second_ns),
                },
            ),
            .rss_unavailable => try failures.add(gate, input, "could not obtain peak RSS on this platform", ""),
            .rss => try failures.addFmt(
                gate,
                input,
                "exceeded its peak-RSS ceiling",
                "peak RSS: {d:.1} MiB; ceiling: {d} MiB",
                .{
                    @as(f64, @floatFromInt(result.max_rss_bytes.?)) / @as(f64, mib_bytes),
                    gate.max_rss_mib,
                },
            ),
        }
        return;
    }
    reporter.detail("  external gate '{s}' resources: {d:.3}s", .{
        gate.name,
        @as(f64, @floatFromInt(result.elapsed_ns)) / @as(f64, second_ns),
    });
    if (result.max_rss_bytes) |rss|
        reporter.detail(", {d:.1} MiB peak RSS\n", .{@as(f64, @floatFromInt(rss)) / @as(f64, mib_bytes)})
    else
        reporter.detail("\n", .{});
}

fn benchmarkLimit(
    ctx: *registry.RunCtx,
    failures: *Failures,
    gate: config.ExternalGate,
) registry.RunError!?u64 {
    const name = gate.benchmark orelse return null;
    const path = try snapshot_helper.snapshotPath(ctx.allocator, ctx.project_dir, benchmark.leaf);
    const records = benchmark.read(ctx.allocator, path) catch |e| {
        try failures.add(gate, null, "cannot read benchmark ledger", @errorName(e));
        return null;
    };
    const record = benchmark.find(records, name) orelse {
        try failures.addFmt(gate, null, "names a missing benchmark", benchmark_detail, .{name});
        return null;
    };
    if (record.direction != .min or !std.mem.eql(u8, record.unit, "s") or record.value <= 0) {
        try failures.addFmt(
            gate,
            null,
            "names a benchmark that is not a positive, min-direction value in seconds",
            benchmark_detail,
            .{name},
        );
        return null;
    }
    return secondsToNs(regressionCeiling(record.value, gate.max_regression_pct)) orelse {
        try failures.addFmt(gate, null, "derives an unusable elapsed ceiling", benchmark_detail, .{name});
        return null;
    };
}

fn regressionCeiling(recorded_seconds: f64, max_regression_pct: u32) f64 {
    return recorded_seconds * (1.0 + @as(f64, @floatFromInt(max_regression_pct)) / 100.0);
}

fn secondsToNs(seconds: f64) ?u64 {
    const ns = seconds * @as(f64, second_ns);
    if (!std.math.isFinite(ns) or ns <= 0 or ns > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
    return @intFromFloat(@ceil(ns));
}

fn minNonzero(a: u64, b: u64) u64 {
    if (a == 0) return b;
    if (b == 0) return a;
    return @min(a, b);
}

const ResourceViolation = enum { timeout, benchmark, rss_unavailable, rss };

fn resourceViolation(
    timed_out: bool,
    elapsed_ns: u64,
    max_rss_bytes: ?usize,
    elapsed_limit: ?u64,
    rss_limit: u64,
) ?ResourceViolation {
    if (timed_out) return .timeout;
    if (elapsed_limit) |limit| if (elapsed_ns > limit) return .benchmark;
    if (rss_limit == 0) return null;
    const rss = max_rss_bytes orelse return .rss_unavailable;
    if (rss > rss_limit) return .rss;
    return null;
}

fn runsForChanges(decision: scope.Decision, patterns: []const []const u8) bool {
    if (patterns.len == 0) return true;
    return switch (decision) {
        .whole_tree => true,
        .scoped => |plan| changed: {
            for (plan.files) |path| {
                for (patterns) |pattern| if (external_inputs.matches(path, pattern)) break :changed true;
            }
            break :changed false;
        },
    };
}

const baseline = @import("../baseline.zig");

/// Run the check under capture and return the keys the baseline layer would
/// record for it. This is the whole point of the shape: `run` returning
/// `error.CheckFailed` is NOT enough, because `runWithBaseline` swallows that
/// error and reconstructs the findings from what the check reported.
fn keysFor(arena: std.mem.Allocator, cfg: *const config.Config, project_dir: []const u8) ![]const baseline.Keyed {
    var ctx: registry.RunCtx = .{
        .allocator = arena,
        .project_dir = project_dir,
        .cfg = cfg,
        .quiet = false,
    };
    var cap: reporter.Capture = .{ .allocator = arena };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    run(&ctx) catch |e| switch (e) {
        error.CheckFailed => {},
        else => return e,
    };
    return baseline.keyedViolations(arena, check_name, cap.buf.items, cap.records.items);
}

// spec: External Gates - Records each failing external gate as a keyed violation, so a failing gate is what blocks rather than only what is printed

test "a failing external gate produces a keyed violation, not just printed text" {
    // THE REGRESSION. This check used to report every failure as its own
    // unindented `reporter.fail` header. `baseline.extract` collects only
    // INDENTED lines beneath a header, and treats the `stderr:`/`stdout:` lines
    // this check emitted as trailing hint prose that ends the block — so a
    // failing gate yielded ZERO keys. Against an empty baseline that is "0
    // current, 0 recorded: baseline matches", which is green. Every
    // `[[external]]` gate in every project was advisory, and the projects
    // relying on them (JS syntax gates, schema checks, policy scripts) had no
    // gate at all. Measured in the netlisp tree: 27 declared gates, a
    // deliberately failing one, `0 blocking`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "always-fails",
        .command = &.{ "sh", "-c", "echo boom >&2; exit 1" },
    }} };

    const keys = try keysFor(a, &cfg, ".");
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    // Keyed by gate name, so rewording the diagnostic cannot re-key a baseline.
    try std.testing.expect(std.mem.indexOf(u8, keys[0].key, "always-fails") != null);
    try std.testing.expect(std.mem.indexOf(u8, keys[0].line, "always-fails") != null);
}

// spec: External Gates - Keys a per-input external gate failure by gate name and input path so one file's failure is one violation
test "every failing per-input invocation is separately keyed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-external-keys";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir ++ "/assets");
    try fs.cwd().writeFile(.{ .sub_path = dir ++ "/assets/a.js", .data = "ok" });
    try fs.cwd().writeFile(.{ .sub_path = dir ++ "/assets/b.js", .data = "ok" });

    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "js-syntax",
        .command = &.{ "false", external_inputs.placeholder },
        .inputs = &.{"assets/*.js"},
    }} };

    // Two files, two failures, two DISTINCT keys — one file being fixed must
    // resolve exactly one baseline row, never collapse into a shared one.
    const keys = try keysFor(a, &cfg, dir);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expect(!std.mem.eql(u8, keys[0].key, keys[1].key));
    try std.testing.expect(std.mem.indexOf(u8, keys[0].key, "assets/a.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, keys[1].key, "assets/b.js") != null);
}

// spec: External Gates - Records a misconfigured external gate as a keyed violation the same way a failing one is
test "a misconfigured external gate is keyed too, not silently tolerated" {
    // The config-error paths (unmatched input pattern, a placeholder with no
    // inputs, a missing benchmark record) had the same defect as the failure
    // path: printed, never keyed. A gate that cannot run is exactly as
    // ungated as a gate that fails.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "js-syntax",
        .command = &.{"true"},
        .inputs = &.{"definitely-missing-assets/*.js"},
    }} };

    const keys = try keysFor(a, &cfg, ".");
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expect(std.mem.indexOf(u8, keys[0].line, "unmatched input pattern") != null);
}

// spec: External Gates - Reports no violation for a passing external gate
test "a passing external gate keys nothing" {
    // The other direction: the fix must not turn a green run into debt.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "always-passes",
        .command = &.{"true"},
    }} };
    try std.testing.expectEqual(@as(usize, 0), (try keysFor(a, &cfg, ".")).len);
}

// spec: External Gates - Runs configured argv commands without a shell and blocks on nonzero exit

test "external gate failure propagates without a shell" {
    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "expected-failure",
        .command = &.{"false"},
    }} };
    // Arena, as in production: this check owns the child's captured output and
    // the rendered violation text for the length of one run and frees neither.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: registry.RunCtx = .{
        .allocator = arena.allocator(),
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = false,
    };
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    try std.testing.expectError(error.CheckFailed, run(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "expected-failure") != null);
    try std.testing.expect(max_output_bytes <= 4 * 1024 * 1024);
}

// spec: External Gates - Runs an input-placeholder command once for every file matched by an input glob
test "external gate expands a glob and names each failing per-input invocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-external-glob";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir ++ "/assets");
    try fs.cwd().writeFile(.{ .sub_path = dir ++ "/assets/a.js", .data = "ok" });
    try fs.cwd().writeFile(.{ .sub_path = dir ++ "/assets/b.js", .data = "ok" });

    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "js-syntax",
        .command = &.{ "false", external_inputs.placeholder },
        .inputs = &.{"assets/*.js"},
    }} };
    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &cfg, .quiet = false };
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    try std.testing.expectError(error.CheckFailed, run(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "assets/a.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "assets/b.js") != null);
}

// spec: External Gates - Fails when a declared external input pattern matches no file
test "external gate fails closed on an unmatched input pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "js-syntax",
        .command = &.{"true"},
        .inputs = &.{"definitely-missing-assets/*.js"},
    }} };
    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = false };
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    try std.testing.expectError(error.CheckFailed, run(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "unmatched input pattern") != null);
}

// spec: External Gates - Runs opt-in external performance gates only when configured hot paths change
test "external performance gate path scope matches changed hot paths" {
    const unrelated: scope.Decision = .{ .scoped = .{ .base = "HEAD", .files = &.{"README.md"} } };
    const hot: scope.Decision = .{ .scoped = .{ .base = "HEAD", .files = &.{"src/router.zig"} } };
    try std.testing.expect(!runsForChanges(unrelated, &.{"src/*.zig"}));
    try std.testing.expect(runsForChanges(hot, &.{"src/*.zig"}));
    try std.testing.expect(runsForChanges(.{ .whole_tree = "safe fallback" }, &.{"src/*.zig"}));
}

// spec: External Gates - Fails external performance gates that exceed a recorded wall-time regression, timeout, or peak-RSS ceiling
test "external performance gate derives benchmark regression and timeout ceilings" {
    try std.testing.expectApproxEqAbs(@as(f64, 125), regressionCeiling(100, 25), 0.0001);
    try std.testing.expectEqual(@as(u64, 20), minNonzero(20, 30));
    try std.testing.expectEqual(@as(u64, 30), minNonzero(0, 30));
    try std.testing.expectEqual(ResourceViolation.timeout, resourceViolation(true, 1, 1, 10, 10).?);
    try std.testing.expectEqual(ResourceViolation.benchmark, resourceViolation(false, 11, 1, 10, 10).?);
    try std.testing.expectEqual(ResourceViolation.rss, resourceViolation(false, 1, 11, 10, 10).?);
    try std.testing.expect(resourceViolation(false, 1, 1, 10, 10) == null);
}
