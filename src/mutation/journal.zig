//! Crash-safe mutant hygiene for the `mutate` command. A mutant is a deliberate
//! edit spliced into a *real* source file; if guardian dies while one is applied
//! (a user SIGKILLing a stuck run, an OOM, a crash) the broken bytes are left on
//! disk — silently corrupting the tree. Three layers guard against that:
//!
//!   1. **Journal.** `begin` records the file, the mutant byte range, the full
//!      original bytes, and a hash of the mutated bytes to
//!      `.guardian/cache/mutant-in-flight.json` *before* the splice; `finish`
//!      clears it after the normal in-place restore.
//!   2. **Signal handlers.** `install` traps SIGINT/SIGTERM, kills any running
//!      child process group (it's in its own group, so it never got the
//!      terminal's signal), reverts the in-flight file, and re-raises — so
//!      Ctrl-C never leaves a mutated file or a spinning test child behind.
//!      SIGKILL can't be caught; that is exactly what the journal is for.
//!   3. **Startup recovery.** `recover` runs at every `mutate` start: a stale
//!      journal a dead run left behind is reverted (verified against the
//!      recorded hash) before any new work begins.
//!
//! A signal handler takes no context, so the in-flight file and child group
//! live in module-level state; guardian.toml grants this file a `ban-globals`
//! allow, exactly as it does for the reporter singleton.

const std = @import("std");
const fs = @import("../fs.zig");
const reporter = @import("../reporter.zig");

const Allocator = std.mem.Allocator;

/// Cache-relative path of the in-flight journal a crash/kill leaves behind.
/// Public so `doctor` can name the file to delete without respelling it.
pub const leaf = ".guardian/cache/mutant-in-flight.json";
/// Read cap for a source file during recovery (mirrors the runner's cap).
const max_src_bytes: usize = 10 * 1024 * 1024;
/// Seed for the whole-file drift hash — any fixed value; this is drift
/// detection, not security.
const hash_seed: u64 = 0;

// ── Process-global in-flight state (signal-handler reachable) ───────────────
// A signal handler takes no argument, so the file it must revert lives here.
// The non-atomic fields are published/observed through `g_active`'s
// release/acquire ordering (writers set the fields, then store true; the
// handler loads true, then reads the fields).

var g_active = std.atomic.Value(bool).init(false);
var g_child_pgid = std.atomic.Value(i32).init(0);
var g_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var g_path_len: usize = 0;
var g_orig_ptr: ?[*]const u8 = null;
var g_orig_len: usize = 0;

/// One in-flight mutant handed to `begin`: the file (relative + absolute), the
/// full original and mutated bytes, and the mutant byte range.
pub const Entry = struct {
    rel_path: []const u8,
    abs_path: []const u8,
    original: []const u8,
    mutated: []const u8,
    start: usize,
    end: usize,
};

/// Wire form of the journal record (private DTO; field order = JSON key order).
const Record = struct {
    rel_path: []const u8,
    start: usize,
    end: usize,
    original: []const u8,
    mutated_hash: []const u8,
};

/// Drops an error the caller genuinely cannot act on (a signal handler killing a
/// maybe-dead child, re-raising a signal). Keeps every catch non-empty so the
/// swallow reads as deliberate rather than accidental.
fn ignoreErr(_: anyerror) void {}

/// Marks `entry`'s file in-flight and writes the crash-recovery journal, both
/// *before* the mutant is spliced onto disk. Best-effort on the file write (a
/// failed journal only forfeits SIGKILL recovery, logged); the in-flight marker
/// the signal handler reverts from is always set.
pub fn begin(arena: Allocator, project_dir: []const u8, entry: Entry) void {
    markInFlight(entry.abs_path, entry.original);
    writeJournal(arena, project_dir, entry) catch |e|
        std.log.warn("guardian mutate journal write failed: {s}", .{@errorName(e)});
}

/// Clears the in-flight marker and removes the journal after a normal in-place
/// restore. Best-effort on the file remove.
pub fn finish(arena: Allocator, project_dir: []const u8) void {
    clearInFlight();
    removeJournal(arena, project_dir);
}

