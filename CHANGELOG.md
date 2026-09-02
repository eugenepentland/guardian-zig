# Changelog

All notable Guardian changes are recorded here. Releases follow semantic
versioning; consumers should pin a tag and Zig package hash rather than a live
sibling checkout.

## 0.2.0 - Unreleased

- New `projection-completeness` check with `[[projection]]` config rules: a
  struct literal that rebuilds a declared bundle out of the parts a caller
  happens to hold, while omitting part of the bundle. Nothing in the compiler
  can see it, because every field of such a struct DEFAULTS — an omitted field
  is not an error, it is a silent empty. Measured from eda's own fix commits
  (2026-09): `pour.Copper` gained a defaulted `arcs` field in 30c8b52c and five
  literals projecting a Copper from a routed result kept spelling the old
  bundle, so the connectivity oracle they feed read a net joined only by an arc
  as an OPEN; ten sites were repaired by hand across 60275963 and 04af9ace and
  two were still wrong afterwards (`placement/fine_accept.zig`,
  `placement/congestion.zig`) — both of which this check reports. A rule names
  the `type` and the `fields` that must travel together; a literal setting SOME
  but not ALL of them is the finding, and one setting NONE of them is not a
  projection of that bundle. `type` matches the TAIL of a literal's type path at
  a segment boundary, so `Copper` covers `pour.Copper{` while
  `routed_copper.Copper` covers only that one — the narrowing a repo with four
  distinct `Copper` types needs. An anonymous `.{ … }` literal is judged only
  when it sets `anonymous_min_fields` (default 2) of the declared set AND sets
  nothing outside `fields` + `optional`; on eda that half reported 98 literals
  to the typed half's 4, most of them unrelated structs whose vocabulary is a
  subset, so `anonymous_min_fields = 0` turns it off. `test` blocks are skipped,
  and `// projection-ok: <why>` beside the literal, above it, or on the
  enclosing statement is the in-source exemption, so a deliberate partial
  projection carries a reason rather than a baseline row. Keyed
  `<name>|<file>|<fn>|<sorted fields set>`, so rewording the message or moving
  the literal never re-keys a consumer baseline.

