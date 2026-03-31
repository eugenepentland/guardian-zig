# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
4 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Config edge case tests: malformed TOML, missing values, multi-line arrays
- Support test/ directory in file size checks (currently only checks src/)
- Add color output (detect TTY, use ANSI codes for pass/fail)
- Add a `--quiet` flag that only prints failures

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching (matchesPattern, extractImports) + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze(): full coverage, unverified, duplicates, unlinked
- Added boundary rules for guardian-zig itself + boundary violation in test-project
- Normalized import paths in boundary violations: `src/core/../utils/foo.zig` → `src/utils/foo.zig`. Added normalizePath() + 4 test cases. 14 tests total.

## Observations
- Boundary violation message now clean: `src/core/math.zig: forbidden import 'src/utils/helpers.zig' (rule: src/core/*)`
- All 3 projects verified: self (pass), test-project (expected spec + boundary failures), EDA (expected spec/fmt/size failures)
- 14 unit tests all pass
