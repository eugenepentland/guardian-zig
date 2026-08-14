# Changelog

All notable Guardian changes are recorded here. Releases follow semantic
versioning; consumers should pin a tag and Zig package hash rather than a live
sibling checkout.

## 0.2.0 - Unreleased

<<<<<<< HEAD
<<<<<<< HEAD
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
=======
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
>>>>>>> claude/shadowed-const

=======
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
>>>>>>> claude/import-layering
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
