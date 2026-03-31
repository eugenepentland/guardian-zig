# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
4 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add `spec-suggest` — scan for new pub fns not yet in existing SPEC.md and suggest additions (diff against current spec)
- Add a `--quiet` flag that only prints failures
- Add build.zig integration test: invoke `zig build` on test-project and verify exit code/output
- Explore making file-size exclude patterns support glob syntax
- Update CLAUDE.md to document spec-init and the full onboarding flow
- Add unit tests for extractPubFns and collectModules

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze() (18 tests total)
- Boundary rules for self + test-project violation
- Normalized import paths
- Config edge case tests
- File size checks both src/ and test/
- Color output (TTY-detected)
- `spec-init` subcommand + wired into build.zig as `zig build spec-init` for all consumer projects. Tested on EDA: found 17 modules, generated full skeleton.

## Observations
- `zig build spec-init` on EDA produces a comprehensive 17-module SPEC.md skeleton — very useful for onboarding
- The generated behaviors use `- fn_name works correctly` as placeholder text — user edits to describe actual behavior
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 18 unit tests all pass
