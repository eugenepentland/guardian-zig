# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Look into publishing guardian as a proper zig package (URL-based dependency via GitHub)
- Consider a `spec-diff` command
- Use matchGlob for boundary module patterns too (currently uses matchesPattern with different syntax)

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
- Extracted modules to spec/init.zig and analysis.zig
- Updated CLAUDE.md, extended boundary rules, wired spec-suggest everywhere
- `--quiet` flag in all build.zig files
- Expanded SPEC.md to 17/17 behaviors
- Integration tests: walkBoundaries + walkFileSize + exclude on test-project
- Fixed file-size exclude bug
- Improved error messages with summary counts
- **Glob syntax for file-size exclude**: `*` matches any sequence of chars. Patterns without `*` fall back to substring match (backward compatible). Examples: `"src/generated/*"`, `"*/output.zig"`, `"src/*/test_*.zig"`. Added matchGlob + 10 test cases. 27 tests total.

## Observations
- matchGlob is simple (~30 lines) but handles all practical cases: leading/trailing/middle wildcards, multiple wildcards, substring fallback
- Backward compatible: existing configs with plain substring patterns still work
- All 3 projects verified: self (silent pass), test-project (expected failures), EDA (expected failures)
- 27 tests, 17/17 spec coverage
