//! Snapshot file format: read, write, and set-diff the sorted `<value>` lines
//! under a `# guardian-snapshot v<N>` header that the budget/surface checks
//! ratchet against. Pure format layer — lifecycle and pass/fail policy live in
//! snapshot_helper.zig.

const std = @import("std");
const fs = @import("fs.zig");
const Allocator = std.mem.Allocator;

threadlocal var failure_path: ?[]const u8 = null;

/// Path of the snapshot whose most recent read failed on this thread.
pub fn lastErrorPath() ?[]const u8 {
    return failure_path;
}

pub const magic_prefix = "# guardian-snapshot v";

/// Comment `merge-file` stamps on a merged counter snapshot whose two sides
/// both moved the same counter: the merge took the larger value, which is a
/// guess, so the file must be regenerated before it can be trusted. The
/// `merge-state` check fails the gate while this line is present.
pub const regen_marker = "# guardian-merge: regenerate";

/// Line prefixes git writes into a file it could not merge. A snapshot holding
/// one is an unresolved conflict, not data — reading it must name that rather
/// than diff the marker text as though it were an entry. `=======` is left out
/// deliberately: alone it is ambiguous, and every real conflict carries the
/// unambiguous opening/closing markers too.
const conflict_prefixes = [_][]const u8{ "<<<<<<<", ">>>>>>>", "|||||||" };

/// True when `line` opens, closes, or splits a git conflict region.
pub fn isConflictMarker(line: []const u8) bool {
    for (conflict_prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return true;
    }
    return false;
}

/// True when `line` is a comment (the version header, the regenerate marker, or
/// any other `#` row) rather than a snapshot entry.
pub fn isComment(line: []const u8) bool {
    return line.len > 0 and line[0] == '#';
}

/// True when `content` carries the merge-regenerate marker comment.
pub fn hasRegenMarker(content: []const u8) bool {
    return std.mem.indexOf(u8, content, regen_marker) != null;
}

/// A read snapshot file, parsed into version + sorted lines.
pub const Snapshot = struct {
    version: u32,
    lines: []const []const u8,
};

/// Set difference between an old snapshot and a new sorted-lines slice.
pub const Diff = struct {
    added: []const []const u8,
    removed: []const []const u8,

    /// True when nothing was added or removed — the snapshot is unchanged.
    pub fn isEmpty(self: Diff) bool {
        return self.added.len == 0 and self.removed.len == 0;
    }
};

pub const ReadError = error{
    Missing,
    BadFormat,
    VersionMismatch,
    ConflictMarkers,
} || std.mem.Allocator.Error || fs.File.OpenError || fs.File.ReadError || error{StreamTooLong};

/// Parses the magic header line, validating the prefix and version.
/// Returns BadFormat on a missing/malformed header and VersionMismatch
/// when the parsed version doesn't equal expected_version.
fn parseHeader(header: ?[]const u8, expected_version: u32) ReadError!u32 {
    const version = try parseVersion(header);
    if (version != expected_version) return error.VersionMismatch;
    return version;
}

/// Extracts the version integer from a header line, or BadFormat if the
/// line is missing, lacks the magic prefix, or has a non-integer version.
fn parseVersion(header: ?[]const u8) ReadError!u32 {
    const line = header orelse return error.BadFormat;
    if (!std.mem.startsWith(u8, line, magic_prefix)) return error.BadFormat;
    const ver_str = line[magic_prefix.len..];
    return std.fmt.parseInt(u32, ver_str, 10) catch error.BadFormat;
}

/// Reads a snapshot file. Returns Missing if the file does not exist,
/// BadFormat if the magic header is missing or malformed, VersionMismatch
/// if the version doesn't match expected_version, ConflictMarkers when the
/// file is an unresolved merge.
pub fn read(arena: Allocator, path: []const u8, expected_version: u32) ReadError!Snapshot {
    failure_path = path;
    const content = fs.cwd().readFileAlloc(arena, path, 16 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return error.Missing,
        // Pass through real I/O / OOM errors — only a bad header is BadFormat,
        // so "your snapshot is corrupt" isn't reported for a permission error.
        else => |err| return err,
    };
    const parsed = try parse(arena, content, expected_version);
    failure_path = null;
    return parsed;
}

