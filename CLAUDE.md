# Guardian for Zig

## Guiding Principles

1. **AI-first** — Exists to catch AI agent mistakes
2. **Hard block** — All checks fail the build. No warnings, no bypass
3. **Zero-config** — Works with sensible defaults. Config only to override
4. **Opinionated** — SPEC.md + `// spec:` tags ARE the workflow
5. **Invisible** — Runs on every `zig build`. The user doesn't think about it
6. **Self-hosting** — Guardian verifies itself
7. **Zig-only** — Purpose-built for Zig
8. **Missing SPEC.md = error** — Clear message, don't create files magically
9. **1:1 spec-test mapping** — Every behavior needs exactly one matching tag

## Onboarding a New Project

```bash
# 1. Add guardian dependency to build.zig.zon
# 2. Wire guardian into build.zig (see Integration below)
# 3. Generate starter SPEC.md from your code:
zig build spec-init

# 4. Edit SPEC.md — replace placeholder behaviors with real descriptions
# 5. Add // spec: tags to your tests
# 6. Build — guardian now gates every build:
zig build
```

## Build & Run

```bash
zig build          # compiles AND runs all guardian checks
zig build test     # tests AND runs all guardian checks
zig build run      # runs AND runs all guardian checks
zig build spec-init  # generate starter SPEC.md from pub fn signatures
zig build mutate     # mutation-test lines changed vs HEAD (fast tier)
zig build mutate-full  # mutation-test the whole tree + score ratchet
zig build debt       # non-gating baseline/snapshot debt report
```

The `mutate` / `mutate-full` steps are auto-registered by `addAllChecks`
(`opts.mutate_steps` defaults true), so consumers get them for free; the
registration is idempotent.

The `guardian-check` binary also runs directly:

```bash
guardian-check nightly .             # full suite + whole-tree mutation ratchet (CI/cron tier)
guardian-check commit --intent "..." .  # gate the tree, then auto-commit on green
guardian-check all . --only spec,file-size  # run only these checks (no green cache stamp)
guardian-check all . --skip line-length     # run every check except these
guardian-check debt .                # baseline/snapshot debt totals + deltas (non-gating)
guardian-check explain <check>       # why it blocks, how to fix, how to exempt (no name = list all)
guardian-check version               # print the version (also --version)
```

Guardian is invisible — it gates every build automatically.

## Integration

Add to `build.zig.zon`:
```zig
.guardian = .{ .path = "../guardian-zig" },
```

Add to `build.zig`:
```zig
const guardian = @import("guardian");
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
const check_exe = guardian_dep.artifact("guardian-check");

// Format check
const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
b.getInstallStep().dependOn(&fmt_check.step);

// One call wires every hard-block check into the install step.
// Adding new checks doesn't change this snippet.
guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{});

// spec-init: generate starter SPEC.md (separate step, not a gate)
const spec_init_run = b.addRunArtifact(check_exe);
spec_init_run.addArgs(&.{ "spec-init", "." });
const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
spec_init_step.dependOn(&spec_init_run.step);
```

## Config (guardian.toml)

Optional. Defaults are sensible:
```toml
spec_file = "SPEC.md"        # default
max_file_lines = 1000         # default
file_size_exclude = ["generated/*", "*/vendor_*.zig"]

[[boundary]]
module = "src/core/*"
forbidden = ["utils"]
```

### Pattern syntax

All patterns use `*` as a wildcard matching any characters:
- `src/generated/*` — matches files under src/generated/
- `*/vendor_*.zig` — matches vendor files in any directory
- `utils` — plain substring match (no `*` = backward compatible)

This syntax is used in both `file_size_exclude` and `[[boundary]]` module patterns.

## Spec-Driven Workflow

1. Generate starter spec: `zig build spec-init`
2. Edit `SPEC.md` with real behavior descriptions:
   ```markdown
   ## Authentication
   - Validates JWT tokens on every request
   - Rejects expired tokens with 401
   ```

3. Tag each test with exactly one matching `// spec:` comment:
   ```zig
   // spec: Authentication - Validates JWT tokens on every request
   test "jwt validation" { ... }
   ```

4. Guardian enforces 1:1 coverage. Missing tags or duplicate tags fail the build.

## What Guardian Checks

