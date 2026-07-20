//! CLI entry point: parse argv, resolve the git-diff ref (--against /
//! GUARDIAN_AGAINST / config), and dispatch to a registered command or one of
//! specially-handled commands (`all`, `nightly`, `commit`, maintenance tools,
//! `explain`, and `version`) that cannot all be registry entries without an
//! @import cycle.

const std = @import("std");
const config_mod = @import("config.zig");
const config_parser = @import("config_parser.zig");
const reporter = @import("reporter.zig");
const registry = @import("cli/registry.zig");
const run_all = @import("cli/run_all.zig");
const nightly = @import("cli/nightly.zig");
const commit_cmd = @import("cli/commit.zig");
const install_hook = @import("cli/install_hook.zig");
const explain = @import("cli/explain.zig");
const doctor = @import("cli/doctor.zig");
const spec_sync = @import("cli/spec_sync.zig");
const accept = @import("cli/accept.zig");
const version = @import("version.zig");
const baseline = @import("baseline.zig");
const mutation_runner = @import("mutation/runner.zig");
const required_inputs = @import("required_inputs.zig");

/// Env var naming a git ref for diff-scoped checks; the --against flag
/// takes precedence, guardian.toml's [change_classification] follows.
const against_env = "GUARDIAN_AGAINST";
const policy_approval_env = "GUARDIAN_POLICY_APPROVED";

/// Entry point. Parses argv, dispatches to the registered command.
pub fn main() !void {
    // page_allocator is intentional here; pub fn main is the documented
    // exemption point in the "Allocator Hygiene" spec — every other call
    // site threads the allocator from this arena.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A mutation run's child builds re-invoke guardian; gating the
    // deliberately-mutated tree would deadlock the tier on itself, so
    // every command no-ops until the mutant is restored.
    if (envFlagActive(readEnv(allocator, mutation_runner.mutation_env))) {
        reporter.init(false);
        reporter.ok("checks skipped (mutation test run in progress)", .{});
        return;
    }

    // A guardian-spawned child build (e.g. `commit`'s test run) sets this so the
    // wired gate no-ops while the child's real work — compiling and running the
    // tests — still executes. Distinct from the mutation env so its intent reads
    // clearly; it never skips anything but guardian's own checks.
    if (envFlagActive(readEnv(allocator, commit_cmd.child_skip_env))) {
        reporter.init(false);
        reporter.ok("checks skipped (guardian-spawned child build)", .{});
        return;
    }

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        reporter.init(false);
        registry.printHelp();
        std.process.exit(1);
    }

    const parsed = parseArgs(args[1..]);
    reporter.init(parsed.quiet);

    // `--version` / `version`: print and exit before any project work. Printing
    // std.debug.print from pub fn main is exempt from debug-print-ban.
    if (parsed.show_version or isVersionCommand(parsed.command)) {
        std.debug.print("guardian-check {s}\n", .{version.string});
        return;
    }

    const command = parsed.command orelse {
        registry.printHelp();
        std.process.exit(1);
    };

    // `explain <check>`: static, needs no project dir or config. An unknown
    // name exits non-zero after listing the valid checks.
    if (std.mem.eql(u8, command, "explain")) {
        if (!explain.run(explainQuery(parsed))) std.process.exit(1);
        return;
    }

    // --only and --skip contradict each other; reject the combination outright.
    if (onlySkipConflict(parsed)) {
        reporter.fatal("--only and --skip cannot be combined", .{});
    }

    // Fail closed on a broken guardian.toml: load prints a located diagnostic
    // and we exit non-zero rather than silently running on all-defaults.
    const cfg = config_parser.load(allocator, parsed.project_dir) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => std.process.exit(1),
    };
    var ctx: registry.RunCtx = .{
        .allocator = allocator,
        .project_dir = parsed.project_dir,
        .cfg = &cfg,
        .quiet = parsed.quiet,
        .against = parsed.against orelse nonEmpty(readEnv(allocator, against_env)),
        .full = parsed.full,
        .gate = parsed.gate,
        .only = try splitCsv(allocator, parsed.only),
        .skip = try splitCsv(allocator, parsed.skip),
        .intent = parsed.intent,
        .json = parsed.json,
        .check_filter = parsed.check_filter,
        .prune_stale = parsed.prune_stale,
        .confirm = parsed.confirm,
        .assert_density = parsed.assert_density,
        .refresh = try splitCsv(allocator, parsed.accept_checks),
        .policy_approved = envFlagActive(readEnv(allocator, policy_approval_env)),
        .command_exists = registeredCommand,
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
    full: bool = false,
    /// `--gate`: force `all` to block on violations regardless of `[gate]
    /// on_build`. For the pre-commit hook and CI.
    gate: bool = false,
    against: ?[]const u8 = null,
    /// Raw comma-separated `--only` value (split later); null = no filter.
    only: ?[]const u8 = null,
    /// Raw comma-separated `--skip` value (split later); null = no filter.
    skip: ?[]const u8 = null,
    /// `--intent "<message>"` value for the `commit` command; null when absent.
    intent: ?[]const u8 = null,
    json: bool = false,
    check_filter: ?[]const u8 = null,
    prune_stale: bool = false,
    confirm: bool = false,
    assert_density: bool = false,
    /// First positional after `accept`, before the optional project directory.
    accept_checks: ?[]const u8 = null,
    /// True when `--version` was passed anywhere on the command line.
    show_version: bool = false,
};

