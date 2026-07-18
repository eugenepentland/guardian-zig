# Guardian for Zig — Audit Brief

*Prepared 2026-07-14 for an external reviewer. This is a self-contained overview of what
the tool is, why it exists, and how it works. You should be able to form an opinion from
this document plus a skim of the codebase; pointers to deeper in-repo docs are at the end.*

---

## 1. What it is, in one paragraph

Guardian is a **build-step quality gate for Zig projects, purpose-built to catch the
mistakes AI coding agents make**. It wires into `zig build` as a hard block: every build
runs ~65 static checks over the source tree, and any violation fails the build — no
warnings, no bypass flags. Its centerpiece is an enforced **spec-driven workflow**: every
behavior listed in a project's `SPEC.md` must map 1:1 to a test carrying a matching
`// spec:` tag, so an agent can't ship code whose claimed behavior has no verifying test.
Around that core it layers structural limits, dependency-injection discipline, error-handling
rules, snapshot ratchets on dangerous constructs, diff-aware process gates, and an
explicit-step mutation tester that proves the tests actually bite.

## 2. The problem it solves

AI agents write plausible code fast, and their failure modes are systematic rather than
random:

- **Claiming behavior without testing it** — "done" with no regression test, or a test
  that exists but asserts nothing.
- **Silently swallowing errors** — `catch {}`, `catch unreachable`, stubbed bodies that
  `return undefined`.
- **Grabbing hidden dependencies** — reading the clock, filesystem, network, environment,
  or RNG directly in domain code, making the code untestable and nondeterministic.
- **Quiet scope creep** — widening the public API, adding `@panic`s or unsafe casts,
  hardcoding secrets or absolute paths, all in a diff nobody asked for.
- **Gaming the gate itself** — an empty test, a skipped test, or a spec tag on a test that
  never runs still "counts" unless the gate is designed against it.

Human-oriented linters treat these as style warnings a developer can ignore. Guardian's
thesis is that **for an agent-driven workflow the gate must be hard, invisible, and
un-negotiable**: the agent runs `zig build`, the build is red or green, and the only path
to green is fixing the code (or making an explicit, human-reviewable exemption in config
or a committed snapshot file).

## 3. Guiding principles

These are the project's own stated invariants — a useful lens for the audit is *whether
the implementation actually upholds them*:

1. **AI-first** — exists to catch agent mistakes, not to bikeshed human style.
2. **Hard block** — every check fails the build. No warning tier, no `--force`.
3. **Zero-config** — sensible defaults; `guardian.toml` only overrides.
4. **Opinionated** — `SPEC.md` + `// spec:` tags ARE the workflow, not an option.
5. **Invisible** — runs on every `zig build`; the user shouldn't think about it.
6. **Self-hosting** — Guardian gates its own build with all checks enabled.
7. **Zig-only** — purpose-built; leans on Zig's AST and tokenizer, no generic-linter core.
8. **Missing SPEC.md is an error** — never silently creates files.
9. **1:1 spec-test mapping** — every behavior needs exactly one matching tag; missing
   *and duplicate* tags both fail.

## 4. How it works

### Integration

A consumer adds Guardian as a `build.zig.zon` dependency and makes one call in
`build.zig` — `guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{})` — which
wires every gating check (plus `zig fmt --check` and the `mutate`/`mutate-full` steps)
into the install step. From then on, `zig build`, `zig build test`, and `zig build run`
all run the full gate.

The checker is also a standalone binary (`guardian-check`) with subcommands:
`all` (the full gate, with `--only`/`--skip` filters), `nightly` (full gate + whole-tree
mutation ratchet, for CI/cron), `commit --intent "..."` (gate, then auto-commit the
verified change set with safety-railed staging), `debt` (non-gating report of all frozen
baseline/snapshot debt), `explain <check>` (rationale/fix/exemption for any check),
`spec-init` (generate a starter SPEC.md), and `mutate`.

### The check suite (~65 checks, 68 registry entries)

64 checks gate the build; a 65th (`stdout-flush`) is report-only by default because its
heuristic is intra-procedural and can false-positive. Three registry entries are explicit
non-gating steps (`spec-init`, `mutate`, `debt`). Six checks are opt-in, default off
(`test-coverage`, `escape-discipline`, `oom-discipline`, `magic-number`, `completeness`,
`fuzz-presence`). The families:

