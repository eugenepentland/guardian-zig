# Guardian Loop Notes

## Priority Ideas
- Add more unit tests to boost mutation kill rate — config parsing, change classification, boundary matching, mutation generation all need dedicated tests. This is the biggest lever for improving mutation score.
- Add boundary rules for guardian-zig itself — stages/ should not import shell.zig directly, only main.zig and mutation.zig should use shell
- Add --skip-mutation flag for faster iteration during development
- Support test/ directory in file size checks (currently only checks src/)
- Improve dead code stage — Zig compiler catches unused locals as errors, but could grep for unreferenced pub functions
- Add a summary line count to mutation testing output (e.g., "Tested 45 mutations across 8 files")
- Make mutation testing respect .gitignore (don't mutate generated files)
- Add color output support (detect TTY and use ANSI colors for pass/fail)
- Consider skipping mutation of lines inside `if (std.mem.eql(` patterns — these are string comparisons in config/arg parsing that generate trivially surviving mutations

## Completed
- Refine mutation skip rules — added `shouldSkipErrorHandling()` that skips lines ending with `catch {}`, `catch continue`, `catch return`, `orelse return`, `orelse &.{}`, etc. Reduced surviving mutations from 65+ to 35 (nearly 50% reduction). The catch→unreachable mutator was the biggest source of noise.

## Observations
- Most remaining survivors are in main.zig (arg parsing comparisons), config.zig (TOML parsing), and spec/parser.zig (markdown parsing) — all areas with minimal test coverage
- The mutation score is 0% because no mutations are killed by tests yet — need to add targeted unit tests
- Build-verified mode works well for the EDA integration — compile/test/fmt are handled by the build graph, guardian only does analysis
