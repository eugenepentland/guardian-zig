//! stdout-flush — report-only heuristic for a buffered stdout/stderr writer
//! that is never flushed.
//!
//! 0.15's "Writergate" made the buffered-writer + explicit `flush()` pattern the
//! norm (`std.fs.File.stdout().writer(&buf)` then `w.interface.flush()`). In
//! 0.15 a *missing* flush silently TRUNCATES output — the buffered bytes are
//! dropped when the writer goes out of scope — so a forgotten flush is a
//! correctness bug, not a style nit.
//!
//! The heuristic is intra-procedural: within one function (delimited by `fn`
//! boundaries) it flags a body that calls `stdout()`/`stderr()` AND builds a
//! writer (`.writer(...)` / `.writerStreaming(...)`) but contains no `flush(`
//! call. It is deliberately coarse and has known blind spots:
//!   * a flush performed by a called helper is invisible (false positive), and
//!   * it does not prove the flush is on the *same* writer or reachable on every
//!     path (a flush in an untaken branch still counts — false negative).
//! Because that precision is unproven, this check is REPORT-ONLY BY DEFAULT: it
//! surfaces findings but never returns `error.CheckFailed`, so it can't red a
//! build. A project that trusts the signal promotes it to a gating hard-block
//! with `[stdout_flush] enabled = true`; the default (absent or `false`) keeps
//! today's report-only behavior exactly.
//!
//! Detection is lexical (call-target identifiers), so a name inside a string or
//! comment never fires. Guardian's own human output is unbuffered
//! `std.debug.print` to stderr and its one buffered *file* writer (snapshot.zig)
//! flushes, so this reports zero on Guardian itself.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const measurement = @import("../measurement.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;
const lineOf = @import("../text.zig").lineOf;

/// Registry name, shared by the [[allow]] lookup and the measurement bridge.
const check_name = "stdout-flush";

/// Accumulated signals for one function region (between two `fn` boundaries).
const Region = struct {
    saw_source: bool = false,
    saw_writer: bool = false,
    saw_flush: bool = false,
    /// 1-indexed line of the first `stdout()`/`stderr()` call (0 = unset).
    source_line: u32 = 0,
};

/// Pure-function entry: returns one finding line (allocator-owned) per function
/// that buffers stdout/stderr with no reachable flush. Empty slice = clean.
/// Used by the unit tests; production goes through `run`.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var findings: std.ArrayList([]const u8) = .empty;
    try scan(allocator, rel_path, content, &findings);
    return findings.toOwnedSlice(allocator);
}

/// Splits `content` into function regions at `fn` boundaries and appends a
/// finding for every region that buffers stdout/stderr without a flush.
/// Propagates OOM rather than dropping a finding.
fn scan(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    findings: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const z = try allocator.dupeSentinel(u8, content, 0);
    var tok = std.zig.Tokenizer.init(z);
    var region: Region = .{};
    var prev_ident: []const u8 = "";

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            // A new `fn` closes the region that just ended (its body is fully
            // behind us) and starts a fresh one.
            .keyword_fn => {
                try finalize(allocator, rel_path, region, findings);
                region = .{};
                prev_ident = "";
            },
            .identifier => prev_ident = z[t.loc.start..t.loc.end],
            // A `(` after an interesting identifier is a call to it. The byte
            // offset is passed raw — `classifyCall` resolves it to a line only
            // for the first source hit per region, so the O(offset) `lineOf`
            // scan runs at most once per function instead of per `(`.
            .l_paren => {
                classifyCall(&region, prev_ident, z, t.loc.start);
                prev_ident = "";
            },
            else => prev_ident = "",
        }
    }
    try finalize(allocator, rel_path, region, findings);
}

/// Records a call to `ident` into the region's signal set. `offset` is the byte
/// position of the call's `(`; it is resolved to a line only for the first
/// source hit per region (`source_line == 0`), keeping the O(offset) `lineOf`
/// scan off the hot path of every other `(`.
fn classifyCall(region: *Region, ident: []const u8, source: []const u8, offset: usize) void {
    if (isSource(ident)) {
        region.saw_source = true;
        if (region.source_line == 0) region.source_line = lineOf(source, offset);
    } else if (isWriter(ident)) {
        region.saw_writer = true;
    } else if (std.mem.eql(u8, ident, "flush")) {
        region.saw_flush = true;
    }
}

/// True for a `File.stdout()` / `File.stderr()` call target.
fn isSource(ident: []const u8) bool {
    return std.mem.eql(u8, ident, "stdout") or std.mem.eql(u8, ident, "stderr");
}

/// True for a `.writer(...)` / `.writerStreaming(...)` buffered-writer builder.
fn isWriter(ident: []const u8) bool {
    return std.mem.eql(u8, ident, "writer") or std.mem.eql(u8, ident, "writerStreaming");
}

/// Appends a finding when the region buffered a std stream without flushing.
fn finalize(
    allocator: Allocator,
    rel_path: []const u8,
    region: Region,
    findings: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const unflushed = region.saw_source and region.saw_writer and !region.saw_flush;
    if (!unflushed) return;
    const msg = try std.fmt.allocPrint(
        allocator,
        "{s}:{d}: buffers stdout/stderr with no reachable flush() before returning",
        .{ rel_path, region.source_line },
    );
    try findings.append(allocator, msg);
}

