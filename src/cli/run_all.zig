const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");

const print = std.debug.print;
const fail = reporter.fail;

pub const COMMAND_NAME = "all";
const SKIP = [_][]const u8{"spec-init"};

/// Runs every registered hard-block check sequentially in this process.
/// Continues past failures so the user sees every failing check at once;
/// returns error.CheckFailed if any check failed.
///
/// Skips `spec-init` (a generator, not a gate). The `all` command itself
/// is dispatched outside the registry, so it never recurses.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    var failed: u32 = 0;
    var ran: u32 = 0;
    for (registry.all) |cmd| {
        if (shouldSkip(cmd.name)) continue;
        ran += 1;
        cmd.run(ctx) catch |e| switch (e) {
            error.CheckFailed => {
                failed += 1;
            },
            else => return e,
        };
    }

    if (failed == 0) {
        reporter.ok("run-all: {d} check(s) passed", .{ran});
        return;
    }

    fail("run-all: {d}/{d} check(s) failed", .{ failed, ran });
    return error.CheckFailed;
}

fn shouldSkip(name: []const u8) bool {
    for (SKIP) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}
