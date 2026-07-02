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
const guardian = @import("guardian");
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
const check_exe = guardian_dep.artifact("guardian-check");

// Format check
const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
b.getInstallStep().dependOn(&fmt_check.step);

// One call wires every hard-block check into the install step.
// Adding new checks doesn't change this snippet.
guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{});

// spec-init: generate starter SPEC.md (separate step, not a gate)
const spec_init_run = b.addRunArtifact(check_exe);
spec_init_run.addArgs(&.{ "spec-init", "." });
const spec_init_step = b.step("spec-init", "Generate starter SPEC.md from pub fn signatures");
spec_init_step.dependOn(&spec_init_run.step);
```

## Config (guardian.toml)

Optional. Defaults are sensible:
```toml
spec_file = "SPEC.md"        # default
max_file_lines = 500          # default
file_size_exclude = ["generated/*", "*/vendor_*.zig"]

[[boundary]]
module = "src/core/*"
forbidden = ["utils"]
```

### Pattern syntax

All patterns use `*` as a wildcard matching any characters:
- `src/generated/*` — matches files under src/generated/
- `*/vendor_*.zig` — matches vendor files in any directory
- `utils` — plain substring match (no `*` = backward compatible)

This syntax is used in both `file_size_exclude` and `[[boundary]]` module patterns.

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

54 checks (most hard-block; test-coverage/escape-discipline/oom-discipline
opt-in) plus `zig fmt --check`. Full table in README.md;
the categories are: spec workflow, structural, public API, code style,
error handling, and allocation. Three checks are snapshot-based
(pub-api-surface, panic-budget, int-from-float-budget) — refresh
with `GUARDIAN_UPDATE_SNAPSHOT=1 zig build` and commit `.guardian/`.

Some checks were folded into a related one to cut overlap
(spec-drift→pub-api-surface, comptime-quota→panic-budget,
doc-quality→doc-comments, dup-const→repeated-string-literal,
vague-name-blacklist→naming); the retired names are still tolerated in a
`disabled` list. Per-check path exemptions live in guardian.toml `[[allow]]`
entries (check + paths), not compiled into the checks.

`all` runs are cached: when the hashed input set (src/test/build/spec/
guardian.toml/.guardian) is unchanged since the last green run, checks are
skipped. Disable with `cache_enabled = false`. Turn off individual checks
with a top-level `disabled = ["check-name", ...]` list (not a per-check
`enabled` flag).

## Project Structure

```
src/
  check.zig            # CLI entry / dispatch
  cli/                 # Command registry + shared types
  checks/              # One file per check
  spec/                # SPEC.md parser, // spec: matcher, spec-init
  ast/                 # Zig AST helpers (pubFns, fnDeclInfos, import_graph)
  walk.zig             # Recursive .zig file walker (visitor pattern)
  reporter.zig         # ok / fail printing + Violation type
  snapshot.zig         # Read/write/diff for snapshot-based checks
  snapshot_helper.zig  # Lifecycle helper used by all snapshot checks
  baseline.zig         # Baseline/ratchet mode for legacy violations
  cache.zig            # Skip-when-unchanged input digest for `all`
  config.zig           # guardian.toml parser
  build_helper.zig     # addAllChecks for downstream consumers
  testing/             # Golden-file test harness
```
