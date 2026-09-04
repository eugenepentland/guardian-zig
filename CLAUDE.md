# Guardian for Zig

Toolchain: Zig `0.17.0-dev.1683+5ceec001b` exactly, matching
`build.zig.zon`. Zig 0.17 optimize spellings are lowercase (`debug`, `safe`,
`fast`, and `small`), including `-Doptimize=safe` on the command line.

## Local ROI records

Guardian records check observations automatically in the project's
git-ignored `.guardian/cache/check-roi.jsonl`. Human outcome labels go to the
separate `.guardian/cache/check-roi-labels.jsonl`; they are append-only, and
the latest matching subject or observation label wins. Neither file is uploaded.

Once the outcome of a task is known, review and label only observations you can
classify from evidence. Run the helper from this checkout (or use its absolute
path when `<project>` is a different checkout):

```bash
scripts/guardian-roi pending <project>
scripts/guardian-roi label-subject <project> <subject-id> <category> \
  [--minutes N] [--cycles N] [--reason TEXT] [--note TEXT]
scripts/guardian-roi label <project> <observation-id> <category> \
  [--minutes N] [--cycles N] [--reason TEXT] [--note TEXT]
scripts/guardian-roi summary <project> --markdown
scripts/guardian-roi summary <project> --json
```

`pending` defaults to one row per stable subject in the latest Guardian
digest's direct `all`/build cohort. Label that subject normally: the label
applies to recurring commit-specific observations, including future ones from
the same check implementation. Use `pending --observations` and `label` only
for a true per-occurrence exception; the latest matching label wins. Use
`pending --all` only for retained older digests and workflow-only findings.

Categories are `defect` (a correctness, security, reliability, or behavior bug
that could have shipped), `useful-review` (a worthwhile design, test,
documentation, safety, or maintainability improvement without a defect),
`intentional-change` (an accurate report of a deliberate reviewed change), and
`false-positive` (the condition was factually wrong, inapplicable to otherwise-
valid code, or produced only appeasement work with no meaningful benefit).
Friction or runtime alone is not a false positive.

Leave uncertain subjects pending. A snapshot accept or a finding
disappearing does not prove an outcome. Record only incremental minutes and
extra gate/validation cycles caused by the finding; omit unknown cost instead
of recording zero. Usefulness, coverage, classifications, and human cost are
counted once per stable subject (Guardian digest + check + finding key), not
once per commit. The summary is observational evidence, not causal proof or
an instruction to change policy. Cache hits are invocations, not executions;
never sum per-check elapsed times because parallel checks overlap. The helper
ignores malformed or unknown records and never edits `guardian.toml`, accepts
snapshots, or infers outcomes.

Logging is best-effort. A `check ROI write failed: WouldBlock` warning means a
record was deliberately dropped under sustained lock contention so telemetry
could not stall the gate. Recorded run duration also excludes the deferred
telemetry append itself.

Headline metrics use ordinary `all`/build runs from the latest Guardian digest.
Older implementations and compound-workflow passes remain available in the
JSON digest/scope/origin/phase cohorts; `accept` update and verify passes do not
count as retries. New labels snapshot their observation context so they remain
attributable after the bounded raw stream rotates.

ROI and DORA use separate local files but share the v1 opt-out:

```toml
[dora]
enabled = false
```

Local logging is on by default and has no upload. Raw records can contain local
paths, commits, and finding keys, so keep `--reason` and `--note` free of
secrets or sensitive data. Human summaries omit finding messages and notes.

## Usage Feedback Log

ROI labels do not replace `FEEDBACK.md`. After every task that exercised a
Guardian gate, append an entry at the bottom of its Log section and commit it in
this repository. Use `bug`, `friction`, `good`, and/or `wish` bullets; a smooth
run still gets a one-line `good` entry. Skip only when Guardian was not touched.
Make entries concrete and self-contained. Never edit, reorder, or delete an
older entry; Eugene prunes entries during triage.

```markdown
## YYYY-MM-DD · <agent> · <project> — <task>
- **good:** <check or gate behavior and why it helped>
```

