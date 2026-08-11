//! `merge-state` — refuse to gate a tree whose `.guardian/` metadata is still
//! mid-merge: conflict markers git left behind, a counter merge the driver had
//! to guess (marked for regeneration), or a row that does not parse in its own
//! format. Each of those reads as ordinary debt to every other check, so
//! without this the tree gates green on numbers nobody measured.

const std = @import("std");
const reporter = @import("../reporter.zig");
const types = @import("../cli/types.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const scan = @import("../merge/scan.zig");

/// CLI name of this check.
pub const check_name = "merge-state";

/// Entry point: scan `.guardian/` and fail on anything a merge left unfinished.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const found = try scan.findings(ctx.allocator, ctx.project_dir);
    if (found.len == 0) {
        reporter.ok("merge-state: .guardian metadata is fully resolved", .{});
        return;
    }
    reporter.fail("merge-state FAILED ({d} unresolved metadata finding(s))", .{found.len});
    for (found) |f| {
        reporter.emit(.{
            .check = check_name,
            .file = f.path,
            .line = @intCast(f.line),
            .message = scan.describe(f.trouble),
            .identity = f.path,
        });
        reporter.detail("    {s}\n", .{f.text});
    }
    printFix(ctx, found);
    return error.CheckFailed;
}

/// Prints the regeneration command for each distinct check the findings name —
/// the resolution that always works, whatever the conflict looked like. A file
/// that is not a check's snapshot at all (the mutation cohort, the benchmark
/// ledger) has no refresh env var, so it is named as the hand job it is.
fn printFix(ctx: *types.RunCtx, found: []const scan.Finding) void {
    reporter.detail("  fix: regenerate the file on the merged tree, then commit .guardian/:\n", .{});
    for (found, 0..) |f, i| {
        if (alreadyNamed(found[0..i], f.check)) continue;
        if (isCheckOwned(ctx, f.check)) {
            reporter.detail("    {s}={s} zig build\n", .{ snapshot_helper.update_env, f.check });
            continue;
        }
        reporter.detail("    {s}: not a check snapshot — re-record it with the command that owns it\n", .{f.path});
    }
}

/// True when `check` is a registered check, i.e. its metadata is derived state a
/// selective refresh can rebuild. The registry is reached through the context's
/// membership callback, which exists so a check never imports the registry.
fn isCheckOwned(ctx: *types.RunCtx, check: []const u8) bool {
    const exists = ctx.command_exists orelse return true;
    return exists(check);
}

/// True when an earlier finding already named `check` (so its command prints
/// once, not once per row).
fn alreadyNamed(earlier: []const scan.Finding, check: []const u8) bool {
    for (earlier) |e| {
        if (std.mem.eql(u8, e.check, check)) return true;
    }
    return false;
}

/// Prints the same located report outside a check run — used by the CLI when a
/// snapshot read aborts on conflict markers, so the operator sees WHICH file and
/// line rather than a bare error name.
pub fn reportUnresolved(ctx: *types.RunCtx) void {
    const found = scan.findings(ctx.allocator, ctx.project_dir) catch return;
    if (found.len == 0) return;
    reporter.fail("a .guardian metadata file is still mid-merge:", .{});
    for (found) |f| reporter.detail("  {s}:{d}: {s}\n", .{ f.path, f.line, scan.describe(f.trouble) });
    printFix(ctx, found);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Merge - Fails the gate while metadata carries a merge marker

test "run passes on this repository's resolved metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const config = @import("../config.zig");
    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{
        .allocator = arena.allocator(),
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    // Guardian's own `.guardian/` is committed resolved, so the gate is green.
    try run(&ctx);
}

// spec: Merge - Names each affected check's regeneration command once

test "printFix names every distinct check exactly once" {
    var cap: reporter.Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const found = [_]scan.Finding{
        .{ .path = ".guardian/a.txt", .line = 2, .trouble = .unresolved, .text = "<<<<<<<", .check = "spec" },
        .{ .path = ".guardian/a.txt", .line = 9, .trouble = .unresolved, .text = "<<<<<<<", .check = "spec" },
        .{ .path = ".guardian/pub-api.txt", .line = 1, .trouble = .pending_regen, .text = "#", .check = "pub-api-surface" },
    };
    const config = @import("../config.zig");
    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = testing.allocator, .project_dir = ".", .cfg = &cfg, .quiet = true };
    printFix(&ctx, &found);
    const out = cap.buf.items;
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "GUARDIAN_UPDATE_SNAPSHOT=spec "));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "GUARDIAN_UPDATE_SNAPSHOT=pub-api-surface"));
    // Both duplicate rows collapse to the one command that fixes them.
    try testing.expect(alreadyNamed(found[0..1], "spec"));

    // A file that is nobody's snapshot (the mutation cohort) has no refresh env
    // var, so it must not be told to run one that would hard-fail on the name.
    ctx.command_exists = &noCheckExists;
    cap.buf.clearRetainingCapacity();
    printFix(&ctx, found[2..]);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "GUARDIAN_UPDATE_SNAPSHOT=") == null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "not a check snapshot") != null);
}

/// Registry stand-in for a metadata file no check owns.
fn noCheckExists(_: []const u8) bool {
    return false;
}
