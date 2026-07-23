# Guardian Interface & Performance Audit — 2026-07-23

*Prepared from a full audit session in eda (worktree `guardian-zig-audit-c1db28`,
tree at main `f6b2496`): live timing measurements, a complete CLI/config/env
inventory of this repo, the eda-side integration audit, and a clustering of all
116 FEEDBACK.md entries. The companion eda commit `b04fde4` (branch
`claude/guardian-zig-audit-c1db28`) implements the consumer-side half. This doc
is the guardian-side implementation brief.*

---

## 1. Measured reality (what is and isn't slow)

| Path | Measured | Note |
|---|---|---|
| `zig build` no-change (green tree) | **0.77 s** | skip-cache fixes (7ef992e + eda c658947) hold |
| `zig build` cold worktree | 53.8 s | compile-dominated; gate ≈ 1 s ReleaseSafe |
| `guardian-check debt .` | 1.5 s | |
| `zig build test-fast` | **2.3 s** | the fail-closed boundary tier |
| `zig build test` (full Debug suite) | **1923 s wall / 1926 s CPU** | 32 min, one core, serial, 25 output lines |
| stale standalone `guardian-check all .` | 35.7 s cold / 35.4 s "warm" | red verdict → cache never engages |

The suite was 60.7 s when eda's `[mutation]` sizing note was written
(2026-07-08) — **32× growth in two weeks**, entirely in the Debug test binary's
placement/routing solves. The 67 checks are ~1 s of any of it. "Guardian is
slow / gets stuck" is (a) the silent 32-min suite the commit flow hosted,
(b) shared `.zig-cache` contention between concurrent agent sessions, and
(c) the historical mutation hangs (since watchdogged).

**Reproduced live — the stale-binary trap:** the standalone
`zig-out/bin/guardian-check` (Debug, 2 builds old) reports **49 phantom
`pub-api-surface` violations** (all in eda's generated, gitignored
`src/serve/templates/*.zig`) on the exact tree the dep-built ReleaseSafe gate
passes green. The red verdict also disables the green cache, so every rerun
pays the full ~35 s scan. Two binaries, two verdicts, same tree, no warning.

## 2. Interface surface (inventory counts)

79 subcommands (67 checks + 9 meta + 3 registry) · 13 flags · 7 `GUARDIAN_*`
env vars · 32 guardian.toml tables / 85 keys · 64 KB README · 35.3 k LOC.
Of 116 logged FEEDBACK sessions: 63 clean `good:`, 34 `friction:`, 9 `wish:`,
2 `bug:`. 40 of eda's 66 baselines are empty. **The checks earn their keep;
the friction concentrates on six workflow seams:**

| Seam | Entries | Cost signature |
|---|---|---|
| baseline re-key/renumber churn on every run | ~7 | 39% of eda commits carry `.guardian` diffs; agents abandoned `commit` |
| accept/refresh mechanism confusion (3 mechanisms × 2 check classes) | ~5 | 2 × ~8-min wasted cycles each |
| opaque cap messages (function-size = *params* ×3, line-length ratchet, test rationale) | ~6 | 1 wasted gate cycle each |
| red gate blocks fresh binary | ~4 | dead diagnostic cycles |
| silent long runs read as hangs | ~4 | parked agent turns, heartbeat wished twice |
| stale-binary phantom reds | 2 + live repro | phantom violations, blocked deploys |

## 3. Consumer-side half (DONE — eda branch `claude/guardian-zig-audit-c1db28`, commit `b04fde4`)

- `[gate] test_command = "zig build test-fast"` — commit flow gates on the
  2.3 s boundary suite instead of the 32-min Debug suite (which stays the
  manual/nightly tier). Verified: gate green 1.65 s, zero `.guardian/` churn.
- `[policy] profile = "agent"` — the 8 pure-style checks demote to report-only
  (kills the line-length-ratchet and repeated-switch-on-enum friction classes).
  Verified live: `repeated-switch-on-enum: report-only finding (policy did not
  block)`.
- `[mutation]` stale-timing warning: at 32 min/full-suite run, each mutate-full
  smoke survivor costs ~32 min — the 2026-07-08 nightly budget math is void
  until eda fixes its suite (optimized test binary / solver tests out of the
  default tier).
- eda CLAUDE.md drift fix: 65-check → 67-check.

## 4. Guardian-side Tier 1 (this repo — the implementation brief)

