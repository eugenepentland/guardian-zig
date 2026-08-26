# Guardian Agent Instructions

## Local ROI records

Guardian records check observations automatically in the project's
git-ignored `.guardian/cache/check-roi.jsonl`. Human outcome labels go to the
separate `.guardian/cache/check-roi-labels.jsonl`; they are append-only, and
the latest valid label for an observation wins. Neither file is uploaded.

Once the outcome of a task is known, review and label only observations you can
classify from evidence. Run the helper from this checkout (or use its absolute
path when `<project>` is a different checkout):

```bash
scripts/guardian-roi pending <project>
scripts/guardian-roi label <project> <observation-id> <category> \
  [--minutes N] [--cycles N] [--reason TEXT] [--note TEXT]
scripts/guardian-roi summary <project> --markdown
scripts/guardian-roi summary <project> --json
```

Use these categories:

- `defect`: the finding exposed a correctness, security, reliability, or
  behavior bug that could otherwise have shipped.
- `useful-review`: it prompted a worthwhile design, test, documentation,
  safety, or maintainability improvement, but did not expose a defect.
- `intentional-change`: it accurately surfaced a deliberate, reviewed change
  that needed acknowledgement rather than correction.
- `false-positive`: the condition was factually wrong, the policy did not apply
  to otherwise-valid code, or the only resulting edit was appeasement with no
  meaningful benefit. Friction or runtime alone is not a false positive.

Leave uncertain observations pending instead of guessing. A snapshot accept or
a finding disappearing does not by itself mean `false-positive` or `defect`.
Record only incremental minutes and extra gate/validation cycles attributable
to that finding; omit an unknown cost rather than writing zero. Keep `reason`
short and use `note` only for useful local context.

The summary is observational evidence, not a causal proof or an instruction to
change policy. A cache hit is an invocation, not a check execution, and
per-check elapsed times must not be summed because checks can overlap in
parallel. The helper ignores malformed or unknown records and never edits
`guardian.toml`, accepts snapshots, or infers an outcome.

Logging is best-effort. A `check ROI write failed: WouldBlock` warning means a
record was deliberately dropped under sustained lock contention so telemetry
could not stall the gate. Recorded run duration also excludes the deferred
telemetry append itself.

Headline metrics use ordinary `all`/build runs from the latest Guardian digest.
Older implementations and compound-workflow passes remain available in the
JSON digest/scope/origin/phase cohorts; `accept` update and verify passes do not
count as retries. New labels snapshot their observation context so they remain
attributable after the bounded raw stream rotates.

ROI and DORA metrics use separate local files but share the v1 opt-out:

```toml
[dora]
enabled = false
```

Local logging is on by default. Raw records can contain local paths, commit
identifiers, and finding keys, so do not put secrets or sensitive data in
`--reason` or `--note`. Human summaries omit finding messages and label notes.

## Mandatory usage feedback

ROI labels do not replace `FEEDBACK.md`. After every task that exercised a
Guardian gate, append an entry at the bottom of its Log section and commit it in
this repository. Use `bug`, `friction`, `good`, and/or `wish` bullets; a smooth
run still gets a one-line `good` entry. Skip this only when Guardian was not
touched. Make each entry concrete and self-contained, and never edit, reorder,
or delete an older entry.

```markdown
## YYYY-MM-DD · <agent> · <project> — <task>
- **good:** <check or gate behavior and why it helped>
```

```bash
git -C ~/ai/canopy/guardian-zig add FEEDBACK.md
git -C ~/ai/canopy/guardian-zig commit -m "feedback: <project> — <one-liner>"
```
