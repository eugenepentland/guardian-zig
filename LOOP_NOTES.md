# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
5 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add `spec-suggest` — scan for new pub fns not yet in existing SPEC.md and suggest additions
- Add a `--quiet` flag that only prints failures
- Explore making file-size exclude patterns support glob syntax
- Consider adding a `spec-check` subcommand that can run standalone (not just as build step) for CI pipelines

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
- `spec-init` subcommand + wired into build.zig
- Extracted spec-init logic to `spec/init.zig` + extractPubFns tests (21 tests total)
- Updated CLAUDE.md: added onboarding section, spec-init docs, checks summary table, updated project structure. AI agents now have clear instructions for the full workflow.

## Observations
- CLAUDE.md now has a clear 6-step onboarding guide that any AI agent can follow
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 21 unit tests all pass
- The priority list is getting thin — most core features are in. Remaining ideas are refinements.
