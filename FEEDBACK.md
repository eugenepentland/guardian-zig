# Guardian Usage Feedback Log

Append-only log of real-world Guardian experience, written by whichever agent
(Claude, Codex/ChatGPT, or a human) just finished work in a Guardian-gated
project. Eugene reviews this list periodically and turns entries into Guardian
changes; the entries themselves are the triage backlog.

## How to add an entry (agents: follow this exactly)

1. Write the entry **at the bottom of the Log section** — never edit, reorder,
   or delete existing entries (pruning happens at triage, by Eugene only).
2. Make it self-contained: another agent (or Eugene, weeks later) has none of
   your session context. Name the check, the project, what happened, and what
   it cost you (retries, wasted builds, confusion).
3. Commit the append in this repo immediately, so the tree stays clean:

   ```bash
   git -C ~/ai/canopy/guardian-zig add FEEDBACK.md
   git -C ~/ai/canopy/guardian-zig commit -m "feedback: <project> — <one-liner>"
   ```

4. A smooth session is signal too — a one-line `good:` entry is enough.
   Skip logging only when the session never touched a Guardian gate.

### Entry format

```markdown
## YYYY-MM-DD · <agent> · <project> — <task one-liner>
- **friction:** <what slowed you down — check name, what happened, cost>
- **bug:** <behavior that looks wrong, with repro if cheap>
- **good:** <what worked well / caught a real mistake>
- **wish:** <feature or change that would have helped>
```

Use only the bullet kinds you have something to say about. Multiple bullets of
the same kind are fine.

---

## Log

## 2026-07-18 · claude · eda + guardian-zig — RF bend wave, Guardian audit, four usability fixes
- **good:** gate caught 6 real issues in the Guardian fixes themselves before
  commit: pub-api-surface drift, a `@panic` (panic-budget), a stray
  `std.log.warn` (debug-print-ban), missing test coverage on new pub fns, a
  126-char line, and an unchecked `append` (oom-discipline). All were genuine.
- **friction:** `zig build test` never runs the install step, so
  `zig-out/bin/guardian-check` silently lags edits — I smoke-tested a stale
  binary and burned a 55s replay. Partially mitigated now (installs gated on
  green + stale-artifact caution line, cf740ec), but the test-vs-install split
  still surprises.
- **friction:** guardian-zig runs HARD mode (no `[baseline]`), so
  baseline-mode features (session accepts, volume wording) can't be exercised
  in-repo — verifying them needed a hand-built clone with `[baseline]
  enabled = true` appended. A fixture/e2e harness for baseline-mode behavior
  would shorten that loop.
- **wish:** baseline merge driver or a `guardian-check reconcile` for ratchet
  conflicts when two branches both auto-lower the same baseline file —
  today it's manual union-by-hand in a merge.
- **wish:** commit-flow guard against sweeping huge untracked files into a
  `guardian-check commit` path list (cap on file size / count with a prompt).
- **wish:** completeness-waiver profiles (declare a category as deliberately
  N/A for a project instead of carrying it as frozen debt forever).
- **wish:** a stable installed path for `guardian-check` (e.g. `zig build
  install-tool` to a fixed prefix) so isolated-cache workflows (`--cache-dir`
  outside the repo) don't each rebuild/lose track of the binary.
- **wish:** bare `GUARDIAN_UPDATE_SNAPSHOT=1` should require an explicit
  `=all` — `=1` ratifying every snapshot at once is an easy fat-finger next
  to the selective `=check-a,check-b` form.

## 2026-07-18 · codex · eda — KiCad layout sync
- **friction:** selecting the first `.zig-cache/**/guardian-check` found an
  older cached binary whose line-length semantics rewrote the baseline, then
  produced 36 false regressions during the commit gate. This cost one failed
  commit attempt and a manual baseline reconciliation; using the current
  fixed-path `guardian-zig/zig-out/bin/guardian-check` resolved it.
- **good:** the current `guardian-check commit` failed closed on the mismatched
  ratchets without staging or committing anything. After reconciliation, all
  67 checks passed and the feature could be committed and merged safely.

## 2026-07-18 · codex · eda — restore PCB Ctrl+Z after autosave
- **good:** the line-length gate caught one 170-character regression-test
  assertion before commit; splitting out the needle fixed it, and the next
  full gate passed all 67 checks and 1,197 tests.
