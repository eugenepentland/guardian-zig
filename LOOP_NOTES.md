# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Look into publishing guardian as a proper zig package (URL-based dependency via GitHub)
- Consider a `spec-diff` command
- Update CLAUDE.md config docs to show glob syntax examples for file_size_exclude

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
- Integration tests on test-project (boundaries, file size, exclude)
- Fixed file-size exclude bug
- Improved error messages with summary counts
- Glob syntax for file-size exclude patterns
- **Unified pattern matching**: removed `matchesPattern`, boundary rules now use `matchGlob` — same `*` wildcard syntax as file-size excludes. One pattern language for all config. Removed 12 lines of dead code. 26 tests total (merged 3 matchesPattern tests into 1 matchGlob test).

## Observations
- Config now uses one consistent pattern syntax everywhere: `*` = wildcard, no `*` = substring match
- Removed matchesPattern entirely — matchGlob handles all boundary cases correctly
- All 3 projects verified: self (silent pass), test-project (expected failures), EDA (expected failures)
- 26 tests, 17/17 spec coverage
