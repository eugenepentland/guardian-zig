# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Explore making file-size exclude patterns support glob syntax (currently substring match)
- Consider a `spec-diff` command
- Look into publishing guardian as a proper zig package (URL-based dependency)

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
- Integration tests: walkBoundaries + walkFileSize on test-project
- **Fixed file-size exclude bug**: `continue` inside `for (excludes)` was continuing the excludes loop, not the outer file iterator. Files matching exclude patterns were NOT actually being skipped. Fixed with labeled block. Added integration test that verifies exclude actually works. 26 tests total.

## Observations
- The exclude bug was a real logic error that existed since the feature was added — `continue` in a nested for doesn't do what you'd expect. Test-driven iteration found it.
- 26 tests, 17/17 spec coverage
- All 3 projects verified: self (silent pass), test-project (expected failures), EDA (expected failures)
- Priority list is thin — mostly publishing/polish
