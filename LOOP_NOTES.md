# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
Consumers wire it in with one line: `guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{})`.

Source layout:
- `src/check.zig` — main entry / dispatch
- `src/cli/` — command registry and shared types
- `src/checks/` — one file per check (17 hard-block checks + 1 generator)
- `src/spec/` — SPEC.md parser, tag matcher, spec-init generator
- `src/ast/` — Zig AST helpers (pub-fn / pub-decl / import scans)
- `src/walk.zig` — error-propagating .zig file walker
- `src/snapshot.zig` — shared snapshot (write/diff) primitive used by pub-api / panic-budget / spec-drift
- `src/build_helper.zig` — re-exported `addAllChecks` for consumers
- `src/config.zig` — guardian.toml parser

Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config`.

## Status: SHIPPED

All 14 of the 16 originally-proposed checks landed plus the original 4 (spec, file-size, boundaries, spec-init).
2 deferred with explicit reasoning:
- `spec-init++` — landed as a focused upgrade: one bullet per pub fn, drop the redundant comma-list summary.
- `allocator-hygiene` — formally deferred (see RESEARCH-BRIEF §10). Needs arena-aware ownership analysis the audit
  flagged as undecidable with a token-pattern approach.

## Final Stats
- 30 source files, ~4000 lines of Zig
- 17 hard-block checks + 1 generator (`spec-init`)
- 70 tests, 38 spec-tags / 39 SPEC.md behaviors (1:1 covered)
- 44 commits

## Hard-block check inventory
spec · spec-quality · spec-drift · file-size · function-size · boundaries · usingnamespace-ban · naming · doc-comments ·
imports (cycle detection) · pub-api-surface · panic-budget · catch-discipline · error-discipline ·
cognitive-complexity · anytype-budget · dead-pub.

Three checks are snapshot-based (pub-api-surface, panic-budget, spec-drift) — diff-against-baseline; commit the
snapshot or the build fails.

## Configurable knobs
- `[complexity] max_score` (default 15; Guardian's own toml: 50 for dispatch-heavy state machines)
- `[anytype_budget] max_per_file` (default 2; Guardian's own toml: 6 for the logger pattern in `reporter.zig`)
- `max_file_lines` (default 500), `file_size_exclude` glob list
- `spec_quality.forbidden_phrases`, `spec_quality.enabled`
- `[[boundary]]` rules

## Publishing
Push to GitHub; consumers depend via URL in `build.zig.zon`, then add the one-line `guardian.addAllChecks(...)`
call in `build.zig`. See README for the canonical snippet.
