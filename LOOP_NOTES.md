# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Look into publishing guardian as a proper zig package (URL-based dependency via GitHub)
- Consider a `spec-diff` command
- The tool is feature-complete. Most value now comes from using it on real projects and fixing issues that surface.

## Completed
- Refactored to pure build.zig steps
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze(), boundary matching, config parsing, extractPubFns
- Boundary rules for self + test-project violation
- Normalized import paths
- File size checks both src/ and test/
- Color output (TTY-detected)
- `spec-init` and `spec-suggest` subcommands
- Extracted modules to spec/init.zig and analysis.zig
- `--quiet` flag in all build.zig files
- Expanded SPEC.md to 17/17 behaviors
- Integration tests on test-project (boundaries, file size, exclude)
- Fixed file-size exclude bug (continue targeting wrong loop)
- Improved error messages with summary counts
- Glob syntax for file-size exclude and boundary patterns
- Unified pattern matching (removed matchesPattern, everything uses matchGlob)
- Documented glob pattern syntax in CLAUDE.md config section with examples

## Observations
- CLAUDE.md now documents pattern syntax: `*` wildcard, substring fallback, examples for both file_size_exclude and boundary rules
- 26 tests, 17/17 spec coverage
- All 3 projects verified: self (silent pass), test-project (expected failures), EDA (expected failures)
- Tool is mature — 21 loop iterations, from initial scaffold to polished product
