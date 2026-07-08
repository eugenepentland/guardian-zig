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

57 checks gate Guardian's own self-build (plus the `spec-init` generator and the `mutate` command, which are explicit steps rather than gates). Most are hard-block; `test-coverage`, `escape-discipline`, `oom-discipline`, and `magic-number` are opt-in (default off). The list below is grouped by FRAMEWORK.md tier; defaults are recalibrated toward larger, evidence-based thresholds. Several formerly-standalone checks have been folded into a related one (`spec-drift`→`pub-api-surface`, `comptime-quota`→`panic-budget`, `doc-quality`→`doc-comments`, `dup-const`→`repeated-string-literal`, `vague-name-blacklist`→`naming`), and `returns-per-function` was retired as redundant with `cognitive-complexity`; their old names are still tolerated in a `disabled` list.

### Spec workflow
| Check | Blocks on |
|---|---|
| **spec** | Missing SPEC.md, unverified behaviors, unlinked tags, duplicate tags |
| **spec-quality** | Vague phrases (`properly`, `as needed`, etc.); behaviors shorter than 20 chars |

### Process gates (git-aware)
| Check | Blocks on |
|---|---|
| **change-classification** | Behavioral lines added to `src/**.zig` (vs `--against` / `GUARDIAN_AGAINST` / `[change_classification] against`, default HEAD) with **no** test-block lines, `// spec:` tags, or SPEC.md changes in the same diff — the "quick fix with no regression test" pattern. Skips silently outside a git repo. |

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
| **debug-print-ban** | `std.debug.print(...)` calls outside `pub fn main` / test blocks / CLI command modules (`cli/*`, `commands*`) |

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

Plus `zig fmt --check` and the `spec-init` generator.

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

Both tiers fail below `min_score_pct` (default 80). Scoring: timeouts count
as kills (the mutant made the suite hang — it was caught); compile-error
mutants are *unviable* and excluded. During mutant runs guardian sets
`GUARDIAN_MUTATION_RUN=1` on child builds, and every guardian command no-ops
under it — so the deliberately-broken tree isn't gated against itself.

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
GUARDIAN_UPDATE_SNAPSHOT=1 zig build
git add .guardian/
```

The snapshot files are plain text, sorted, designed to diff cleanly in code review.

## Adopting Guardian on an existing codebase

Installing 50+ hard-block checks on a project with existing violations would mean "fix everything before you can build." That's not realistic. Instead, turn on **baseline mode** — every check records its current violations on the first run and only fails when *new* ones appear. Existing violations become a frozen ratchet that you can shrink over time.

In `guardian.toml`:

```toml
[baseline]
enabled = true
```

Then run `zig build`. On the first build, `.guardian/baselines/<check>.txt` is written for each check that found violations, and the build passes. On subsequent builds:

| What changed in your code | Outcome | Exit code |
|---|---|---|
| Nothing | `<check>: baseline matches (N violation(s))` | 0 |
| You fixed some violations | `<check>: M resolved (now N) — re-run with GUARDIAN_UPDATE_SNAPSHOT=1 to prune` | 0 |
| You introduced a new violation | `<check>: K new violation(s) above baseline of N` — only the new ones are printed | 1 |
| You set the env var | `<check>: baseline refreshed (N violation(s))` | 0 |

The recommended workflow once baselines exist:
1. **PRs that fix violations** — let the build print "M resolved", then run `GUARDIAN_UPDATE_SNAPSHOT=1 zig build` and commit the shrunk baseline.
2. **PRs that intentionally accept a new violation** (rare) — same env var, same commit pattern.
3. **PRs that incidentally regress** — fix the new violation, no baseline changes.

The baseline files are plain text and sorted, so they diff cleanly in code review.

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
parallel = true    # run checks across cores (default); false forces sequential

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
[change_classification]
enabled = true
against = "HEAD"

# The mutate command's budgets (explicit step, not part of `all`).
[mutation]
min_score_pct = 80   # fail below this kill rate
max_mutants = 100    # deterministic sampling cap per run
timeout_secs = 300   # per-phase child build timeout (timeout = killed)

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

## Tools

```bash
zig build spec-init                  # Generate starter SPEC.md
zig build mutate                     # Mutation-test changed lines (fast tier, auto-wired)
zig build mutate-full                # Mutation-test the whole tree + ratchet (auto-wired)
GUARDIAN_UPDATE_SNAPSHOT=1 zig build # Refresh snapshot baselines
GUARDIAN_AGAINST=origin/main ...     # Diff base for change-classification / mutate
```

### `guardian-check` CLI

The checker binary also runs directly (this is what the build steps invoke):

```bash
guardian-check all .                 # Run every hard-block check
guardian-check all . --only spec,file-size   # Run ONLY the named checks
guardian-check all . --skip line-length      # Run every check EXCEPT the named ones
guardian-check nightly .             # Full suite + whole-tree mutation ratchet
guardian-check explain catch-discipline      # Why a check blocks, how to fix, how to exempt
guardian-check explain               # List every check name + summary
guardian-check version               # Print the guardian version (also --version)
```

- **`--only` / `--skip`** take comma-separated check names and are mutually
  exclusive. Unknown names (or non-gates like `mutate`) hard-fail with the
  valid-name hint. A filtered run is a subset, so it never writes the green
  skip-cache stamp — a partial run can't mask a failure in the checks it skipped.
- **`explain`** prints a longer rationale for every registered check: the
  agent mistake it catches, how to fix a violation, and the exemption knob
  (`[[allow]]` paths, a config toggle, the `disabled` list, or a snapshot
  refresh). Unknown/no name lists all checks.
- **`--version` / `version`** print the version (from `src/version.zig`).

## Principles

1. **AI-first** — catches agent mistakes
2. **Hard block** — no warnings, no bypass
3. **Zero-config** — sensible defaults
4. **Opinionated** — SPEC.md + `// spec:` tags are THE workflow
5. **Invisible** — runs on every `zig build`
6. **Self-hosting** — Guardian verifies itself
