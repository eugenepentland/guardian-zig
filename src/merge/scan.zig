//! Reads every `.guardian/` metadata file and reports the ones a merge left in
//! a state the gate must not accept: git's conflict markers still in the file,
//! a counter merge still marked for regeneration, or a row that does not parse
//! in its own format.
//!
//! This is the locator behind the `merge-state` check and behind the diagnostic
//! `check.zig` prints when a snapshot read fails on an unresolved conflict — one
//! implementation, so both name the same file and line.

const std = @import("std");
const fs = @import("../fs.zig");
const Allocator = std.mem.Allocator;
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const artifact = @import("artifact.zig");

/// Upper bound on a metadata file this scan will read.
const max_bytes = 16 * 1024 * 1024;

/// The `.guardian/` subdirectories holding metadata files (`cache/` is derived,
/// git-ignored output and never merged).
const scanned_dirs = [_][]const u8{ ".guardian", ".guardian/baselines" };

/// What is wrong with one metadata file, and where.
pub const Trouble = enum {
    /// git's conflict markers are still in the file.
    unresolved,
    /// A merge picked a counter value it had to guess; the file must be
    /// regenerated before it can be trusted.
    pending_regen,
    /// A row does not parse in the file's own format.
    malformed_row,
};

/// One located finding: the project-relative file, the 1-based line, what is
/// wrong, the offending text, and the check whose refresh regenerates the file.
pub const Finding = struct {
    path: []const u8,
    line: usize,
    trouble: Trouble,
    text: []const u8,
    check: []const u8,
};

/// Every finding under `project_dir`'s `.guardian/`, in directory order. An
/// unreadable directory or file is skipped: this reports on metadata that
/// exists, and `doctor` owns the "your metadata is unreadable" verdict.
pub fn findings(arena: Allocator, project_dir: []const u8) Allocator.Error![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (scanned_dirs) |rel| try scanDir(arena, &out, project_dir, rel);
    return out.toOwnedSlice(arena);
}

/// Appends the findings for every `.txt` file directly inside `rel`.
fn scanDir(
    arena: Allocator,
    out: *std.ArrayList(Finding),
    project_dir: []const u8,
    rel: []const u8,
) Allocator.Error!void {
    const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, rel });
    var dir = fs.cwd().openDir(full, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const rel_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });
        const content = dir.readFileAlloc(arena, entry.name, max_bytes) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try inspect(arena, out, rel_path, content);
    }
}

/// Appends every finding in one file's bytes.
pub fn inspect(
    arena: Allocator,
    out: *std.ArrayList(Finding),
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error!void {
    const check = checkNameFor(rel_path);
    const parsed = try artifact.parse(arena, content);
    if (parsed.failure()) |p| {
        // A missing header is `doctor`'s advisory, not a merge failure: only an
        // unresolved conflict is reported here.
        if (p.kind != .conflict_markers) return;
        try out.append(arena, located(rel_path, p, .unresolved, check));
        return;
    }
    const file = parsed.value();
    if (file.pending_regen) try out.append(arena, .{
        .path = rel_path,
        .line = 1,
        .trouble = .pending_regen,
        .text = snapshot.regen_marker,
        .check = check,
    });
    const kind = artifact.classify(rel_path, file.version, file.rows);
    for (try artifact.malformedRows(arena, content, kind)) |p|
        try out.append(arena, located(rel_path, p, .malformed_row, check));
}

/// Pairs a parse problem with the file it came from.
fn located(rel_path: []const u8, p: artifact.Problem, trouble: Trouble, check: []const u8) Finding {
    return .{ .path = rel_path, .line = p.line, .trouble = trouble, .text = p.text, .check = check };
}

/// The check whose refresh regenerates the file at `rel_path` (its leaf without
/// the `.txt`, with `pub-api.txt` resolved to its differently-spelled check).
fn checkNameFor(rel_path: []const u8) []const u8 {
    const leaf = std.fs.path.basename(rel_path);
    if (!std.mem.endsWith(u8, leaf, ".txt")) return leaf;
    return snapshot_helper.canonicalCheckName(leaf[0 .. leaf.len - ".txt".len]);
}

/// One-line description of a finding, for the check's output.
pub fn describe(trouble: Trouble) []const u8 {
    return switch (trouble) {
        .unresolved => "unresolved conflict markers",
        .pending_regen => "merged with a guessed counter; regenerate before committing",
        .malformed_row => "row does not parse in this file's format",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Collects the findings for one file's bytes, the way `scanDir` would.
fn inspectOne(arena: Allocator, rel_path: []const u8, content: []const u8) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    try inspect(arena, &out, rel_path, content);
    return out.toOwnedSlice(arena);
}

// spec: Merge - Locates an unresolved or regenerate-marked metadata file

test "inspect reports conflict markers and the regenerate marker with their file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const conflicted = "# guardian-snapshot v2\n<<<<<<< HEAD\nsrc/a.zig::f | fn f() void\n";
    const found = try inspectOne(a, ".guardian/pub-api.txt", conflicted);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expect(found[0].trouble == .unresolved);
    try testing.expectEqual(@as(usize, 2), found[0].line);
    // The finding names the check that regenerates the file, not the leaf.
    try testing.expectEqualStrings("pub-api-surface", found[0].check);

    const marked = "# guardian-snapshot v1\n" ++ snapshot.regen_marker ++ " (x)\n@alignCast 68\n";
    const pending = try inspectOne(a, ".guardian/unsafe-ops-budget.txt", marked);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expect(pending[0].trouble == .pending_regen);
    try testing.expectEqualStrings("unsafe-ops-budget", pending[0].check);
}

// spec: Merge - Passes metadata that carries neither marker

test "inspect stays silent on a clean metadata file and names a bad row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const clean = "# guardian-snapshot v1\n@alignCast 68\n@bitCast 0\n";
    var quiet: std.ArrayList(Finding) = .empty;
    try inspect(a, &quiet, ".guardian/unsafe-ops-budget.txt", clean);
    try testing.expectEqual(@as(usize, 0), quiet.items.len);

    const broken = "# guardian-snapshot v1\n@alignCast 68\nnot a counter row\n";
    const found = try inspectOne(a, ".guardian/unsafe-ops-budget.txt", broken);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expect(found[0].trouble == .malformed_row);
    try testing.expectEqual(@as(usize, 3), found[0].line);
    try testing.expect(std.mem.indexOf(u8, describe(found[0].trouble), "does not parse") != null);
}

// spec: Merge - Scans the metadata directories a repository actually commits

test "findings reads this repository's own .guardian metadata cleanly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Guardian's own committed metadata is resolved, so the scan is empty — and
    // a missing directory is a skip, not an error.
    try testing.expectEqual(@as(usize, 0), (try findings(a, ".")).len);
    try testing.expectEqual(@as(usize, 0), (try findings(a, "/nonexistent-guardian-project")).len);
}
