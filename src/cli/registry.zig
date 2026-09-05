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
const check_deprecated_alias = @import("../checks/deprecated_alias.zig");
const check_spec_quality = @import("../checks/spec_quality.zig");
const check_completeness = @import("../checks/completeness.zig");
const check_naming = @import("../checks/naming.zig");
const check_function_size = @import("../checks/function_size.zig");
const check_doc_comments = @import("../checks/doc_comments.zig");
const check_imports = @import("../checks/imports.zig");
const check_import_layering = @import("../checks/import_layering.zig");
// doc-quality folded into doc-comments (presence + quality in one walk).
const check_pub_api_surface = @import("../checks/pub_api_surface.zig");
const check_panic_budget = @import("../checks/panic_budget.zig");
const check_catch_discipline = @import("../checks/catch_discipline.zig");
const check_unwrap_discipline = @import("../checks/unwrap_discipline.zig");
const check_error_discipline = @import("../checks/error_discipline.zig");
const check_cognitive_complexity = @import("../checks/cognitive_complexity.zig");
const check_anytype_budget = @import("../checks/anytype_budget.zig");
const check_oom_discipline = @import("../checks/oom_discipline.zig");
const check_dead_pub = @import("../checks/dead_pub.zig");
const check_allocator_hygiene = @import("../checks/allocator_hygiene.zig");
const check_debug_print_ban = @import("../checks/debug_print_ban.zig");
const check_orphan_files = @import("../checks/orphan_files.zig");
const check_test_reachability = @import("../checks/test_reachability.zig");
const check_stub_body_ban = @import("../checks/stub_body_ban.zig");
const check_int_from_float_budget = @import("../checks/int_from_float_budget.zig");
const check_unsafe_ops_budget = @import("../checks/unsafe_ops_budget.zig");
const check_assert_density = @import("../checks/assert_density.zig");
const check_type_size = @import("../checks/type_size.zig");
const check_function_length = @import("../checks/function_length.zig");
const check_nesting_depth = @import("../checks/nesting_depth.zig");
const check_test_coverage = @import("../checks/test_coverage.zig");
const check_ban = @import("../checks/ban.zig");
const check_concept = @import("../checks/concept.zig");
const check_canonical_idiom = @import("../checks/canonical_idiom.zig");
const check_measure_vocabulary = @import("../checks/measure_vocabulary.zig");
const check_twin_parity = @import("../checks/twin_parity.zig");
const check_divergent_const = @import("../checks/divergent_const.zig");
const check_shadowed_const = @import("../checks/shadowed_const.zig");
const check_twin_referent = @import("../checks/twin_referent.zig");
const check_twin_drift = @import("../checks/twin_drift.zig");
const check_duplicate_json_key = @import("../checks/duplicate_json_key.zig");
const check_ban_time = @import("../checks/ban_time.zig");
const check_ban_rng = @import("../checks/ban_rng.zig");
const check_ban_fs = @import("../checks/ban_fs.zig");
const check_ban_net = @import("../checks/ban_net.zig");
const check_ban_env = @import("../checks/ban_env.zig");
const check_ban_sleep = @import("../checks/ban_sleep.zig");
const check_ban_globals = @import("../checks/ban_globals.zig");
const check_ban_hardcoded_paths = @import("../checks/ban_hardcoded_paths.zig");
const check_ban_secrets = @import("../checks/ban_secrets.zig");
const check_init_deinit_symmetry = @import("../checks/init_deinit_symmetry.zig");
const check_errdefer_in_init = @import("../checks/errdefer_in_init.zig");
const check_test_has_assertion = @import("../checks/test_has_assertion.zig");
const check_test_no_conditional = @import("../checks/test_no_conditional.zig");
const check_test_skip_ban = @import("../checks/test_skip_ban.zig");
const check_prod_imports_no_test = @import("../checks/no_test_imports_in_prod.zig");
const check_bool_ops_per_condition = @import("../checks/bool_ops_per_condition.zig");
const check_line_length = @import("../checks/line_length.zig");
const check_repeated_string_literal = @import("../checks/repeated_string_literal.zig");
const check_stack_escape = @import("../checks/stack_escape.zig");
const check_change_classification = @import("../checks/change_classification.zig");
const check_error_path_test = @import("../checks/error_path_testing.zig");
const check_test_erosion = @import("../checks/test_erosion.zig");
const check_assert_doc_consistency = @import("../checks/assert_doc_consistency.zig");
const check_fatal_exit = @import("../checks/fatal_exit.zig");
const check_fuzz_presence = @import("../checks/fuzz_presence.zig");
const check_concurrency_presence = @import("../checks/concurrency_presence.zig");
const check_script_string_safety = @import("../checks/script_string_safety.zig");
const check_dead_model_field = @import("../checks/dead_model_field.zig");
const check_projection_completeness = @import("../checks/projection_completeness.zig");
const check_module_doc_header = @import("../checks/module_doc_header.zig");
const check_external_gates = @import("../checks/external_gates.zig");
const check_policy_drift = @import("../checks/policy_drift.zig");
const check_merge_state = @import("../checks/merge_state.zig");
const check_must_return_ref = @import("../checks/must_return_ref.zig");
const check_pub_exposes_private = @import("../checks/pub_exposes_private.zig");
const check_compound_assert = @import("../checks/compound_assert.zig");
const check_try_in_return = @import("../checks/try_in_return.zig");
const check_abi_layout = @import("../checks/abi_layout.zig");
const check_undefined_init = @import("../checks/undefined_init.zig");
const check_import_resolution = @import("../checks/import_resolution.zig");
const cmd_mutate = @import("mutate.zig");
const cmd_optimize_divergence = @import("optimize_divergence.zig");
const cmd_debt = @import("debt.zig");

