# Guardian for Zig

Build-step quality gates for Zig projects. Runs on every `zig build` — invisible, opinionated, hard-blocking.

**Designed for AI agents.** Guardian catches mistakes by enforcing spec-driven development: every behavior in your SPEC.md must have a matching test, and every test must trace back to a spec.

## Quick Start

1. Add guardian to your `build.zig.zon`:
```zig
.guardian = .{ .path = "../guardian-zig" },
```

2. Wire it into `build.zig`:
```zig
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
const check_exe = guardian_dep.artifact("guardian-check");

b.getInstallStep().dependOn(&b.addFmt(.{ .paths = &.{"src"}, .check = true }).step);

for ([_][]const u8{ "spec", "file-size", "boundaries" }) |cmd| {
    const run = b.addRunArtifact(check_exe);
    run.addArgs(&.{ cmd, ".", "--quiet" });
    run.setCwd(b.path("."));
    b.getInstallStep().dependOn(&run.step);
}
```

3. Generate your SPEC.md:
```bash
zig build spec-init
```

4. Edit SPEC.md, add `// spec:` tags to tests, then build:
```bash
zig build  # guardian gates every build
```

## What It Checks

| Check | Blocks on |
|-------|-----------|
| **Format** | Unformatted .zig files |
| **Spec coverage** | Missing SPEC.md, unverified behaviors, unlinked tags, duplicate tags |
| **File size** | Any .zig file exceeding max_file_lines (default 500) |
| **Boundaries** | Forbidden @import paths per module rules |

## Spec-Driven Workflow

```markdown
## Authentication
- Validates JWT tokens on every request
- Rejects expired tokens with 401
```

```zig
// spec: Authentication - Validates JWT tokens on every request
test "jwt validation" { ... }
```

Guardian enforces **1:1 mapping**: every spec behavior needs exactly one test tag.

## Config (guardian.toml)

Optional — sensible defaults work out of the box:
```toml
spec_file = "SPEC.md"
max_file_lines = 500
file_size_exclude = ["generated/*"]

[[boundary]]
module = "src/core/*"
forbidden = ["utils"]
```

Patterns use `*` as a wildcard. Without `*`, substring matching is used.

## Tools

```bash
zig build spec-init      # Generate starter SPEC.md from pub fn signatures
zig build spec-suggest   # Find pub fns not yet covered in SPEC.md
```

## Principles

1. **AI-first** — catches agent mistakes
2. **Hard block** — no warnings, no bypass
3. **Zero-config** — sensible defaults
4. **Opinionated** — SPEC.md + `// spec:` tags are THE workflow
5. **Invisible** — runs on every `zig build`
6. **Self-hosting** — guardian verifies itself (17/17 spec behaviors, 26 tests)
