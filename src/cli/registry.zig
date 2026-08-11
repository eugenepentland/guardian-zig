//! The check registry: the `all` table mapping each CLI name to its one-line
//! summary and `run` fn, plus `find`/`summaryFor`/`printHelp`. Adding a check
//! here wires it everywhere (build_helper derives the gate list from this at
//! comptime). The composed commands (all/nightly/commit/explain/version) are
//! dispatched outside the table to avoid an @import cycle with run_all.

const std = @import("std");
const types = @import("types.zig");

const check_formatting = @import("../checks/formatting.zig");
const check_spec = @import("../checks/spec.zig");
const check_spec_init = @import("../checks/spec_init.zig");
const check_file_size = @import("../checks/file_size.zig");
const check_boundaries = @import("../checks/boundaries.zig");
const check_usingnamespace_ban = @import("../checks/usingnamespace_ban.zig");
const check_deprecated_alias = @import("../checks/deprecated_alias.zig");
const check_spec_quality = @import("../checks/spec_quality.zig");
const check_completeness = @import("../checks/completeness.zig");
const check_naming = @import("../checks/naming.zig");
const check_function_size = @import("../checks/function_size.zig");
const check_doc_comments = @import("../checks/doc_comments.zig");
const check_imports = @import("../checks/imports.zig");
// doc-quality folded into doc-comments (presence + quality in one walk).
const check_pub_api_surface = @import("../checks/pub_api_surface.zig");
const check_panic_budget = @import("../checks/panic_budget.zig");
const check_catch_discipline = @import("../checks/catch_discipline.zig");
const check_unwrap_discipline = @import("../checks/unwrap_discipline.zig");
const check_error_discipline = @import("../checks/error_discipline.zig");
const check_cognitive_complexity = @import("../checks/cognitive_complexity.zig");
const check_anytype_budget = @import("../checks/anytype_budget.zig");
const check_escape_discipline = @import("../checks/escape_discipline.zig");
const check_oom_discipline = @import("../checks/oom_discipline.zig");
const check_dead_pub = @import("../checks/dead_pub.zig");
const check_allocator_hygiene = @import("../checks/allocator_hygiene.zig");
const check_debug_print_ban = @import("../checks/debug_print_ban.zig");
const check_orphan_files = @import("../checks/orphan_files.zig");
const check_test_reachability = @import("../checks/test_reachability.zig");
const check_stub_body_ban = @import("../checks/stub_body_ban.zig");
const check_int_from_float_budget = @import("../checks/int_from_float_budget.zig");
const check_unsafe_ops_budget = @import("../checks/unsafe_ops_budget.zig");
const check_type_size = @import("../checks/type_size.zig");
const check_function_length = @import("../checks/function_length.zig");
const check_nesting_depth = @import("../checks/nesting_depth.zig");
const check_test_coverage = @import("../checks/test_coverage.zig");
const check_ban = @import("../checks/ban.zig");
const check_ban_time = @import("../checks/ban_time.zig");
const check_ban_rng = @import("../checks/ban_rng.zig");
const check_ban_fs = @import("../checks/ban_fs.zig");
const check_ban_net = @import("../checks/ban_net.zig");
const check_ban_env = @import("../checks/ban_env.zig");
const check_ban_sleep = @import("../checks/ban_sleep.zig");
const check_ban_globals = @import("../checks/ban_globals.zig");
const check_ban_hardcoded_paths = @import("../checks/ban_hardcoded_paths.zig");
const check_ban_secrets = @import("../checks/ban_secrets.zig");
const check_compile_error_explanation = @import("../checks/compile_error_explanation.zig");
const check_init_hygiene = @import("../checks/init_hygiene.zig");
const check_static_factory_ban = @import("../checks/static_factory_ban.zig");
const check_init_deinit_symmetry = @import("../checks/init_deinit_symmetry.zig");
const check_errdefer_in_init = @import("../checks/errdefer_in_init.zig");
const check_test_has_assertion = @import("../checks/test_has_assertion.zig");
const check_test_no_conditional = @import("../checks/test_no_conditional.zig");
const check_test_skip_ban = @import("../checks/test_skip_ban.zig");
const check_prod_imports_no_test = @import("../checks/no_test_imports_in_prod.zig");
const check_bool_ops_per_condition = @import("../checks/bool_ops_per_condition.zig");
const check_line_length = @import("../checks/line_length.zig");
const check_boolean_param_ban = @import("../checks/boolean_param_ban.zig");
const check_magic_number = @import("../checks/magic_number.zig");
const check_repeated_string_literal = @import("../checks/repeated_string_literal.zig");
const check_struct_method_cap = @import("../checks/struct_method_cap.zig");
const check_optional_density = @import("../checks/optional_density.zig");
const check_stringly_typed_switches = @import("../checks/stringly_typed_switches.zig");
const check_repeated_switch_on_enum = @import("../checks/repeated_switch_on_enum.zig");
const check_stack_escape = @import("../checks/stack_escape.zig");
const check_change_classification = @import("../checks/change_classification.zig");
const check_assert_doc_consistency = @import("../checks/assert_doc_consistency.zig");
const check_fatal_exit = @import("../checks/fatal_exit.zig");
const check_stdout_flush = @import("../checks/stdout_flush.zig");
const check_fuzz_presence = @import("../checks/fuzz_presence.zig");
const check_module_doc_header = @import("../checks/module_doc_header.zig");
const check_external_gates = @import("../checks/external_gates.zig");
const check_policy_drift = @import("../checks/policy_drift.zig");
const cmd_mutate = @import("mutate.zig");
const cmd_debt = @import("debt.zig");
const cmd_history = @import("history.zig");

