# Guardian for Zig

Build-step quality gates for Zig projects, combining blocking correctness checks
with advisory maintainability guidance.

Requires Zig `0.17.0-dev.1683+5ceec001b`, the exact snapshot pinned by
`build.zig.zon`.

**Designed for AI agents.** Guardian catches mistakes by enforcing spec-driven development: every behavior in your SPEC.md must have a matching test, and every test must trace back to a spec.

## Quick Start

1. Add guardian to your `build.zig.zon`:
```zig
.guardian = .{ .path = "../guardian-zig" },
```

2. Wire it into `build.zig`:
```zig
const guardian = @import("guardian");
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
const check_exe = guardian_dep.artifact("guardian-check");

b.getInstallStep().dependOn(&b.addFmt(.{ .paths = &.{b.path("src")}, .check = true }).step);

// One call wires up every registered gate:
guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{});
```

The same call also registers a canonical `guardian` runner plus the consumer-facing `guardian-doctor`,
`guardian-debt`, `guardian-spec-sync`, `guardian-accept`, and
`guardian-explain` steps. Set `.maintenance_steps = false` only when a consumer
needs to own those step names itself.

3. Generate your SPEC.md:
```bash
zig build spec-init
```

4. Edit SPEC.md, add `// spec:` tags to tests, then build:
```bash
zig build  # guardian runs every check and REPORTS findings; the binary still builds
```

**Report during dev, block at commit.** By default (`[gate] on_build =
"report"`) a plain `zig build` runs every check and prints all findings but
exits 0, so a dev build never refuses to produce a binary. The gate BLOCKS —
fails the build on any violation — at commit time: `guardian-check commit`,
`nightly`, and `guardian-check all . --gate` (what the pre-commit hook runs)
always block regardless of `on_build`. Set `on_build = "block"` to make every
`zig build` hard-block as before. Run `guardian-check install-hook` (or let
`commit` auto-install it) so a raw `git commit` can't slip past the gate.

**Diff-scoped during dev, whole-tree at commit.** A plain local `zig build`
only re-reads what you changed. Guardian diffs the working tree against the
merge base with `main` (then `master`) and hands the *per-file* checks — shape,
naming, complexity, per-file style, the hidden-dependency bans — only those
files. Checks whose verdict is inherently whole-tree keep reading everything:
import cycles, cross-file duplicate literals/consts, repeated enum switches,
dead-pub and test-coverage reference maps, orphan-file and test reachability, the
SPEC↔tag map, and every tree-wide snapshot/budget (`pub-api-surface`,
`panic-budget`, `int-from-float-budget`, `unsafe-ops-budget`). The capability
is a `scope` field on each registry entry with **no default**, so a newly added
check has to classify itself.

Every scoped run says so, naming the base and how much of the tree it read, and
a scoped run counts as *partial*: it never stamps the green skip-cache (so a
later whole-tree run can't skip on it), never records a delivery event, and
never prunes, lowers, or rewrites a baseline or ratchet — from a partial view a
missing violation may just be an unread file, so shrinks report as matches
while new violations still fail.

Scoping is dropped — the whole tree is read — for `--full`, for any blocking
gate run (`--gate`, the pre-commit hook, `commit`, `nightly`, `accept`,
`migrate`), for any run that may write `.guardian/` metadata, when guardian.toml
or `.guardian/` has *uncommitted* changes (the caps every file is judged against
moved), and whenever the base or the diff can't be resolved. `--against <ref>`
picks an explicit base. Measured on a 234-file consumer tree: 42.0 s whole-tree
→ 15.5 s for a one-file edit.

### Prebuilt `guardian-check` — don't recompile an unchanged tool

Guardian is a `.path` dependency, so by default every consumer *compiles* it
into that consumer's own Zig cache. A project that gives each short-lived
worktree a private cache therefore pays a full cold `safe` compile of an
unchanged quality tool before any of its own code builds — one consumer
measured 49 s of a 53 s first build.

`addAllChecks` now looks for the binary a plain `zig build` already leaves in
the Guardian checkout (`<dep root>/zig-out/bin/guardian-check`) and runs *that*
instead. Measured here on a minimal consumer, `-Doptimize=ReleaseSafe`, fresh
`--cache-dir` per run:

| first build | compiled from source | prebuilt reused |
| --- | --- | --- |
| private local cache, shared global cache | 67.9 s | **11.3 s** |
| private local *and* global cache | 73.1 s | **15.4 s** |

Selection order, decided once per `addAllChecks` call:

1. **Guardian gating its own tree** (dependency build root == project build
   root) → always compile. Nothing else is considered — see below.
2. `GUARDIAN_PREBUILT=off` or `=0` → compile from source (the old behavior).
3. `GUARDIAN_PREBUILT=<path>` → run that binary.
4. `<dep root>/zig-out/bin/guardian-check` exists → run it.
5. Otherwise → compile from source.

**Fail closed.** A reused binary could predate the source it is gating, so every
prebuilt invocation depends on one prepended step:

```
guardian-selfcheck → guardian-check selfcheck <dep root>
```

`build.zig` hashes Guardian's own sources at configure time (`build.zig`,
`build.zig.zon`, every `.zig` under `src/`) and embeds the digest in the binary;
`selfcheck` recomputes that hash over the source root and compares. Both sides
import `src/source_digest.zig`, so they cannot drift. A mismatch **fails the
build** before a single check runs — it never degrades to a warning:

```
guardian: selfcheck: prebuilt guardian-check is stale vs its source (binary c845a5f2262e, source 11c27a552883)
  run `zig build` in /path/to/guardian-zig, or set GUARDIAN_PREBUILT=off to compile guardian-check from source
```

The walk costs under 10 ms, so the guard is free next to what it saves.
`guardian-check version` prints the same digest, and `zig build
guardian-selfcheck` runs the guard on its own.

Guardian's **own** build never takes this path, whatever `GUARDIAN_PREBUILT`
says: a `zig-out` binary gating the very source it was compiled from is the
stale-binary trap, and `selfcheck` cannot catch it there — the digest it
compares against is the stale one baked into that same binary.

One upgrade caveat: a prebuilt binary from a Guardian older than this feature
has no `selfcheck` command, so the guard step fails with Guardian's usage help
rather than the message above. `zig build` in the Guardian checkout (or
`GUARDIAN_PREBUILT=off`) clears it.

**`test-filter` — the same idea for the *test* suite, but report-only.**
`guardian-check test-filter .` derives the `test "…"` names declared by the
files your diff changed and prints them, so a local edit/verify loop can run
those instead of the whole suite:

```bash
eval "zig build test $(guardian-check test-filter . --args)"
```

(`eval`, not a bare `$(...)`: command substitution word-splits without
processing quotes, so a test name containing spaces would be torn into separate
arguments. The emitted names are POSIX single-quoted, which is what makes
handing them to `eval` safe.) `[test_filter] flag` sets how your project spells
the flag; `--json` is the machine-readable form.

Measured on a 1387-test consumer tree (Zig 0.15.1, 12 cores, ReleaseSafe test
binary): editing one file and running the suite costs **207 s** (a 3-minute
test-binary rebuild plus 9 s of test execution); the same edit with the derived
filter costs **26 s**. Re-running with nothing changed is 9.5 s unfiltered vs
0.2 s filtered. The saving is in the *compile*: `--test-filter` is a compiler
flag, so unmatched tests are never analyzed.

That is also exactly why this **never gates**. A filtered build does not
type-check the tests it skipped, so it cannot prove the test binary even
compiles — a production call site can change, its own test can go stale, and a
filtered run stays green. `commit`, the pre-commit hook, and CI always run the
whole `[gate] test_command`; nothing appends a filter to it. Every report
therefore prints its own blind spots alongside the names: unnamed `test { }`
blocks (unfilterable — they always run), changed files that declare no test,
changed paths that aren't indexed source, and the test count of every file that
transitively imports a changed one. An empty derivation prints *no* arguments,
so an interpolating pipeline degrades to the full suite rather than to zero
tests.

### The filtered loop's two honesty gaps, and the two things that close them

A filtered run is fast, and it lies in two specific ways. Both are properties of
`--test-filter` being a *compiler* flag — measured on Zig 0.15.1:

| What you see | What actually happened |
| --- | --- |
| `zig build test -Dtest-filter=typo` → `3/3 steps succeeded`, exit 0 | The filter matched **nothing**. Zero tests were compiled, zero ran. Identical output to a green suite. |
| A filtered run passes 59/59 | The tests it skipped were never analyzed. `zig build test` on the same tree can die with a compile error. |

**1. `guardian.testRunner(dep)` — a count you can see.** Guardian ships a custom
test runner that prints, before the first test executes:

```
guardian/test: 3 test(s) selected by filter: "wildcard"
```

and *fails the run* when nothing the filter named actually ran, because a
zero-match filter is evidence of nothing. Wire it in two lines:

```zig
const filters = b.option([]const []const u8, "test-filter", "Run only matching tests") orelse &.{};
guardian.enableTestDiagnostics(test_mod);              // keep assertion source lines in safe builds
const unit_tests = b.addTest(.{
    .root_module = test_mod,
    .filters = filters,
    .test_runner = guardian.testRunner(guardian_dep),  // <-- the count and the guard
});
const run_tests = b.addRunArtifact(unit_tests);
guardian.announceFilters(run_tests, filters);         // <-- what the filter was
```

Zig never tells a runner what the filter was, so `announceFilters` forwards the
texts as `--guardian-filter=` arguments. That is worth wiring: with the filters
in hand the runner counts how many *selected* tests a filter actually names, and
fails on zero. Without them it can only detect a completely empty binary — and
an unnamed `test { }` block has no name to match, so it compiles into every
filtered binary and pads the count. Guardian's own suite has two: a nonsense
filter there reports

```
guardian/test: 2 test(s) selected by filter: "nope" — 0 match by name, 2 unnamed test block(s) run regardless
```

and fails. The runner runs in `.server` mode, so the build system keeps its own
progress display, per-test failure attribution, and `--fuzz` support. Set
`GUARDIAN_TEST_ALLOW_EMPTY=1` for the one legitimate empty case — a project that
genuinely has no tests yet.

`enableTestDiagnostics` sets Zig's error-return tracing on the test module. It
is what keeps the assertion source location behind a plain `testing.expect`
when tests use `safe`/`fast`; without it the compiler discards that
trace and no runner can reconstruct the missing call site. Calling
`addTestCompileProbe` with the same module enables this automatically.

**2. `guardian.addTestCompileProbe(b, …)` — the compile-only middle tier.**
Between "filtered run" (seconds, proves little) and "the gate" (minutes) sits the
cheap question a filtered loop can never answer: *does the whole suite still
compile?* One line registers `zig build test-compile`:

```zig
_ = guardian.addTestCompileProbe(b, .{ .root_module = test_mod });
```

It declares no filters and never asks for the binary, so the build system passes
`-fno-emit-bin`: every test is type-checked, nothing is linked, nothing runs.
Measured on Guardian's own 756-test suite (Zig 0.15.1): a source edit costs
**~2 s** to re-analyze this way, against minutes for the full `zig build test`
— the saving is codegen and linking, which a type-check question does not need.
It is deliberately **not** a dependency of `test` — making it one would rebuild
the whole suite on every filtered run and erase the reason to filter. The
recommended loop:

```bash
zig build test -Dtest-filter='the thing I am changing'   # fast, narrow, honest about its count
zig build test-compile                                   # cheap: does everything still compile?
guardian-check commit --intent "..."                     # the gate: whole suite, whole tree
```

## What It Checks

Guardian's self-build runs 68 registered checks. Most hard-block under the default
`strict` policy; `stdout-flush` remains report-only unless explicitly promoted,
and several checks are opt-in or become active only when configured. The list
below is grouped by FRAMEWORK.md tier; defaults are recalibrated toward larger,
evidence-based thresholds. Retired and folded check names remain tolerated in a
`disabled` list so upgrades do not break existing configuration.

### Spec workflow
| Check | Blocks on |
|---|---|
| **spec** | Missing SPEC.md, unverified behaviors, unlinked tags, duplicate tags |
| **spec-quality** | Vague phrases (`properly`, `as needed`, etc.); behaviors shorter than 20 chars |
| **completeness** *(opt-in)* | A `## ` SPEC.md feature section that doesn't address (or `completeness-waiver:`) each of the 8 scenario categories: empty/large inputs, unauthorized access, I/O failure, concurrent access, malformed encoding, integer overflow, panic-free. Off unless `[completeness] enabled = true`; exempt non-feature sections via `[completeness] exempt_sections`. Check a section *before* running the gate with `guardian-check explain completeness --section "<name>"` |

#### Spec failures come with the fix

`spec` blocks on frozen text — a violation line is what a consumer's baseline is
keyed by — so everything it *learned* rides the advisory channel beside it, and
survives baseline mode (which otherwise replaces a check's own output with its
outcome report). On any run with unlinked tags you also get:

