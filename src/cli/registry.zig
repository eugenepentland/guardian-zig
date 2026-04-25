const std = @import("std");
const types = @import("types.zig");

const check_spec = @import("../checks/spec.zig");
const check_spec_init = @import("../checks/spec_init.zig");
const check_file_size = @import("../checks/file_size.zig");
const check_boundaries = @import("../checks/boundaries.zig");
const check_usingnamespace_ban = @import("../checks/usingnamespace_ban.zig");
const check_spec_quality = @import("../checks/spec_quality.zig");
const check_naming = @import("../checks/naming.zig");
const check_function_size = @import("../checks/function_size.zig");
const check_doc_comments = @import("../checks/doc_comments.zig");
const check_imports = @import("../checks/imports.zig");

pub const RunCtx = types.RunCtx;
pub const NeedsAst = types.NeedsAst;
pub const Command = types.Command;

pub const all: []const Command = &.{
    .{ .name = "spec", .summary = "Verify SPEC.md ↔ // spec: tag coverage", .run = check_spec.run },
    .{ .name = "spec-init", .summary = "Generate starter SPEC.md from pub fn signatures", .run = check_spec_init.run },
    .{ .name = "file-size", .summary = "Enforce per-file line limit", .run = check_file_size.run },
    .{ .name = "boundaries", .summary = "Enforce @import boundary rules", .run = check_boundaries.run },
    .{ .name = "usingnamespace-ban", .summary = "Reject usingnamespace declarations in src/", .run = check_usingnamespace_ban.run },
    .{ .name = "spec-quality", .summary = "Lint SPEC.md prose for vague phrases and stub behaviors", .run = check_spec_quality.run },
    .{ .name = "naming", .summary = "Enforce Zig naming conventions (PascalCase types, camelCase fns)", .run = check_naming.run },
    .{ .name = "function-size", .summary = "Cap function parameter count", .run = check_function_size.run },
    .{ .name = "doc-comments", .summary = "Require /// doc comments on every public fn/type", .run = check_doc_comments.run },
    .{ .name = "imports", .summary = "Detect cycles in the @import graph", .run = check_imports.run },
};

/// Look up a command by its CLI name; null if not registered.
pub fn find(name: []const u8) ?Command {
    for (all) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

/// Print the usage summary enumerating every registered command.
pub fn printHelp() void {
    const print = std.debug.print;
    print("Usage: guardian-check <command> [project-dir] [--quiet]\n\n", .{});
    print("Commands:\n", .{});
    for (all) |cmd| {
        print("  {s: <14} {s}\n", .{ cmd.name, cmd.summary });
    }
}