/// Records the process-group id of the currently-running child (0 when none),
/// so a SIGINT/SIGTERM handler can kill a spinning test child on the way out.
pub fn trackChild(pgid: i32) void {
    g_child_pgid.store(pgid, .release);
}

/// Installs SIGINT/SIGTERM handlers that kill a running child group and revert
/// the in-flight mutant before the process dies. Call once at `mutate` start.
pub fn install() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

/// Startup recovery: if a dead run left a journal, revert the original bytes
/// when the on-disk file still hashes to what that run wrote; if the file has
/// changed since, refuse and warn loudly rather than clobber it. Runs at every
/// `mutate` start — a missing journal is the normal case (no-op).
pub fn recover(arena: Allocator, project_dir: []const u8) void {
    recoverInner(arena, project_dir) catch |e|
        std.log.warn("guardian mutate recovery failed: {s}", .{@errorName(e)});
}

/// A journal found on disk: the file it names, and whether this checkout
/// actually contains that file. `false` is the "left by an interrupted run in
/// another checkout" case — nothing here is at risk, and the journal is inert
/// until the next `mutate` drops it.
pub const Leftover = struct {
    rel_path: []const u8,
    file_present: bool,
};

/// Reports a journal a previous run left behind, or null when there is none
/// (the normal case) or it cannot be parsed. Read-only: unlike `recover` it
/// never reverts anything and never deletes the journal, so `doctor` can
/// describe the state without changing it.
pub fn leftover(arena: Allocator, project_dir: []const u8) Allocator.Error!?Leftover {
    const jpath = try journalPath(arena, project_dir);
    const content = fs.cwd().readFileAlloc(arena, jpath, max_src_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const rec = std.json.parseFromSliceLeaky(Record, arena, content, .{
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const abs = try std.fs.path.join(arena, &.{ project_dir, rec.rel_path });
    return .{ .rel_path = rec.rel_path, .file_present = fileExists(abs) };
}

/// Whether `abs` names an existing file. Split out so `leftover` reads as one
/// statement per fact it gathers.
fn fileExists(abs: []const u8) bool {
    fs.cwd().access(abs, .{}) catch return false;
    return true;
}

// ── Signal-handler side (async-signal-safe: no alloc, no locks) ─────────────

/// SIGINT/SIGTERM handler: kill any running child group (it's in its own group,
/// so it didn't receive the terminal signal), revert the in-flight mutant, then
/// restore the default disposition and re-raise so the exit status is right.
fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    const pg = g_child_pgid.load(.acquire);
    if (pg > 0) std.posix.kill(-pg, std.posix.SIG.KILL) catch |e| ignoreErr(e);
    if (g_active.load(.acquire)) revertInFlightRaw();
    var dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &dfl, null);
    std.posix.raise(sig) catch |e| ignoreErr(e);
}

/// Async-signal-safe best-effort revert of the in-flight file: truncate it and
/// write the original bytes back with raw syscalls (no allocation, no locks).
fn revertInFlightRaw() void {
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .TRUNC = true };
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, g_path_buf[0..g_path_len :0].ptr, flags, 0) catch return;
    defer _ = std.posix.system.close(fd);
    const p = g_orig_ptr orelse return;
    var off: usize = 0;
    while (off < g_orig_len) {
        const rc = std.posix.system.write(fd, p + off, g_orig_len - off);
        const n: usize = switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            else => return,
        };
        if (n == 0) return;
        off += n;
    }
}

/// Publishes the current mutant's file + original bytes for the signal handler.
/// Infallible (pure state writes); a path longer than the buffer disables only
/// the signal-path revert (the journal still covers startup recovery).
fn markInFlight(abs: []const u8, original: []const u8) void {
    if (abs.len >= g_path_buf.len) {
        g_active.store(false, .release);
        return;
    }
    @memcpy(g_path_buf[0..abs.len], abs);
    g_path_buf[abs.len] = 0;
    g_path_len = abs.len;
    g_orig_ptr = original.ptr;
    g_orig_len = original.len;
    g_active.store(true, .release);
}

