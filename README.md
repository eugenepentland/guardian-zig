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
const guardian = @import("guardian");
const guardian_dep = b.dependency("guardian", .{ .target = target, .optimize = optimize });
const check_exe = guardian_dep.artifact("guardian-check");

b.getInstallStep().dependOn(&b.addFmt(.{ .paths = &.{"src"}, .check = true }).step);

// One call wires up every hard-block check:
guardian.addAllChecks(b, check_exe, b.getInstallStep(), .{});
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

27 hard-block checks ship today, all gating Guardian's own self-build (one — `test-coverage` — is opt-in).

### Spec workflow
| Check | Blocks on |
|---|---|
| **spec** | Missing SPEC.md, unverified behaviors, unlinked tags, duplicate tags |
| **spec-quality** | Vague phrases (`properly`, `as needed`, etc.); behaviors shorter than 20 chars |
| **spec-drift** | A `pub fn` signature changed without updating its snapshot |

### Structural
| Check | Blocks on |
|---|---|
| **file-size** | Any .zig file exceeding `max_file_lines` (default 500) |
| **function-size** | Any function with more than `max_params` parameters (default 5) |
| **function-length** | Any fn over `max_lines` source lines (default 100) |
| **nesting-depth** | Any fn body with brace nesting over `max_depth` (default 4) |
| **type-size** | Any pub struct/enum/union over `max_fields` (default 15) |
| **imports** | Cycles in the `@import` graph |
| **boundaries** | Forbidden `@import` paths per module rules |
| **orphan-files** | A .zig file unreachable from any configured root via `@import` |
| **test-coverage** *(opt-in)* | A pub fn with no identifier reference from any test block |

### Public API
| Check | Blocks on |
|---|---|
| **pub-api-surface** | Unintended additions/removals to the public API (snapshot diff) |
| **dead-pub** | A `pub fn` / `pub const` referenced nowhere in the project |

### Code style
| Check | Blocks on |
|---|---|
| **naming** | PascalCase fns that don't return `type`; lowercase types |
| **doc-comments** | `pub fn` or `pub struct/enum/union` without a `///` doc comment |
| **doc-quality** | Empty / placeholder / sub-`min_chars` `///` comments (default 12) |
| **cognitive-complexity** | Per-function complexity score (default 15) |
| **anytype-budget** | More than `max_per_file` `anytype` parameters (default 2) |
| **usingnamespace-ban** | Any `usingnamespace` in `src/` |
| **debug-print-ban** | `std.debug.print(...)` calls outside `pub fn main` / test blocks |

### Error handling
| Check | Blocks on |
|---|---|
| **error-discipline** | Inferred `!T` or `anyerror!T` on `pub fn` (require explicit error sets) |
| **catch-discipline** | `catch unreachable` and `catch {}` (silent error swallow) |
| **stub-body-ban** | Single-statement bodies that are `return undefined`, placeholder `@panic`, or `unreachable` in non-noreturn fns |
| **panic-budget** | Increase in `@panic` / `unreachable` / `TODO` / `FIXME` counts (snapshot) |
| **comptime-quota** | Increase in `@setEvalBranchQuota` call count or max literal (snapshot) |

### Allocation
| Check | Blocks on |
|---|---|
| **allocator-hygiene** | Hardcoded `std.heap.page_allocator` / `c_allocator` / `GeneralPurposeAllocator` / `testing.allocator` outside `pub fn main` / tests |
| **dup-const** | Same `pub const NAME = "literal"` declared in 2+ files |

Plus `zig fmt --check` and the `spec-init` generator.

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

## Snapshot-based checks

`pub-api-surface`, `panic-budget`, and `spec-drift` write a baseline file under `.guardian/` on first run, then fail the build when subsequent runs diverge. To accept a real change:

```bash
GUARDIAN_UPDATE_SNAPSHOT=1 zig build
git add .guardian/
```

The snapshot files are plain text, sorted, designed to diff cleanly in code review.

## Config (guardian.toml)

Optional — sensible defaults work out of the box. Each check has its own section:

```toml
spec_file = "SPEC.md"
max_file_lines = 500
file_size_exclude = ["generated/*"]

[[boundary]]
module = "src/core/*"
forbidden = ["utils"]

[function_size]
max_params = 5

[complexity]
max_score = 15

[anytype_budget]
max_per_file = 2

[spec_quality]
forbidden_phrases = ["properly", "as needed"]

[function_length]
max_lines = 100

[nesting_depth]
max_depth = 4

[type_size]
max_fields = 15

# Opt-in: every pub fn must be referenced from at least one test block.
[test_coverage]
enabled = true
exempt_names = ["main", "build"]
```

Patterns use `*` as a wildcard; without `*`, substring matching is used.

## Tools

```bash
zig build spec-init                  # Generate starter SPEC.md
GUARDIAN_UPDATE_SNAPSHOT=1 zig build # Refresh snapshot baselines
```

## Principles

1. **AI-first** — catches agent mistakes
2. **Hard block** — no warnings, no bypass
3. **Zero-config** — sensible defaults
4. **Opinionated** — SPEC.md + `// spec:` tags are THE workflow
5. **Invisible** — runs on every `zig build`
6. **Self-hosting** — Guardian verifies itself
