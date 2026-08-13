# Changelog

All notable Guardian changes are recorded here. Releases follow semantic
versioning; consumers should pin a tag and Zig package hash rather than a live
sibling checkout.

## 0.2.0 - Unreleased

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
