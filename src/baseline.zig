const std = @import("std");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const reporter = @import("reporter.zig");
const types = @import("cli/types.zig");
const snapshot_helper = @import("snapshot_helper.zig");

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
/// A check's failing output is `[header] [violation lines…] [trailing hint /
/// suggestion block]`. Only the middle is real violations. A violation line is
/// indented (two spaces or a tab); the trailing block is everything from the
/// first hint marker (`fix:` / `add:`) or the first blank line after violations
/// began — whichever comes first. This excludes multi-line `fix:` continuations
/// (e.g. `       or re-run …`) and the spec check's `add:` suggestion block,
/// which earlier only-`fix:`-prefixed skipping miscounted as violations.
///
/// The returned lines are dedented (leading whitespace stripped) and
/// allocator-owned.
pub fn extract(arena: Allocator, output: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, output, '\n');
    var collected_any = false;
    while (iter.next()) |raw| {
        if (raw.len == 0) {
            // A blank line after violations began ends the violation block;
            // the trailing hint/suggestion prose follows (spec prints exactly
            // one such blank before its `add:` block).
            if (collected_any) break;
            continue;
        }
        if (!isIndented(raw)) continue;
        const trimmed = leftTrim(raw);
        if (isHintStart(trimmed)) break;
        try out.append(arena, try arena.dupe(u8, trimmed));
        collected_any = true;
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

/// The first line of a check's trailing hint/suggestion block: a `fix:` hint or
/// the spec check's `add:` suggestions. Everything from here on is prose, not
/// violations.
fn isHintStart(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "fix:") or std.mem.startsWith(u8, trimmed, "add:");
}

/// Blanks the source-line position in a violation line so baseline matching is
/// insensitive to line-number churn. A violation reads `<file>:<line>: <message>`;
/// an unrelated edit *above* it shifts `<line>`, which would otherwise read as the
/// old violation resolved + a new one added — a spurious "new violation" that fails
/// the build and forces a needless baseline refresh. The stable identity is
/// file + message (the message names the function / construct), so blank the first
/// `:<digits>:` group. Lines with no such group (file-level `<file>: N lines`,
/// plain tokens) are returned unchanged.
fn positionKey(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;
        var j = i + 1;
        while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
        if (j > i + 1 and j < line.len) {
            if (line[j] == ':') return std.fmt.allocPrint(arena, "{s}::{s}", .{ line[0..i], line[j + 1 ..] });
        }
    }
    return line;
}

/// Position-insensitive multiset diff of baseline vs. current violations: like
/// `snapshot.diff`, but matches on `positionKey`, so a violation that only moved
/// source lines is neither added nor removed. Multiplicity is preserved (N hits of
/// the same message in one file still diff correctly), and a genuinely new
/// violation still surfaces as `added`.
fn diffByPosition(arena: Allocator, old: snapshot.Snapshot, current: []const []const u8) Allocator.Error!snapshot.Diff {
    const Item = struct { key: []const u8, line: []const u8 };
    const order = struct {
        fn lt(_: void, a: Item, b: Item) bool {
            const c = std.mem.order(u8, a.key, b.key);
            return if (c != .eq) c == .lt else std.mem.order(u8, a.line, b.line) == .lt;
        }
    }.lt;
    const olds = try arena.alloc(Item, old.lines.len);
    for (old.lines, 0..) |l, k| olds[k] = .{ .key = try positionKey(arena, l), .line = l };
    const news = try arena.alloc(Item, current.len);
    for (current, 0..) |l, k| news[k] = .{ .key = try positionKey(arena, l), .line = l };
    std.mem.sort(Item, olds, {}, order);
    std.mem.sort(Item, news, {}, order);

    var added: std.ArrayListUnmanaged([]const u8) = .empty;
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < olds.len and j < news.len) {
        switch (std.mem.order(u8, olds[i].key, news[j].key)) {
            .eq => {
                i += 1;
                j += 1;
            },
            .lt => {
                try removed.append(arena, olds[i].line);
                i += 1;
            },
            .gt => {
                try added.append(arena, news[j].line);
                j += 1;
            },
        }
    }
    while (i < olds.len) : (i += 1) try removed.append(arena, olds[i].line);
    while (j < news.len) : (j += 1) try added.append(arena, news[j].line);
    return .{ .added = try added.toOwnedSlice(arena), .removed = try removed.toOwnedSlice(arena) };
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

    const loaded = try readOrInit(arena, baseline_path, current);
    const old = switch (loaded) {
        .initialized => |outcome| return outcome,
        .existing => |snap| snap,
    };

    std.mem.sort([]const u8, current, {}, lessThan);
    // Match ignoring source-line position so an unrelated edit that merely shifts a
    // legacy violation's line number isn't reported as a new violation (see positionKey).
    const d = try diffByPosition(arena, old, current);
    return classify(d, old.lines.len, current.len);
}

