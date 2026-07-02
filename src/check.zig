const std = @import("std");
const config_mod = @import("config.zig");
const config_parser = @import("config_parser.zig");
const reporter = @import("reporter.zig");
const registry = @import("cli/registry.zig");
const run_all = @import("cli/run_all.zig");
const baseline = @import("baseline.zig");

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

    const parsed = parseArgs(args[1..]);
    reporter.init(parsed.quiet);
    const command = parsed.command orelse {
        registry.printHelp();
        std.process.exit(1);
    };

    const cfg = config_parser.load(allocator, parsed.project_dir);
    var ctx: registry.RunCtx = .{
        .allocator = allocator,
        .project_dir = parsed.project_dir,
        .cfg = &cfg,
        .quiet = parsed.quiet,
    };

    dispatch(&ctx, &cfg, command) catch |e| switch (e) {
        // CheckFailed means the check already printed its own diagnostic.
        // Exit non-zero without surfacing a Zig stack trace.
        error.CheckFailed => std.process.exit(1),
        else => return e,
    };
}

const ParsedArgs = struct {
    command: ?[]const u8 = null,
    project_dir: []const u8 = ".",
    quiet: bool = false,
};

// Scans argv (sans program name): first non-flag token is the command, the
// next is the project dir; `--quiet`/`-q` toggles quiet mode.
fn parseArgs(args: [][:0]u8) ParsedArgs {
    var parsed: ParsedArgs = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            parsed.quiet = true;
        } else if (parsed.command == null) {
            parsed.command = arg;
        } else {
            parsed.project_dir = arg;
        }
    }
    return parsed;
}

// Routes the parsed command to `all`, or to a registered command (optionally
// wrapped in baseline mode). Propagates error.CheckFailed to the caller.
fn dispatch(ctx: *registry.RunCtx, cfg: *const config_mod.Config, command: []const u8) !void {
    if (std.mem.eql(u8, command, run_all.COMMAND_NAME)) {
        return run_all.run(ctx);
    }
    const cmd = registry.find(command) orelse {
        registry.printHelp();
        std.process.exit(1);
    };
    if (cfg.baseline.enabled) {
        return baseline.runWithBaseline(ctx, cmd);
    }
    return cmd.run(ctx);
}

// ── Tests ──────────────────────────────────────────────────────────────