- New `twin-drift` check with a `[twin_drift]` config table: two functions in
  DIFFERENT files whose copied bodies have stopped agreeing.
  Measured in eda (an audit of 155 fix commits, 2026-09), "two hand-written
  copies of one rule drifted" is the cause behind 25 of them. The live case is
  `buildNetClassOverrides`, duplicated in `drc_session.zig` and `wasm_drc.zig`:
  the first file's header says the JSON board parser was copied on purpose to
  stay under the file-size cap, then the wasm copy gained `.class`,
  `.power_branch_width`, `.keepout_mm` and `.keepout_escape_mm` over two commits
  and the session copy gained none of them, so the session DRC now runs with no
  keepout rule. The two share no type, no call and no file, so nothing in the
  compiler can see it and each copy's own tests keep passing.
  - Similarity is `2*|LCS| / (|A| + |B|)` over normalised body lines (comments
    and blanks dropped, internal whitespace collapsed, one entry per source
    line), which reads directly as "share N% of their body"; the motivating
    pair measures 81% against a 0.6 floor.
  - IDENTICAL bodies are NOT reported. Byte-identical twins are duplication
    debt, and listing them buries the pair that is actively wrong — the same two
    files hold four of them. `report_identical = true` asks for that inventory.
  - A `mirrors X` / `same as Y` claim in either doc comment does NOT exempt the
    pair, because a declared mirror that drifted is the worst case; the message
    says `(declared mirror)` instead. The exemptions are `// twin-drift-ok:
    <reason>` above either copy, `[twin_drift] ignore` for a name a project
    implements once per file as an interface, and `[[allow]]`.
  - A fn inside a `test` block, and a private fn reachable only from `test`
    blocks in its own file (directly or through another such helper), are both
    skipped: excluding those per-file fixtures took the eda run from 203
    findings to 69.
  - The advisory detail line names WHAT drifted — up to four lines one copy has
    and the other does not, preferring new content over a line the other copy
    merely re-wrapped, so the motivating pair reports its four missing rule
    fields rather than a moved brace. It rides `reporter.warn`, which no
    baseline records.
  - Cost: a body over `max_lines` (default 400) is counted rather than
    compared, and a bag-of-lines upper bound rejects a proposed pair in O(n+m)
    before the LCS runs.
  - Self-hosting: the check found `containsWord` spelled identically in
    `panic-budget` and `spec-quality` under two parameter names, now reconciled
    into `text.zig`. Guardian's own `[twin_drift] ignore` names the four
    check-plugin protocol functions (`run`, `analyzeContent`, `analyzeFile`,
    `fileVisit`), one implementation per check by construction, and six sibling
    pairs carry `// twin-drift-ok:` annotations naming what deliberately
    differs.
  - **Pairing is name-agnostic (v2), and the baseline key changes with it.**
    v1 proposed a pair only when the two functions shared a NAME. That misses a
    copy that was renamed, and a shared name is not evidence of a shared rule,
    so two functions overlapping only in scaffolding were proposed and then
    judged on that scaffolding. v2 proposes from the BODIES: each is
    re-tokenised with Zig's own tokenizer (every string and char literal
    collapsed to one `$str` token, every number to `$num`, keywords, operators
    and identifiers kept as their text) and becomes the multiset of its 3-gram
    token shingles; over all candidate bodies of the run each shingle gets an
    idf, each body a `tf*idf` vector, and a pair is proposed when the cosine
    reaches the new `[twin_drift] pair_similarity` (default 0.5). An inverted
    index accumulates those dot products sparsely and only through shingles held
    by at most 96 bodies, so two bodies sharing nothing rare are never compared.
    Judgement is untouched — the same line-level LCS against `min_similarity`
    decides, `report_identical`, the exemptions and the detail lines are all
    unchanged — so v2 changed which pairs are *proposed*, not how a proposed
    pair is judged.
    - **Consumer baselines for `twin-drift` re-key.** The identity is now
      `<nameA>|<fileA>|<nameB>|<fileB>` with the sides ordered by path, since a
      pair no longer has one shared name to be keyed by. Guardian is the only
      consumer of this check so far, which is why the re-key lands now.
    - Measured on eda (526 files, ~510k lines): v1 0.26 s / 69 pairs, v2 0.49 s
      / 126 pairs over 5,734 candidate bodies and 263,536 distinct shingles.
      The motivating `buildNetClassOverrides` pair scores 0.68 against the 0.5
      floor; the two scaffolding-only pairs v1 misreported score 0.44 and 0.33.
      56 of v1's 69 stay, 13 drop, and all 70 new pairs are copies under a
      different name — `shapeOfPoly`/`shapeFromWorldPoly`,
      `isSafeLibName`/`isSafeFootprint`, `writeXml`/`writeHtmlEscaped` — the
      population v1 could not see.
    - `[twin_drift] ignore` stays, and Guardian still needs it: pairing by body
      is not pairing by protocol, so one interface implemented once per file
      still looks alike whatever the implementations are called (Guardian's own
      tree: 8 findings with the list, 70 without). Two of the eight were real
      duplication and were reconciled rather than annotated — `check.splitCsv`
      now calls `snapshot_helper.splitNames`, and `divergent-const` and
      `shadowed-const` now read one `const_fold.rootConsts` population instead
      of two hand-written copies of the same loop. A third, the copied
      owned-string-map insert behind `FakeEnv.set` and `FakeFs.writeFile`, moved
      to `fakes/owned_map.zig`.
  - **Frozen pairs are silent.** The advisory detail rode `reporter.warn`,
    which no baseline records — so a project that baselined its whole backlog
    kept being told about all of it: eda, with 125 pairs frozen and
    `twin-drift . --list` reading `NEW (0) / LIVE (125)`, still saw
    `twin-drift: 124 finding(s) — report-only` and 124 `warning:` lines on every
    cold gate. The check now consults its OWN baseline (the new public
    `baseline.frozenKeys`, which `spec` reuses for its unlinked-tag hints) and
    prints the sample only for a pair that is actually being reported — a NEW
    pair, or every pair when baseline mode is off for the check or under
    `--dry-run`. The sample also joins the reported pair's `fix_hint`, so
    `last-run.jsonl` names what drifted on rows that have no advisory tier to
    read it from. No identity key moved: a consumer's frozen rows stay LIVE.
  - **A corpus shift no longer changes the verdict on files nothing touched.**
    The v2 proposal is corpus-wide — `idf(s) = ln((N+1)/(df+1)) + 1` moves
    whenever a body is added or removed ANYWHERE — so a pair sitting just under
    `pair_similarity` crosses it with no edit to either of its own files.
    Measured in eda (2026-09-02) while merging five branches that each
    reconciled a disjoint family out of 125 frozen pairs: after the first merge
    removed 40 bodies, the next branch's rebased tree reported
    `module_policy.stripUpper` / `pin_roles.normalizeIdent` (90% LCS) and
    `assembly_debug.writeJsonString` / `route_review.writeJsonString` as NEW
    blocking rows in files no branch had touched, and one merge left main red
    until a later branch's baseline happened to carry the row. Both pairs were
    real drift, so the *proposal* was right and the tf-idf pass and the LCS
    judgement are unchanged; what BLOCKS is narrowed instead.
    - A pair already recorded in the baseline is LIVE, exactly as before.
    - An unrecorded pair BLOCKS only when this change touched one of its two
      files, read through the same `scope.resolve` every other diff-aware
      feature uses: `--against` / `GUARDIAN_AGAINST` when given, else the merge
      base with `main`/`master`, working tree plus index, untracked included.
    - Every other unrecorded pair is **SURFACED**: it does not block and the run
      does not record it. It rides the advisory channel as ONE collapsed line
      (`twin-drift: N pair(s) surfaced by corpus shift, none in files this
      change touched — advisory; guardian-check accept twin-drift . records
      them`), flagged `alert` so `--summary` cannot bury it behind a finding
      count, expanded per pair (with drift samples) by `--verbose`, listed by
      `--list` in a new `SURFACED (n)` bucket between NEW and LIVE, and left
      alone by `--dry-run`, whose contract is still every finding unfiltered.
    - With no resolvable base — outside a repository, or with no `main`/`master`
      to merge-base against — nothing can be PROVEN untouched, so every
      unrecorded pair blocks (the pre-narrowing behaviour) and the run says so
      in one line under the failure.
    - `guardian-check accept twin-drift .` records the surfaced pairs, and may
      do so under `[baseline] deny_growth` even though it adds keys — but only
      for pairs the run proved neither file changed against the base: that is
      pre-existing debt made visible, not growth the change introduced. A pair
      whose file the change touched is never surfaced, never carries the
      exemption, and is still refused. Identity keys are untouched, and the
      frozen-pair advisory suppression is unchanged.
  - **The idf table is frozen, so Guardian's own scoring stops moving.** The
    narrowing above decides what a corpus shift may BLOCK; this decides whether
    it moves a score at all. Across the same five eda merges, **128 of 174**
    untouched surviving pairs (74%) changed score with neither of their own
    files edited, five reported pairs sat within 0.02 of the 0.5 floor, and the
    `stripUpper` pair crossed it from 0.4927 — a knife-edge, measured in
    `docs/twin-drift-scoring-study-2026-09-02.md`. Removing the idf is not the
    fix: it IS the discriminator, and every corpus-independent weighting the
    study measured gave back the separation that rejects `padNets` at 0.44 and
    `placement` at 0.33. So the weighting stays and the TABLE is pinned.
    - `.guardian/twin-drift-df.txt` (v4) holds the document count and every
      shingle's frequency as they stood at the last accept: a `docs <N>` header
      row, then one row per shingle ascending — a bare 8-character base-36 key
      at the implicit frequency 1, `<key> <df>` above it.
    - **Both halves of the decision read it**, the idf weight AND the
      `2 <= df <= max_df` proposal gate. The gate too, because a boilerplate
      3-gram drifting across `max_df` adds or removes real mass from an
      untouched pair's cosine — freezing only the weight still let the eda pair
      cross. What stays live is the posting COUNT, which only sizes each
      posting list. Two bodies that did not change therefore score
      bit-identically however the rest of the tree moved: replayed over the
      study's six eda states, a table frozen at the first reproduces the
      frozen-idf reference exactly five merges later (125/85/49/31/14/0 pairs,
      `stripUpper` never admitted).
    - A shingle the table has never seen falls back to its LIVE frequency, so
      code added since the freeze is proposed and judged normally.
    - **No table means no change.** A project without one scores exactly as it
      did before the file existed, and no ordinary run, `--gate`, `--dry-run` or
      `--list` ever creates or rewrites it — `--dry-run` and `--list` DO read an
      existing one, because that is scoring, not baseline filtering. Only an
      accept that names twin-drift writes it: `guardian-check accept twin-drift
      .`, `GUARDIAN_UPDATE_SNAPSHOT=twin-drift` (or `=all`), or `zig build
      guardian-accept -Dguardian-checks=twin-drift`. Accept means ratify the
      current state, so the table is rewritten from the corpus this run measured
      even when no pair is new; the write is the same content-checked atomic
      replacement every other `.guardian/` file uses, so a re-accept that
      measures the same corpus leaves `git status` clean. It is not a baseline:
      `deny_growth` and hysteresis do not apply to it.
    - **The whole vocabulary is stored, df=1 rows included**, and that is
      measured rather than lazy. Dropping the df=1 tail would cut eda's table
      from 264,931 rows to 85,392 — but an absent shingle falls back to live,
      and a 3-gram that was unique at freeze time and is held by two bodies now
      IS the corpus shift: a df>=2-only table replayed 125/**86**/50/32/15/0 and
      re-admitted the very `stripUpper` pair this feature exists to remove. The
      other way out (treat an absent shingle as df=1) is worse, since `proposes`
      needs df >= 2 and every 3-gram of a newly added file would then be unable
      to propose anything — two fresh copies of one rule would go unseen. The
      row count is paid, and paid down in the encoding: the truncated key and
      the implicit df=1 take eda's table from 5.9 MB raw to **2.5 MB**. The key
      is the low 41 bits of the shingle hash, where the expected number of
      distinct 3-grams sharing a key over eda's vocabulary is 16 (0.006%), and a
      collision costs those two shingles one merged frequency — never a crash, a
      missed pair, or a non-deterministic file.
    - **An unusable table warns and scores live**, never degrades in silence: a
      stale version, a broken row, a missing `docs` count or leftover conflict
      markers each produce ONE line naming the file, the reason, and
      `guardian-check accept twin-drift .`.
    - `guardian-check twin-drift . --list` now heads its output with the table's
      coverage — how many of this run's live shingles it holds, and its frozen N
      against the live one — so staleness is a thing you look up before a
      release rather than a line on every gate run. (`--list` replays every
      `alert` advisory line above the listing now, the same rule
      `run_view.showsAlerts` applies under `--summary`.)
    - `guardian-check merge-file` classifies the table as its own artifact kind
      and resolves a conflict by keeping **OURS whole**, then marking the file
      for regeneration: every row is one measurement of one corpus, so a row
      from ours beside a row from theirs describes a corpus neither branch had.
      `install-merge-driver`'s `.guardian/**` attribute already covers it, and
      `twin-drift-df` joins `pub-api` as a metadata leaf whose basename resolves
      to its check — so a named refresh keeps the table through a red sibling.
    - Freezing removes drift caused by Guardian's OWN scoring and nothing else.
      It does not touch a pair that genuinely crosses because someone edited a
      third file, and every refresh is a fresh chance for such a pair to appear
      — which is what the diff-aware narrowing above is for. The study is
      explicit that of the two, the narrowing is the more important.