// Scans argv (sans program name): first non-flag token is the command, the next
// is the project dir; `--quiet`/`-q` toggles quiet mode, `--full` selects
// mutate's whole-tree tier, `--against <ref>` sets the diff base, `--only`/
// `--skip <a,b>` filter the `all` suite, `--intent "<msg>"` is the commit
// subject, `--version` requests the version.
fn parseArgs(args: []const [:0]u8) ParsedArgs {
    var parsed: ParsedArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            parsed.quiet = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            parsed.full = true;
        } else if (std.mem.eql(u8, arg, "--gate")) {
            parsed.gate = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            parsed.show_version = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.eql(u8, arg, "--prune-stale")) {
            parsed.prune_stale = true;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            parsed.confirm = true;
        } else if (std.mem.eql(u8, arg, "--assert-density")) {
            parsed.assert_density = true;
        } else if (std.mem.eql(u8, arg, "--against")) {
            i += 1;
            if (i < args.len) parsed.against = args[i];
        } else if (std.mem.eql(u8, arg, "--only")) {
            i += 1;
            if (i < args.len) parsed.only = args[i];
        } else if (std.mem.eql(u8, arg, "--skip")) {
            i += 1;
            if (i < args.len) parsed.skip = args[i];
        } else if (std.mem.eql(u8, arg, "--intent")) {
            i += 1;
            if (i < args.len) parsed.intent = args[i];
        } else if (std.mem.eql(u8, arg, "--check")) {
            i += 1;
            if (i < args.len) parsed.check_filter = args[i];
        } else if (parsed.command == null) {
            parsed.command = arg;
        } else if (std.mem.eql(u8, parsed.command.?, accept.command_name) and parsed.accept_checks == null) {
            parsed.accept_checks = arg;
        } else {
            parsed.project_dir = arg;
        }
    }
    return parsed;
}

/// True when `command` is the `version` command (prints the version like the
/// `--version` flag).
fn isVersionCommand(command: ?[]const u8) bool {
    const c = command orelse return false;
    return std.mem.eql(u8, c, "version");
}

fn registeredCommand(name: []const u8) bool {
    return registry.find(name) != null;
}

/// The check name for `explain`: the positional after the command, or null when
/// omitted. parseArgs stores that positional in `project_dir`, so its default
/// "." means no name was given (a bare `explain` lists every check).
fn explainQuery(parsed: ParsedArgs) ?[]const u8 {
    return if (std.mem.eql(u8, parsed.project_dir, ".")) null else parsed.project_dir;
}

/// True when both --only and --skip were given — a contradiction that is an
/// error rather than an intersection.
fn onlySkipConflict(parsed: ParsedArgs) bool {
    return parsed.only != null and parsed.skip != null;
}

/// Splits a comma-separated `--only`/`--skip` value into check names, trimming
/// whitespace and dropping blank segments ("a,,b" -> {a,b}); empty slice when
/// null (no filter active).
fn splitCsv(allocator: std.mem.Allocator, csv: ?[]const u8) std.mem.Allocator.Error![]const []const u8 {
    const s = csv orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        // Propagate OOM: a truncated --only/--skip list would silently narrow
        // the suite, skipping checks the user asked to run (fail-open).
        try list.append(allocator, trimmed);
    }
    return list.toOwnedSlice(allocator);
}

