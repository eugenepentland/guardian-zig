const std = @import("std");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");

pub const UPDATE_ENV = "GUARDIAN_UPDATE_SNAPSHOT";

pub const LifecycleError = snapshot.WriteError || snapshot.ReadError;

/// Outcome of a snapshot lifecycle run. Callers translate this to user-facing
/// messages and exit status. `drift` and `version_mismatch` mean the build
/// should fail; the others are success paths.
pub const Outcome = union(enum) {
    /// No prior snapshot existed; one was just written.
    created: usize,
    /// Snapshot matches current state exactly.
    unchanged: usize,
    /// `force_update` was set; snapshot was rewritten.
    updated: usize,
    /// Snapshot exists and disagrees with current state.
    drift: snapshot.Diff,
    /// Snapshot exists with a stale version; caller should fail and instruct
    /// the user to re-run with the update env var.
    version_mismatch,
};

/// True when *any* refresh was requested via GUARDIAN_UPDATE_SNAPSHOT (a full
/// "1"/"true"/"all" refresh or a comma-separated check-name list). Empty /
/// unset / "0" all return false. Used only by the run-all skip-cache to bypass
/// the cache whenever a refresh might rewrite `.guardian/`; per-check refresh
/// decisions go through `shouldUpdateFor`.
pub fn shouldUpdate(allocator: Allocator) bool {
    const v = std.process.getEnvVarOwned(allocator, UPDATE_ENV) catch return false;
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, &std.ascii.whitespace);
    return t.len > 0 and !std.mem.eql(u8, t, "0");
}

/// A parsed GUARDIAN_UPDATE_SNAPSHOT request. `none` = unset / empty / "0";
/// `all` = "1" / "true" / "all" (refresh every snapshot and baseline — the
/// backward-compatible behavior); `named` = a comma-separated check-name list,
/// so only those checks' snapshots/baselines refresh. Selective refresh means
/// accepting one intended snapshot change can no longer silently ratify
/// unrelated drift (e.g. spec-baseline growth) in the same run.
const Refresh = union(enum) {
    none,
    all,
    named: []const []const u8,
};

/// True when the whole value names a full refresh: "1", "true", or "all".
fn isAllToken(v: []const u8) bool {
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "all");
}

/// Splits a comma-separated check-name list, trimming each segment and dropping
/// blanks ("a,,b" -> {a,b}). Propagates OOM: a truncated list would silently
/// drop a check from the refresh set — the public entry points below turn OOM
/// into the fail-closed "no refresh" default rather than a partial list.
fn splitNames(allocator: Allocator, csv: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        try list.append(allocator, trimmed);
    }
    return list.toOwnedSlice(allocator);
}

/// Classifies a raw GUARDIAN_UPDATE_SNAPSHOT value into a Refresh request. Pure
/// (no env read) so the none/all/named partition is unit-testable.
fn classifyValue(allocator: Allocator, raw: []const u8) Allocator.Error!Refresh {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "0")) return .none;
    if (isAllToken(trimmed)) return .all;
    return .{ .named = try splitNames(allocator, trimmed) };
}

/// Reads and classifies GUARDIAN_UPDATE_SNAPSHOT; `.none` when unset/unreadable.
fn parseRefresh(allocator: Allocator) Allocator.Error!Refresh {
    const raw = std.process.getEnvVarOwned(allocator, UPDATE_ENV) catch return .none;
    return classifyValue(allocator, raw);
}

/// True when `name` appears in `names`.
fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// True when refresh request `r` covers the check `check_name`: every check
/// under `all`, only the listed checks under `named`, none under `none`.
fn refreshIncludes(r: Refresh, check_name: []const u8) bool {
    return switch (r) {
        .none => false,
        .all => true,
        .named => |names| containsName(names, check_name),
    };
}

/// True when the check named `check_name` should refresh its snapshot/baseline
/// this run — the per-check replacement for the old global `shouldUpdate`
/// boolean. Threaded through every snapshot check, `mutate`'s ratchet, and
/// baseline mode so `GUARDIAN_UPDATE_SNAPSHOT=<name[,name]>` refreshes only
/// those checks (`=1`/`true`/`all` still refreshes everything).
pub fn shouldUpdateFor(allocator: Allocator, check_name: []const u8) bool {
    // OOM while parsing the refresh list collapses to "no refresh": the check
    // then compares against its committed snapshot, so real drift still reds the
    // build (fail closed) rather than being silently ratified.
    const r = parseRefresh(allocator) catch return false;
    return refreshIncludes(r, check_name);
}

/// The check names listed in a `named` GUARDIAN_UPDATE_SNAPSHOT request, or null
/// under the none/all modes (nothing to validate). Callers validate the names
/// against the registry so a typo hard-fails instead of silently refreshing
/// nothing.
pub fn refreshTargets(allocator: Allocator) ?[]const []const u8 {
    return switch (parseRefresh(allocator) catch return null) {
        .named => |names| names,
        else => null,
    };
}

/// Joins `project_dir/.guardian/{leaf}` for snapshot file paths. Caller owns
/// the returned slice (via allocator).
pub fn snapshotPath(allocator: Allocator, project_dir: []const u8, leaf: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.guardian/{s}", .{ project_dir, leaf });
}

/// Identifies a snapshot file: its path and format version.
pub const SnapSpec = struct {
    path: []const u8,
    version: u32,
};