/// Clears the in-flight marker so the signal handler stops reverting.
fn clearInFlight() void {
    g_active.store(false, .release);
}

// ── Journal file I/O ────────────────────────────────────────────────────────

fn recoverInner(arena: Allocator, project_dir: []const u8) !void {
    const jpath = try journalPath(arena, project_dir);
    const content = fs.cwd().readFileAlloc(arena, jpath, max_src_bytes) catch return; // no journal
    const rec = std.json.parseFromSliceLeaky(Record, arena, content, .{
        .ignore_unknown_fields = true,
    }) catch {
        removeJournal(arena, project_dir);
        return;
    };
    try restoreFromJournal(arena, project_dir, rec);
}

/// Given a parsed journal, revert the file when it still matches the mutated
/// bytes; drop the journal silently when it is already original; refuse and
/// warn loudly when it has drifted to some third state.
///
/// The wording matters. A journal naming a file this checkout never contained
/// is inert — an interrupted run in *another* checkout wrote it, nothing here
/// is at risk — so it reports as a calm note and not as an alarm about a file
/// the reader cannot even find. Only the drift case, where real bytes on disk
/// may be part guardian's and part yours, asks the reader to look.
fn restoreFromJournal(arena: Allocator, project_dir: []const u8, rec: Record) !void {
    const abs = try std.fs.path.join(arena, &.{ project_dir, rec.rel_path });
    const on_disk = fs.cwd().readFileAlloc(arena, abs, max_src_bytes) catch {
        reporter.ok(
            "mutate: dropped a stale journal from an interrupted run — it names {s}, " ++
                "which this checkout does not contain, so there is nothing to revert",
            .{rec.rel_path},
        );
        removeJournal(arena, project_dir);
        return;
    };
    const disk_hash = try hashHex(arena, on_disk);
    if (std.mem.eql(u8, disk_hash, rec.mutated_hash)) {
        try fs.cwd().writeFile(.{ .sub_path = abs, .data = rec.original });
        reporter.ok("mutate: recovered {s} — reverted a mutant an interrupted run left applied", .{rec.rel_path});
        removeJournal(arena, project_dir);
        return;
    }
    if (std.mem.eql(u8, disk_hash, try hashHex(arena, rec.original))) {
        removeJournal(arena, project_dir); // already back to original — just drop the journal
        return;
    }
    reporter.fail(
        "mutate: leaving {s} as it is — it changed after an interrupted run mutated it, so " ++
            "guardian cannot tell its bytes from yours; compare with `git diff -- {s}`",
        .{ rec.rel_path, rec.rel_path },
    );
    removeJournal(arena, project_dir);
}

fn writeJournal(arena: Allocator, project_dir: []const u8, entry: Entry) !void {
    const rec: Record = .{
        .rel_path = entry.rel_path,
        .start = entry.start,
        .end = entry.end,
        .original = entry.original,
        .mutated_hash = try hashHex(arena, entry.mutated),
    };
    const line = try std.json.Stringify.valueAlloc(arena, rec, .{});
    const p = try journalPath(arena, project_dir);
    if (std.fs.path.dirname(p)) |dir| try fs.cwd().makePath(dir);
    try fs.cwd().writeFile(.{ .sub_path = p, .data = line });
}

fn removeJournal(arena: Allocator, project_dir: []const u8) void {
    const p = journalPath(arena, project_dir) catch return;
    fs.cwd().deleteFile(p) catch |e| ignoreErr(e);
}

/// The journal file path: `<project_dir>/.guardian/cache/mutant-in-flight.json`.
fn journalPath(arena: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, leaf });
}

