# Guardian Hardening Audit — 2026-08-24

**Question asked:** Guardian is entering hardening mode — stop adding features,
simplify. What high-value items remain worth adding, and what low-value surface
can go?

**Evidence base:** five parallel sub-audits over this worktree — (1) a full read
of all 830 FEEDBACK.md entries (2026-07-18 → 08-24), (2) the five prior audit
docs + CHANGELOG cross-checked for what is settled vs open, (3) the 83-entry
check registry with per-check LOC and both consumers' configs/baselines, (4)
the 43k-LOC non-check surface (commands, env vars, config, build integration),
(5) a code-level robustness scan (crash surface, state files, child processes,
fuzzing) — plus live data: eda's `last-run.jsonl`/`dora.jsonl`, `.guardian/`
git churn, and repo commit statistics.

---

## Verdict

Guardian is **feature-complete for its mission and the hardening turn is
overdue** — the tool's own data says so:

- **The checks are not the problem.** 79 gating checks run in ~1.1 s whole-tree;
  the FEEDBACK log credits ~25 of them with repeated real catches; and the
  noisy tail is already neutralized in practice — eda runs
  `[policy] profile = "agent"`, and **100% of eda's current advisory findings
  (197/197 rows in `last-run.jsonl`) come from five style-tier checks that
  profile has already demoted to report-only**. The prior audit's
  "don't cut checks" conclusion (07-23) was right about the spine; the cut
  list below is precisely the tier the flagship consumer has since un-gated.
- **The orchestration layer is where cost and bugs live.** Since June the
  most-churned files are `check.zig`, `run_all.zig`, `explain.zig`,
  `registry.zig`, the config parser, and `baseline.zig` — not checks. The
  non-check surface is 43,274 of 69,425 src LOC (62%): 23 CLI commands, 13 env
  vars, ~40 config sections (~5,000 LOC of config machinery), and duplicate
  mechanisms for acceptance, diff-base, and child-run suppression.
- **The feedback loop itself became the biggest process cost:** 752 of 869 repo
  commits since 07-20 (87%) are FEEDBACK.md appends; 20.7% of all entries are
  pure `good:` confirmations the old rules mandated, and marginal information
  per entry dropped sharply after ~08-20. (Rules rewritten as part of this
  audit — §6.)
- **Robustness is already unusually good** — fail-closed config, atomic
  snapshot writes, a metadata transaction that fixed the July baseline-wipe
  class, an exemplary mutation watchdog, three enforced fuzz harnesses, zero
  TODO/FIXME in src/. The remaining gaps cluster in exactly four places:
  cross-process concurrency (no lock of any kind), git environment
  assumptions, environmental errors escaping `main` as raw traces, and the few
  non-atomic cache-tier writers.

---

## 1. Fix first — the two live bugs (open in the log's final week)

**B1 · `guardian-check commit` phase-2 zombie busy-spin, now with metadata
damage.** Five reproductions 08-21 → 08-24 (codex/eda): the maker child goes
defunct, the parent spins at 100% CPU printing "tests running" for 340–1,190 s
until Ctrl-C — and on 08-23/08-24 the runs **also rewrote nine unrelated
`.guardian/baselines/*.txt`**, which violates the read-only-metadata invariant
that closed the July wipe bugs. A process-group kill for commit landed ~08-20,
but reproductions continue after it. This is the most serious live defect: it
combines a hang, a lie (tests finished), and state damage. The state-damage
half is likely the same root cause family as H1 below (no cross-process
writer exclusion).

