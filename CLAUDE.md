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

## Onboarding a New Project

```bash
# 1. Add guardian dependency to build.zig.zon
# 2. Wire guardian into build.zig (see Integration below)
# 3. Generate starter SPEC.md from your code:
zig build spec-init

# 4. Edit SPEC.md — replace placeholder behaviors with real descriptions
# 5. Add // spec: tags to your tests
# 6. Build — guardian now gates every build:
zig build
```

## Build & Run

```bash
zig build          # compiles AND runs all guardian checks
zig build test     # tests AND runs all guardian checks
zig build run      # runs AND runs all guardian checks
zig build spec-init  # generate starter SPEC.md from pub fn signatures
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

// spec-init: generate starter SPEC.md
const spec_init_run = b.addRunArtifact(check_exe);
spec_init_run.addArgs(&.{ "spec-init", "." });
spec_init_run.setCwd(b.path("."));
const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
spec_init_step.dependOn(&spec_init_run.step);
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

1. Generate starter spec: `zig build spec-init`
2. Edit `SPEC.md` with real behavior descriptions:
   ```markdown
   ## Authentication
   - Validates JWT tokens on every request
   - Rejects expired tokens with 401
   ```

3. Tag each test with exactly one matching `// spec:` comment:
   ```zig
   // spec: Authentication - Validates JWT tokens on every request
   test "jwt validation" { ... }
   ```

4. Guardian enforces 1:1 coverage. Missing tags or duplicate tags fail the build.

## What Guardian Checks

| Check | What it does | Blocks on |
|-------|-------------|-----------|
| Format | `zig fmt --check src/` | Any unformatted files |
| Spec coverage | Matches SPEC.md behaviors to `// spec:` tags | Missing SPEC.md, unverified behaviors, unlinked tags, duplicate tags |
| File size | Counts lines in src/ and test/ .zig files | Any file exceeding max_file_lines (default 500) |
| Boundaries | Checks `@import` paths against `[[boundary]]` rules | Forbidden imports |

## Project Structure

```
src/
  check.zig          # Analysis executable (spec, file-size, boundaries, spec-init)
  config.zig         # guardian.toml parser
  spec/
    parser.zig       # SPEC.md parser
    matcher.zig      # // spec: tag scanner + 1:1 enforcement
    init.zig         # pub fn scanner for spec-init
```