/// Reads an env var; null when unset (arena-owned when present).
fn readEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

/// Truthy-flag semantics shared with GUARDIAN_UPDATE_SNAPSHOT: set and
/// neither empty nor "0".
fn envFlagActive(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Collapses an empty env value to null so it can't shadow config.
fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

// Routes the parsed command to `all`, or to a registered command (optionally
// wrapped in baseline mode). Propagates error.CheckFailed to the caller.
fn dispatch(ctx: *registry.RunCtx, cfg: *const config_mod.Config, command: []const u8) !void {
    if (needsRequiredInputs(command)) try required_inputs.validate(ctx);
    if (std.mem.eql(u8, command, run_all.command_name)) {
        return run_all.run(ctx);
    }
    // nightly composes `all` + `mutate --full`; dispatched specially (like
    // `all`) because it can't be a registry entry without an @import cycle.
    if (std.mem.eql(u8, command, nightly.command_name)) {
        return nightly.run(ctx);
    }
    // commit gates the tree (`all`) then auto-commits on green; special-dispatched
    // for the same reason as nightly (commit.zig imports run_all → registry cycle).
    if (std.mem.eql(u8, command, commit_cmd.command_name)) {
        return commit_cmd.run(ctx);
    }
    // install-hook writes .git/hooks/pre-commit (the blocking gate); special-
    // dispatched like commit, so a raw `git commit` can't bypass the gate now
    // that a dev build only reports.
    if (std.mem.eql(u8, command, install_hook.command_name)) return install_hook.run(ctx);
    if (std.mem.eql(u8, command, "doctor")) return doctor.run(ctx);
    if (std.mem.eql(u8, command, "spec-sync")) return spec_sync.run(ctx);
    if (std.mem.eql(u8, command, accept.command_name)) return accept.run(ctx);
    const cmd = registry.find(command) orelse {
        registry.printHelp();
        std.process.exit(1);
    };
    // `all`/`nightly` validate refresh + deny_growth names inside run_all.run;
    // a single-check run (e.g. `guardian-check pub-api-surface`, `mutate`) has
    // to validate them here so a typo'd GUARDIAN_UPDATE_SNAPSHOT still hard-fails.
    try run_all.validateSelectiveConfig(ctx);
    // Baseline mode only wraps real gate checks. Non-gates (spec-init, mutate,
    // debt — the run_all SKIP set) must run raw: baseline-wrapping a report like
    // `debt` would capture its own output as "violations" and baseline it.
    const mode = cfg.policy.modeFor(cmd.name);
    if (cfg.policy.usesBaselineFor(cmd.name, cfg.baseline) and run_all.isAllCheck(cmd.name)) {
        return baseline.runWithBaseline(ctx, cmd);
    }
    if (mode != .report) return cmd.run(ctx);
    cmd.run(ctx) catch |e| switch (e) {
        error.CheckFailed => {
            reporter.ok("{s}: report-only finding (policy did not block)", .{cmd.name});
            return;
        },
        else => return e,
    };
}

fn needsRequiredInputs(command: []const u8) bool {
    if (std.mem.eql(u8, command, run_all.command_name)) return true;
    if (std.mem.eql(u8, command, nightly.command_name)) return true;
    if (std.mem.eql(u8, command, commit_cmd.command_name)) return true;
    if (std.mem.eql(u8, command, accept.command_name)) return true;
    if (std.mem.eql(u8, command, "mutate")) return true;
    return run_all.isAllCheck(command);
}

test "project-analysis commands require input preflight" {
    try std.testing.expect(needsRequiredInputs("all"));
    try std.testing.expect(needsRequiredInputs("accept"));
    try std.testing.expect(needsRequiredInputs("mutate"));
    try std.testing.expect(needsRequiredInputs("pub-api-surface"));
    try std.testing.expect(!needsRequiredInputs("doctor"));
    try std.testing.expect(!needsRequiredInputs("debt"));
    try std.testing.expect(!needsRequiredInputs("spec-init"));
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
    _ = @import("config_semantics.zig");
    _ = @import("config_policy.zig");
    _ = @import("build_helper.zig");
    _ = @import("required_inputs.zig");
    _ = @import("metadata_transaction.zig");
    _ = @import("spec/parser.zig");
    _ = @import("spec/matcher.zig");
    _ = @import("spec/init.zig");
    _ = @import("walk.zig");
    _ = @import("text.zig");
    _ = @import("git.zig");
    _ = @import("accept_session.zig");
    _ = @import("mutation/gen.zig");
    _ = @import("mutation/runner.zig");
    _ = @import("mutation/journal.zig");
    _ = @import("mutation/cache.zig");
    _ = @import("mutation/report.zig");
    _ = @import("cli/mutate.zig");
    _ = @import("cli/debt.zig");
    _ = @import("cli/doctor.zig");
    _ = @import("cli/spec_sync.zig");
    _ = @import("cli/accept.zig");
    _ = @import("cli/nightly.zig");
    _ = @import("cli/commit.zig");
    _ = @import("cli/install_hook.zig");
    _ = @import("cli/explain.zig");
    _ = @import("version.zig");
    _ = @import("reporter.zig");
    _ = @import("sink.zig");
    _ = @import("dora.zig");
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
    _ = @import("ratchet.zig");
    _ = @import("testing/golden_runner.zig");

    // Fakes — deterministic test doubles shipped as the `guardian-fakes`
    // module. They live outside src/checks/, so the check-file meta-guard
    // doesn't cover them; the "test root imports every fakes file" guard below
    // keeps this list in sync with src/fakes/*.zig.
    _ = @import("fakes/fakes.zig");
    _ = @import("fakes/clock.zig");
    _ = @import("fakes/random.zig");
    _ = @import("fakes/fs.zig");
    _ = @import("fakes/env.zig");

    // Checks — keep in sync with src/checks/*.zig (enforced by test-root-drift)
    _ = @import("checks/allocator_hygiene.zig");
    _ = @import("checks/anytype_budget.zig");
    _ = @import("checks/assert_doc_consistency.zig");
    _ = @import("checks/ban_env.zig");
    _ = @import("checks/ban_fs.zig");
    _ = @import("checks/ban_globals.zig");
    _ = @import("checks/ban_hardcoded_paths.zig");
    _ = @import("checks/banned_symbol_helper.zig");
    _ = @import("checks/ban_net.zig");
    _ = @import("checks/ban_rng.zig");
    _ = @import("checks/ban_secrets.zig");
    _ = @import("checks/ban_sleep.zig");
    _ = @import("checks/ban_time.zig");
    _ = @import("checks/boolean_param_ban.zig");
    _ = @import("checks/bool_ops_per_condition.zig");
    _ = @import("checks/boundaries.zig");
    _ = @import("checks/catch_discipline.zig");
    _ = @import("checks/change_classification.zig");
    _ = @import("checks/cognitive_complexity.zig");
    _ = @import("checks/compile_error_explanation.zig");
    _ = @import("checks/completeness.zig");
    _ = @import("checks/dead_pub.zig");
    _ = @import("checks/debug_print_ban.zig");
    _ = @import("checks/deprecated_alias.zig");
    _ = @import("checks/doc_comments.zig");
    _ = @import("checks/errdefer_in_init.zig");
    _ = @import("checks/error_discipline.zig");
    _ = @import("checks/escape_discipline.zig");
    _ = @import("checks/oom_discipline.zig");
    _ = @import("checks/fatal_exit.zig");
    _ = @import("checks/file_size.zig");
    _ = @import("checks/function_length.zig");
    _ = @import("checks/function_size.zig");
    _ = @import("checks/fuzz_presence.zig");
    _ = @import("checks/imports.zig");
    _ = @import("checks/int_from_float_budget.zig");
    _ = @import("checks/init_deinit_symmetry.zig");
    _ = @import("checks/init_hygiene.zig");
    _ = @import("checks/line_length.zig");
    _ = @import("checks/magic_number.zig");
    _ = @import("checks/module_doc_header.zig");
    _ = @import("checks/external_gates.zig");
    _ = @import("checks/policy_drift.zig");
    _ = @import("checks/naming.zig");
    _ = @import("checks/nesting_depth.zig");
    _ = @import("checks/no_test_imports_in_prod.zig");
    _ = @import("checks/optional_density.zig");
    _ = @import("checks/orphan_files.zig");
    _ = @import("checks/panic_budget.zig");
    _ = @import("checks/pub_api_surface.zig");
    _ = @import("checks/repeated_string_literal.zig");
    _ = @import("checks/repeated_switch_on_enum.zig");
    _ = @import("checks/spec_init.zig");
    _ = @import("checks/spec_quality.zig");
    _ = @import("checks/spec.zig");
    _ = @import("checks/static_factory_ban.zig");
    _ = @import("checks/stringly_typed_switches.zig");
    _ = @import("checks/struct_method_cap.zig");
    _ = @import("checks/stub_body_ban.zig");
    _ = @import("checks/stdout_flush.zig");
    _ = @import("checks/stack_escape.zig");
    _ = @import("checks/test_coverage.zig");
    _ = @import("checks/test_has_assertion.zig");
    _ = @import("checks/test_no_conditional.zig");
    _ = @import("checks/test_skip_ban.zig");
    _ = @import("checks/type_size.zig");
    _ = @import("checks/unsafe_ops_budget.zig");
    _ = @import("checks/unwrap_discipline.zig");
    _ = @import("checks/usingnamespace_ban.zig");
}

// spec: Configuration - Parses the against and full command-line flags

test "parseArgs reads --against ref and --full alongside command and dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc([:0]u8, 5);
    args[0] = try a.dupeZ(u8, "mutate");
    args[1] = try a.dupeZ(u8, ".");
    args[2] = try a.dupeZ(u8, "--against");
    args[3] = try a.dupeZ(u8, "origin/main");
    args[4] = try a.dupeZ(u8, "--full");
    const parsed = parseArgs(args);
    try std.testing.expectEqualStrings("mutate", parsed.command.?);
    try std.testing.expectEqualStrings(".", parsed.project_dir);
    try std.testing.expectEqualStrings("origin/main", parsed.against.?);
    try std.testing.expect(parsed.full);
    try std.testing.expect(!parsed.quiet);
}