* **one line per unlinked tag, never just the first**, each carrying its fix:
  the exact bullet to paste, or `a bullet with this exact text already lives
  under `## Other`` when the bullet landed under the wrong heading (that mistake
  otherwise reads as two unrelated findings — one `unlinked tag:` and one
  `unverified:` — that never say they are the same behavior), or
  `closest bullet is X (1 char(s) apart)` when the two texts merely drifted;
* a note that **the tag scan walks `test/` and `src/` on disk, not the compiled
  test set** — so a `-Dtest-filter` build sees the same list and the list is
  complete. Believing otherwise is what turned one edit into an edit-per-tag
  loop for three consumer sessions;
* `N other tag(s) here are baselined-unlinked` for a file whose *other* tags are
  frozen debt in `.guardian/baselines/spec.txt` — previously discoverable only
  by grepping that file, and easy to misread as the house style to copy.

Tags already frozen in the baseline get no hint: the guidance is about the work
in front of you, not the backlog behind it.

```
$ guardian-check explain completeness --section "Widgets" .
completeness --section "Widgets" — 3/8 categories satisfied in SPEC.md

  ok       empty inputs           bullet: Rejects an empty request body with a 400
  ok       large inputs           bullet: Streams a very large widget list without buffering it whole
  MISSING  unauthorized access    add a bullet with one of its keywords, or waive it
  waived   concurrent access      reason: single-threaded CLI, one request at a time
  NEEDS    panic-free             waiver has no (reason) — add one
  …
Categories, and the keywords a bullet may contain to address one:

  empty inputs          empty | no input | zero-length | zero length | blank
  integer overflow      overflow | underflow | saturat | wraparound | wrap-around
  …
```

Naming a section SPEC.md does not have yet prints the paste-ready skeleton
instead — the point being that adding a new `## ` section no longer costs a
whole build to find out whether its eight waivers landed. `explain completeness`
without `--section` prints the same keyword table, which was previously
discoverable only by reading the check's source.

### Process gates (git-aware)
| Check | Blocks on |
|---|---|
| **change-classification** | Behavioral lines added to `src/**.zig` (vs `--against` / `GUARDIAN_AGAINST` / `[change_classification] against`, default HEAD) with **no** test-block lines, `// spec:` tags, or an added/modified SPEC.md **behavior bullet** in the same diff — the "quick fix with no regression test" pattern. A spec edit waives the test only when it adds/modifies a `- ` bullet outside a code fence (a prose/typo/header edit no longer counts). When the base is HEAD and the working tree is clean, it gates the **last commit** (`HEAD~1..HEAD`) instead of passing an empty diff — skipping merge/root commits, toggled by `[change_classification] gate_last_commit`. Skips silently outside a git repo. |
| **policy-drift** *(opt-in)* | Changes, deletions, or renames affecting protected Guardian policy/debt paths without trusted CI approval |
| **external-gates** *(configured)* | A project-defined argv command exits nonzero or cannot be started; commands never run through a shell |
| **merge-state** | A `.guardian/` metadata file left mid-merge: git's conflict markers still in it, a counter merge the driver had to guess (`# guardian-merge: regenerate`), or a row that does not parse in its own format. Each of those reads as ordinary debt to every other check, so the tree would otherwise gate green on numbers nobody measured. The fix line names the exact `GUARDIAN_UPDATE_SNAPSHOT=<check> zig build` per file |

### Formatting (runs first)
| Check | Blocks on |
|---|---|
| **formatting** | Any `src/` file that differs from `zig fmt` output. Scheduled **before** every other check and flushed immediately, because it is the cheapest gate and its fix is one command: the finding names the file, the first line that differs, and the exact `zig fmt <file>` to run. A consumer wiring Guardian can drop its own `b.addFmt(.{ .check = true })` step. Exempt via the top-level `exclude` globs or `disabled` |