| Family | Representative checks | What it catches |
|---|---|---|
| **Spec workflow** | `spec`, `spec-quality`, `completeness` | Missing/unverified behaviors, unlinked or duplicate tags, vague spec prose, unaddressed failure scenarios |
| **Process gates (git-aware)** | `change-classification` | Behavioral src changes with no test or spec change in the same diff — the "quick fix, no regression test" pattern |
| **Structural** | `file-size`, `function-length`, `nesting-depth`, `imports` (cycles), `boundaries`, `orphan-files` | Size/complexity blowups, dependency-direction violations, unreachable files |
| **Public API** | `pub-api-surface` (snapshot), `dead-pub` | Unintended API changes, dead exported code |
| **Code style** | `naming`, `doc-comments`, `cognitive-complexity`, `deprecated-alias`, `usingnamespace-ban` | Zig-idiom violations, undocumented public API, stale 0.15 std spellings |
| **Error handling** | `catch-discipline`, `unwrap-discipline`, `stack-escape`, `stub-body-ban`, `panic-budget` (snapshot), `unsafe-ops-budget` (snapshot), `fatal-exit` | Swallowed errors, dangling stack pointers, placeholder bodies, creeping `@panic`/unsafe-cast counts |
| **Allocation** | `allocator-hygiene`, `oom-discipline` | Hardcoded global allocators, OOM conflated with "not found" |
| **Hidden-dependency bans** | `ban-time`, `ban-rng`, `ban-fs`, `ban-net`, `ban-env`, `ban-sleep`, `ban-globals`, `ban-hardcoded-paths`, `ban-secrets`, `debug-print-ban` | Nondeterminism acquired instead of injected; secrets and absolute paths in source |
| **Constructor/DI hygiene** | `init-hygiene`, `static-factory-ban`, `init-deinit-symmetry`, `errdefer-in-init` | Logic in constructors, singletons, leaked allocators |
| **Test hygiene** | `test-has-assertion`, `test-no-conditional`, `test-skip-ban`, `fuzz-presence` | Tests that assert nothing, tests with control flow, tests that skip themselves while still satisfying their spec tag |
| **Anti-patterns** | `boolean-param-ban`, `repeated-string-literal`, `stringly-typed-switches`, `repeated-switch-on-enum` | API smells and duplicated dispatch |

The check taxonomy and thresholds derive from an evidence-based framework document
(`FRAMEWORK.md`): the thesis is that testability is the leading indicator of change-cost,
so the highest-leverage rules prevent hidden dependencies, enforce dependency direction,
and bound complexity — not stylistic preference.

### Escape valves (all explicit and reviewable)

Hard-block doesn't mean no exemptions — it means every exemption is a **committed,
diffable artifact** rather than an ignored warning:

- **`[[allow]]` entries** in `guardian.toml` grant per-check path exemptions (this is
  also how Guardian records its own self-hosting carve-outs, so downstream repos never
  inherit them).
- **Snapshot checks** (`pub-api-surface`, `panic-budget`, `int-from-float-budget`,
  `unsafe-ops-budget`) freeze a count/surface in plain-text files under `.guardian/`;
  accepting a change requires `GUARDIAN_UPDATE_SNAPSHOT=<check-name>` and committing the
  diff. The refresh is **selective by name** — accepting one intended change can't
  silently ratify unrelated drift; an unknown name hard-fails.
- **Baseline mode** for adopting on legacy codebases: existing violations are frozen per
  check and only *new* ones fail. The ten threshold checks use **per-item ratchets**
  (each offender gets a personal, only-shrinks ceiling), so an improvement that's still
  over cap doesn't red the build, and default caps stay strict for all new code.
  Baselines auto-prune as violations are fixed; `deny_growth` can freeze named checks'
  baselines against ever growing.
- **`disabled` list** turns checks off by name (unknown names fail — a typo can't
  silently disable nothing).
- **Inline waivers** exist only where a check is provably over-strict for a specific
  line: `// allocator-ok:` and `// mutate-ok: <reason>` (equivalent mutants).

### Mutation testing (`mutate`)

Static checks prove tests *exist*; mutation testing proves they *bite*. Guardian splices
single-operator bugs into production code (comparison flips, `+`/`-` swaps, `and`/`or`
swaps, boolean flips), runs the suite against each mutant, and reports **survivors** —
mutants no test killed. Two tiers: a **fast tier** mutating only lines changed vs a git
ref (cheap enough for every PR) and a **full tier** with a whole-tree kill-score ratchet
in `.guardian/mutation.txt`. Both gate on `min_score_pct` (default 80) once a minimum
viable-mutant floor is met. A per-mutant result cache makes re-runs and resumes
near-instant. Mutation is an explicit step, never part of the default gate (each mutant
costs a build+test cycle); `nightly` composes the full gate + full mutation for CI.

### Performance and ergonomics

- **Skip cache**: a green `all` run stamps a digest of the input set (src, tests,
  build files, SPEC.md, guardian.toml, `.guardian/`); an unchanged tree skips the run.
  Filtered (`--only`/`--skip`) runs never write the stamp, so a partial run can't mask
  a failure.
- **Machine-readable output**: every run drops JSONL under the git-ignored
  `.guardian/cache/` — `last-run.jsonl` (structured violations with stable ratchet keys
  and metrics), `dora.jsonl` (per-run delivery metrics: outcome, failed checks,
  duration), `last-mutate.jsonl` (survivors), `mutants.jsonl` (result cache). Agents
  consume these instead of scraping terminal prose.
