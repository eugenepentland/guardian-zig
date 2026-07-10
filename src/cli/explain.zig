//! `explain <check>` — long-form rationale for a check: why it blocks (the
//! AI-agent mistake it catches), how to fix a violation, and how to exempt it.
//! With no name — or an unknown one — it lists every registered command. The
//! one-line summary is pulled from the registry; the prose lives here as a
//! name→text table so registry.zig stays lean.
//!
//! Dispatched specially by check.zig (never a gate), so it may import the
//! registry without forming a cycle. Every registered command must have an
//! entry here — a unit test walks the registry and fails on any gap.

const std = @import("std");
const registry = @import("registry.zig");

const print = std.debug.print;

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
    \\Fix: split the file along a seam — extract a type or a helper group into
    \\its own module.
    \\Exempt: raise `max_file_lines`, list a glob in `file_size_exclude`, or
    \\disable via the top-level `disabled` list.
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
    \\with a non-empty reason.
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
    \\Why: a parameter list that keeps growing signals an agent bolting on args
    \\instead of bundling related inputs — each call site gets more fragile.
    \\Fix: group related parameters into an options/context struct.
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
    \\Exempt: `GUARDIAN_UPDATE_SNAPSHOT=1 zig build` and commit `.guardian/` once
    \\the surface change is deliberate.
    },
    .{ .name = "panic-budget", .text = 
    \\Why: agents scatter `@panic` / `unreachable` / `TODO` / `FIXME` as they
    \\stub, turning recoverable paths into crashes.
    \\Fix: handle the case explicitly (return an error) instead of panicking, or
    \\resolve the TODO.
    \\Exempt: `GUARDIAN_UPDATE_SNAPSHOT=1 zig build` to accept a deliberate new
    \\site and commit the snapshot.
    },
    .{ .name = "catch-discipline", .text = 
    \\Why: `catch unreachable`, `catch {}` and `catch undefined` convert a real
    \\error into a crash, silent swallow, or UB — a classic agent shortcut.
    \\Fix: handle the error with a `switch`, a named `catch |e|` body, or a
    \\deliberate return.
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
    \\writer/formatter boundaries.
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
    .{ .name = "stub-body-ban", .text = 
    \\Why: a single-statement `return undefined` / placeholder `@panic` /
    \\`unreachable` body is an agent's unfinished stub masquerading as done.
    \\Fix: implement the real body, or return a proper error until it exists.
    \\Exempt: none — finish the function. Disable only during migration.
    },
    .{ .name = "int-from-float-budget", .text = 
    \\Why: every new `@intFromFloat` is a lossy cast that silently mishandles NaN
    \\/ out-of-range values unless guarded.
    \\Fix: clamp/validate the float and document the range before casting.
    \\Exempt: `GUARDIAN_UPDATE_SNAPSHOT=1 zig build` after the guard review, then
    \\commit the snapshot.
    },
    .{ .name = "unsafe-ops-budget", .text = 
    \\Why: new `@ptrCast`/`@bitCast`/`@ptrFromInt`/… or `undefined` re-assignments
    \\are unsafe operations agents reach for to make types line up.
    \\Fix: prefer a safe conversion; if genuinely needed, isolate and comment it.
    \\Exempt: `GUARDIAN_UPDATE_SNAPSHOT=1 zig build` to accept the new count and
    \\commit the snapshot.
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
    \\Fix: extract cohesive blocks into named helpers.
    \\Exempt: raise `[function_length] max_lines`, or disable the check.
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
    \\Why: a mutable `pub var` global is shared hidden state — an agent's quick
    \\stash that causes spooky action at a distance.
    \\Fix: pass the state explicitly, or own it in a struct with a lifetime.
    \\Exempt: allowed in `wiring`/`main`; add paths via
    \\`[[allow]] check = "ban-globals"`.
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
    \\Fix: name intermediate booleans, or split the condition.
    \\Exempt: raise `[bool_ops] max_ops`, or disable the check.
    },
    .{ .name = "line-length", .text = 
    \\Why: very long lines force horizontal scrolling and hide the end of a
    \\statement an agent tacked on.
    \\Fix: wrap the line; `\\` multiline-string lines are already exempt.
    \\Exempt: raise `[line_length] max_len`, or disable the check.
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
    .{ .name = "change-classification", .text = 
    \\Why: agents ship a behavioral src change with no test — the "quick fix,
    \\no regression test" pattern that lets the same bug return.
    \\Fix: add a test (or `// spec:` tag / SPEC.md bullet) in the same change.
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
    .{ .name = "commit", .text = 
    \\Why: a meta command, not a gate — brings guardian-zig into the sibling
    \\guardians' intent-driven flow: run the whole gate, then commit the change
    \\set, with rails so a green build can't leak a secret or stage build output.
    \\Fix: n/a — run `guardian-check commit --intent "<message>" [dir]`. On green
    \\it stages the working-tree change set (never `git add -A`; forbidden
    \\secret/artifact paths skipped and reported; `.guardian/` + SPEC.md always
    \\included) and commits with the intent as the subject. On red it prints the
    \\violations and leaves git untouched. Never pushes, never amends.
    \\Exempt: n/a — never part of `all`; requires an explicit non-empty --intent.
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
    print("\nmeta commands: all, nightly, commit, version\n", .{});
}

/// Runs the explain command. `query` is the check name (null lists everything).
/// Returns false only when a non-empty name was given but is unknown, so the
/// caller can exit non-zero; true otherwise.
pub fn run(query: ?[]const u8) bool {
    if (query) |name| {
        if (!resolves(name)) {
            print("unknown check: {s}\n\n", .{name});
            listAll();
            return false;
        }
        print("{s} — {s}\n\n", .{ name, registry.summaryFor(name).? });
        print("{s}\n", .{lookup(name).?});
        return true;
    }
    listAll();
    return true;
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

// spec: Explain - Documents the commit meta command

test "explain resolves and documents the commit meta command" {
    // commit is dispatched specially (not a registry entry) but is still
    // explainable: it has both a summary and a long-form entry.
    try std.testing.expect(lookup("commit") != null);
    try std.testing.expect(resolves("commit"));
}
