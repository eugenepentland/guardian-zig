# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add a `--quiet` flag that only prints failures
- Explore making file-size exclude patterns support glob syntax
- Wire spec-suggest into test-project and EDA build.zig
- Update guardian.toml boundary rules to also protect analysis.zig (spec/* should not import it)

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
- Extracted analysis helpers to `analysis.zig` (matchesPattern, extractImports, normalizePath, containsIgnoreCase, walkBoundaries) + containsIgnoreCase test. Guardian caught check.zig at 511 lines — second time dogfooding forced a split. check.zig now 353 lines.

## Observations
- Guardian has now caught its own file size violations TWICE — both times forcing productive refactoring
- 6 source files, 22 tests total (7 in analysis.zig, all moved from check.zig + 1 new containsIgnoreCase)
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