/// Reads `path` at `expected_version`, or null when the file is absent or is in
/// a different format version.
///
/// For a READ-ONLY reader, "nothing recorded yet" and "recorded in a format I
/// don't speak" are the same answer — there is no comparable stored state — and
/// neither is worth failing a report over. Only a corrupt file or a real I/O
/// error still propagates. Writers must NOT use this: they have to tell the two
/// apart, because absent means create and stale means migrate.
pub fn readOptional(arena: Allocator, path: []const u8, expected_version: u32) ReadError!?Snapshot {
    return read(arena, path, expected_version) catch |e| switch (e) {
        error.Missing, error.VersionMismatch => {
            failure_path = null;
            return null;
        },
        else => e,
    };
}

/// Parses snapshot bytes into version + entries — `read` without the file I/O,
/// so the tolerances below are testable from a string.
///
/// Entries are **sorted on load**, and comment rows (`#`) are skipped. Both are
/// merge tolerances: a union-resolved conflict is unsorted by construction, and
/// `diff` merges two ordered runs, so an unsorted file used to trip an assert
/// and abort the process (`reached unreachable`) with no hint that ORDER was the
/// problem. A file that still holds git's conflict markers is a named error
/// instead — there is no honest reading of it.
pub fn parse(arena: Allocator, content: []const u8, expected_version: u32) ReadError!Snapshot {
    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    const version = try parseHeader(lines_iter.next(), expected_version);

    var lines: std.ArrayList([]const u8) = .empty;
    while (lines_iter.next()) |line| {
        if (line.len == 0 or isComment(line)) continue;
        if (isConflictMarker(line)) return error.ConflictMarkers;
        try lines.append(arena, line);
    }
    const owned = try lines.toOwnedSlice(arena);
    std.mem.sort([]const u8, owned, {}, lessThan);
    return .{ .version = version, .lines = owned };
}

/// Parses a stored snapshot at the version declared by its own header. Used by
/// `doctor`, which validates integrity across several snapshot families without
/// pretending they all share one format version.
pub fn parseAnyVersion(arena: Allocator, content: []const u8) ReadError!Snapshot {
    var lines = std.mem.splitScalar(u8, content, '\n');
    const version = try parseVersion(lines.next());
    return parse(arena, content, version);
}

/// Errors that an atomic snapshot replacement may propagate.
pub const WriteError = fs.AtomicFile.InitError ||
    fs.AtomicFile.FinishError ||
    std.mem.Allocator.Error ||
    error{WriteFailed};

/// Writes a snapshot file. Lines are sorted in place for deterministic output.
pub fn write(path: []const u8, version: u32, lines: [][]const u8) WriteError!void {
    std.mem.sort([]const u8, lines, {}, lessThan);
    try writePresorted(path, version, lines);
}

/// Writes a snapshot file in the caller's line order (no sort). Callers that
/// need a non-lexical order — the per-item ratchet baseline stores `<value>
/// <key>` lines but sorts them by *key* so a value change never reorders the
/// file — presort and call this. `write` is `sort` + `writePresorted`.
pub fn writePresorted(path: []const u8, version: u32, lines: []const []const u8) WriteError!void {
    var buf: [4096]u8 = undefined;
    var atomic = try fs.cwd().atomicFile(path, .{ .make_path = true, .write_buffer = &buf });
    defer atomic.deinit();
    const w = &atomic.file_writer.interface;
    try w.print("{s}{d}\n", .{ magic_prefix, version });
    for (lines) |line| {
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    try atomic.finish();
}

/// Sorts `lines`, then writes only when the result differs from what is already
/// on disk — the content-identical short-circuit. Returns true when the file was
/// (re)written, false when an identical file was left untouched. The `sort` +
/// `writePresortedChecked` twin of `write`, used by the baseline/ratchet/snapshot
/// lifecycle so a rewrite that would only re-emit the same set (unchanged
/// content, a re-order, a re-stamp) never dirties a consumer's `git status`.
pub fn writeChecked(arena: Allocator, path: []const u8, version: u32, lines: [][]const u8) WriteError!bool {
    std.mem.sort([]const u8, lines, {}, lessThan);
    return writePresortedChecked(arena, path, version, lines);
}

/// Writes `lines` in the caller's order only when the rendered bytes differ from
/// the file already on disk. Returns true when it (re)wrote, false when the
/// existing file was byte-identical and left in place. See `writeChecked`.
pub fn writePresortedChecked(arena: Allocator, path: []const u8, version: u32, lines: []const []const u8) WriteError!bool {
    const rendered = try render(arena, version, lines);
    if (onDiskEquals(arena, path, rendered)) return false;
    try writePresorted(path, version, lines);
    return true;
}

/// Renders the exact bytes `writePresorted` would emit (version header + one
/// line each) into an arena buffer, so a write can be compared against the file
/// on disk before replacing it.
fn render(arena: Allocator, version: u32, lines: []const []const u8) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{s}{d}\n", .{ magic_prefix, version }));
    for (lines) |line| {
        try buf.appendSlice(arena, line);
        try buf.append(arena, '\n');
    }
    return buf.toOwnedSlice(arena);
}

