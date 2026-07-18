//! Explicit, named baseline/snapshot acceptance workflow. It previews the
//! selected failures, refreshes only those checks, then reruns them without a
//! refresh so the command cannot report success on unverifiable metadata.

const std = @import("std");
const types = @import("types.zig");
const run_all = @import("run_all.zig");
const reporter = @import("../reporter.zig");
const ratchet = @import("../ratchet.zig");
const accept_session = @import("../accept_session.zig");

pub const command_name = "accept";

/// Reviews, accepts, and verifies the checks named in `ctx.refresh`.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    if (ctx.refresh.len == 0) {
        reporter.fail("accept: name at least one check (comma-separated)", .{});
        reporter.detail("  usage: guardian-check accept file-size,line-length .\n", .{});
        return error.CheckFailed;
    }
    try run_all.validateCheckNames(ctx.refresh, "accept");

    var preview = ctx.*;
    preview.only = ctx.refresh;
    preview.refresh = &.{};
    run_all.run(&preview) catch |e| switch (e) {
        error.CheckFailed => reporter.ok("accept: preview complete; applying only the named refreshes", .{}),
        else => return e,
    };

    var update = ctx.*;
    update.only = ctx.refresh;
    try run_all.run(&update);

    var verify = ctx.*;
    verify.only = ctx.refresh;
    verify.refresh = &.{};
    try run_all.run(&verify);
    recordSession(ctx);
    reporter.ok("accept: verified {d} named check(s); review and commit the .guardian/ diff", .{ctx.refresh.len});
}

/// Upper bound on names the session note records per accept — comfortably
/// above the ten ratchet checks that exist, so the bound never truncates a
/// real invocation.
const max_session_names = 16;

/// Records the accepted RATCHET checks as this session's pending accepts, so
/// the same subjects may keep growing until the next commit without another
/// accept round-trip (see accept_session.zig). Non-ratchet names are skipped —
/// only the ratchet lifecycle consults the note. Best-effort by design.
fn recordSession(ctx: *types.RunCtx) void {
    var names: [max_session_names][]const u8 = undefined;
    var n: usize = 0;
    for (ctx.refresh) |name| {
        if (ratchet.metricMode(name) == null) continue;
        if (n == names.len) break;
        names[n] = name;
        n += 1;
    }
    if (n == 0) return;
    accept_session.record(ctx.allocator, ctx.project_dir, names[0..n]);
}

// spec: Maintenance - Accept refreshes only named checks and verifies them after updating metadata

test "accept command name remains stable for build-helper integration" {
    try std.testing.expectEqualStrings("accept", command_name);
}
