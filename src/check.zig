const std = @import("std");
const config_mod = @import("config.zig");
const reporter = @import("reporter.zig");
const registry = @import("cli/registry.zig");

pub fn main() !void {
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

    const cmd = registry.find(command.?) orelse {
        registry.printHelp();
        std.process.exit(1);
    };

    const cfg = config_mod.load(allocator, project_dir);
    var ctx: registry.RunCtx = .{
        .allocator = allocator,
        .project_dir = project_dir,
        .cfg = &cfg,
        .quiet = quiet_mode,
    };
    try cmd.run(&ctx);
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
    _ = @import("cli/registry.zig");
    _ = @import("checks/spec.zig");
    _ = @import("checks/spec_init.zig");
    _ = @import("checks/file_size.zig");
    _ = @import("checks/boundaries.zig");
    _ = @import("checks/usingnamespace_ban.zig");
    _ = @import("checks/spec_quality.zig");
    _ = @import("checks/naming.zig");
    _ = @import("checks/function_size.zig");
}