// spec: Configuration - Parses the only, skip, and version command-line flags

test "parseArgs reads --only, --skip and --version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc([:0]u8, 6);
    args[0] = try a.dupeZ(u8, "all");
    args[1] = try a.dupeZ(u8, "--only");
    args[2] = try a.dupeZ(u8, "spec,file-size");
    args[3] = try a.dupeZ(u8, "--skip");
    args[4] = try a.dupeZ(u8, "boundaries");
    args[5] = try a.dupeZ(u8, "--version");
    const parsed = parseArgs(args);
    try std.testing.expectEqualStrings("all", parsed.command.?);
    try std.testing.expectEqualStrings("spec,file-size", parsed.only.?);
    try std.testing.expectEqualStrings("boundaries", parsed.skip.?);
    try std.testing.expect(parsed.show_version);
}

// spec: Configuration - Parses the gate command-line flag

test "parseArgs reads the --gate flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc([:0]u8, 3);
    args[0] = try a.dupeZ(u8, "all");
    args[1] = try a.dupeZ(u8, ".");
    args[2] = try a.dupeZ(u8, "--gate");
    const parsed = parseArgs(args);
    try std.testing.expectEqualStrings("all", parsed.command.?);
    try std.testing.expect(parsed.gate);
    // Absent by default: a plain build reports rather than blocks.
    const plain = try a.alloc([:0]u8, 1);
    plain[0] = try a.dupeZ(u8, "all");
    try std.testing.expect(!parseArgs(plain).gate);
}