/// True when the file at `path` exists and holds exactly `bytes`. A missing or
/// unreadable file is "not equal" (so the write proceeds), never an error.
fn onDiskEquals(arena: Allocator, path: []const u8, bytes: []const u8) bool {
    const existing = fs.cwd().readFileAlloc(arena, path, 16 * 1024 * 1024) catch return false;
    return std.mem.eql(u8, existing, bytes);
}

/// Compute added/removed sets between snapshot lines and a new sorted slice.
///
/// The linear merge below is only correct on ordered inputs. `new_lines` is the
/// caller's freshly measured state, sorted immediately before the call, so that
/// side stays an assert. `old.lines` comes off DISK, where a hand-resolved merge
/// can leave any order at all, so it is sorted defensively instead: a file must
/// never be able to abort the process. `parse` already sorts, making the copy
/// below a no-op on every read snapshot; it exists for a hand-built `Snapshot`.
pub fn diff(arena: Allocator, old: Snapshot, new_lines: []const []const u8) std.mem.Allocator.Error!Diff {
    std.debug.assert(std.sort.isSorted([]const u8, new_lines, {}, lessThan));
    const old_lines = try sortedCopy(arena, old.lines);
    var added: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    var j: usize = 0;
    while (i < old_lines.len and j < new_lines.len) {
        const cmp = std.mem.order(u8, old_lines[i], new_lines[j]);
        switch (cmp) {
            .eq => {
                i += 1;
                j += 1;
            },
            .lt => {
                try removed.append(arena, old_lines[i]);
                i += 1;
            },
            .gt => {
                try added.append(arena, new_lines[j]);
                j += 1;
            },
        }
    }
    while (i < old_lines.len) : (i += 1) try removed.append(arena, old_lines[i]);
    while (j < new_lines.len) : (j += 1) try added.append(arena, new_lines[j]);

    return .{
        .added = try added.toOwnedSlice(arena),
        .removed = try removed.toOwnedSlice(arena),
    };
}

/// An ascending copy of `lines`, so the caller can merge it without mutating
/// (or trusting the order of) what it was handed.
fn sortedCopy(arena: Allocator, lines: []const []const u8) Allocator.Error![][]const u8 {
    const out = try arena.dupe([]const u8, lines);
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// spec: Snapshot Lifecycle - Atomically replaces snapshot files after fully writing their contents

test "write then read round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_path = "zig-cache/test-snapshot.txt";
    var lines = [_][]const u8{ "zebra", "apple", "mango" };
    try write(tmp_path, 1, &lines);
    defer fs.cwd().deleteFile(tmp_path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ tmp_path, @errorName(e) });

    const snap = try read(a, tmp_path, 1);
    try std.testing.expectEqual(@as(u32, 1), snap.version);
    try std.testing.expectEqual(@as(usize, 3), snap.lines.len);
    // Sorted on write
    try std.testing.expectEqualStrings("apple", snap.lines[0]);
    try std.testing.expectEqualStrings("mango", snap.lines[1]);
    try std.testing.expectEqualStrings("zebra", snap.lines[2]);
}

