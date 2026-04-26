const std = @import("std");
const config_mod = @import("config.zig");
const reporter = @import("reporter.zig");
const registry = @import("cli/registry.zig");
const run_all = @import("cli/run_all.zig");

/// Entry point. Parses argv, dispatches to the registered command.
pub fn main() !void {
    // page_allocator is intentional here; pub fn main is the documented
    // exemption point in the "Allocator Hygiene" spec — every other call
    // site threads the allocator from this arena.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        reporter.init(false);
        registry.printHelp();
        std.process.exit(1);
    }

    var command: ?[]const u8 = null;
    var project_dir: []const u8 = ".";
    var quiet_mode: bool = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet_mode = true;
        } else if (command == null) {
            command = arg;
        } else {
            project_dir = arg;
        }
    }
    reporter.init(quiet_mode);
    if (command == null) {
        registry.printHelp();
        std.process.exit(1);
    }

    const cfg = config_mod.load(allocator, project_dir);
    var ctx: registry.RunCtx = .{
        .allocator = allocator,
        .project_dir = project_dir,
        .cfg = &cfg,
        .quiet = quiet_mode,
    };

    if (std.mem.eql(u8, command.?, run_all.COMMAND_NAME)) {
        run_all.run(&ctx) catch |e| switch (e) {
            error.CheckFailed => std.process.exit(1),
            else => return e,
        };
        return;
    }

    const cmd = registry.find(command.?) orelse {
        registry.printHelp();
        std.process.exit(1);
    };
    cmd.run(&ctx) catch |e| switch (e) {
        // CheckFailed means the check already printed its own diagnostic.
        // Exit non-zero without surfacing a Zig stack trace.
        error.CheckFailed => std.process.exit(1),
        else => return e,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test {
    _ = @import("config.zig");
    _ = @import("spec/parser.zig");
    _ = @import("spec/matcher.zig");
    _ = @import("spec/init.zig");
    _ = @import("walk.zig");
    _ = @import("reporter.zig");
    _ = @import("ast/parser.zig");
    _ = @import("snapshot.zig");
    _ = @import("snapshot_helper.zig");
    _ = @import("cli/types.zig");
    _ = @import("cli/registry.zig");
    _ = @import("cli/run_all.zig");
    _ = @import("testing/golden_runner.zig");
    _ = @import("checks/spec.zig");
    _ = @import("checks/spec_init.zig");
    _ = @import("checks/file_size.zig");
    _ = @import("checks/boundaries.zig");
    _ = @import("checks/usingnamespace_ban.zig");
    _ = @import("checks/spec_quality.zig");
    _ = @import("checks/naming.zig");
    _ = @import("checks/function_size.zig");
    _ = @import("checks/doc_comments.zig");
    _ = @import("checks/imports.zig");
    _ = @import("checks/pub_api_surface.zig");
    _ = @import("checks/panic_budget.zig");
    _ = @import("checks/spec_drift.zig");
    _ = @import("checks/catch_discipline.zig");
    _ = @import("checks/error_discipline.zig");
    _ = @import("checks/cognitive_complexity.zig");
    _ = @import("checks/anytype_budget.zig");
    _ = @import("checks/dead_pub.zig");
    _ = @import("checks/allocator_hygiene.zig");
    _ = @import("checks/dup_const.zig");
    _ = @import("checks/debug_print_ban.zig");
    _ = @import("checks/orphan_files.zig");
    _ = @import("checks/stub_body_ban.zig");
    _ = @import("checks/doc_quality.zig");
    _ = @import("checks/comptime_quota.zig");
    _ = @import("checks/type_size.zig");
    _ = @import("ast/import_graph.zig");
}
