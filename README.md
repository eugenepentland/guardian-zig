# Guardian for Zig

Build-step quality gates for Zig projects. Runs on every `zig build` — invisible, opinionated, hard-blocking.

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

b.getInstallStep().dependOn(&b.addFmt(.{ .paths = &.{"src"}, .check = true }).step);

// One call wires up every hard-block check:
guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{});
```

3. Generate your SPEC.md:
```bash
zig build spec-init
```

4. Edit SPEC.md, add `// spec:` tags to tests, then build:
```bash
zig build  # guardian gates every build
```

## What It Checks

59 checks gate Guardian's own self-build (plus three registry entries that are explicit steps rather than gates: the `spec-init` generator, the `mutate` command, and the `debt` report). Most are hard-block; `test-coverage`, `escape-discipline`, `oom-discipline`, `magic-number`, and `completeness` are opt-in (default off — Guardian turns `magic-number` and `test-coverage` on for itself). The list below is grouped by FRAMEWORK.md tier; defaults are recalibrated toward larger, evidence-based thresholds. Several formerly-standalone checks have been folded into a related one (`spec-drift`→`pub-api-surface`, `comptime-quota`→`panic-budget`, `doc-quality`→`doc-comments`, `dup-const`→`repeated-string-literal`, `vague-name-blacklist`→`naming`), and `returns-per-function` was retired as redundant with `cognitive-complexity`; their old names are still tolerated in a `disabled` list.

### Spec workflow
| Check | Blocks on |
|---|---|
| **spec** | Missing SPEC.md, unverified behaviors, unlinked tags, duplicate tags |
| **spec-quality** | Vague phrases (`properly`, `as needed`, etc.); behaviors shorter than 20 chars |
| **completeness** *(opt-in)* | A `## ` SPEC.md feature section that doesn't address (or `completeness-waiver:`) each of the 8 scenario categories: empty/large inputs, unauthorized access, I/O failure, concurrent access, malformed encoding, integer overflow, panic-free. Off unless `[completeness] enabled = true`; exempt non-feature sections via `[completeness] exempt_sections` |

### Process gates (git-aware)
| Check | Blocks on |
|---|---|
| **change-classification** | Behavioral lines added to `src/**.zig` (vs `--against` / `GUARDIAN_AGAINST` / `[change_classification] against`, default HEAD) with **no** test-block lines, `// spec:` tags, or an added/modified SPEC.md **behavior bullet** in the same diff — the "quick fix with no regression test" pattern. A spec edit waives the test only when it adds/modifies a `- ` bullet outside a code fence (a prose/typo/header edit no longer counts). When the base is HEAD and the working tree is clean, it gates the **last commit** (`HEAD~1..HEAD`) instead of passing an empty diff — skipping merge/root commits, toggled by `[change_classification] gate_last_commit`. Skips silently outside a git repo. |

### Structural
| Check | Blocks on |
|---|---|
| **file-size** | Any .zig file exceeding `max_file_lines` (default 1000) |
| **function-size** | Any function with more than `max_params` parameters (default 6) |
| **function-length** | Any fn over `max_lines` source lines (default 120) |
| **nesting-depth** | Any fn body with brace nesting over `max_depth` (default 5) |
| **type-size** | Any pub struct/enum/union over `max_fields` (default 7) |
| **imports** | Cycles in the `@import` graph |
| **boundaries** | Forbidden `@import` paths per module rules |
| **orphan-files** | A .zig file unreachable from any configured root via `@import` |
| **test-coverage** *(opt-in)* | A pub fn with no identifier reference from any test block |

### Public API
| Check | Blocks on |
|---|---|
| **pub-api-surface** | Unintended additions/removals to the public API, or a changed `pub fn` signature (snapshot diff) |
| **dead-pub** | A `pub fn` / `pub const` referenced nowhere in the project (optionally ignoring test-only references) |