```bash
git -C ~/ai/canopy/guardian-zig add FEEDBACK.md
git -C ~/ai/canopy/guardian-zig commit -m "feedback: <project> — <one-liner>"
```

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

**Every run ends on a verdict line.** The runner's last output, on every exit
path and in both modes, is `guardian/test: PASS — N passed` (`, K skipped` when
nonzero) or `guardian/test: FAIL — F failed of N` (plus the leak count, the
logged-error count, or `over an opt-in time cap`), and `FAIL — <reason>` when a
run ends before its suite finished (the zero-match guard, an aborted runner).
The line and the exit status are read off one `timing.Verdict`, so they cannot
disagree — with one documented seam: under `zig build test` a failing test still
exits the runner 0, because Zig's Run step discards every per-test result when a
test runner exits nonzero ("the test runner itself broke"). The verdict exists
because a piped `zig build test` ends on Zig's own `failed command: …` banner —
recorded before any verdict exists and erased only on the success path, so a
GREEN piped run reads as failed. Guardian cannot unprint it; it outranks it.

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

**The installed `guardian-check` is `safe` by default** — a plain
`zig build` (no `-Doptimize`) builds `zig-out/bin/guardian-check` optimized,
because consumer projects (eda) run it as their commit gate and a `debug` build
turns that ~1.1 s whole-tree gate into ~42 s, silently, for every agent commit
until someone notices (measured 2026-07-26). An explicit `-Doptimize=debug`
still produces a debug binary for debugger work; the test suite keeps the
plain debug default so its compile stays fast. If commits in a consumer repo
start reporting a gate of tens of seconds, check this binary's size first
(`safe` ≈ 10 MB, `debug` ≈ 55 MB).

**Consumers reuse that binary instead of recompiling it.** `addAllChecks`
prefers `<guardian dep root>/zig-out/bin/guardian-check` over a from-source
compile, because a consumer with a private per-worktree Zig cache otherwise pays
a full cold `safe` compile of an unchanged tool before any of its own code
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
guardian-check commit --intent "..." .  # block-gate, run tests, opt-in mutation tier, auto-commit + install hook on green
guardian-check install-hook .        # write .git/hooks/pre-commit that runs the blocking gate
guardian-check install-merge-driver . # local git attributes + driver so .guardian/ conflicts auto-resolve
guardian-check merge-file %O %A %B --path %P  # the driver itself (base, ours, theirs; result lands in ours)
guardian-check all . --only spec,file-size  # run only these checks (no green cache stamp)
guardian-check all . --skip line-length     # run every check except these
guardian-check all . --summary       # verdict line + blocking detail only (advisory collapsed to counts)
guardian-check all . --verbose       # replay every check in full (overrides --summary and scope-collapse)
guardian-check all . --full          # whole tree: opt out of the default diff scoping
guardian-check all . --against origin/main  # diff-scope against an explicit base ref
guardian-check <check> . --list      # one check's rows: NEW / LIVE / RESOLVED vs its baseline (read-only)
guardian-check <check> . --dry-run   # one check's current findings, no baseline filtering, writes NOTHING
guardian-check size src/foo.zig .    # one file's CURRENT measurements vs caps + frozen ratchet ceilings
guardian-check debt .                # baseline/snapshot debt totals + deltas (non-gating); --json goes to stdout
guardian-check debt . --live         # + each ratcheted key vs its ceiling AND what is nearest a blocking limit
guardian-check debt . --current      # the same switch under its original name (re-parses the tree)
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
const fmt_check = b.addFmt(.{ .paths = &.{b.path("src")}, .check = true });
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

[mutation]
on_commit = false            # opt the FAST mutation tier into `commit` (default off)
min_free_gib = 5             # free-disk floor the commit tier needs before it starts

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