/// Lowercase hex of the whole-file drift hash.
fn hashHex(arena: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{x}", .{std.hash.Wyhash.hash(hash_seed, bytes)});
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Whether the journal file currently exists under `project_dir`.
fn journalPresent(arena: Allocator, project_dir: []const u8) bool {
    const p = journalPath(arena, project_dir) catch return false;
    fs.cwd().access(p, .{}) catch return false;
    return true;
}

// spec: Mutation Testing - Recovers an interrupted run by reverting the journaled in-flight mutant

test "recover reverts a journaled mutant and refuses when the file changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/journal-recover-proj";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("journal test cleanup: {s}", .{@errorName(e)});
    try fs.cwd().makePath(dir ++ "/src");
    // Capture the recovery messages: this test deliberately drives the drift
    // path, and an uncaptured warning about a fixture file no checkout contains
    // is what made every `zig build test` look like it had found real trouble.
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default;
    defer reporter.default = prior;
    reporter.default = .{ .capture = &cap };

    const rel = "src/z.zig";
    const abs = try std.fs.path.join(a, &.{ dir, rel });
    const original = "return a < b;\n";
    const mutated = "return a <= b;\n";
    const entry: Entry = .{
        .rel_path = rel,
        .abs_path = abs,
        .original = original,
        .mutated = mutated,
        .start = 9,
        .end = 10,
    };

    // (1) Dead run: the mutated bytes sit on disk with a journal and no finish()
    //     — recover restores the original byte-for-byte and consumes the journal.
    try fs.cwd().writeFile(.{ .sub_path = abs, .data = mutated });
    begin(a, dir, entry);
    try testing.expect(journalPresent(a, dir));
    recover(a, dir);
    try testing.expectEqualStrings(original, try fs.cwd().readFileAlloc(a, abs, max_src_bytes));
    try testing.expect(!journalPresent(a, dir));

    // (2) Drift: the journal says mutated, but the file was edited since — recover
    //     refuses to touch it (safer to warn than clobber an unknown edit).
    try fs.cwd().writeFile(.{ .sub_path = abs, .data = mutated });
    begin(a, dir, entry);
    const edited = "return foo(a, b);\n";
    try fs.cwd().writeFile(.{ .sub_path = abs, .data = edited });
    recover(a, dir);
    try testing.expectEqualStrings(edited, try fs.cwd().readFileAlloc(a, abs, max_src_bytes));
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "leaving src/z.zig as it is") != null);

    // (3) Normal completion: finish() clears an active journal.
    begin(a, dir, entry);
    try testing.expect(journalPresent(a, dir));
    finish(a, dir);
    try testing.expect(!journalPresent(a, dir));
}

// spec: Mutation Testing - Reports a journal naming an absent file as an inert leftover

test "leftover names the journaled file and whether this checkout has it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/journal-leftover-proj";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("journal test cleanup: {s}", .{@errorName(e)});
    try fs.cwd().makePath(dir ++ "/src");
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default;
    defer reporter.default = prior;
    reporter.default = .{ .capture = &cap };

    // No journal is the normal state, and reads as nothing to report.
    try testing.expect(try leftover(a, dir) == null);

    const rel = "src/z.zig";
    const abs = try std.fs.path.join(a, &.{ dir, rel });
    const entry: Entry = .{
        .rel_path = rel,
        .abs_path = abs,
        .original = "return a < b;\n",
        .mutated = "return a <= b;\n",
        .start = 9,
        .end = 10,
    };
    try fs.cwd().writeFile(.{ .sub_path = abs, .data = entry.mutated });
    begin(a, dir, entry);
    const present = (try leftover(a, dir)).?;
    try testing.expectEqualStrings(rel, present.rel_path);
    try testing.expect(present.file_present);

    // The other checkout's journal: the named file is not here, so nothing is
    // at risk — and reading it leaves the journal exactly where it was.
    try fs.cwd().deleteFile(abs);
    const absent = (try leftover(a, dir)).?;
    try testing.expect(!absent.file_present);
    try testing.expect(journalPresent(a, dir));
    // Recovery says so calmly rather than warning about a file nobody can find.
    recover(a, dir);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "dropped a stale journal") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "NOT reverting") == null);
}
