# Guardian for Zig

## Usage Feedback Log

`FEEDBACK.md` (repo root) is the append-only log where agents record friction,
bugs, wins, and wishes after working in any Guardian-gated project — the format
and append rules are documented at the top of that file. When working on
Guardian itself, read it first: open `friction:`/`wish:` entries are the triage
backlog Eugene draws changes from. Never delete or rewrite existing entries;
pruning happens only when Eugene triages.

## Guiding Principles

1. **AI-first** — Exists to catch AI agent mistakes
2. **Hard block at commit** — Nothing enters history unverified; dev builds report, never refuse
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
zig build          # compiles AND runs all checks in REPORT mode (exit 0; findings printed)
zig build test     # tests AND runs all checks (report mode); unit-test failures still fail
zig build test -Dtest-filter=<name>  # narrow the run; the runner prints how many it selected
zig build test-compile  # compile every test, run none (the cheap whole-suite tier)
zig build run      # runs AND runs all guardian checks (report mode)
zig build spec-init  # generate starter SPEC.md from pub fn signatures
zig build mutate     # mutation-test lines changed vs HEAD (fast tier)
zig build mutate-full  # mutation-test the whole tree + score ratchet
zig build debt       # non-gating baseline/snapshot debt report
```

**The filtered test loop is honest, and still not the suite.** Guardian's own
suite runs on Guardian's test runner (`src/test_runner.zig`), which prints
`guardian/test: N test(s) selected` before the first test and **fails** when
nothing the filter named ran — a zero-match `-Dtest-filter` used to exit 0,
byte-identical to a green run (`GUARDIAN_TEST_ALLOW_EMPTY=1` opts out for a
project with no tests yet). "Nothing named" rather than "no tests" because
unnamed `test { }` blocks have no name to match and compile into every filtered
binary: guardian's two would otherwise report a comforting `2 test(s) selected`
for a filter that matched nothing. That check needs the filter texts, which Zig
never gives a runner — `guardian.announceFilters(run, filters)` forwards them.
The second gap is structural: Zig gives `--test-filter` to the
*compiler*, so a filtered build never analyzes the tests it skipped and cannot
prove the suite compiles. `zig build test-compile` is that missing tier —
whole-suite, no filter, `-fno-emit-bin`, so it type-checks everything and runs
nothing. It is deliberately not a dependency of `test`.

**The runner also guards what the suite COSTS.** After the last test it prints
`guardian/test: test wall <t>s` plus the slowest tests over a floor
(`GUARDIAN_TEST_TIMINGS` widens both). On top of that, a test whose own wall
time reaches **5 s** gets a `guardian/test: SLOW  <t>s  <name>` line the moment
it finishes — always on, streamed, so a creeping hog is named on every run
rather than only in a table at the end. Two **opt-in** caps turn that into a
failure: `GUARDIAN_TEST_MAX_TEST_SECS` (per test) and
`GUARDIAN_TEST_MAX_WALL_SECS` (whole-run total of test time), unsigned seconds,
where absent/empty/unparseable/`0` all mean unset. A broken cap never cuts the
run short — every test runs and reports, then the run prints which test(s) blew
the per-test cap (and/or the wall total against its cap) and exits non-zero.
They are **opt-in** because wall time on a shared box is not deterministic
(measured 2026-08-10: the same suite 2x slower under concurrent builds), which
is also why the always-on tier only warns. **A cap is not a watchdog** — it is
read off a test that finished, so a hung test still hangs; caps catch cost
regressions, not deadlocks. To put one in a project's gate, note that
`[gate] test_command` is **argv-split and run with no shell**, so a bare
`VAR=1 zig build test` fails with `FileNotFound`; use `env(1)`:

```toml
[gate]
test_command = "env GUARDIAN_TEST_MAX_WALL_SECS=120 zig build test"
```

`testTier` strips a leading `env NAME=VALUE …` before classifying, so that
still counts as the whole default suite and draws no advisory.

**The installed `guardian-check` is ReleaseSafe by default** — a plain
`zig build` (no `-Doptimize`) builds `zig-out/bin/guardian-check` optimized,
because consumer projects (eda) run it as their commit gate and a Debug build
turns that ~1.1 s whole-tree gate into ~42 s, silently, for every agent commit
until someone notices (measured 2026-07-26). An explicit `-Doptimize=Debug`
still produces a Debug binary for debugger work; the test suite keeps the
plain Debug default so its compile stays fast. If commits in a consumer repo
start reporting a gate of tens of seconds, check this binary's size first
(ReleaseSafe ≈ 10 MB, Debug ≈ 55 MB).

**Consumers reuse that binary instead of recompiling it.** `addAllChecks`
prefers `<guardian dep root>/zig-out/bin/guardian-check` over a from-source
compile, because a consumer with a private per-worktree Zig cache otherwise pays
a full cold ReleaseSafe compile of an unchanged tool before any of its own code
builds (measured on a minimal consumer, fresh `--cache-dir`: 67.9 s → 11.3 s).
Selection order: self-hosting always compiles, then `GUARDIAN_PREBUILT=off|0`
compiles, then `GUARDIAN_PREBUILT=<path>` runs that binary, then the
dependency's installed binary, else compile. Every prebuilt invocation depends
on one prepended `guardian-selfcheck` step running `guardian-check selfcheck
<dep root>`, which recomputes the source digest `build.zig` embedded at
configure time (`src/source_digest.zig`, imported by both sides so they cannot
drift) and **fails the build** on a mismatch — never a warning. Guardian's own
build never uses the prebuilt path, whatever `GUARDIAN_PREBUILT` says: a
zig-out binary gating the source it was built from is the stale-binary trap, and
selfcheck cannot catch it there. `guardian-check version` prints the digest.

**Report during dev, block at commit** (`[gate] on_build`, default `"report"`).
A plain `zig build` runs every check and prints findings but exits 0, so a dev
build always produces a binary — verify guardian-clean with `guardian-check all
. --gate` (or set `on_build = "block"`). `commit`/`nightly`/`accept` and the
pre-commit hook always block.

**Diff-scoped during dev, whole-tree at commit.** A local `zig build` scopes
the *per-file* checks to the files changed since the merge base with
`main`/`master`; the inherently whole-tree checks (import cycles, cross-file
duplicates, dead-pub / test-coverage maps, orphan and test reachability, SPEC↔tag
coverage, every tree-wide snapshot/budget) still read everything. Each check's
capability is the `scope` field on its `cli/registry.zig` entry — it has **no
default**, so a new check must classify itself; `src/scope.zig` owns the
decision. A scoped run announces itself, never stamps the green cache, and
never prunes or rewrites a baseline/ratchet. `--full`, `--gate`, `commit`,
`nightly`, `accept`, `migrate`, any metadata-writing run, and uncommitted
guardian.toml / `.guardian/` drift all fall back to the whole tree;
`--against <ref>` picks an explicit base.

The `mutate` / `mutate-full` steps are auto-registered by `addAllChecks`
(`opts.mutate_steps` defaults true), so consumers get them for free; the
registration is idempotent.

The `guardian-check` binary also runs directly:

```bash
guardian-check all . --gate          # BLOCK mode: fail on any violation (what the pre-commit hook runs)
guardian-check nightly .             # full suite + whole-tree mutation ratchet (CI/cron tier; always blocks)
guardian-check commit --intent "..." .  # block-gate, run tests, auto-commit + install hook on green
guardian-check install-hook .        # write .git/hooks/pre-commit that runs the blocking gate
guardian-check all . --only spec,file-size  # run only these checks (no green cache stamp)
guardian-check all . --skip line-length     # run every check except these
guardian-check all . --summary       # verdict line + blocking detail only (advisory collapsed to counts)
guardian-check all . --verbose       # replay every check in full (overrides --summary and scope-collapse)
guardian-check all . --full          # whole tree: opt out of the default diff scoping
guardian-check all . --against origin/main  # diff-scope against an explicit base ref
guardian-check size src/foo.zig .    # one file's CURRENT measurements vs caps + frozen ratchet ceilings
guardian-check debt .                # baseline/snapshot debt totals + deltas (non-gating)
guardian-check debt . --current      # + each ratcheted key's current value vs its ceiling (re-parses the tree)
guardian-check bench set <name> <value> --unit s --dir min --note "..." .  # record a measurement
guardian-check bench list .          # print the benchmark ledger (.guardian/benchmarks.txt)
guardian-check explain <check>       # why it blocks, how to fix, how to exempt (no name = list all)
guardian-check explain completeness --section "<name>" .  # dry-run one SPEC.md section's 8 categories
guardian-check selfcheck <guardian-root>  # prove a prebuilt binary matches that Guardian source
guardian-check version               # print the version + source digest (also --version)
```

Guardian is invisible — every build runs it (report mode by default), and
commit/hook/`--gate` block on any violation.

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
// Adding new checks doesn't change this snippet. It also picks how
// guardian-check is reached: the dependency's already-built
// zig-out/bin/guardian-check when there is one (behind a fail-closed
// `guardian-selfcheck` staleness step), else a compile from source.
// GUARDIAN_PREBUILT=off forces the compile; GUARDIAN_PREBUILT=<path> picks a
// binary.
guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{});

// spec-init: generate starter SPEC.md (separate step, not a gate)
const spec_init_run = b.addRunArtifact(check_exe);
spec_init_run.addArgs(&.{ "spec-init", "." });
const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
spec_init_step.dependOn(&spec_init_run.step);

// Honest filtered test loop (both optional, both one line).
// 1. The counting runner: prints `guardian/test: N test(s) selected` and
//    fails a run that selected none (GUARDIAN_TEST_ALLOW_EMPTY=1 opts out).
const filters = b.option([]const []const u8, "test-filter", "Run only matching tests") orelse &.{};
guardian.enableTestDiagnostics(test_mod); // retained assertion locations in optimized test builds
const unit_tests = b.addTest(.{
    .root_module = test_mod,
    .filters = filters,
    .test_runner = guardian.testRunner(guardian_dep),
});
const run_tests = b.addRunArtifact(unit_tests);
guardian.announceFilters(run_tests, filters); // optional: name the filters in the line

// 2. `zig build test-compile`: compile every test, run none — the cheap
//    whole-suite tier a filtered run can never provide. Never a dep of `test`.
_ = guardian.addTestCompileProbe(b, .{ .root_module = test_mod });
```