**B2 · The `failed command:` banner on green runs.** The single largest
friction item in the whole log — ~260 mentions, present in ~14 of the final 23
entries, still open on the last day. Zig's build runner prints it before the
verdict line exists; the verdict line (08-14) mitigates but agents still
re-run with `echo $?` almost every session. Guardian cannot unprint the
parent's banner on a direct `zig build test`, but in the paths where guardian
**is** the parent (`commit`'s `test_command` child, `nightly`), it can capture
the child's stderr and suppress/relabel the banner on exit-0. Do that, and
document the direct-invocation case as WONTFIX-with-reason so the log stops
re-litigating it.

**B3 · The opt-in test caps are dead switches — verified still broken.**
`GUARDIAN_TEST_MAX_TEST_SECS`/`_WALL_SECS` are read through an 8 KiB
FixedBufferAllocator shared with argv parsing, and `readEnv` maps any failure
to `null` = "unset" (`test_runner.zig:96–97, 399–403`) — eda bisected it live:
with `env -i` a 5 s cap correctly fails an 11 s shard; add ~2 KB of ordinary
environment and the identical run passes. Their gate comment calls both caps
"dead letters". (The 08-17 fix was the unrelated `env`-prefix tokenizing in
`testTier`; no CHANGELOG entry touches this read.) Fix the read with a
dedicated allocation path — or remove the caps entirely rather than ship
switches that silently do nothing, which is the worst state for a gate.

## 2. High-value additions — all hardening, ranked

Nothing here is a feature; each hardens behavior that already exists.

| # | Item | Prevents | Effort |
|---|------|----------|--------|
| H1 | **Cross-process writer lock** (`.guardian/cache/writer.lock`, exclusive-create, pid-stale detection) held by metadata-writable runs and `mutate` | Two concurrent accepts silently reverting each other via the transaction rollback (`metadata_transaction.zig` restores pre-run bytes unconditionally); concurrent `mutate` runs fighting over the shared splice/journal paths; likely implicated in B1's baseline rewrite | S–M |
| H2 | **Pin the git environment**: `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0` in `spawnGit` | `isNotARepo` matches the English string only — on a non-English locale the documented "skip outside a repo" becomes a hard gate failure; optional-lock contention under concurrency | S |
| H3 | **Named diagnostics for environmental errors** now escaping `main` as raw error-return traces (`check.zig:167` `else => return e`): map WalkError/GitError to one `reporter.fail` line, and carry the offending path (an 11 MB file dies as bare `error.FileTooBig` today). Verified sharp edge to close in the same pass: the shared AST index walk takes only the top-level `exclude` list (`run_all.zig:293`), not `file_size_exclude` (`file_size.zig:211`) — so a >10 MB generated file that the user explicitly excluded from file-size still kills every `all` run with `FileTooBig`. Unify or document which key actually shields the walk | "The gate crashed with a stack trace" sessions; an excluded file crashing the run it was excluded from | S |
| H4 | **Atomic writes for the cache tier**: green stamp + `last-run.jsonl` via the existing `AtomicFile`; dora append as one O_APPEND write | Truncated stamp/log from mid-write kill or concurrent report-mode runs (today: spurious full re-runs, garbled telemetry) | XS |
| H5 | **Corrupt-state recovery UX**: one error renderer for baseline/ratchet/snapshot readers naming the file path and remedy; make all readers of one file agree corrupt ≠ absent; fail closed on unparseable `recover_pct` (currently `catch return` keeps the default silently) | An agent stuck against an opaque `BadFormat` red gate after a bad merge; a policy value that silently doesn't apply | S–M |
| H6 | **Extend fuzzing** to the remaining untrusted-text parsers — SPEC.md parser, `snapshot.parse`, `ratchet.decodeLine`, `git.parseUnifiedDiff`/porcelain-Z, `dora.parseRecord`, `sink.splitLocation`, `violation_key.skeleton`, `merge/three_way` — and register each in `[fuzz_presence] modules` so refactors can't drop them | The abort class `snapshot.parse` already had once (merge-mangled state files, hostile filenames) | S each |
| H7 | **`doctor` validates `.guardian/`** with the cheap readers that already exist (snapshot/ratchet/stamp/dora), and detects a half-rolled-back tree | Corrupt/conflicted state discovered mid-gate instead of by the diagnostic command whose job that is | S |
| H8 | **Machine-readable suite total** (`SUITE: N passed across K shards` or equivalent final line) | The most-repeated un-built ask of the last fortnight (10+ entries): release-gate failure summaries currently show only passing shard tails; the actionable failure lives in test.log. Output-contract honesty, same family as the verdict line | S |
| H9 | **Hysteresis trip message says what clears it** ("growth blocks until ≤N; net-zero or shrinking commits land freely; recover fully at ≤M") | 3 asks in the final week; agents currently believe only a shrink-to-recover clears the gate | XS |
| H10 | **pub-api-surface accept-ergonomics message fixes**: never truncate findings for a check whose only remedy is accept; no fix-line ending in a bare colon; name the accept command on every path | The largest open friction cluster on the most-discussed check (6+ sessions) | S |
| H11 | **Generate the README/CLAUDE check tables and command list from the registry, with a staleness gate** | The recurring stale-docs class: "76 checks/80 entries" was wrong again this week (fixed to 79/83 in this audit — by hand, which is the problem). Standing recommendation from 07-23, never built; it is anti-drift infrastructure, not a feature | M |
| H12 | Git child watchdog (generous deadline, pgid pattern already exists in `budget_runner`); crash-window journal for the metadata rollback (pattern exists in `mutation/journal.zig`) | Wedged git hanging every build; SIGKILL mid-rollback leaving half-restored state | M |

Explicitly **not** re-opened (verified fixed or settled): baseline wipes
(architectural fix confirmed), mutation zombies (watchdog is exemplary), cache
poisoning (fail-open + binary identity + selfcheck), config fail-open,
parallel mutants (deferred with recorded blocker), warn/severity tiers and
bypass flags (settled no), and the parallel per-check pass's reporter capture
(checked: `reporter.default` is `threadlocal` with per-worker arenas and
single-threaded replay — no race).

## 3. Low-value surface — remove or fold

### 3a. Checks to remove (12 checks, ~2,725 LOC, none configured by eda)

The 07-23 "don't cut checks" call predates two facts: eda's `agent` profile
un-gating the style tier, and the live-noise data above. Removing this list
ratifies measured reality; every item is either compiler-redundant, an
unadopted opt-in, or a demoted style opinion with an empty/trivial baseline.
The `disabled`-list tolerance for retired names is the established removal
path.

| Check | LOC | Why it goes | Risk |
|---|---|---|---|
| usingnamespace-ban | 107 | Keyword removed from Zig in 0.15; the pinned 0.17 compiler rejects it, and `deprecated_alias.zig` flags it too — triple-redundant | ~0 |
| magic-number | 287 | Opt-in; sole enabler is guardian's own dogfood; demoted by the agent profile; guardian's own toml calls it "pure noise in literal-heavy domains"; shadowed-const's declared mode is the precision version of the same idea | ~0 |
| stringly-typed-switches | 188 | Style opinion, demoted, empty baseline; the dangerous version (drifting string tables) is exactly what `concept` catches | low |
| boolean-param-ban | 194 | API style, demoted, empty baseline; Zig std itself uses bool params | ~0 |
| struct-method-cap | 214 | Style, demoted, empty baseline; size pressure already comes from type-size/file-size | low |
| optional-density | 294 | Style ratio, demoted; legitimately-optional-heavy types (config, partial records) are common; log calls it "pure tax" on override records | low |
| repeated-switch-on-enum | 356 | Demoted; the one check FEEDBACK names as pure cost ("baseline churn… catching no defects"); guardian self-exempts 6 globs of its own tree | low-mod |
| static-factory-ban | 206 | Java-ism name heuristic; empty baseline; the harmful substrate (mutable global) is ban-globals' job | low |
| init-hygiene | 219 | The opinion half of the init trio (branchy init is often legitimate Zig); correctness stays in init-deinit-symmetry + errdefer-in-init | low-mod |
| compile-error-explanation | 125 | An unexplained `@compileError` announces itself the moment it fires; empty baseline | ~0 |
| escape-discipline | 200 | Opt-in enabled by **nobody** — not even eda, an HTML-serving app and the ideal customer; revive from history if a consumer asks | low |
| stdout-flush | 335 | Report-only forever by design, promoted by nobody; a 0.15-Writergate transitional concern | mod (class is real; note in docs where it went) |

Kept despite temptation: **line-length** and **repeated-string-literal**
(demoted, but eda carries frozen ratchets/debt that removal would orphan —
retire these only with a baseline-migration step), **completeness** (46 KB of
eda debt smells, but eda deliberately enabled it), the six tiny **ban-\***
checks (~334 LOC total on a shared engine, zero noise, the "opinionated
zero-config" bet working as designed), **test-coverage**/**oom-discipline**
(guardian self-hosts them).

### 3b. Checks to fold (keep the signal, shed the code)

| Fold | Evidence | LOC |
|---|---|---|
| boundaries → import-layering | README calls boundaries "the older, narrower form of the same idea"; layering is a strict superset (allow + reason + per-edge keys). Needs a config alias/migration — **eda configures both** | 125 |
| unwrap-discipline → catch-discipline | Same tokenizer shape, same mistake class (crash-on-absence), same defaults. One check, two keywords | 166 |
| bool-ops-per-condition → cognitive-complexity | The complexity check's own comment says the metric was split to avoid double-counting — same shape as the executed returns-per-function fold. Keep the signal (3 real catches in Aug): fold the counting into the score | 200 |
| module-doc-header → doc-comments | Both doc-presence walks; doc-comments already absorbed doc-quality | 232 |
| allocator-hygiene onto the shared ban engine | 390-LOC bespoke `ChainState` machine hand-rolls what `banned_symbol_helper` gives 8 other checks. Keep the check, delete the engine | ~300 |
| shadowed-const: delete the `auto` measurement tier | Its own doc admits auto misses the motivating finding (`1.0` is on the ignore list); only `declared` gates; ~half the 903-LOC file supports the non-gating tier | ~450 |
| repeated-string-literal, cross-file half (if the check survives) | Duplicate-const-across-files re-scans what divergent/shadowed-const scan, for the harmless polarity | ~250 |

Watch-list, not folds: `concept.zig` (1,549 LOC — earns it today via eda's 11
rules and real catches, but it is the check most likely to grow unbounded;
freeze its keyword surface), `twin_referent.zig` (838 LOC parsing English
prose — highest LOC-per-catch in the suite), `duplicate_json_key.zig` (757
LOC whose mistake class evaporates once the json-writer idiom migration
completes — planned obsolescence, revisit in a month).

### 3c. Non-check surface

| Item | LOC | Action |
|---|---|---|
| `history` command | 1,024 | **Remove.** Sole reader of dora.jsonl, 3 commits ever, its own header admits 429 records accumulated "without a single mention of the file"; its one FEEDBACK appearance is an infinite-loop bug it caused. Keep the cheap dora *sink* (data keeps accruing for future analysis) |
| `size` command | 260 | **Fold into `debt --live`** — same question at different granularity (`file_metrics` is already shared) |
| `guardian-fakes` module | 439 | **Drop from the public surface** (README/build exports) — zero consumers anywhere in canopy; keep as internal test util if guardian's own tests use it |
| `test-filter` command + `[test_filter]` config | 567 | **Freeze/remove** — advisory-only, never gates, and FEEDBACK says most projects need build.zig edits before its report is usable |
| `[measurement]` bridge | 424 | **Decide deliberately**: zero adopters, but it answers the logged profiling-dance friction. Either wire it into a consumer this month or delete it — an unadopted bridge is pure carrying cost |
| policy-lock rail (`policy-drift` check + `GUARDIAN_POLICY_APPROVED` + lock keys) | ~150 | **Remove** — default-off, configured by nobody, duplicates what code review of guardian.toml does |
| `[benchmark] gate` tier + `--force` | ~150 | **Remove** — the regression-refusal machinery is unused; the ledger itself stays (real eda records, praised) |
| `single_process = false` branch in build_helper | ~50 | **Delete** — dead legacy branch, nothing sets it |
| Env vars 13 → ~8 | — | Merge `GUARDIAN_SKIP_CHECKS` into `GUARDIAN_MUTATION_RUN` (two names, one behavior); drop `GUARDIAN_AGAINST` (the flag and the config key are the other two spellings); finish the 07-23 half-done consolidation: make `GUARDIAN_UPDATE_SNAPSHOT` a thin alias over `accept` internals, or retire it after a deprecation window (46 references today) |
| CLI collapse (07-23 Tier 2) | — | The umbrella item. Stage it: first hide peripheral commands from `printHelp` (precedent: `selfcheck`/`migrate` are already hidden), then retire aliases — `--current` = `--live`, `version` vs `--version` keep one, and `--summary` (verified: `summary: bool = true` is the default and nothing sets it false, so the flag is a pure no-op spelling; `run_view`'s `.normal` branch is unreachable dead code) — then fold per the rows above. The ~8-verb end-state from 07-23 remains the right target |

## 4. Do not remove (and why)

`.guardian` **merge driver** (installed and load-bearing in eda's multi-agent
worktree flow; 3,187–3,835 rows merged conflict-free per the log) ·
**doctor** (FEEDBACK asks for *more* of it — and H7 grows it) · **bench
ledger** (real records, agent-memory role) · **debt** (105 FEEDBACK mentions;
"first command I run before touching a big file") · **explain** (85% praise;
"paid for itself" repeatedly) · **sink/last-run.jsonl** (the agent fix-loop
reads it) · **cache/green-stamp** (the "invisible" principle depends on it) ·
**run_view** (the verdict-line contract) · **mutation subsystem** (keep +
freeze: hard-code the three timeout tunables nobody varies; eda actively
ratchets) · **hysteresis/ratchet/relocation stack** (this IS the anti-gaming
machinery; watch the two 08-11 counter-metrics — comment-elision and
shim-bisection — as agreed) · the **relational family** (concept,
canonical-idiom, divergent/shadowed-const, twin-\*, duplicate-json-key: eda
invests config in all of them and each has ≥1 real catch) · the **honest test
loop** (counting runner, test-compile probe — top praise magnets) · the
**spine checks** (spec, change-classification, pub-api-surface, the ratcheted
size/complexity set, import/reachability graph set, compiler-blind
correctness set, test-gaming defenses).

## 5. Parked under the feature freeze

Logged wishes that are real but are features, not hardening — park explicitly
so the log stops re-asking: board-corpus regression tier / golden-output
fixtures; `--defer-snapshots`; `commit --paths` / staged-subset accept;
scratch-instrumentation escape hatch; mutation `--recheck` + debug child
builds; auto-rebuild of a stale prebuilt dep (the *hint* exists; auto-rebuild
is a feature). Revisit after the hardening backlog clears.

## 6. The feedback log — rules changed (done in this audit)

Old rules mandated logging every session ("a smooth session is signal too"),
plus `wish:`/`prototyping:` channels. Result: 830 entries in 5 weeks, 1,368
`good:` bullets vs 116 `bug:`, 20.7% pure-praise entries, 87% of all repo
commits, and sharply declining information density once the tool stabilized.

**FEEDBACK.md's header now says: log only problems.** `bug:` and `friction:`
are the only bullet kinds; a smooth session logs nothing and commits nothing;
feature wishes are out of scope while Guardian hardens (a fix proposal
attached to a real problem is still welcome, inside the bullet). Existing
entries are untouched per the append-only rule; CLAUDE.md's pointer paragraph
is synced. Known tradeoff, accepted: the log loses its health-metric and
fix-confirmation signals — absence of new complaints now carries that
information.

## 7. Housekeeping landed with this audit

- **CHANGELOG.md repaired**: 9 committed merge-conflict marker lines (three
  stacked blocks from the 08-14 shadowed-const/import-layering/twin-parity
  merges) removed; all four content blocks kept.
- **CLAUDE.md counts corrected**: 76→79 gating checks, 80→83 registry entries
  (until H11 exists, these will drift again).
- **LOOP_NOTES.md / RESEARCH-BRIEF.md stamped Historical** (AUDIT.md P7,
  outstanding since July); RESEARCH-BRIEF's Principles/Non-Goals remain the
  canonical scope statement.
- **FEEDBACK.md rules rewritten** (§6) and CLAUDE.md synced.

## 8. Suggested sequencing

1. **B1** (commit zombie + baseline rewrite) with **H1** (writer lock) — one
   investigation, likely one root-cause family.
2. **B2** banner suppression in commit/nightly + **B3** fix-or-remove the dead
   caps + **H9/H10** message fixes — the papercut wave; cheap, kills most
   residual log traffic.
3. **H2–H5** (git env, error rendering, atomic cache tier, corrupt-state UX).
4. **Removals/folds** (§3) in two commits: checks first (registry + docs +
   `disabled` tolerance), then commands/config/env — each behind the
   deny-growth-style refusal if a consumer still references it.
5. **H6–H8** (fuzz extension, doctor sweep, suite line).
6. **H11** docgen, then the staged CLI collapse — the last structural item,
   after which the doc-drift class is closed by construction.

Net effect if §3 executes in full: ~5,500–6,500 LOC removed, 12 fewer checks
(79→67, none of them gating anything in practice today), 5 fewer env vars,
one acceptance mechanism, and a CLI whose help fits on a screen — with zero
loss of demonstrated catch value.
