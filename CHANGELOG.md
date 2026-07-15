# Changelog

All notable Guardian changes are recorded here. Releases follow semantic
versioning; consumers should pin a tag and Zig package hash rather than a live
sibling checkout.

## 0.2.0 - Unreleased

- Make configuration parsing and validation fail closed.
- Harden mutation scoring, sampling, snapshots, and timeout handling.
- Isolate and clean mutation build caches and add a smoke-test stage.
- Add doctor, structured debt, stale-state cleanup, and spec-sync tooling.
- Add continuous integration, scheduled mutation/fuzzing, and release checks.