- **`[baseline] deny_growth` is documented per flavor, matching the code.** The
  docs said a refresh that would "raise a recorded value or add a key" fails for
  both baseline flavors; only the per-item ratchet (v2) has ever worked that way.
  An identity baseline (v3) is guarded by its COUNT — a row is one violation, so
  the count is the debt, a swap is not growth, and a reconciliation that resolves
  eighteen rows while recording two lands (which is what eda observed on
  2026-09-02, against a doc that said it should fail). The lenient rule is the
  intended one and is kept; README, CLAUDE.md and `explain` now state both rules
  separately. On top of it, `reporter.Violation` gains `growth_exempt`: a check
  may mark an addition a `deny_growth` refresh may still record, having PROVEN
  it is pre-existing debt the change only made visible. Exempt additions are
  discounted from the count comparison and are named in no refusal; every other
  addition is refused exactly as before. `twin-drift`'s surfaced pairs are the
  only user today.
- Group ROI triage by stable subject (Guardian digest + check + finding key),
  so recurring commit-specific observation IDs no longer inflate the pending
  backlog or usefulness totals. `guardian-roi pending` now defaults to the
  current direct cohort, `label-subject` classifies present and future
  occurrences, and `--observations` / per-observation `label` remain available
  for exceptions. Summaries count categories and human cost once per subject.