- **`explain`**: every check documents the agent mistake it catches, how to fix a
  violation, and its exemption knob.
- **Deterministic fakes**: a standalone `guardian-fakes` module ships `FakeClock`,
  `SeededRandom`, `FakeFs`, `FakeEnv` — the test doubles you put behind the ports that
  the `ban-*` checks force you to create.

## 5. Architecture at a glance

```
src/
  check.zig            # CLI entry / dispatch
  cli/                 # Command registry + run_all + mutate/nightly/commit/debt/explain
  checks/              # One file per check (~67 files)
  spec/                # SPEC.md parser, // spec: matcher, spec-init generator
  ast/                 # Zig AST helpers (pub fns, fn decl info, import graph)
  git.zig              # git shell-outs for diff-scoped features
  mutation/            # Mutant generator, in-place splice/test runner, result cache
  walk.zig             # Recursive .zig file walker
  reporter.zig         # ok/fail printing + structured Violation type
  sink.zig / dora.zig  # JSONL sinks (violations, delivery metrics)
  snapshot*.zig        # Snapshot lifecycle for budget checks
  baseline.zig / ratchet.zig  # v1 text baselines + v2 per-item ratchets
  cache.zig            # Skip-when-unchanged input digest
  config.zig           # guardian.toml parser (fails closed on unknown keys)
  build_helper.zig     # addAllChecks for consumers
  fakes/               # guardian-fakes module
```

Checks parse each file once into a shared AST/token index and run in parallel across
cores. The config parser fails closed: an unknown section or key is a hard error with a
`guardian.toml:line:` diagnostic. Guardian is fully self-hosting — its own build runs all
64 gates plus four of the opt-ins, and its parser/matcher/scanner cores carry
`std.testing.fuzz` harnesses.

## 6. Known limitations (acknowledged by the project)

- **Sequential mutation runs.** Mutants are spliced into the real tree in place, so they
  can't run concurrently. Copy-tree sandboxes break consumers with relative-path
  dependencies; parallelism is deferred. Mitigated by the fast tier + result cache.
- **`stdout-flush` is heuristic** (intra-procedural), hence report-only by default.
- **Deferred checks**: allocator-injection, train-wreck chains, stable-deps metrics,
  duplicate-token detection, port-implementation verification — designed but not built
  (see README "Future work").
- **Gate escapes have been found before.** Prior internal audits (in-repo `AUDIT.md`,
  `AUDIT-2026-07-08.md`) surfaced real self-defeating bugs — test files not wired into
  the test root (tests that never ran but still satisfied spec tags), AST checks blind
  to nested containers, and a commit-then-build sequencing hole in
  `change-classification`. These were fixed (e.g. the `commit` command now gates the
  exact diff it commits, closing the timing hole), but the pattern — *the gate itself is
  the attack surface* — is the project's most important recurring risk.

## 7. What we'd like your opinion on

Any honest reaction is useful, but these are the live questions:

1. **Concept**: Is "hard-block build gate designed against agent failure modes" the right
   shape for this problem, or does the value live in a subset (spec↔test mapping +
   mutation testing) with the other ~50 checks as noise? Is the 1:1 spec-test mapping a
   feature or a straitjacket?
2. **Gameability**: If you were an agent (or a lazy human) trying to get to green without
   doing the work, where would you push? Trivial-but-tagged tests, spec bullets written
   to match code after the fact, `mutate-ok` abuse, baseline-mode adoption that freezes
   everything forever?
3. **Check portfolio**: Which checks would you cut, demote, or merge? Is there a tier of
   checks whose false-positive/config-burden cost exceeds the class of bug they catch?
4. **Adoption realism**: Would a team (or an agent fleet) actually live with this on a
   real codebase? Is baseline/ratchet mode enough to make retrofit tolerable, or is the
   all-or-nothing hard-block still too hostile?
5. **Escape-valve design**: Are committed snapshots + named selective refresh + `[[allow]]`
   paths the right exemption model, or does it just relocate the bypass problem into
   files an agent can also edit?
6. **Mutation tier**: Is the fast-tier/full-tier split with a ratcheted score the right
   cost/value trade, or is mutation testing on every PR unrealistic even scoped to
   changed lines?
7. **Anything structurally missing** for the stated goal — a class of agent mistake with
   no covering check, or a workflow moment (PR review, CI, commit) the gate doesn't reach?

## 8. Where to look next

| Doc | Contents |
|---|---|
| `README.md` | Full check table, config reference, adoption guide, mutation details |
| `FRAMEWORK.md` | The research framework the check tiers/thresholds derive from |
| `SPEC.md` | Guardian's own spec — every behavior the suite verifies about itself |
| `AUDIT.md`, `AUDIT-2026-07-08.md` | Prior internal audits and their findings |
| `RESEARCH-BRIEF.md` | Feature-space inventory used for brainstorming within scope |
| `guardian.toml` | Guardian's own self-hosting config, including its `[[allow]]` carve-outs |
