# Guardian for Zig

## Overview

A verification gate tool for AI-generated Zig code. Runs a 9-stage pipeline and auto-commits on success or writes GUARDIAN_FEEDBACK.md on failure.

## Build & Run

```bash
# Build
zig build

# Run tests
zig build test

# Check a project
zig build run -- check --intent "description" [target-dir]

# Self-check
zig build run -- check --intent "description" .
```

## Project Structure

```
src/
  main.zig              # CLI entry, arg parsing, orchestration
  config.zig            # TOML subset parser + Config struct
  stage.zig             # StageResult type
  pipeline.zig          # Sequential stage runner
  shell.zig             # Child process wrapper
  git.zig               # Git operations
  feedback.zig          # GUARDIAN_FEEDBACK.md writer
  spec/
    parser.zig          # SPEC.md parser
    matcher.zig         # // spec: tag scanner
  stages/
    change.zig          # Stage 1: Change classification
    spec_coverage.zig   # Stage 2: Spec coverage
    compilation.zig     # Stage 3: zig build
    format.zig          # Stage 4: zig fmt --check
    file_size.zig       # Stage 5: Line count limits
    dead_code.zig       # Stage 6: Unused code detection
    boundaries.zig      # Stage 7: @import boundary enforcement
    tests.zig           # Stage 8: zig build test
    mutation.zig        # Stage 9: Mutation testing
```

## Config (guardian.toml)

```toml
spec_file = "SPEC.md"
min_spec_coverage = 100
min_test_coverage = 80
min_mutation_score = 90
max_file_lines = 500
mutation_exclude = []
file_size_exclude = []

[[boundary]]
module = "src/stages/*"
forbidden = ["shell"]
```

## Workflow

Instead of running `zig build`, `zig build test`, etc. directly, use:

```bash
guardian-zig check --intent "description of changes" [target-dir]
```

This validates spec coverage, compilation, formatting, file sizes, dead code, boundaries, tests, and mutation testing in sequence. On success it auto-commits.
