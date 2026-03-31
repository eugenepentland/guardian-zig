# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
5 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add `spec-suggest` — scan for new pub fns not yet in existing SPEC.md and suggest additions
- Add a `--quiet` flag that only prints failures
- Update CLAUDE.md to document spec-init and full onboarding flow
- Explore making file-size exclude patterns support glob syntax

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
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
- Extracted spec-init logic to `spec/init.zig` — check.zig was 557 lines (over 500 limit), split brought it to 424. Added 3 unit tests for extractPubFns. Guardian caught its own file size violation — dogfooding works!

## Observations
- Guardian caught check.zig exceeding the 500-line limit — forced the split. Self-hosting principle validated.
- Now 5 source files, 21 tests total (18 prior + 3 extractPubFns)
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