pub const RunCtx = types.RunCtx;
pub const NeedsAst = types.NeedsAst;
pub const Command = types.Command;

pub const all: []const Command = &.{
    // First on purpose: the cheapest gate in the suite, and the one whose fix
    // is a single command. cli/run_all runs it before the rest and flushes its
    // output immediately, so a formatting slip never costs a whole run.
    .{
        .name = check_formatting.check_name,
        .summary = "Require every src file to match zig fmt output",
        .scope = .per_file,
        .run = check_formatting.run,
    },
    .{
        .name = "spec",
        .summary = "Verify SPEC.md \u{2194} // spec: tag coverage",
        .scope = .whole_tree,
        .run = check_spec.run,
    },
    .{
        .name = "spec-init",
        .summary = "Generate starter SPEC.md from pub fn signatures",
        .scope = .whole_tree,
        .run = check_spec_init.run,
    },
    .{
        .name = "mutate",
        .summary = "Mutation-test the suite (fast tier: changed lines; --full: whole tree)",
        .scope = .whole_tree,
        .run = cmd_mutate.run,
    },
    .{
        .name = "debt",
        .summary = "Report baseline/snapshot debt totals with deltas (non-gating)",
        .scope = .whole_tree,
        .run = cmd_debt.run,
    },
    // whole_tree because it reads one whole artifact — the append-only run log
    // — and answers about every run in it. A diff-scoped run must never hand it
    // a narrowed view: "96% of runs are green" is a statement about the log's
    // entire contents or it is a lie.
    .{
        .name = cmd_history.command_name,
        .summary = "Report gate outcomes, durations, and failing checks from the run log (non-gating)",
        .scope = .whole_tree,
        .run = cmd_history.run,
    },
    .{
        .name = "file-size",
        .summary = "Warn on large files; block extreme ones",
        .scope = .per_file,
        .run = check_file_size.run,
    },
    .{
        .name = "boundaries",
        .summary = "Enforce @import boundary rules",
        .scope = .per_file,
        .run = check_boundaries.run,
    },
    .{
        .name = "usingnamespace-ban",
        .summary = "Reject usingnamespace declarations in src/",
        .scope = .per_file,
        .run = check_usingnamespace_ban.run,
    },
    .{
        .name = "deprecated-alias",
        .summary = "Reject deprecated 0.15 std spellings " ++
            "(ArrayListUnmanaged, managed hashmaps, usingnamespace, getStdOut)",
        .scope = .per_file,
        .run = check_deprecated_alias.run,
    },
    .{
        .name = "spec-quality",
        .summary = "Lint SPEC.md prose for vague phrases and stub behaviors",
        .scope = .whole_tree,
        .run = check_spec_quality.run,
    },
    .{
        .name = "completeness",
        .summary = "Require each SPEC.md feature section to address or waive 8 scenario categories (opt-in)",
        .scope = .whole_tree,
        .run = check_completeness.run,
    },
    .{
        .name = "naming",
        .summary = "Enforce Zig naming conventions (PascalCase types, camelCase fns)",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_naming.run,
    },
    .{
        .name = "function-size",
        .summary = "Cap function parameter count",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_function_size.run,
    },
    .{
        .name = "doc-comments",
        .summary = "Require a real /// doc comment on every public fn/type (presence + quality)",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_doc_comments.run,
    },
    .{
        .name = "imports",
        .summary = "Detect cycles in the @import graph",
        .scope = .whole_tree,
        .run = check_imports.run,
    },
    .{
        .name = "pub-api-surface",
        .summary = "Snapshot every pub fn/type; diff fails build",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .run = check_pub_api_surface.run,
    },
    .{
        .name = "panic-budget",
        .summary = "Cap @panic / unreachable / TODO / FIXME counts via snapshot",
        .scope = .whole_tree,
        .run = check_panic_budget.run,
    },
    .{
        .name = "catch-discipline",
        .summary = "Reject catch unreachable/undefined and empty catch blocks",
        .scope = .per_file,
        .run = check_catch_discipline.run,
    },
    .{
        .name = "unwrap-discipline",
        .summary = "Reject orelse unreachable / orelse undefined (crash-on-null)",
        .scope = .per_file,
        .run = check_unwrap_discipline.run,
    },
    .{
        .name = "error-discipline",
        .summary = "Require explicit error sets on pub fn",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_error_discipline.run,
    },
    .{
        .name = "cognitive-complexity",
        .summary = "Cap per-function cognitive complexity score",
        .scope = .per_file,
        .run = check_cognitive_complexity.run,
    },
    .{
        .name = "anytype-budget",
        .summary = "Cap anytype parameter count per file",
        .scope = .per_file,
        .run = check_anytype_budget.run,
    },
    .{
        .name = "dead-pub",
        .summary = "Flag unused public declarations",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .run = check_dead_pub.run,
    },
    .{
        .name = "allocator-hygiene",
        .summary = "Reject hardcoded global allocators outside main/test",
        .scope = .per_file,
        .run = check_allocator_hygiene.run,
    },
    .{
        .name = "debug-print-ban",
        .summary = "Reject std.debug.print(...) calls outside main/test",
        .scope = .per_file,
        .run = check_debug_print_ban.run,
    },
    .{
        .name = "orphan-files",
        .summary = "Flag .zig files under src/ unreachable from any configured root",
        .scope = .whole_tree,
        .run = check_orphan_files.run,
    },
    .{
        .name = "test-reachability",
        .summary = "Flag files whose test blocks no test root imports (they never compile)",
        // Reachability is a property of the whole import graph: a file's status
        // can flip because a file *outside* the diff dropped its import.
        .scope = .whole_tree,
        .run = check_test_reachability.run,
    },
    .{
        .name = "stub-body-ban",
        .summary = "Reject obvious stub function bodies " ++
            "(return undefined, placeholder panics, unreachable in value fns)",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_stub_body_ban.run,
    },
    .{
        .name = "int-from-float-budget",
        .summary = "Track @intFromFloat call count via snapshot (new sites need a guard review)",
        .scope = .whole_tree,
        .run = check_int_from_float_budget.run,
    },
    .{
        .name = "unsafe-ops-budget",
        .summary = "Track unsafe-cast builtin and undefined re-assignment counts via snapshot",
        .scope = .whole_tree,
        .run = check_unsafe_ops_budget.run,
    },
    .{
        .name = "type-size",
        .summary = "Cap fields per pub struct/enum/union/opaque",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_type_size.run,
    },
    .{
        .name = "function-length",
        .summary = "Warn on long functions; block extreme ones",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_function_length.run,
    },
    .{
        .name = "nesting-depth",
        .summary = "Cap brace-nesting depth inside fn bodies",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_nesting_depth.run,
    },
    .{
        .name = "test-coverage",
        .summary = "Require every pub fn to be referenced from a test block (opt-in)",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .run = check_test_coverage.run,
    },
    .{
        .name = "ban",
        .summary = "Enforce project-declared banned symbol chains from [[ban]] entries",
        // Per-file like every other ban: each rule's verdict is a property of
        // the file it matched in, so a diff-scoped run may narrow it.
        .scope = .per_file,
        .run = check_ban.run,
    },
    .{
        .name = "ban-time",
        .summary = "Reject std.time wall-clock reads outside infra/clock",
        .scope = .per_file,
        .run = check_ban_time.run,
    },
    .{
        .name = "ban-rng",
        .summary = "Reject RNG construction outside infra/random",
        .scope = .per_file,
        .run = check_ban_rng.run,
    },
    .{
        .name = "ban-fs",
        .summary = "Reject std.fs I/O calls outside infra/fs",
        .scope = .per_file,
        .run = check_ban_fs.run,
    },
    .{
        .name = "ban-net",
        .summary = "Reject std.net / std.http use outside adapters/http or infra/net",
        .scope = .per_file,
        .run = check_ban_net.run,
    },
    .{
        .name = "ban-env",
        .summary = "Reject env-var reads outside config or main",
        .scope = .per_file,
        .run = check_ban_env.run,
    },
    .{
        .name = "ban-sleep",
        .summary = "Reject sleep calls outside test infrastructure",
        .scope = .per_file,
        .run = check_ban_sleep.run,
    },
    .{
        .name = "ban-globals",
        .summary = "Reject mutable pub var globals outside wiring/main",
        .scope = .per_file,
        .run = check_ban_globals.run,
    },
    .{
        .name = "ban-hardcoded-paths",
        .summary = "Reject hardcoded absolute paths and URLs in string literals",
        .scope = .per_file,
        .run = check_ban_hardcoded_paths.run,
    },
    .{
        .name = "ban-secrets",
        .summary = "Reject hardcoded credentials " ++
            "(known token formats + entropy-gated secret assignments)",
        .scope = .per_file,
        .run = check_ban_secrets.run,
    },
    .{
        .name = "compile-error-explanation",
        .summary = "Reject @compileError without a non-empty string explanation",
        .scope = .per_file,
        .run = check_compile_error_explanation.run,
    },
    .{
        .name = "init-hygiene",
        .summary = "Reject init bodies with loops, conditionals, or switch statements",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_init_hygiene.run,
    },
    .{
        .name = "static-factory-ban",
        .summary = "Reject static factory / singleton patterns in business logic",
        .scope = .per_file,
        .run = check_static_factory_ban.run,
    },
    .{
        .name = "init-deinit-symmetry",
        .summary = "Require pub deinit on structs that own an allocator field",
        .scope = .per_file,
        .run = check_init_deinit_symmetry.run,
    },
    .{
        .name = "errdefer-in-init",
        .summary = "Require errdefer between multiple try calls inside init",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_errdefer_in_init.run,
    },
    .{
        .name = "test-has-assertion",
        .summary = "Require every test block to contain at least one expect* call",
        .scope = .per_file,
        .run = check_test_has_assertion.run,
    },
    .{
        .name = "test-no-conditional",
        .summary = "Reject if/while/switch and extra for loops at the top level of a test body",
        .scope = .per_file,
        .run = check_test_no_conditional.run,
    },
    .{
        .name = "test-skip-ban",
        .summary = "Reject tests that are empty or unconditionally return error.SkipZigTest",
        .scope = .per_file,
        .run = check_test_skip_ban.run,
    },
    .{
        .name = "prod-imports-no-test",
        .summary = "Reject production code @import-ing test files",
        .scope = .per_file,
        .run = check_prod_imports_no_test.run,
    },
    .{
        .name = "bool-ops-per-condition",
        .summary = "Cap boolean operators per condition",
        .scope = .per_file,
        .run = check_bool_ops_per_condition.run,
    },
    .{
        .name = "line-length",
        .summary = "Warn on long lines; block extreme ones",
        .scope = .per_file,
        .run = check_line_length.run,
    },
    .{
        .name = "boolean-param-ban",
        .summary = "Reject bool parameters in public functions",
        .scope = .per_file,
        .run = check_boolean_param_ban.run,
    },
    .{
        .name = "magic-number",
        .summary = "Reject bare integer literals outside a small allowlist",
        .scope = .per_file,
        .run = check_magic_number.run,
    },
    .{
        .name = "repeated-string-literal",
        .summary = "Reject 3+ repeats of a literal in a file and duplicate consts across files",
        .scope = .whole_tree,
        .run = check_repeated_string_literal.run,
    },
    .{
        .name = "struct-method-cap",
        .summary = "Cap pub fn methods per pub struct/enum/union",
        .scope = .per_file,
        .run = check_struct_method_cap.run,
    },
    .{
        .name = "optional-density",
        .summary = "Cap percentage of optional fields in a public struct",
        .scope = .per_file,
        .run = check_optional_density.run,
    },
    .{
        .name = "stringly-typed-switches",
        .summary = "Reject switch expressions whose case keys are string literals",
        .scope = .per_file,
        .run = check_stringly_typed_switches.run,
    },
    .{
        .name = "repeated-switch-on-enum",
        .summary = "Flag the same enum dot-prong set switched in 2+ files",
        .scope = .whole_tree,
        .run = check_repeated_switch_on_enum.run,
    },
    .{
        .name = "stack-escape",
        .summary = "Reject returning the address of a stack local (dangling pointer)",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_stack_escape.run,
    },
    .{
        .name = "assert-doc-consistency",
        .summary = "Require a body assert() in any fn whose doc claims an Asserts precondition",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_assert_doc_consistency.run,
    },
    .{
        .name = "fatal-exit",
        .summary = "Reject a hand-rolled std.process.exit(nonzero) outside the entry/fatal path",
        .scope = .per_file,
        .run = check_fatal_exit.run,
    },
    .{
        .name = "stdout-flush",
        .summary = "A buffered stdout/stderr writer with no reachable flush; gates only if [stdout_flush] enabled",
        .scope = .per_file,
        .run = check_stdout_flush.run,
    },
    .{
        .name = "change-classification",
        .summary = "Require a test or spec change alongside behavioral src changes (vs git ref)",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .run = check_change_classification.run,
    },
    .{
        .name = "escape-discipline",
        .summary = "Flag raw {s} interpolation into HTML/SVG markup (opt-in)",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_escape_discipline.run,
    },
    .{
        .name = "oom-discipline",
        .summary = "Flag allocation errors conflated with domain absence (opt-in)",
        .needs_ast = .yes,
        .scope = .per_file,
        .run = check_oom_discipline.run,
    },
    .{
        .name = "fuzz-presence",
        .summary = "Require a std.testing.fuzz call in each configured module (opt-in)",
        .scope = .whole_tree,
        .run = check_fuzz_presence.run,
    },
    .{
        .name = "module-doc-header",
        .summary = "Require a //! module doc header on src files over [module_doc_header] min_lines (default 200)",
        .scope = .per_file,
        .run = check_module_doc_header.run,
    },
    .{
        .name = "external-gates",
        .summary = "Run project-defined non-Zig argv gates from [[external]] entries",
        .scope = .whole_tree,
        .run = check_external_gates.run,
    },
    .{
        .name = "policy-drift",
        .summary = "Protect guardian.toml and accepted-debt files in trusted CI",
        .scope = .whole_tree,
        .run = check_policy_drift.run,
    },
};

