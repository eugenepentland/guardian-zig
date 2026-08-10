//! Project-defined non-Zig gates. Commands execute directly as argv arrays in
//! the project directory (never through a shell), and their declared input
//! files participate in Guardian's green-run cache digest.

const std = @import("std");
const config = @import("../config.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const external_inputs = @import("../external_inputs.zig");
const benchmark = @import("../benchmark.zig");
const budget_runner = @import("../budget_runner.zig");
const scope = @import("../scope.zig");
const snapshot_helper = @import("../snapshot_helper.zig");

const max_output_bytes: usize = 4 * 1024 * 1024;

/// Runs every configured `[[external]]` command and blocks on spawn/nonzero.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    if (ctx.cfg.external_gates.len == 0) {
        reporter.ok("external-gates: none configured", .{});
        return;
    }
    var failed: usize = 0;
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
            failed += 1;
            reporter.fail("external gate '{s}' could not expand inputs: {s}", .{ gate.name, @errorName(e) });
            continue;
        };
        const missing = try external_inputs.unmatched(ctx.allocator, gate.inputs, inputs);
        if (missing.len > 0) {
            failed += 1;
            reporter.fail("external gate '{s}' has {d} unmatched input pattern(s)", .{ gate.name, missing.len });
            for (missing) |pattern| reporter.detail("  missing: {s}\n", .{pattern});
            continue;
        }
        if (external_inputs.usesPlaceholder(gate.command)) {
            if (inputs.len == 0) {
                failed += 1;
                reporter.fail("external gate '{s}' uses {s} but declares no inputs", .{ gate.name, external_inputs.placeholder });
                continue;
            }
            for (inputs) |input| {
                invocations += 1;
                const argv = try external_inputs.argvForInput(ctx.allocator, gate.command, input);
                if (!try runOne(ctx, gate, argv, input)) failed += 1;
            }
        } else {
            invocations += 1;
            if (!try runOne(ctx, gate, gate.command, null)) failed += 1;
        }
    }
    if (failed > 0) return error.CheckFailed;
    reporter.ok("external-gates: {d} configured gate(s), {d} invocation(s) passed, {d} path-scoped skip(s)", .{
        ctx.cfg.external_gates.len,
        invocations,
        skipped,
    });
}

fn runOne(
    ctx: *registry.RunCtx,
    gate: config.ExternalGate,
    argv: []const []const u8,
    input: ?[]const u8,
) registry.RunError!bool {
    if (gate.benchmark != null or gate.timeout_secs > 0 or gate.max_rss_mib > 0)
        return runBudgeted(ctx, gate, argv, input);
    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = argv,
        .cwd = ctx.project_dir,
        .max_output_bytes = max_output_bytes,
    }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (input) |path|
            reporter.fail("external gate '{s}' could not start for {s}: {s}", .{ gate.name, path, @errorName(e) })
        else
            reporter.fail("external gate '{s}' could not start: {s}", .{ gate.name, @errorName(e) });
        return false;
    };
    if (result.term == .Exited and result.term.Exited == 0) return true;
    if (input) |path|
        reporter.fail("external gate '{s}' FAILED for {s}", .{ gate.name, path })
    else
        reporter.fail("external gate '{s}' FAILED", .{gate.name});
    const stderr = std.mem.trim(u8, result.stderr, &std.ascii.whitespace);
    const stdout = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (stderr.len > 0) reporter.detail("  stderr: {s}\n", .{stderr});
    if (stdout.len > 0) reporter.detail("  stdout: {s}\n", .{stdout});
    return false;
}

const second_ns = std.time.ns_per_s;
const mib_bytes: u64 = 1024 * 1024;

