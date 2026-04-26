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
const check_pub_api_surface = @import("../checks/pub_api_surface.zig");
const check_panic_budget = @import("../checks/panic_budget.zig");
const check_spec_drift = @import("../checks/spec_drift.zig");
const check_catch_discipline = @import("../checks/catch_discipline.zig");
const check_error_discipline = @import("../checks/error_discipline.zig");
const check_cognitive_complexity = @import("../checks/cognitive_complexity.zig");
const check_anytype_budget = @import("../checks/anytype_budget.zig");
const check_dead_pub = @import("../checks/dead_pub.zig");
const check_allocator_hygiene = @import("../checks/allocator_hygiene.zig");
const check_dup_const = @import("../checks/dup_const.zig");
const check_debug_print_ban = @import("../checks/debug_print_ban.zig");
const check_orphan_files = @import("../checks/orphan_files.zig");
const check_stub_body_ban = @import("../checks/stub_body_ban.zig");
const check_doc_quality = @import("../checks/doc_quality.zig");

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
    .{ .name = "pub-api-surface", .summary = "Snapshot every pub fn/type; diff fails build", .run = check_pub_api_surface.run },
    .{ .name = "panic-budget", .summary = "Cap @panic / unreachable / TODO / FIXME counts via snapshot", .run = check_panic_budget.run },
    .{ .name = "spec-drift", .summary = "Snapshot pub fn prototypes; diff fails on signature change", .run = check_spec_drift.run },
    .{ .name = "catch-discipline", .summary = "Reject catch unreachable in production code", .run = check_catch_discipline.run },
    .{ .name = "error-discipline", .summary = "Require explicit error sets on pub fn", .run = check_error_discipline.run },
    .{ .name = "cognitive-complexity", .summary = "Cap per-function cognitive complexity score", .run = check_cognitive_complexity.run },
    .{ .name = "anytype-budget", .summary = "Cap anytype parameter count per file", .run = check_anytype_budget.run },
    .{ .name = "dead-pub", .summary = "Flag unused public declarations", .run = check_dead_pub.run },
    .{ .name = "allocator-hygiene", .summary = "Reject hardcoded global allocators outside main/test", .run = check_allocator_hygiene.run },
    .{ .name = "dup-const", .summary = "Reject duplicate file-scope string-literal consts across files", .run = check_dup_const.run },
    .{ .name = "debug-print-ban", .summary = "Reject std.debug.print(...) calls outside main/test", .run = check_debug_print_ban.run },
    .{ .name = "orphan-files", .summary = "Flag .zig files under src/ unreachable from any configured root", .run = check_orphan_files.run },
    .{ .name = "stub-body-ban", .summary = "Reject obvious stub function bodies (return undefined, placeholder panics, unreachable in value fns)", .run = check_stub_body_ban.run },
    .{ .name = "doc-quality", .summary = "Reject empty or stub /// doc comments on public declarations", .run = check_doc_quality.run },
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