// spec: Configuration - Parses the intent flag for the commit command

test "parseArgs reads --intent message alongside command and dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc([:0]u8, 4);
    args[0] = try a.dupeZ(u8, "commit");
    args[1] = try a.dupeZ(u8, "--intent");
    args[2] = try a.dupeZ(u8, "add the widget");
    args[3] = try a.dupeZ(u8, ".");
    const parsed = parseArgs(args);
    try std.testing.expectEqualStrings("commit", parsed.command.?);
    try std.testing.expectEqualStrings("add the widget", parsed.intent.?);
    try std.testing.expectEqualStrings(".", parsed.project_dir);
}

// spec: Maintenance - Parses maintenance command flags independently of the project directory

test "parseArgs reads maintenance report and prune flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc([:0]u8, 8);
    args[0] = try a.dupeZ(u8, "debt");
    args[1] = try a.dupeZ(u8, "../project");
    args[2] = try a.dupeZ(u8, "--json");
    args[3] = try a.dupeZ(u8, "--check");
    args[4] = try a.dupeZ(u8, "spec");
    args[5] = try a.dupeZ(u8, "--prune-stale");
    args[6] = try a.dupeZ(u8, "--yes");
    args[7] = try a.dupeZ(u8, "--assert-density");
    const parsed = parseArgs(args);
    try std.testing.expectEqualStrings("debt", parsed.command.?);
    try std.testing.expectEqualStrings("../project", parsed.project_dir);
    try std.testing.expectEqualStrings("spec", parsed.check_filter.?);
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.prune_stale);
    try std.testing.expect(parsed.confirm);
    try std.testing.expect(parsed.assert_density);
}

