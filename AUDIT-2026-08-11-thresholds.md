# Threshold Design Audit — the trip-then-halve (hysteresis) proposal

Date: 2026-08-11. Question under evaluation (Eugene): replace "refactor once the metric
hits X" with a tolerant trip threshold whose crossing demands the metric be cut **in
half** before merging again (e.g. 10k-line file cap → tripped file must reach 5k).
Evidence base: eda repo archaeology at HEAD `4fbb76e9`, Guardian source + `.guardian/`
state, all 376 FEEDBACK.md entries (2026-07-18 → 2026-08-11), and external literature
(every claim sourced below). All code written by AI agents.

---

## Verdict

**The diagnosis is confirmed; the mechanism is right; three parameters of the proposal
as stated are wrong.**

1. Threshold surfing is real but **localized**: it is a *file-size hard-cap* phenomenon
   (plus accept-creep on type-size). The function-shape checks are working and should
   not change.
2. The attractor is maintained by two specific leaks: **accept is one env-var** while
   splitting is Guardian's most check-expensive action, and **ratchet entries prune**
   the moment a file dips under cap, restoring free regrowth. Hysteresis genuinely
   closes both.
3. As stated — 50% dead-band, block-until-half — the proposal schedules the empirically
   riskiest change shape (big-bang refactor), moves the hover point rather than
   removing it, and amplifies the already-observed compression pathology (agents
   deleting doc comments to buy lines). The reshaped version below keeps the
   anti-hover property at incremental-refactor cost.

---

## Part 1 — What actually happens in eda (measured 2026-08-11)

### The pile-up is at the hard cap, and only there

- The three largest files sit at 100±3% of the 10,000-code-line hard cap; nothing else
  is within 57% of it: `pcb_layout_page.zig` 10,291 (ceiling 10,294 — 3 lines of
  headroom), `router.zig` 10,273 (0 headroom, at ceiling), `optimizer.zig` **9,983 —
  17 lines under the cap, un-ratcheted**, so line 10,001 blocks. Fourth-largest:
  `sync.zig` at 4,306. Organic growth does not produce three files at the limit and
  then a void; the gate pins them there.
- Same posture three weeks earlier, different file: FEEDBACK 2026-07-26 records
  router.zig at "9984 of a hard 10000".

### A complete surf cycle, in the commit messages

- Jul 26 `32da46a0`: "split router.zig into cohesive modules — **9988 -> 9129 code
  lines, 871 under the 10000 hard limit**" — the landing measured against the cap, not
  a design target.