/// Look up a command by its CLI name; null if not registered.
pub fn find(name: []const u8) ?Command {
    for (all) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

// Commands dispatched specially by check.zig rather than through this registry:
// the `all` aggregate, the composed `nightly` tier, and the informational
// explain/version. They can't be registry entries — their run functions would
// close an @import cycle with run_all — so they are listed here by hand.
const meta_commands = [_]struct { name: []const u8, summary: []const u8 }{
    .{ .name = "all", .summary = "Run every hard-block check (filter with --only/--skip a,b)" },
    .{ .name = "nightly", .summary = "Full suite + whole-tree mutation ratchet (scheduled/CI tier)" },
    .{ .name = "commit", .summary = "Gate the tree, then auto-commit the change set with --intent" },
    .{ .name = "install-hook", .summary = "Write a pre-commit hook that runs the blocking gate" },
    .{ .name = "explain", .summary = "Explain a check: why it blocks, how to fix, how to exempt" },
    .{ .name = "doctor", .summary = "Audit Guardian metadata/integration health (read-only)" },
    .{ .name = "spec-sync", .summary = "Suggest missing SPEC.md bullets without editing files" },
    .{ .name = "test-filter", .summary = "Report the diff-derived test-name filter for local runs (never gates)" },
    .{ .name = "accept", .summary = "Preview, accept, and verify named baseline/snapshot drift" },
    .{ .name = "bench", .summary = "Record, list, or remove measured metrics in the benchmark ledger" },
    .{ .name = "size", .summary = "Print one file's current measurements against their caps and ratchet ceilings" },
    .{ .name = "version", .summary = "Print the guardian-check version (also --version)" },
};

/// One-line summary for `name` from either the check registry or the specially
/// dispatched meta commands (all/nightly/commit/explain/version); null when the
/// name is neither. Lets `explain` resolve a documented meta command that — to
/// avoid an @import cycle — is not a registry entry.
pub fn summaryFor(name: []const u8) ?[]const u8 {
    if (find(name)) |cmd| return cmd.summary;
    for (meta_commands) |m| if (std.mem.eql(u8, m.name, name)) return m.summary;
    return null;
}

/// Print the usage summary enumerating every registered command plus the
/// specially-dispatched meta commands.
pub fn printHelp() void {
    const print = std.debug.print;
    const row = "  {s: <14} {s}\n";
    print("Usage: guardian-check <command> [project-dir] [--quiet|--summary(default)|--verbose]\n\n", .{});
    print("Commands:\n", .{});
    for (all) |cmd| print(row, .{ cmd.name, cmd.summary });
    print("\nMeta commands (composed / informational):\n", .{});
    for (meta_commands) |m| print(row, .{ m.name, m.summary });
}

/// Checks whose verdict is inherently whole-tree — cross-file graphs and
/// duplicate scans, tree-wide snapshots and budgets, coverage and spec/tag
/// maps, the diff-driven process gates, and the non-gate commands. Diff
/// scoping must never narrow one of these to the changed files, so the list is
/// asserted against the registry below and a future edit cannot quietly
/// reclassify one as `per_file`. (Exhaustiveness in the other direction is a
/// compile-time property: `Command.scope` has no default, so a newly
/// registered check must classify itself.)
const inherently_whole_tree = [_][]const u8{
    "spec",                    "spec-init",               "mutate",
    "debt",                    "history",                 "spec-quality",
    "completeness",            "imports",                 "pub-api-surface",
    "panic-budget",            "dead-pub",                "orphan-files",
    "int-from-float-budget",   "unsafe-ops-budget",       "test-coverage",
    "repeated-string-literal", "repeated-switch-on-enum", "change-classification",
    "fuzz-presence",           "external-gates",          "policy-drift",
    "test-reachability",
};

/// True when every name in `inherently_whole_tree` resolves to a registered
/// check classified `.whole_tree`. Factored out of the test so the loop isn't
/// a conditional in a test body.
fn wholeTreeClassificationHolds() bool {
    for (inherently_whole_tree) |name| {
        const cmd = find(name) orelse return false;
        if (cmd.scope != .whole_tree) return false;
    }
    return true;
}

// spec: Diff Scoping - Classifies every cross-file and tree-wide check as whole-tree

test "the inherently whole-tree checks stay classified whole_tree" {
    try std.testing.expect(wholeTreeClassificationHolds());
    // The counterpart: a per-file shape/style check is narrowable, which is
    // where the whole speedup comes from.
    try std.testing.expect(find("line-length").?.scope == .per_file);
    try std.testing.expect(find("naming").?.scope == .per_file);
    try std.testing.expect(find("cognitive-complexity").?.scope == .per_file);
}
