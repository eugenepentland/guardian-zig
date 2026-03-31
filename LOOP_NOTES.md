# Guardian Loop Notes

## Priority Ideas
- Refine mutation skip rules — catch/orelse mutators are too noisy on error handling boilerplate, generating tons of surviving mutations that aren't meaningful. Skip lines with `catch {}`, `catch continue`, `catch return` patterns.
- Add more unit tests to boost mutation kill rate — config parsing, change classification, boundary matching, mutation generation all need dedicated tests
- Add boundary rules for guardian-zig itself — stages/ should not import shell.zig directly, only main.zig should orchestrate shell access
- Add --skip-mutation flag for faster iteration during development
- Support test/ directory in file size checks (currently only checks src/)
- Improve dead code stage — Zig compiler catches unused locals as errors, but could grep for unreferenced pub functions
- Add a summary line count to mutation testing output (e.g., "Tested 45 mutations across 8 files")
- Make mutation testing respect .gitignore (don't mutate generated files)
- Add color output support (detect TTY and use ANSI colors for pass/fail)

## Completed
(none yet)

## Observations
(none yet)