/// Result of loading (and possibly initializing) a baseline before diffing.
const Loaded = union(enum) {
    /// No usable baseline existed; `current` was written and this is the
    /// final outcome (`created` when absent, `refreshed` when stale).
    initialized: Outcome,
    /// A usable baseline was loaded.
    existing: snapshot.Snapshot,
};

/// Read the baseline, initializing it when absent or stale. Both init
/// paths write `current` as the new baseline before returning.
fn readOrInit(
    arena: Allocator,
    baseline_path: []const u8,
    current: [][]const u8,
) (snapshot.WriteError || snapshot.ReadError)!Loaded {
    const snap = snapshot.read(arena, baseline_path, VERSION) catch |e| {
        // Missing → fresh `created`; stale version → re-record as `refreshed`.
        // Both write `current` as the new baseline; any other error propagates.
        const outcome: Outcome = switch (e) {
            error.Missing => .{ .created = current.len },
            error.VersionMismatch => .{ .refreshed = current.len },
            else => return e,
        };
        try snapshot.write(baseline_path, VERSION, current);
        return .{ .initialized = outcome };
    };
    return .{ .existing = snap };
}

/// Turn a position-insensitive diff into a lifecycle outcome:
/// `grown` on additions, `shrunk` on removals, else `matched`.
fn classify(d: snapshot.Diff, baseline_len: usize, current_len: usize) Outcome {
    if (d.added.len > 0) {
        return .{ .grown = .{ .new_lines = d.added, .baseline_size = baseline_len } };
    }
    if (d.removed.len > 0) {
        return .{ .shrunk = .{ .remaining = current_len, .removed = d.removed.len } };
    }
    return .{ .matched = current_len };
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
        .shrunk => |s| reporter.ok(
            "{s}: {d} violation(s) resolved (now {d}) — " ++
                "re-run with GUARDIAN_UPDATE_SNAPSHOT=1 to prune",
            .{ check_name, s.removed, s.remaining },
        ),
        .refreshed => |n| reporter.ok("{s}: baseline refreshed ({d} violation(s))", .{ check_name, n }),
        .grown => |g| {
            reporter.fail(
                "{s}: {d} new violation(s) above baseline of {d}",
                .{ check_name, g.new_lines.len, g.baseline_size },
            );
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

// spec: Baseline Mode - Captures each check's current violations on first run and only fails on additions
// spec: Baseline Mode - Wraps a single check run with capture, diff, and outcome reporting

test "pathFor builds the baseline file path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try pathFor(arena.allocator(), "proj", "magic-number");
    try std.testing.expectEqualStrings("proj/.guardian/baselines/magic-number.txt", p);
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

test "extract ignores multi-line fix-hint continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample =
        \\guardian: int-from-float budget FAILED (casts: 1 found, 0 budgeted)
        \\  src/x.zig:5: unguarded @intFromFloat
        \\  fix: guard the new @intFromFloat (isFinite + range check),
        \\       or re-run with GUARDIAN_UPDATE_SNAPSHOT=1 and commit .guardian/x.txt
    ;
    const lines = try extract(a, sample);
    // Only the violation; both hint lines (incl. the non-`fix:` continuation)
    // are excluded.
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("src/x.zig:5: unguarded @intFromFloat", lines[0]);
}

test "extract stops at the spec add: suggestion block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample =
        \\guardian: spec coverage FAILED (2 unverified)
        \\  unverified: Auth - Validates tokens
        \\  unverified: Auth - Rejects expired tokens
        \\
        \\  add: // spec: Auth - Validates tokens
        \\  add: // spec: Auth - Rejects expired tokens
        \\  Each spec behavior must have exactly one // spec: tag (1:1 mapping).
    ;
    const lines = try extract(a, sample);
    // The two unverified behaviors, not the add: block or the trailing prose.
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("unverified: Auth - Validates tokens", lines[0]);
    try std.testing.expectEqualStrings("unverified: Auth - Rejects expired tokens", lines[1]);
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

test "positionKey blanks the source-line position, leaves position-free lines alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "src/x.zig:: fn foo is 246 lines (cap 200)",
        try positionKey(a, "src/x.zig:553: fn foo is 246 lines (cap 200)"),
    );
    // No `:<digits>:` group (a file-level metric line) → returned unchanged.
    try std.testing.expectEqualStrings(
        "src/x.zig: 1234 lines (max 1000)",
        try positionKey(a, "src/x.zig: 1234 lines (max 1000)"),
    );
}

