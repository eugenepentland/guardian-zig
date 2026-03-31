# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Priority Ideas
- Look into publishing guardian as a proper zig package (URL-based dependency via GitHub)
- Explore making file-size exclude patterns support glob syntax
- Consider a `spec-diff` command

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
- Integration tests: walkBoundaries + walkFileSize + exclude on test-project
- Fixed file-size exclude bug (continue targeting wrong loop)
- Improved error messages with summary counts: `spec coverage FAILED (3/5 covered, 2 unverified, 0 unlinked, 0 duplicate)`, `file size FAILED (6 file(s) over 500 line limit)`, `boundary check FAILED (1 violation(s))`. 26 tests total.

## Observations
- Error messages now give instant context — you know the scale of the problem without reading details
- All 3 projects verified: self (silent pass), test-project (improved error output), EDA (improved error output)
- 26 tests, 17/17 spec coverage
- Tool is very mature now. Core features, tests, docs, polish all done. Main remaining work is publishing.
