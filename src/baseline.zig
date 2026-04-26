const std = @import("std");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const reporter = @import("reporter.zig");
const types = @import("cli/types.zig");
const snapshot_helper = @import("snapshot_helper.zig");

// spec: Baseline Mode - Captures each check's current violations on first run and only fails on additions
// spec: Baseline Mode - Wraps a single check run with capture, diff, and outcome reporting

/// Baseline file format version. Bump if the format changes meaningfully.
pub const VERSION: u32 = 1;

/// Outcome of one check's baseline lifecycle. Maps to user-visible
/// reporter output: `created`, `matched`, `shrunk` and `refreshed`
/// are success paths; `grown` fails the build.
pub const Outcome = union(enum) {
    /// No prior baseline existed; one was just written.
    created: usize,
    /// Current set matches baseline exactly.
    matched: usize,
    /// Some baselined violations were resolved. Run with
    /// GUARDIAN_UPDATE_SNAPSHOT=1 to prune them.
    shrunk: struct { remaining: usize, removed: usize },
    /// `force_refresh` was set; baseline was rewritten.
    refreshed: usize,
    /// New violations beyond the baseline.
    grown: struct { new_lines: []const []const u8, baseline_size: usize },
};

/// Pulls violation lines out of a check's captured stdout.
///
/// A "violation line" is any line that:
///   - is indented (starts with two spaces or a tab), AND
///   - isn't a fix hint (starts with `  fix:` or `    fix:`), AND
///   - isn't a continuation of a fix hint.
///
/// The returned lines are dedented (leading whitespace stripped) and
/// allocator-owned.
pub fn extract(arena: Allocator, output: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |raw| {
        if (raw.len == 0) continue;
        if (!isIndented(raw)) continue;
        const trimmed = leftTrim(raw);
        if (isFixLine(trimmed)) continue;
        try out.append(arena, try arena.dupe(u8, trimmed));
    }
    return out.toOwnedSlice(arena);
}

fn isIndented(line: []const u8) bool {
    if (line.len == 0) return false;
    return line[0] == ' ' or line[0] == '\t';
}

fn leftTrim(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[i..];
}

fn isFixLine(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "fix:");
}

/// Run the baseline lifecycle for a check.
///
/// `current` may be reordered (sorted) for diffing.
/// `force_refresh = true` rewrites the baseline regardless of state.
pub fn lifecycle(
    arena: Allocator,
    baseline_path: []const u8,
    current: [][]const u8,
    force_refresh: bool,
) (snapshot.WriteError || snapshot.ReadError)!Outcome {
    if (force_refresh) {
        try snapshot.write(baseline_path, VERSION, current);
        return .{ .refreshed = current.len };
    }

    const old = snapshot.read(arena, baseline_path, VERSION) catch |e| switch (e) {
        error.Missing => {
            try snapshot.write(baseline_path, VERSION, current);
            return .{ .created = current.len };
        },
        // Stale version: treat as "no baseline" so we re-record cleanly.
        error.VersionMismatch => {
            try snapshot.write(baseline_path, VERSION, current);
            return .{ .refreshed = current.len };
        },
        else => return e,
    };

    std.mem.sort([]const u8, current, {}, lessThan);
    const d = try snapshot.diff(arena, old, current);
    if (d.added.len > 0) {
        return .{ .grown = .{
            .new_lines = d.added,
            .baseline_size = old.lines.len,
        } };
    }
    if (d.removed.len > 0) {
        return .{ .shrunk = .{
            .remaining = current.len,
            .removed = d.removed.len,
        } };
    }
    return .{ .matched = current.len };
}

/// Build the per-check baseline file path: `<project_dir>/.guardian/baselines/<check>.txt`.
pub fn pathFor(arena: Allocator, project_dir: []const u8, check_name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.guardian/baselines/{s}.txt", .{ project_dir, check_name });
}

/// Run `cmd` with output captured, then apply the baseline lifecycle.
/// Used by both `run-all` and the single-check dispatch in `check.zig`.
pub fn runWithBaseline(ctx: *types.RunCtx, cmd: types.Command) types.RunError!void {
    const force_refresh = snapshot_helper.shouldUpdate(ctx.allocator);
    var capture: reporter.Capture = .{ .allocator = ctx.allocator };
    defer capture.deinit();

    // Inner scope so the capture is restored *before* processOutcome runs —
    // otherwise the outcome's reporter.fail / detail would route into the
    // capture buffer instead of stderr.
    {
        const prior = reporter.default.capture;
        defer reporter.default.capture = prior;
        reporter.default.capture = &capture;

        cmd.run(ctx) catch |e| switch (e) {
            error.CheckFailed => {},
            else => return e,
        };
    }

    return processOutcome(ctx, cmd.name, capture.buf.items, force_refresh);
}

