# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
4 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`.
Test fixture at `test-project/` exercises all checks.

## Recent Changes (redesign)
- Guardian now runs on every `zig build`, not a separate step
- Missing SPEC.md is a hard error with clear instructions
- 1:1 strict spec-test mapping — duplicate tags detected
- 13/13 spec behaviors covered on self

## Priority Ideas
- Add boundary rules for guardian-zig itself in guardian.toml to exercise that check on self
- Support test/ directory in file size checks (currently only checks src/)
- Add color output (detect TTY, use ANSI codes for pass/fail)
- Add a `--quiet` flag that only prints failures
- Test fixture: add a file that deliberately violates a boundary rule to verify detection works
- Config edge case tests: malformed TOML, missing values, multi-line arrays

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching (matchesPattern, extractImports) + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze(): full coverage, unverified behaviors, duplicate tags, unlinked tags (4 new tests, 13 total)

## Observations
- 13 unit tests all pass
- All 3 projects produce correct output: self (pass), test-project (expected spec failure), EDA (expected fmt/size/spec failures)
- Duplicate tag detection works correctly in tests
- The analyze() tests caught no bugs this round — the implementation was already correct
