# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Explore making file-size exclude patterns support glob syntax
- Consider adding SPEC.md entries for analysis.zig and spec/init.zig public functions
- Add an integration-style test: verify spec check exit code on known-bad directory
- Update test-project and EDA build.zig to also use --quiet
- Update CLAUDE.md to document --quiet flag

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
- Extended boundary rules: spec/* cannot import config or analysis
- Wired spec-suggest into all consumer projects
- Added `--quiet` / `-q` flag: suppresses pass messages, only prints failures. Used by default in guardian-zig's own build.zig so successful builds are completely silent.

## Observations
- `zig build` is now truly invisible when everything passes — zero output
- Failures still print clearly with full details even in quiet mode
- All 3 projects verified: self (silent pass), test-project (expected failures shown), EDA (expected failures shown)
- 22 unit tests all pass
