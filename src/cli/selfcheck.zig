//! `selfcheck` — the fail-closed staleness guard behind the prebuilt binary.
//!
//! A consumer build that reuses `<guardian>/zig-out/bin/guardian-check` instead
//! of compiling one skips ~49 s of cold compile per worktree, and buys exactly
//! one new failure mode: the binary could predate the source it is gating. This
//! command closes that hole. It recomputes `source_digest` over the Guardian
//! source root it is handed and compares it against the digest `build.zig`
//! embedded when this binary was built. Equal means the binary IS that source;
//! anything else exits non-zero with both remedies named.
//!
//! Dispatched directly (like `size` and `doctor`), never registered: it is a
//! statement about the *tool*, not about the project, so it must never join the
//! `all` suite or be reachable as a gate on a consumer's code.

const std = @import("std");
const fs = @import("../fs.zig");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const source_digest = @import("../source_digest.zig");
const wiring = @import("../wiring.zig");
const build_options = @import("build_options");

const print = reporter.detail;

pub const command_name = "selfcheck";

/// Digest of the Guardian source this binary was compiled from, embedded by
/// build.zig at configure time (see `src/source_digest.zig`).
pub const embedded_digest: []const u8 = build_options.source_digest;

/// Leading hex characters shown in a report. Enough to tell two digests apart at
/// a glance, short enough to keep the line readable.
const shown_digest_chars = 12;

/// Entry point. Reads only the source root it is given: no config, no project
/// scan, no writes — the whole command is a directory walk and a hash, so it
/// can sit in front of every other guardian invocation without being felt.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    var root = openRoot(ctx.project_dir) catch return reportUnreadable(ctx.project_dir);
    defer root.close();

    const actual = source_digest.compute(wiring.io(), ctx.allocator, root.inner) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceRootUnreadable => return reportUnreadable(ctx.project_dir),
    };
    if (!isCurrent(&actual)) return reportStale(ctx, &actual);

    reporter.ok("selfcheck: prebuilt guardian-check matches {s} (source {s})", .{
        ctx.project_dir,
        shown(embedded_digest),
    });
}

/// Opens the Guardian source root, collapsing every reason it cannot be opened
/// into the one error whose remedy the report knows.
fn openRoot(path: []const u8) error{SourceRootUnreadable}!fs.Dir {
    return fs.cwd().openDir(path, .{}) catch error.SourceRootUnreadable;
}

/// True when this binary was built from exactly the source that produced
/// `actual` — the only condition under which a prebuilt binary may gate a tree.
fn isCurrent(actual: []const u8) bool {
    return std.mem.eql(u8, embedded_digest, actual);
}

/// The first characters of a digest, for a report line.
fn shown(digest: []const u8) []const u8 {
    return digest[0..@min(digest.len, shown_digest_chars)];
}

/// Reports a stale prebuilt binary. Both remedies are named because they answer
/// different situations: rebuilding is what a Guardian developer wants, and the
/// opt-out is what an unrelated consumer — who never asked to be in Guardian's
/// build loop — wants.
fn reportStale(ctx: *types.RunCtx, actual: []const u8) types.RunError!void {
    reporter.fail(
        "selfcheck: prebuilt guardian-check is stale vs its source (binary {s}, source {s})",
        .{ shown(embedded_digest), shown(actual) },
    );
    print("  {s}\n", .{try remedy(ctx.allocator, ctx.project_dir)});
    return error.CheckFailed;
}

/// Reports a source root that could not be read at all — a wrong path, or a
/// dependency directory that is not a Guardian checkout.
fn reportUnreadable(root: []const u8) types.RunError!void {
    reporter.fail("selfcheck: cannot read guardian source root '{s}'", .{root});
    print("  expected a directory holding build.zig, build.zig.zon and src/\n", .{});
    return error.CheckFailed;
}

/// Builds the remediation line. Kept as one rendered string so a test can hold
/// the whole contract — both remedies, and the root to run them in.
fn remedy(arena: std.mem.Allocator, root: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "run `zig build` in {s}, or set GUARDIAN_PREBUILT=off to compile guardian-check from source",
        .{root},
    );
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Prebuilt Binary - Judges the binary current only when the recomputed digest equals the embedded one

test "isCurrent accepts the embedded digest and nothing else" {
    try testing.expect(isCurrent(embedded_digest));
    try testing.expect(!isCurrent("0123456789abcdef"));
    try testing.expect(!isCurrent(""));
    // A prefix must not pass: a truncated digest is not a match.
    try testing.expect(!isCurrent(embedded_digest[0 .. embedded_digest.len - 1]));
}

// spec: Prebuilt Binary - Names both the rebuild and the opt-out when the binary is stale

test "the stale report names the rebuild root and the opt-out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const line = try remedy(arena.allocator(), "../guardian-zig");
    try testing.expect(std.mem.indexOf(u8, line, "zig build") != null);
    try testing.expect(std.mem.indexOf(u8, line, "../guardian-zig") != null);
    try testing.expect(std.mem.indexOf(u8, line, "GUARDIAN_PREBUILT=off") != null);
}

// spec: Prebuilt Binary - Fails when the named Guardian source root cannot be opened

test "openRoot rejects a path that is not a directory on disk" {
    try testing.expectError(error.SourceRootUnreadable, openRoot("guardian-no-such-source-root"));
}

// spec: Prebuilt Binary - Embeds a full-width hex source digest that the version command prints

test "the embedded digest is a full-width lowercase hex string" {
    try testing.expectEqual(@as(usize, source_digest.hex_len), embedded_digest.len);
    for (embedded_digest) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}

// spec: Prebuilt Binary - Abbreviates a digest for the report line

test "shown truncates a full digest and tolerates a short one" {
    try testing.expectEqual(@as(usize, shown_digest_chars), shown(embedded_digest).len);
    try testing.expectEqualStrings("abc", shown("abc"));
}