test "diffByPosition ignores a pure line-number shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old: snapshot.Snapshot = .{ .version = 1, .lines = &.{"src/x.zig:553: fn foo is 246 lines (cap 200)"} };
    const new_lines = [_][]const u8{"src/x.zig:559: fn foo is 246 lines (cap 200)"};
    const d = try diffByPosition(a, old, &new_lines);
    try std.testing.expect(d.isEmpty());
}

test "diffByPosition still flags a genuinely new violation amid shifts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old: snapshot.Snapshot = .{
        .version = 1,
        .lines = &.{"src/x.zig:10: fn foo reaches nesting depth 7 (cap 6)"},
    };
    const new_lines = [_][]const u8{
        "src/x.zig:14: fn foo reaches nesting depth 7 (cap 6)", // same violation, only moved
        "src/y.zig:99: fn bar reaches nesting depth 8 (cap 6)", // genuinely new
    };
    const d = try diffByPosition(a, old, &new_lines);
    try std.testing.expectEqual(@as(usize, 1), d.added.len);
    try std.testing.expectEqualStrings("src/y.zig:99: fn bar reaches nesting depth 8 (cap 6)", d.added[0]);
    try std.testing.expectEqual(@as(usize, 0), d.removed.len);
}

test "diffByPosition preserves multiplicity for count-based checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two identical-message hits in one file, both shifted → still a match (no churn).
    const old: snapshot.Snapshot = .{ .version = 1, .lines = &.{
        "src/x.zig:5: std.fs.cwd reference outside allowed paths",
        "src/x.zig:50: std.fs.cwd reference outside allowed paths",
    } };
    const shifted = [_][]const u8{
        "src/x.zig:7: std.fs.cwd reference outside allowed paths",
        "src/x.zig:60: std.fs.cwd reference outside allowed paths",
    };
    try std.testing.expect((try diffByPosition(a, old, &shifted)).isEmpty());
    // A third hit appears → exactly one new violation.
    const grown = [_][]const u8{
        "src/x.zig:7: std.fs.cwd reference outside allowed paths",
        "src/x.zig:60: std.fs.cwd reference outside allowed paths",
        "src/x.zig:80: std.fs.cwd reference outside allowed paths",
    };
    const d = try diffByPosition(a, old, &grown);
    try std.testing.expectEqual(@as(usize, 1), d.added.len);
}