const FileScanCtx = struct {
    allocator: Allocator,
    findings: *std.ArrayList([]const u8),
    extra_allowed: []const []const u8 = &.{},
    /// Live only when a `[measurement]` path bridges this check on a local run
    /// (see measurement.zig): a hand-rolled counter dump inside one is deferred
    /// to the non-blocking MEASURE channel instead of counted here.
    exempt: *measurement.Exemption,
};

/// True if `rel_path` matches a configured [[allow]] path for this check.
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.extra_allowed)) return;
    const found = try analyzeContent(ctx.allocator, entry.rel_path, entry.content);
    if (ctx.exempt.covers(entry.rel_path)) {
        for (found) |msg| try ctx.exempt.record(entry.rel_path, msg);
        return;
    }
    for (found) |msg| try ctx.findings.append(ctx.allocator, msg);
}

/// Whether the run must hard-fail: only when a finding exists AND the
/// `[stdout_flush] enabled` gate is on. Off (the default) keeps the check
/// report-only, so findings surface without ever failing the build.
fn shouldGate(finding_count: usize, enabled: bool) bool {
    return enabled and finding_count > 0;
}

/// Entry point for the stdout-flush check. Report-only by default: it surfaces
/// findings but returns success. When `[stdout_flush] enabled = true`, a finding
/// instead fails the build with `error.CheckFailed`.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var findings: std.ArrayList([]const u8) = .empty;
    var exempt = measurement.forCheck(allocator, ctx, check_name);
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .findings = &findings,
        .extra_allowed = ctx.cfg.extraAllowed(check_name),
        .exempt = &exempt,
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });
    try exempt.report();

    if (findings.items.len == 0) {
        reporter.ok("stdout-flush: no buffered stdout/stderr writer missing a flush", .{});
        return;
    }

    const gating = shouldGate(findings.items.len, ctx.cfg.stdout_flush.enabled);
    if (gating) {
        reporter.fail(
            "stdout-flush FAILED ({d} function(s) buffer stdout/stderr with no reachable flush)",
            .{findings.items.len},
        );
    } else {
        reporter.ok(
            "stdout-flush: {d} function(s) buffer stdout/stderr with no reachable flush (report-only, not gating)",
            .{findings.items.len},
        );
    }
    for (findings.items) |f| detail("  {s}\n", .{f});
    detail("  note: a missing flush() truncates output in 0.15 — add " ++
        "w.interface.flush() before returning.\n", .{});
    if (gating) return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Stdout Flush - Flags a buffered stdout writer with no flush

test "analyzeContent flags a buffered stdout writer that never flushes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn emit() void {
        \\    var buf: [256]u8 = undefined;
        \\    var w = std.fs.File.stdout().writer(&buf);
        \\    w.interface.print("hi", .{}) catch {};
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent reports the line of the first source call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // stdout()'s `(` sits on line 3; the lazily-resolved source line must still
    // pin the finding to that line (the perf fix defers lineOf but must not
    // move the reported line).
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn emit() void {
        \\    var buf: [256]u8 = undefined;
        \\    var w = std.fs.File.stdout().writer(&buf);
        \\    w.interface.print("hi", .{}) catch {};
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.startsWith(u8, out[0], "src/x.zig:3:"));
}

// spec: Stdout Flush - Allows a buffered stdout writer that flushes before returning

test "analyzeContent allows a buffered stdout writer that flushes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn emit() void {
        \\    var buf: [256]u8 = undefined;
        \\    var w = std.fs.File.stdout().writer(&buf);
        \\    w.interface.print("hi", .{}) catch {};
        \\    w.interface.flush() catch {};
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Stdout Flush - Ignores a stdout write that never buffers

test "analyzeContent ignores an unbuffered stdout write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn emit() void {
        \\    std.fs.File.stdout().writeAll("hi") catch {};
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags a buffered stderr writerStreaming with no flush" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn emit() void {
        \\    var buf: [256]u8 = undefined;
        \\    var w = std.fs.File.stderr().writerStreaming(&buf);
        \\    w.interface.print("hi", .{}) catch {};
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent ignores a non-std writer with no flush" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn emit(list: *std.ArrayList(u8), a: std.mem.Allocator) void {
        \\    list.writer(a).print("hi", .{}) catch {};
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent attributes flush to the right function region" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The first fn buffers-without-flush; the flush belongs to a later fn.
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn bad() void {
        \\    var buf: [256]u8 = undefined;
        \\    var w = std.fs.File.stdout().writer(&buf);
        \\    _ = &w;
        \\}
        \\fn other(w: anytype) void {
        \\    w.flush() catch {};
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Stdout Flush - Hard-blocks a missing flush when the enabled toggle is on

test "a finding gates the build when the enabled toggle is on" {
    try std.testing.expect(shouldGate(1, true));
}

// spec: Stdout Flush - Stays report-only for a missing flush when the toggle is off

test "a finding stays report-only when the enabled toggle is off" {
    try std.testing.expect(!shouldGate(1, false));
    // A clean tree never gates, on or off.
    try std.testing.expect(!shouldGate(0, true));
}
