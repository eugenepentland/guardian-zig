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
- Normalize boundary import paths (resolve `../` segments) for cleaner violation messages

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching (matchesPattern, extractImports) + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze(): full coverage, unverified, duplicates, unlinked (13 tests total)
- Added boundary rules for guardian-zig itself: `src/spec/*` cannot import `config`
- Added deliberate boundary violation to test-project: core/math.zig imports utils/helpers.zig — correctly detected and reported

## Observations
- Boundary detection works end-to-end: test-project now has 2 intentional failures (spec coverage + boundary violation)
- Guardian self-check: 13/13 specs, all boundaries pass, file sizes OK
- EDA: correctly reports missing SPEC.md (hard error), fmt failures, file size violations
- The boundary violation message shows unresolved `../` paths (`src/core/../utils/helpers.zig`) — could normalize for readability
