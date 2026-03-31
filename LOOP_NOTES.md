# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
4 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add color output (detect TTY, use ANSI codes for pass/fail)
- Add a `--quiet` flag that only prints failures
- Consider spec lifecycle: `spec-suggest` subcommand to analyze code and suggest SPEC.md entries
- Add build.zig integration test: a test that invokes `zig build` on test-project and verifies the exit code and output
- Consider checking build.zig itself for file size (currently only .zig files in src/ and test/)

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching (matchesPattern, extractImports) + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze(): full coverage, unverified, duplicates, unlinked
- Added boundary rules for guardian-zig itself + boundary violation in test-project
- Normalized import paths in boundary violations
- Config edge case tests: comments/blanks, malformed values, multiple boundaries, empty arrays (18 tests)
- File size now checks both src/ and test/ directories. Gracefully skips missing dirs. Fixed hardcoded `src/` prefix in violation messages.

## Observations
- All 3 projects verified: self (pass), test-project (expected spec + boundary failures), EDA (expected spec/fmt/size failures)
- EDA file size violations correctly show `src/` prefix from the walk, not hardcoded
- test-project has no test/ dir — file size check gracefully skips it
- 18 unit tests all pass