### Structural
| Check | Blocks on |
|---|---|
| **file-size** | Warn above `max_file_lines` (default 1000); fail above `hard_max_file_lines` (default 10000) |
| **module-doc-header** | Any src file over `[module_doc_header] min_lines` lines (default 200) that doesn't open with a `//!` module doc block (≥2 lines or ≥60 chars); lower `min_lines` to require headers on smaller files; exempt paths via `[[allow]]` |
| **function-size** | Any function with more than `max_params` runtime parameters (default 6); `comptime` specialization inputs do not consume the budget |
| **function-length** | Warn above `max_lines` (default 120); fail above `hard_max_lines` (default 400) |
| **nesting-depth** | Any fn body with brace nesting over `max_depth` (default 5) |
| **type-size** | Any pub struct/enum/union over `max_fields` (default 7) |
| **imports** | Cycles in the `@import` graph |
| **boundaries** | Forbidden `@import` paths per module rules |
| **orphan-files** | A .zig file unreachable from any configured root via `@import` |
| **test-reachability** | A .zig file that declares `test` blocks no test root REFERENCES — Zig never compiles those tests, and the spec check no longer counts their `// spec:` tags as covered (it reports them instead). Reachability follows the referencing edges, not every textual `@import`: `_ = @import("x.zig")`, `_ = alias`, `@import("x.zig").member`, `refAllDecls`, and any import alias the file actually uses — an import nobody mentions compiles nothing. Roots come from `[test_reachability] roots`, else `src/main.zig` / `src/root.zig` / `src/test_root.zig` / `src/tests.zig` / each `.zig` directly under `test/`; when no root resolves the check skips instead of blocking. It also holds that model against ground truth: `guardian-check commit` records how many tests its own run selected (the runner's `guardian/test: N test(s) selected` line), and a run that compiled FEWER tests than the roots reach is reported as a count gap — the model cannot see a reference sitting in code no test analyzes, and the measurement can |
| **test-coverage** *(opt-in)* | A pub fn with no identifier reference from any test block |

### Public API
| Check | Blocks on |
|---|---|
| **pub-api-surface** | Unintended additions/removals to the public API, or a changed `pub fn` signature (snapshot diff) |
| **dead-pub** | A `pub fn` / `pub const` referenced nowhere in the project (optionally ignoring test-only references) |

### Code style
| Check | Blocks on |
|---|---|
| **naming** | PascalCase fns that don't return `type`; lowercase types; SCREAMING_SNAKE container-scope consts (Zig consts are snake_case, or PascalCase for a type; a C-ABI mirror opts out via `[[allow]] check = "naming"`); vague public identifiers (`tmp` / `data` / `Manager` / `Util` etc.) |
| **doc-comments** | `pub fn` or `pub struct/enum/union` missing a `///` doc comment (protocol names `deinit`/`format`/`next`/`reset` exempt, extend via `doc_quality.exempt_names`), or one that's empty / placeholder / under `min_chars` (default 12) |
| **cognitive-complexity** | Per-function complexity score (default 25) |
| **anytype-budget** | More than `max_per_file` `anytype` parameters (default 2) |
| **usingnamespace-ban** | Any `usingnamespace` in `src/` |
| **deprecated-alias** | Deprecated 0.15 std spellings by token match: `std.ArrayListUnmanaged` (→ `std.ArrayList`), `std.array_list.Managed`, managed `std.StringHashMap`/`AutoHashMap`(`+Array`) constructions (→ the `*Unmanaged` maps — discouraged, not deprecated; `[[allow]]` opts out per path), `usingnamespace` (removed in 0.15), and pre-Writergate `getStdOut`/`getStdErr`. String/comment mentions are never flagged |
| **stdout-flush** *(report-only by default)* | A function that builds a buffered `std.fs.File.stdout()`/`stderr()` writer (`.writer` / `.writerStreaming`) but has no reachable `flush()` — in 0.15 a missing flush truncates the output. Intra-procedural heuristic (a flush in a called helper reads as a false positive), so it is **report-only by default** — findings surface without failing the build. Set `[stdout_flush] enabled = true` to promote it to a gating hard-block; the default (absent/`false`) keeps the report-only behavior. Exempt paths via `[[allow]] check = "stdout-flush"` |

### Error handling
| Check | Blocks on |
|---|---|
| **error-discipline** | Inferred `!T` or `anyerror!T` on `pub fn` (require explicit error sets) |
| **catch-discipline** | `catch unreachable` and `catch {}` (silent error swallow) |
| **unwrap-discipline** | `orelse unreachable` / `orelse undefined` (crash/UB on null) |
| **stack-escape** | Returning `&local` / a slice of a stack array / `&local.field` / a `const` alias of `&local` — a dangling pointer into the dead frame |
| **stub-body-ban** | Single-statement bodies that are `return undefined`, placeholder `@panic`, or `unreachable` in non-noreturn fns |
| **panic-budget** | Increase in `@panic` / `unreachable` / `TODO` / `FIXME` counts, or `@setEvalBranchQuota` call count / max literal (snapshot) |
| **int-from-float-budget** | Increase in the `@intFromFloat` count — each new lossy float→int cast needs a NaN/range guard review (snapshot). Casts inside a body of a `[int_from_float] guard_fns` wrapper don't count (the wrapper *is* the guard, e.g. a `checkedInt` that validates isFinite+range first); optional `require_guard` path globs additionally **hard-fail** any unguarded cast under them |
| **unsafe-ops-budget** | Increase in any unsafe-cast builtin count (`@ptrCast`, `@alignCast`, `@bitCast`, `@ptrFromInt`, `@intFromPtr`, `@constCast`, `@volatileCast`) or in `undefined` re-assignments to a live lvalue; declaration-init and test blocks exempt (snapshot) |
| **assert-doc-consistency** | A fn whose `///` doc carries the Zig-core `Asserts` precondition convention (whole word, case-sensitive) but whose body has no `assert(` call — the doc promises a guard the code never performs (exempt paths via `[[allow]]`) |
| **fatal-exit** | A hand-rolled `std.process.exit(<nonzero>)` outside the process entry file (auto-detected by its `fn main`) or the designated fatal-helper file (`[[allow]] check = "fatal-exit"`). `exit(0)` / `std.process.cleanExit` are fine — route hard exits through `reporter.fatal` (Zig-core `std.process.fatal`), which keeps the `guardian:` prefix. Lexical `process.exit(` match, so string/comment mentions never fire |

### Allocation
| Check | Blocks on |
|---|---|
| **allocator-hygiene** | Hardcoded `std.heap.page_allocator` / `c_allocator` / `GeneralPurposeAllocator` / `testing.allocator` outside `pub fn main` / tests (suppress a deliberate site with a `// allocator-ok:` comment) |
| **escape-discipline** *(opt-in)* | Raw `{s}` interpolation into HTML/SVG markup without an escape helper (XSS sink) |
| **oom-discipline** *(opt-in)* | A swallowing `catch` on an allocating call that conflates `OutOfMemory` with "not found" |

### Hidden Dependency Bans (Tier 1)
Every nondeterminism source must be injected, not acquired. Each check ships with the FRAMEWORK.md symbol list baked in — except `ban`, whose rules are yours.

| Check | Blocks on |
|---|---|
| **ban** *(configured)* | A symbol chain named by a `[[ban]]` entry, used inside that rule's `paths` and outside its `allow`. The project's own bans, on the same engine as the checks below: `chain = ["optimizer", "placeFromPoses"]` bans `optimizer.placeFromPoses`, `paths` scopes where (omit = the whole tree), `allow` exempts the sanctioned wrapper, and `reason` names the alternative and closes every violation. No entries = a trivial pass. Matching is textual over identifier tokens with no alias resolution: any *reference* counts (not just calls), a chain in a string/comment never does, and uses in `test {…}` / `pub fn main` are allowed — same as every ban-* check. Exempt a file from all rules with `[[allow]] check = "ban"` |
| **ban-time** | `std.time.timestamp` / `nanoTimestamp` / `Instant.now` etc. outside `infra/clock` |
| **ban-rng** | `std.crypto.random` / `std.Random.DefaultPrng.init` outside `infra/random` |
| **ban-fs** | `std.fs.cwd` / `openFileAbsolute` etc. outside `infra/fs` |
| **ban-net** | `std.net.*` / `std.http.*` outside `adapters/http` or `infra/net` |
| **ban-env** | `std.process.getEnvVarOwned` etc. outside `config` or `main` |
| **ban-sleep** | `std.Thread.sleep` / `std.time.sleep` outside test infrastructure |
| **ban-globals** | A file-scope `var` (pub or not, `threadlocal` included) or a `pub var` at container scope, outside `wiring` / `main` — mutable process-lifetime global state. Test files exempt; `[[allow]] check = "ban-globals"` grants path exemptions (Guardian's own `reporter.zig` threadlocal singleton). Struct-scope non-pub container `var`s are out of scope |
| **ban-hardcoded-paths** | absolute `/etc`, `/usr`, Windows `C:\`, `http://`, `https://` literals |
| **ban-secrets** | hardcoded credentials — known vendor token formats (AWS/GitHub/Slack/Google/OpenAI/Stripe-live/JWT), PEM private-key headers, and entropy-gated `password`/`token`/`secret`-named assignments (precision-first: publishable/test keys and placeholders are ignored) |
| **debug-print-ban** | `std.debug.print` and `std.log.*` outside `pub fn main` / tests / CLI command modules (`cli/*`, `commands*`) |

### Constructor & DI Hygiene (Tier 1)
| Check | Blocks on |
|---|---|
| **compile-error-explanation** | `@compileError` without a non-empty string literal |
| **init-hygiene** | `init` / `create` / `make` body containing `if`, `while`, `for`, or `switch` |
| **static-factory-ban** | `.getDefault()`, `.singleton()`, `.shared()` etc. outside `main` / `wiring` |
| **init-deinit-symmetry** | A pub struct with an `allocator:` / `gpa:` field but no `pub fn deinit` |
| **errdefer-in-init** | An `init` body with 2+ `try` calls and no `errdefer` |

### Test Hygiene (Tier 1)
| Check | Blocks on |
|---|---|
| **test-has-assertion** | A named `test "..." {…}` block with no `expect*` call |
| **test-no-conditional** | `if` / `while` / `switch` or 2+ `for` loops at the top level of a test body |
| **test-skip-ban** | A test whose body is empty or whose first statement is an unconditional `return error.SkipZigTest;` — it still satisfies its `// spec:` tag while never running (a conditional `if (…) return error.SkipZigTest;` is legal) |
| **prod-imports-no-test** | Production code `@import`-ing a `*_test.zig` or `tests/` path |
| **fuzz-presence** *(opt-in)* | A file in `[fuzz_presence] modules` that has no `std.testing.fuzz` call (or is missing/unreadable — fail-closed). Off unless `[fuzz_presence] modules` names at least one path; guardian points it at the parser/matcher/scanner cores it fuzzes |

### Complexity Bounds (Tier 1)
| Check | Blocks on |
|---|---|
| **bool-ops-per-condition** | More than `max_ops` (default 3) `and`/`or`/`!` per condition |

### Tier 2 Anti-patterns
| Check | Blocks on |
|---|---|
| **line-length** | Warn above `max_len` (default 120); fail above `hard_max_len` (default 240; `\\` multiline-string lines skipped) |
| **boolean-param-ban** | A `bool` parameter in any `pub fn` |
| **magic-number** *(opt-in)* | Bare integer literals outside the small allowlist (float idioms like `0.5` / `1e-9` allowed) |
| **repeated-string-literal** | The same string literal appearing 3+ times in one file, or the same `pub const NAME = "literal"` across 2+ files |
| **concept** *(configured)* | A literal spelling named by a `[[concept]]` entry, found in a file the rule's `owner` list doesn't cover. Guardian's first **relational** check: every other one judges a single item (a file, a function), this one says a literal has a HOME and anywhere else is a copy that will drift. `literals` are exact substrings; `patterns` add a minimal wildcard (`*` = one or more characters that are not whitespace, a quote, or structural punctuation (`,;=:(){}[]`), so `In*.Cu` catches `In1.Cu` inside a string but never spans two tokens, a newline, or minified code; `*` is the only metacharacter and a run of them collapses to one). Matching is **lexical, not AST, on purpose** — drift crosses languages, so `files` globs scan any extension (`*.css`, `*.js`). Two contexts are exempt so the frozen ledger stays real: a line that IS a comment (line-leading `//`; a trailing comment shares a code line, which counts whole), and a Zig `test` block — a golden literal there is the independent witness a sync-triangle test is supposed to spell, not a second authority. A rule's `files` globs scope THAT rule only (a JS-only rule never reports a Zig offender); a rule with no `files` key is judged against the walked source set. String escapes resolve, so `literals = ["\"id\""]` names a spelling that CONTAINS quotes — the discriminator between a wire-format id and a bare enum tag of the same name. One violation per (file, concept) naming the count, the occurrence lines, the owner and the `reason`; keyed `<file>|<name>`, so an offender file freezes as a whole and a NEW file fails. `guardian.toml` and `.guardian/` are always exempt; no entries = a trivial pass |
| **divergent-const** | One file-scope `const NAME` holding **different** values in 2+ files — `silk_stroke_mm` 0.12 in the Gerber writer and 0.15 in the `.kicad_mod` writer, `max_footprint_bytes` 1 MiB in four readers and 256 KiB in two. Note the polarity against repeated-string-literal: same name + same value is harmless here, same name + DIFFERENT value is the risk. Values are compared FOLDED (`16 << 20` = `16 * 1024 * 1024` = `16_777_216`, `1_000_000` = `1_000_000.0`); an initializer that does not fold to a number is skipped. Default `mode = "units"` groups only names whose trailing `_` segment is a unit (`_mm`, `_bytes`, `_ms`, `_hz`, …); `mode = "all"` groups every name and `ignore_names` exempts the generic ones. A `/// mirror-of: <path>.zig.<name>` doc annotation exempts a const from the divergence rule and instead requires it to EQUAL that referent. Keyed by the NAME |
| **twin-referent** | A comment CLAIMING a relationship (`mirrors`, `same as`, `twin of`, `in lockstep with`, `verified against`, `matches`) whose named referent does not resolve — a doc pointing at a deleted function, a file that was split into a directory, `optimizer.INNER_LAYER_COLORS` where the symbol is lowercase. Precision by construction: the phrase alone is never reported, only a phrase followed IN THE SAME SENTENCE by something code-shaped — a word ending in `.zig` (no glob, non-empty basename) or a dotted chain rooted in a module of the tree. Resolution is containment, not semantics: a path must name an indexed file (exactly or as a tail at `/`), a chain's final symbol must be declared, named as a field, or dereferenced anywhere in the tree; `std.*` / `builtin.*` are skipped. A hard-coded `file.zig:120-160` range is reported outright. Keyed `<file>|<referent>` |
| **duplicate-json-key** | One function writing the same `"key":` twice into the same JSON object — last-wins today, a `SyntaxError` under any strict reader. Scoped by OBJECT SEGMENT so a function writing two sibling objects is silent: a `{`/`}` a literal actually emits (`{{`/`}}` included) ends a segment, and so does a completed call between two literals, an `else` / switch `=>` / `return` (alternatives, not a sequence). A format placeholder (`{d}`, `{s}`) is a value, not a brace. A literal must also be an argument to a call that WRITES (`print`/`write`/`format`/`append`), so `std.mem.indexOf(u8, body, "\"dnp\":true")` is not a write. Test blocks are never scanned. Keyed `<file>|<fn>|<key>` |
| **struct-method-cap** | Pub container with > 20 `pub fn` methods |
| **optional-density** | Pub struct where > 50% of fields are `?T` |
| **stringly-typed-switches** | `switch` whose case keys are string literals |

### Tier 3 Architectural Fitness
| Check | Blocks on |
|---|---|
| **repeated-switch-on-enum** | The same enum prong-set switched in 2+ production files; test blocks are ignored and the diagnostic names every collision file |

Plus `zig fmt --check`, wired as a format gate alongside the checks. The
`spec-init`, `mutate`, `debt`, and `history` steps are non-gating — see [Tools](#tools).

## Mutation testing (`mutate`)

Static checks prove tests *exist*; `mutate` proves they *bite*. Each mutant is
one small deliberate bug spliced into production code (comparison flips
`==`/`!=`/`<`/`<=`/`>`/`>=`, binary `+`/`-` and `+=`/`-=` swaps, `and`/`or`
swaps, `true`/`false` flips — test blocks are never mutated). The suite runs
against each mutant; a mutant every test passes **survived**, and survivors
are the gaps where your tests weren't constraining behavior.

```bash
zig build mutate        # fast tier: mutate only lines changed vs HEAD
zig build mutate-full   # nightly tier: whole tree + score ratchet
```

Two tiers:
- **Fast** (default): mutants are restricted to lines changed vs the diff
  base (`--against <ref>` / `GUARDIAN_AGAINST` / config, default HEAD), plus
  all of any untracked new file, sampled to `fast_max_mutants`.
- **Full** (`--full`): the whole tree, sampled down to `max_mutants`. The
  score is ratcheted in `.guardian/mutation.txt` — it can never drop without
  `zig build guardian-accept -Dguardian-checks=mutate`.

Both tiers fail below `min_score_pct` (default 80) — but only once the run has
at least `min_mutants` (default 4) **viable** mutants. Below that floor a single
survivor would be a meaningless red (1 of 2 = 50%), so the run instead lists its
survivors *informationally* and exits green (`N viable mutant(s) below
min_mutants=M — informational, not gated`). The floor mostly bites the fast tier,
where a tiny diff can produce only a mutant or two; a below-floor run never
records the score ratchet. Scoring includes only conclusive killed/surviving
mutants; compile errors are *unviable*. A timeout is retried with a larger
deadline, and a repeated timeout is *inconclusive*: it cannot inflate the score
and prevents the run from updating its ratchet.
During mutant runs guardian sets `GUARDIAN_MUTATION_RUN=1` on child builds, and
every guardian command no-ops under it — so the deliberately-broken tree isn't
gated against itself.

### Per-mutant timeout (process-group kill)

A mutant that turns a loop condition into an infinite loop makes the spawned
suite spin forever. Guardian bounds every mutant with a **per-mutant deadline**
= `max(timeout_floor_secs, timeout_multiplier × baseline)`, where `baseline` is
the wall time of one clean, un-mutated `zig build test` measured once at the
start of the run (defaults: floor **30s**, multiplier **5**, cargo-mutants
style). A fast suite is floored so a slow-to-compile mutant isn't mistaken for a
hang; a slow suite scales up so only a genuine runaway trips. When the clean
suite can't be measured (it errors or itself hangs past `timeout_secs`), the
deadline falls back to `timeout_secs`.

Each mutant's `zig build`/`zig build test` runs in its **own process group**
(`setpgid`), and on deadline the watchdog kills the **whole group**
(`kill(-pgid, SIGKILL)`) — so the compile/test *grandchildren* an infinite-loop
mutant would otherwise leave spinning at 100% CPU die with the build, not just
the direct child. On the first timeout Guardian retries that phase using
`timeout_retry_multiplier` (default 2). A repeated timeout is recorded as
`inconclusive`, fails the campaign without changing its score ratchet, and a
clear line prints the file, mutation, elapsed, and deadline. A per-mutant
heartbeat (every 15s) prints the in-flight mutant's elapsed vs. deadline, so a
stalled run is distinguishable from a merely slow one.

Mutation child builds use the disposable `.guardian/cache/zig-mutate` local
cache while keeping Zig's normal global dependency cache. Guardian removes this
one-use cache after the campaign and on recovery, preventing mutation-only build
artifacts from permanently growing the project cache. If `smoke_step` is set,
Guardian first verifies it on the clean tree, then uses it as a cheap first stage
for every mutant; smoke survivors still run the complete `test` step.

Sampling ranks stable mutant identity hashes rather than taking every k-th
candidate, so unrelated insertions do not reshuffle the whole cohort. A stable
within-line column distinguishes repeated operators on one line. The exact
selection is written to `.guardian/cache/mutation-cohort.jsonl`; the full ratchet
stores its cohort digest and reports cohort turnover instead of comparing scores
from incompatible samples. Exact suite-digest outcome caches retain the latest
`retained_cache_suites` cohorts and are never reused across differing digests.

### Crash-safe mutant journal

A mutant is spliced into the *real* source file, so a run that dies mid-mutant
(a user `SIGKILL`ing a stuck run, an OOM, a crash) would leave the broken bytes
on disk. Three layers prevent that:

- **Journal.** Before each splice, the original bytes + a hash of the mutated
  file are written to `.guardian/cache/mutant-in-flight.json`; a normal restore
  clears it.
- **Signal handlers.** `SIGINT`/`SIGTERM` (e.g. Ctrl-C) kill any running child
  group, revert the in-flight file, and re-raise — so an interrupt never leaves
  a mutated file or a spinning child behind. `SIGKILL` can't be caught; that's
  what the journal is for.
- **Startup recovery.** Every `mutate` run first checks for a journal a dead run
  left behind and reverts it (verified against the recorded hash); if the file
  has changed since, it refuses and warns loudly rather than clobber the edit.

### Survivor report

Every survivor prints its `file:line`, the operator swap (`original -> replacement`),
and the **original source line** — the exact context an agent needs to write the
killing test:

```
  src/parser.zig:88: `>` -> `>=` survived
      if (depth > max) return error.TooDeep;
  fix: strengthen the tests these mutants slipped past — assert the exact values, not just success.
```

The same survivors are written machine-readably to
`.guardian/cache/last-mutate.jsonl` — one `{"type":"survivor","file":…,"line":…,
"op":…,"original_line":…}` record per survivor, then a `{"type":"summary",…}`
record (tier, score, outcome counts, `waived`, `cached`, `gated`). std.json does
the escaping; no timestamps. Agents read the log instead of scraping terminal
prose.

### Result cache (resume / re-run)

Each mutant's outcome is a pure function of the tree state and the mutant's
identity, so guardian caches it in `.guardian/cache/mutants.jsonl` (git-ignored
and excluded from the skip-cache digest, so it never churns git or the build
cache). A mutant whose `(suite digest, identity)` key is already recorded skips
the build+test cycle and reuses the outcome, marked `(cached)`.

The **suite digest** hashes every `src/`+`test/` `.zig` file plus `build.zig`,
`build.zig.zon`, and `guardian.toml`, so **any source or test change invalidates
every record** — correctness first: the cache never replays an outcome a change
could have altered. Its value is therefore *repeating a run at the same tree
state*: resuming an interrupted run (completed mutants are flushed immediately,
so a re-run picks up where a `Ctrl-C`/CI-timeout/OOM left off), a CI retry, or
re-running after a doc-only edit or a red gate that didn't touch sources. The
file is append-only during a run and compacted on load (stale-suite records
dropped, latest outcome per identity kept). A snapshot refresh
(`GUARDIAN_UPDATE_SNAPSHOT=mutate` / `=all`) bypasses cache reads entirely — a
fresh ratchet must be a fresh measurement.

### Equivalent-mutant waiver (`// mutate-ok`)

Some mutants are *equivalent* — no test can ever kill them because they don't
change observable behavior. The classic case is `>` vs `>=` on a min/max-style
scan:

```zig
// `>` and `>=` are equivalent here: on a tie we keep the first-seen max either
// way, so no test distinguishes them.
if (candidate > best) best = candidate; // mutate-ok: min/max boundary equivalence
```

A source line containing `// mutate-ok` (optionally `// mutate-ok: <reason>`) is
excluded from mutant **generation** in both tiers; the run reports `W site(s)
waived via mutate-ok` and the score is computed over the remaining mutants.
**Use sparingly** — a waiver you add to silence a *real* survivor is a test you
didn't write. Reserve it for genuinely equivalent mutants and say why in the
reason.

`mutate` is an explicit step, never part of `all`: each mutant costs a build
+ test cycle. **`addAllChecks` auto-registers the `mutate` and `mutate-full`
steps for you** (`opts.mutate_steps` defaults `true`), so every consumer gets
the mutation tier the day it upgrades — no hand-wiring. The registration is
idempotent, so calling `addAllChecks` more than once (install + test steps) is
safe, as is keeping your own hand-rolled `mutate` step. Opt out with
`addAllChecks(b, check_exe, step, .{ .mutate_steps = false })`.

### `nightly` — the scheduled tier

`guardian-check nightly [dir]` runs the full `all` suite, then `mutate --full`
on the same tree, and fails if either fails. It's the obvious cron/CI home for
the whole-tree ratchet that `mutate-full` alone rarely gets scheduled into. A
suggested CI split: `GUARDIAN_AGAINST=origin/main zig build mutate` on PRs
(fast tier, changed lines only) and `guardian-check nightly .` on a schedule.

### Future work (not yet shipped)
The plan to mechanise FRAMEWORK.md into Guardian leaves a few rules deferred:
- **allocator-injection** — needs full parameter-list AST parsing to avoid false positives on every `pub fn run(ctx: *RunCtx)`. `allocator-hygiene` covers the worst case (hardcoded global allocators) until then.
- **train-wreck** — depth-2 member-access analysis was prototyped but produced too many false positives on legitimate `tree.tokens.items` / `obj.field.method()` chains; needs taint-style filtering.
- **parallel mutants** — the engine splices each mutant into the *real* source tree in place, which forbids running mutants concurrently (two would corrupt each other's file). Copy-tree / worktree sandboxes would parallelize, but they break consumers with a relative-path dependency: the production consumer depends on guardian via `.path = "../guardian-zig"`, and a sandbox at a different directory depth resolves that relative dep to the wrong location (building against the wrong guardian, or failing outright). Guardian can't know or safely rewrite consumer manifests, so a general copy-tree parallelism would be flaky in exactly the setup that matters. Deferred until a depth-preserving sandbox with collision-safe naming proves out; a working sequential engine beats a flaky parallel one. In the meantime the wall-clock cost is mitigated two ways: the **fast tier** only mutates changed lines (usually a handful), and the **result cache** skips unchanged mutants and resumes interrupted runs, so a re-run is near-instant.
- **same-type-adjacent-params**, **identical-switch-case** — both need the AST helper to expose parameter types and switch-case bodies.
- **stable-deps** — extending `import_graph.zig` with per-node Ce / Ca / I metrics. Designed but not implemented.
- **dup-tokens** — token-window hashing with snapshot ratchet. Designed but not implemented.
- **port-implementations** — opt-in via `[[port]]` declarations. Designed but not implemented.

## Fuzzing

Guardian's hand-rolled scanners eat untrusted text — arbitrary `guardian.toml`
bytes, config glob patterns, and whole source files — so the parser/matcher/
scanner cores carry `std.testing.fuzz` harnesses (the guardian.toml parser, the
`matchWildcard` glob cursor, and the `text.TestScope` brace tracker).

```bash
zig build test          # harnesses run once per corpus entry + empty input (smoke)
zig build test --fuzz -Dfuzz-filter="fuzz: guardian.toml parser"
                        # deep run: select exactly one harness for libFuzzer
```

Under a plain `zig build test` each harness runs as a smoke test — the test
runner calls it on every seeded corpus entry plus the empty string, so a
regression in the reject paths reds the normal build. `--fuzz` turns the same
harnesses into a coverage-guided search (it needs a toolchain whose fuzzer
coverage instrumentation is working; the smoke path always runs). Each asserts
an invariant rather than success: the parser may reject input, but a reject must
populate its diagnostic; a star-free glob matches iff the candidate equals the
pattern; the scope tracker never underflows and keeps `test_depth <= depth`.

## Spec-Driven Workflow

```markdown
## Authentication
- Validates JWT tokens on every request
- Rejects expired tokens with 401
```

```zig
// spec: Authentication - Validates JWT tokens on every request
test "jwt validation" { ... }
```

Guardian enforces **1:1 mapping**: every spec behavior needs exactly one primary
test tag. For durable links, prefix a behavior with an ID containing a digit;
the prose can then change without breaking the test link. Extra focused cases
use `spec-case` and do not weaken the required primary link:

```markdown
- [AUTH-1] Validates JWT tokens on every request
```

```zig
// spec: AUTH-1
test "valid token" { ... }

// spec-case: AUTH-1
test "expired token" { ... }
```

Legacy prose tags remain supported.

## Snapshot-based checks

`pub-api-surface`, `panic-budget`, `int-from-float-budget`, and
`unsafe-ops-budget` write a snapshot under `.guardian/` on first run, then fail
when subsequent runs diverge. Accept only the check you reviewed:

```bash
zig build guardian-accept -Dguardian-checks=pub-api-surface
git add .guardian/
```

`guardian-accept` also records the accepted ratchet checks as *session
pending*: until your next commit, further growth of the same check
re-accepts automatically with a green notice (the ratchet locks again the
moment HEAD moves). One accept per feature, not one per build.

`guardian-accept` previews the named failures, refreshes only those metadata
files, and reruns the checks without refresh before reporting success. Multiple
checks are comma-separated. The older environment variable remains supported
for named checks. A broad refresh now requires the explicit
`GUARDIAN_UPDATE_SNAPSHOT=all`; ambiguous `=1` and `=true` values fail without
refreshing anything.

```bash
zig build guardian-accept -Dguardian-checks=spec,panic-budget
```

An unknown name **hard-fails** the run (a typo can't silently refresh nothing). The names are the same kebab-case names used everywhere else: `mutate` refreshes the mutation-score ratchet, and in baseline mode a check name refreshes that check's baseline. One alias exists, because one snapshot leaf is spelled differently from its check: `pub-api` (the basename of `.guardian/pub-api.txt`, the file you were just reading) resolves to `pub-api-surface` in `accept`, `--only`/`--skip`, and `GUARDIAN_UPDATE_SNAPSHOT`.

### Reading a pub-api-surface diff

The drift report is grouped rather than printed as one alphabetical
add/remove list, so the shape of the change is legible without hand-diffing:

```
guardian: pub-api FAILED — surface changed
  delta: 1 new, 1 changed, 1 removed, 2 moved — review changed/removed below before accepting
  changed:
    ~ src/router.zig::claimed | fn claimed(lane: u8) bool -> fn claimed(lane: u8, cls: u8) bool
  moved: src/router.zig -> src/gap_policy.zig :: helper
  moved: src/router.zig -> src/gap_policy.zig :: width
  - src/router.zig::stays | fn stays() void
  + src/router.zig::brandNew | fn brandNew() void
```

- **changed** — one symbol whose signature was edited, as a single `~ key | old -> new` line instead of a `+` and a `-` at opposite ends of the listing.
- **moved** — a byte-identical signature that reappeared under a different file. A relocation counts as neither new nor removed, so a refactor that lifts a cohesive chunk into a new module reads as `N moved` instead of `N new, N removed`. It is still drift: the snapshot must be accepted.
- **`-` / `+`** — the genuinely one-sided entries.

When the delta is additions-only the summary says so and carries the accept
commands on the next line, so reviewing and accepting are one step.

The snapshot files are plain text, sorted, designed to diff cleanly in code review.

## Machine-readable output

Guardian is AI-first, so it emits four JSONL logs — **all under `.guardian/cache/`,
which is git-ignored and excluded from the skip-cache input digest, so writing them
never churns git or invalidates the build cache, and none carries a timestamp
(`std.time` is banned):**

| File | Written by | Contents |
|---|---|---|
| `last-run.jsonl` | every `all` / `nightly` run | one `violation` record per finding + a final `summary` (detailed below) |
| `dora.jsonl` | every `all` / `nightly` run | append-only DORA delivery-metrics record per run; read back by `guardian-check history` (see [Delivery metrics](#delivery-metrics-dora)) |
| `last-mutate.jsonl` | every `mutate` run | one `survivor` record per surviving mutant + a `summary` (see [Survivor report](#survivor-report)) |
| `mutants.jsonl` | every `mutate` run | per-mutant result cache for resume / re-run (see [Result cache](#result-cache-resume--re-run)) |

The rest of this section covers `last-run.jsonl`; the mutation logs and the DORA
sink are detailed in their own sections.

Every `all` / `nightly` run drops the machine-readable log of what it found at
**`.guardian/cache/last-run.jsonl`** — one JSON object per line (JSONL). It exists
so an agent's fix loop, an editor integration, or the `debt` report can consume
structured findings instead of re-parsing terminal prose.

```jsonl
{"type":"violation","check":"function-length","file":"src/foo.zig","line":246,"message":"fn parse is 246 lines (hard limit 200)","fix_hint":"extract the function's phases into focused helpers","ratchet_key":"src/foo.zig|parse","metric":246}
{"type":"violation","check":"catch-discipline","file":"src/foo.zig","line":16,"message":"catch block is empty (silently swallows the error)","fix_hint":"handle the error explicitly with a switch or named return","ratchet_key":null,"metric":null}
{"type":"violation","check":"spec","file":null,"line":null,"message":"unverified: Auth - Validates tokens","fix_hint":null,"ratchet_key":null,"metric":null}
{"type":"summary","passed":58,"failed":2,"skipped":3,"filtered":false}
```

- One `violation` record per finding, then a final `summary` record whose
  `passed` + `failed` + `skipped` sum to the 79 registry entries — `skipped` is
  the 4 built-in non-gates (`spec-init` / `mutate` / `debt` / `history`) plus
  anything `disabled` or filtered out. A green run writes a summary-only log.
- Threshold checks (function-length, nesting-depth, cognitive-complexity,
  function-size, type-size, file-size, struct-method-cap, optional-density,
  bool-ops, line-length) emit a **`ratchet_key`** (stable per-subject identity —
  `file|fn`, `file|Type`, or `file`) and a **`metric`** (the measured value).
  Other checks contribute at least `check` + `message` (the rest `null`).
- **`file` / `line` are filled for a prose-reporting check too.** A check that
  prints `src/x.zig:16: <message>` rather than emitting a structured record has
  that prefix lifted into the row's own fields, so every row is addressable
  without re-parsing the message. Only the two canonical spellings are split
  (`<file>:<line>: msg` and `<file>: msg`); anything else keeps its message
  verbatim, and a finding with no file at all (a SPEC.md behavior) still has
  `file: null`.
- **`fix_hint` carries the remedy.** A check that emits records sets it per
  finding (`formatting` → `zig fmt src/x.zig`; `deprecated-alias` → the modern
  spelling; the ban family → the port to inject). A prose check's single
  trailing `fix:` line — the one printed once beneath its findings — is attached
  to each of its rows. A ratchet regression's hint names the ceiling it broke,
  by how much, and the `guardian-check accept` command. It is `null` where no
  hint exists, never filled with filler.
- **Baseline mode reports through the same records.** A baselined check's
  findings are consumed by the baseline layer, so what it *reported* — the
  violations above the baseline, or the keys that regressed past their ratchet
  ceiling — is forwarded to the sink with the check's own file/line/metric.
  Grandfathered debt is not forwarded: a row means "this run reported it".
- Written under `cache/` on purpose: that subdir is git-ignored and excluded from
  the skip-cache input digest, so the log is rewritten every run without churning
  git or invalidating the build cache. No timestamps (std.time is banned).
- Escaping is done by `std.json` — the file is always valid JSONL.

Under the hood the threshold checks emit a structured `reporter.Violation`
(carrying `check` / `ratchet_key` / `metric`) that the reporter renders to the
exact same human-readable line; baseline capture reads those records instead of
re-scraping prose. Those `ratchet_key` + `metric` records are what power the
**per-item ratchets** (baseline v2) described under *Adopting Guardian on an
existing codebase* — none of it changes a check's terminal output.

## Delivery metrics (DORA)

Every real `all` / `nightly` run also appends one line to an append-only
DORA-metrics sink at **`.guardian/cache/dora.jsonl`** — the data source for
deployment-frequency / lead-time / change-failure-rate / MTTR analysis. It never
gates the build.

```jsonl
{"type":"run","branch":"main","commit":"c36513b…","outcome":"green","failed_checks":[],"duration_ms":558}
{"type":"run","branch":"main","commit":"d41f2c9…","outcome":"red","failed_checks":["spec","doc-comments"],"duration_ms":612}
```

- One record per full-suite run: `outcome` is `green` (every check passed) or
  `red`, `failed_checks` lists the failed gate names, `duration_ms` is the
  wall-clock run time. Outside a git repo, `branch` and `commit` are `null`.
- **Cache-skipped and filtered (`--only`/`--skip`) runs record nothing** — only a
  complete, executed suite is a delivery event. A `nightly` run records once (via
  its nested `all` pass), reflecting the check-suite outcome.
- Lives under `cache/` on purpose: that subdir is git-ignored and excluded from
  the skip-cache input digest, so appending every run never churns git or
  invalidates the build cache. `std.json` does the escaping.
- Configurable via `[dora]` in guardian.toml:

```toml
[dora]
enabled = true                          # default; false disables the sink
sink_path = ".guardian/cache/dora.jsonl"  # default; relative paths resolve under the project dir
```

Run duration is guardian's one legitimate wall-clock read — the sink module
carries a `ban-time` `[[allow]]` for `std.time.Timer` that does **not** propagate
to consumers.

### Reading it back: `guardian-check history`

The sink is only half the loop. **`guardian-check history [dir]`** is the read
surface over the same file — how often the gate is green, what a run costs,
which checks actually block, and how long the current red patch has run:

```
guardian: history: 430 run(s) recorded in .guardian/cache/dora.jsonl
  outcome    371 green / 59 red — 86.3% pass rate
  streak     current: 3 red — failing spec, test-coverage
             longest: 5 red — last failing ban-globals
  duration   median 2214 ms · p90 2997 ms (last 430 run(s))
  trend      last 20: 2066 ms · prior 100: 1199 ms — slower than before
  failures   check                     runs
             file-size                24
             function-length          9
  last red   commit    branch            checks
             83967325  main              completeness, stack-escape
```

- **`--check <name>`** narrows the report to one check's failure history: how
  many runs it failed, its share of them, and the last few with their commit,
  branch, and what else failed alongside it.
- **`--json`** writes the whole report to **stdout** as one object
  (`runs` / `streaks` / `durations` / `top_failures` / `recent_red` / `check`),
  so a caller can pipe it. The report itself stays on stderr.
- It **streams**. The log is append-only and unbounded, so it is read one line
  at a time and every remembered figure lives in a fixed-size buffer; duration
  statistics cover the most recent 512 runs and the report always names that
  window. A line that is not a decodable run record is counted and skipped, and
  an absent log is the ordinary answer "no runs recorded yet".
- Never a gate: it is a registry entry (so `--only`/`--skip` and `explain` know
  it) but a built-in non-gate, like `debt`, so `all` never runs it.

## Benchmark ledger (`bench`)

Agents measure expensive things — a full-board route, a suite wall clock, a
mutation kill score — and then the number survives only in a chat report. The
next agent re-measures it, or re-runs an experiment already known to have
failed. The ledger is where a measurement lands instead:

```bash
guardian-check bench set close_open_nets_wall_s 531 --unit s --dir min \
  --note "fixture B, 87/90 nets, DRC 11/8" .
guardian-check bench set terminal_via_default_smd_cost_nets -1 --dir info \
  --note "defaulting smd_ok: 87->86 on fixture B, DRC held 11/8" .
guardian-check bench list .
guardian-check bench rm close_open_nets_wall_s .
```

Storage is one plain, sorted, diff-friendly line per metric in
**`.guardian/benchmarks.txt`** — the same `# guardian-snapshot v<N>` format as
the other ratchets:

```
# guardian-snapshot v1
close_open_nets_wall_s 531 s min a3c81cd… 2026-07-25 fixture B, 87/90 nets, DRC 11/8
terminal_via_default_smd_cost_nets -1 - info a3c81cd… 2026-07-25 defaulting smd_ok: 87->86 on fixture B
```

`<name> <value> <unit> <direction> <commit> <date> <note…>`; `-` is the
placeholder for an omitted unit/commit/date, and re-recording a metric REPLACES
its line (history is git's job). Values must be finite; names/units are single
printable words; a note is one line.

**Guardian never runs a benchmark.** It records what an agent measured and
prints it back — one compact line per metric at the start of every `all` run,
including the `--quiet` build-wired run and a cache-skipped one:

```
guardian: bench close_open_nets_wall_s = 531 s (min, @a3c81cd 2026-07-25: "fixture B, 87/90 nets, DRC 11/8")
guardian: bench terminal_via_default_smd_cost_nets = -1 (info, @a3c81cd 2026-07-25: "defaulting smd_ok: 87->86 on fixture B")
```

- **`--dir min|max|info`** — lower is better / higher is better / no direction.
  `info` is the *negative-result* case: "relaxing the gap router's terminal
  via-ban cost a net" is a fact worth keeping next to the code, not a target.
  Omitting `--dir` records an `info` metric.
- **Report-only by default.** Nothing in the ledger can fail a gate; a corrupt
  ledger is reported and stepped over, never rewritten.
- **Opt-in per-metric ratchet.** Name a metric in `[benchmark] gate` and it may
  only improve or hold when re-recorded — the mutation-score ratchet's
  philosophy, applied to whatever an agent chose to measure:

```toml
[benchmark]
gate = ["kill_score"]     # empty by default: nothing is gated
```

```
$ guardian-check bench set kill_score 70 --unit % --dir max --note "after the rewrite" .
guardian: bench set REFUSED: kill_score regresses the gated ratchet
  recorded: bench kill_score = 81 % (max, @a531f4a6 2026-07-26: "full cohort, 100 mutants")
  proposed: bench kill_score = 70 % (max, @a531f4a6 2026-07-26: "after the rewrite")
  fix: improve the number, or accept it deliberately with --force --note "<why>".
```

`--force` accepts the regression, and it *requires* a non-empty `--note`
explaining what was accepted — so the trade is recorded in the ledger rather
than argued in a lost transcript.

The recorded date is guardian's second legitimate wall-clock read (after the
DORA sink): `src/cli/bench.zig` carries a repo-local `ban-time` `[[allow]]`
that does **not** propagate to consumers.

## Adopting Guardian on an existing codebase

Installing 50+ hard-block checks on a project with existing violations would mean "fix everything before you can build." That's not realistic. Instead, turn on **baseline mode** — every check records its current violations on the first run and only fails when *new* ones appear. Existing violations become a frozen ratchet that you can shrink over time.

The key move is to keep blocking thresholds meaningful. For most threshold
checks, baseline mode grandfathers each existing offender individually. File
size, function length, and line length instead report ordinary overages as
warnings and put only findings beyond their generous hard limits into ratchet
state, avoiding acceptance work for routine maintainability advice.

In `guardian.toml`:

```toml
[baseline]
enabled = true
```

Then run `zig build`. On the first build, `.guardian/baselines/<check>.txt` is written for each check that found violations, and the build passes.

### Two baseline flavors

Baseline mode runs one of two lifecycles per check, chosen automatically:

- **Per-item ratchets (baseline v2)** for the ten **threshold** checks — `function-length`, `nesting-depth`, `cognitive-complexity`, `function-size`, `type-size`, `file-size`, `struct-method-cap`, `optional-density`, `bool-ops-per-condition`, `line-length`. Each blocking offender is stored as a `<value> <key>` line and gets a **personal, only-shrinks ceiling**. The advisory tier for file size, function length, and line length is deliberately excluded from ratchets.
- **Identity baselines (v3)** for every other check — each violation is frozen under a **content-derived key**, not its rendered text; a new key fails, a resolved key auto-prunes.

This split fixes the structural flaw that made consumers raise global caps: a text baseline embeds the metric in the line, so *any* metric change (including a shrink) reads as a new violation. Ratchets store the metric as a comparable number instead.

### Baseline keys survive message rewording

A v3 key is `<check>|<file>|<discriminator>`, resolved in three tiers:

1. **`Violation.identity`** — the check names *what it flagged* (the prong set, the banned symbol, the repeated literal). Fully rendering-independent.
2. **`ratchet_key`** — the `file|symbol` identity the threshold checks already emit, reused verbatim.
3. **Message skeleton** — the fallback for checks that still report prose: the message with standalone digit runs collapsed to `#` (digits glued to an identifier, like `u8` or `f32`, are preserved).

Source line numbers are absent from every tier, so a violation that merely moved stays matched. Tier 1 means a diagnostic can be reworded word-for-word without re-keying any consumer's baseline; tier 3 absorbs counts, caps and measured values but *not* a prose rewrite — so **give a check an `identity` before rewording its message**. Keys are stored verbatim, so a `.guardian/` diff still reads as subjects rather than hashes.

For a threshold check, subsequent builds report:

| What changed | Outcome | Exit code |
|---|---|---|
| Nothing | `<check>: ratchet matches (N key(s))` | 0 |
| An offender shrank / vanished | `<check>: R ratchet(s) lowered, P pruned (now N key(s))` — the file is auto-rewritten to the smaller ceilings | 0 |
| A grandfathered offender grew | `<check>: <key> grew <old> -> <new> (ratcheted at <old>)` | 1 |
| A brand-new offender over the default cap | `<check>: <key> new offender over default cap (measured value: <value>)` — never silently added | 1 |
| You set the env var | `<check>: ratchet refreshed (N key(s))` | 0 |

Improvements can never be lost: a lowered ceiling is written on the same green run, so a later regression is measured against the *new, tighter* value. A new offender is one the default cap already flagged — it fails rather than being grandfathered, so history is frozen but new code stays strict.

Metadata updates are transactional across an `all` run. If any check fails,
Guardian restores every non-cache `.guardian` snapshot and baseline to its
pre-run bytes; diagnostic JSONL/cache files remain available. Successful runs
retain legitimate auto-lowering. When upgrading an old recommended-threshold
ratchet to the warning/hard split, an entry is retained while its subject still
produces an advisory warning, so a green run cannot silently empty that debt.

### Migration is automatic

A pre-upgrade project has v1 *text* baselines. On the first build after upgrading, guardian reads each one, finds the version doesn't match, and re-records it — **no manual step, no red build**. Commit the rewritten `.guardian/baselines/`.

- Threshold checks → **re-recorded as a v2 ratchet**: `<check>: migrated to per-item ratchet (N key(s))`.
- Every other check → **re-keyed to v3 identities**: `<check>: baseline re-keyed to stable identities (N violation(s))`.

The v3 re-key is *guarded*, so it is a genuine no-op — the same violations under new keys:

- It can never **drop** debt: every violation the check currently reports is written to the new baseline. An old entry with no current counterpart is one the check no longer reports — the ordinary auto-prune case.
- It can never **add** debt: the migration is refused if any file now holds *more* violations than v1 recorded for it. A rewording moves violations between keys within a file; it never creates one. So a file that gained a violation gained real debt, and the run fails with `<check>: cannot re-key the legacy baseline — ...` listing that file's violations (after a re-key the new one can't be singled out, so all are shown).

### Worked example: retire a global cap

Say your project carries `max_file_lines = 10000` — a 10× relaxation added so 25 oversized legacy files could build, which silently removed the file-size cap from *all* new code too. With ratchets you can take it back:

```toml
# Before: one global escape hatch that neuters the cap everywhere.
max_file_lines = 10000

# After: default cap for everyone, baseline mode grandfathers the 25 offenders.
# (max_file_lines line deleted → back to the 1000 default)
[baseline]
enabled = true
```

On the next build, `file-size` writes a ratchet with 25 entries — each oversized file pinned to its *current* length (`11482 src/placement/optimizer.zig`, …). Every one of those files can now only shrink; a 26th file crossing 1000 lines fails as a new offender; and the 24,000 lines of code that were under 1000 are held to 1000 again. The stale cap-justification comments (`# Instance has 16 fields`) go with it.

### Recommended workflow

1. **PRs that fix violations** — the build **auto-lowers / prunes** the ratchet in place, so just commit the updated `.guardian/baselines/<check>.txt`. No env var, no round-trip.
2. **PRs that intentionally accept a regression** (rare) — run `zig build guardian-accept -Dguardian-checks=<check>`, review the metadata diff, and commit it with the code.
3. **PRs that incidentally regress** — fix the new violation, no baseline changes.

The baseline files are plain text and sorted by key, so a value change is a one-line diff in code review.

**Freeze a baseline against growth.** For the checks whose debt should only ever shrink — the 1:1 spec map is the canonical case — list them in `[baseline] deny_growth`. A refresh that would *raise* a recorded value or *add* a key fails with a clear message instead of ratifying the growth (this applies to both flavors):

```toml
[baseline]
enabled = true
deny_growth = ["spec", "file-size"]
```

```
guardian: refusing to refresh file-size: ratchet would raise a value or add a key;
          fix the regressions or remove file-size from deny_growth
```

**See where the debt is.** `guardian-check debt [dir]` prints a non-gating
report of every baseline/snapshot total, sorted high-to-low, with the change vs
the committed `.guardian/` state. Add `--assert-density` when you also want the
informational `assert()`-per-KLOC table.

Rows are grouped by **what the number measures**, because one count-sorted
table cannot be read: an API-surface inventory is not debt however large it
gets, and a mutation score is the one row where higher is better. A per-item
ratchet also shows its worst offender — labelled `worst (baselined)`, because
it is the STORED ceiling and does not move when you edit the file:

```
debt — baselined violations, LOWER is better (delta vs HEAD)
  file-size                 25 violations       (+25 vs HEAD)  worst (baselined): 11482 src/placement/optimizer.zig
  function-length            8 violations       (unchanged)    worst (baselined): 246 src/router.zig|route
inventory — tracked totals, NOT debt (delta vs HEAD)
  pub-api-surface         2830 tracked symbols  (unchanged)
scores — HIGHER is better (delta vs HEAD)
  mutation                  32 % killed         (unchanged)
```

`--json` writes the same report to **stdout** (the human report stays on
stderr, so `debt --json | jq` receives the payload and nothing else). Each row
carries `kind` (`violation` / `inventory` / `score`), `direction`
(`lower_better` / `higher_better` / `neutral`) and `unit` as fields, so a
machine reader never infers them from label text, and `worst` is structured
`{metric, file, item}` (`item` null for a file-level metric) rather than a
preformatted string.

**Ask what is about to block.** `guardian-check debt [dir] --live` (spelled
`--current` as well) measures the tree and adds two sections: every ratcheted
key against its frozen ceiling, and a **headroom** list of the items within 10%
of the limit that would block them, least room first. That is the pre-flight
question — "can this grow?" — which the stored numbers cannot answer, and it
names which limit binds, since a frozen ceiling can sit either side of the
check's hard cap:

```
headroom — within 90% of the limit that blocks them, least room first (measured now)
  file-size        src/serve/pcb_layout_page.zig     10296 of 10296 frozen ceiling — 0 left
  file-size        src/placement/optimizer.zig        9988 of 10000 hard cap — 12 left
```

It is opt-in because it re-reads and re-parses `src/` and `test/`; a plain
metadata-only debt report should not pay for a source walk (measured on a
1000-file consumer: 1.2 s with it, 0.1 s without).

**Ask what a number is right now.** A ratchet freezes each item at the value
Guardian measured, and neither the checks nor `debt` report that value back
until something already fails — so trimming a file toward its ceiling used to
mean re-running the whole gate to read the number. `guardian-check size <path>
[dir]` answers it in one command, using the checks' own measurement functions
(so it agrees with the gate byte for byte — a hand-rolled `grep -c` does not,
because the file-size metric excludes `test { ... }` blocks):

```
size — src/placement/optimizer.zig (measured now; no gate, no writes)
  file-size        src/placement/optimizer.zig  11482 code lines  cap 1000 rec / 10000 hard   ceiling 11482 — AT CEILING, 0 headroom
  function-length  route                          246 lines       cap 120 rec / 400 hard      no ratchet ceiling recorded
  not measured here (metric lives inside the check's scan): nesting-depth, cognitive-complexity, …
```

`guardian-check debt . --live` does the same comparison tree-wide: per
ratcheted check, how many keys have headroom, how many sit exactly on their
ceiling, and how many are already over — plus a line for each of the last two,
and the headroom list shown above.

### Tier-by-tier rollout

If you'd rather adopt one rule family at a time, list the checks you're not ready for in the top-level `disabled` array (by their kebab-case names — see the tables above). Delete a name to turn that check on, fix its violations (or baseline them), commit, move on:

```toml
[baseline]
enabled = true       # always-on safety net while you work through the tiers

# Top-level list of checks to skip entirely, by name.
disabled = [
    "ban-time",      # Tier 1 — enable once a Clock port exists
    "ban-fs",        # Tier 1 — enable once a Filesystem port exists
    # ... and so on for the Tier 2 + Tier 3 checks you're deferring
]
```

Unknown names in `disabled` fail the build, so a typo can't silently leave a
check off. The three advisory size checks expose separate recommended and hard
limits; keep the recommendation useful for guidance and move the hard limit
only when a project has a legitimate extreme case.

### Extracting a module?

Splitting a file — usually to get it back under the `file-size` ratchet — reliably
trips three *other* checks at once, because moving code duplicates the small
things that came with it. Each finding is individually right, but they turn a
one-step move into a three-check cleanup. Do these three up front and extraction
stays a single build:

1. **`repeated-string-literal` — share the consts, don't copy them.** The arg
   keys / table names / type tags the moved code used are now spelled in two
   files. Put them in **one** module (the extracted file, or a small shared
   `keys.zig`) and have the other side `@import` it. A `const` per literal in
   each file is what the check exists to stop; a single owner is the fix.
2. **`repeated-switch-on-enum` — move the switch onto the type, don't duplicate
   it.** A `switch` over the same prong set in two files (the classic case: a
   JSON-coercion `switch (value) { .float, .integer, else }` in both halves)
   fails even when each copy is small. Give the enum — or the module that owns
   it — one method (`fn asF32(self: Value) ?f32`) and call it from both sides.
   That is nearly always the better API, not a workaround.
3. **`deprecated-alias` — write the current idiom in the new file.** Fresh code
   copied from an older file carries older spellings: use `.empty` rather than
   `std.ArrayListUnmanaged{}`, `std.ArrayList` rather than the `Unmanaged`
   alias. `guardian-check explain deprecated-alias` lists the pairs.

Two things that are *not* your problem: the extracted file inherits nothing from
the original's ratchets (its shape metrics are measured fresh), and neither half
needs a baseline refresh if you land the extraction and these three fixes in one
commit.

## Config (guardian.toml)

Optional — sensible defaults work out of the box. Each check has its own section:

```toml
spec_file = "SPEC.md"
max_file_lines = 1000
hard_max_file_lines = 10000
file_size_exclude = ["generated/*"]
required_inputs = ["src/serve/templates/*.zig"] # codegen must produce at least one match
exclude = ["src/serve/templates"]   # path globs dropped from the scan entirely (generated code)
parallel = true         # run checks across cores (default); false forces sequential
cache_enabled = true    # skip a full run when the hashed input set is unchanged (default)

# Report during dev, block at commit. In report mode `zig build` prints every
# finding but exits 0; commit/nightly/`all --gate` always block. commit runs
# test_command (and it must pass) before committing, and auto-installs the
# blocking pre-commit hook unless install_hook = false.
[gate]
on_build = "report"          # "report" (default) | "block"
test_command = "zig build test"
install_hook = true

# Severity preset plus explicit per-check overrides. strict is the
# backward-compatible default; agent/safety make selected heuristics advisory.
[policy]
profile = "agent"       # strict | agent | safety
block = ["file-size"]   # hard-block even when global baseline mode is enabled
ratchet = ["naming"]    # baseline this check even without global baseline mode
report = ["line-length"]

# Optional CI rail for policy and accepted-debt changes. policy-drift itself
# is always blocking and cannot be demoted by the lists above.
lock_enabled = true
lock_against = "origin/main"
protected_paths = ["guardian.toml", ".guardian/", ".github/workflows/"]

# Instrumentation bridge: while profiling these paths, the checks that fire on
# the ACT of instrumenting report under a non-blocking MEASURE verb on a LOCAL
# run — and block exactly as usual at commit. See "Measurement mode" below.
[measurement]
paths = ["src/placement/router.zig", "src/bench"]

# Cache-size warnings from `doctor`; zero disables that warning class.
[doctor]
zig_cache_warn_mib = 4096
guardian_cache_warn_mib = 1024

# Non-Zig gates execute directly as argv (no shell). Every exact file read by
# the command should be listed in inputs so the green-run cache invalidates.
[[external]]
name = "frontend-js-syntax"
command = ["node", "--check", "src/serve/assets/app.js"]
inputs = ["src/serve/assets/app.js"]

[[external]]
name = "frontend-css-syntax"
command = ["stylelint", "src/serve/assets/app.css"]
inputs = ["src/serve/assets/app.css", ".stylelintrc.json"]

# Optional browser/runtime contract. The script may launch Playwright or any
# project-native smoke harness; Guardian only requires a zero exit status.
[[external]]
name = "browser-smoke"
command = ["node", "tools/browser-smoke.mjs"]
inputs = ["tools/browser-smoke.mjs", "src/serve/assets/app.js", "src/serve/assets/app.css"]

# Expensive performance gates can run only when a hot path changes. This one
# compares elapsed seconds with a positive, min-direction record named
# barracuda_route_wall_s in .guardian/benchmarks.txt. The tighter of the
# benchmark + headroom and timeout_secs stops the process group; peak RSS is
# checked after the command. Omit all five fields for an ordinary external gate.
[[external]]
name = "barracuda-route-budget"
command = ["zig-out/bin/netlisp", "bench-route", "barracuda"]
inputs = ["projects/designs/barracuda.netlisp"]
paths = ["src/placement/*", "src/route/*"]
benchmark = "barracuda_route_wall_s"
max_regression_pct = 25
timeout_secs = 180
max_rss_mib = 4096

[[boundary]]
module = "src/core/*"
forbidden = ["utils"]

[function_size]
max_params = 6

[complexity]
max_score = 25

[anytype_budget]
max_per_file = 2
exclude = ["reporter.zig"]   # variadic/formatting boundaries are exempt

[spec_quality]
forbidden_phrases = ["properly", "as needed"]

[function_length]
max_lines = 120
hard_max_lines = 400

[line_length]
max_len = 120
hard_max_len = 240

[nesting_depth]
max_depth = 5

[type_size]
max_fields = 7
exclude = ["config.zig"]   # flat aggregation structs are exempt

# Opt-in: every pub fn must be referenced from at least one test block.
[test_coverage]
enabled = true
exempt_names = ["main", "build"]

# Opt-in: references from inside test blocks don't count toward liveness,
# so production-dead code kept alive only by its own test is flagged.
[dead_pub]
ignore_test_refs = true

# Diff-scoped process gate: behavioral src changes need a test/spec change.
# `against` is the default diff base (--against / GUARDIAN_AGAINST override).
# A spec change waives the test only when it adds/modifies a `- ` behavior
# bullet. When the base is HEAD and the tree is clean, gate_last_commit gates
# the last commit (HEAD~1..HEAD) instead of vacuously passing an empty diff.
[change_classification]
enabled = true
against = "HEAD"
gate_last_commit = true

# The mutate command's budgets (explicit step, not part of `all`).
[mutation]
min_score_pct = 80        # fail below this kill rate
min_mutants = 4           # gate on the percentage only at >= this many viable mutants
max_mutants = 100         # deterministic sampling cap per run
fast_max_mutants = 8      # smaller PR/changed-lines budget
smoke_step = "test-fast"  # optional cheap first stage; survivors still run all tests
timeout_floor_secs = 30   # per-mutant timeout floor (a fast suite still gets >= this)
timeout_multiplier = 5    # per-mutant timeout = max(floor, this x clean-suite baseline)
timeout_retry_multiplier = 2 # expand the deadline for the timeout retry
timeout_secs = 300        # baseline-measurement cap + fallback when no baseline
retained_cache_suites = 3 # exact historical suite caches retained for reuse

# Opt-in: every `## ` SPEC.md feature section must address or waive the 8
# scenario categories. Exempt non-feature sections (Overview, Changelog) by name.
[completeness]
enabled = true
exempt_sections = ["Overview", "Configuration"]

# DORA delivery-metrics sink (non-gating): one JSON line per full-suite run.
[dora]
enabled = true
sink_path = ".guardian/cache/dora.jsonl"

# Adopt on a legacy codebase: baseline every check's current violations, then
# only fail on NEW ones (auto-pruned as you fix them). deny_growth freezes the
# listed checks' baselines against ever growing, even under a refresh.
[baseline]
enabled = true
deny_growth = ["spec"]

# Per-check allowed-path exemptions. Each ban-family / path-scoped check keeps
# its architectural defaults (infra/clock, adapters/http, config, main, …);
# [[allow]] grants extra paths on top, merged by check name. This is where a
# project (Guardian included) records its own self-hosting carve-outs instead of
# compiling them into the check — so a downstream repo never inherits them.
[[allow]]
check = "ban-fs"
paths = ["src/infra/persistence/*"]

# Your own bans, enforced by the `ban` check on the ban-family engine. Use one
# when a call must route through a wrapper and the callee's signature isn't
# yours to change (a non-defaulted struct field is the better trick when it is).
# chain: one identifier per segment — this bans `optimizer.placeFromPoses`.
# paths: where the ban applies (omit for the whole tree). allow: exempt paths,
# typically the sanctioned wrapper itself. reason: what to use instead — it ends
# every violation message, and is the half worth reading.
[[ban]]
chain = ["optimizer", "placeFromPoses"]
paths = ["src/serve/*"]
allow = ["src/serve/route_seed.zig"]
reason = "call through RouteSeed instead"

# Your own owned concepts, enforced by the `concept` check. Use one when a set
# of magic spellings models ONE domain fact and keeps getting hand-copied —
# layer names, their colours, the file suffixes they map to — until the copies
# disagree. name: kebab-case and unique; it names every violation and is half of
# its baseline key. literals: exact substrings. patterns: `*` matches one or
# more characters that are not whitespace or a quote. owner: where the spelling
# is allowed to live. files: what THIS rule scans (any extension — this is how a
# .css copy is reachable at all), scoping that rule alone; omit for the source
# set Guardian already walks. Escapes resolve inside any value, so a literal may
# carry a quote: literals = ["\"track_track\""]. reason: where the value comes
# from, appended to every violation.
[[concept]]
name = "layer-names"
literals = ["F.Cu", "B.Cu"]
patterns = ["In*.Cu"]
owner = ["src/board_layers.zig"]
files = ["src/*.zig", "assets/*.css"]
reason = "layer names come from board_layers.LayerTable"

# divergent-const: one file-scope const NAME holding DIFFERENT values in two
# files. Default `mode = "units"` groups only names whose trailing `_` segment
# is a unit (`_mm`, `_bytes`, `_ms`, `_hz`, ...) — a physical quantity is where
# a silent disagreement actually ships; `"all"` groups every name.
# `ignore_names` exempts generic names that legitimately differ per module.
[divergent_const]
mode = "units"
ignore_names = ["eps", "margin"]

# twin-referent: globs silencing one "mirrors X / same as Y" claim, matched
# against the commenting file's path AND the referent text.
[twin_referent]
ignore = ["src/vendor/*"]
```

Patterns use `*` as a wildcard; without `*`, substring matching is used.
`required_inputs` is intentionally stricter: entries without `*` are exact
project-relative paths, while glob entries must match at least one file or
directory. Guardian checks them before `all`, individual gates, acceptance,
commit, nightly, or mutation can update metadata.

### Complete key reference

Every setting `src/config_parser.zig` understands (the parser fails closed —
unknown names, malformed values, incomplete
`[[boundary]]`/`[[allow]]`/`[[ban]]`/`[[concept]]` entries, a `[[ban]]` chain
segment that isn't a bare identifier, a `[[concept]]` name that isn't kebab-case
or that a previous entry already used, and unsafe mutation ranges are hard errors
with a `guardian.toml:line:` diagnostic). String arrays may span lines and
include comments and trailing commas.

| Scope | Keys |
|---|---|
| *(top level)* | `spec_file`, `max_file_lines`, `hard_max_file_lines`, `cache_enabled`, `parallel`, `file_size_exclude`, `exclude`, `disabled`, `required_inputs` |
| `[[boundary]]` | `module`, `forbidden` |
| `[[allow]]` | `check`, `paths` |
| `[[ban]]` | `chain` (required, one identifier per segment), `paths`, `allow`, `reason` |
| `[[concept]]` | `name` (required, kebab-case, unique), `literals`, `patterns` (at least one of the two required), `owner`, `files`, `reason` |
| `[[external]]` | `name`, `command`, `inputs`, `paths`, `benchmark`, `max_regression_pct`, `timeout_secs`, `max_rss_mib` |
| `[gate]` | `on_build` (`"report"`\|`"block"`), `test_command`, `install_hook` |
| `[test_filter]` | `flag` (default `-Dtest-filter=`) — read only by the non-gating `test-filter` report |
| `[policy]` | `profile`, `block`, `ratchet`, `report`, `lock_enabled`, `lock_against`, `protected_paths` |
| `[doctor]` | `zig_cache_warn_mib`, `guardian_cache_warn_mib` |
| `[spec_quality]` | `enabled`, `forbidden_phrases` |
| `[function_size]` | `enabled`, `max_params` |
| `[complexity]` | `enabled`, `max_score` |
| `[anytype_budget]` | `enabled`, `max_per_file`, `exclude` |
| `[orphan_files]` | `enabled`, `roots` |
| `[test_reachability]` | `enabled`, `roots` (test roots; empty = `src/main.zig` / `src/root.zig` / `test/*.zig`) |
| `[doc_quality]` | `enabled`, `min_chars`, `exempt_names` |
| `[type_size]` | `enabled`, `max_fields`, `exclude` |
| `[function_length]` | `enabled`, `max_lines`, `hard_max_lines` |
| `[nesting_depth]` | `enabled`, `max_depth` |
| `[test_coverage]` | `enabled`, `exempt_names` |
| `[bool_ops]` | `enabled`, `max_ops` |
| `[line_length]` | `enabled`, `max_len`, `hard_max_len` |
| `[baseline]` | `enabled`, `deny_growth` |
| `[escape_discipline]` | `enabled` |
| `[oom_discipline]` | `enabled` |
| `[magic_number]` | `enabled` |
| `[dead_pub]` | `ignore_test_refs` |
| `[change_classification]` | `enabled`, `against`, `gate_last_commit` |
| `[mutation]` | `min_score_pct`, `min_mutants`, `max_mutants`, `fast_max_mutants`, `smoke_step`, `timeout_floor_secs`, `timeout_multiplier`, `timeout_retry_multiplier`, `timeout_secs`, `retained_cache_suites` |
| `[completeness]` | `enabled`, `exempt_sections` |
| `[dora]` | `enabled`, `sink_path` |
| `[benchmark]` | `gate` (metric names opted into the ledger ratchet) |
| `[fuzz_presence]` | `modules` |
| `[int_from_float]` | `guard_fns`, `require_guard` |
| `[measurement]` | `paths` |
| `[divergent_const]` | `ignore_names`, `mode` (`"units"` (default) \| `"all"`) |
| `[twin_referent]` | `ignore` |

## Measurement mode (`[measurement]`)

Profiling a hot path means patching in scaffolding the gate exists to forbid — a
`pub var dbg_via_reason: [8]usize` counter, a `std.time.nanoTimestamp`
accumulator, a `std.debug.print` in the loop under study. It is read once and
deleted, but the gate cannot tell it apart from production code, so the only
supported workflow was *patch it in, build with the gate failing, run, read,
`git checkout` the file*: the gate and the diagnostic build were two different
worlds with no bridge between them.

`[measurement]` is that bridge, placed on exactly the half of the boundary that
costs nothing: **exploratory instrumentation stops fighting a local build, and
nothing extra can ship.**

```toml
[measurement]
paths = ["src/placement/router.zig", "src/bench"]
```

Each entry is a project-relative **file** or **directory prefix**. It is not a
glob: a wildcard, an absolute path, or a `..` escape is a hard config error,
because an allowlist that silently matches nothing is worse than a typo.

**Local run** (build-wired `all`, `guardian-check all <dir>`) — findings inside
those paths are reported under a distinct, non-blocking verb, and the run prints
one standing reminder so scaffolding cannot linger unnoticed:

```
guardian: MEASURE ban-globals (2 in src/placement/router.zig — exempt locally, blocks commit)
  src/placement/router.zig:41: mutable global var outside wiring/main
  src/placement/router.zig:42: mutable global var outside wiring/main
guardian: MEASURE: 3 finding(s) exempt by [measurement] — src/placement/router.zig
  (ban-globals 2, ban-time 1) — void at commit; strip before you ship
```

**Commit time** (`guardian-check commit`), **`--gate`** (the pre-commit hook and
CI), **`nightly`**, and **any run that may write `.guardian/` metadata**
(`accept`, `migrate`, a pending `GUARDIAN_UPDATE_SNAPSHOT` refresh) — the
exemption is **void**. The same findings block exactly as they do today, and no
baseline or snapshot can ever be recorded from an exempted view.

A local run that deferred anything also **withholds the green skip-cache stamp**,
so the next gating run always re-executes the suite instead of skipping on a
digest that was only green because of the exemption. The cost is one full run at
commit; the benefit is that the boundary cannot be smuggled through the cache.

### What it defers, and what it never touches

Only five checks are instrumentation-class, chosen because the thing each one
flags *is* the act of instrumenting:

| Check | Why it is bridged |
|---|---|
| `ban-globals` | a per-cause counter is a file-scope `pub var`; the check's own fix (scope it to a struct field) is the production plumbing you are trying not to grow |
| `ban-time` | a phase timer is `std.time.nanoTimestamp` / `Timer.start`; its fix is to inject a Clock port |
| `debug-print-ban` | `std.debug.print` in the loop is the read-out |
| `stdout-flush` | the hand-rolled buffered dump of those counters |
| `pub-api-surface` | a counter a second module reads must be `pub`, so the surface snapshot drifts for the life of the experiment (drift is filtered per file; the snapshot itself is never rewritten from the filtered view) |

Everything else keeps working normally inside a measurement path — in
particular the correctness and safety checks (`catch-discipline`,
`error-discipline`, `panic-budget`, `unsafe-ops-budget`, `ban-secrets`,
`allocator-hygiene`, `oom-discipline`), the spec workflow (`spec`,
`completeness`, `change-classification`), and every shape ratchet
(`function-length`, `file-size`, `cognitive-complexity`, …). An empty or absent
`[measurement]` section is exactly today's behavior everywhere.

## Tools

```bash
zig build                            # Compile + run every gate check (the primary gate)
zig build test                       # Run tests + every gate check
zig build guardian                   # Run all checks through the freshly built Guardian binary
zig build guardian -- version        # Forward arbitrary guardian-check arguments to that binary
zig build guardian -- all . --only spec,file-size # Run a filtered current-binary check
zig build spec-init                  # Generate starter SPEC.md (non-gating generator)
zig build mutate                     # Mutation-test changed lines (fast tier, auto-wired)
zig build mutate-full                # Mutation-test the whole tree + ratchet (auto-wired)
zig build debt                       # Non-gating baseline/snapshot debt report
zig build guardian-doctor            # Consumer-facing integration/metadata audit
zig build guardian-debt              # Consumer-facing debt report
zig build guardian-spec-sync         # Consumer-facing spec suggestions
zig build guardian-accept -Dguardian-checks=spec # Accept one reviewed metadata change
zig build guardian-explain -Dguardian-explain=spec # Explain a check
GUARDIAN_AGAINST=origin/main ...             # Diff base for change-classification / mutate
```

`GUARDIAN_AGAINST` selects the git ref used by diff-scoped features (an
`--against` flag wins). Guardian sets `GUARDIAN_MUTATION_RUN=1` itself on mutant
child builds. `GUARDIAN_UPDATE_SNAPSHOT` remains a compatibility path for named
checks or the explicit `all` token; `1` and `true` are rejected. Prefer the
named `accept` command. A trusted CI job may set
`GUARDIAN_POLICY_APPROVED=1` only after policy-file review.

### `guardian-check` CLI

The checker binary also runs directly. Prefer `zig build guardian -- ...` during
development so the command cannot resolve to a stale cache artifact:

```bash
guardian-check all .                 # Concise grouped report; exit 0 unless [gate] on_build = block
guardian-check all . --gate          # Force BLOCK mode: fail on any violation (what the pre-commit hook runs)
guardian-check all . --quiet         # Report/gate but print only failures (what the build wiring uses)
guardian-check all . --only spec,file-size   # Run ONLY the named checks
guardian-check all . --skip line-length      # Run every check EXCEPT the named ones
guardian-check all . --summary       # Explicit spelling of the concise default
guardian-check all . --verbose       # Replay every check and benchmark metric in full
guardian-check nightly .             # Full suite + whole-tree mutation ratchet (always blocks)
guardian-check commit --intent "fix the parser" .   # Block-gate, run tests, then auto-commit on green
guardian-check install-hook .        # Write .git/hooks/pre-commit that runs the blocking gate
guardian-check install-merge-driver . # Teach this clone's git to merge .guardian/ metadata
guardian-check merge-file %O %A %B --path %P  # The driver itself (git calls this; base, ours, theirs)
guardian-check size src/parser.zig . # One file's current measurements vs its caps and ratchet ceilings
guardian-check debt .                # Baseline/snapshot debt totals + deltas (non-gating)
guardian-check debt . --live         # Measure now: every ratcheted key vs its ceiling, + what is nearest a blocking limit
guardian-check debt . --current      # The same switch under its original name
guardian-check debt . --json         # Machine-readable debt report, on stdout
guardian-check debt . --assert-density # Add assert/KLOC diagnostics on demand
guardian-check debt . --check spec   # Restrict the debt report to one check
guardian-check debt . --prune-stale  # Preview obsolete baseline removal (dry run)
guardian-check debt . --prune-stale --yes # Explicitly delete the previewed files
guardian-check history .             # Gate outcomes, durations, and failing checks from the run log
guardian-check history . --check spec # One check's failure history
guardian-check history . --json      # The whole report as one JSON object on stdout
guardian-check doctor .              # Read-only metadata/integration health audit
guardian-check spec-sync .           # Suggest missing SPEC.md bullets (dry run)
guardian-check test-filter .         # Report the diff-derived test-name filter (never gates)
guardian-check test-filter . --args  # Just the argument string, on stdout, for `eval`
guardian-check test-filter . --json  # Machine-readable derivation + its blind spots
guardian-check bench set route_wall_s 531 --unit s --dir min --note "87/90 nets, fixture B" .
guardian-check bench list .          # Print the benchmark ledger
guardian-check bench rm route_wall_s .  # Drop one recorded metric
zig build guardian-accept -Dguardian-checks=spec,file-size # Preferred named metadata acceptance
guardian-check accept spec,file-size . # Raw-binary fallback for the same workflow
guardian-check explain catch-discipline      # Why a check blocks, how to fix, how to exempt
guardian-check explain completeness  # ...plus the category -> keyword table it matches on
guardian-check explain completeness --section "Web Server" .  # Dry-run one SPEC.md section
guardian-check explain               # List every check name + summary
guardian-check selfcheck ../guardian-zig  # Prove a prebuilt binary matches that Guardian source root
guardian-check version               # Print the guardian version + source digest (also --version)
```

- **`--only` / `--skip`** take comma-separated check names and are mutually
  exclusive. Unknown names (or non-gates like `mutate`) hard-fail with the
  valid-name hint. A filtered run is a subset, so it never writes the green
  skip-cache stamp — a partial run can't mask a failure in the checks it skipped.
- **The `run-all:` verdict line** closes *every* exit path — green, blocking,
  and cache-skipped — on the always-visible channel, so one grep covers all
  three and "no guardian output" is never a possible reading:

  ```
  run-all: 75 check(s) passed
  run-all: 75 checks — 0 blocking, 3 report-only
  run-all: 2/72 failed (type-size, naming) — 3 report-only
  run-all: cached — 0 blocking (inputs unchanged since last green run)
  ```

  A diff-scoped run appends ` — diff-scoped vs <base>, N file(s) in scope`. Each
  blocking failures are grouped beneath the verdict by check, with up to three
  actionable findings and a remaining count. The complete record stays in
  `.guardian/cache/last-run.jsonl` and returns with `--verbose`.
- **Concise by default.** Passing checks disappear, advisory checks collapse to
  one counted line each, the benchmark ledger collapses to its metric count,
  and blocking failures are grouped by check. The result stays actionable
  without making routine build output thousands of lines long.
- **Scope-aware collapse.** On a diff-scoped run, a non-blocking check whose
  findings *all* fall outside the changed files collapses to one counted line —
  `repeated-string-literal: 44 finding(s), none in scope — report-only
  (--verbose for detail)`. A single in-scope finding prints the check in full, a
  blocking check is rendered in the grouped failure section, and the full
  detail always remains in `.guardian/cache/last-run.jsonl`.
- **`--summary` / `--verbose`** select presentation only. `--summary` is the
  explicit spelling of the concise default. `--verbose` replays every captured
  check line and benchmark metric, opting out of grouping and scope-collapse;
  it wins when both flags are supplied.
- **Green-run cache** skips a run when the input digest matches the last green
  run, regardless of whether the Git worktree is dirty. The digest hashes every
  file each check reads (src/ + test/ `.zig`, `build.zig`/`build.zig.zon`, the
  SPEC file, `guardian.toml`, `.guardian/` excluding cache/, declared external
  inputs, and project-local `@embedFile` assets) plus HEAD and the guardian
  binary identity, so a content-identical tree runs the same checks to the same
  verdict — the common no-change rebuild in an agent edit/build loop skips even
  with mid-feature edits or long-lived `.guardian/` baseline drift in the tree.
  Changing HEAD, `build.zig.zon`, declared external inputs, or a project-local
  file referenced by `@embedFile` invalidates the stamp. This makes embedded
  JS/CSS/template changes visible to configured external syntax or browser-smoke
  gates. Guardian cannot replace the language
  tool itself, so configure `node --check`, Stylelint, Playwright, or an equivalent
  argv command under `[[external]]` for the asset types the project ships.
- **`--gate`** forces `all` to block on any violation regardless of `[gate]
  on_build`. Report mode (the default) prints every finding but exits 0 and
  appends `guardian: N check(s) would block commit (…) — run guardian-check
  commit to gate`; block mode fails the build. `commit`/`nightly`/`accept`
  always block.
- **`commit`** block-gates the tree, runs `[gate] test_command` (which must
  pass), auto-installs the pre-commit hook (unless `install_hook = false`), then
  auto-commits the change set (see below). Never part of `all`; requires
  `--intent`.
- **`install-hook`** writes `.git/hooks/pre-commit` (marked with a guardian
  comment) running `guardian-check all . --gate`, so a raw `git commit` still
  hits the blocking gate now that a dev build only reports. The hook resolves a
  binary in order: `$GUARDIAN_CHECK` → `./zig-out/bin/guardian-check` →
  `guardian-check` on PATH. It never overwrites a non-guardian pre-commit hook.
- **`install-merge-driver`** teaches THIS clone's git to resolve `.guardian/`
  conflicts: `.guardian/** merge=guardian` goes into `.git/info/attributes`
  (local, deliberately not the tracked `.gitattributes`) and
  `merge.guardian.driver` is pointed at `guardian-check merge-file %O %A %B
  --path %P`. Idempotent, and `install-hook`/`commit` install it too, so a
  consumer gets it without a second command. `doctor` reports whether it is on.
- **`merge-file`** is that driver. Arguments are in GIT's order — `%O %A %B` is
  BASE, OURS, THEIRS — and the merged result is written to `<ours>` (`%A`).
  Per format: a **v3 identity baseline** and the **pub-api surface** union their
  entries (with multiplicity) minus anything either side deleted, because a
  deletion is debt somebody paid; a **v2 per-item ratchet** keeps the TIGHTER
  ceiling per key, so a merge can never silently ratify growth; a **counter both
  sides moved** takes the larger value and stamps
  `# guardian-merge: regenerate`, which `merge-state` then blocks until you
  refresh it. A format with no safe resolution (the mutation cohort, the
  benchmark ledger, headers that disagree) is refused without writing, so git
  records an ordinary conflict. The canonical resolution for anything it refuses
  is unchanged: resolve provisionally, regenerate on the merged tree with
  `GUARDIAN_UPDATE_SNAPSHOT=<check> zig build`, review that diff.
- **`accept`** previews named check failures, refreshes only their recognized
  snapshot/baseline metadata, then verifies those checks without refresh.
- **`debt`** reports every baseline/snapshot total sorted high-to-low, with the
  change vs the committed `.guardian/` state (omitted outside a git repo). Never
  gates by default and is excluded from `all` — run it to decide what to pay
  down. `--json` emits structured output; `--check <name>` filters it. Stale
  baseline pruning is preview-only with `--prune-stale` and requires a second,
  explicit `--yes` before anything is deleted.
- **`doctor`** audits recognized metadata headers, stale baseline/snapshot
  files, mutation-ratchet adoption, local path integration, and cache size.
  Configure general Zig and Guardian cache warnings independently under
  `[doctor]`; set a threshold to zero to disable that warning.
  Advisory warnings exit zero; corrupt or unreadable recognized metadata exits
  nonzero. It never modifies the project.
- **`spec-sync`** cross-references SPEC.md with current `// spec:` and
  `// spec-case:` test tags and prints deduplicated missing bullets grouped by
  section. A bare stable ID becomes `[ID] TODO: describe behavior`. It is always
  a dry run; `--json` is available for tooling.
- **`explain`** prints a longer rationale for every registered check: the
  agent mistake it catches, how to fix a violation, and the exemption knob
  (`[[allow]]` paths, a config toggle, the `disabled` list, or a snapshot
  refresh). Unknown/no name lists all checks.
- **`--version` / `version`** print the version (from `src/version.zig`).

### `commit` — intent-driven auto-commit

`guardian-check commit --intent "<message>" [dir]` brings guardian-zig into the
sibling guardians' workflow: block-gate the tree, run the tests, then commit the
change set it just verified.

- **Red gate** → the violations print, git is left completely untouched, exit
  non-zero. **Green gate** → the project's own tests (`[gate] test_command`,
  default `zig build test`) run next and must pass — nothing enters history
  unverified. The test child runs with `GUARDIAN_SKIP_CHECKS=1` set so its wired
  guardian gate no-ops (this tree was already gated) while the tests still
  compile and run. Only then is the change set staged and committed with the
  intent as the message subject. Missing/empty `--intent` is a clean error with
  no side effects.
- **Auto-installs the pre-commit hook** (unless `[gate] install_hook = false`)
  so a later raw `git commit` can't bypass the gate now that a dev build only
  reports.
- **Safety-railed staging** (never `git add -A` / `.`): the path list comes from
  `git status --porcelain` (modified + untracked). **Untracked** paths matching
  the forbidden secret/build list are **skipped with a loud warning** (printed
  even in quiet mode), never staged — `.env` / `.env.*`, `*.pem`, `*.key`,
  `*.p12`, `id_rsa*`, `*credentials*` / `*secret*` (except `.zig` sources: a
  `credentials.zig` store module is code the gate just verified, not a secret),
  and `zig-out/` / `.zig-cache/` / `zig-cache/`. An **already-tracked path is
  never skipped** — it was deliberately added to the repo, and dropping it would
  leave the commit not matching the gated tree; `git add`ing an untracked path
  yourself is the deliberate escape hatch that lifts the rail the same way.
  `.guardian/` metadata and `SPEC.md` are **always
  included**, so the baseline/snapshot churn a run produced rides the commit
  that caused it — making that churn attributable instead of smeared across
  unrelated commits. Never pushes, never amends. A green gate with nothing left
  to stage reports "nothing to commit" and exits 0.
- **Closes the diff-timing hole.** Because `commit` gates the exact working-tree
  diff it is about to commit, change-classification (which diffs the same tree)
  is guaranteed to have seen the change — the escape hatch that let a
  commit-then-build flow slip an untested change past the gate is structurally
  closed for this workflow.

## Deterministic fakes (test doubles)

The Tier-1 `ban-time` / `ban-rng` / `ban-fs` / `ban-env` checks force every
nondeterminism source behind an injected port (`infra/clock`, `infra/random`,
`infra/fs`, `config`). Guardian ships the deterministic values you put behind
those ports **in your tests** as a standalone `guardian-fakes` module:

| Fake | Replaces (check) | Shape |
|---|---|---|
| `FakeClock` | a Clock port (`ban-time`) | manually advanced `i128`-nanosecond counter — no `std.time` |
| `SeededRandom` | a Random port (`ban-rng`) | thin `std.Random.DefaultPrng` wrapper with a **required** explicit seed |
| `FakeFs` | a filesystem port (`ban-fs`) | in-memory `path -> bytes` map (write / read / exists / delete / list) |
| `FakeEnv` | a config/env port (`ban-env`) | in-memory `name -> value` map (set / get / unset) |

They are dependency-free (only `std`), in-memory, and deterministic — a test
that "reads the clock", "sleeps", "rolls a die", "reads a file", or "reads an
env var" is instant and reproducible run to run.

### Wiring

`guardian-fakes` is a separate module from the checker, imported only by the
compilation that runs your **tests**. In your `build.zig`:

```zig
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });

// The fakes module (test doubles). Add it to whatever compilation runs your tests.
const fakes_mod = guardian_dep.module("guardian-fakes");
my_tests.root_module.addImport("guardian_fakes", fakes_mod);
```

### Example — a FakeClock behind a Clock port

```zig
const std = @import("std");
const fakes = @import("guardian_fakes");

test "retry backs off using the injected clock" {
    // A minimal Clock port: production depends on this seam; the test injects a fake.
    const Clock = struct {
        backing: *fakes.FakeClock,
        fn now(self: @This()) i128 { return self.backing.now(); }
    };

    var fake = fakes.FakeClock.init(0);
    const clock = Clock{ .backing = &fake };

    fake.sleep(1_500); // advances the clock instead of blocking — instant + deterministic
    try std.testing.expectEqual(@as(i128, 1_500), clock.now());
}
```

`FakeFs` and `FakeEnv` own the keys/values you insert, so call `deinit`:

```zig
var fs = fakes.FakeFs.init(std.testing.allocator);
defer fs.deinit();
try fs.writeFile("config.toml", "enabled = true");
const bytes = try fs.readFile(std.testing.allocator, "config.toml");
defer std.testing.allocator.free(bytes);
try std.testing.expect(fs.exists("config.toml"));
try std.testing.expectError(error.FileNotFound, fs.readFile(std.testing.allocator, "absent.toml"));
```

`SeededRandom` requires an explicit seed, so a "random" test is reproducible:

```zig
var rng = fakes.SeededRandom.init(0xC0FFEE);
const r = rng.random(); // a std.Random — call r.int(u32), r.float(f64), …
```

## Principles

1. **AI-first** — catches agent mistakes
2. **Hard block at commit** — nothing enters history unverified; dev builds report, never refuse
3. **Zero-config** — sensible defaults
4. **Opinionated** — SPEC.md + `// spec:` tags are THE workflow
5. **Invisible** — runs on every `zig build`
6. **Self-hosting** — Guardian verifies itself
