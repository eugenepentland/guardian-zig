# Changelog

All notable Guardian changes are recorded here. Releases follow semantic
versioning; consumers should pin a tag and Zig package hash rather than a live
sibling checkout.

## 0.2.0 - Unreleased

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