test "writePresorted keeps the caller's line order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_path = "zig-cache/test-snapshot-presorted.txt";
    // Deliberately non-lexical order: writePresorted must not reorder it.
    const lines = [_][]const u8{ "130 zebra", "95 apple" };
    try writePresorted(tmp_path, 2, &lines);
    defer fs.cwd().deleteFile(tmp_path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ tmp_path, @errorName(e) });

    const snap = try read(a, tmp_path, 2);
    try std.testing.expectEqual(@as(usize, 2), snap.lines.len);
    try std.testing.expectEqualStrings("130 zebra", snap.lines[0]);
    try std.testing.expectEqualStrings("95 apple", snap.lines[1]);
}

// spec: Snapshot Lifecycle - Skips an identical rewrite and leaves the file untouched

test "writeChecked rewrites only when the content differs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_path = "zig-cache/test-snapshot-checked.txt";
    fs.cwd().deleteFile(tmp_path) catch {};
    defer fs.cwd().deleteFile(tmp_path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ tmp_path, @errorName(e) });

    // First write of a missing file reports a real write.
    var first = [_][]const u8{ "beta", "alpha" };
    try std.testing.expect(try writeChecked(a, tmp_path, 1, &first));

    // Re-writing the SAME set (even given in a different order — writeChecked
    // sorts first) renders byte-identical content, so the file is left untouched
    // and nothing is reported as written: the content-identical short-circuit.
    const before = try fs.cwd().readFileAlloc(a, tmp_path, 4096);
    var same = [_][]const u8{ "alpha", "beta" };
    try std.testing.expect(!try writeChecked(a, tmp_path, 1, &same));
    const after = try fs.cwd().readFileAlloc(a, tmp_path, 4096);
    try std.testing.expectEqualStrings(before, after);

    // A genuine change writes again.
    var changed = [_][]const u8{ "alpha", "gamma" };
    try std.testing.expect(try writeChecked(a, tmp_path, 1, &changed));

    // writePresortedChecked is the presorted twin (no sort) the ratchet uses:
    // it preserves the caller's order and applies the same short-circuit.
    const ordered = [_][]const u8{ "130 zebra", "95 apple" };
    try std.testing.expect(try writePresortedChecked(a, tmp_path, 2, &ordered));
    try std.testing.expect(!try writePresortedChecked(a, tmp_path, 2, &ordered));
    const snap = try read(a, tmp_path, 2);
    try std.testing.expectEqualStrings("130 zebra", snap.lines[0]);
}

test "read returns Missing for missing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.Missing, read(a, "/tmp/does-not-exist-guardian.txt", 1));
}

test "read returns VersionMismatch on wrong version" {
    _ = &lastErrorPath;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp_path = "zig-cache/test-snapshot-ver.txt";
    var lines = [_][]const u8{"x"};
    try write(tmp_path, 1, &lines);
    defer fs.cwd().deleteFile(tmp_path) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ tmp_path, @errorName(e) });

    try std.testing.expectError(error.VersionMismatch, read(a, tmp_path, 2));
}

test "parseAnyVersion validates the declared header and conflict markers" {
    const a = std.testing.allocator;
    const parsed = try parseAnyVersion(a, "# guardian-snapshot v7\nalpha\n");
    defer a.free(parsed.lines);
    try std.testing.expectEqual(@as(u32, 7), parsed.version);
    try std.testing.expectError(
        error.ConflictMarkers,
        parseAnyVersion(a, "# guardian-snapshot v7\n<<<<<<< ours\n"),
    );
}

test "diff finds added and removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old: Snapshot = .{
        .version = 1,
        .lines = &.{ "apple", "banana", "cherry" },
    };
    const new_lines = [_][]const u8{ "apple", "cherry", "date" };
    const d = try diff(a, old, &new_lines);

    try std.testing.expectEqual(@as(usize, 1), d.removed.len);
    try std.testing.expectEqualStrings("banana", d.removed[0]);
    try std.testing.expectEqual(@as(usize, 1), d.added.len);
    try std.testing.expectEqualStrings("date", d.added[0]);
}

