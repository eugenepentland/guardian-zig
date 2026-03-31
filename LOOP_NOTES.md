# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
4 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add a `--quiet` flag that only prints failures
- Consider spec lifecycle: `spec-suggest` subcommand to analyze code and suggest SPEC.md entries
- Add build.zig integration test: a test that invokes `zig build` on test-project and verifies exit code/output
- Consider a `spec init` subcommand to generate starter SPEC.md from existing pub fn signatures
- Explore making the file-size exclude patterns support glob syntax (currently substring match)

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching (matchesPattern, extractImports) + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze(): full coverage, unverified, duplicates, unlinked
- Added boundary rules for guardian-zig itself + boundary violation in test-project
- Normalized import paths in boundary violations
- Config edge case tests (18 tests total)
- File size now checks both src/ and test/
- Color output: green `guardian:` prefix on pass, red on fail. TTY-detected via `File.stderr().isTty()` — no ANSI codes when piped.

## Observations
- Color output is invisible in build system output (piped, not TTY) but will show in direct terminal runs
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 18 unit tests all pass
- No ANSI escape code leakage in piped/captured output — clean grep-able messages
