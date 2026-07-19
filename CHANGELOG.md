# Changelog

All notable Guardian changes are recorded here. Releases follow semantic
versioning; consumers should pin a tag and Zig package hash rather than a live
sibling checkout.

## 0.2.0 - Unreleased

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
