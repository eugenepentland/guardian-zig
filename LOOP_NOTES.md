# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Explore making file-size exclude patterns support glob syntax
- Consider adding SPEC.md entries for analysis.zig and spec/init.zig public functions
- Add an integration-style test: verify spec check exit code on known-bad directory
- Consider a `spec-diff` command: show what changed between current SPEC.md and what spec-init would generate

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
- `--quiet` flag + used by default in all build.zig files (guardian, test-project, EDA). CLAUDE.md integration example updated.

## Observations
- All 3 projects now completely silent on success — only failures show
- EDA: previously showed "no boundary rules configured" pass message, now silent
- 22 unit tests all pass
- Tool is feature-complete and polished. Remaining items are minor refinements.