// Aggregates every module's tests. Zig only collects `test` decls from files
// reachable through a `test` block in the test root, so any new file under
// src/ must be referenced here or its tests silently never run. The
// `test-root-drift` check enforces that every src/checks/*.zig appears below.
test {
    // Framework modules
    _ = @import("config.zig");
    _ = @import("config_parser.zig");
    _ = @import("spec/parser.zig");
    _ = @import("spec/matcher.zig");
    _ = @import("spec/init.zig");
    _ = @import("walk.zig");
    _ = @import("text.zig");
    _ = @import("reporter.zig");
    _ = @import("ast/decls.zig");
    _ = @import("ast/parser.zig");
    _ = @import("ast/containers.zig");
    _ = @import("ast/index.zig");
    _ = @import("ast/import_graph.zig");
    _ = @import("cache.zig");
    _ = @import("snapshot.zig");
    _ = @import("snapshot_helper.zig");
    _ = @import("cli/types.zig");
    _ = @import("cli/registry.zig");
    _ = @import("cli/run_all.zig");
    _ = @import("baseline.zig");
    _ = @import("testing/golden_runner.zig");

    // Checks — keep in sync with src/checks/*.zig (enforced by test-root-drift)
    _ = @import("checks/allocator_hygiene.zig");
    _ = @import("checks/anytype_budget.zig");
    _ = @import("checks/ban_env.zig");
    _ = @import("checks/ban_fs.zig");
    _ = @import("checks/ban_globals.zig");
    _ = @import("checks/ban_hardcoded_paths.zig");
    _ = @import("checks/banned_symbol_helper.zig");
    _ = @import("checks/ban_net.zig");
    _ = @import("checks/ban_rng.zig");
    _ = @import("checks/ban_sleep.zig");
    _ = @import("checks/ban_time.zig");
    _ = @import("checks/boolean_param_ban.zig");
    _ = @import("checks/bool_ops_per_condition.zig");
    _ = @import("checks/boundaries.zig");
    _ = @import("checks/catch_discipline.zig");
    _ = @import("checks/cognitive_complexity.zig");
    _ = @import("checks/compile_error_explanation.zig");
    _ = @import("checks/comptime_quota.zig");
    _ = @import("checks/dead_pub.zig");
    _ = @import("checks/debug_print_ban.zig");
    _ = @import("checks/doc_comments.zig");
    _ = @import("checks/doc_quality.zig");
    _ = @import("checks/dup_const.zig");
    _ = @import("checks/errdefer_in_init.zig");
    _ = @import("checks/error_discipline.zig");
    _ = @import("checks/escape_discipline.zig");
    _ = @import("checks/oom_discipline.zig");
    _ = @import("checks/file_size.zig");
    _ = @import("checks/function_length.zig");
    _ = @import("checks/function_size.zig");
    _ = @import("checks/imports.zig");
    _ = @import("checks/int_from_float_budget.zig");
    _ = @import("checks/init_deinit_symmetry.zig");
    _ = @import("checks/init_hygiene.zig");
    _ = @import("checks/line_length.zig");
    _ = @import("checks/magic_number.zig");
    _ = @import("checks/naming.zig");
    _ = @import("checks/nesting_depth.zig");
    _ = @import("checks/no_test_imports_in_prod.zig");
    _ = @import("checks/optional_density.zig");
    _ = @import("checks/orphan_files.zig");
    _ = @import("checks/panic_budget.zig");
    _ = @import("checks/pub_api_surface.zig");
    _ = @import("checks/repeated_string_literal.zig");
    _ = @import("checks/repeated_switch_on_enum.zig");
    _ = @import("checks/returns_per_function.zig");
    _ = @import("checks/spec_init.zig");
    _ = @import("checks/spec_quality.zig");
    _ = @import("checks/spec.zig");
    _ = @import("checks/static_factory_ban.zig");
    _ = @import("checks/stringly_typed_switches.zig");
    _ = @import("checks/struct_method_cap.zig");
    _ = @import("checks/stub_body_ban.zig");
    _ = @import("checks/test_coverage.zig");
    _ = @import("checks/test_has_assertion.zig");
    _ = @import("checks/test_no_conditional.zig");
    _ = @import("checks/type_size.zig");
    _ = @import("checks/unwrap_discipline.zig");
    _ = @import("checks/usingnamespace_ban.zig");
    _ = @import("checks/vague_name_blacklist.zig");
}

// Meta-guard: the block above is hand-maintained, and the whole reason ~78
// tests once silently never ran is that it drifted from the files on disk.
// This walks src/checks/ and fails if any file is missing from the block, so
// the next added check can't skip its tests unnoticed. (The fs walk is allowed
// in test scope; the capturing while is an iterator loop, and its inner `if`s
// are nested — so neither ban-fs nor test-no-conditional flags it.)
test "test root imports every check file" {
    const self_src = @embedFile("check.zig");
    var dir = try std.fs.cwd().openDir("src/checks", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var missing_buf: [256]u8 = undefined;
    var missing_len: usize = 0;
    var needle_buf: [256]u8 = undefined;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const needle = try std.fmt.bufPrint(&needle_buf, "@import(\"checks/{s}\")", .{entry.name});
        if (std.mem.indexOf(u8, self_src, needle) == null) {
            @memcpy(missing_buf[0..entry.name.len], entry.name);
            missing_len = entry.name.len;
            break;
        }
    }
    // A non-empty result names a check file missing from the block above.
    try std.testing.expectEqualStrings("", missing_buf[0..missing_len]);
}
