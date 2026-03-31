# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking).
4 source files: `check.zig`, `config.zig`, `spec/parser.zig`, `spec/matcher.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add `spec-suggest` — like spec-init but for existing SPEC.md: scan for new pub fns not yet in spec and suggest additions
- Add a `--quiet` flag that only prints failures
- Add build.zig integration test: invoke `zig build` on test-project and verify exit code/output
- Wire `spec-init` into build.zig as an optional step consumers can expose (e.g., `zig build spec-init`)
- Explore making file-size exclude patterns support glob syntax

## Completed
- Refactored to pure build.zig steps — 19 files → 4 files
- Unit tests for boundary matching + fixed glob bug
- Created test fixture project
- Redesign: invisible build integration, hard errors, 1:1 spec mapping
- Unit tests for analyze() (18 tests total)
- Boundary rules for self + test-project violation
- Normalized import paths
- Config edge case tests
- File size checks both src/ and test/
- Color output (TTY-detected)
- `spec-init` subcommand: scans src/ for pub fn declarations, generates starter SPEC.md grouped by module. Refuses to overwrite existing file. Skips `main` and `build` functions. Tested on test-project: found 3 modules, 6 pub fns.

## Observations
- spec-init generates clean output: `## module_name` sections with `- fn_name works correctly` behaviors
- Refusing to overwrite is correct — user should delete SPEC.md explicitly before regenerating
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- 18 unit tests all pass
