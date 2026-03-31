# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Explore making file-size exclude patterns support glob syntax
- Consider a `spec-diff` command: show what changed between current SPEC.md and what spec-init would generate
- Look into publishing guardian as a proper zig package (with URL-based dependency support)
- Consider adding a walkFileSize integration test using test-project (similar to boundary test)

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
- Extended boundary rules
- Wired spec-suggest into all consumer projects
- `--quiet` flag in all build.zig files
- Expanded SPEC.md to 17/17 behaviors
- Integration test: walkBoundaries on test-project's actual directory, verifies it detects core/math.zig importing utils. First test that exercises real file I/O against the test fixture. 23 tests total.

## Observations
- The integration test walks real directories — not just testing string logic but actual file scanning
- test-project serves double duty: exercises guardian checks as a build step AND provides test data for unit/integration tests
- All 3 projects verified: self (silent pass), test-project (expected failures), EDA (expected failures)
- 23 unit tests all pass