// spec: Assertion Discipline - Snapshot diff merges two sorted inputs into their exact set difference
test "diff over disjoint sorted inputs reports every add and remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Both sides are sorted (the diff precondition) but share no element, so the
    // linear merge must interleave them into a full remove-set and add-set.
    const old: Snapshot = .{ .version = 1, .lines = &.{ "bravo", "delta", "foxtrot" } };
    const new_lines = [_][]const u8{ "alpha", "charlie", "echo", "golf" };
    const d = try diff(a, old, &new_lines);
    try std.testing.expectEqual(@as(usize, 3), d.removed.len);
    try std.testing.expectEqual(@as(usize, 4), d.added.len);
    try std.testing.expectEqualStrings("alpha", d.added[0]);
    try std.testing.expectEqualStrings("bravo", d.removed[0]);
}

// spec: Merge - Reads an unsorted snapshot by sorting it on load

test "parse sorts a union-resolved snapshot instead of aborting the run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exactly what a hand-unioned conflict leaves behind: well-formed entries in
    // no particular order. This used to trip diff's isSorted assert.
    const unioned = "# guardian-snapshot v2\nzebra\napple\nmango\n";
    const snap = try parse(a, unioned, 2);
    try std.testing.expectEqualStrings("apple", snap.lines[0]);
    try std.testing.expectEqualStrings("zebra", snap.lines[2]);

    // ...and diffing it against the same set now reports no drift at all.
    var current = [_][]const u8{ "apple", "mango", "zebra" };
    try std.testing.expect((try diff(a, snap, &current)).isEmpty());
}

// spec: Merge - Names an unresolved conflict instead of reading marker text as entries

test "parse rejects conflict markers and skips comment rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const conflicted = "# guardian-snapshot v2\n<<<<<<< HEAD\napple\n=======\nbanana\n>>>>>>> theirs\n";
    try std.testing.expectError(error.ConflictMarkers, parse(a, conflicted, 2));

    // A merged-but-unregenerated counter file still READS (the gate reports the
    // marker); the comment is not mistaken for an entry.
    const marked = "# guardian-snapshot v1\n" ++ regen_marker ++ " (X)\n@alignCast 68\n";
    const snap = try parse(a, marked, 1);
    try std.testing.expectEqual(@as(usize, 1), snap.lines.len);
    try std.testing.expectEqualStrings("@alignCast 68", snap.lines[0]);
    try std.testing.expect(hasRegenMarker(marked));
    try std.testing.expect(!hasRegenMarker(conflicted));
    try std.testing.expect(isComment("# x") and !isComment("x"));
    // Both ends of a conflict region are markers; the bare `=======` separator
    // is not, since a snapshot row could legitimately start that way.
    try std.testing.expect(isConflictMarker("<<<<<<< HEAD"));
    try std.testing.expect(isConflictMarker(">>>>>>> theirs"));
    try std.testing.expect(!isConflictMarker("======="));
}

test "diff identical snapshots returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old: Snapshot = .{
        .version = 1,
        .lines = &.{ "apple", "banana" },
    };
    const new_lines = [_][]const u8{ "apple", "banana" };
    const d = try diff(a, old, &new_lines);
    try std.testing.expect(d.isEmpty());
}

fn fuzzSnapshotParser(backing: Allocator, smith: *std.testing.Smith) anyerror!void {
    var bytes: [64 * 1024]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    _ = parseAnyVersion(arena.allocator(), input) catch |err| switch (err) {
        error.BadFormat, error.ConflictMarkers, error.OutOfMemory => return,
        else => return,
    };
}

test "fuzz: snapshot parser tolerates arbitrary state bytes" {
    try std.testing.fuzz(std.testing.allocator, fuzzSnapshotParser, .{ .corpus = &.{ "", "# guardian-snapshot v2\nx\n", "<<<<<<<" } });
}

test "optional missing reads clear the diagnostic path" {
    try std.testing.expect((try readOptional(std.testing.allocator, "zig-cache/no-such-snapshot.txt", 1)) == null);
    try std.testing.expect(lastErrorPath() == null);
}
