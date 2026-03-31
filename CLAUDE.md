# Guardian for Zig

## Overview

Build-step quality gates for Zig projects. Integrates into `build.zig` as a package dependency — no external tool needed. Runs `zig build guardian` to verify compilation, tests, formatting, spec coverage, file sizes, and import boundaries.

## Build & Run

```bash
zig build              # build guardian-check executable
zig build test         # run unit tests
zig build guardian     # run full quality gate on self
```

## Integration

Add guardian as a dependency in your `build.zig.zon`:

```zig
.guardian = .{
    .path = "../guardian-zig",  // or git URL
},
```

Add the guardian step to your `build.zig`:

```zig
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
const check_exe = guardian_dep.artifact("guardian-check");

const guardian_step = b.step("guardian", "Run guardian verification pipeline");

// Compile + test + fmt (native build steps)
guardian_step.dependOn(b.getInstallStep());
guardian_step.dependOn(&run_tests.step);
guardian_step.dependOn(&b.addFmt(.{ .paths = &.{"src"}, .check = true }).step);

// Spec coverage, file size, boundaries (guardian checks)
for ([_][]const u8{ "spec", "file-size", "boundaries" }) |cmd| {
    const run = b.addRunArtifact(check_exe);
    run.addArgs(&.{ cmd, "." });
    run.setCwd(b.path("."));
    guardian_step.dependOn(&run.step);
}
```

Then: `zig build guardian`

## Project Structure

```
src/
  check.zig          # Analysis executable (spec, file-size, boundaries)
  config.zig         # guardian.toml parser
  spec/
    parser.zig       # SPEC.md parser
    matcher.zig      # // spec: tag scanner
```

## Config (guardian.toml)

```toml
spec_file = "SPEC.md"
max_file_lines = 500
file_size_exclude = []

[[boundary]]
module = "src/stages/*"
forbidden = ["shell"]
```