// spec: Maintenance - Parses named accept checks before the optional project directory

test "parseArgs reads accept check list and project directory positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc([:0]u8, 3);
    args[0] = try a.dupeZ(u8, "accept");
    args[1] = try a.dupeZ(u8, "file-size,line-length");
    args[2] = try a.dupeZ(u8, "../project");
    const parsed = parseArgs(args);
    try std.testing.expectEqualStrings("file-size,line-length", parsed.accept_checks.?);
    try std.testing.expectEqualStrings("../project", parsed.project_dir);
}

// spec: Configuration - Splits a comma-separated filter value into check names

test "splitCsv trims segments and returns empty for null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try splitCsv(a, "spec, file-size ,,boundaries");
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("spec", out[0]);
    try std.testing.expectEqualStrings("file-size", out[1]);
    try std.testing.expectEqualStrings("boundaries", out[2]);
    try std.testing.expectEqual(@as(usize, 0), (try splitCsv(a, null)).len);
}

// spec: Configuration - Rejects combining the only and skip filters

test "onlySkipConflict flags only+skip together" {
    try std.testing.expect(onlySkipConflict(.{ .only = "a", .skip = "b" }));
    try std.testing.expect(!onlySkipConflict(.{ .only = "a" }));
    try std.testing.expect(!onlySkipConflict(.{ .skip = "b" }));
    try std.testing.expect(!onlySkipConflict(.{}));
}

// spec: Mutation Testing - Skips every check while a mutation test run is in progress

test "envFlagActive gates the mutation-run check skip" {
    // The main() short-circuit fires exactly when GUARDIAN_MUTATION_RUN is
    // set to a non-empty value other than "0" (same semantics as
    // GUARDIAN_UPDATE_SNAPSHOT).
    try std.testing.expect(envFlagActive("1"));
    try std.testing.expect(envFlagActive("yes"));
    try std.testing.expect(!envFlagActive("0"));
    try std.testing.expect(!envFlagActive(""));
    try std.testing.expect(!envFlagActive(null));
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

// Meta-guard for src/fakes/ — the check-file guard above only walks
// src/checks/, but the same drift bug (AUDIT P0-1) would silently drop a fakes
// file's tests from the test root. This walks src/fakes/ and fails if any file
// is missing from the aggregation block, so a future fake can't skip its tests
// unnoticed. (fs walk allowed in test scope; the capturing while is an iterator
// loop and its inner ifs are nested — neither ban-fs nor test-no-conditional
// flags it, same as the check-file guard.)
test "test root imports every fakes file" {
    const self_src = @embedFile("check.zig");
    var dir = try std.fs.cwd().openDir("src/fakes", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var missing_buf: [256]u8 = undefined;
    var missing_len: usize = 0;
    var needle_buf: [256]u8 = undefined;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const needle = try std.fmt.bufPrint(&needle_buf, "@import(\"fakes/{s}\")", .{entry.name});
        if (std.mem.indexOf(u8, self_src, needle) == null) {
            @memcpy(missing_buf[0..entry.name.len], entry.name);
            missing_len = entry.name.len;
            break;
        }
    }
    // A non-empty result names a fakes file missing from the block above.
    try std.testing.expectEqualStrings("", missing_buf[0..missing_len]);
}