## Config (guardian.toml)

Optional. Defaults are sensible:
```toml
spec_file = "SPEC.md"        # default
max_file_lines = 1000         # default
hard_max_file_lines = 10000   # only extreme files fail; ordinary growth warns
file_size_exclude = ["generated/*", "*/vendor_*.zig"]
required_inputs = ["src/generated/*.zig"] # codegen must produce at least one match

[gate]
on_build = "report"          # "report" (default: dev builds report, exit 0) | "block"
test_command = "zig build test"   # commit runs this (must pass) before committing
install_hook = true          # commit auto-installs the blocking pre-commit hook

[[boundary]]
module = "src/core/*"
forbidden = ["utils"]

# Your own banned symbols, enforced by the `ban` check (no entries = trivial pass)
[[ban]]
chain = ["optimizer", "placeFromPoses"]   # one identifier per segment
paths = ["src/serve/*"]                   # omit for the whole tree
allow = ["src/serve/route_seed.zig"]      # the sanctioned wrapper itself
reason = "call through RouteSeed instead" # ends every violation message
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

**A spec failure carries its own fix, on the advisory channel.** The violation
*lines* are frozen text — a spec violation is baselined by its rendered form
(`violation_key.zig` tier 3), so changing a word of `unlinked tag: <tag> in
<file>` would re-key every consumer's committed baseline. Everything the check
learned therefore rides `reporter.warn`, which baselines and ratchets exclude by
construction and which survives baseline mode's capture-and-replace of a check's
own output: **one hint per unlinked tag** (the exact bullet to paste; or "a
bullet with this exact text already lives under `## Other`" for the
wrong-`## `-section mistake, whose two halves otherwise read as an unrelated
`unlinked tag:` and `unverified:` pair; or "closest bullet is X (N char(s)
apart)" for a drifted rewording), a note that **the tag scan walks `test/` and
`src/` on disk rather than the compiled test set** (so a `-Dtest-filter` build
sees the same list and the list is complete — the opposite belief is what turned
one edit into an edit-per-tag loop), and `N other tag(s) here are
baselined-unlinked` for a file whose other tags are frozen debt. Tags already in
the baseline get no hint, so the guidance is about the new work only.

