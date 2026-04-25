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

/// Returns true if the user has requested a snapshot regeneration via the
/// GUARDIAN_UPDATE_SNAPSHOT env var. Empty / unset / "0" all return false.
pub fn shouldUpdate(allocator: Allocator) bool {
    const v = std.process.getEnvVarOwned(allocator, UPDATE_ENV) catch return false;
    defer allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Joins `project_dir/.guardian/{leaf}` for snapshot file paths. Caller owns
/// the returned slice (via allocator).
pub fn snapshotPath(allocator: Allocator, project_dir: []const u8, leaf: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.guardian/{s}", .{ project_dir, leaf });
}

/// Runs the standard snapshot lifecycle for set-diff style checks
/// (pub-api-surface, spec-drift): if no snapshot exists OR `force_update` is
/// set, write the current `new_lines` and report created/updated. Otherwise
/// read the prior snapshot and diff against the (sorted) current state.
///
/// `new_lines` is sorted in place when needed for diffing. The slice may be
/// retained by the returned Outcome.
pub fn lifecycle(
    allocator: Allocator,
    snap_path: []const u8,
    version: u32,
    new_lines: [][]const u8,
    force_update: bool,
) LifecycleError!Outcome {
    if (force_update) {
        try snapshot.write(snap_path, version, new_lines);
        return .{ .updated = new_lines.len };
    }

    const old = snapshot.read(allocator, snap_path, version) catch |e| switch (e) {
        error.Missing => {
            try snapshot.write(snap_path, version, new_lines);
            return .{ .created = new_lines.len };
        },
        error.VersionMismatch => return .version_mismatch,
        else => return e,
    };

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

test "snapshotPath joins project_dir, .guardian, leaf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try snapshotPath(a, "/tmp/proj", "panic-budget.txt");
    try testing.expectEqualStrings("/tmp/proj/.guardian/panic-budget.txt", p);
}

// spec: Snapshot Lifecycle - Creates snapshot file on first run with no prior snapshot
test "lifecycle creates snapshot when missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-create.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    const out = try lifecycle(a, path, 1, &lines, false);
    try testing.expect(out == .created);
    try testing.expectEqual(@as(usize, 2), out.created);

    // Re-running with no change should return .unchanged.
    var lines2 = [_][]const u8{ "alpha", "beta" };
    const out2 = try lifecycle(a, path, 1, &lines2, false);
    try testing.expect(out2 == .unchanged);
}

// spec: Snapshot Lifecycle - Reports drift when current state differs from prior snapshot
test "lifecycle reports drift when changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-drift.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, path, 1, &lines, false);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, path, 1, &lines2, false);
    try testing.expect(out == .drift);
    try testing.expectEqual(@as(usize, 1), out.drift.added.len);
    try testing.expectEqualStrings("gamma", out.drift.added[0]);
    try testing.expectEqual(@as(usize, 1), out.drift.removed.len);
    try testing.expectEqualStrings("beta", out.drift.removed[0]);
}

// spec: Snapshot Lifecycle - Honors GUARDIAN_UPDATE_SNAPSHOT to regenerate snapshot
test "lifecycle force_update overwrites existing snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-force.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, path, 1, &lines, false);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, path, 1, &lines2, true);
    try testing.expect(out == .updated);

    // After force-update, the new state is now the baseline.
    var lines3 = [_][]const u8{ "alpha", "gamma" };
    const out2 = try lifecycle(a, path, 1, &lines3, false);
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
    const out = try lifecycle(a, path, 2, &lines2, false);
    try testing.expect(out == .version_mismatch);
}
