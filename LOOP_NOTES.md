# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
4 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Support test/ directory in file size checks (currently only checks src/)
- Add color output (detect TTY, use ANSI codes for pass/fail)
- Add a `--quiet` flag that only prints failures
- Consider spec lifecycle: `spec-suggest` subcommand to analyze code and suggest SPEC.md entries

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching (matchesPattern, extractImports) + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze(): full coverage, unverified, duplicates, unlinked
- Added boundary rules for guardian-zig itself + boundary violation in test-project
- Normalized import paths in boundary violations
- Config edge case tests: comments/blanks ignored, malformed values fall back to defaults, multiple [[boundary]] sections, empty arrays. 18 tests total.

## Observations
- Malformed integer values correctly fall back to defaults (parseInt catch)
- Unquoted string values correctly fall back to defaults (parseString returns null)
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 18 unit tests all pass
