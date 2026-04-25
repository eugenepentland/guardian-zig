const std = @import("std");
const config_mod = @import("../config.zig");

const check_spec = @import("../checks/spec.zig");
const check_spec_init = @import("../checks/spec_init.zig");
const check_file_size = @import("../checks/file_size.zig");
const check_boundaries = @import("../checks/boundaries.zig");
const check_usingnamespace_ban = @import("../checks/usingnamespace_ban.zig");
const check_spec_quality = @import("../checks/spec_quality.zig");
const check_naming = @import("../checks/naming.zig");
const check_function_size = @import("../checks/function_size.zig");

pub const RunCtx = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    cfg: *const config_mod.Config,
    quiet: bool,
};

pub const NeedsAst = enum { no, yes };

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    needs_ast: NeedsAst = .no,
    run: *const fn (ctx: *RunCtx) anyerror!void,
};

pub const all: []const Command = &.{
    .{ .name = "spec", .summary = "Verify SPEC.md ↔ // spec: tag coverage", .run = check_spec.run },
    .{ .name = "spec-init", .summary = "Generate starter SPEC.md from pub fn signatures", .run = check_spec_init.run },
    .{ .name = "file-size", .summary = "Enforce per-file line limit", .run = check_file_size.run },
    .{ .name = "boundaries", .summary = "Enforce @import boundary rules", .run = check_boundaries.run },
    .{ .name = "usingnamespace-ban", .summary = "Reject usingnamespace declarations in src/", .run = check_usingnamespace_ban.run },
    .{ .name = "spec-quality", .summary = "Lint SPEC.md prose for vague phrases and stub behaviors", .run = check_spec_quality.run },
    .{ .name = "naming", .summary = "Enforce Zig naming conventions (PascalCase types, camelCase fns)", .run = check_naming.run },
    .{ .name = "function-size", .summary = "Cap function parameter count", .run = check_function_size.run },
};

pub fn find(name: []const u8) ?Command {
    for (all) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

pub fn printHelp() void {
    const print = std.debug.print;
    print("Usage: guardian-check <command> [project-dir] [--quiet]\n\n", .{});
    print("Commands:\n", .{});
    for (all) |cmd| {
        print("  {s: <14} {s}\n", .{ cmd.name, cmd.summary });
    }
}