### 4.1 Ordinary runs never write `.guardian/`  *(largest evidence base)*
Report-mode and plain check runs become read-only on metadata: no re-keys, no
line-number renumbering, no auto-created empty baselines, no snapshot rewrite +
restore dance. All writes move behind two verbs: `accept` (explicit) and
`commit` (gated). Add content-identical short-circuit: if a rewrite would only
change ordering/prefix/header, skip the write (the 2026-07-21 wish — this alone
ends the churn). Provide `guardian-check migrate` (or `accept --migrate`) as
the deliberate one-shot for format re-keys (v1→v3 class), so a format bump is
one reviewed commit instead of per-session churn.
Touch points: `src/check.zig:300` (`baseline.runWithBaseline`),
`src/baseline.zig` write paths, `src/snapshot_helper.zig` (write/restore),
`src/cli/run_all.zig` (restore-on-red), `src/cli/accept.zig`, `src/cli/commit.zig`.
Acceptance: a green *and* a red `all` run on a dirty-baseline-format tree leave
`git status` untouched; `accept`/`commit` produce the identical diff the old
path did.

### 4.2 One acceptance mechanism
`accept` already handles named baseline *and* snapshot drift — make it the only
documented path. `GUARDIAN_UPDATE_SNAPSHOT` becomes a thin alias that forwards
to (or prints) the equivalent `accept` invocation, including for baseline-class
checks (the 2026-07-20 eda entry burned two ~8-min cycles on exactly that
asymmetry). Every failing check's block prints its own exact remediation:
`guardian-check accept <check> .` — no class knowledge required.
Touch points: `src/snapshot_helper.zig:12,36,88,142`, `src/cli/run_all.zig:340`
(broad-token rejection — keep, but reject *before* any write), per-check
`fail_hint`s in `src/cli/registry.zig`.

### 4.3 Heartbeat + honest quiet mode
- `all --quiet`: name the failing check(s) in the summary line (not just
  "1/67 failed"), and emit a heartbeat ("check 33/67: pub-api-surface") when a
  check exceeds ~5 s.
- `commit`: phase markers (gate → tests → stage → commit) with a final timing
  split ("gate 1.1 s · tests 2.3 s"); stream or tick the child test build so a
  long suite is visibly alive (the parked-agent entries of 07-21/07-22).
- `mutate`: per-mutant progress line (N/M, elapsed, survivor count).
- Keep `last-run.jsonl` truthful after a restore (stale green summary observed
  2026-07-20).
Touch points: `src/cli/run_all.zig`, `src/cli/commit.zig`,
`src/mutation/runner.zig`, `src/reporter.zig`.

### 4.4 Binary-identity stamp
Every gated run records the running binary's digest in `.guardian/cache/`. Any
`guardian-check` invocation whose digest differs from the last-green stamp
prints one line — "this binary (built <date>) is not the one that last gated
this tree; rebuild via `zig build guardian -- <cmd>`" — *before* listing
violations, and `doctor` reports the mismatch. Kills phantom-red triage and the
permanent ~35 s rescan loop.
Touch points: `src/check.zig` (main dispatch), `src/cache.zig`,
`src/cli/doctor.zig`.

### 4.5 Commit-path hygiene (bug from the log)
`commit`'s staged path list must exclude untracked cache-pattern dirs
(`.zig-cache*`, `zig-out`, anything ignorable) — it swept `.zig-cache-c/` into
a commit twice on 2026-07-20. Touch point: `src/cli/commit.zig` path snapshot.

## 5. Tier 2 (surface shrink — after Tier 1)

- Collapse the CLI to ~8 verbs (`check [--only a,b]`, `accept`, `commit`,
  `explain`, `debt`, `doctor`, `mutate`, `version`); the 67 leaf commands stay
  as hidden aliases. README's per-check tables remain the reference; the
  command list shrinks to one screen.
- Auto-generate the README command/config reference from `src/cli/registry.zig`
  + `src/config_parser.zig` tables with a `--check` staleness gate (the exact
  docgen pattern eda already enforces for its language reference). Found drift
  it would have caught: README "complete key reference" missing
  `[stdout_flush]` and `[module_doc_header]`; eda CLAUDE.md said 65 checks;
  CLAUDE.md promises a `cache/last-run.jsonl` that a fresh checkout never has.
- Message-quality batch (each cost ≥1 logged cycle): name the measured
  dimension ("8 **params**, cap 6"), print ratchet ceiling + offending line
  ("…:633 is 253 chars; this file's max is 203"), inline one-line rationale for
  the test-shape rules, per-class remediation hint (4.2 covers this).

## 6. Explicit non-goals

Do **not** cut checks. 63/116 sessions were clean runs, 40/66 eda baselines are
empty, and the log's `good:` entries repeatedly credit specific checks with
catching real defects. The complexity that hurts is the five seams above, not
the check inventory.
