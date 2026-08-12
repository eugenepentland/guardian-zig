//! fatal-exit — hard-block on a hand-rolled `std.process.exit(<nonzero>)`.
//!
//! Zig core routes every unrecoverable termination through one helper
//! (`std.process.fatal`, 281 call sites in the compiler) so the exit path is
//! consistent and greppable. Guardian carries its own `reporter.fatal` for the
//! same reason (it keeps the "guardian: " prefix and coloring that
//! `std.process.fatal` drops). A raw `std.process.exit(1)` sprinkled through the
//! codebase is exactly the fragmentation that helper exists to prevent — and an
//! agent reaches for the bare exit by reflex.
//!
//! This check flags any `process.exit(...)` whose argument is not the literal
//! `0`, except in two places where a raw exit is legitimate:
//!   * the process entry file — detected portably by the presence of a
//!     `fn main` (so a downstream `src/main.zig` is exempt without config), and
//!   * the fatal helper's own file — designated per-project via a
//!     `[[allow]] check = "fatal-exit"` path glob (Guardian points it at
//!     `src/reporter.zig`).
//! `std.process.exit(0)` and `std.process.cleanExit(...)` are always fine — a
//! clean success exit is not the fragmentation this targets.
//!
//! Detection is lexical (a `process . exit (` token chain), so a banned spelling
//! inside a string literal or comment is never flagged. Limitation: an aliased
//! `const exit = std.process.exit;` call is not caught (the chain no longer
//! reads `process.exit`), and the main-entry exemption is file-wide rather than
//! scoped to `main`'s body.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;
const lineOf = @import("../text.zig").lineOf;

/// Progress through the `process . exit` token chain.
const Chain = enum { none, process, process_dot, exit_ready };

/// Pure-function entry: returns the violation lines (allocator-owned) for every
/// nonzero `std.process.exit(...)` in `content`. A file that defines `fn main`
/// is the process entry point, so its exits are legitimate and it returns empty.
/// Empty slice = pass. Used by the unit tests; production goes through `run`.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(allocator);

    const has_main = try scan(allocator, content, &lines);
    if (has_main) return violations.toOwnedSlice(allocator);

    for (lines.items) |ln| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}:{d}: std.process.exit with a nonzero code — route through reporter.fatal / the fatal helper",
            .{ rel_path, ln },
        );
        try violations.append(allocator, msg);
    }
    return violations.toOwnedSlice(allocator);
}

/// Scans `content`, appending the 1-indexed line of every nonzero
/// `process.exit(...)` to `lines`. Returns whether the file defines a `fn main`
/// (the process entry point, where a raw exit is legitimate). Propagates OOM
/// from the tokenizer copy / the append rather than dropping a finding.
fn scan(allocator: Allocator, content: []const u8, lines: *std.ArrayList(u32)) Allocator.Error!bool {
    const z = try allocator.dupeSentinel(u8, content, 0);
    var tok = std.zig.Tokenizer.init(z);
    var chain: Chain = .none;
    var has_main = false;
    var prev_was_fn = false;
    var pending_exit = false;
    var exit_line: u32 = 0;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;

        // `fn main` marks the entry file — the one place a raw exit belongs.
        if (prev_was_fn and t.tag == .identifier and std.mem.eql(u8, z[t.loc.start..t.loc.end], "main"))
            has_main = true;

        // The token right after `process.exit(` decides the verdict: `0` is a
        // clean exit; anything else (nonzero literal, identifier, expression) is
        // the hand-rolled fatal path this check redirects to the helper.
        if (pending_exit) {
            if (!isZeroLiteral(z, t)) try lines.append(allocator, exit_line);
            pending_exit = false;
        }

        switch (t.tag) {
            .identifier => chain = advanceIdent(chain, z[t.loc.start..t.loc.end]),
            .period => chain = if (chain == .process) .process_dot else .none,
            .l_paren => {
                if (chain == .exit_ready) {
                    pending_exit = true;
                    exit_line = lineOf(z, t.loc.start);
                }
                chain = .none;
            },
            else => chain = .none,
        }
        prev_was_fn = t.tag == .keyword_fn;
    }
    return has_main;
}

/// Advances the `process . exit` chain on an identifier `text`.
fn advanceIdent(chain: Chain, text: []const u8) Chain {
    if (chain == .process_dot and std.mem.eql(u8, text, "exit")) return .exit_ready;
    if (std.mem.eql(u8, text, "process")) return .process;
    return .none;
}

/// True when `t` is the integer literal `0` (a clean, allowed exit code).
fn isZeroLiteral(z: []const u8, t: std.zig.Token) bool {
    return t.tag == .number_literal and std.mem.eql(u8, z[t.loc.start..t.loc.end], "0");
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
    extra_allowed: []const []const u8 = &.{},
};

/// True if `rel_path` matches a configured [[allow]] path (the designated
/// fatal-helper file, e.g. Guardian's src/reporter.zig).
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.extra_allowed)) return;
    const found = try analyzeContent(ctx.allocator, entry.rel_path, entry.content);
    for (found) |msg| try ctx.violations.append(ctx.allocator, msg);
}

/// Entry point for the fatal-exit check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .extra_allowed = ctx.cfg.extraAllowed("fatal-exit"),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("fatal-exit: no hand-rolled std.process.exit outside the entry/fatal path", .{});
        return;
    }
    reporter.fail("fatal-exit FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: use reporter.fatal(...) instead of std.process.exit(nonzero); " ++
        "the entry file (pub fn main) and [[allow]] fatal-helper paths are exempt.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Fatal Exit - Flags a nonzero std.process.exit outside the entry file

test "analyzeContent flags std.process.exit(1) in a non-main file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn boom() void {
        \\    std.process.exit(1);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Fatal Exit - Allows std.process.exit(0)

test "analyzeContent allows std.process.exit(0)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn done() void {
        \\    std.process.exit(0);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Fatal Exit - Exempts a file that defines pub fn main

test "analyzeContent exempts a file that defines pub fn main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/main.zig",
        \\pub fn main() void {
        \\    std.process.exit(1);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags a nonzero exit through a variable code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn boom(code: u8) void {
        \\    std.process.exit(code);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent ignores process.exit inside a string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const s = "std.process.exit(1)";
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "isAllowed matches a configured fatal-helper path" {
    try std.testing.expect(isAllowed("src/reporter.zig", &.{"src/reporter.zig"}));
    try std.testing.expect(!isAllowed("src/other.zig", &.{"src/reporter.zig"}));
}
