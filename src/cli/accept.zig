//! Explicit, named baseline/snapshot acceptance workflow. It previews the
//! selected failures, refreshes only those checks, then reruns them without a
//! refresh so the command cannot report success on unverifiable metadata.

const std = @import("std");
const types = @import("types.zig");
const run_all = @import("run_all.zig");
const reporter = @import("../reporter.zig");

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
    reporter.ok("accept: verified {d} named check(s); review and commit the .guardian/ diff", .{ctx.refresh.len});
}

// spec: Maintenance - Accept refreshes only named checks and verifies them after updating metadata

test "accept command name remains stable for build-helper integration" {
    try std.testing.expectEqualStrings("accept", command_name);
}