- Add local per-check ROI telemetry without changing DORA semantics. Every
  `all` invocation now appends a schema-v1 `check-roi.jsonl` record, including
  cache/partial scope, total and check-phase wall time, overlapping per-check
  timings, effective policy/outcome, and stable finding observations; `accept`
  and `commit` add explicit workflow-phase events. The raw stream is locked,
  bounded to 32 MiB plus one retained generation, git-ignored, local-only, and
  best-effort. `last-run.jsonl` gains an additive baseline-v3 `finding_key`.
  The stdlib-only `scripts/guardian-roi` helper lists pending observations,
  appends evidence-backed human labels to a separate durable ledger, and emits
  latest-digest/direct-run Markdown headlines plus JSON digest/scope/origin/
  phase cohorts without editing policy. Label attribution survives raw-log
  rotation. Agent documentation now defines the four classifications,
  unknown-cost semantics, privacy limits, and the required usage-feedback
  workflow.
- New `canonical-idiom` check with `[[idiom]]` config rules: pattern-level
  ownership for a code idiom that is not a named symbol. `[[ban]]` owns a call
  chain and `[[concept]]` owns a literal spelling; neither can express an
  EXPRESSION SHAPE built out of ordinary std calls, which is the form an agent
  re-derives from scratch every time because there is no name to search for.
  Measured in the flagship consumer on 2026-08-14, each with a canonical
  implementation already in the tree: 51 sites hand-rolling a sub-block leaf
  split as `lastIndexOfScalar(u8, <x>, '/')` under 8 different function names,
  6 byte-identical `urlDecodeAlloc` wrappers around
  `std.Uri.percentDecodeInPlace`, 8 private tmp+rename atomic writes, and ~24
  private JSON escaper loops in 7 incompatible tiers despite `json_writer.zig`.
  A rule declares `fragments`, and the CONJUNCTION is the design: a LINE matches
  only when every fragment appears on it, which narrows a legitimate std call
  back down to the one expression that means the idiom. `files` scopes the scan
  (default `["src/*.zig"]` — Guardian's `*` spans `/`, so that is already the
  whole subtree), `allow` names the canonical home, and `reason` is REQUIRED
  (an idiom finding is unactionable without the name of the thing to call, so a
  rule omitting it is a config error rather than a violation with a
  placeholder). One violation per (rule, file) keyed `<name>|<file>` — rule
  first, because an idiom's ledger is read as "which files still hand-roll THIS
  shape", so a sorted baseline groups one rule's whole cleanup campaign.
  Multi-line idioms are deliberately out of scope.
- The comment/`test`-block blanking and the every-extension glob walk that
  `concept` introduced move to `src/checks/lexical_scan.zig`, shared with
  `canonical-idiom`. The two relational checks now cannot disagree about what a
  lexical scan may judge, and the second one gains the exemptions that made the
  first one's frozen ledger real instead of re-deriving them.
