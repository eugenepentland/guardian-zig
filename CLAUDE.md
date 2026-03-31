# Guardian for Zig

## Overview

A verification gate tool for AI-generated Zig code. Integrates into any Zig project's `build.zig` as a package dependency. Runs a multi-stage pipeline and auto-commits on success or writes GUARDIAN_FEEDBACK.md on failure.

## Build & Run

```bash
# Build
zig build

# Run tests
zig build test

# Standalone check
zig build run -- check --intent "description" [target-dir]
```

## Integration (Recommended)

Add guardian as a dependency in your project's `build.zig.zon`:

```zig
.dependencies = .{
    .guardian = .{
        .path = "../guardian-zig",  // or git URL
    },
},
```

Add the guardian step to your `build.zig`:

```zig
// Guardian verification step
const guardian_dep = b.dependency("guardian", .{
    .target = target,
    .optimize = optimize,
});

const intent = b.option([]const u8, "intent", "Guardian intent message");

const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });

const guardian_run = b.addRunArtifact(guardian_dep.artifact("guardian"));
guardian_run.addArgs(&.{ "check", "--intent", intent orelse "(no intent)", "--build-verified" });
guardian_run.setCwd(b.path("."));

// Guardian runs after compile + test + fmt pass
guardian_run.step.dependOn(b.getInstallStep());
guardian_run.step.dependOn(&run_tests.step);
guardian_run.step.dependOn(&fmt_check.step);

const guardian_step = b.step("guardian", "Run guardian verification pipeline");
guardian_step.dependOn(&guardian_run.step);
```

Then run:
```bash
zig build guardian -Dintent="description of changes"
```

The build graph ensures compilation, tests, and formatting pass before guardian runs its analysis stages (spec coverage, file size, boundaries, change classification, mutation testing) and auto-commits.

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
    change.zig          # Change classification
    spec_coverage.zig   # Spec coverage
    compilation.zig     # zig build (standalone mode only)
    format.zig          # zig fmt --check (standalone mode only)
    file_size.zig       # Line count limits
    dead_code.zig       # Unused code detection
    boundaries.zig      # @import boundary enforcement
    tests.zig           # zig build test (standalone mode only)
    mutation.zig        # Mutation testing
```

## Modes

- **Standalone**: `guardian check --intent "..."` — runs all 9 stages including compile/test/fmt
- **Build-verified**: `guardian check --intent "..." --build-verified` — skips compile/test/fmt (handled by build.zig dependencies)
