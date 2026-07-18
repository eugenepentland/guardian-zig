# Changelog

All notable Guardian changes are recorded here. Releases follow semantic
versioning; consumers should pin a tag and Zig package hash rather than a live
sibling checkout.

## 0.2.0 - Unreleased

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
  and caution on failure that zig-out binaries predate the red run.
- Report file/type-size regressions as volume growth with accept-first guidance,
  distinct from shape regressions whose fix guidance leads.
- Exempt `// spec:` / `// spec-case:` tag lines from the line-length cap — their
  text mirrors SPEC.md bullets, not code style.
- Add continuous integration, scheduled mutation/fuzzing, and release checks.