`guardian-check explain completeness --section "<name>" [dir]` answers "what
would this section need?" without running the gate: per-category `ok` / `waived`
/ `MISSING` against the CURRENT SPEC.md with the evidence for each, or a
paste-ready skeleton when the heading does not exist yet. `explain completeness`
(no `--section`) prints the category → keyword table, which was previously
readable only in `src/checks/completeness.zig`.

## What Guardian Checks

70 checks gate the build (most hard-block; completeness/test-coverage/
escape-discipline/oom-discipline/magic-number/fuzz-presence are opt-in, default
off; one of them, stdout-flush, is report-only by default — it runs in `all`
but never fails the build unless `[stdout_flush] enabled = true` promotes it to a
gating hard-block, which Guardian leaves off). Formatting is one of them:
the `formatting` check runs FIRST in every `all` pass and prints immediately
(cheapest gate, one-command fix), so a consumer no longer needs its own
`zig fmt --check` build step. Three more registry entries are
non-gating steps, never part of `all`: the `spec-init` generator, the `mutate`
command, and the `debt` report (73 registry entries total;
`all`/`nightly`/`commit`/`explain`/`version`
are dispatched specially and aren't registry entries). Full table in README.md;
the categories are: spec workflow, git-aware process gates, structural,
public API, code style, error handling, and allocation. Four checks are
snapshot-based (pub-api-surface, panic-budget, int-from-float-budget,
unsafe-ops-budget) — refresh with `zig build guardian-accept -Dguardian-checks=<check>`
flow and commit `.guardian/`. `GUARDIAN_UPDATE_SNAPSHOT` remains selective: `=all`
is the only broad refresh, while a comma-separated check-name list
(`=pub-api-surface,spec`) refreshes only those checks' snapshots/baselines —
one accepted change no longer ratifies unrelated drift. Ambiguous `=1` and
`=true` values, plus unknown names, hard-fail — with one alias, since one
snapshot leaf is spelled differently from its check: `pub-api` (the basename of
`.guardian/pub-api.txt`) resolves to `pub-api-surface` in `accept`,
`--only`/`--skip`, and `GUARDIAN_UPDATE_SNAPSHOT`. pub-api-surface's drift
report is grouped rather than one alphabetical add/remove list: a signature edit
prints as a single `~ key | old -> new` line under `changed:`, a byte-identical
signature that reappeared under a different file prints as
`moved: <fileA> -> <fileB> :: <name>` and counts as neither new nor removed
(still drift — the snapshot must be accepted), and an additions-only delta
carries the accept commands on the line under the summary. The non-gating `guardian-check debt [dir]` (`zig build
debt`) reports every baseline/snapshot total, sorted by count, with the delta
vs the committed `.guardian/` state, then an informational assert-density table
(assert() calls per KLOC per top-level src module, ascending).

**Report vs block (`[gate]`).** By default (`on_build = "report"`) a build-wired
`all` run prints every finding but exits 0 and appends `guardian: N check(s)
would block commit (…) — run guardian-check commit to gate`, so a dev build
never refuses to produce a binary; `on_build = "block"` (or `all --gate`)
restores the hard-block. `commit`/`nightly`/`accept` always block. `commit` runs
`[gate] test_command` (default `zig build test`, must pass) before committing,
then auto-installs the blocking pre-commit hook unless `install_hook = false`.
`guardian-check install-hook [dir]` writes `.git/hooks/pre-commit` (guardian
marker; resolves `$GUARDIAN_CHECK` → `./zig-out/bin/guardian-check` →
`guardian-check` on PATH; never clobbers a foreign hook) so a raw `git commit`
still hits the gate.

**Verdict-first, scope-aware output (`run-all:`).** *Every* exit path ends in
exactly one `run-all:` line, on the always-visible channel — so `grep run-all`
never comes up empty and can never be confused with "the pattern was wrong":

```
run-all: 70 check(s) passed                                  # green
run-all: 70 checks — 0 blocking, N report-only               # green, demoted findings
run-all: 2/70 failed (type-size, …) — 3 report-only          # blocking
run-all: cached — 0 blocking (inputs unchanged since last green run)
```

A diff-scoped run appends ` — diff-scoped vs <base>, N file(s) in scope`. The
failure line names the failing checks and echoes each one's first finding
(file:line, item, metric, cap) beneath it, with a `(+N more)` tail when that
check found more than one thing; a policy-demoted check prints `REPORT` instead
of `FAILED`. Detail is replayed **blocking first, advisory second**, so a reader
reaches what fails the build without scrolling through report-only output (the
run already captures every check's output for deterministic replay, so ordering
it costs nothing). On a **diff-scoped** run a non-blocking check whose findings
*all* fall outside the changed files collapses to one counted line —
`repeated-string-literal: 44 finding(s), none in scope — report-only (--verbose
for detail)` — with the full detail still in `.guardian/cache/last-run.jsonl`.
`all --summary` prints the verdict plus blocking detail only (every advisory
check collapsed to its count, passing checks silent); `all --verbose` restores
everything and overrides `--summary`. The green stamp records the guardian
binary's identity, so a blocking snapshot/ratchet failure whose binary differs
from the last green run prints a hint that names **which side is newer** — a
newer running binary means the recorded green is stale (re-run the gate), a
newer stamp means this binary predates the gated tree (rebuild first). That is
the stale-binary false-positive trap.

Two features diff the working tree against a git ref (`--against` flag,
`GUARDIAN_AGAINST` env var, or `[change_classification] against`; default
HEAD): the `change-classification` check fails behavioral src changes that
ship with no test or spec change (skips outside a git repo), and the
`mutate` command (explicit step, never part of `all`) mutation-tests the
suite — the fast tier mutates only changed lines, `--full` ratchets a
whole-tree kill score in `.guardian/mutation.txt` and both gate on
`[mutation] min_score_pct` (default 80). Child builds during mutation run
with `GUARDIAN_MUTATION_RUN=1`, which makes every guardian command no-op;
`commit`'s `zig build test` child sets `GUARDIAN_SKIP_CHECKS=1` for the same
no-op (the tree was already gated) while the tests still compile and run.
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
post-write tree), and only clean Git worktrees may skip. Git HEAD,
`build.zig.zon`, declared external inputs, and project-local `@embedFile` assets
participate in the digest. Thus a run that rewrites `.guardian/` — an auto-pruned baseline,
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
text baselines self-migrate to v2 on first build. Every *other* check uses
**identity baselines (v3)**: a violation is keyed by
`<check>|<file>|<discriminator>` derived from content — `Violation.identity`
(what the check flagged), else `ratchet_key`, else the message with standalone
digit runs collapsed to `#` — never by its rendered text, so rewording a
diagnostic no longer re-keys consumer baselines. Line numbers are in no tier.
v1 baselines self-migrate to v3 on first run, guarded so the re-key can neither
drop a violation nor adopt a new one (it is refused if any file gained
violations). Reword-prone checks should set `identity` (see
`src/violation_key.zig`). `[baseline] deny_growth =
["spec", ...]` freezes the named checks' baselines against ever growing — a
refresh that would raise their count (or add a key) fails instead.
File size, function length, and line length only emit ratchet records beyond
their generous hard limits; their recommended-limit warnings never need acceptance.

