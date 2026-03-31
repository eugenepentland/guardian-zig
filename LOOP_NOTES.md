# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
5 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add a `--quiet` flag that only prints failures
- Explore making file-size exclude patterns support glob syntax
- Wire spec-suggest into EDA and test-project build.zig as `zig build spec-suggest`
- Consider adding a unit test for containsIgnoreCase

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
- `spec-init` subcommand + wired into build.zig
- Extracted spec-init logic to `spec/init.zig` + extractPubFns tests (21 tests)
- Updated CLAUDE.md with full onboarding docs
- `spec-suggest` subcommand: scans for pub fns not mentioned in existing SPEC.md behaviors, case-insensitive matching. Wired into `zig build spec-suggest`. Advisory (not a hard check). Tested: guardian self (8 internal fns uncovered), test-project (4 fns not in natural-language spec).

## Observations
- Spec lifecycle is now complete: `spec-init` creates, `spec-suggest` maintains, `spec` check enforces
- Case-insensitive matching works well: "add" matches "Adds two numbers" — but conjugation mismatches remain (e.g., "multiply" vs "Multiplies"). This is acceptable for an advisory tool.
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 21 unit tests all pass
- The priority list is mostly refinements now — core feature set is solid