62 checks gate the build (most hard-block; completeness/test-coverage/
escape-discipline/oom-discipline/magic-number/fuzz-presence are opt-in, default
off) plus `zig fmt --check`. Three more registry entries are non-gating steps,
never part of `all`: the `spec-init` generator, the `mutate` command, and the
`debt` report (65 registry entries total; `all`/`nightly`/`commit`/`explain`/`version`
are dispatched specially and aren't registry entries). Full table in README.md;
the categories are: spec workflow, git-aware process gates, structural,
public API, code style, error handling, and allocation. Four checks are
snapshot-based (pub-api-surface, panic-budget, int-from-float-budget,
unsafe-ops-budget) — refresh with `GUARDIAN_UPDATE_SNAPSHOT=1 zig build`
and commit `.guardian/`. `GUARDIAN_UPDATE_SNAPSHOT` is now *selective*: `=1`
(or `true`/`all`) refreshes everything, but a comma-separated check-name list
(`=pub-api-surface,spec`) refreshes only those checks' snapshots/baselines —
one accepted change no longer ratifies unrelated drift. An unknown name in the
list hard-fails the run. The non-gating `guardian-check debt [dir]` (`zig build
debt`) reports every baseline/snapshot total, sorted by count, with the delta
vs the committed `.guardian/` state, then an informational assert-density table
(assert() calls per KLOC per top-level src module, ascending).

Two features diff the working tree against a git ref (`--against` flag,
`GUARDIAN_AGAINST` env var, or `[change_classification] against`; default
HEAD): the `change-classification` check fails behavioral src changes that
ship with no test or spec change (skips outside a git repo), and the
`mutate` command (explicit step, never part of `all`) mutation-tests the
suite — the fast tier mutates only changed lines, `--full` ratchets a
whole-tree kill score in `.guardian/mutation.txt` and both gate on
`[mutation] min_score_pct` (default 80). Child builds during mutation run
with `GUARDIAN_MUTATION_RUN=1`, which makes every guardian command no-op.
The `mutate`/`mutate-full` build steps are auto-wired by `addAllChecks`
(`opts.mutate_steps`, idempotent), and the `nightly` command composes `all`
+ `mutate --full` for the scheduled/CI tier (dispatched specially, like `all`,
so it never appears in the registry). `all` also accepts `--only a,b` /
`--skip a,b` (mutually exclusive; unknown names hard-fail; a filtered run
never writes the green skip-cache stamp); `explain <check>` prints a check's
rationale/fix/exemption; `version` (or `--version`) prints the version.

Some checks were folded into a related one to cut overlap
(spec-drift→pub-api-surface, comptime-quota→panic-budget,
doc-quality→doc-comments, dup-const→repeated-string-literal,
vague-name-blacklist→naming), and returns-per-function was retired as
redundant with cognitive-complexity; the retired names are still tolerated
in a `disabled` list. Per-check path exemptions live in guardian.toml `[[allow]]`
entries (check + paths), not compiled into the checks.

`all` runs are cached: when the hashed input set (src/test/build/spec/
guardian.toml/.guardian) is unchanged since the last green run, checks are
skipped. The green stamp is written *after* checks run (recomputed over the
post-write tree), so a run that rewrites `.guardian/` — an auto-pruned baseline,
a freshly created snapshot — doesn't trigger a spurious full re-run next build,
and a `.guardian/` that diverges from the stamped state always re-runs. Disable
with `cache_enabled = false`. Turn off individual checks with a top-level
`disabled = ["check-name", ...]` list (not a per-check `enabled` flag).

Baseline mode (`[baseline] enabled = true`) auto-prunes: when violations
resolve, the baseline file is rewritten smaller in place (no refresh env var).
The ten threshold checks (function-length, nesting-depth, cognitive-complexity,
function-size, type-size, file-size, struct-method-cap, optional-density,
bool-ops-per-condition, line-length) use **per-item ratchets** (baseline v2):
each offender is stored as `<value> <key>` and gets a personal only-shrinks
ceiling, so an improvement that's still over cap no longer reds the build; v1
text baselines self-migrate to v2 on first build. `[baseline] deny_growth =
["spec", ...]` freezes the named checks' baselines against ever growing — a
refresh that would raise their count (or add a key) fails instead.

Every `all`/`nightly` run also drops machine-readable JSONL under the
git-ignored, digest-excluded `.guardian/cache/`: `last-run.jsonl` (structured
violations + summary) and `dora.jsonl` (per-run delivery metrics); `mutate`
adds `last-mutate.jsonl` (survivors) and `mutants.jsonl` (result cache).

## Project Structure

```
src/
  check.zig            # CLI entry / dispatch
  cli/                 # Command registry + run_all + mutate/nightly/commit/debt/explain commands
  checks/              # One file per check
  spec/                # SPEC.md parser, // spec: matcher, spec-init
  ast/                 # Zig AST helpers (pubFns, fnDeclInfos, import_graph)
  git.zig              # git diff parsing/shell-outs for diff-scoped features
  mutation/            # Mutant generator, in-place splice/test runner, result cache + survivor report
  walk.zig             # Recursive .zig file walker (visitor pattern)
  reporter.zig         # ok / fail printing + Violation type
  sink.zig             # last-run.jsonl machine-readable violation log
  dora.zig             # DORA delivery-metrics JSONL sink (non-gating)
  snapshot.zig         # Read/write/diff for snapshot-based checks
  snapshot_helper.zig  # Lifecycle helper used by all snapshot checks
  baseline.zig         # Baseline mode for legacy violations (v1 text baselines)
  ratchet.zig          # Per-item ratchets (baseline v2) for threshold checks
  cache.zig            # Skip-when-unchanged input digest for `all`
  config.zig           # guardian.toml parser
  build_helper.zig     # addAllChecks for downstream consumers
  fakes/               # Deterministic test doubles (FakeClock/SeededRandom/FakeFs/FakeEnv) — the `guardian-fakes` module consumers import in tests
  testing/             # Golden-file test harness
```
