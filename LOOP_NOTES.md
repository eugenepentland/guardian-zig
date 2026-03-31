# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Explore making file-size exclude patterns support glob syntax
- Consider a `spec-diff` command
- Look into publishing guardian as a proper zig package (URL-based dependency)
- Consider adding a file-size exclude integration test (verify exclude patterns work on real files)

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
- Extracted spec-init to `spec/init.zig`, analysis helpers to `analysis.zig`
- Updated CLAUDE.md with full onboarding docs
- Extended boundary rules, wired spec-suggest everywhere
- `--quiet` flag in all build.zig files
- Expanded SPEC.md to 17/17 behaviors
- Integration test: walkBoundaries on test-project
- Moved walkFileSize to analysis.zig + 2 integration tests: high limit (no violations) and low limit (finds 3+ violations). check.zig now 301 lines. 25 tests total.

## Observations
- check.zig keeps shrinking as analysis logic moves to analysis.zig (353 → 301 lines)
- Integration tests on test-project are high-confidence: they walk real dirs, not mocked data
- All 3 projects verified: self (silent pass), test-project (expected failures), EDA (expected failures)
- 25 unit tests all pass