/// Spelled once: the registry entry, the whole-tree list and the change-subject
/// list all name this check, and three copies of one string is how they drift.
const change_classification_name = "change-classification";

pub const RunCtx = types.RunCtx;
pub const NeedsAst = types.NeedsAst;
pub const Command = types.Command;
pub const MergeInputs = types.MergeInputs;

pub const all: []const Command = &.{
    // First on purpose: the cheapest gate in the suite, and the one whose fix
    // is a single command. cli/run_all runs it before the rest and flushes its
    // output immediately, so a formatting slip never costs a whole run.
    .{
        .name = check_formatting.check_name,
        .summary = "Require every src file to match zig fmt output",
        .scope = .per_file,
        .subject = .tree,
        .run = check_formatting.run,
    },
    .{
        .name = "spec",
        .summary = "Verify SPEC.md \u{2194} // spec: tag coverage",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_spec.run,
    },
    .{
        .name = "spec-init",
        .summary = "Generate starter SPEC.md from pub fn signatures",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_spec_init.run,
    },
    .{
        .name = "mutate",
        .summary = "Mutation-test the suite (fast tier: changed lines; --full: whole tree)",
        .scope = .whole_tree,
        .subject = .change,
        .run = cmd_mutate.run,
    },
    .{
        .name = "optimize-divergence",
        .summary = "Run the suite under safe and fast; fail on divergence (nightly tier)",
        .scope = .whole_tree,
        .subject = .tree,
        .run = cmd_optimize_divergence.run,
    },
    .{
        .name = "debt",
        .summary = "Report baseline/snapshot debt totals with deltas (non-gating)",
        .scope = .whole_tree,
        .subject = .tree,
        .run = cmd_debt.run,
    },
    .{
        .name = "file-size",
        .summary = "Warn on large files; block extreme ones",
        .scope = .per_file,
        .subject = .tree,
        .run = check_file_size.run,
    },
    .{
        .name = "boundaries",
        .summary = "Enforce @import boundary rules",
        .scope = .per_file,
        .subject = .tree,
        .run = check_boundaries.run,
    },
    .{
        .name = "deprecated-alias",
        .summary = "Reject deprecated 0.15 std spellings " ++
            "(ArrayListUnmanaged, managed hashmaps, usingnamespace, getStdOut)",
        .scope = .per_file,
        .subject = .tree,
        .run = check_deprecated_alias.run,
    },
    .{
        .name = "spec-quality",
        .summary = "Lint SPEC.md prose for vague phrases and stub behaviors",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_spec_quality.run,
    },
    .{
        .name = "completeness",
        .summary = "Require each SPEC.md feature section to address or waive 8 scenario categories (opt-in)",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_completeness.run,
    },
    .{
        .name = "naming",
        .summary = "Enforce Zig naming conventions (PascalCase types, camelCase fns)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_naming.run,
    },
    .{
        .name = check_measure_vocabulary.check_name,
        .summary = "Report names that disagree about a unit or quantity kind (opt-in, advisory)",
        .needs_ast = .yes,
        // Per-file: every pair of names it judges is found inside ONE file (a
        // declaration, an assignment, a call whose callee that file declares),
        // so a diff-scoped run narrows it soundly.
        .scope = .per_file,
        .subject = .tree,
        .run = check_measure_vocabulary.run,
    },
    .{
        .name = "function-size",
        .summary = "Cap function parameter count",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_function_size.run,
    },
    .{
        .name = "doc-comments",
        .summary = "Require a real /// doc comment on every public fn/type (presence + quality)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_doc_comments.run,
    },
    .{
        .name = "imports",
        .summary = "Detect cycles in the @import graph",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_imports.run,
    },
    .{
        .name = "import-resolution",
        .summary = "Require every path-shaped @import to name a file that exists",
        // Whole-tree for the same reason as import-layering, from the other
        // side: the TARGET of an import is a file the diff need not have
        // touched. Deleting or renaming `src/b.zig` while leaving its importers
        // alone is exactly the break this catches, and a narrowed run would
        // never look at the importer.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_import_resolution.run,
    },
    .{
        .name = "import-layering",
        .summary = "Enforce project-declared import directions from [[layering]] entries",
        // Whole-tree, unlike its `[[ban]]` cousin: an edge's TARGET is a file
        // the diff need not have touched, so a narrowed graph would report a
        // forbidden import as resolved because the file it points at went out
        // of view. The graph is only meaningful whole.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_import_layering.run,
    },
    .{
        .name = "pub-api-surface",
        .summary = "Snapshot every pub fn/type; diff fails build",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_pub_api_surface.run,
    },
    .{
        .name = "panic-budget",
        .summary = "Cap @panic / unreachable / TODO / FIXME counts via snapshot",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_panic_budget.run,
    },
    .{
        .name = "catch-discipline",
        .summary = "Reject catch unreachable/undefined and empty catch blocks",
        .scope = .per_file,
        .subject = .tree,
        .run = check_catch_discipline.run,
    },
    .{
        .name = "unwrap-discipline",
        .summary = "Reject orelse unreachable / orelse undefined (crash-on-null)",
        .scope = .per_file,
        .subject = .tree,
        .run = check_unwrap_discipline.run,
    },
    .{
        .name = "error-discipline",
        .summary = "Require explicit error sets on pub fn",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_error_discipline.run,
    },
    .{
        .name = "cognitive-complexity",
        .summary = "Cap per-function cognitive complexity score",
        .scope = .per_file,
        .subject = .tree,
        .run = check_cognitive_complexity.run,
    },
    .{
        .name = "anytype-budget",
        .summary = "Cap anytype parameter count per file",
        .scope = .per_file,
        .subject = .tree,
        .run = check_anytype_budget.run,
    },
    .{
        .name = "dead-pub",
        .summary = "Flag unused public declarations",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_dead_pub.run,
    },
    .{
        .name = "allocator-hygiene",
        .summary = "Reject hardcoded global allocators outside main/test",
        .scope = .per_file,
        .subject = .tree,
        .run = check_allocator_hygiene.run,
    },
    .{
        .name = "debug-print-ban",
        .summary = "Reject std.debug.print(...) calls outside main/test",
        .scope = .per_file,
        .subject = .tree,
        .run = check_debug_print_ban.run,
    },
    .{
        .name = "orphan-files",
        .summary = "Flag .zig files under src/ unreachable from any configured root",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_orphan_files.run,
    },
    .{
        .name = "test-reachability",
        .summary = "Flag files whose test blocks no test root imports (they never compile)",
        // Reachability is a property of the whole import graph: a file's status
        // can flip because a file *outside* the diff dropped its import.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_test_reachability.run,
    },
    .{
        .name = "stub-body-ban",
        .summary = "Reject obvious stub function bodies " ++
            "(return undefined, placeholder panics, unreachable in value fns)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_stub_body_ban.run,
    },
    .{
        .name = "int-from-float-budget",
        .summary = "Track @intFromFloat call count via snapshot (new sites need a guard review)",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_int_from_float_budget.run,
    },
    .{
        .name = "unsafe-ops-budget",
        .summary = "Track unsafe-cast builtin and undefined re-assignment counts via snapshot",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_unsafe_ops_budget.run,
    },
    .{
        .name = check_assert_density.check_name,
        .summary = "Ratchet per-module assertion density upward (advisory, never blocks)",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_assert_density.run,
    },
    .{
        .name = "type-size",
        .summary = "Cap fields per pub struct/enum/union/opaque",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_type_size.run,
    },
    .{
        .name = "function-length",
        .summary = "Warn on long functions; block extreme ones",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_function_length.run,
    },
    .{
        .name = "nesting-depth",
        .summary = "Cap brace-nesting depth inside fn bodies",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_nesting_depth.run,
    },
    .{
        .name = "test-coverage",
        .summary = "Require every pub fn to be referenced from a test block (opt-in)",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_test_coverage.run,
    },
    .{
        .name = "ban",
        .summary = "Enforce project-declared banned symbol chains from [[ban]] entries",
        // Per-file like every other ban: each rule's verdict is a property of
        // the file it matched in, so a diff-scoped run may narrow it.
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban.run,
    },
    .{
        .name = "concept",
        .summary = "Flag a [[concept]] literal used outside the module that owns it",
        // Whole-tree even though each verdict is one file's: a rule's `files`
        // globs reach paths the parsed source index does not hold at all (JS,
        // CSS, TOML), so there is nothing for a diff-scoped run to narrow them
        // to — and narrowing only the source-set half would make the two halves
        // of one check disagree about how much they read.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_concept.run,
    },
    .{
        .name = "canonical-idiom",
        .summary = "Flag an [[idiom]] expression shape hand-rolled outside its canonical home",
        // Whole-tree for the same reason `concept` is: every rule carries a
        // `files` glob set, which reaches paths the parsed source index does not
        // hold at all (JS, CSS, TOML), so there is nothing for a diff-scoped run
        // to narrow the scan to.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_canonical_idiom.run,
    },
    .{
        .name = check_twin_parity.check_name,
        .summary = "Require a parity test for every capability a [[twin]] entry exposes on 2+ surfaces",
        // Whole-tree: the question is whether a test named in config exists
        // ANYWHERE, so a diff-scoped view would report every twin whose test
        // lives outside the diff as missing — the loudest possible false
        // positive on a one-file change.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_twin_parity.run,
    },
    .{
        .name = "divergent-const",
        .summary = "Flag one file-scope const name holding different values in two or more files",
        .needs_ast = .yes,
        // The subject is a NAME across the whole tree: a file the diff never
        // touched is half of every finding, and narrowing the scan would report
        // a divergence as resolved because its other side went out of view.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_divergent_const.run,
    },
    .{
        .name = "shadowed-const",
        .summary = "Flag a named constant's value reappearing as a bare literal in another file",
        .needs_ast = .yes,
        // Whole-tree for two independent reasons: a rule's referent is resolved
        // against every file's declarations (a narrowed index would report it
        // dangling), and the shadow itself is a relation between two files, so
        // narrowing to the changed one would report a live shadow as resolved.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_shadowed_const.run,
    },
    .{
        .name = "twin-referent",
        .summary = "Flag a mirrors/same-as comment whose named file or symbol does not resolve",
        .needs_ast = .yes,
        // Resolution reads the whole tree's files and declared identifiers, so a
        // narrowed index would report every referent outside the diff as dangling.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_twin_referent.run,
    },
    .{
        .name = check_twin_drift.check_name,
        .summary = "Flag two same-named functions in different files whose copied bodies have drifted apart",
        .needs_ast = .yes,
        // Whole-tree by construction: the other half of every pair lives in a
        // file the diff never touched — that is what makes the drift invisible
        // in the first place — so a narrowed index would report a live twin as
        // resolved the moment only one copy was edited.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_twin_drift.run,
    },
    .{
        .name = "duplicate-json-key",
        .summary = "Flag one JSON key written twice into the same object by one function",
        .needs_ast = .yes,
        // Each verdict is a property of the one function that wrote both keys,
        // so a diff-scoped run may narrow it like any other per-file check.
        .scope = .per_file,
        .subject = .tree,
        .run = check_duplicate_json_key.run,
    },
    .{
        .name = "ban-time",
        .summary = "Reject std.time wall-clock reads outside infra/clock",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_time.run,
    },
    .{
        .name = "ban-rng",
        .summary = "Reject RNG construction outside infra/random",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_rng.run,
    },
    .{
        .name = "ban-fs",
        .summary = "Reject std.fs I/O calls outside infra/fs",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_fs.run,
    },
    .{
        .name = "ban-net",
        .summary = "Reject std.net / std.http use outside adapters/http or infra/net",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_net.run,
    },
    .{
        .name = "ban-env",
        .summary = "Reject env-var reads outside config or main",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_env.run,
    },
    .{
        .name = "ban-sleep",
        .summary = "Reject sleep calls outside test infrastructure",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_sleep.run,
    },
    .{
        .name = "ban-globals",
        .summary = "Reject mutable pub var globals outside wiring/main",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_globals.run,
    },
    .{
        .name = "ban-hardcoded-paths",
        .summary = "Reject hardcoded absolute paths and URLs in string literals",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_hardcoded_paths.run,
    },
    .{
        .name = "ban-secrets",
        .summary = "Reject hardcoded credentials " ++
            "(known token formats + entropy-gated secret assignments)",
        .scope = .per_file,
        .subject = .tree,
        .run = check_ban_secrets.run,
    },
    .{
        .name = "init-deinit-symmetry",
        .summary = "Require pub deinit on structs that own an allocator field",
        .scope = .per_file,
        .subject = .tree,
        .run = check_init_deinit_symmetry.run,
    },
    .{
        .name = "errdefer-in-init",
        .summary = "Require errdefer between multiple try calls inside init",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_errdefer_in_init.run,
    },
    .{
        .name = "test-has-assertion",
        .summary = "Require every test block to contain at least one expect* call",
        .scope = .per_file,
        .subject = .tree,
        .run = check_test_has_assertion.run,
    },
    .{
        .name = "test-no-conditional",
        .summary = "Reject if/while/switch and extra for loops at the top level of a test body",
        .scope = .per_file,
        .subject = .tree,
        .run = check_test_no_conditional.run,
    },
    .{
        .name = "test-skip-ban",
        .summary = "Reject tests that are empty or unconditionally return error.SkipZigTest",
        .scope = .per_file,
        .subject = .tree,
        .run = check_test_skip_ban.run,
    },
    .{
        .name = "prod-imports-no-test",
        .summary = "Reject production code @import-ing test files",
        .scope = .per_file,
        .subject = .tree,
        .run = check_prod_imports_no_test.run,
    },
    .{
        .name = "bool-ops-per-condition",
        .summary = "Cap boolean operators per condition",
        .scope = .per_file,
        .subject = .tree,
        .run = check_bool_ops_per_condition.run,
    },
    .{
        .name = "line-length",
        .summary = "Warn on long lines; block extreme ones",
        .scope = .per_file,
        .subject = .tree,
        .run = check_line_length.run,
    },
    .{
        .name = "repeated-string-literal",
        .summary = "Reject 3+ repeats of a literal in a file and duplicate consts across files",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_repeated_string_literal.run,
    },
    .{
        .name = "stack-escape",
        .summary = "Reject returning the address of a stack local (dangling pointer)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_stack_escape.run,
    },
    .{
        .name = check_undefined_init.check_name,
        .summary = "Require a // SAFETY: justification for an undefined value (opt-in)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_undefined_init.run,
    },
    .{
        .name = check_must_return_ref.check_name,
        .summary = "Reject returning a capacity-owning container field by value (leaks a copy)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_must_return_ref.run,
    },
    .{
        .name = "pub-exposes-private",
        .summary = "Reject a pub fn signature naming a type or error set that is not pub",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_pub_exposes_private.run,
    },
    .{
        .name = "compound-assert",
        .summary = "Split a std.debug.assert conjunction into one assert per conjunct",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_compound_assert.run,
    },
    .{
        .name = "try-in-return",
        .summary = "Reject `return try <expr>` — bind the tried value to a local first",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_try_in_return.run,
    },
    // Both halves read one file at a time: the assertion must be co-located
    // with the struct it pins, and a field's packed type is resolved only in
    // the file that declares it. Nothing here consults another file, so a
    // diff-scoped run may narrow it without changing a verdict.
    .{
        .name = check_abi_layout.check_name,
        .summary = "Pin extern/packed struct layout and reject an unaligned wide packed field (ziglang/zig#23564)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_abi_layout.run,
    },
    .{
        .name = "assert-doc-consistency",
        .summary = "Require a body assert() in any fn whose doc claims an Asserts precondition",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_assert_doc_consistency.run,
    },
    .{
        .name = "fatal-exit",
        .summary = "Reject a hand-rolled std.process.exit(nonzero) outside the entry/fatal path",
        .scope = .per_file,
        .subject = .tree,
        .run = check_fatal_exit.run,
    },
    .{
        .name = change_classification_name,
        .summary = "Require a test or spec change alongside behavioral src changes (vs git ref)",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .subject = .change,
        .run = check_change_classification.run,
    },
    .{
        .name = "error-path-test",
        .summary = "Require a test naming each error path the change adds (vs git ref)",
        .needs_ast = .yes,
        .scope = .whole_tree,
        // Judges the diff, and cross-references it against every test in the
        // tree: neither half may be narrowed, and neither may be frozen.
        .subject = .change,
        .run = check_error_path_test.run,
    },
    .{
        .name = "test-erosion",
        .summary = "Report a change whose test count or assertion count went backwards (advisory)",
        .needs_ast = .yes,
        .scope = .whole_tree,
        .subject = .change,
        .run = check_test_erosion.run,
    },
    .{
        .name = "oom-discipline",
        .summary = "Flag allocation errors conflated with domain absence (opt-in)",
        .needs_ast = .yes,
        .scope = .per_file,
        .subject = .tree,
        .run = check_oom_discipline.run,
    },
    .{
        .name = "fuzz-presence",
        .summary = "Require a std.testing.fuzz call in each configured module (opt-in)",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_fuzz_presence.run,
    },
    .{
        .name = "concurrency-test-presence",
        .summary = "Require a concurrency test in each configured module (opt-in)",
        // Whole-tree like fuzz-presence: the verdict is over the config's own
        // path list, read from disk rather than from the parsed index, so a
        // diff-scoped run has nothing to narrow it to.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_concurrency_presence.run,
    },
    .{
        .name = "script-string-safety",
        .summary = "Flag a script-blob JSON serializer that escapes \" and \\ but not < (stored XSS; opt-in)",
        // Whole-tree like its lexical cousins concept/canonical-idiom: the
        // `blob_files` globs reach paths the parsed source index need not hold,
        // and the scan reads them from disk, so there is nothing for a
        // diff-scoped run to narrow it to.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_script_string_safety.run,
    },
    .{
        .name = "dead-model-field",
        .summary = "Flag a struct field surfaced in output but read by no enforcement path (opt-in)",
        .needs_ast = .yes,
        // Whole-tree like dead-pub: a field's liveness is a cross-file property
        // — its enforcing read can live in a file the diff never touched, so a
        // narrowed view would report a live field as dead.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_dead_model_field.run,
    },
    .{
        .name = check_projection_completeness.check_name,
        .summary = "Flag a struct literal that projects only part of a declared field bundle (opt-in)",
        .needs_ast = .yes,
        // Per-file: a literal is judged entirely on what it sets against the
        // rule's declared field list, so a narrowed view reaches the same
        // verdict for every file it holds. Nothing about the type's declaration
        // site or any other file changes the answer.
        .scope = .per_file,
        .subject = .tree,
        .run = check_projection_completeness.run,
    },
    .{
        .name = "module-doc-header",
        .summary = "Require a //! module doc header on src files over [module_doc_header] min_lines (default 200)",
        .scope = .per_file,
        .subject = .tree,
        .run = check_module_doc_header.run,
    },
    .{
        .name = "external-gates",
        .summary = "Run project-defined non-Zig argv gates from [[external]] entries",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_external_gates.run,
    },
    .{
        .name = "policy-drift",
        .summary = "Protect guardian.toml and accepted-debt files in trusted CI",
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_policy_drift.run,
    },
    .{
        .name = check_merge_state.check_name,
        .summary = "Reject .guardian metadata left unresolved or marked for regeneration by a merge",
        // The subject is the whole `.guardian/` tree, not any source file, so a
        // diff-scoped run must still read all of it: a conflicted baseline is
        // exactly as dangerous when the diff touches nothing near it.
        .scope = .whole_tree,
        .subject = .tree,
        .run = check_merge_state.run,
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
    .{ .name = "install-merge-driver", .summary = "Point this clone's git at the .guardian metadata merge driver" },
    .{ .name = "merge-file", .summary = "Merge one .guardian metadata file (git merge driver: %O %A %B)" },
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
    print("\nSingle-check introspection (read-only, writes nothing):\n", .{});
    print(row, .{ "--list", "one check's rows as NEW / LIVE / RESOLVED against its baseline" });
    print(row, .{ "--dry-run", "one check's current findings, unfiltered by any baseline" });
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
    "spec",                      "spec-init",       "mutate",
    "debt",                      "spec-quality",    "completeness",
    "imports",                   "pub-api-surface", "panic-budget",
    "dead-pub",                  "orphan-files",    "int-from-float-budget",
    "unsafe-ops-budget",         "test-coverage",   "repeated-string-literal",
    change_classification_name,  "fuzz-presence",   "external-gates",
    "concurrency-test-presence", "policy-drift",    "test-reachability",
    "merge-state",               "concept",         "canonical-idiom",
    "divergent-const",           "shadowed-const",  "twin-referent",
    "import-layering",           "twin-parity",     "script-string-safety",
    "dead-model-field",          "twin-drift",      "import-resolution",
    "error-path-test",           "test-erosion",    "assert-density",
};

/// Checks whose subject is the CHANGE UNDER REVIEW rather than the tree's
/// accumulated state: they read the diff against a base ref and judge what it
/// added. The baseline layer must never adopt their findings as a starting set
/// — that would freeze the defect the diff is introducing (see
/// `types.CheckSubject` and `baseline.refuseAdoption`). Asserted against the
/// registry below, exactly as `inherently_whole_tree` is, so a future edit
/// cannot quietly reclassify one. (Exhaustiveness the other way is a
/// compile-time property: `Command.subject` has no default.)
const change_subject = [_][]const u8{
    "mutate",
    change_classification_name,
    "error-path-test",
    "test-erosion",
};

/// True when every name in `change_subject` resolves to a registered check
/// classified `.change`.
fn changeSubjectClassificationHolds() bool {
    for (change_subject) |name| {
        const cmd = find(name) orelse return false;
        if (cmd.subject != .change) return false;
    }
    return true;
}

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

// spec: Diff Scoping - Classifies every diff-time check's subject as the change under review

test "the diff-time checks stay classified as change-subject" {
    try std.testing.expect(changeSubjectClassificationHolds());
    // The counterpart: a standing-debt check is `.tree`, so `accept` can still
    // record its findings as a starting set — that is what a baseline is for.
    try std.testing.expect(find("function-size").?.subject == .tree);
    try std.testing.expect(find("twin-drift").?.subject == .tree);
    try std.testing.expect(find("spec").?.subject == .tree);
}