fn runBudgeted(
    ctx: *registry.RunCtx,
    gate: config.ExternalGate,
    argv: []const []const u8,
    input: ?[]const u8,
) registry.RunError!bool {
    const elapsed_limit = try benchmarkLimit(ctx, gate) orelse if (gate.benchmark != null) return false else null;
    const configured_timeout = if (gate.timeout_secs == 0) @as(u64, 0) else @as(u64, gate.timeout_secs) * second_ns;
    const timeout_ns = minNonzero(configured_timeout, elapsed_limit orelse 0);
    const result = budget_runner.run(ctx.allocator, argv, ctx.project_dir, timeout_ns) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        reportGateFailure(gate.name, input, "could not run under resource supervision", @errorName(e));
        return false;
    };
    if (!(result.term == .Exited and result.term.Exited == 0)) {
        if (result.timed_out) {
            reportGateFailure(gate.name, input, "exceeded its wall-time ceiling", null);
            reporter.detail("  elapsed ceiling: {d:.3}s\n", .{@as(f64, @floatFromInt(timeout_ns)) / @as(f64, second_ns)});
            return false;
        }
        reportGateFailure(gate.name, input, "exited unsuccessfully", null);
        return false;
    }
    const max_rss_bytes = @as(u64, gate.max_rss_mib) * mib_bytes;
    if (resourceViolation(result.timed_out, result.elapsed_ns, result.max_rss_bytes, elapsed_limit, max_rss_bytes)) |violation| {
        switch (violation) {
            .timeout => {
                reportGateFailure(gate.name, input, "exceeded its wall-time ceiling", null);
                reporter.detail("  elapsed ceiling: {d:.3}s\n", .{@as(f64, @floatFromInt(timeout_ns)) / @as(f64, second_ns)});
            },
            .benchmark => {
                const limit = elapsed_limit.?;
                reportGateFailure(gate.name, input, "regressed beyond its recorded benchmark ceiling", null);
                reporter.detail("  elapsed: {d:.3}s; ceiling: {d:.3}s\n", .{
                    @as(f64, @floatFromInt(result.elapsed_ns)) / @as(f64, second_ns),
                    @as(f64, @floatFromInt(limit)) / @as(f64, second_ns),
                });
            },
            .rss_unavailable => reportGateFailure(gate.name, input, "could not obtain peak RSS on this platform", null),
            .rss => {
                reportGateFailure(gate.name, input, "exceeded its peak-RSS ceiling", null);
                reporter.detail("  peak RSS: {d:.1} MiB; ceiling: {d} MiB\n", .{
                    @as(f64, @floatFromInt(result.max_rss_bytes.?)) / @as(f64, mib_bytes),
                    gate.max_rss_mib,
                });
            },
        }
        return false;
    }
    reporter.detail("  external gate '{s}' resources: {d:.3}s", .{
        gate.name,
        @as(f64, @floatFromInt(result.elapsed_ns)) / @as(f64, second_ns),
    });
    if (result.max_rss_bytes) |rss|
        reporter.detail(", {d:.1} MiB peak RSS\n", .{@as(f64, @floatFromInt(rss)) / @as(f64, mib_bytes)})
    else
        reporter.detail("\n", .{});
    return true;
}

fn benchmarkLimit(ctx: *registry.RunCtx, gate: config.ExternalGate) registry.RunError!?u64 {
    const name = gate.benchmark orelse return null;
    const path = try snapshot_helper.snapshotPath(ctx.allocator, ctx.project_dir, benchmark.leaf);
    const records = benchmark.read(ctx.allocator, path) catch |e| {
        reporter.fail("external gate '{s}' cannot read benchmark ledger: {s}", .{ gate.name, @errorName(e) });
        return null;
    };
    const record = benchmark.find(records, name) orelse {
        reporter.fail("external gate '{s}' names missing benchmark '{s}'", .{ gate.name, name });
        return null;
    };
    if (record.direction != .min or !std.mem.eql(u8, record.unit, "s") or record.value <= 0) {
        reporter.fail("external gate '{s}' benchmark '{s}' must be a positive, min-direction value in seconds", .{ gate.name, name });
        return null;
    }
    return secondsToNs(regressionCeiling(record.value, gate.max_regression_pct)) orelse {
        reporter.fail("external gate '{s}' benchmark '{s}' produces an unusable elapsed ceiling", .{ gate.name, name });
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

fn reportGateFailure(name: []const u8, input: ?[]const u8, message: []const u8, detail: ?[]const u8) void {
    if (input) |path|
        reporter.fail("external gate '{s}' {s} for {s}{s}{s}", .{ name, message, path, if (detail != null) ": " else "", detail orelse "" })
    else
        reporter.fail("external gate '{s}' {s}{s}{s}", .{ name, message, if (detail != null) ": " else "", detail orelse "" });
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

// spec: External Gates - Runs configured argv commands without a shell and blocks on nonzero exit

test "external gate failure propagates without a shell" {
    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "expected-failure",
        .command = &.{"false"},
    }} };
    var ctx: registry.RunCtx = .{
        .allocator = std.testing.allocator,
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
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir ++ "/assets");
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/assets/a.js", .data = "ok" });
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/assets/b.js", .data = "ok" });

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
