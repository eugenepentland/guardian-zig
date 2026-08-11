//! Session-scoped accept memory for ratchet checks.
//!
//! `guardian-check accept file-size` locks the ratchet at today's values, but
//! a feature still being written keeps growing the same file — historically
//! that meant re-running accept every few builds for the same intent ("this
//! feature grows this file"). This module records each accepted ratchet check
//! together with the git HEAD it was accepted at; while HEAD is unchanged
//! (the same working session), further growth of that check auto-re-accepts
//! with a green notice instead of failing. The first commit moves HEAD, the
//! note expires, and the ratchet is locked again — accept churn dies without
//! ever weakening what a commit can ratify.
//!
//! The note lives under `.guardian/cache/` (gitignored, excluded from the
//! green-run digest) and is best-effort everywhere: outside a git repo
//! nothing is recorded and nothing is ever pending.

const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("git.zig");
const snapshot = @import("snapshot.zig");
const reporter = @import("reporter.zig");

/// Pending-accepts file format version.
pub const version: u32 = 1;

/// Project-relative path of the note file, named here so `doctor` can tell a
/// reader which file to delete without a second spelling of it.
pub const leaf = ".guardian/cache/pending-accepts.txt";

fn pathFor(a: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ project_dir, leaf });
}

/// Records `checks` as pending at the current HEAD. Entries recorded at any
/// other HEAD are dropped (they expired at a commit). Best-effort: outside a
/// git repo, or on any I/O failure, the note is simply not recorded.
pub fn record(a: Allocator, project_dir: []const u8, checks: []const []const u8) void {
    const head = git.headHash(a, project_dir) orelse return;
    recordAtHead(a, project_dir, head, checks) catch |e|
        reporter.detail("  note: pending-accept session note not recorded ({s})\n", .{@errorName(e)});
}

/// True when `check` was accepted at the current HEAD and no commit has
/// happened since — the condition under which further ratchet growth of that
/// check re-accepts instead of failing.
pub fn isPending(a: Allocator, project_dir: []const u8, check: []const u8) bool {
    const head = git.headHash(a, project_dir) orelse return false;
    return isPendingAtHead(a, project_dir, head, check);
}

/// Testable core of `record`: merge surviving same-`head` entries with the
/// newly accepted checks and rewrite the note.
fn recordAtHead(
    a: Allocator,
    project_dir: []const u8,
    head: []const u8,
    checks: []const []const u8,
) (Allocator.Error || snapshot.WriteError)!void {
    const path = try pathFor(a, project_dir);
    var lines: std.ArrayList([]const u8) = .empty;
    if (snapshot.read(a, path, version)) |snap| {
        for (snap.lines) |line| {
            const e = decodeLine(line) orelse continue;
            if (!std.mem.eql(u8, e.head, head)) continue; // expired at a commit
            if (nameInList(checks, e.check)) continue; // re-recorded below
            try lines.append(a, line);
        }
    } else |_| {}
    for (checks) |check|
        try lines.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ head, check }));
    try snapshot.write(path, version, lines.items);
}

/// Testable core of `isPending`: a `<head> <check>` line must match exactly.
fn isPendingAtHead(a: Allocator, project_dir: []const u8, head: []const u8, check: []const u8) bool {
    const path = pathFor(a, project_dir) catch return false;
    const snap = snapshot.read(a, path, version) catch return false;
    for (snap.lines) |line| {
        const e = decodeLine(line) orelse continue;
        if (std.mem.eql(u8, e.head, head) and std.mem.eql(u8, e.check, check)) return true;
    }
    return false;
}

/// One pending note: the HEAD it was accepted at and the accepted check.
pub const Entry = struct { head: []const u8, check: []const u8 };

/// Every recorded note, in file order. Empty when the note file is absent,
/// unreadable, or holds no decodable line — this is a read surface for
/// `doctor`, so an unusable note reads as "nothing pending" rather than an
/// error. Entries recorded at some other HEAD have already expired and suppress
/// nothing; they are still returned, because a leftover nothing else mentions
/// is exactly what a health audit exists to surface.
pub fn recorded(a: Allocator, project_dir: []const u8) Allocator.Error![]const Entry {
    const path = try pathFor(a, project_dir);
    const snap = snapshot.read(a, path, version) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var out: std.ArrayList(Entry) = .empty;
    for (snap.lines) |line| {
        const e = decodeLine(line) orelse continue;
        try out.append(a, e);
    }
    return out.items;
}

/// Parses a stored `<head> <check>` line, or null when blank / malformed.
fn decodeLine(line: []const u8) ?Entry {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    if (sp == 0 or sp + 1 >= line.len) return null;
    return .{ .head = line[0..sp], .check = line[sp + 1 ..] };
}

fn nameInList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Maintenance - Accept records a session note that expires when the head commit changes

test "a recorded session note is pending at its head and expires at another" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-accept-session";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    try recordAtHead(a, dir, "aaaa1111", &.{ "file-size", "type-size" });
    try testing.expect(isPendingAtHead(a, dir, "aaaa1111", "file-size"));
    try testing.expect(isPendingAtHead(a, dir, "aaaa1111", "type-size"));
    // Not accepted → never pending.
    try testing.expect(!isPendingAtHead(a, dir, "aaaa1111", "function-length"));
    // A commit moved HEAD → the note has expired.
    try testing.expect(!isPendingAtHead(a, dir, "bbbb2222", "file-size"));

    // Recording at the new head drops the expired entries and starts fresh.
    try recordAtHead(a, dir, "bbbb2222", &.{"file-size"});
    try testing.expect(isPendingAtHead(a, dir, "bbbb2222", "file-size"));
    try testing.expect(!isPendingAtHead(a, dir, "bbbb2222", "type-size"));
    try testing.expect(!isPendingAtHead(a, dir, "aaaa1111", "file-size"));
}

// spec: Maintenance - Lists every recorded session note including expired ones

test "recorded lists notes from both heads and is empty without a note file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-accept-session-list";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};

    try testing.expectEqual(@as(usize, 0), (try recorded(a, dir)).len);
    try recordAtHead(a, dir, "aaaa1111", &.{ "file-size", "type-size" });
    const entries = try recorded(a, dir);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("aaaa1111", entries[0].head);
    try testing.expectEqualStrings("file-size", entries[0].check);
    // An entry recorded at another head suppresses nothing, but stays visible.
    try testing.expect(!isPendingAtHead(a, dir, "bbbb2222", "file-size"));
    try testing.expectEqual(@as(usize, 2), (try recorded(a, dir)).len);
}

test "decodeLine parses head and check, rejecting malformed lines" {
    const e = decodeLine("abc123 file-size").?;
    try testing.expectEqualStrings("abc123", e.head);
    try testing.expectEqualStrings("file-size", e.check);
    try testing.expect(decodeLine("") == null);
    try testing.expect(decodeLine("no-space") == null);
    try testing.expect(decodeLine("head ") == null);
}

test "a missing note file means nothing is pending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(!isPendingAtHead(a, "zig-cache/no-such-session-dir", "aaaa1111", "file-size"));
}

test "record and isPending agree through the live git head" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-accept-session-live";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    // Inside a git checkout this is a live round-trip at the real HEAD;
    // outside one, record no-ops and isPending stays false — the two public
    // entry points agree either way.
    record(a, dir, &.{"file-size"});
    const in_repo = git.headHash(a, dir) != null;
    try testing.expectEqual(in_repo, isPending(a, dir, "file-size"));
    try testing.expect(!isPending(a, dir, "function-length"));
}