### Code style
| Check | Blocks on |
|---|---|
| **naming** | PascalCase fns that don't return `type`; lowercase types; vague public identifiers (`tmp` / `data` / `Manager` / `Util` etc.) |
| **doc-comments** | `pub fn` or `pub struct/enum/union` missing a `///` doc comment (protocol names `deinit`/`format`/`next`/`reset` exempt, extend via `doc_quality.exempt_names`), or one that's empty / placeholder / under `min_chars` (default 12) |
| **cognitive-complexity** | Per-function complexity score (default 25) |
| **anytype-budget** | More than `max_per_file` `anytype` parameters (default 2) |
| **usingnamespace-ban** | Any `usingnamespace` in `src/` |

### Error handling
| Check | Blocks on |
|---|---|
| **error-discipline** | Inferred `!T` or `anyerror!T` on `pub fn` (require explicit error sets) |
| **catch-discipline** | `catch unreachable` and `catch {}` (silent error swallow) |
| **unwrap-discipline** | `orelse unreachable` / `orelse undefined` (crash/UB on null) |
| **stack-escape** | Returning `&local` / a slice of a stack array / `&local.field` / a `const` alias of `&local` — a dangling pointer into the dead frame |
| **stub-body-ban** | Single-statement bodies that are `return undefined`, placeholder `@panic`, or `unreachable` in non-noreturn fns |
| **panic-budget** | Increase in `@panic` / `unreachable` / `TODO` / `FIXME` counts, or `@setEvalBranchQuota` call count / max literal (snapshot) |
| **int-from-float-budget** | Increase in the `@intFromFloat` count — each new lossy float→int cast needs a NaN/range guard review (snapshot) |
| **unsafe-ops-budget** | Increase in any unsafe-cast builtin count (`@ptrCast`, `@alignCast`, `@bitCast`, `@ptrFromInt`, `@intFromPtr`, `@constCast`, `@volatileCast`) or in `undefined` re-assignments to a live lvalue; declaration-init and test blocks exempt (snapshot) |

### Allocation
| Check | Blocks on |
|---|---|
| **allocator-hygiene** | Hardcoded `std.heap.page_allocator` / `c_allocator` / `GeneralPurposeAllocator` / `testing.allocator` outside `pub fn main` / tests (suppress a deliberate site with a `// allocator-ok:` comment) |
| **escape-discipline** *(opt-in)* | Raw `{s}` interpolation into HTML/SVG markup without an escape helper (XSS sink) |
| **oom-discipline** *(opt-in)* | A swallowing `catch` on an allocating call that conflates `OutOfMemory` with "not found" |

### Hidden Dependency Bans (Tier 1)
Every nondeterminism source must be injected, not acquired. Each check ships with the FRAMEWORK.md symbol list baked in.

| Check | Blocks on |
|---|---|
| **ban-time** | `std.time.timestamp` / `nanoTimestamp` / `Instant.now` etc. outside `infra/clock` |
| **ban-rng** | `std.crypto.random` / `std.Random.DefaultPrng.init` outside `infra/random` |
| **ban-fs** | `std.fs.cwd` / `openFileAbsolute` etc. outside `infra/fs` |
| **ban-net** | `std.net.*` / `std.http.*` outside `adapters/http` or `infra/net` |
| **ban-env** | `std.process.getEnvVarOwned` etc. outside `config` or `main` |
| **ban-sleep** | `std.Thread.sleep` / `std.time.sleep` outside test infrastructure |
| **ban-globals** | top-level `pub var` outside `wiring` / `main` |
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

### Complexity Bounds (Tier 1)
| Check | Blocks on |
|---|---|
| **bool-ops-per-condition** | More than `max_ops` (default 3) `and`/`or`/`!` per condition |

### Tier 2 Anti-patterns
| Check | Blocks on |
|---|---|
| **line-length** | Source line over `max_len` codepoints (default 120; `\\` multiline-string lines skipped) |
| **boolean-param-ban** | A `bool` parameter in any `pub fn` |
| **magic-number** *(opt-in)* | Bare integer literals outside the small allowlist (float idioms like `0.5` / `1e-9` allowed) |
| **repeated-string-literal** | The same string literal appearing 3+ times in one file, or the same `pub const NAME = "literal"` across 2+ files |
| **struct-method-cap** | Pub container with > 20 `pub fn` methods |
| **optional-density** | Pub struct where > 50% of fields are `?T` |
| **stringly-typed-switches** | `switch` whose case keys are string literals |