fn processOutcome(
    ctx: *types.RunCtx,
    check_name: []const u8,
    captured: []const u8,
    force_refresh: bool,
) types.RunError!void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const violations_const = try extract(a, captured);
    const violations = try a.alloc([]const u8, violations_const.len);
    @memcpy(violations, violations_const);

    const path = try pathFor(a, ctx.project_dir, check_name);
    const outcome = lifecycle(a, path, violations, force_refresh) catch |e| {
        reporter.fail("{s}: baseline I/O failed: {s}", .{ check_name, @errorName(e) });
        return error.CheckFailed;
    };

    return reportOutcome(check_name, outcome);
}

fn reportOutcome(check_name: []const u8, outcome: Outcome) types.RunError!void {
    switch (outcome) {
        .created => |n| reporter.ok("{s}: baselined {d} violation(s)", .{ check_name, n }),
        .matched => |n| reporter.ok("{s}: baseline matches ({d} violation(s))", .{ check_name, n }),
        .shrunk => |s| reporter.ok("{s}: {d} violation(s) resolved (now {d}) — re-run with GUARDIAN_UPDATE_SNAPSHOT=1 to prune", .{ check_name, s.removed, s.remaining }),
        .refreshed => |n| reporter.ok("{s}: baseline refreshed ({d} violation(s))", .{ check_name, n }),
        .grown => |g| {
            reporter.fail("{s}: {d} new violation(s) above baseline of {d}", .{ check_name, g.new_lines.len, g.baseline_size });
            for (g.new_lines) |line| reporter.detail("  {s}\n", .{line});
            return error.CheckFailed;
        },
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── Tests ──────────────────────────────────────────────────────────────

fn deleteIfExists(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) }),
    };
}

test "extract pulls violation lines and skips headers and fix hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample =
        \\guardian: ban-fs FAILED (3 occurrence(s))
        \\  src/x.zig:5: std.fs.cwd reference outside allowed paths
        \\  src/y.zig:8: std.fs.cwd reference outside allowed paths
        \\  src/z.zig:12: std.fs.cwd reference outside allowed paths
        \\  fix: inject a Filesystem port from infra/fs.
    ;
    const lines = try extract(a, sample);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("src/x.zig:5: std.fs.cwd reference outside allowed paths", lines[0]);
    try std.testing.expectEqualStrings("src/z.zig:12: std.fs.cwd reference outside allowed paths", lines[2]);
}

test "extract handles empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try extract(a, "");
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "extract skips ok-only output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample = "guardian: ban-fs: no forbidden references\n";
    const lines = try extract(a, sample);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "lifecycle creates baseline on first run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-create.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    const out = try lifecycle(a, path, &lines, false);
    try std.testing.expect(out == .created);
    try std.testing.expectEqual(@as(usize, 2), out.created);
}

test "lifecycle returns matched on identical run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-match.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, path, &lines, false);

    var lines2 = [_][]const u8{ "alpha", "beta" };
    const out = try lifecycle(a, path, &lines2, false);
    try std.testing.expect(out == .matched);
}

test "lifecycle returns grown when new violations appear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-grown.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{"alpha"};
    _ = try lifecycle(a, path, &lines, false);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, path, &lines2, false);
    try std.testing.expect(out == .grown);
    try std.testing.expectEqual(@as(usize, 1), out.grown.new_lines.len);
    try std.testing.expectEqualStrings("gamma", out.grown.new_lines[0]);
}

test "lifecycle returns shrunk when violations are resolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-shrunk.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta", "gamma" };
    _ = try lifecycle(a, path, &lines, false);

    var lines2 = [_][]const u8{"alpha"};
    const out = try lifecycle(a, path, &lines2, false);
    try std.testing.expect(out == .shrunk);
    try std.testing.expectEqual(@as(usize, 2), out.shrunk.removed);
    try std.testing.expectEqual(@as(usize, 1), out.shrunk.remaining);
}

test "lifecycle force_refresh rewrites the baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-refresh.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, path, &lines, false);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, path, &lines2, true);
    try std.testing.expect(out == .refreshed);

    // After refresh, the new state is the baseline.
    var lines3 = [_][]const u8{ "alpha", "gamma" };
    const out2 = try lifecycle(a, path, &lines3, false);
    try std.testing.expect(out2 == .matched);
}