72 checks gate the build (most hard-block; completeness/test-coverage/
oom-discipline/fuzz-presence are opt-in and default off). Formatting is one of them:
the `formatting` check runs FIRST in every `all` pass and prints immediately
(cheapest gate, one-command fix), so a consumer no longer needs its own
`zig fmt --check` build step. Three more registry entries are
non-gating steps, never part of `all`: the `spec-init` generator, the `mutate`
command and the `debt` report (75 registry
entries total; `all`/`nightly`/`commit`/`explain`/`version`
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
debt`) reports every baseline/snapshot total with the delta vs the committed
`.guardian/` state, **grouped by what the number measures** — violation debt
(lower is better), inventories that are not debt at all (the pub-api surface),
and scores (higher is better) — plus, on request, an informational
assert-density table (assert() calls per KLOC per top-level src module,
ascending). A ratchet's worst offender is labelled `worst (baselined)` because
it is the stored ceiling, not a live measurement; `--live` measures the tree and
adds the ratchet-ceiling table and the headroom list (items within 10% of the
limit that would block them). `--json` writes to **stdout**, with `kind`,
`direction` and `unit` per row and a structured `worst {metric, file, item}`.

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
run-all: 72 check(s) passed                                  # green
run-all: 72 checks — 0 blocking, N report-only               # green, demoted findings
run-all: 2/76 failed (type-size, …) — 3 report-only          # blocking
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

**The fast mutation tier can gate `commit`, opt-in** (`[mutation] on_commit`,
default false). When on, `commit` runs it after `[gate] test_command` passes and
before creating the commit, and a failing verdict refuses the commit —
`min_score_pct` / `min_mutants` unchanged. It never splices the working tree:
`git stash create` records the tracked changes as a dangling commit without
touching the tree, the index or the stash reflog, `git worktree add --detach
.guardian/cache/commit-mutate` checks that out, the untracked non-ignored files
are copied in (a candidate tree missing a brand-new module does not compile, and
a tree that does not compile scores every mutant *unviable* — a vacuous 100%
green), every splice lands there, and the worktree is removed on every exit path
with a leftover from a killed run cleared before the next tier starts. It diffs
the same base ref `commit` already resolves for change-classification, and
copies `last-mutate.jsonl` back out before deleting the scratch tree (the
per-mutant result cache goes with it). It refuses to start below `[mutation]
min_free_gib` (default 5) and fails closed there; a filesystem it cannot measure
is not a refusal. Off by default because the tier rebuilds and re-tests the
project once per mutant — see the eda measurement in FEEDBACK.md.

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
The eight threshold checks (function-length, nesting-depth, cognitive-complexity,
function-size, type-size, file-size, bool-ops-per-condition, line-length) use
**per-item ratchets** (baseline v2):
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
["spec", ...]` freezes the named checks' baselines against ever growing, and
what counts as growth follows the flavor: a **per-item ratchet** refuses a
refresh that raises a value *or adds a key*, while an **identity baseline**
refuses one that leaves the file larger than it found it — a row is one
violation, so the count is the debt and a swap is not growth. The one exception
is an addition a check marked `growth_exempt` after PROVING it is pre-existing
debt its change only made visible (today only `twin-drift`'s surfaced pairs);
those are discounted from the comparison.
File size, function length, and line length only emit ratchet records beyond
their generous hard limits; their recommended-limit warnings never need acceptance.

**twin-drift's scoring is frozen beside its baseline.** Its tf-idf proposal is
corpus-wide, so a live `idf` moves EVERY score whenever a body is added or
removed anywhere — measured on eda, 74% of untouched surviving pairs changed
score across a merge, and one crossed the floor into a blocking row in two files
nothing had touched (`docs/twin-drift-scoring-study-2026-09-02.md`).
`.guardian/twin-drift-df.txt` (v4) therefore pins the document count and every
shingle's frequency as of the last accept, and BOTH the weight and the
`2 <= df <= max_df` proposal gate read it — the gate too, because a boilerplate
3-gram drifting across `max_df` adds real mass to an untouched pair's cosine.
Only the posting COUNT stays live (it sizes each posting list). A shingle the
table has never seen falls back to its live frequency, so code added since the
freeze is paired normally, and a project with NO table behaves exactly as it did
before the file existed. Only an accept naming twin-drift writes it
(`accept twin-drift .`, `GUARDIAN_UPDATE_SNAPSHOT=twin-drift`/`=all`,
`-Dguardian-checks=twin-drift`); no ordinary run, `--gate`, `--dry-run` or
`--list` ever creates one, though `--dry-run`/`--list` do READ one. It is not a
baseline — `deny_growth` and hysteresis do not apply — and `merge-file` keeps
OURS whole on a conflict and marks the file for regeneration; a table carrying
that marker is still used, but warns once per run until an accept re-measures
it (the marker is a comment, so nothing else would see it). An unreadable
table warns once and scores live; `twin-drift . --list` heads its output with
the table's coverage and its frozen N against the live one. The whole vocabulary
is stored (eda: 264,931 rows / 2.5 MB), because a df>=2-only table re-admitted
the exact pair the freeze removes.

**Those three hard caps are also under hysteresis — trip → no accept → shrink
to recover** (`[hysteresis]`, `src/hysteresis.zig`; `enabled` default true,
`recover_pct` default 20 valid 1..90, `checks` default
`["file-size", "function-length"]` — only the three two-tier names are legal
and an unknown one hard-fails config parsing). Crossing a hard cap **cannot be
accepted**: `accept`/`GUARDIAN_UPDATE_SNAPSHOT` refuse to create the entry or
raise an existing ceiling (the deny_growth refusal path), and the failure drops
every accept command and names the recover line instead. The entry then
**remembers the trip**: below the cap it is reconciled against the check's
*advisory* records (which carry `ratchet_key` + `metric` — the same seam
`preserveAdvisoryRatchets` uses, so nothing re-measures the tree), so a shrink
auto-lowers it, growth **fails** ("growth blocks until it reaches <=8000;
shrinking commits land freely"), and it prunes only at the recover line —
printing a `recovered:` line, beside relocation's `moved:` ones. Unratcheted
subjects in the advisory band stay free; first-record adoption still
grandfathers over-cap subjects (born tripped); relocation transfers still carry
a tripped entry to its new key; a diff-scoped run holds an entry it did not see
rather than clearing it; and a session accept note never covers a trip.
`debt --live` marks each tripped key `TRIPPED — recover at <=N (M to go)`.
Because the trip is what remains, the near-cap alert of a bound check ends
`crossing cannot be accepted` instead of `crossing blocks the gate`.

**The file-size metric counts code, and the last warning before a crossing is
un-collapsible.** A *code line* is a **non-blank, non-comment line outside
`test { ... }` blocks** — one function (`file_size.codeLines`) measures it for
the gate, `guardian-check size`, and `debt`, so they cannot drift. Comments and
blanks used to count, which made deleting doc comments the cheapest way to buy
headroom at a frozen ceiling: the gate rewarded removing explanation. It no
longer does, and no ratchet migration is needed — values that drop under the new
metric classify as `improved` and auto-lower on the next write-allowed run. On
top of that, a file (or function) at **≥95% of its hard cap** emits one
`NEAR HARD CAP` line flagged `alert` on the Violation: `run_view.showsAlerts`
replays it even when the check's own output is collapsed to
`N finding(s) — report-only`, so `--summary`, `--quiet` and diff-scope collapsing
can no longer bury the one file that is a line away from blocking. An alert is a
warning, never a violation: no baseline, ratchet or snapshot records it, and it
carries no `ratchet_key` of its own.

Every `all`/`nightly` run also drops machine-readable JSONL under the
git-ignored, digest-excluded `.guardian/cache/`: `last-run.jsonl` (structured
violations + summary), `dora.jsonl` (full-run delivery metrics), and
`check-roi.jsonl` (every invocation's per-check facts); `guardian-roi label`
appends human outcomes to `check-roi-labels.jsonl`, while `mutate` adds
`last-mutate.jsonl` (survivors) and `mutants.jsonl` (result cache).

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
  check_roi.zig        # local per-check cost/usefulness facts + stable observation IDs
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
