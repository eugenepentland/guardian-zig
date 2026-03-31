# Guardian Loop Notes

## Architecture
Guardian is pure build.zig steps. Runs on every `zig build` (invisible, hard-blocking, silent on success).
6 source files, 1408 lines total: `check.zig`, `config.zig`, `analysis.zig`, `spec/parser.zig`, `spec/matcher.zig`, `spec/init.zig`.
Test fixture at `test-project/` exercises all checks with intentional failures.

Boundary rules: `src/spec/*` cannot import `config` or `analysis`.

## Status: COMPLETE

The tool is feature-complete, tested, documented, and publish-ready. No further loop iterations needed.

To publish: push the repo to GitHub, then projects can depend on it via URL in build.zig.zon.

## Final Stats
- 26 tests, 17/17 spec coverage, 35 commits
- 6 source files, 1408 lines of Zig
- All 3 projects verified: self (pass), test-project (expected failures), EDA (expected failures)
- Files: README.md, LICENSE (MIT), CLAUDE.md, SPEC.md, .gitignore, guardian.toml

## Completed (all iterations)
- Pure build.zig integration (invisible, hard-blocking)
- Spec coverage check with 1:1 enforcement + duplicate detection
- File size check (src/ + test/) with glob exclude patterns
- Boundary check with @import analysis and path normalization
- spec-init (generate SPEC.md from code) + spec-suggest (find uncovered fns)
- Color output (TTY-detected), --quiet flag, summary counts in errors
- Unified matchGlob pattern syntax across all config
- Comprehensive tests: unit (config, parser, matcher, analysis) + integration (real directory walks)
- Self-hosting: guardian verifies itself on every build
- Test fixture project exercising all checks
- Full documentation: README, CLAUDE.md, SPEC.md, inline comments
