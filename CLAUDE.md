# Guardian for Zig

## Guiding Principles

1. **AI-first** — Exists to catch AI agent mistakes
2. **Hard block** — All checks fail the build. No warnings, no bypass
3. **Zero-config** — Works with sensible defaults. Config only to override
4. **Opinionated** — SPEC.md + `// spec:` tags ARE the workflow
5. **Invisible** — Runs on every `zig build`. The user doesn't think about it
6. **Self-hosting** — Guardian verifies itself
7. **Zig-only** — Purpose-built for Zig
8. **Missing SPEC.md = error** — Clear message, don't create files magically
9. **1:1 spec-test mapping** — Every behavior needs exactly one matching tag

## Build & Run

```bash
zig build          # compiles AND runs all guardian checks
zig build test     # tests AND runs all guardian checks
zig build run      # runs AND runs all guardian checks
```

Guardian is invisible — it gates every build automatically.

## Integration

Add to `build.zig.zon`:
```zig
.guardian = .{ .path = "../guardian-zig" },
```

Add to `build.zig`:
```zig
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
const check_exe = guardian_dep.artifact("guardian-check");

// Format check
const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
b.getInstallStep().dependOn(&fmt_check.step);

// Guardian checks gate every build
for ([_][]const u8{ "spec", "file-size", "boundaries" }) |cmd| {
    const run = b.addRunArtifact(check_exe);
    run.addArgs(&.{ cmd, "." });
    run.setCwd(b.path("."));
    b.getInstallStep().dependOn(&run.step);
}
```

## Config (guardian.toml)

Optional. Defaults are sensible:
```toml
spec_file = "SPEC.md"        # default
max_file_lines = 500          # default

[[boundary]]
module = "src/core/*"
forbidden = ["utils"]
```

## Spec-Driven Workflow

1. Write behaviors in `SPEC.md`:
   ```markdown
   ## Authentication
   - Validates JWT tokens on every request
   - Rejects expired tokens with 401
   ```

2. Tag each test with exactly one matching `// spec:` comment:
   ```zig
   // spec: Authentication - Validates JWT tokens on every request
   test "jwt validation" { ... }
   ```

3. Guardian enforces 1:1 coverage. Missing tags or duplicate tags fail the build.

## Project Structure

```
src/
  check.zig          # Analysis executable (spec, file-size, boundaries)
  config.zig         # guardian.toml parser
  spec/
    parser.zig       # SPEC.md parser
    matcher.zig      # // spec: tag scanner + 1:1 enforcement
```
