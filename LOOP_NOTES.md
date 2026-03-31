# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis` — enforced on every build.

## Priority Ideas
- Add a `--quiet` flag that only prints failures
- Explore making file-size exclude patterns support glob syntax
- Consider adding SPEC.md entries for analysis.zig and spec/init.zig public functions
- Add an integration-style test: verify spec check exit code on known-bad directory

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
- Extended boundary rules: spec/* cannot import config or analysis
- Wired `spec-suggest` into test-project and EDA build.zig as `zig build spec-suggest`. All consumer projects now have full spec lifecycle: init, suggest, check.

## Observations
- All consumer projects now have `zig build spec-init` and `zig build spec-suggest`
- EDA's spec-suggest correctly errors when no SPEC.md exists (directs user to run spec-init first)
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 22 unit tests all pass
- The tool is feature-complete for the core use case. Remaining items are polish.
