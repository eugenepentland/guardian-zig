//! `explain <check>` — long-form rationale for a check: why it blocks (the
//! AI-agent mistake it catches), how to fix a violation, and how to exempt it.
//! With no name — or an unknown one — it lists every registered command. The
//! one-line summary is pulled from the registry; the prose lives here as a
//! name→text table so registry.zig stays lean.
//!
//! `explain completeness --section <name>` is the one data-driven variant: it
//! answers "what would this `## ` section need?" against the CURRENT SPEC.md,
//! so adding a new section stops being a guess that costs a whole build to
//! verify. It reads, never writes, and is not a gate.
//!
//! Dispatched specially by check.zig (never a gate), so it may import the
//! registry without forming a cycle. Every registered command must have an
//! entry here — a unit test walks the registry and fails on any gap.

const std = @import("std");
const registry = @import("registry.zig");
const completeness = @import("../checks/completeness.zig");

const print = std.debug.print;

/// The check whose `--section` dry run is implemented; naming it once keeps the
/// argument rejection and the dispatch from drifting apart.
const section_check = "completeness";

/// One check's long-form explanation, keyed by its registry name.
const Entry = struct {
    name: []const u8,
    text: []const u8,
};

// Each entry answers three questions: Why it blocks (the agent mistake), how to
// Fix a real violation, and how to Exempt it (the guardian.toml knob, snapshot
// refresh, or top-level `disabled` list). Prose sits in `\\` multiline literals
// so it is exempt from the line-length cap.
const entries = [_]Entry{
    .{ .name = "formatting", .text =
    \\Why: an agent hand-edits a file and leaves it in a shape `zig fmt` would
    \\rewrite, so every later diff carries formatting noise. It is also the
    \\cheapest gate in the suite, so it runs FIRST and prints immediately — a
    \\formatting slip costs seconds instead of a whole run.
    \\Fix: run the `zig fmt <file>` command printed under the finding; the line
    \\reported is where the file first diverges from canonical output.
    \\Exempt: list the path in the top-level `exclude` globs, or put
    \\"formatting" in the top-level `disabled` list (a vendored tree kept
    \\verbatim is the only good reason).
    },
    .{ .name = "spec", .text =
    \\Why: an agent adds a behavior but never writes — or mistags — its test, so
    \\SPEC.md and the suite silently drift apart.
    \\Fix: give every SPEC.md `- ` bullet exactly one `// spec: <Section> -
    \\<bullet>` tag sitting directly on a test; delete orphan/duplicate tags.
    \\Exempt: none — the 1:1 map is the workflow. Remove the bullet if the
    \\behavior is truly gone.
    },
    .{ .name = "spec-init", .text =
    \\Why: not a gate — the generator that seeds a starter SPEC.md from your
    \\`pub fn` signatures so onboarding isn't a blank page.
    \\Fix: run `zig build spec-init`, then replace the placeholder bullets with
    \\real behavior descriptions.
    \\Exempt: n/a — it only runs when you invoke it.
    },
    .{ .name = "mutate", .text =
    \\Why: not a gate — static checks prove tests exist; `mutate` proves they
    \\bite by splicing small deliberate bugs and checking the suite catches them.
    \\Fix: for each surviving mutant, strengthen the test to assert the exact
    \\value the mutation changed, not merely that the call succeeded. Survivors
    \\print file:line, the operator swap, and the original line; the same land in
    \\`.guardian/cache/last-mutate.jsonl` for an agent to read.
    \\Exempt: tune `[mutation] min_score_pct` / `min_mutants` (runs below the
    \\viable-mutant floor report but don't gate) / `max_mutants`; waive a genuinely
    \\equivalent mutant with a `// mutate-ok: <reason>` line. Repeat runs reuse the
    \\per-mutant result cache; a snapshot refresh bypasses it. Run the fast tier
    \\(`zig build mutate`) on PRs and `mutate-full` in nightly.
    },
    .{ .name = "debt", .text =
    \\Why: not a gate — a report of accumulated ratchet debt (per-check baseline
    \\counts, snapshot totals, mutation score) so frozen debt growth is a visible
    \\decision, not a side effect smeared across `.guardian/` churn commits. It
    \\also prints an informational assert-density table: assert() calls per KLOC
    \\per top-level src module, ascending, to surface the most assert-starved code.
    \\Fix: nothing to fix — it always exits 0. Use it to decide what to pay down;
    \\the delta column shows the change vs the committed `.guardian/` state.
    \\Exempt: n/a — run `guardian-check debt [dir]`; never part of `all`.
    },
    .{ .name = "file-size", .text =
    \\Why: agents let a file grow unbounded, concentrating unrelated concerns
    \\where every future edit risks a merge conflict or a stray regression.
    \\Metric: a CODE line is a non-blank, non-comment line outside `test { ... }`
    \\blocks. Comments and blanks were counted once, which made deleting doc
    \\comments the cheapest way to buy headroom — a gate that rewards removing
    \\explanation. They no longer count, so only moving code moves the number
    \\(`guardian-check size <file> .` reads it back without a gate run).
    \\Finding: files above `max_file_lines` warn; only files above
    \\`hard_max_file_lines` block. Split along a cohesive module seam. At 95% of
    \\the hard limit the file also draws one NEAR HARD CAP line, printed even
    \\when the run collapses the advisory tier to a count — the last warning
    \\before a crossing lands mid-feature on whoever adds the next line.
    \\Hysteresis (on by default, `[hysteresis]`): crossing the hard cap TRIPS
    \\this file and cannot be accepted — no env var, no ceiling raise. The trip
    \\is then remembered below the cap: the entry follows the file down (every
    \\shrink lands green, even while still over), growth blocks, and the trip
    \\clears only at the recover line, `recover_pct` under the cap (10000 →
    \\8000 at the default 20). `guardian-check debt . --live` prints each
    \\tripped key and what is left to fall.
    \\Exempt: adjust either limit, list a glob in `file_size_exclude`, drop the
    \\check from `[hysteresis] checks` (or set `enabled = false`) to restore
    \\plain ratchet behavior, or disable it via the top-level `disabled` list.
    },
    .{ .name = "boundaries", .text =
    \\Why: an agent reaches across an architectural layer (core importing utils),
    \\eroding the module boundaries the design depends on.
    \\Fix: invert the dependency or route through the allowed module; remove the
    \\forbidden `@import`.
    \\Exempt: edit or drop the offending `[[boundary]]` rule in guardian.toml.
    },
    .{ .name = "deprecated-alias", .text =
    \\Why: Zig 0.15 renamed a batch of std containers/idioms and kept the old
    \\names as `/// Deprecated` aliases. `std.ArrayListUnmanaged` (= `std.ArrayList`
    \\today), `std.array_list.Managed`, `usingnamespace` (removed from the grammar),
    \\and the pre-Writergate `getStdOut`/`getStdErr` all compile now but are a
    \\guaranteed tree-wide breaking diff on 0.16 — and agents trained on older Zig
    \\reach for them by reflex. Managed `std.StringHashMap`/`AutoHashMap`(+Array)
    \\are not deprecated, only discouraged (std moved to the unmanaged maps that
    \\keep the allocator on the owning struct); they ride this check because
    \\`[[allow]]` is a clean per-path opt-out. Detection is lexical, so a banned
    \\name inside a string/comment is never flagged.
    \\Fix: std.ArrayListUnmanaged -> std.ArrayList; managed std.*HashMap(...) ->
    \\the *Unmanaged map, passing the allocator per call (`put(gpa, k, v)`,
    \\`deinit(gpa)`) with an `= .empty` decl-literal init; drop usingnamespace for
    \\explicit re-exports (`pub const x = mod.x;`); getStdOut/getStdErr ->
    \\std.fs.File.stdout()/stderr() + a buffered writer with an explicit flush().
    \\Exempt: add a `[[allow]] check = "deprecated-alias"` path glob in
    \\guardian.toml (the C-ABI/vendor escape hatch — e.g. a file that mirrors an
    \\old API on purpose), or drop the check via the top-level `disabled` list.
    },
    .{ .name = "spec-quality", .text =
    \\Why: vague spec bullets ("handles input properly") can't drive a real test,
    \\so the 1:1 map becomes theater.
    \\Fix: rewrite the bullet to state a concrete, observable behavior of at
    \\least the minimum length.
    \\Exempt: tune `[spec_quality] forbidden_phrases`, or disable the section.
    },
    .{ .name = "completeness", .text =
    \\Why (opt-in): an agent writes a happy-path spec and never considers the
    \\scenario classes that ship the most bugs — empty/large inputs, overflow,
    \\I/O failure, unauthorized/concurrent access, malformed encoding, panics.
    \\Fix: for each `## ` feature section in SPEC.md, add a `- ` bullet whose
    \\prose addresses each of the 8 categories (the 1:1 map then forces a test),
    \\or waive one explicitly: `- completeness-waiver: <category> (<reason>)`
    \\with a non-empty reason. A bullet addresses a category when its prose
    \\contains any one of that category's keywords, listed below.
    \\Dry run: `guardian-check explain completeness --section "<name>" [dir]`
    \\prints that section's standing against the CURRENT SPEC.md — which
    \\categories are already addressed, which are waived, and which are still
    \\missing — or, for a section that does not exist yet, the paste-ready
    \\skeleton. Adding a new `## ` section no longer costs a build to verify.
    \\Exempt: off unless `[completeness] enabled = true`; list non-feature
    \\sections (Overview, Changelog) in `[completeness] exempt_sections`.
    },
    .{ .name = "naming", .text =
    \\Why: agents bleed Rust/Python/C casing into Zig or reach for placeholder
    \\names (tmp/data/Manager) that describe nothing. Zig std reserves
    \\SCREAMING_SNAKE for C/OS-ABI mirrors (~97% of its all-caps hits) — a plain
    \\const is snake_case (`std.fs.max_path_bytes`).
    \\Fix: PascalCase iff a fn returns `type`; camelCase fns; PascalCase types;
    \\snake_case container-scope consts (PascalCase when the value is a type);
    \\rename vague identifiers to something concrete.
    \\Exempt: a genuine C-ABI-mirror file whose SCREAMING casing matches the
    \\foreign API opts out via `[[allow]] check = "naming"` path globs in
    \\guardian.toml; or drop the whole check via the top-level `disabled` list
    \\(the retired `vague-name-blacklist` name is tolerated there too).
    },
    .{ .name = "function-size", .text =
    \\Scope: this is the PARAMETER-COUNT check — "size" means how many runtime
    \\arguments a fn takes, not how long it is. For line count see
    \\`explain function-length`.
    \\Why: a runtime parameter list that keeps growing signals an agent bolting
    \\on args instead of bundling related inputs — each call site gets more
    \\fragile. `comptime` specialization parameters are reported but excluded,
    \\and the finding states both counts ("has 7 runtime params (+1 comptime)").
    \\Fix: group related runtime parameters into an options/context struct.
    \\Exempt: raise `[function_size] max_params`, or disable the check.
    },
    .{ .name = "doc-comments", .text =
    \\Why: agents ship a public API with no doc comment — or a placeholder one —
    \\leaving the next reader (human or model) to guess the contract.
    \\Fix: add a real doc comment (>= min_chars) to every pub fn/type stating
    \\what it does.
    \\Exempt: add trivial names to `[doc_quality] exempt_names` (deinit/format/
    \\next/reset are exempt by default), or lower `min_chars`.
    },
    .{ .name = "imports", .text =
    \\Why: a cycle in the `@import` graph makes modules impossible to reason about
    \\or reuse in isolation — an easy accident when an agent wires two files.
    \\Scope: this is the CYCLE check — a structural illness, derived from the
    \\graph alone, exempt from nothing. Directional layer rules ("core may not
    \\import serve") are the separate, configured `import-layering` check.
    \\Fix: extract the shared types into a third module, or invert one edge.
    \\Exempt: none — cycles are always a defect. Break the loop.
    },
    .{ .name = "import-layering", .text =
    \\Scope: this is the DIRECTION check, not the cycle one. A layering edge is
    \\perfectly acyclic and compiles fine; it is wrong only because you declared
    \\which way your layers point. `imports` (cycles) reads no config and exempts
    \\nothing; this one reads `[[layering]]` and exempts what you say it may.
    \\Why: an agent — or a hurried refactor — reaches UP a layer because the
    \\helper it wants happens to live there. Measured in eda (2026-08-14): a
    \\core-layer `src/kicad_pcb/import_layout_command.zig` importing
    \\`src/serve/pcb_layout_import.zig`, because sidecar persistence lives in
    \\serve/ — acyclic, so `imports` passed, and nothing else could say a word.
    \\Declare one:
    \\  [[layering]]
    \\  name = "core-no-serve"          # kebab-case, unique; names the violation
    \\  from = ["src/kicad_pcb/*"]      # the files the rule constrains
    \\  to   = ["src/serve/*"]          # what they may not import
    \\  allow = ["src/kicad_pcb/serve_adapter.zig"]  # the sanctioned adapter
    \\  reason = "the format layer must not reach up into the web layer"
    \\Every key but `allow` is required: a rule with no `from`/`to` matches no
    \\edge and a rule with no `reason` leaves a violation nobody can act on, so
    \\both are config errors rather than entries that sit there enforcing
    \\nothing.
    \\Fix: invert the dependency, or move the shared type into a module BOTH
    \\layers may import — the same extraction the cycle check asks for, done
    \\before there is a cycle. The rule's `reason` is the half of the message
    \\worth reading, which is why a rule cannot omit it.
    \\Matching: on RESOLVED, project-relative paths. `import_graph` normalizes
    \\every edge against the importing file's directory, so the
    \\`../serve/pcb_layout_import.zig` a core file actually writes is matched as
    \\`src/serve/pcb_layout_import.zig` — the only spelling a `to` glob could be
    \\written against. `std`, `builtin`, `root` and package imports are not
    \\paths and are never candidates. Patterns are Guardian's ordinary globs:
    \\`*` is the wildcard and a pattern without one is a plain substring.
    \\Ratcheting a coupling surface down: this is what the per-EDGE baseline is
    \\for. eda's serve/ imports placement internals across 38 files (35 of them
    \\straight into a 12.3k-line optimizer.zig); declare the rule, let baseline
    \\mode freeze today's 38 edges, and the 39th fails while the count only
    \\falls as files move onto the extracted types.
    \\Exempt: add the path to that rule's `allow`, narrow its `from` / `to`,
    \\exempt a file from every rule with `[[allow]] check = "import-layering"`
    \\(the top-level `exclude` list drops it too), or delete the rule.
    \\Baseline: one violation per (rule, source file, target file), keyed
    \\`<rule>|<from>|<to>` — the EDGE, not the file. A file with two forbidden
    \\imports is two rows, so removing one lands green while the other stays
    \\frozen; a per-file key would freeze the file whole and hide the second.
    },
    .{ .name = "pub-api-surface", .text =
    \\Why: an agent silently widens (or breaks) the public API — a new pub fn, a
    \\changed signature — with no reviewer sign-off.
    \\Fix: make the API change intentional, then accept it into the snapshot.
    \\Exempt: `zig build guardian-accept -Dguardian-checks=pub-api-surface`
    \\and commit `.guardian/` once the surface change is deliberate. The raw CLI
    \\fallback is `guardian-check accept pub-api-surface .`; `pub-api` — the
    \\basename of `.guardian/pub-api.txt` — is accepted as an alias for the name.
    \\Read the report by group: `~` is one signature edited in place, `moved:` is
    \\the same signature under a different file (neither new nor removed), and
    \\`+`/`-` are the one-sided entries.
    },
    .{ .name = "panic-budget", .text =
    \\Why: agents scatter `@panic` / `unreachable` / `TODO` / `FIXME` as they
    \\stub, turning recoverable paths into crashes.
    \\Fix: handle the case explicitly (return an error) instead of panicking, or
    \\resolve the TODO.
    \\Exempt: `zig build guardian-accept -Dguardian-checks=panic-budget` to
    \\accept a deliberate new site, verify it, and commit the snapshot.
    },
    .{ .name = "catch-discipline", .text =
    \\Why: `catch unreachable`, `catch {}` and `catch undefined` convert a real
    \\error into a crash, silent swallow, or UB — a classic agent shortcut.
    \\Fix: handle the error with a `switch`, a named `catch |e|` body, or a
    \\deliberate return. When the same file already handles an error properly the
    \\finding quotes that shape and line ("this file already uses `catch return`
    \\at line 765") — copy it rather than inventing a new policy.
    \\Exempt: none in src/; test blocks are already exempt.
    },
    .{ .name = "unwrap-discipline", .text =
    \\Why: `orelse unreachable` / `orelse undefined` crashes (or invokes UB) the
    \\instant an optional the agent assumed was set is null.
    \\Fix: handle the null branch explicitly, or prove non-null with a preceding
    \\check and comment.
    \\Exempt: none in src/; test blocks are already exempt.
    },
    .{ .name = "error-discipline", .text =
    \\Why: an inferred `!T` or `anyerror!T` on a pub fn hides the real failure
    \\modes from callers, so agents can't reason about what to handle.
    \\Fix: declare an explicit error set: `pub fn f() MyError!T`.
    \\Exempt: `main` and `anytype`-param (writer) fns are already skipped;
    \\otherwise name the set.
    },
    .{ .name = "cognitive-complexity", .text =
    \\Why: deeply tangled control flow is where agents (and humans) introduce
    \\off-by-one and missed-branch bugs.
    \\Fix: extract helpers, flatten nesting, replace flag threading with early
    \\returns.
    \\Exempt: raise `[complexity] max_score`, or disable the check.
    },
    .{ .name = "anytype-budget", .text =
    \\Why: over-using `anytype` erases type information, so mistakes surface as
    \\confusing comptime errors far from the cause.
    \\Fix: give parameters concrete types; reserve `anytype` for genuine
    \\writer/formatter boundaries. When factoring two `comptime fmt: []const u8,
    \\args: anytype` entry points onto one helper would ADD a third anytype pair,
    \\pass the formatted result down instead: the shared helper takes the
    \\`BufPrintError![]const u8` (or the rendered slice) and the fmt+args stay at
    \\the two call sites, so the budget falls instead of rising.
    \\Exempt: raise `[anytype_budget] max_per_file`, or list the file in
    \\`[anytype_budget] exclude`.
    },
    .{ .name = "dead-pub", .text =
    \\Why: an agent leaves a `pub fn`/`pub const` referenced nowhere — dead
    \\surface that misleads future callers and rots.
    \\Fix: delete it, or make it non-pub if it's an internal helper.
    \\Exempt: set `[dead_pub] ignore_test_refs` to tune test-only liveness, or
    \\disable the check.
    },
    .{ .name = "allocator-hygiene", .text =
    \\Why: a hardcoded global allocator (page_allocator, GPA, testing.allocator)
    \\outside main/test defeats injection and hides leaks.
    \\Fix: thread an `Allocator` parameter from the entry point instead.
    \\Exempt: annotate a deliberate site with a `// allocator-ok:` comment.
    },
    .{ .name = "debug-print-ban", .text =
    \\Why: `std.debug.print` / `std.log.*` left in production is stray trace
    \\output an agent forgot to remove.
    \\Fix: route user-facing output through your reporter, or delete the trace.
    \\Exempt: allowed in `pub fn main`, tests, and `cli/*`/`commands*` modules;
    \\extra paths via `[[allow]] check = "debug-print-ban"`.
    },
    .{ .name = "orphan-files", .text =
    \\Why: a .zig file reachable from no root is dead code — or, worse, tests an
    \\agent wrote that never actually run.
    \\Fix: `@import` it from a reachable module (or the test root), or delete it.
    \\Exempt: declare explicit roots in `[orphan_files] roots`, or disable.
    },
    .{ .name = "test-reachability", .text =
    \\Why: Zig only compiles the tests it can reach. A file nobody imports from
    \\the test root contributes no `test` blocks to the test binary, so its tests
    \\never run — and the spec check still counts their `// spec:` tags as
    \\satisfied. The suite reads green while nothing verifies the behavior (eda:
    \\six files, 29 dead tests, found only by accident during a mutation run).
    \\Fix: put the file in a test root's @import chain — usually one line,
    \\`_ = @import("path/to/file.zig");` inside the root's aggregator test block.
    \\The finding names how many test blocks are currently dead.
    \\Exempt: name your real roots in `[test_reachability] roots` (Guardian's own
    \\root is src/check.zig, not a main.zig), or set `enabled = false`. The check
    \\skips itself when no root resolves, so it never blocks a project it cannot
    \\measure.
    },
    .{ .name = "stub-body-ban", .text =
    \\Why: a single-statement `return undefined` / placeholder `@panic` /
    \\`unreachable` body is an agent's unfinished stub masquerading as done.
    \\Fix: implement the real body, or return a proper error until it exists.
    \\Exempt: none — finish the function. Disable only during migration.
    },
    .{ .name = "int-from-float-budget", .text =
    \\Why: every new `@intFromFloat` is a lossy cast that silently mishandles NaN
    \\/ out-of-range values unless guarded.
    \\Fix: clamp/validate the float and document the range before casting — or
    \\route it through a guard fn that checks isFinite+range in float space first
    \\(eda's `numeric.checkedInt` is the model consumer, guarding 95 raw sites vs
    \\10 today). Name that fn in `[int_from_float] guard_fns = ["checkedInt"]` and
    \\casts in its body stop counting toward the budget — the wrapper IS the guard.
    \\Optional strict mode: `[int_from_float] require_guard = ["src/render/*"]`
    \\hard-fails ANY unguarded cast under those path globs, so a chosen subtree can
    \\be driven to zero (independent of the snapshot budget).
    \\Exempt: `zig build guardian-accept -Dguardian-checks=int-from-float-budget`
    \\after guard review, then commit the verified snapshot.
    },
    .{ .name = "unsafe-ops-budget", .text =
    \\Why: new `@ptrCast`/`@bitCast`/`@ptrFromInt`/… or `undefined` re-assignments
    \\are unsafe operations agents reach for to make types line up.
    \\Fix: prefer a safe conversion; if genuinely needed, isolate and comment it.
    \\Exempt: `zig build guardian-accept -Dguardian-checks=unsafe-ops-budget` to
    \\accept the new count and commit the verified snapshot.
    },
    .{ .name = "type-size", .text =
    \\Why: a struct that keeps gaining fields is a god-object an agent grew
    \\instead of decomposing.
    \\Fix: split the type along cohesion lines into smaller structs.
    \\Exempt: raise `[type_size] max_fields`, or list the file in
    \\`[type_size] exclude` for legitimate flat config bags.
    },
    .{ .name = "function-length", .text =
    \\Why: an ever-longer function is where agents append logic rather than
    \\factor it — the hardest place to review a change safely.
    \\Finding: functions above `max_lines` warn; only those above
    \\`hard_max_lines` block. Extract cohesive blocks into named helpers. At 95%
    \\of the hard limit the function draws one NEAR HARD CAP line, printed even
    \\when the run collapses the advisory tier to a count.
    \\Hysteresis (on by default, `[hysteresis]`): crossing `hard_max_lines`
    \\TRIPS the function and cannot be accepted. While tripped the entry only
    \\ever shrinks — growth blocks with no accept to reach for — and the trip
    \\clears at the recover line, `recover_pct` under the cap (400 → 320 at the
    \\default 20).
    \\Exempt: adjust either `[function_length]` limit, drop the check from
    \\`[hysteresis] checks` to restore plain ratchet behavior, or disable it.
    },
    .{ .name = "nesting-depth", .text =
    \\Why: deep brace nesting hides the branch an agent forgot to handle.
    \\Fix: early-return guard clauses, or extract the inner block into a helper.
    \\Exempt: raise `[nesting_depth] max_depth`, or disable the check.
    },
    .{ .name = "test-coverage", .text =
    \\Why (opt-in): a pub fn referenced by no test is behavior an agent shipped
    \\with zero executable proof.
    \\Fix: add a test that references the function.
    \\Exempt: list entry points in `[test_coverage] exempt_names`; the check is
    \\off unless `[test_coverage] enabled = true`.
    },
    .{ .name = "ban", .text =
    \\Why: the compiled ban-* checks are Guardian's opinions (clock, RNG, fs);
    \\this one is YOURS. It enforces the `[[ban]]` entries in guardian.toml, for
    \\the case those checks can't reach: a call that must route through a
    \\wrapper, a third-party symbol one layer may not touch. Making a struct
    \\field non-defaulted gets the same effect only when you own the callee's
    \\signature — a cross-layer or third-party symbol has no such trick.
    \\Declare one:
    \\  [[ban]]
    \\  chain = ["optimizer", "placeFromPoses"]  # bans optimizer.placeFromPoses
    \\  paths = ["src/serve/*"]                  # where (omit = the whole tree)
    \\  allow = ["src/serve/route_seed.zig"]     # the sanctioned wrapper itself
    \\  reason = "call through RouteSeed instead"
    \\Fix: call the alternative the rule's `reason` names — it is the half of the
    \\message worth reading, so a rule without one says so in every violation.
    \\Exempt: add the path to that rule's `allow`, narrow its `paths`, exempt a
    \\file from every rule with `[[allow]] check = "ban"`, or delete the rule.
    \\Uses inside a `test {…}` block and inside `pub fn main` are already allowed,
    \\as in every ban-* check.
    \\Limits: matching is TEXTUAL over identifier tokens, exactly like ban-time
    \\and friends — `chain = ["a", "b"]` matches the token sequence `a.b`, and
    \\one identifier per segment ("a.b" in a single segment is a config error).
    \\There is no alias resolution: `const p = optimizer.placeFromPoses;` is
    \\caught where it is written (any reference counts, not just calls), but a
    \\later `p(board)` in another file is not. A symbol reached through a renamed
    \\import (`const opt = @import("optimizer.zig"); opt.placeFromPoses()`) needs
    \\its own rule for that spelling. Chains inside strings/comments never match.
    },
    .{ .name = "concept", .text =
    \\Why: a set of magic spellings that model ONE domain fact gets hand-copied
    \\outward until the copies disagree. The motivating case: a PCB tool's layer
    \\names ("F.Cu", "In1.Cu"), the hexes its viewer paints them with, and the
    \\Gerber suffixes it writes them to, duplicated across ~40 sites in Zig, JS
    \\and CSS. Every other check here is per-item (one file, one function); this
    \\one is relational — the literal has a HOME, and anywhere else is drift.
    \\`[[ban]]` cannot say it: it matches Zig identifier chains, not text, and
    \\never opens a .css file. Declare one:
    \\  [[concept]]
    \\  name = "layer-names"               # kebab-case, unique; names the violation
    \\  literals = ["F.Cu", "B.Cu"]        # exact substrings
    \\  patterns = ["In*.Cu"]              # `*` = 1+ chars, never leaving one token
    \\  owner = ["src/board_layers.zig"]   # where the spelling is allowed to live
    \\  files = ["src/*.zig", "*.css"]     # optional scan set (any extension)
    \\  require_in = ["assets/viewer.js"]  # mirrors that must spell EVERY literal
    \\  literals_from = { file = "src/drc/kind.zig", fragments = ["=> \""] }
    \\  reason = "layer names come from board_layers.LayerTable"
    \\Fix: import the value from the owner module instead of respelling it. The
    \\violation names the concept, every occurrence line (up to five) WITH the
    \\text that matched on each — the concrete `In1.Cu`, not the `In*.Cu` that
    \\found it — the owner, and the rule's `reason`, which is the half worth
    \\reading, so a rule without one says so in every violation.
    \\Choosing `owner`: the vocabulary has to physically live where every
    \\consumer can IMPORT it, so pick a LEAF of the import graph — usually NOT
    \\the module with the best-known predicate. A module the predicate's home
    \\already imports cannot import it back (the `imports` check fails the
    \\cycle), so the obvious owner is often the one half the tree cannot reach.
    \\`owner` is a LIST: naming both the predicate's home and the leaf that
    \\physically holds the literals is the intended shape, not a loosened rule.
    \\Under `[baseline] deny_growth = ["concept"]`, plan the landing site BEFORE
    \\the refactor: a fix must land in an owner or in a file already baselined
    \\for that rule, because extracting a shared helper into a FRESH file adds a
    \\baseline row, which is growth, and the gate refuses it.
    \\A vendored or minified bundle a rule keeps matching belongs in that rule's
    \\`owner` list (or in `[[allow]] check = "concept"`) — the owner list doubles
    \\as the exclusion list, and nobody edits three.min.js to stop a wildcard
    \\from matching it.
    \\Exempt: add the path to that rule's `owner`, narrow its `literals` /
    \\`patterns` / `files`, exempt a file from every rule with
    \\`[[allow]] check = "concept"`, or delete the rule. guardian.toml itself and
    \\`.guardian/` are always exempt — the declaration names its own literals.
    \\Limits: matching is LEXICAL (plain text), on purpose — drift crosses
    \\languages and no parser spans them. Exactly three contexts are blanked
    \\before matching: a line whose first non-whitespace opens `//` (so `///`
    \\and `//!`), a line-leading `/* … */` block in a `.css` file, and a whole
    \\Zig `test { … }` block wherever a parse tree was available. Nothing else —
    \\a TRAILING comment of either shape shares a code line and that line counts
    \\whole, because judging it needs the per-language string lexer this check
    \\refuses to be (`"https://…"`). String CONTENTS always count: a spelling
    \\inside a quoted string is the main thing this check exists to find. A
    \\rule's `files` globs scope THAT rule alone — they are its domain, not
    \\"also scan these". `*` matches one or more characters that are not
    \\whitespace, a quote, or structural punctuation (`,;=:(){}[]`), so a pattern
    \\never spans two tokens, a newline, or minified code; `*` is the only
    \\metacharacter (`.` and `#` are literal), and a run of them collapses to one.
    \\A `files` glob never descends into a dot-directory, `zig-out`, or
    \\`node_modules`, and a glob that names nothing is silence — a project may
    \\declare the concept before the owner exists.
    \\`require_in` is the SAME relation read the other way. `owner` is permissive
    \\(only these files may spell it); `require_in` is total (each of THESE files
    \\must spell EVERY literal of the family, or the mirror has gone quietly out
    \\of date). The case it exists for: a DRC kind string renamed in Zig
    \\(eda, 2026-08-12, commit 51bff373) left the viewer's hand-mirrored JS branch
    \\dead — 531 grep-marker tests missed it because no marker watched that
    \\string, and the JS side's 8-entry `DRC_BLOCK` gate table fails PERMISSIVELY
    \\on a rename (an unrecognised kind simply stops blocking). A `require_in`
    \\file is owner-equivalent, so it is never also reported as drift; `patterns`
    \\are excluded (a wildcard names a shape, not a spelling a mirror could hold);
    \\a literal surviving only in a comment does NOT satisfy the requirement,
    \\since the same blanking applies; and a `require_in` glob that names no file
    \\is itself a violation — unlike a `files` glob, whose silence only narrows a
    \\scan, a vacuous requirement is exactly the permissive failure this key kills.
    \\`literals_from` makes the family TOTAL instead of a snapshot. A hand-written
    \\`literals` list stops covering an enum the day a variant is added — the new
    \\wire string joins no family, so no mirror is ever asked for it. Point it at
    \\the emitting source and every double-quoted string on a line carrying ALL
    \\the `fragments` joins the family (union with `literals`, deduped, comment
    \\lines blanked first, escapes NOT resolved — the spelling as written is what
    \\a mirror copies). `file` and a non-empty `fragments` are both required, and
    \\an unreadable file or an extraction that yields nothing is a violation, not
    \\a shrug: an empty family passes every mirror.
    \\Baseline: one violation per (file, concept), keyed `<file>|<name>` — NOT by
    \\the literal or the count. So a baselined offender file is frozen as a
    \\whole, a NEW file fails, and a second drifted literal inside an
    \\already-frozen file stays frozen. The other three rows are keyed for their
    \\own subjects: a missing mirror literal is `<rule>|<literal>|<file>` (so
    \\learning one of three spellings resolves exactly that row), an unmatched
    \\mirror glob is `<rule>|require_in|<glob>`, and a failed extraction is
    \\`<rule>|literals_from`. Freeze the counts too with
    \\`[baseline] deny_growth = ["concept"]`.
    },
    .{ .name = "canonical-idiom", .text =
    \\Why: an EXPRESSION SHAPE with one canonical implementation gets re-derived
    \\from scratch everywhere else, because the shape has no name to search for.
    \\Measured in eda on 2026-08-14, every one of them with the canonical version
    \\already in the tree: 51 sites splitting a sub-block leaf by hand with
    \\`lastIndexOfScalar(u8, <x>, '/')` under 8 different function names, 6
    \\byte-identical `urlDecodeAlloc` wrappers around
    \\`std.Uri.percentDecodeInPlace`, 8 private tmp+rename atomic writes, and ~24
    \\private JSON escaper loops in 7 incompatible tiers despite json_writer.zig.
    \\`[[ban]]` owns a NAME and cannot say it — banning `lastIndexOfScalar` would
    \\reject every legitimate use of the same std call — and `[[concept]]` owns a
    \\LITERAL, of which there is none here. Declare one:
    \\  [[idiom]]
    \\  name = "subblock-leaf-split"          # kebab-case, unique; names the violation
    \\  fragments = ["lastIndexOfScalar", "'/'"]   # ALL must appear on ONE line
    \\  files = ["src/*.zig"]                 # optional scan set; this is the default
    \\  allow = ["src/subblock.zig"]          # the canonical implementation's home
    \\  reason = "call subblock.leafOf()"     # REQUIRED — names what to call instead
    \\Fix: call what the `reason` names. The violation gives the file, the first
    \\matching line, the column the leftmost fragment starts at, and how many
    \\lines in that file match, so a 51-site cleanup can be worked file by file.
    \\Writing a rule: `fragments` is a CONJUNCTION, and that is the whole design.
    \\One fragment is nearly always either too broad to turn on (`lastIndexOfScalar`
    \\alone) or so specific it is really a `[[concept]]` literal; two narrow a
    \\common std call back down to the one expression that means the idiom. Tune a
    \\new rule with `guardian-check canonical-idiom . --dry-run`, which prints
    \\every current finding and writes no baseline.
    \\`reason` is required here, unlike `[[ban]]`/`[[concept]]` where it is merely
    \\recommended: "you hand-rolled a shape" is unactionable without the name of
    \\the thing to call, so a rule omitting it is a config error, not a violation
    \\with a placeholder.
    \\Exempt: add the path to that rule's `allow` (which is also where the
    \\canonical implementation itself must be listed — somebody has to write the
    \\shape once), narrow its `fragments` / `files`, exempt a file from every rule
    \\with `[[allow]] check = "canonical-idiom"`, or delete the rule.
    \\guardian.toml and `.guardian/` are always exempt — the rule's own
    \\declaration writes its fragments on one line.
    \\Limits: matching is LEXICAL (plain text) and SINGLE-LINE. No regex — a rule
    \\a reader cannot evaluate in their head is a rule they cannot trust — so
    \\every fragment is a plain substring. Multi-line idioms are deliberately out
    \\of scope: a shape spread over four lines has no stable textual form, and the
    \\scan splits on `\n` before looking, so fragments satisfied on ADJACENT lines
    \\never match. Blanked before matching, exactly as in `concept`: a line whose
    \\first non-whitespace opens `//`, a line-leading `/* … */` block in a `.css`
    \\file, and a whole Zig `test { … }` block wherever a parse tree was available
    \\— so the migration comment that quotes the idiom, and the golden test that
    \\pins the canonical helper against it, are not themselves reported. A
    \\TRAILING comment shares a code line and that line counts whole. `files`
    \\defaults to `["src/*.zig"]`, and note Guardian's `*` spans `/`: `src/*.zig`
    \\already means the whole `src` subtree, while a `src/**/*.zig` spelling would
    \\read as "requires an intermediate directory" and miss `src/main.zig`.
    \\Baseline: one violation per (rule, file), keyed `<name>|<file>` — NOT by the
    \\line or the count, so moving a site down a file never churns the ledger. The
    \\rule comes FIRST (where `concept` puts the file first) because an idiom's
    \\ledger is read the other way round: "which files still hand-roll THIS
    \\shape", 51 of them at a time, so a sorted baseline groups one rule's whole
    \\cleanup campaign together. A baselined file is frozen as a whole and a NEW
    \\file fails; freeze the counts too with
    \\`[baseline] deny_growth = ["canonical-idiom"]`.
    },
    .{ .name = "twin-parity", .text =
    \\Why: one capability reachable on several surfaces — a CLI subcommand, an
    \\HTTP route, an MCP tool — is several implementations of one answer, and
    \\nothing in a compiler can see that they are meant to agree. They share no
    \\type, no call, often no file, so they drift while every surface keeps
    \\passing its own tests. Measured in eda (2026-08-14): ~19 capabilities on 2+
    \\surfaces, exactly ONE with a test asserting the surfaces return the same
    \\bytes — and the reimplemented pairs had already diverged into different
    \\BOM-merge gating, different clamps, and different JSON for one field.
    \\Declare one:
    \\  [[twin]]
    \\  name = "export-pdf"                       # kebab-case, unique
    \\  surfaces = ["cli:export-pdf", "http:/api/schematic-pdf", "mcp:export_pdf"]
    \\  parity_test = "pdf export matches"        # substring of the test's name
    \\Fix: write the test `parity_test` names — one call per surface, asserting
    \\the same bytes — or point `parity_test` at the test that already does.
    \\Two rules, and only one of them is a ratchet. A twin that NAMES a
    \\`parity_test` must have it: a test named in config and absent from the tree
    \\is a rename nobody propagated or a deletion nobody noticed, never an
    \\intention, so that one always blocks. A twin that names none is reported as
    \\`twin-uncovered`, one row per twin, so today's uncovered set freezes in the
    \\baseline and can only shrink — add `[baseline] deny_growth = ["twin-parity"]`
    \\and a row that LOSES its parity_test is growth the gate refuses.
    \\Exempt: there is no path exemption to reach for — the subject is a config
    \\entry, not a file. Delete the `[[twin]]` row if the capability genuinely
    \\has one implementation, or add it to the `disabled` list to turn the whole
    \\registry off.
    \\Limits: `surfaces` are FREE-FORM labels and nothing resolves them — this
    \\check has no idea what an MCP tool is, and a per-surface resolver would
    \\make the registry unwritable for projects shaped differently. What the
    \\count buys is real: fewer than two surfaces is a config error, because a
    \\capability with one implementation has nothing to disagree with. Matching a
    \\`parity_test` is CONTAINMENT against declared test names, not equality, so
    \\a clarifying rename ("…, including the cover page") does not red the gate.
    \\The scan walks `.zig` files under `src/` and `test/` — the tests ON DISK,
    \\never the compiled test set, exactly as the spec check's tag scan does, so
    \\a -Dtest-filter build sees the same list. Unnamed `test { }` blocks are
    \\skipped: there is no text a parity_test could match them by. Nothing here
    \\proves the test is any GOOD — it proves a named test exists, which is the
    \\difference between a registry that decays and one that does not.
    \\Baseline: `<kind> <name>` — `parity export-pdf` for the missing test,
    \\`uncovered export-pdf` for the unproven twin. Keyed apart on purpose (the
    \\same split `divergent-const` makes between `const <name>` and
    \\`mirror <file>|<name>`): one shared key would let a FROZEN uncovered row
    \\absorb the missing-test failure the moment someone adds a `parity_test`
    \\pointing at a test that does not exist, turning the rule that must always
    \\block into the one that never does.
    },
    .{ .name = "divergent-const", .text =
    \\Why: one file-scope const NAME holds DIFFERENT values in two files, so two
    \\call sites that read as one fact do not behave as one. Measured in eda:
    \\`silk_stroke_mm` 0.12 in the Gerber writer and 0.15 in the .kicad_mod
    \\writer (two silkscreens from one board), `max_footprint_bytes` 1 MiB in
    \\four readers and 256 KiB in two (loads in the editor, fails in the
    \\preview), `max_board_bytes` 64 vs 48 MiB — 24 names in all. Guardian helps
    \\create this debt: naming a literal pushes it into a const and
    \\nothing then looks across files. Note the POLARITY — unlike
    \\repeated-string-literal's cross-file rule, same name + same value is the
    \\harmless case here; same name + different value is the risk.
    \\Fix: give the two files one const and import it from the module that owns
    \\the fact. If the copy is deliberate (a dependency-light mirror), annotate
    \\it and it becomes a CHECKED copy instead:
    \\  /// mirror-of: src/board/limits.zig.max_blob_bytes
    \\  const max_blob_bytes = 1024;
    \\An annotated const is exempt from the divergence rule and must instead
    \\EQUAL its referent — a stronger guarantee, verified whatever the mode and
    \\ignore list say.
    \\Exempt: `[divergent_const] ignore_names = ["eps", "margin"]` for generic
    \\names that legitimately differ per module, `[[allow]] check =
    \\"divergent-const"` for a path, or the `disabled` list.
    \\Limits: only FILE-SCOPE consts are read — a const inside a container is
    \\namespaced by it, and a const inside a function is local by construction.
    \\Values are compared FOLDED, so `16 << 20`, `16 * 1024 * 1024` and
    \\`16_777_216` are one value and `1_000_000` equals `1_000_000.0`; an
    \\initializer that does not fold to a number (a call, an identifier, a
    \\division — which means different things to ints and floats) is skipped
    \\entirely. Default `mode = "units"` groups only names whose trailing
    \\`_`-separated segment is a unit (`_mm`, `_bytes`, `_ms`, `_hz`, …), which
    \\is where a silent disagreement actually ships; `mode = "all"` groups every
    \\name.
    \\Baseline: one violation per NAME, keyed `const <name>` — not per file, so a
    \\third disagreeing copy joins the existing row instead of arriving as a new
    \\violation. A broken mirror is keyed `mirror <file>|<name>` instead: that
    \\one IS a single site's own claim.
    },
    .{ .name = "shadowed-const", .text =
    \\Why: a value that already HAS a name reappears somewhere else as a BARE
    \\literal — divergent-const's blind spot, and the reason a clean
    \\divergent-const run is not the same as a consistent tree: it compares one
    \\NAME across files, so a copy that never got a name is invisible to it.
    \\Measured in eda (2026-08-14) with divergent-const at zero rows:
    \\`export_fab.zig` declares `auto_outline_margin_mm = 1.0` while
    \\`placement/pour.zig` and `placement/route_free_space.zig` each re-derive
    \\the same rectangle from a bare `1.0` (one comment reads "Replicated here
    \\to avoid an import cycle"), so changing the constant silently desyncs the
    \\pour raster from the Edge.Cuts outline; three files hold a `1e-6`
    \\clearance epsilon under three different names; a `0.05` mm sampling step
    \\sits bare in two files; a 16 MiB sidecar cap is spelled four ways with one
    \\256 MiB outlier.
    \\Fix: import the constant instead of respelling its value. If the copy must
    \\stay local (a real import cycle), give it a NAME and a
    \\`/// mirror-of: <path>.zig.<name>` annotation — divergent-const then
    \\verifies the two are equal, which is the checked version of the comment.
    \\Declare the gate:
    \\  [[shadow]]
    \\  const = "src/export_fab.zig.auto_outline_margin_mm"  # <path>.zig.<name>
    \\  files = ["src/placement/*.zig"]   # optional; default is every src file
    \\  ignore = ["src/placement/vendor*"]
    \\  reason = "the pour raster must follow the same Edge.Cuts outline"
    \\Zero rules is a zero-config pass. A declared rule is an author's claim, so
    \\it is verified whatever the auto-mode noise controls say, and a rule whose
    \\referent resolves to nothing is ITSELF a violation (as a dangling
    \\twin-referent claim is) — a rule that silently matches nothing reads as a
    \\guarantee and is not one.
    \\Modes: `declared` (default) is the precise gate — only the [[shadow]]
    \\rules. `[shadowed_const] mode = "auto"` is a MEASUREMENT tier: it sweeps
    \\every unit-suffixed file-scope const (divergent-const's default
    \\population) and reports bare occurrences of each value elsewhere. Use it
    \\to size the problem, not to gate — the motivating case above proves the
    \\difference, since `1.0` is on `ignore_values` and the sweep cannot see it.
    \\Auto-mode noise controls: `ignore_values` (folded compare, default
    \\["0","1","-1","2","0.5","10","100","1000"]; set `[]` to ignore nothing),
    \\`min_float_digits` (default 2) and `min_int_digits` (default 3). Digits are
    \\counted off the value's shortest round-trip decimal, NOT counting a
    \\leading zero before the point and counting the zeros after it — which is
    \\what makes `1e-6` (six) and `0.05` (two) specific while `0.5` (one) is not.
    \\Exempt: narrow a rule's `files`, add to its `ignore`, exempt a path from
    \\every rule with `[[allow]] check = "shadowed-const"`, or delete the rule.
    \\Limits: BARE means unnamed. A literal that IS a named const/var's
    \\initializer is a name, not a shadow — that is divergent-const's subject,
    \\with a different fix, and flagging it here would fight the common remedy:
    \\"push this literal into a named const". A file that
    \\declares the value under ANY name is skipped for that value in both modes.
    \\Everything else counts: an expression operand, a call argument, a struct
    \\field default, an array length. Comments and string contents are not
    \\literals at all (the scan reads `number_literal` nodes, never text), and a
    \\`test` block is skipped, because a test's expected value is supposed to be
    \\spelled independently of the constant it checks. Values compare FOLDED,
    \\exactly as in divergent-const (`16 << 20` = `16_777_216`), and only
    \\file-scope consts can be a target.
    \\Baseline: one violation per (constant, shadowing file), keyed
    \\`<referent>|<file>` — so a fourth bare copy in an already-frozen file
    \\stays frozen, a NEW file fails, and the same file shadowing a different
    \\constant is its own row. A dangling rule is keyed `rule <referent>`: that
    \\one is the config's own broken claim, one row however many files it would
    \\have scanned.
    },
    .{ .name = "twin-referent", .text =
    \\Why: a comment claiming "mirrors X" / "same as Y" / "verified against Z" is
    \\a maintenance contract written in prose, and prose does not move when code
    \\does. Measured in eda: a doc naming a deleted function now sits on an
    \\unrelated one, `render_svg.zig` named after it was split into a directory,
    \\a hard-coded `file.zig:120-160` range pointing at unrelated code, and
    \\`optimizer.INNER_LAYER_COLORS` where the symbol is lowercase. Each reads as
    \\verified and is not.
    \\Fix: repoint the comment at a name that exists, or drop the claim. For a
    \\line range, name the symbol instead — the numbers rot on the next edit
    \\above them, so there is nothing to repoint them to.
    \\Exempt: `[twin_referent] ignore = ["src/vendor/*", "legacy.zig"]` (globs,
    \\matched against the commenting file's path AND the referent text),
    \\`[[allow]] check = "twin-referent"`, or the `disabled` list.
    \\Limits: a claim phrase alone is NEVER reported — English is full of
    \\"matches the filter". The phrase must be followed IN THE SAME SENTENCE by
    \\something code-shaped: a word ending in `.zig` (no glob, non-empty
    \\basename), or a dotted chain whose first segment names a module in the
    \\tree. Backticks are stripped as punctuation and do not by themselves make
    \\a word a referent — that rule produced false positives on prose about
    \\wildcards. Resolution is containment, not semantics: a path must name an
    \\indexed file (exactly or as a tail starting at `/`, so a bare `limits.zig`
    \\resolves), a chain's final symbol must be declared, named as a field, or
    \\dereferenced ANYWHERE in the tree, and a chain rooted in `std`/`builtin` is
    \\skipped since this check has no index of them.
    \\Baseline: one violation per `<file>|<referent>`, so rewording the sentence
    \\around a claim — or moving it down the file — keeps its key.
    },
    .{ .name = "twin-drift", .text =
    \\Why: two hand-written copies of one rule stopped agreeing. Measured in eda
    \\(an audit of 155 fix commits, 2026-09): that is the cause behind 25 of
    \\them. The live case is `buildNetClassOverrides`, duplicated in
    \\drc_session.zig and wasm_drc.zig — the header of the first says the JSON
    \\board parser was copied on purpose to stay under the file-size cap. The
    \\wasm copy then gained `.class`, `.power_branch_width`, `.keepout_mm` and
    \\`.keepout_escape_mm`; the session copy gained none of them, so the session
    \\DRC now runs with no keepout rule. The two share no type, no call and no
    \\file, so nothing in the compiler can see it and each copy's own tests keep
    \\passing.
    \\Fix: reconcile the two copies, or lift the shared part into one fn both
    \\call. If the divergence is deliberate, say so above either copy:
    \\  // twin-drift-ok: the wasm bridge clamps to the page's own limits
    \\A `mirrors X` / `same as Y` claim in the doc comment does NOT exempt the
    \\pair — a declared mirror that drifted is the worst case, not the safe one
    \\— but the message then says `(declared mirror)`.
    \\Exempt: the annotation above, `[twin_drift] ignore = ["run", "deinit"]`
    \\for a name a project implements once per file as an INTERFACE rather than
    \\copying, `[[allow]] check = "twin-drift"` for a path, or the `disabled`
    \\list.
    \\Pairing (v2): names are not consulted. Each body is re-tokenised with
    \\Zig's own tokenizer — every string and char literal collapsed to one
    \\`$str`, every number to `$num`, everything else kept as its text — and
    \\becomes the multiset of its 3-gram token shingles. Every shingle gets an
    \\idf across the run's candidate bodies, every body a tf*idf vector, and a
    \\pair is PROPOSED when the cosine reaches `[twin_drift] pair_similarity`
    \\(default 0.5). An inverted index accumulates that sparsely, through
    \\shingles held by at most 96 bodies, so two functions overlapping only in
    \\boilerplate are never compared. v1 paired by NAME and could see neither a
    \\renamed copy nor the difference between a shared rule and a shared name.
    \\Limits: the cosine only PROPOSES. Judgement is unchanged: similarity is
    \\2*|LCS| / (|A| + |B|) over normalised body lines (comments and blanks
    \\dropped, internal whitespace collapsed, one entry per source line),
    \\reported as "share N% of their body". IDENTICAL bodies are NOT reported:
    \\that is duplication debt, and listing it would bury the pair that is
    \\actively wrong — `[twin_drift] report_identical = true` asks for the
    \\inventory. Bodies under `min_statements` (default 8) are scaffolding and
    \\never compared; a body over `max_lines` (default 400) is counted and
    \\skipped rather than paid for. A fn inside a `test` block, and a private fn
    \\reachable only from `test` blocks in its own file, are both skipped — a
    \\per-file fixture written to the same shape is not a twin. Pairing by body
    \\is not pairing by protocol: one interface implemented once per file still
    \\looks alike whatever the implementations are called, so `ignore` still
    \\earns its keep.
    \\Baseline: one violation per pair, keyed `<nameA>|<fileA>|<nameB>|<fileB>`
    \\with the two sides ordered by path, so editing either copy further moves
    \\the percentage without re-keying the row. Renaming a copy DOES re-key it —
    \\after a rename it is a different pair of functions. The differing lines
    \\ride the advisory channel, which no baseline records.
    },
    .{ .name = "duplicate-json-key", .text =
    \\Why: one function writes the same JSON key twice into the same object, so
    \\the blob is last-wins today and a SyntaxError under any strict reader.
    \\Measured in eda: one serializer emitted "pour_min_width" and
    \\"pour_corner_radius" twice into a single "rules" object, from two
    \\`w.print` format strings fourteen lines apart — nothing in either line
    \\looks wrong, they are simply too far apart to hold in one head.
    \\Fix: write the key once. The second write is the one the reader gets, so
    \\deleting the WRONG one changes the payload — check which value is current
    \\before removing either.
    \\Exempt: `[[allow]] check = "duplicate-json-key"` for a path, or the
    \\`disabled` list. There is no per-key knob: a duplicate key is never
    \\intentional.
    \\Limits: precision is bought with recall, deliberately. Keys are compared
    \\only inside one OBJECT SEGMENT: a `{` or `}` a literal actually emits
    \\(including the `{{`/`}}` escapes of a format string) ends the segment, and
    \\so does a completed call between two literals — a write this check cannot
    \\see inside. So `{"a":1}` then `{"a":2}` is silent (sibling objects), and a
    \\duplicate separated by `try writeNested(w)` is silent too. A format
    \\PLACEHOLDER (`{d}`, `{s}`) is a value, not a brace — which is exactly what
    \\makes the motivating case reachable. Test blocks are never scanned, so a
    \\test's own JSON fixtures cannot fire it.
    \\Baseline: one violation per `<file>|<fn>|<key>`, so the line pair may move
    \\freely.
    },
    .{ .name = "ban-time", .text =
    \\Why: reading the wall clock inline makes behavior time-dependent and
    \\untestable — an agent grabbing `std.time.timestamp()` where it's handy.
    \\Fix: inject a clock port and read time through it.
    \\Exempt: allowed under `infra/clock`; add paths via
    \\`[[allow]] check = "ban-time"`.
    },
    .{ .name = "ban-rng", .text =
    \\Why: constructing an RNG inline makes runs non-reproducible — flaky tests
    \\and un-seedable behavior.
    \\Fix: inject a seeded random port and draw from it.
    \\Exempt: allowed under `infra/random`; add paths via
    \\`[[allow]] check = "ban-rng"`.
    },
    .{ .name = "ban-fs", .text =
    \\Why: direct `std.fs` I/O couples logic to the real filesystem, so an agent's
    \\code can't be tested without touching disk.
    \\Fix: inject a filesystem port (or pass in the bytes) instead.
    \\Exempt: allowed under `infra/fs`; add paths via
    \\`[[allow]] check = "ban-fs"`.
    },
    .{ .name = "ban-net", .text =
    \\Why: inline `std.net`/`std.http` hides a network dependency inside business
    \\logic — untestable and non-deterministic.
    \\Fix: inject an HTTP/net adapter behind an interface.
    \\Exempt: allowed under `adapters/http` or `infra/net`; add paths via
    \\`[[allow]] check = "ban-net"`.
    },
    .{ .name = "ban-env", .text =
    \\Why: reading env vars deep in the code scatters configuration an agent
    \\should have threaded from the entry point.
    \\Fix: read env once in config/main and pass the value down.
    \\Exempt: allowed in `config` or `main`; add paths via
    \\`[[allow]] check = "ban-env"`.
    },
    .{ .name = "ban-sleep", .text =
    \\Why: a real sleep in production code is an agent's substitute for proper
    \\synchronization — slow and flaky.
    \\Fix: wait on the actual condition/event instead of sleeping.
    \\Exempt: allowed in test infrastructure; add paths via
    \\`[[allow]] check = "ban-sleep"`.
    },
    .{ .name = "ban-globals", .text =
    \\Why: a mutable file-scope `var` (pub or not, `threadlocal` included) — or a
    \\`pub var` at container scope — is shared hidden global state, an agent's
    \\quick stash that causes spooky action at a distance. zig-core's library core
    \\has ~zero of these; process-lifetime globals live only in the entry layer.
    \\Fix: pass the state explicitly, or own it in a struct with a lifetime.
    \\Exempt: allowed in `wiring`/`main` and test files; add paths via
    \\`[[allow]] check = "ban-globals"` (Guardian exempts its own reporter.zig
    \\threadlocal singleton this way). A struct-scope non-pub container `var` is
    \\out of scope.
    },
    .{ .name = "ban-hardcoded-paths", .text =
    \\Why: a literal `/etc`, a Windows drive path, or `http://host` is an
    \\environment assumption an agent baked in that breaks on another machine.
    \\Fix: make the path/URL a configurable input.
    \\Exempt: add paths via `[[allow]] check = "ban-hardcoded-paths"`, or disable.
    },
    .{ .name = "ban-secrets", .text =
    \\Why: a hardcoded credential (AWS/GitHub/Slack token, PEM key, high-entropy
    \\`password =`) is a leak an agent pasted from a sample.
    \\Fix: remove the secret; load it from env/secret storage at runtime.
    \\Exempt: publishable/test keys and placeholders are already ignored; add
    \\paths via `[[allow]] check = "ban-secrets"` for fixtures.
    },
    .{ .name = "init-deinit-symmetry", .text =
    \\Why: a struct that owns an allocator field but has no `pub fn deinit` leaks
    \\whatever it allocated — an agent forgot the teardown.
    \\Fix: add a `pub fn deinit` that frees everything init acquired.
    \\Exempt: disable the check if the type deliberately borrows (never owns).
    },
    .{ .name = "errdefer-in-init", .text =
    \\Why: an init with 2+ `try` calls and no `errdefer` leaks the first resource
    \\when the second fails — a subtle agent oversight.
    \\Fix: add an `errdefer` to release each acquired resource on a later failure.
    \\Exempt: none — add the errdefer. Disable only during migration.
    },
    .{ .name = "test-has-assertion", .text =
    \\Why: a `test "..."` with no `expect*` call asserts nothing — it passes as
    \\long as it doesn't crash, giving false coverage an agent counts as tested.
    \\Fix: add an `expect`/`expectEqual`/… that checks the actual result.
    \\Exempt: none — a test must assert something.
    },
    .{ .name = "test-no-conditional", .text =
    \\Why: `if`/`while`/`switch` (or extra `for`) at a test's top level usually
    \\means the test only checks one branch, or skips silently.
    \\Fix: split into separate tests, or drive inputs table-style with asserts.
    \\A test may keep ONE top-level loop; every further loop belongs in a named
    \\helper. The multi-loop finding names the loop to hoist: the assertion-free
    \\fixture builder when there is one, otherwise the extra loop itself (which
    \\can also be merged into the first, table-style).
    \\Exempt: none — restructure the test. Disable only as a last resort.
    },
    .{ .name = "test-skip-ban", .text =
    \\Why: a test whose body is empty or whose first statement is
    \\`return error.SkipZigTest;` never runs yet still satisfies its `// spec:`
    \\tag — a silent hole in the flagship 1:1 spec-test guarantee.
    \\Fix: implement the test so it asserts real behavior, or delete both the
    \\test and its `// spec:` tag (and the SPEC.md bullet if the behavior is
    \\gone). A conditional skip (`if (cond) return error.SkipZigTest;`) is legal
    \\and never flagged.
    \\Exempt: none — finish or remove the test. Disable only during migration.
    },
    .{ .name = "prod-imports-no-test", .text =
    \\Why: production code importing a `*_test.zig`/`tests/` file drags test-only
    \\scaffolding into the shipped binary — an agent wiring the wrong module.
    \\Fix: import from the production module; move shared helpers out of the test
    \\file.
    \\Exempt: none — production must not depend on tests.
    },
    .{ .name = "bool-ops-per-condition", .text =
    \\Why: a condition crammed with many `and`/`or`/`!` is where boolean-logic
    \\bugs hide.
    \\Fix: split into nested/sequential ifs to cut the leaf count, or name an
    \\intermediate boolean (naming alone doesn't reduce the leaves).
    \\Exempt: raise `[bool_ops] max_ops`, or disable the check.
    },
    .{ .name = "line-length", .text =
    \\Why: very long lines force horizontal scrolling and hide the end of a
    \\statement an agent tacked on.
    \\Finding: lines above `max_len` warn; only those above `hard_max_len` block.
    \\Wrap when it improves readability; `\\` multiline strings are exempt.
    \\Exempt: adjust either `[line_length]` limit, or disable the check.
    },
    .{ .name = "repeated-string-literal", .text =
    \\Why: the same literal repeated 3+ times (or a duplicated named const across
    \\files) is knowledge an agent copy-pasted instead of centralizing.
    \\Two sub-analyses, both with an 8-char minimum length (short literals like
    \\"init"/"name" are common coincidences, not shared knowledge): (1) in-file —
    \\a literal appearing 3+ times in one file, its every occurrence line named;
    \\(2) cross-file — the same file-scope `const NAME = "value"` (identical name
    \\AND value) declared in 2+ files.
    \\Fix: extract a shared file-scope const and import it everywhere.
    \\Exempt: disable via the top-level `disabled` list (retired `dup-const` name
    \\also tolerated there).
    },
    .{ .name = "stack-escape", .text =
    \\Why: returning `&local`, a slice of a stack array, or `&local.field` yields
    \\a dangling pointer into a dead frame — a memory-safety bug agents write.
    \\Fix: return by value, or accept an out-param/allocator the caller owns.
    \\Exempt: none — it's undefined behavior. Restructure the return.
    },
    .{ .name = "assert-doc-consistency", .text =
    \\Why: an agent writes the Zig-core `/// Asserts <precondition>` doc but never
    \\adds the guard, so the doc promises a check the body never performs — a
    \\precondition that reads as enforced yet isn't.
    \\Fix: add the `assert(` the doc promises (`std.debug.assert(...)`), or reword
    \\the doc so it no longer claims an `Asserts` precondition.
    \\Exempt: add paths via `[[allow]] check = "assert-doc-consistency"`; the
    \\trigger is the whole word `Asserts` (case-sensitive), so lowercase prose
    \\never fires.
    },
    .{ .name = "fatal-exit", .text =
    \\Why: a raw `std.process.exit(1)` scattered through the code fragments the
    \\termination path an agent should route through one helper. Zig core funnels
    \\every hard exit through `std.process.fatal` (×281); Guardian carries
    \\`reporter.fatal`, which keeps the "guardian: " prefix and coloring that
    \\`std.process.fatal` drops. `exit(0)` and `std.process.cleanExit` are fine —
    \\a clean success exit isn't the fragmentation this targets.
    \\Fix: replace `std.process.exit(<nonzero>)` with `reporter.fatal("...", .{})`
    \\(or your project's fatal helper). Detection is the lexical `process.exit(`
    \\chain, so string/comment mentions never fire.
    \\Exempt: the process entry file is auto-detected by its `fn main` (a
    \\downstream `src/main.zig` needs no config); designate the fatal helper's own
    \\file via `[[allow]] check = "fatal-exit"` (Guardian points it at
    \\`src/reporter.zig`).
    },
    .{ .name = "change-classification", .text =
    \\Why: agents ship a behavioral src change with no test — the "quick fix,
    \\no regression test" pattern that lets the same bug return.
    \\Fix: add a test (or `// spec:` tag / SPEC.md bullet) in the same change.
    \\Not an accept: "N behavioral line(s) added" is not baseline churn — there is
    \\no snapshot to ratify. `GUARDIAN_UPDATE_SNAPSHOT=change-classification` and
    \\`guardian-check accept change-classification .` do not clear it.
    \\Exempt: `[change_classification] enabled = false`, or set the diff base via
    \\`--against` / `GUARDIAN_AGAINST`; skips silently outside a git repo.
    },
    .{ .name = "oom-discipline", .text =
    \\Why (opt-in): a swallowing `catch` on an allocating call conflates
    \\OutOfMemory with "not found", dropping data an agent meant to keep.
    \\Fix: propagate the allocation error; handle domain-absence separately.
    \\Exempt: off unless `[oom_discipline] enabled = true`.
    },
    .{ .name = "fuzz-presence", .text =
    \\Why (opt-in): a hand-rolled parser/decoder that ate untrusted input loses
    \\its fuzz harness in a refactor, so the coverage-guided net silently lapses.
    \\Fix: add a `test { try std.testing.fuzz(ctx, testOne, .{}); }` harness to
    \\each module listed in `[fuzz_presence] modules`. A listed file that is
    \\missing/unreadable or carries no `std.testing.fuzz` call fails the gate —
    \\fail-closed, so a stale path can't quietly pass.
    \\Exempt: off unless `[fuzz_presence] modules` names at least one file; drop
    \\a path from that list if it no longer needs a fuzz harness.
    },
    .{ .name = "concurrency-test-presence", .text =
    \\Why (opt-in): a mutex, a lock table or a rev guard can sit in a file for its
    \\whole life with nothing proving it serializes anything — the motivating case
    \\was a lockless check-then-write where two savers both read rev=5, both wrote
    \\rev=6, and one write was silently lost. A lock EXISTING is not the lock being
    \\exercised, and no static check can decide the runtime property; this one only
    \\refuses to let a file you declared concurrency-critical carry no concurrency
    \\test at all.
    \\Fix: add a test that starts a second unit of execution over the shared state —
    \\`std.Thread.spawn` (joined), `Thread.Pool`, or `io.concurrent` /
    \\`Io.Group.concurrent`. The spawn may live in a helper the test calls, so
    \\test-no-conditional can still push the join loop out of the test body.
    \\Not accepted: a lock, RwLock, Semaphore or Condition on its own (that is the
    \\thing being questioned), and `io.async` / `Group.async` — std's own docs say
    \\the function "may be called immediately", so an async test can pass having
    \\never interleaved. Only spelling matched on the TOKEN stream counts: a
    \\mention in a comment or a string literal never does, and a spawn no test
    \\reaches is production code.
    \\Exempt: off unless `[concurrency_presence] modules` names at least one file;
    \\a listed file that is missing/unreadable fails closed, so drop a path from
    \\that list when it no longer guards shared mutable state.
    },
    .{ .name = "script-string-safety", .text =
    \\Why (opt-in): a JSON/string serializer whose output is embedded verbatim in
    \\an HTML `<script>` element must escape `<`, or a `</script>` sequence in the
    \\data terminates the element early — a stored-XSS class. A plain
    \\application/json writer legitimately need not escape `<`, so only the consumer
    \\knows which serializers feed a script blob.
    \\Fix: escape `<` as `\u003c` in the flagged serializer (see
    \\json_writer.writeScriptString), or route its strings through that helper.
    \\Exempt: off unless `[script_string_safety] blob_files` names at least one
    \\file; drop a file whose output never lands in a `<script>` element.
    },
    .{ .name = "dead-model-field", .text =
    \\Why (opt-in): a model-struct field parsed from input and rendered to the user
    \\but read by no decision path is a contract shown and enforced by nobody — the
    \\displayed value drifts from what the tool actually does.
    \\Fix: read the field in an enforcement path (ERC / requirement / validation),
    \\stop surfacing it, or — if its check lives in a file the rule didn't list —
    \\add that file's glob to the rule's `logic` list.
    \\Exempt: off unless `[[dead_model_field]]` names a struct; list exact `fields`
    \\to check precisely, or an `owner` file to discover the struct's fields.
    },
    .{ .name = "projection-completeness", .text =
    \\Why (opt-in): a struct literal that rebuilds a value out of the parts it
    \\happens to hold — `Copper{ .tracks = rr.tracks, .vias = rr.vias }` — keeps
    \\compiling unchanged when the struct grows a field, because every field
    \\DEFAULTS. The compiler cannot help: an omitted field is not an error, it is
    \\a silent empty. In eda, `pour.Copper` gained `arcs` and five such literals
    \\kept projecting the old bundle, so the connectivity oracle they feed read a
    \\net joined only by an arc as an OPEN; ten sites were fixed by hand across
    \\three follow-up commits and two were still wrong after that.
    \\Fix: set every field the `[[projection]]` rule declares — they travel
    \\together — or, if this one deliberately drops a field, note
    \\`// projection-ok: <why>` on the literal's line, on a comment line directly
    \\above it, or on the enclosing statement's line. That note is the exemption:
    \\the omission gets a reason in the source instead of a baseline row.
    \\Scope: `type` matches the TAIL of a literal's type path at a segment
    \\boundary, so a bare `Copper` covers `Copper{`, `pour.Copper{` and
    \\`routed_copper.Copper{` — and the qualified `routed_copper.Copper` covers
    \\only the last, which is what you want when the repo holds several
    \\same-named types (eda has four `Copper`s; one is a two-field struct whose
    \\COMPLETE literal a bare rule reads as a partial projection).
    \\An anonymous `.{ … }` literal has no path, so it is judged only when it
    \\sets `anonymous_min_fields` (default 2) of the declared set AND sets
    \\nothing outside `fields` + `optional` — list every field of the type across
    \\those two keys. That half is still weaker than the typed one: measured on
    \\eda it reported 98 anonymous literals to the typed half's 4, and roughly
    \\two thirds were `SavedRoutes` / `LiftedNet` literals whose whole vocabulary
    \\is a subset of Copper's. `anonymous_min_fields = 0` turns it off, which is
    \\the right setting for field names as common as `tracks`/`vias`.
    \\A literal setting NONE of the declared fields is not a projection of this
    \\bundle and is never reported, and `test` blocks are skipped (a fixture may
    \\build a partial value).
    \\Exempt: off unless `[[projection]]` declares a rule; `allow` globs exempt
    \\paths per rule and `[[allow]] check = "projection-completeness"` exempts
    \\them for every rule. Keyed `<name>|<file>|<fn>|<sorted fields set>`, so
    \\rewording the message or moving the literal never re-keys a baseline.
    },
    .{ .name = "module-doc-header", .text =
    \\Why: a src file over the line threshold (`[module_doc_header] min_lines`,
    \\default 200) is where a reader arrives cold and needs orientation, yet an
    \\agent rarely writes the `//!` module doc. Calibrated to zig-core reality —
    \\its own tree carries `//!` on only ~25-28% of files, but consistently on the
    \\large, load-bearing ones — so the gate targets the big modules, not every
    \\file.
    \\Fix: add a `//!` block at line 1 (2+ lines or 60+ chars) naming the module
    \\and its one key contract (ownership rule, fail-loud polarity, an invariant).
    \\Tune: lower `[module_doc_header] min_lines` to require headers on smaller
    \\files (default 200).
    \\Exempt: add paths via `[[allow]] check = "module-doc-header"`.
    },
    .{ .name = "external-gates", .text = "Why: Zig projects often ship JavaScript, generated assets, schemas, or\n" ++
        "other files Guardian cannot understand natively; those checks still need\n" ++
        "to participate in the same cached, hard-blocking build contract.\n" ++
        "Fix: add `[[external]]` with a name, argv-style command array, and exact or\n" ++
        "`*`-globbed input paths. An exact `{input}` argv token runs once per matched\n" ++
        "file. Guardian performs no shell interpolation and runs from the project root.\n" ++
        "For an expensive gate, `paths` scopes it to changed hot paths; `benchmark` +\n" ++
        "`max_regression_pct`, `timeout_secs`, and `max_rss_mib` enforce resource budgets.\n" ++
        "Exempt: remove the entry or set `external-gates` to report-only in [policy]." },
    .{
        .name = "policy-drift",
        .text = "Why (opt-in): an agent can otherwise loosen guardian.toml or ratify its own\n" ++
            "baseline growth in the same change that needs the exemption.\n" ++
            "Fix: review protected changes, then set GUARDIAN_POLICY_APPROVED=1 in the\n" ++
            "trusted CI job. Configure the comparison ref and paths under [policy].\n" ++
            "Exempt: off unless `[policy] lock_enabled = true`; this check cannot demote itself.",
    },
    .{ .name = "commit", .text =
    \\Why: a meta command, not a gate — brings guardian-zig into the sibling
    \\guardians' intent-driven flow: run the whole gate, then commit the change
    \\set, with rails so a green build can't leak a secret or stage build output.
    \\Fix: n/a — run `guardian-check commit --intent "<message>" [dir]`. On green
    \\it stages the working-tree change set (never `git add -A`; untracked
    \\secret/artifact paths are skipped with a loud warning — never a tracked
    \\path or a .zig source; `.guardian/` + SPEC.md always included) and commits
    \\with the intent as the subject. On red it prints the violations and leaves
    \\git untouched. Never pushes, never amends.
    \\Exempt: n/a — never part of `all`; requires an explicit non-empty --intent.
    },
    .{ .name = "install-hook", .text =
    \\Why: a meta command, not a gate — with a dev build now only REPORTING, a raw
    \\`git commit` would otherwise slip past Guardian. This writes
    \\`.git/hooks/pre-commit` (marked with a guardian comment) that runs the
    \\blocking gate (`guardian-check all . --gate`), so the commit aborts on red.
    \\Fix: n/a — run `guardian-check install-hook [dir]` (commit auto-installs it
    \\unless `[gate] install_hook = false`). The hook resolves a binary in order:
    \\$GUARDIAN_CHECK, ./zig-out/bin/guardian-check, then guardian-check on PATH.
    \\Exempt: an existing non-guardian pre-commit hook is never overwritten — add
    \\`guardian-check all . --gate` to it by hand, or remove it and re-run.
    },
    .{ .name = "merge-state", .text =
    \\Why: a `.guardian/` file git left mid-merge reads as ordinary debt to every
    \\other check, so the tree gates GREEN on numbers nobody measured. Three
    \\states are refused: git's conflict markers still in the file, a counter
    \\merge the driver had to guess (`# guardian-merge: regenerate`), and a row
    \\that does not parse in its own format.
    \\Fix: regenerate the named file on the MERGED tree — the command is printed
    \\per file (`GUARDIAN_UPDATE_SNAPSHOT=<check> zig build`), then commit
    \\`.guardian/`. That is the canonical snapshot-merge recipe: resolve
    \\provisionally, regenerate, review the diff.
    \\Exempt: none. Install the driver (`guardian-check install-merge-driver`) so
    \\most of these conflicts never reach you in the first place.
    },
    .{ .name = "install-merge-driver", .text =
    \\Why: a meta command, not a gate. `.guardian/` files are auto-shrinking
    \\ratchets and per-item snapshots that every branch touches, so they conflict
    \\constantly — and the "obvious" hand-union is wrong in ways that are silent
    \\(a union of a sorted snapshot is unsorted; a union of two grown counters
    \\keeps only one side's growth).
    \\Fix: n/a — run `guardian-check install-merge-driver [dir]` (install-hook and
    \\commit install it too). It writes `.guardian/** merge=guardian` into
    \\`.git/info/attributes` (local, NOT the tracked .gitattributes) and points
    \\`merge.guardian.driver` at `guardian-check merge-file %O %A %B --path %P`.
    \\Exempt: n/a — an existing attributes file is extended, never replaced.
    },
    .{ .name = "merge-file", .text =
    \\Why: a meta command, not a gate — the driver git runs per conflicted
    \\`.guardian/` file. Arguments are in GIT's order, `%O %A %B` = base, ours,
    \\theirs, and the merged result is written to `<ours>` (`%A`).
    \\Fix: n/a — per format: a v3 identity baseline and the pub-api surface union
    \\their entries minus anything either side deleted (a deletion is debt paid);
    \\a v2 per-item ratchet keeps the TIGHTER ceiling per key; a counter both
    \\sides moved takes the larger value and marks the file for regeneration,
    \\which `merge-state` then blocks until you refresh it.
    \\Exempt: a format with no safe resolution (the mutation cohort, the
    \\benchmark ledger, mismatched headers) is refused, so git records an
    \\ordinary conflict and you regenerate instead.
    },
    .{ .name = "doctor", .text = "Why: a read-only maintenance command that catches corrupt recognized\n" ++
        "Guardian metadata before a ratchet can silently lose meaning, while also\n" ++
        "surfacing advisory cleanup/reproducibility issues.\n" ++
        "Fix: repair malformed metadata; review warnings for stale baselines, a\n" ++
        "missing mutation ratchet, path-based integration, or a very large cache.\n" ++
        "Exempt: n/a — never part of `all`; advisory warnings do not fail it." },
    .{ .name = "spec-sync", .text = "Why: unlinked `// spec:` tags often represent implemented behavior whose\n" ++
        "exact SPEC.md bullet was omitted. This assistant groups exact suggestions\n" ++
        "without claiming that generated prose is automatically authoritative.\n" ++
        "Fix: review and manually apply appropriate suggestions. Add `--json` for\n" ++
        "machine-readable output. The command never modifies files.\n" ++
        "Exempt: n/a — never part of `all`; it is always a dry run." },
    .{ .name = "test-filter", .text =
    \\Why: on a large tree an edit costs a whole test-binary rebuild plus the whole
    \\suite (measured on one consumer: ~207s per edit/verify iteration, of which
    \\~180s disappears when only the changed file's tests are compiled). This
    \\derives the test names your diff's files declare so a LOCAL loop can run
    \\those instead — and reports, in the same breath, everything the filter does
    \\not cover: unnamed `test { }` blocks, changed paths with no derivable test,
    \\and the tests of every file that depends on a changed one.
    \\Fix: n/a — read-only, non-gating, runs no tests. Use it as
    \\`eval "$(guardian-check test-filter . --args)"`-style interpolation:
    \\`eval "zig build test $(guardian-check test-filter . --args)"` (eval, not a
    \\bare $(...): command substitution word-splits without processing quotes).
    \\`--json` for tooling. `[test_filter] flag` sets your project's flag spelling.
    \\Exempt: n/a — never part of `all` and never reachable from a gate. Zig hands
    \\--test-filter to the COMPILER, so unmatched tests are never analyzed: a green
    \\filtered run does not even prove the test binary builds. `commit`, the
    \\pre-commit hook, and CI always run the whole `[gate] test_command`.
    },
    .{ .name = "accept", .text = "Why: intentional baseline/snapshot drift should be accepted by name, not through\n" ++
        "a broad environment-variable refresh that can ratify unrelated changes.\n" ++
        "Fix: run `zig build guardian-accept -Dguardian-checks=file-size,line-length`; Guardian previews,\n" ++
        "refreshes only those checks, then verifies them without refresh.\n" ++
        "Exempt: n/a — never part of `all`; always review the resulting .guardian/ diff." },
    .{ .name = "bench", .text = "Why: an agent spends minutes (sometimes hours) measuring something — a\n" ++
        "full-board route, a suite wall clock, a kill score — and the number then\n" ++
        "survives only in a chat report, so the next agent re-measures it or, worse,\n" ++
        "re-runs an experiment already known to have failed.\n" ++
        "Fix: record it — `guardian-check bench set <name> <value> --unit s --dir\n" ++
        "min --note \"87/90 nets, fixture B\" .` writes one sorted line to\n" ++
        "`.guardian/benchmarks.txt`, and every gate run prints it back. A negative\n" ++
        "result is `--dir info` plus the note explaining what it cost.\n" ++
        "Exempt: n/a — never part of `all` and never blocking. Naming a metric in\n" ++
        "`[benchmark] gate = [...]` opts it into a ratchet: `set` then refuses a\n" ++
        "regression unless `--force` arrives with an explanatory `--note`." },
    .{ .name = "size", .text =
    \\Why: a ratchet freezes each item at the value guardian measured, but nothing
    \\reported that value back — the checks print a number only once an item is
    \\already over its cap, and `debt` lists ceilings without the current value
    \\beside them. Reading the number back cost one consumer six ~90s gate runs for
    \\a single file trim, with a 170-line disagreement against `grep -c` (a
    \\file-size code line is a non-blank, non-comment line outside
    \\`test { ... }` blocks; grep counts all three).
    \\Fix: n/a — run `guardian-check size <path> [dir]`. It prints the file's code
    \\lines, per-fn length and runtime params, per-type field counts, and the count
    \\of over-long lines, each against the check's caps and its frozen ceiling with
    \\the headroom left. Add `--current` to `debt` for the same comparison
    \\tree-wide. The values come from the checks' own measurement functions, so
    \\they match what the gate would ratchet.
    \\Exempt: n/a — never part of `all`, never gates, never writes. Three ratchets
    \\(nesting-depth, cognitive-complexity, bool-ops-per-condition) compute their metric inside the check's own threshold
    \\scan; they are named in the report rather than approximated.
    },
};

/// Returns the explanation text for `name`, or null when no entry exists.
fn lookup(name: []const u8) ?[]const u8 {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e.text;
    return null;
}

/// True when `query` resolves to a printable explanation: a null query (the
/// bare listing) always resolves; a named query resolves only when it has a
/// known summary (a registered check or a documented meta command) and an entry
/// here. Meta commands (e.g. `commit`) live outside the registry to avoid an
/// @import cycle, so summaryFor — not find — is the membership test.
fn resolves(query: ?[]const u8) bool {
    const name = query orelse return true;
    return registry.summaryFor(name) != null and lookup(name) != null;
}

/// Prints every registered command name with its one-line summary.
fn listAll() void {
    print("guardian checks — run `guardian-check explain <name>` for the full rationale:\n\n", .{});
    for (registry.all) |cmd| {
        print("  {s: <26} {s}\n", .{ cmd.name, cmd.summary });
    }
    print("\nmeta commands: all, nightly, commit, install-hook, install-merge-driver,", .{});
    print(" merge-file, doctor, spec-sync, test-filter, accept, size, version\n", .{});
}

/// What `explain` was asked for. Everything but `name` exists for the
/// `--section` dry run, which is the only variant that reads project state.
pub const Query = struct {
    /// The check name; null lists every command.
    name: ?[]const u8 = null,
    /// `--section <name>`: report that SPEC.md section's completeness standing.
    section: ?[]const u8 = null,
    /// Directory the dry run resolves the spec file against.
    project_dir: []const u8 = ".",
    /// `spec_file` from guardian.toml (defaults are fine when it is unreadable).
    spec_file: []const u8 = "SPEC.md",
    /// `[completeness] exempt_sections` — a listed section needs no categories.
    exempt: []const []const u8 = &.{},
};

/// Runs the explain command. Returns false only when the request cannot be
/// answered (an unknown check name, or `--section` on a check that has no
/// section report), so the caller can exit non-zero; true otherwise.
pub fn run(allocator: std.mem.Allocator, query: Query) bool {
    const name = query.name orelse {
        if (query.section != null) return sectionNeedsCheck();
        listAll();
        return true;
    };
    if (!resolves(name)) {
        print("unknown check: {s}\n\n", .{name});
        listAll();
        return false;
    }
    if (query.section) |section| return printSectionReport(allocator, name, section, query);
    print("{s} — {s}\n\n", .{ name, registry.summaryFor(name).? });
    print("{s}\n", .{lookup(name).?});
    if (std.mem.eql(u8, name, section_check)) printKeywordTable();
    return true;
}

/// The `--section` flag with no check named: say which check owns it rather
/// than silently listing every command.
fn sectionNeedsCheck() bool {
    print("--section needs a check name: guardian-check explain {s} --section \"<name>\" [dir]\n", .{section_check});
    return false;
}

/// The category → keyword table, printed straight from the check's own table so
/// the documented keywords can never drift from the matched ones. This is the
/// answer to "which words count as addressing a category", which four consumer
/// sessions could previously get only by reading the check's source.
fn printKeywordTable() void {
    print("\nCategories, and the keywords a bullet may contain to address one:\n\n", .{});
    for (completeness.categories) |cat| {
        print("  {s: <22}", .{cat.name});
        for (cat.keywords, 0..) |kw, i| {
            if (i > 0) print(" | ", .{});
            print("{s}", .{kw});
        }
        print("\n", .{});
    }
    print("\n  Matching is case-insensitive substring, so \"overflow\" is addressed by\n", .{});
    print("  \"Saturates instead of overflowing\" as well as by \"integer overflow\".\n", .{});
}

/// Prints one SPEC.md section's completeness standing (or its skeleton). Only
/// `completeness` has a section report; any other check says so and fails.
fn printSectionReport(
    allocator: std.mem.Allocator,
    name: []const u8,
    section: []const u8,
    query: Query,
) bool {
    if (!std.mem.eql(u8, name, section_check)) {
        print("--section is only meaningful for `{s}` (asked for `{s}`)\n", .{ section_check, name });
        return false;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sections = readSections(a, query) orelse {
        print("cannot read {s}/{s} — run from the project root, or pass the directory\n", .{ query.project_dir, query.spec_file });
        return false;
    };
    const report = completeness.reportSection(a, sections, query.exempt, section) catch {
        print("out of memory building the section report\n", .{});
        return false;
    };
    printReportHeader(report, query.spec_file);
    if (report.present) printPresentSection(report) else printSkeleton(report);
    printKeywordTable();
    return true;
}

/// Reads the spec's feature sections, collapsing both "unreadable" outcomes
/// (missing file, OOM) to null — the caller prints one actionable message.
fn readSections(a: std.mem.Allocator, query: Query) ?[]const completeness.FeatureSection {
    return completeness.readFeatureSections(a, query.project_dir, query.spec_file) catch null;
}

fn printReportHeader(report: completeness.SectionReport, spec_file: []const u8) void {
    const total = completeness.categories.len;
    if (!report.present) {
        print("completeness --section \"{s}\" — no such `## ` heading in {s} yet.\n", .{ report.name, spec_file });
        print("A new section starts at 0/{d} categories; here is the skeleton that satisfies it.\n\n", .{total});
        return;
    }
    print("completeness --section \"{s}\" — {d}/{d} categories satisfied in {s}\n", .{
        report.name,
        report.satisfied(),
        total,
        spec_file,
    });
    if (report.exempt) print(
        "This section is in `[completeness] exempt_sections`, so the gate skips it entirely.\n",
        .{},
    );
    print("\n", .{});
}

/// Per-category standing for a section that exists, each line carrying the
/// evidence: the bullet that matched, the waiver's reason, or the keywords that
/// would satisfy it.
fn printPresentSection(report: completeness.SectionReport) void {
    var missing: usize = 0;
    for (report.categories) |c| {
        switch (c.state) {
            .addressed => |bullet| print("  ok       {s: <22} bullet: {s}\n", .{ c.category.name, bullet }),
            .waived => |reason| print("  waived   {s: <22} reason: {s}\n", .{ c.category.name, reason }),
            .waiver_no_reason => {
                missing += 1;
                print("  NEEDS    {s: <22} waiver has no (reason) — add one\n", .{c.category.name});
            },
            .missing => {
                missing += 1;
                print("  MISSING  {s: <22} add a bullet with one of its keywords, or waive it\n", .{c.category.name});
            },
        }
    }
    if (missing == 0) {
        print("\nThis section would pass the completeness gate as written.\n", .{});
        return;
    }
    print("\nAdd one line per MISSING category — a real bullet, or a reasoned waiver:\n\n", .{});
    printWaiverLines(report, .missing_only);
}

/// The paste-ready skeleton for a section that does not exist yet: the heading
/// plus one waiver line per category, every reason left as a placeholder so the
/// author must replace what they can actually address.
fn printSkeleton(report: completeness.SectionReport) void {
    print("  ## {s}\n", .{report.name});
    print("  - <the behaviour this section is actually about>\n", .{});
    printWaiverLines(report, .all);
    print("\nReplace each waiver you can genuinely address with a `- ` bullet containing\n", .{});
    print("one of that category's keywords; a waiver's `(reason)` may not be empty.\n", .{});
}

/// Whether the waiver skeleton covers every category or only the unsatisfied ones.
const WaiverScope = enum { all, missing_only };

fn printWaiverLines(report: completeness.SectionReport, scope: WaiverScope) void {
    for (report.categories) |c| {
        const unsatisfied = c.state == .missing or c.state == .waiver_no_reason;
        if (scope == .missing_only and !unsatisfied) continue;
        print("  - {s} {s} (<why this section cannot hit it>)\n", .{ completeness.waiver_prefix, c.category.name });
    }
}

// spec: Explain - Returns the explanation text for a registered check name
// spec: Explain - Signals an unknown check name
// spec: Explain - Provides an explanation entry for every registered command

test "lookup returns text for a known check and null otherwise" {
    try std.testing.expect(lookup("catch-discipline") != null);
    try std.testing.expect(lookup("not-a-real-check") == null);
}

test "resolves accepts known names and the bare listing, rejects unknown" {
    try std.testing.expect(resolves("catch-discipline"));
    try std.testing.expect(resolves(null));
    try std.testing.expect(!resolves("bogus-name"));
    // Specially-dispatched commands resolve too, via summaryFor + an entry.
    try std.testing.expect(resolves("test-filter"));
}

test "every registered command has an explain entry" {
    // A gap here means a check was registered without documenting it; the
    // assertion names the offending command on failure.
    for (registry.all) |cmd| {
        errdefer std.debug.print("missing explain entry: {s}\n", .{cmd.name});
        try std.testing.expect(lookup(cmd.name) != null);
    }
}

// spec: Explain - Resolves a summary for checks and documented meta commands

test "registry.summaryFor covers checks and meta commands" {
    try std.testing.expect(registry.summaryFor("spec") != null); // a registered check
    try std.testing.expect(registry.summaryFor("commit") != null); // a meta command
    try std.testing.expect(registry.summaryFor("nightly") != null); // a meta command
    try std.testing.expect(registry.summaryFor("not-a-command") == null);
}

// spec: Completeness Reporting - Refuses a section query aimed at a check with no section report

test "a section query resolves only for the completeness check" {
    // Asking any other check for a section report is a mistake worth naming:
    // silently printing that check's prose instead would look like an answer.
    try std.testing.expect(!run(std.testing.allocator, .{ .name = "spec", .section = "Widgets" }));
    // ...and `--section` with no check named says which check owns the flag.
    try std.testing.expect(!run(std.testing.allocator, .{ .section = "Widgets" }));
    // The keyword table is the completeness explain's own data, so the check
    // that owns `--section` is the one whose categories are documented.
    try std.testing.expect(completeness.categories.len > 0);
}

// spec: Explain - Aims each entry at the fix the reader came for

test "explain entries lead with the disambiguation each check is misread on" {
    // `function-size` reads like "function length": say which one it is, first.
    const size = lookup("function-size").?;
    try std.testing.expect(std.mem.startsWith(u8, size, "Scope: this is the PARAMETER-COUNT check"));
    try std.testing.expect(std.mem.indexOf(u8, size, "function-length") != null);
    // anytype-budget: the fix for a shared formatting helper is passing the
    // formatted result down, not a third `comptime fmt, args: anytype` pair.
    try std.testing.expect(std.mem.indexOf(u8, lookup("anytype-budget").?, "BufPrintError") != null);
    // change-classification: name the flow that does NOT clear it.
    try std.testing.expect(std.mem.indexOf(u8, lookup("change-classification").?, "not baseline churn") != null);
}

// spec: Concept Ownership - Explains the concept check's real exemptions and its owner, deny_growth and vendored-bundle guidance

test "explain concept states what is blanked and where a fix may land" {
    const text = lookup("concept").?;
    // The entry used to claim "A hit inside a comment or a string counts",
    // which stopped being true for comments the day the exemptions landed. A
    // reader planned around that model and then re-derived every site by hand.
    try std.testing.expect(std.mem.indexOf(u8, text, "A hit inside a comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`test { \u{2026} }` block") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`/* \u{2026} */` block in a `.css` file") != null);
    // The three lessons an adopting project pays for the hard way otherwise.
    try std.testing.expect(std.mem.indexOf(u8, text, "LEAF of the import graph") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deny_growth") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "minified bundle") != null);
    // The two directions the check now reads, and the fail-closed rule each
    // carries — a reader who plans around "owner only" designs the wrong fix.
    try std.testing.expect(std.mem.indexOf(u8, text, "require_in") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fails PERMISSIVELY") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "empty family passes every mirror") != null);
}

// spec: Twin Parity - Explains the twin-parity check's two rules, its free-form surfaces and its split baseline keys

test "explain twin-parity separates the blocking rule from the coverage ratchet" {
    const text = lookup("twin-parity").?;
    // The measurement that justifies the check, so an adopting project can see
    // the shape of its own problem rather than a rule stated in the abstract.
    try std.testing.expect(std.mem.indexOf(u8, text, "exactly ONE") != null);
    // Which rule blocks and which one ratchets: reading them as one rule is how
    // a project ends up accepting the wrong row.
    try std.testing.expect(std.mem.indexOf(u8, text, "always blocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deny_growth") != null);
    // The two things a reader otherwise assumes wrongly: surfaces are not
    // resolved, and the parity_test match is containment.
    try std.testing.expect(std.mem.indexOf(u8, text, "FREE-FORM labels") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CONTAINMENT") != null);
    // And why the two rows are keyed apart at all.
    try std.testing.expect(std.mem.indexOf(u8, text, "uncovered export-pdf") != null);
}

// spec: Canonical Idiom - Explains the fragment conjunction, the required reason and the rule-first baseline key

test "explain canonical-idiom states why one fragment is not a rule" {
    const text = lookup("canonical-idiom").?;
    // The conjunction IS the design: a reader who takes this for a one-fragment
    // grep writes a rule that bans an ordinary std call tree-wide.
    try std.testing.expect(std.mem.indexOf(u8, text, "CONJUNCTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "lastIndexOfScalar") != null);
    // The two things an adopting project otherwise learns by failing: reason is
    // required here, and the baseline key puts the RULE first.
    try std.testing.expect(std.mem.indexOf(u8, text, "`reason` is required here") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "keyed `<name>|<file>`") != null);
    // And the glob trap: `src/**/*.zig` is not this engine's spelling.
    try std.testing.expect(std.mem.indexOf(u8, text, "src/**/*.zig") != null);
}

// spec: Import Layering - Separates declared import direction from the cycle check in both explanations

test "explain distinguishes the layering rule check from the cycle check" {
    // The two read the same graph, so each entry has to say which question it
    // answers or a reader takes the first one they find and stops.
    const cycles = lookup("imports").?;
    try std.testing.expect(std.mem.indexOf(u8, cycles, "this is the CYCLE check") != null);
    try std.testing.expect(std.mem.indexOf(u8, cycles, "import-layering") != null);
    const layering = lookup("import-layering").?;
    try std.testing.expect(std.mem.indexOf(u8, layering, "this is the DIRECTION check") != null);
    // The three things an adopting project otherwise pays for the hard way: the
    // exact TOML, that a resolved path is what a glob matches, and that the
    // baseline freezes one EDGE at a time.
    try std.testing.expect(std.mem.indexOf(u8, layering, "[[layering]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, layering, "RESOLVED, project-relative paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, layering, "the EDGE, not the file") != null);
}

// spec: Explain - Documents the commit meta command

test "explain resolves and documents the commit meta command" {
    // commit is dispatched specially (not a registry entry) but is still
    // explainable: it has both a summary and a long-form entry.
    try std.testing.expect(lookup("commit") != null);
    try std.testing.expect(resolves("commit"));
}
