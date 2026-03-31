# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps — no standalone binary. 4 source files:
- `check.zig` — spec, file-size, boundary analysis executable
- `config.zig` — guardian.toml parser
- `spec/parser.zig` — SPEC.md parser
- `spec/matcher.zig` — // spec: tag scanner

Test fixture at `test-project/` exercises all checks with intentional failures.

## Priority Ideas
- Add more unit tests — spec matcher analyze(), config edge cases, file size walk logic
- Add boundary rules for guardian-zig itself in guardian.toml
- Support test/ directory in file size checks (currently only checks src/)
- Add color output (detect TTY, use ANSI codes for pass/fail markers)
- Consider a `change-classification` check subcommand using git diff
- Add a `--quiet` flag that only prints failures (for CI use)
- Test fixture: add a test case that intentionally violates a boundary rule to verify detection

## Completed
- Refine mutation skip rules (pre-refactor)
- Refactored to pure build.zig steps — 19 files → 4 files
- Added unit tests for boundary matching + fixed glob pattern bug
- Created test fixture project — exercises spec coverage (3/5 covered), file size (50 line limit), boundaries (core/ can't import utils/), compile/test/fmt. Validated on all 3 projects: self (pass), test-project (expected spec failure), EDA (runs correctly, known fmt/size failures)

## Observations
- All 3 projects produce correct output after every change
- test-project boundary check passes because core/math.zig and core/strings.zig don't import utils/ — could add a deliberate violation test
- EDA: 40/40 tests pass, fmt and file-size checks correctly flag issues
- 9 unit tests pass in guardian-zig itself