### Tier 3 Architectural Fitness
| Check | Blocks on |
|---|---|
| **repeated-switch-on-enum** | The same enum prong-set switched in 2+ files (move dispatch onto the type) |

Plus `zig fmt --check`, wired as a format gate alongside the checks. The
`spec-init`, `mutate`, and `debt` steps are non-gating — see [Tools](#tools).

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
  all of any untracked new file. Cheap enough to run on every PR.
- **Full** (`--full`): the whole tree, sampled down to `max_mutants`. The
  score is ratcheted in `.guardian/mutation.txt` — it can never drop without
  `GUARDIAN_UPDATE_SNAPSHOT=1`.

Both tiers fail below `min_score_pct` (default 80) — but only once the run has
at least `min_mutants` (default 4) **viable** mutants. Below that floor a single
survivor would be a meaningless red (1 of 2 = 50%), so the run instead lists its
survivors *informationally* and exits green (`N viable mutant(s) below
min_mutants=M — informational, not gated`). The floor mostly bites the fast tier,
where a tiny diff can produce only a mutant or two; a below-floor run never
records the score ratchet. Scoring: timeouts count as kills (the mutant made the
suite hang — it was caught); compile-error mutants are *unviable* and excluded.
During mutant runs guardian sets `GUARDIAN_MUTATION_RUN=1` on child builds, and
every guardian command no-ops under it — so the deliberately-broken tree isn't
gated against itself.

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
(`GUARDIAN_UPDATE_SNAPSHOT=mutate` / `=1`) bypasses cache reads entirely — a
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

Guardian enforces **1:1 mapping**: every spec behavior needs exactly one test tag.

## Snapshot-based checks

`pub-api-surface`, `panic-budget`, `int-from-float-budget`, and `unsafe-ops-budget` write a baseline file under `.guardian/` on first run, then fail the build when subsequent runs diverge. To accept a real change:

```bash
GUARDIAN_UPDATE_SNAPSHOT=1 zig build   # refresh every drifted snapshot + baseline
git add .guardian/
```

**Selective refresh.** `=1` (also `true` / `all`) accepts *everything* that drifted in that run — every snapshot **and** every baseline. That all-or-nothing valve is how frozen debt creeps up: refreshing to accept one intended change silently ratifies unrelated drift in the same run. To accept only specific checks, name them (comma-separated):

```bash
GUARDIAN_UPDATE_SNAPSHOT=pub-api-surface zig build      # only the pub-api snapshot
GUARDIAN_UPDATE_SNAPSHOT=spec,panic-budget zig build    # just these two
```

An unknown name **hard-fails** the run (a typo can't silently refresh nothing). The names are the same kebab-case names used everywhere else: `mutate` refreshes the mutation-score ratchet, and in baseline mode a check name refreshes that check's baseline.

The snapshot files are plain text, sorted, designed to diff cleanly in code review.

## Machine-readable output

Guardian is AI-first, so it emits four JSONL logs — **all under `.guardian/cache/`,
which is git-ignored and excluded from the skip-cache input digest, so writing them
never churns git or invalidates the build cache, and none carries a timestamp
(`std.time` is banned):**

| File | Written by | Contents |
|---|---|---|
| `last-run.jsonl` | every `all` / `nightly` run | one `violation` record per finding + a final `summary` (detailed below) |
| `dora.jsonl` | every `all` / `nightly` run | append-only DORA delivery-metrics record per run (see [Delivery metrics](#delivery-metrics-dora)) |
| `last-mutate.jsonl` | every `mutate` run | one `survivor` record per surviving mutant + a `summary` (see [Survivor report](#survivor-report)) |
| `mutants.jsonl` | every `mutate` run | per-mutant result cache for resume / re-run (see [Result cache](#result-cache-resume--re-run)) |

The rest of this section covers `last-run.jsonl`; the mutation logs and the DORA
sink are detailed in their own sections.

Every `all` / `nightly` run drops the machine-readable log of what it found at
**`.guardian/cache/last-run.jsonl`** — one JSON object per line (JSONL). It exists
so an agent's fix loop, an editor integration, or the `debt` report can consume
structured findings instead of re-parsing terminal prose.

```jsonl
{"type":"violation","check":"function-length","file":"src/foo.zig","line":246,"message":"fn parse is 246 lines (cap 200)","fix_hint":null,"ratchet_key":"src/foo.zig|parse","metric":246}
{"type":"violation","check":"spec","file":null,"line":null,"message":"unverified: Auth - Validates tokens","fix_hint":null,"ratchet_key":null,"metric":null}
{"type":"summary","passed":57,"failed":2,"skipped":3,"filtered":false}
```

- One `violation` record per finding, then a final `summary` record whose
  `passed` + `failed` + `skipped` sum to the 62 registry entries — `skipped` is
  the 3 built-in non-gates (`spec-init` / `mutate` / `debt`) plus anything
  `disabled` or filtered out. A green run writes a summary-only log.
- Threshold checks (function-length, nesting-depth, cognitive-complexity,
  function-size, type-size, file-size, struct-method-cap, optional-density,
  bool-ops, line-length) emit a **`ratchet_key`** (stable per-subject identity —
  `file|fn`, `file|Type`, or `file`) and a **`metric`** (the measured value).
  Other checks contribute at least `check` + `message` (the rest `null`).
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

## Adopting Guardian on an existing codebase

Installing 50+ hard-block checks on a project with existing violations would mean "fix everything before you can build." That's not realistic. Instead, turn on **baseline mode** — every check records its current violations on the first run and only fails when *new* ones appear. Existing violations become a frozen ratchet that you can shrink over time.

The key move: **keep the default caps.** You do *not* raise `max_file_lines`, `max_lines`, or any other threshold to accommodate legacy code. Baseline mode grandfathers each existing offender *individually*, so new code still meets the strict default while history is tolerated exactly as-is.

In `guardian.toml`:

```toml
[baseline]
enabled = true
```

Then run `zig build`. On the first build, `.guardian/baselines/<check>.txt` is written for each check that found violations, and the build passes.

### Two baseline flavors

Baseline mode runs one of two lifecycles per check, chosen automatically:

- **Per-item ratchets (baseline v2)** for the ten **threshold** checks — `function-length`, `nesting-depth`, `cognitive-complexity`, `function-size`, `type-size`, `file-size`, `struct-method-cap`, `optional-density`, `bool-ops-per-condition`, `line-length`. Each offender is stored as a `<value> <key>` line (`130 src/foo.zig|parse`) and gets a **personal, only-shrinks ceiling**. A metric *change* on a grandfathered offender — even an improvement that's still over cap (130 → 125 lines) — no longer reds the build; only a value that *rises above its recorded ceiling* fails.
- **Text baselines (v1)** for every other check — the exact violation lines are frozen and diffed; a new line fails, a resolved line auto-prunes.

This split fixes the structural flaw that made consumers raise global caps: a text baseline embeds the metric in the line, so *any* metric change (including a shrink) reads as a new violation. Ratchets store the metric as a comparable number instead.

For a threshold check, subsequent builds report:

| What changed | Outcome | Exit code |
|---|---|---|
| Nothing | `<check>: ratchet matches (N key(s))` | 0 |
| An offender shrank / vanished | `<check>: R ratchet(s) lowered, P pruned (now N key(s))` — the file is auto-rewritten to the smaller ceilings | 0 |
| A grandfathered offender grew | `<check>: <key> grew <old> -> <new> (ratcheted at <old>)` | 1 |
| A brand-new offender over the default cap | `<check>: <key> new offender over default cap (<value>)` — never silently added | 1 |
| You set the env var | `<check>: ratchet refreshed (N key(s))` | 0 |

Improvements can never be lost: a lowered ceiling is written on the same green run, so a later regression is measured against the *new, tighter* value. A new offender is one the default cap already flagged — it fails rather than being grandfathered, so history is frozen but new code stays strict.

### Migration is automatic

A pre-upgrade project has v1 *text* baselines for these threshold checks. On the first build after upgrading, guardian reads each one, finds the version doesn't match, and **re-records it as a v2 ratchet** — reported as `<check>: migrated to per-item ratchet (N key(s))`, green, no red build. Commit the rewritten `.guardian/baselines/` and you're on ratchets. No manual step.

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
2. **PRs that intentionally accept a regression** (rare) — refresh that one check by name: `GUARDIAN_UPDATE_SNAPSHOT=<check> zig build`, same commit pattern.
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

**See where the debt is.** `guardian-check debt [dir]` (or `zig build debt`) prints a non-gating report of every baseline/snapshot total, sorted high-to-low, with the change vs the committed `.guardian/` state. A per-item ratchet also shows its worst offender:

```
debt report — 2 tracked source(s), sorted by count (delta vs HEAD)
  file-size               25  (+25 vs HEAD)  worst: 11482 src/placement/optimizer.zig
  function-length          8   (unchanged)  worst:   246 src/router.zig|route
```

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

Unknown names in `disabled` fail the build, so a typo can't silently leave a check off. A common combination: baseline mode + threshold relaxation. Set `[function_length] max_lines = 200` to your current worst case, ship Guardian, ratchet the cap down 10–20 lines per release, fix the few new violations each step.

## Config (guardian.toml)

Optional — sensible defaults work out of the box. Each check has its own section:

```toml
spec_file = "SPEC.md"
max_file_lines = 1000
file_size_exclude = ["generated/*"]
exclude = ["src/serve/templates"]   # path globs dropped from the scan entirely (generated code)
parallel = true         # run checks across cores (default); false forces sequential
cache_enabled = true    # skip a full run when the hashed input set is unchanged (default)

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
min_score_pct = 80   # fail below this kill rate
min_mutants = 4      # gate on the percentage only at >= this many viable mutants
max_mutants = 100    # deterministic sampling cap per run
timeout_secs = 300   # per-phase child build timeout (timeout = killed)

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
```

Patterns use `*` as a wildcard; without `*`, substring matching is used.

### Complete key reference

Every setting `src/config_parser.zig` understands (unknown sections/keys are
silently ignored, so a typo'd `[section]` is a no-op, not an error):

| Scope | Keys |
|---|---|
| *(top level)* | `spec_file`, `max_file_lines`, `cache_enabled`, `parallel`, `file_size_exclude`, `exclude`, `disabled` |
| `[[boundary]]` | `module`, `forbidden` |
| `[[allow]]` | `check`, `paths` |
| `[spec_quality]` | `enabled`, `forbidden_phrases` |
| `[function_size]` | `enabled`, `max_params` |
| `[complexity]` | `enabled`, `max_score` |
| `[anytype_budget]` | `enabled`, `max_per_file`, `exclude` |
| `[orphan_files]` | `enabled`, `roots` |
| `[doc_quality]` | `enabled`, `min_chars`, `exempt_names` |
| `[type_size]` | `enabled`, `max_fields`, `exclude` |
| `[function_length]` | `enabled`, `max_lines` |
| `[nesting_depth]` | `enabled`, `max_depth` |
| `[test_coverage]` | `enabled`, `exempt_names` |
| `[bool_ops]` | `enabled`, `max_ops` |
| `[line_length]` | `enabled`, `max_len` |
| `[baseline]` | `enabled`, `deny_growth` |
| `[escape_discipline]` | `enabled` |
| `[oom_discipline]` | `enabled` |
| `[magic_number]` | `enabled` |
| `[dead_pub]` | `ignore_test_refs` |
| `[change_classification]` | `enabled`, `against`, `gate_last_commit` |
| `[mutation]` | `min_score_pct`, `min_mutants`, `max_mutants`, `timeout_secs` |
| `[completeness]` | `enabled`, `exempt_sections` |
| `[dora]` | `enabled`, `sink_path` |

## Tools

```bash
zig build                            # Compile + run every gate check (the primary gate)
zig build test                       # Run tests + every gate check
zig build spec-init                  # Generate starter SPEC.md (non-gating generator)
zig build mutate                     # Mutation-test changed lines (fast tier, auto-wired)
zig build mutate-full                # Mutation-test the whole tree + ratchet (auto-wired)
zig build debt                       # Non-gating baseline/snapshot debt report
GUARDIAN_UPDATE_SNAPSHOT=1 zig build         # Refresh every drifted snapshot + baseline
GUARDIAN_UPDATE_SNAPSHOT=spec,mutate ...     # Refresh only the named checks (typo hard-fails)
GUARDIAN_AGAINST=origin/main ...             # Diff base for change-classification / mutate
```

Three environment variables tune every entry point above: **`GUARDIAN_UPDATE_SNAPSHOT`**
(`1`/`true`/`all` refreshes everything, or a comma-separated check list refreshes only those),
**`GUARDIAN_AGAINST`** (the git ref diff-scoped features compare against; the `--against` flag
wins over it), and **`GUARDIAN_MUTATION_RUN`** — set to `1` by guardian *itself* on the child
builds it spawns during mutation testing, which makes every guardian command no-op so the
deliberately-broken tree isn't gated against itself (you never set this by hand).

### `guardian-check` CLI

The checker binary also runs directly (this is what the build steps invoke):

```bash
guardian-check all .                 # Run every hard-block check
guardian-check all . --quiet         # Same, but print only failures (what the build wiring uses)
guardian-check all . --only spec,file-size   # Run ONLY the named checks
guardian-check all . --skip line-length      # Run every check EXCEPT the named ones
guardian-check nightly .             # Full suite + whole-tree mutation ratchet
guardian-check commit --intent "fix the parser" .   # Gate, then auto-commit on green
guardian-check debt .                # Baseline/snapshot debt totals + deltas (non-gating)
guardian-check explain catch-discipline      # Why a check blocks, how to fix, how to exempt
guardian-check explain               # List every check name + summary
guardian-check version               # Print the guardian version (also --version)
```

- **`--only` / `--skip`** take comma-separated check names and are mutually
  exclusive. Unknown names (or non-gates like `mutate`) hard-fail with the
  valid-name hint. A filtered run is a subset, so it never writes the green
  skip-cache stamp — a partial run can't mask a failure in the checks it skipped.
- **`commit`** gates the tree, then auto-commits the change set (see below).
  Never part of `all`; requires an explicit `--intent`.
- **`debt`** reports every baseline/snapshot total sorted high-to-low, with the
  change vs the committed `.guardian/` state (omitted outside a git repo). Never
  gates (exit 0) and is excluded from `all` — run it to decide what to pay down.
- **`explain`** prints a longer rationale for every registered check: the
  agent mistake it catches, how to fix a violation, and the exemption knob
  (`[[allow]]` paths, a config toggle, the `disabled` list, or a snapshot
  refresh). Unknown/no name lists all checks.
- **`--version` / `version`** print the version (from `src/version.zig`).

### `commit` — intent-driven auto-commit

`guardian-check commit --intent "<message>" [dir]` brings guardian-zig into the
sibling guardians' workflow: run the whole gate, then commit the change set it
just verified.

- **Red gate** → the violations print, git is left completely untouched, exit
  non-zero. **Green gate** → the change set is staged and committed with the
  intent as the message subject. Missing/empty `--intent` is a clean error with
  no side effects.
- **Safety-railed staging** (never `git add -A` / `.`): the path list comes from
  `git status --porcelain` (modified + untracked). A forbidden secret/build
  list is **skipped and reported**, never staged — `.env` / `.env.*`, `*.pem`,
  `*.key`, `*.p12`, `id_rsa*`, `*credentials*`, `*secret*`, and `zig-out/` /
  `.zig-cache/` / `zig-cache/`. `.guardian/` metadata and `SPEC.md` are **always
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
2. **Hard block** — no warnings, no bypass
3. **Zero-config** — sensible defaults
4. **Opinionated** — SPEC.md + `// spec:` tags are THE workflow
5. **Invisible** — runs on every `zig build`
6. **Self-hosting** — Guardian verifies itself
