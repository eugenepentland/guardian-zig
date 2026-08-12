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
    .{ .name = "history", .text =
    \\Why: not a gate — the read surface over the append-only DORA run log
    \\(`.guardian/cache/dora.jsonl`), which guardian has written one record per
    \\gated run into since the sink landed and which nothing read back. It
    \\answers how often the gate is green, what a run costs, which checks
    \\actually block, and how long the current red patch has lasted.
    \\Fix: nothing to fix — it always exits 0 unless the log exists and cannot be
    \\read. `--check <name>` narrows it to one check's failure history; `--json`
    \\writes the whole report to stdout as one object.
    \\Exempt: n/a — run `guardian-check history [dir]`; never part of `all`.
    },
    .{ .name = "file-size", .text =
    \\Why: agents let a file grow unbounded, concentrating unrelated concerns
    \\where every future edit risks a merge conflict or a stray regression.
    \\Finding: files above `max_file_lines` warn; only files above
    \\`hard_max_file_lines` block. Split along a cohesive module seam.
    \\Exempt: adjust either limit, list a glob in `file_size_exclude`, or disable
    \\via the top-level `disabled` list.
    },
    .{ .name = "boundaries", .text =
    \\Why: an agent reaches across an architectural layer (core importing utils),
    \\eroding the module boundaries the design depends on.
    \\Fix: invert the dependency or route through the allowed module; remove the
    \\forbidden `@import`.
    \\Exempt: edit or drop the offending `[[boundary]]` rule in guardian.toml.
    },
    .{ .name = "usingnamespace-ban", .text =
    \\Why: `usingnamespace` hides where a symbol comes from, defeating grep and
    \\letting agents introduce invisible name collisions.
    \\Fix: import the module under an explicit name and qualify each use.
    \\Exempt: none in src/; test files are already allowed. Disable via the
    \\top-level `disabled` list only as a last resort.
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
    \\Fix: extract the shared types into a third module, or invert one edge.
    \\Exempt: none — cycles are always a defect. Break the loop.
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
    \\`hard_max_lines` block. Extract cohesive blocks into named helpers.
    \\Exempt: adjust either `[function_length]` limit, or disable the check.
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
    .{ .name = "compile-error-explanation", .text =
    \\Why: a bare `@compileError` with no message leaves the next person staring
    \\at an unexplained build failure.
    \\Fix: pass a non-empty string literal explaining the constraint.
    \\Exempt: none — always explain the error. Disable only in edge cases.
    },
    .{ .name = "init-hygiene", .text =
    \\Why: `if`/`while`/`for`/`switch` inside an `init`/`create`/`make` body means
    \\the constructor is doing work it should delegate — hard to test.
    \\Fix: keep init to plain field assignment; move logic to a named method.
    \\Test fixtures: a NON-PUB init referenced only from `test` blocks in its own
    \\file is already exempt — a fixture builder filling an array in a loop is
    \\doing its job, and renaming it (`init` -> `setupBoard`) to get past the
    \\check is a rename for the checker's benefit. If yours is still flagged it is
    \\`pub` (any file can construct with it) or something outside a test block
    \\references it: drop the `pub`, or move the builder into the test block.
    \\Exempt: disable via the top-level `disabled` list if your init genuinely
    \\needs branching.
    },
    .{ .name = "static-factory-ban", .text =
    \\Why: `.getDefault()`/`.singleton()`/`.shared()` are hidden global state an
    \\agent used instead of injecting the dependency.
    \\Fix: construct the value at the composition root and pass it in.
    \\Exempt: allowed in `main`/`wiring`; otherwise disable the check.
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
    \\For the multi-loop case the finding names the loop that asserts nothing —
    \\that fixture-building loop is the one to lift into a helper, leaving the
    \\asserting loop in the test.
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
    .{ .name = "boolean-param-ban", .text =
    \\Why: a bool parameter in a pub fn makes call sites unreadable
    \\(`f(true, false)`) and easy for an agent to transpose.
    \\Fix: take a two-case enum, or split into two named functions.
    \\Exempt: disable via the top-level `disabled` list.
    },
    .{ .name = "magic-number", .text =
    \\Why (opt-in): a bare integer literal is an unexplained constant an agent
    \\dropped in — meaning lost the moment it's read.
    \\Fix: name it as a `const` with a descriptive identifier.
    \\Exempt: off unless `[magic_number] enabled = true`; float idioms already
    \\allowed.
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
    .{ .name = "struct-method-cap", .text =
    \\Why: a type with too many `pub fn` methods is accreting responsibilities an
    \\agent should have split.
    \\Fix: extract a cohesive method group into its own type.
    \\Exempt: disable via the top-level `disabled` list.
    },
    .{ .name = "optional-density", .text =
    \\Why: a struct where most fields are `?T` models "anything can be missing" —
    \\an agent dodging a real state machine.
    \\Fix: split into required-vs-optional structs, or model states as a union.
    \\Exempt: disable via the top-level `disabled` list.
    },
    .{ .name = "stringly-typed-switches", .text =
    \\Why: switching on string literals is a fragile substitute for an enum — a
    \\typo an agent makes compiles and silently misroutes.
    \\Fix: define an enum and switch on it; parse strings to the enum at the edge.
    \\Exempt: disable via the top-level `disabled` list.
    },
    .{ .name = "repeated-switch-on-enum", .text =
    \\Why: the same enum prong-set switched in 2+ files means dispatch that should
    \\live on the type is scattered — every new variant is a shotgun edit.
    \\Fix: move the behavior onto the type (a method) so adding a variant is one
    \\edit.
    \\Exempt: disable via the top-level `disabled` list.
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
    .{ .name = "stdout-flush", .text =
    \\Why (report-only by default): in 0.15 a buffered `std.fs.File.stdout()/
    \\stderr()` writer that is never `flush()`ed silently TRUNCATES its output —
    \\the buffered bytes vanish when the writer leaves scope. This surfaces a
    \\function that builds such a writer (`.writer(...)` / `.writerStreaming(...)`)
    \\with no `flush(` in its body. By default it NEVER fails the build: the
    \\heuristic is intra-procedural, so a flush done by a called helper reads as a
    \\false positive and a flush on an untaken branch reads as a false negative —
    \\precision unproven, so report-only until a project trusts the signal.
    \\Fix: call `w.interface.flush()` (or `w.flush()`) before the function
    \\returns, on every path that wrote.
    \\Enable gating: set `[stdout_flush] enabled = true` to promote it to a
    \\hard-block — a finding then fails the build. The default (absent/`false`)
    \\stays report-only.
    \\Exempt: add paths via `[[allow]] check = "stdout-flush"`.
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
    .{ .name = "escape-discipline", .text =
    \\Why (opt-in): raw `{s}` interpolation into HTML/SVG is an XSS sink an agent
    \\builds when concatenating markup from untrusted text.
    \\Fix: route the value through an escaping helper before interpolation.
    \\Exempt: off unless `[escape_discipline] enabled = true`.
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
    \\a single file trim, with a 170-line disagreement against `grep -c` (guardian
    \\excludes `test { ... }` blocks from the file-size metric; grep does not).
    \\Fix: n/a — run `guardian-check size <path> [dir]`. It prints the file's code
    \\lines, per-fn length and runtime params, per-type field counts, and the count
    \\of over-long lines, each against the check's caps and its frozen ceiling with
    \\the headroom left. Add `--current` to `debt` for the same comparison
    \\tree-wide. The values come from the checks' own measurement functions, so
    \\they match what the gate would ratchet.
    \\Exempt: n/a — never part of `all`, never gates, never writes. Five ratchets
    \\(nesting-depth, cognitive-complexity, struct-method-cap, optional-density,
    \\bool-ops-per-condition) compute their metric inside the check's own threshold
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
    // init-hygiene: the test-fixture escape, so nobody renames init for the checker.
    try std.testing.expect(std.mem.indexOf(u8, lookup("init-hygiene").?, "setupBoard") != null);
    // change-classification: name the flow that does NOT clear it.
    try std.testing.expect(std.mem.indexOf(u8, lookup("change-classification").?, "not baseline churn") != null);
}

// spec: Explain - Documents the commit meta command

test "explain resolves and documents the commit meta command" {
    // commit is dispatched specially (not a registry entry) but is still
    // explainable: it has both a summary and a long-form entry.
    try std.testing.expect(lookup("commit") != null);
    try std.testing.expect(resolves("commit"));
}