/// Runs the standard snapshot lifecycle for set-diff style checks
/// (e.g. pub-api-surface): if no snapshot exists OR `force_update` is
/// set, write the current `new_lines` and report created/updated. Otherwise
/// read the prior snapshot and diff against the (sorted) current state.
///
/// `new_lines` is sorted in place when needed for diffing. The slice may be
/// retained by the returned Outcome.
pub fn lifecycle(
    allocator: Allocator,
    spec: SnapSpec,
    new_lines: [][]const u8,
    force_update: bool,
) LifecycleError!Outcome {
    if (force_update) {
        try snapshot.write(spec.path, spec.version, new_lines);
        return .{ .updated = new_lines.len };
    }
    const old = snapshot.read(allocator, spec.path, spec.version) catch |e|
        return onReadError(e, spec, new_lines);
    return finishDiff(allocator, old, new_lines);
}

/// Handles a failed snapshot read: a missing file is written fresh (created),
/// a stale version is surfaced, and any other error propagates.
fn onReadError(e: snapshot.ReadError, spec: SnapSpec, new_lines: [][]const u8) LifecycleError!Outcome {
    switch (e) {
        error.Missing => {
            try snapshot.write(spec.path, spec.version, new_lines);
            return .{ .created = new_lines.len };
        },
        error.VersionMismatch => return .version_mismatch,
        else => return e,
    }
}

/// Sorts `new_lines` in place and diffs it against the prior snapshot.
fn finishDiff(allocator: Allocator, old: snapshot.Snapshot, new_lines: [][]const u8) LifecycleError!Outcome {
    std.mem.sort([]const u8, new_lines, {}, lessThan);
    const diff = try snapshot.diff(allocator, old, new_lines);
    if (diff.isEmpty()) return .{ .unchanged = new_lines.len };
    return .{ .drift = diff };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn deleteIfExists(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) }),
    };
}

// spec: Snapshot Lifecycle - Creates snapshot file on first run with no prior snapshot
// spec: Snapshot Lifecycle - Reports drift when current state differs from prior snapshot
// spec: Snapshot Lifecycle - Honors GUARDIAN_UPDATE_SNAPSHOT to regenerate snapshot

test "snapshotPath joins project_dir, .guardian, leaf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try snapshotPath(a, "/tmp/proj", "panic-budget.txt");
    try testing.expectEqualStrings("/tmp/proj/.guardian/panic-budget.txt", p);
}

test "lifecycle creates snapshot when missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-create.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    const out = try lifecycle(a, .{ .path = path, .version = 1 }, &lines, false);
    try testing.expect(out == .created);
    try testing.expectEqual(@as(usize, 2), out.created);

    // Re-running with no change should return .unchanged.
    var lines2 = [_][]const u8{ "alpha", "beta" };
    const out2 = try lifecycle(a, .{ .path = path, .version = 1 }, &lines2, false);
    try testing.expect(out2 == .unchanged);
}

test "lifecycle reports drift when changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-drift.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, .{ .path = path, .version = 1 }, &lines, false);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, .{ .path = path, .version = 1 }, &lines2, false);
    try testing.expect(out == .drift);
    try testing.expectEqual(@as(usize, 1), out.drift.added.len);
    try testing.expectEqualStrings("gamma", out.drift.added[0]);
    try testing.expectEqual(@as(usize, 1), out.drift.removed.len);
    try testing.expectEqualStrings("beta", out.drift.removed[0]);
}

test "lifecycle force_update overwrites existing snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-force.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, .{ .path = path, .version = 1 }, &lines, false);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, .{ .path = path, .version = 1 }, &lines2, true);
    try testing.expect(out == .updated);

    // After force-update, the new state is now the baseline.
    var lines3 = [_][]const u8{ "alpha", "gamma" };
    const out2 = try lifecycle(a, .{ .path = path, .version = 1 }, &lines3, false);
    try testing.expect(out2 == .unchanged);
}

test "lifecycle reports version_mismatch on stale snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-version.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{"x"};
    try snapshot.write(path, 1, &lines);

    var lines2 = [_][]const u8{"x"};
    const out = try lifecycle(a, .{ .path = path, .version = 2 }, &lines2, false);
    try testing.expect(out == .version_mismatch);
}

// spec: Snapshot Lifecycle - Refreshes only the checks named in a GUARDIAN_UPDATE_SNAPSHOT list

test "classifyValue and refreshIncludes select only the named checks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try classifyValue(a, "pub-api-surface, spec");
    try testing.expect(r == .named);
    try testing.expectEqual(@as(usize, 2), r.named.len);
    // Only the two listed checks refresh; everything else is held back.
    try testing.expect(refreshIncludes(r, "pub-api-surface"));
    try testing.expect(refreshIncludes(r, "spec"));
    try testing.expect(!refreshIncludes(r, "panic-budget"));
}

// spec: Snapshot Lifecycle - Treats a 1, true, or all value as a full refresh

test "classifyValue treats 1, true, and all as a full refresh of every check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "1", "true", "all" }) |token| {
        const r = try classifyValue(a, token);
        try testing.expect(r == .all);
        // A full refresh includes any check name.
        try testing.expect(refreshIncludes(r, "pub-api-surface"));
        try testing.expect(refreshIncludes(r, "anything-else"));
    }
}

// spec: Snapshot Lifecycle - Treats an unset, empty, or zero value as no refresh

test "classifyValue treats empty and zero as no refresh" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "   ", "0" }) |token| {
        const r = try classifyValue(a, token);
        try testing.expect(r == .none);
        try testing.expect(!refreshIncludes(r, "pub-api-surface"));
    }
}