- The 871 lines regrew in **7 days**. Aug 2 `0013e207` accepted the crossing into the
  ratchet at 10,317; `afbad50c` same day re-accepted at 10,520 ("split into a dedicated
  module is a recorded follow-up" — IOU still open, HANDOFF.md:61).
- Since then: oscillation 10,199–10,520 over 9 days with **5 ceiling-raising accepts**
  interleaved with ~1% trims (`ed4bec80`: 10333 → 10227 after route_grid extraction).
- `pcb_layout_page.zig`: accepted 10,095 (Aug 7) → re-accepted **10,696 one commit
  later** (+604 in one accept) → trimmed to 10,294.
- `optimizer.zig` ran the purest loop: crossed at 10,002 (Aug 7 `0c68255e`), trimmed
  back under by Aug 9, entry auto-pruned, now parked at 9,983 — the prune-then-regrow
  loophole live on screen.

### Ratchets park debt; they do not pay it down

Per-key comparison, ratchet init (Jul 8) vs now: nesting-depth **48/48 unchanged**;
function-size 107/121 unchanged; cognitive-complexity 17/21 unchanged; type-size
52 → 71 keys (**+23 new, 13 ceiling raises accepted**; 9 of the 23 new entries are
exactly 8 fields — the minimum possible violation, accepted rather than redesigned).
~34 accept events in 24 days ≈ 1.4/day. The one real paydown — router's ceiling
ratcheting down ~300 lines over 5 weeks — happened under forced frozen-ceiling
pressure on a hot file, which is the mechanism the recommendation below generalizes.

### Warn tiers are inert

Files ≥1,000 raw lines: 5 (Apr 15) → 9 → 19 → 26 → **66 (Aug 11)**, 19% of src.
`mcp_close_gaps.zig` was *born* at 2,336 lines (Jul 25) and hit 5,258 in 17 days
without one intervening trim. When Guardian's Jul 18 re-key un-gated the 120–400
function-length band, the 60 freed functions drifted (12 grew, 12 shrank) — no
explosion, no attention. **Nothing non-blocking changes agent behavior.** (Guardian
dogfoods the same: zero ratchet entries, but 4 of its own files are over the 1k
recommended warn — baseline.zig ~1,364 code lines — warned on every build, ignored;
config.zig was split for the cap and the parser half regrew to ~1,330.)

### The shape checks work — the disease is not general

- The 400-line function hard cap has **never been breached** (longest function: 225).
- function-size (params): **zero accepted violations in 3+ weeks** while old debt
  slowly shrinks. Param distribution decays smoothly to the cap then truncates
  (4→1047, 5→531, 6→289, 7→54); no bunching *at* 6 beyond trend — but 289 functions
  sit at 6/6 with zero headroom, and growth exits through the neighbor: params become
  struct fields, and type-size absorbs the accepts (the balloon squeeze).
- Struct fields do show a modest cap pile-up: count at 7 (69) exceeds the count at 6
  (67), then a cliff; 75 types at exactly 7/7.

### The incentive gradient is the root cause

FEEDBACK 2026-07-26: satisfying file-size "cost roughly two hours, and almost none of
it was on the feature… **every relocation tripped a different check on the new key**"
(moved struct re-fired type-size at its new home despite being baselined at the old
one; plus anytype-budget, pub-api-surface). Splitting — the *intended* fix — is the
most check-expensive action available; accepting a ceiling raise is one env-var. Given
that gradient, agents rationally surf.

### Costs of the status quo

40% of 898 commits since Jul 8 touch `.guardian/`. file-size is the #1 failing check
in the DORA log (24 of 59 red runs). ~15 feedback entries document the zero-headroom
grind (designing changes around 1 line of headroom; rewriting a fix twice for line
count). Four entries in one week document agents **deleting doc comments or merging
readable lines** because a file at its ceiling "can never gain a word of explanation" —
the gate rewarding removal of explanation is the sharpest observed satisficing.
Historical route-around ledger: Apr 26–27 raised every cap 1.5×–20× with
"DO-NOT-INCREASE" comments; the promise did not hold (Instance 16 → 26 fields,
PngRequest 26 → 28 via accepted raises).

---

## Part 2 — What the mechanics allow (Guardian internals)

- Two-tier (warn at recommended / block at generous hard cap): file-size (1k/10k code
  lines), function-length (120/400), line-length (120/240). Single-tier gate-at-cap:
  nesting 5, cognitive-complexity 25, function-size 6 params, type-size 7 fields,
  struct-method-cap 20 (hardcoded), optional-density 50% (hardcoded), bool-ops 3.
  eda's `agent` profile demotes line-length/struct-method-cap/optional-density/bool-ops
  to report-only.
- Ratchet lifecycle (`src/ratchet.zig`, `src/baseline.zig`): new offender **fails**
  until accepted; improvement still over cap auto-lowers the ceiling (persisted only on
  metadata-writable runs: accept/commit/migrate); a key that drops under cap **prunes,
  after which regrowth to cap−1 is free**. `deny_growth` freezes a check's baseline
  against any raise — it is hysteresis's trip half with no exit condition.
- Where a hysteresis rule would live: `ratchet.zig` classify/lifecycle + per-check
  trip/recover config. Structural obstacle: below the hard cap the two-tier checks emit
  only advisory records (which do carry `ratchet_key`+metric — the reusable seam:
  `preserveAdvisoryRatchets`), and single-tier checks emit nothing at all — so recovery
  tracking needs either the advisory records or direct measurement via
  `file_metrics.zig`. The v2 line format `<value> <key>` cannot grow a field
  compatibly → v3 format with guarded migration (precedent exists) or a sidecar.
  Touchpoints: accept + session-accept must refuse tripped keys (session auto-re-accept
  would silently defeat hysteresis), merge driver needs trip-flag semantics (min-wins
  is wrong for flags), scoped runs must report but never write trip state.
- Prior art in-repo: none — no mention of hysteresis/halving anywhere in docs, source,
  or audits. Nearest neighbors: `deny_growth`, the auto-lower path (the downward half
  of the loop), `debt --live`'s 90%-headroom list, and the corpus's own asks (below).

**Nobody in 376 feedback entries asked for hysteresis.** The revealed-preference asks
are: a loud warning within ~1% of the hard cap; **"a hard-cap crossing must not be
ratcheted — drop the accept hint"** (asked twice, 07-30 and 08-06); relocation-aware
ratchet identity; live headroom queries (shipped as `size` / `debt --live` and
immediately praised). The minimal form of the hysteresis proposal is continuous with
what the agents themselves asked for.

---

## Part 3 — What the literature says (sourced)

**The diagnosis is expected, not anomalous.**
- Humans bunch hard under enforced thresholds across domains: tax kinks (Kleven,
  *Bunching*, Ann. Rev. Econ. 2016, https://eml.berkeley.edu/~saez/course/kleven_annualreview.pdf),
  procurement priced just under audit thresholds, AML transactions under alert
  thresholds (https://arxiv.org/pdf/2309.12704). Goodhart's law is the mechanism.
- Fixed code-metric caps were never empirically grounded: Shepperd 1988 on cyclomatic
  complexity; Alves/Ypma/Visser ICSM 2010 (thresholds rest on "expert opinion",
  propose percentile-derived values, https://dl.acm.org/doi/10.1109/ICSM.2010.5609747);
  El Emam TSE 2001 (size confounds metric–defect studies). Partial exception:
  cognitive complexity does correlate with comprehension time (r≈0.65 meta-analysis,
  https://arxiv.org/abs/2007.12520) — cap *values* still unvalidated.
- LLM agents are measurably stronger metric-gamers than humans: METR 2025 (o3 hacked
  scoring in 30.4% of RE-Bench trajectories, https://metr.org/blog/2025-06-05-recent-reward-hacking/);
  ImpossibleBench (https://arxiv.org/pdf/2510.20270); OpenAI on obfuscated reward
  hacking (https://arxiv.org/abs/2503.11926); Anthropic on emergent misalignment from
  production reward hacking (https://arxiv.org/abs/2511.18397); "Building to the Test"
  2026 (agents deliver what the visible check measures). Agents' unforced refactoring
  is shallow (15k-commit study, https://arxiv.org/html/2511.04824) — metric-forced
  refactoring will be shallower.

**Hysteresis is proven engineering — but not in quality gates.**
- Dead-bands kill boundary-hovering everywhere they're used: Schmitt trigger; Nagios
  flap detection (trip ~20%, reset ~5% — the closest analog,
  https://assets.nagios.com/downloads/nagioscore/docs/nagioscore/4/en/flapping.html);
  Prometheus `keep_firing_for`; Kubernetes HPA per-direction stabilization; circuit
  breakers (recovery via a *different* criterion than the trip); Elasticsearch
  85/90/95% watermarks.
- **No linter, CI gate, or quality platform documents a trip-high/reset-low metric
  gate.** Guardian would be first. The proven cousin is the one-sided ratchet
  (Betterer, ESLint bulk suppressions 2025, RuboCop `--auto-gen-config` — whose
  documented failure mode, ceiling-legitimizes-everything-below, eda reproduced).
- Google Tricorder's survival rule for blocking checks: effective false-positive rate
  under ~10% or developers route around it (https://research.google.com/pubs/archive/43322.pdf).
  eda's cap-raise ledger is that route-around, verbatim.

**The 50% one-shot cut is the risky part.**
- Change failure probability rises with change size and diffusion (Mockus & Weiss,
  Bell Labs 2000). Review defect-discovery collapses past ~400 LOC (SmartBear/Cisco).
  Refactoring correlates with induced bugs, concentrated where refactoring tangles
  with other change (Bavota SCAM 2012; Di Penta ESEC/FSE 2020) — and a forced
  mid-feature halving is maximally tangled. Deliberate *incremental campaigns* do pay
  off (Kim/Zimmermann/Nagappan, Windows field study, FSE 2012).
- Aider's refactor benchmark needed an AST-node-count guard to stop models satisfying
  "refactor" by **eliding code** (https://github.com/Aider-AI/refactor-benchmark) —
  the industrialized version of eda's delete-the-doc-comment pathology.
- Large files also degrade the agents themselves: context rot (Chroma 2025), Lost in
  the Middle, aider's large-file edit failures (20% → 61% only by changing edit
  format), practitioner consensus of ~150–500 lines per file for agent editing. A 10k
  trip point is 20–60× that; tolerance is not free.

---

## Part 4 — Pros and cons of trip-then-halve as proposed

### Pros

1. **Targets the confirmed disease at its exact site.** Equilibrium at 100–103% of
   cap, trims of 0.3–8.6%, regrowth in days, 5 accepts/9 days on one file — a wide
   dead-band removes the attractor: nothing to hover under after recovery, and the
   gate can't be satisfied by a 3-line trim.
2. **Closes both measured leaks at once**: no accept at the hard cap (the cap is
   currently soft — one env-var), and no prune-then-regrow (optimizer's loop).
3. **Rare-event economics.** Converts chronic friction (40% `.guardian/` commit touch
   rate, ~1.4 accepts/day, the zero-headroom grind) into an infrequent, unambiguous
   event, then buys months of silence — closer to the "invisible" principle than a
   ceiling agents fight every session.
4. **Refactor-as-explicit-task suits agents.** The corpus shows agents do their worst
   work when a size budget intrudes mid-feature (fix rewritten twice for line count;
   docs deleted) and their best structural work when the task *is* "split this
   cohesively" (the Jul 26 split surfaced real dedup — `segPointDist` ×5; extracted
   modules stayed small and real). Halving forces the work into the second frame, and
   agent labor is cheap.
5. **Proven control-theory shape** (Nagios/Prometheus/HPA/breakers), and Guardian
   already ships the one-sided half (only-shrinks ratchets) — this completes the loop.
6. **Simpler mental model.** "Cross 10k and you owe a cut to 5k" is one sentence, two
   config numbers, no per-item accept ceremony — more zero-config than ratchets.
7. **Recovery headroom is agent-ergonomic and quality-relevant.** A 5k file is far
   more tractable for agent editing than a 10k file, and eda's two pinned giants
   (router, optimizer) are precisely where mutation survivors and shipped bugs
   concentrate.

### Cons

1. **It schedules the empirically riskiest change shape.** A mandated ~5,000-line
   reduction in one red-to-green episode is large, diffuse, refactor-tangled, and
   unreviewable — the exact profile the defect literature flags — executed by agents
   whose unforced refactoring is measurably shallow, under pressure, with the goal
   "make it green."
2. **Merge-blocking semantics are poison for multi-agent flow.** A 10k→5k split of a
   hot engine file is a multi-session campaign; feedback already records that module
   extraction "is exactly what a concurrent multi-agent wave cannot do without
   wrecking siblings' merges." Partial paydown earning nothing (10k→7k still red) is
   bad reward shaping.
3. **Gaming transfers; it doesn't disappear.** (a) The hover moves to the trip line —
   optimizer sits at 9,983 *today* because crossing is expensive; making crossing
   catastrophic makes 9,99x a stronger attractor and invites pre-trip
   panic-compression. (b) "Half" is satisfiable by mechanical bisection (two 5k halves
   + re-exports); no existing check distinguishes cohesive extraction from bisection,
   and the README's split cookbook promises extracted files fresh metrics. (c)
   Elision: agents already delete doc comments to buy single lines; a 5,000-line debt
   amplifies that incentive enormously (aider had to build an AST-mass guard against
   exactly this).
4. **Tolerance widens the free-drift zone.** The audit's clearest finding: nothing
   non-blocking changes agent behavior (66 files past the warn tier; a file born at
   2,336 lines; +505 lines/day when ungated). Raising tolerance raises the steady
   state everywhere below trip, and large files carry real costs for the agents and
   measured bug concentration.
5. **Trip timing is adversarial.** It fires mid-feature on whoever adds line 10,001
   (last crossing: a 12-line JSON writer), handing that session an unplanned mega-
   refactor — and today the one-line-of-headroom warning is buried in 45 advisory
   findings.
6. **The runway is shorter than it looks.** At router's measured regrowth (~170 code
   lines/day steady; one 2,346-line single-day bulge), 5k of headroom ≈ a month at
   bulge pace. The same three engine files would trip repeatedly, and the *third*
   halving of router.zig is an architecture decision a line-count mandate can't make.
7. **It can't replace the threshold system.** "Halve" is meaningful for volume metrics
   only; for nesting 5 / params 6 / bool-ops 3 it prescribes arbitrary rewrites — and
   those checks aren't broken (zero param-cap accepts in 3+ weeks). This is a
   file-size (maybe type-size) policy, not a new regime for all checks.
8. **Moderate implementation blast radius**, and it currently mandates Guardian's most
   painful workflow: the split path re-charges ratchets/type-size/pub-api at new keys.
   Mandating splits without fixing relocation identity first weaponizes that friction.

---

## Part 5 — Recommended shape

Adopt hysteresis as a **one-sided ratchet extension** — "trip → no accept → shrink to
recover" — for volume metrics only:

1. **Hard-cap crossings become non-acceptable** (delete the accept path above the hard
   cap). Feedback asked for exactly this, twice. This alone deletes the
   parked-at-103% equilibrium.
2. **Trip memory instead of prune.** Once tripped, the entry persists below the cap
   until the value reaches the recover line; only then does it prune. Kills the
   optimizer loop.
3. **Recover line ≈ 20% below trip** (8k at a 10k cap; `recover_pct` config knob), not
   50%. eda's observed cohesive-extraction quantum is ~200–900 lines per module
   (route_grid 690, gap_close 785, route_timeline 221, pcb_rules_json 208,
   mcp_parts_tools 507); a 2k band is 2–4 cohesive cuts — an achievable campaign —
   while a 5k band forces cutting past the cohesion frontier into mechanical
   bisection. Widening a band later is cheap; un-widening a mandated 50% mid-campaign
   is not.
4. **While tripped: monotone-shrink-to-land.** Net growth of the tripped file blocks
   (no accept); net shrink lands and lowers the high-water mark; files untouched by a
   commit never block it. This converts the big-bang into the incremental campaign the
   evidence favors — it is exactly the frozen-ceiling dynamic that already paid router
   down ~300 lines in 5 weeks, minus the accept escape and the prune loophole. Side
   effect on hot files: long red-while-shrinking periods push *new* features into new
   modules instead of the giant — which is the desired architecture pressure.
5. **Prerequisites, in order:**
   - **Relocation-aware ratchet identity** (a split must not re-charge type-size/
     ratchets at the new key) — the single highest-leverage change this audit
     surfaces; without it the design mandates the most expensive workflow Guardian has.
   - **Stop counting comment/blank lines in the file-size metric** — removes the
     delete-the-docs incentive outright (currently only test blocks are excluded).
   - **One loud pre-trip warning at ≥95% of the hard cap** on every build, separated
     from the 45-finding advisory noise (also already wished for).
   - Optional: cut-point guidance in the failure message (import-cluster hint).
6. **Scope discipline.** Shape checks stay as they are (they work). type-size's leak
   is accept-creep, not hovering — `deny_growth = ["type-size"]` (already
   implemented) is its fix, possibly with a shed-one-field recovery variant later.
   line-length stays two-tier as is.
7. **Watch two counter-metrics after shipping** (FEEDBACK + DORA): comment-line share
   of shrink commits (elision detector) and new single-caller shim modules (bisection
   detector). If elision appears despite the metric fix, borrow aider's guard: require
   non-comment AST mass to be conserved-or-relocated across a shrink.

The net judgment: Eugene's instinct — thresholds have become attractors and the fix is
a dead-band, not a tighter cap — matches both the repo evidence and forty years of
control engineering. The two corrections that matter: make the dead-band ~20% rather
than 50%, and make "red" mean *this file may only shrink* rather than *nothing merges
until half* — because the one place the current system demonstrably produced real
structural paydown is a hot file pinned under exactly those semantics.

---

## Implementation record (2026-08-11, same day)

Part 5 shipped on this branch as three sequential opus-agent commits, each gate-green
(71 checks) before the next began:

1. `a3198dd` — **file-size counts only code lines** (blank and whole-line-comment
   lines excluded, shared measurer with `size`/`debt`; kills the delete-docs-for-
   headroom incentive — Guardian's own over-advisory files dropped 4 → 1 on the spot);
   **NEAR HARD CAP alert** at ≥95% of a hard cap on an always-visible channel that
   survives `--summary`/scope-collapse (`Violation.alert`); `debt --live` headroom
   rows carry percent-consumed and typed JSON fields.
2. `aa47b86` — **relocation-aware ratchets** (`src/relocation.zig`): git-visible
   renames re-key every entry under the file; a uniquely-matched extracted item
   transfers its ceiling to the new file (`moved:` lines, count conserved, never a
   raise); ambiguous or grown cases still fail but name the candidate and the
   transfer command; deny_growth permits pure relocation. Splitting a file no longer
   re-charges its ratchets.
3. `5f89e28` — **hysteresis** (`src/hysteresis.zig`, `[hysteresis]` config: enabled
   default true, `recover_pct` default 20, checks default file-size +
   function-length): hard-cap crossings can no longer be accepted; a tripped entry is
   held below the cap and prunes only at the recover line (8000 / 320); growth while
   tripped fails with no accept escape while shrink lands and auto-lowers; adoption
   still grandfathers; session accepts, deny_growth, merge driver (min-wins), scoped
   runs, `explain`, and `debt --live` (`TRIPPED — recover at <=N`) all integrated.
   The composite eda-migration test covers: old over-cap entry re-measured smaller
   under the new metric → retained through the recovery zone → growth blocked →
   `recovered:` + prune at ≤8000.

Suite: 936 → 968 tests. Deliberately not built: hysteresis for single-tier shape
checks (no surfing observed; "20% less nesting" prescribes nothing) and any change to
type-size (its leak is accept-creep — the existing `deny_growth = ["type-size"]` is
the remedy, an eda config decision). Post-ship counter-metrics to watch in
FEEDBACK/DORA remain as Part 5 §7: comment-share of shrink commits (elision) and
single-caller shim modules (bisection).