Every `all`/`nightly` run also drops machine-readable JSONL under the
git-ignored, digest-excluded `.guardian/cache/`: `last-run.jsonl` (structured
violations + summary) and `dora.jsonl` (per-run delivery metrics); `mutate`
adds `last-mutate.jsonl` (survivors) and `mutants.jsonl` (result cache).

A `last-run.jsonl` row is meant to be actionable on its own: `file`/`line` are
filled even for a check that only prints prose (its `<file>:<line>: ` prefix is
lifted into the record's own fields), and `fix_hint` carries the remedy — set
per finding by a check that emits records, scraped from a prose check's single
trailing `fix:` line, and, for a ratchet regression, naming the ceiling that
broke plus the `accept` command. Baseline mode forwards what it *reported* —
new violations, or keys past their ratchet ceiling — through `reporter.sink`
with the check's own file/line/metric, because the baseline layer otherwise
consumes those records under its nested capture (which is why a `file-size`
failure used to reach the log as fileless prose, or not at all). Frozen
baseline debt is never forwarded: a row means "this run reported it".

## Project Structure

```
src/
  check.zig            # CLI entry / dispatch
  cli/                 # Command registry + run_all + mutate/nightly/commit/install_hook/debt/explain commands
  cli/run_view.zig     # Presentation policy for a run: verdict line, blocking-first replay, scope-collapse
  checks/              # One file per check
  spec/                # SPEC.md parser, // spec: matcher, spec-init, unlinked-tag hints
  ast/                 # Zig AST helpers (pubFns, fnDeclInfos, import_graph)
  git.zig              # git diff parsing/shell-outs for diff-scoped features
  mutation/            # Mutant generator, in-place splice/test runner, result cache + survivor report
  walk.zig             # Recursive .zig file walker (visitor pattern)
  reporter.zig         # ok / fail printing + Violation type
  sink.zig             # last-run.jsonl machine-readable violation log
  dora.zig             # DORA delivery-metrics JSONL sink (non-gating)
  snapshot.zig         # Read/write/diff for snapshot-based checks
  snapshot_helper.zig  # Lifecycle helper used by all snapshot checks
  baseline.zig         # Baseline mode for legacy violations (v3 identity baselines)
  ratchet.zig          # Per-item ratchets (baseline v2) for threshold checks
  violation_key.zig    # Content-derived violation identity (baseline v3 keys)
  cache.zig            # Skip-when-unchanged input digest for `all`
  config.zig           # guardian.toml parser
  build_helper.zig     # addAllChecks for downstream consumers + prebuilt-binary selection
  source_digest.zig    # std-only digest of Guardian's own source; imported by build.zig AND the binary
  fakes/               # Deterministic test doubles (FakeClock/SeededRandom/FakeFs/FakeEnv) — the `guardian-fakes` module consumers import in tests
  testing/             # Golden-file test harness
```
