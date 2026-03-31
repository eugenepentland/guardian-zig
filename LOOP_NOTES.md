# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis` — enforced on every build.

## Priority Ideas
- Add a `--quiet` flag that only prints failures
- Explore making file-size exclude patterns support glob syntax
- Wire spec-suggest into test-project and EDA build.zig
- Consider adding SPEC.md entries for analysis.zig and spec/init.zig public functions (currently 8 uncovered per spec-suggest)
- Add an integration-style test: verify spec check exit code on a directory with known missing coverage

## Completed
- Refactored to pure build.zig steps
- Unit tests for boundary matching + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze()
- Boundary rules for self + test-project violation
- Normalized import paths
- Config edge case tests
- File size checks both src/ and test/
- Color output (TTY-detected)
- `spec-init` and `spec-suggest` subcommands
- Extracted spec-init logic to `spec/init.zig`
- Updated CLAUDE.md with full onboarding docs
- Extracted analysis helpers to `analysis.zig` + tests
- Extended boundary rules: spec/* cannot import config OR analysis. Validates architectural layering.

## Observations
- Boundary rules now protect the spec/ layer from depending on higher-level modules
- Architecture: check.zig (top) → analysis.zig + config.zig (middle) → spec/* (bottom). Boundaries enforce this.
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 22 unit tests all pass
- Priority list is mostly polish — core feature set is comprehensive