- New check `shadowed-const`, closing `divergent-const`'s recorded blind spot:
  a value that already HAS a name reappearing somewhere else as a BARE literal.
  divergent-const compares one NAME across files, so a copy that never got a
  name is invisible to it — which is why zero rows there is not the same as a
  consistent tree. The eda audit (2026-08-14) that produced this found
  `export_fab.zig` declaring `auto_outline_margin_mm = 1.0` while
  `placement/pour.zig` and `placement/route_free_space.zig` each re-derive the
  same rectangle from a bare `1.0` (one comment reads "Replicated here to avoid
  an import cycle"), so changing the constant silently desyncs the pour raster
  from the Edge.Cuts outline; plus three files holding a `1e-6` clearance
  epsilon under three names, a `0.05` mm step bare in two files, and a 16 MiB
  sidecar cap spelled four ways with one 256 MiB outlier. Two modes, and the
  split is the product: `declared` (the default) is the GATE — a `[[shadow]]`
  rule per constant that matters, `const = "<path>.zig.<name>"` in the same
  referent spelling `/// mirror-of:` already uses, plus optional
  `files`/`ignore`/`reason`; zero rules is a zero-config pass, a declared rule
  is verified whatever the noise controls say, and a rule whose referent
  resolves to nothing is ITSELF a violation (the dangling-claim behavior
  `twin-referent` established). `[shadowed_const] mode = "auto"` is a
  MEASUREMENT tier that sweeps every unit-suffixed file-scope const and reports
  bare occurrences elsewhere, filtered by a folded-compare `ignore_values` list
  and the `min_float_digits`/`min_int_digits` floors — deliberately not the
  default, because it reports 33 rows on Guardian's own tree of which 30 are a
  power-of-two I/O buffer size, and because the motivating case above is
  invisible to it (`1.0` is on the ignore list). BARE means unnamed: a literal
  that IS a named const/var's initializer is a NAME, which is divergent-const's
  subject with a different fix and is what `magic-number` asks you to create;
  comments and strings are not literals at all (the scan reads `number_literal`
  nodes, never text); `test` blocks are skipped; and a file declaring the value
  under any name is skipped for that value. Findings are keyed
  `<referent>|<file>`, so a fourth bare copy in a frozen file stays frozen while
  a new file fails. The numeric fold and the unit-segment table move out of
  `divergent_const.zig` into a shared `checks/const_fold.zig` — two copies of a
  numeric fold is precisely the debt these checks exist to find — and
  `foldNumber` gains a leading-digit guard, since `std.zig.parseNumberLiteral`
  ASSERTS its input starts with a digit and a config-supplied spelling would
  otherwise have panicked the gate.
- New `import-layering` check: project-declared import DIRECTIONS, configured
  with `[[layering]]` entries (`name`, `from`, `to`, `allow`, `reason`). It is
  the declared-architecture half of the import gate; `imports` keeps the
  structural half (cycles) and the two share the graph and nothing else. Two
  findings from an eda audit on 2026-08-14 motivated it. One upward edge —
  `src/kicad_pcb/import_layout_command.zig` importing
  `src/serve/pcb_layout_import.zig`, because the sidecar-persistence helper it
  wants lives in `serve/` — which is acyclic, so `imports` passed, and which
  `[[boundary]]` could name but not carve an exception in (its `forbidden` side
  is a bare substring with no allow list and no reason). And a 38-file coupling
  surface, `serve/` reaching into placement internals with 35 direct imports of
  a 12.3k-line `optimizer.zig`, which a planned `placement/model.zig`
  extraction wants to ratchet down rather than fix in one commit: violations are
  keyed `<rule>|<from>|<to>` — one per EDGE, not per file — so baseline mode
  freezes today's 38, fails the 39th, and lets the count fall one import at a
  time while a second forbidden import inside an already-frozen file still
  fails. Targets are matched on the RESOLVED, project-relative paths
  `import_graph` already normalizes, so a `to` glob is written once against the
  spelling every importer shares; `std`/`builtin`/`root` and package imports are
  never candidates. `name`, `from`, `to` and `reason` are all required — each
  way of being incomplete reads in the config like an enforced architecture
  while enforcing nothing, so it is a located config error instead. No entries
  is the zero-config default and the check passes without walking a file.
- New check `twin-parity` and its `[[twin]]` table: the committed registry of
  capabilities a project exposes on more than one surface, and whether anything
  proves the surfaces still agree. A CLI subcommand, an HTTP route and an MCP
  tool that all "export the PDF" are three implementations of one answer; they
  share no type, no call and often no file, so nothing in a compiler can see
  they are meant to match, and they drift while every surface keeps passing its
  own tests. Measured in the flagship consumer (eda, 2026-08-14): ~19
  capabilities on 2+ surfaces, exactly ONE with a test asserting the surfaces
  return the same bytes, and the reimplemented pairs had already diverged into
  different BOM-merge gating, different clamps, and different JSON for the same
  field. A rule declaring `parity_test` must have a test whose name CONTAINS
  that string (containment, so a clarifying rename does not red the gate) —
  that one always blocks, since a test named in config and absent from the tree
  is never intentional. A rule declaring none is reported as `twin-uncovered`,
  one row per twin, so today's uncovered set freezes in the baseline and can
  only shrink; `[baseline] deny_growth = ["twin-parity"]` then refuses a row
  that LOSES its test. `surfaces` are free-form labels nothing resolves, but
  fewer than two is a config error — a capability with one implementation has
  nothing to disagree with. The two rows are keyed apart (`parity <name>` /
  `uncovered <name>`) so a frozen uncovered row can never absorb the
  missing-test failure.
- `[[concept]]` gains `require_in` and `literals_from` — the totality direction
  of the same relation, and a family that reads itself. Ownership is permissive
  ("only the owner may spell it") and cannot see the failure that hurts most: a
  mirror the project decided to keep, which quietly stops matching. In eda
  (2026-08-12, commit 51bff373) a DRC kind string was renamed in Zig and the
  viewer's hand-mirrored JS branch went dead — 531 grep-marker tests missed it
  because no marker watched that string, and the JS side's 8-entry `DRC_BLOCK`
  gate table fails PERMISSIVELY on a rename (an unrecognised kind simply stops
  blocking). `require_in` names those mirrors and demands EVERY literal of the
  family in EACH of them; a required mirror is owner-equivalent (never also
  reported as drift), `patterns` are excluded (a wildcard names a shape, not a
  spelling), a comment-only mention does not satisfy it, and a `require_in`
  glob that names no file is itself a violation rather than a vacuous pass.
  `literals_from = { file, fragments }` makes the family TOTAL instead of a
  snapshot: every double-quoted string on a line of `file` carrying ALL the
  fragments joins (union with `literals`, deduped, comment lines blanked first,
  escapes not resolved), so a new enum variant enrols itself and a mirror
  missing it fails with nobody editing guardian.toml. An unreadable file or an
  extraction that yields nothing is a violation — an empty family passes every
  mirror. The config parser gains single-line inline-table values, and the
  concept check now prints one `fix:` line per remedy present instead of one
  shared line that could name the wrong problem.
- The `concept` scan no longer judges comment lines or Zig `test` blocks. The
  first real branch composition on the flagship consumer produced 16 findings
  of which 15 were doc comments and golden-value test assertions — and because
  a violation's identity is `<file>|<concept>`, every benign file frozen into
  the baseline is a file whose REAL drift the gate can never see again, so
  counting those contexts actively weakened the check. A line whose first
  non-whitespace opens `//` is blanked before matching (trailing comments share
  a code line, which still counts whole — judging a mid-line `//` against
  `"https://…"` needs the per-language lexer this check refuses to be), and a
  `.zig` file's `test` declarations are blanked via the shared parse tree — a
  golden literal in a test is the independent witness of the owner's value the
  sync-triangle pattern requires, not a second authority. `analyzeFile` gains
  the optional parse-tree parameter; glob-scanned assets (CSS/JS) pass null and
  keep the pure lexical scan.
- Fix `test-reachability`'s edge model and add a ground-truth counter. Zig
  compiles a file's `test` blocks only when the file's namespace is REFERENCED
  from something the test build analyzes (measured on the pinned toolchain: an
  import bound to an alias the file never mentions compiles no tests), yet the
  check walked every textual `@import` — under which a file counts as reachable
  because some other file merely names it. Reachability now walks the
  referencing edges (`src/ast/test_refs.zig`: `_ = @import(...)`, `_ = alias`,
  `@import(...).member`, `refAllDecls`, and any alias the file uses), the
  default root list gains the conventional dedicated test roots
  (`src/test_root.zig`, `src/tests.zig` — a project that roots its suite apart
  from its executable had its real root read as an unreachable file), and the
  config `exclude` globs now apply to the graph. Because no lexical model can
  see whether the referencing code is itself analyzed, `guardian-check commit`
  records what the suite ACTUALLY ran (the runner's `guardian/test: N test(s)
  selected` line, `src/test_count.zig`) and the check reports the gap between
  that measurement and the model — ground truth, not a second opinion.
- Close the spec check's laundering loophole: a `// spec:` tag in a file whose
  tests never compile no longer satisfies its SPEC.md bullet. Such tags are held
  out of the coverage map (so the bullet reads unverified) and reported as
  `tag in a never-compiled file`. Both checks read one shared analysis
  (`src/ast/test_reach.zig`) rather than each other, and a project where nothing
  was measured — no test root resolved — keeps every tag.
- Fix two `[[concept]]` limitations found while adopting the check: a rule's
  `files` globs now scope THAT rule (previously every rule declaring `files` was
  applied to the union of them all, so a JS-only rule reported Zig offenders),
  and TOML string escapes are resolved (`\"`, `\\`, `\n`, `\r`, `\t`), so
  `literals = ["\"track_track\""]` names a spelling that contains a quote
  instead of matching nothing. An unrecognized escape keeps its backslash.
- Add three RELATIONAL checks — findings that exist only *between* files or
  *between* two writes, which no per-item rule can see:
  - `divergent-const`: one file-scope `const NAME` holding **different** values
    in two or more files. Measured in eda: 10 names in the default mode,
    including `silk_stroke_mm` 0.12 in the Gerber writer and 0.15 in the
    `.kicad_mod` writer (two silkscreens from one board) and
    `max_footprint_bytes` 1 MiB in four readers and 256 KiB in two (loads in the
    editor, fails in the preview). The polarity is the opposite of
    `repeated-string-literal`'s cross-file rule: same name + same value is
    harmless, same name + different value is the risk. Values are compared
    FOLDED, so `16 << 20`, `16 * 1024 * 1024` and `16_777_216` are one value; an
    initializer that does not fold to a number is skipped. Default
    `[divergent_const] mode = "units"` groups only unit-suffixed names, `"all"`
    widens, `ignore_names` exempts. A `/// mirror-of: <path>.zig.<name>`
    annotation converts a deliberate copy into a CHECKED one — exempt from the
    divergence rule, required to equal its referent.
  - `twin-referent`: a comment claiming `mirrors` / `same as` / `verified
    against` a named piece of code that no longer resolves. Measured in eda:
    eight, including a file named after it was split into a directory, a
    hard-coded `file.zig:529-562` line range, and `optimizer.INNER_LAYER_COLORS`
    where the symbol is lowercase. The claim phrase alone is never reported —
    only one followed, in the same sentence, by something code-shaped (a `.zig`
    path, or a dotted chain rooted in a module of the tree). `[twin_referent]
    ignore` silences one claim.
  - `duplicate-json-key`: one function writing the same `"key":` twice into the
    same JSON object — last-wins today, a `SyntaxError` under a strict reader.
    Scoped by object SEGMENT (an emitted `{`/`}`, a call it cannot read, an
    `else` / switch `=>` / `return`) so a function writing two sibling objects,
    or two branches writing one key, stays silent; a literal must also be an
    argument to a call that writes.
  Each runs clean on Guardian's own tree and adds under 40 ms to a whole-tree
  gate. Guardian's own `max_file_bytes` was two different read caps in two
  files; both are now named for what they bound.
- Add the `concept` check and `[[concept]]` config entries: a project names a
  concept (`name`), the literal spellings that model it (`literals`, plus `*`
  wildcard `patterns`), the module those spellings belong to (`owner`), and
  optionally the file set to scan (`files`, any extension) — and every
  occurrence outside an owner is reported as drift. This is Guardian's first
  RELATIONAL check: every other one judges a single item (a file, a function),
  while a duplicated domain constant is only wrong relative to where it belongs
  — which no per-item rule and no `[[ban]]` (Zig identifier chains, no notion of
  a home, never opens a `.css`) can express. Matching is deliberately lexical,
  so one rule reaches the Zig, JS and CSS copies of a single spelling. One
  violation per (file, concept), keyed `<file>|<name>`. No entries = a trivial
  pass.
- Add hysteresis to the hard-cap ratchets — trip → no accept → shrink to
  recover — on by default for `file-size` and `function-length`
  (`[hysteresis] enabled/recover_pct/checks`; `line-length` is supported but
  opt-in). Crossing a hard cap now TRIPS the subject and cannot be accepted:
  `accept` and `GUARDIAN_UPDATE_SNAPSHOT` refuse to record the new entry or to
  raise an existing ceiling, and the failure names the recover line instead of
  an accept command. The trip is then remembered below the cap — the entry
  follows the advisory measurement down (every shrink lands green, even while
  still over the cap), growth blocks, and the entry prunes only once the
  subject reaches the recover line, `recover_pct` under the cap (10000 → 8000
  at the default 20), printing a `recovered:` line when it does. Measured
  motivation: one consumer's three largest files sat at 100–103% of the
  10000-line cap with five ceiling-raising accepts on one file in nine days,
  and a file that dipped under the cap had its entry pruned and regrew freely.
  Relocations still transfer (a `git mv`ed tripped file keeps its entry),
  first-record adoption still grandfathers over-cap subjects, session accept
  notes never cover a trip, diff-scoped runs never clear one they could not
  see, and `enabled = false` restores plain ratchet behavior exactly.
  `debt --live` marks each tripped key with its recover line and what is left
  to fall.
- Stop counting comments and blank lines in the `file-size` metric: a code line
  is now a non-blank, non-comment line outside `test { ... }` blocks. At a frozen
  ceiling, deleting doc comments was the cheapest way to buy headroom, so the
  gate rewarded removing explanation. One function measures it for the gate,
  `size` and `debt`, and no ratchet migration is needed — values that drop
  classify as `improved` and auto-lower on the next write-allowed run.
- Add an un-collapsible pre-trip warning: a file (or function) at ≥95% of its
  HARD cap emits one `NEAR HARD CAP` line, replayed by the run summary even when
  the check's own output is collapsed to `N finding(s) — report-only` by
  `--summary`, `--quiet`, or diff scoping. It is a warning, never a violation:
  no baseline, ratchet or snapshot records it.
- Report distance to a blocking limit as a percentage in `debt --live`'s
  headroom list, and type its `--json` rows with `kind` (`measurement`),
  `direction`, `unit` and `pct`.
- Transfer ratchet entries when their subject relocates (`src/relocation.zig`):
  a git-visible whole-file rename re-keys every entry under the old path, and a
  uniquely-matched extracted item carries its ceiling to the file it moved into,
  printing a `moved:` line. A transfer never raises a ceiling and never adds an
  entry — above the candidate's ceiling, an ambiguous match, and a diff-scoped
  run that cannot confirm the old key went quiet all stay failures, each naming
  the recorded entry and its ceiling. `deny_growth` now compares against the
  relocated recording, so a listed check may move an entry but still not raise
  one.
- Make `debt` decision-ready: send `--json` to stdout instead of stderr (so
  `debt --json | jq` receives it), group rows into violation-debt, inventory
  and score sections carrying explicit `kind`/`direction`/`unit` fields, replace
  the preformatted `note` with a structured `worst {metric, file, item}`, label
  it `worst (baselined)` since it is the stored ceiling rather than a live
  measurement, and add a `--live` (alias of `--current`) headroom section
  listing the items nearest the limit that would block them. Also fixes a
  measurement collision in `debt --current`: `function-length`/`function-size`
  and `file-size`/`line-length` share ratchet-key spellings, so ceilings were
  compared against another check's number.
- Make individual snapshot replacements atomic and checked-in Guardian metadata
  transactional across aggregate runs: a red gate restores pre-run state, and
  warning-only legacy ratchets remain until their advisory finding disappears.
- Restrict green-cache skips to clean worktrees and hash Git HEAD,
  `build.zig.zon`, and project-local `@embedFile` assets.
- Prefer consumer-ready `zig build guardian-accept` remediation, exclude
  comptime parameters from function arity, and name collision files while
  ignoring test-only switches in `repeated-switch-on-enum`.
- Require `GUARDIAN_UPDATE_SNAPSHOT=all` for broad refreshes; reject ambiguous
  `1` and `true` values before any metadata changes.
- Add `zig build guardian -- <args>` as the canonical freshly-built CLI runner.
- Add `required_inputs` preflight globs so missing generated inputs fail before
  analysis can create or prune baselines and snapshots.
- Make file size, function length, and line length advisory at their recommended
  limits, with configurable generous hard limits that remain blocking; warnings
  stay out of baseline and ratchet metadata.
- Make configuration parsing and validation fail closed.
- Harden mutation scoring, sampling, snapshots, and timeout handling.
- Isolate and clean mutation build caches and add a smoke-test stage.
- Add doctor, structured debt, stale-state cleanup, and spec-sync tooling.
- Add named, verified metadata acceptance and downstream maintenance build steps.
- Add strict/agent/safety policy profiles with block, ratchet, and report modes.
- Add optional policy-file drift protection for trusted CI review flows.
- Add shell-free external command gates with declared cache inputs.
- Expand external input globs safely through an exact `{input}` argv token; add
  path-scoped external wall-time, benchmark-regression, and peak-RSS budgets;
  retain assertion locations in optimized consumer test modules; and explain
  when a legacy integration compiled those locations out.
- Add stable spec IDs and repeatable `spec-case` links for additional tests.
- Make assert-density reporting opt-in and cache warning thresholds configurable.
- Remember accepts for the working session: an accepted ratchet check may keep
  growing until the next commit without re-accepting (deny_growth still wins).
- Gate artifact installs on a green suite (`Options.gate_install`, default on)
  without delaying generator/formatter dependencies that prepare analysis
  inputs, and caution on failure that zig-out binaries predate the red run.
- Report file/type-size regressions as volume growth with accept-first guidance,
  distinct from shape regressions whose fix guidance leads.
- Exempt `// spec:` / `// spec-case:` tag lines from the line-length cap — their
  text mirrors SPEC.md bullets, not code style.
- Add continuous integration, scheduled mutation/fuzzing, and release checks.
- Add the `ban` check and `[[ban]]` config entries: a project declares its own
  banned symbol chains (`chain`, optional `paths` / `allow` / `reason`) and they
  are enforced on the same engine as the compiled ban-* checks. Previously every
  ban rule was a comptime table inside a check, so a project could not ban a
  third-party or cross-layer symbol at all. No entries = a trivial pass.
- Fix multiline string arrays being read through a reused buffer: a config with
  two multiline arrays parsed the second one's bytes through the first one's
  slices.
- Make the filtered test loop honest: `guardian.testRunner(dep)` wires a test
  runner that prints `guardian/test: N test(s) selected` before the first test
  and fails a run that selected none (`GUARDIAN_TEST_ALLOW_EMPTY=1` opts out),
  and `guardian.addTestCompileProbe(b, …)` registers `zig build test-compile`,
  a whole-suite `-fno-emit-bin` compile that type-checks every test without
  running any — the tier a filtered run cannot provide, since Zig applies
  `--test-filter` in the compiler and never analyzes what it skips.
