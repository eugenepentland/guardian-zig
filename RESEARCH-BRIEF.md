# Guardian for Zig — Research Brief

> **Historical:** this research snapshot is retained for its principles and
> non-goals; its implementation inventory and counts are not current.

This document inventories what Guardian-Zig currently does. Use it to brainstorm
new features that would add value **within the project's stated scope**. Read
the "Principles" and "Non-Goals" sections before proposing ideas — features that
violate them should be ruled out, not pitched.

---

## 1. What it is

Build-step quality gates for Zig projects, designed primarily to catch mistakes
made by AI coding agents. Guardian runs on every `zig build` as a hard block:
no warnings, no bypass flags, no opt-out.

It is invoked as a small executable (`guardian-check`) wired into a consumer
project's `build.zig`. The consumer adds Guardian as a Zig package dependency;
each check becomes a build step that the install/test step depends on.

Target user: Zig developers (often working with AI agents) who want a
spec-driven workflow enforced automatically rather than by convention.

---

## 2. Implemented checks

All checks exit non-zero on failure, blocking the build. All accept
`[project-dir] [--quiet]`.

| Command | What it enforces | Failure conditions |
|---|---|---|
| (built-in `zig fmt --check`) | Source formatting | Any unformatted `.zig` file under `src/` |
| `spec` | 1:1 mapping between `SPEC.md` behaviors and `// spec:` tags on tests | Missing `SPEC.md`; behavior with no tag (unverified); tag with no matching behavior (unlinked); two tags pointing at the same behavior (duplicate) |
| `file-size` | Per-file line cap | Any `.zig` under `src/` or `test/` exceeding `max_file_lines` (default 500), unless excluded |
| `boundaries` | Import allowlist between modules | Any `@import` whose normalized path matches a `forbidden` substring inside a module matching a `[[boundary]].module` glob |
| `spec-init` | (Generator, not a check) | Scans `pub fn` signatures and writes a starter `SPEC.md` — one section per module, placeholder behaviors per function |

### Output behavior
- `--quiet`: silent on success, prints a single failure line + details on error.
- Verbose: prints per-check summaries (e.g. `17/17 behaviors covered`).
- Output is colored when stderr is a TTY.

### Spec-tag format
```zig
// spec: Section Name - Behavior statement
test "..." { ... }
```
Section + behavior is normalized (lowercased, whitespace collapsed) before
comparison, so casing/whitespace differences don't break matching, but the
1:1 rule is otherwise strict.

---

## 3. Workflow

Onboarding a new project:
1. Add `guardian` to `build.zig.zon`.
2. Wire the four check steps into `build.zig` (see `CLAUDE.md` for the
   canonical snippet).
3. `zig build spec-init` → generates a starter `SPEC.md` from `pub fn` names.
4. Edit `SPEC.md`, replacing placeholders with real behavior descriptions.
5. Tag tests with `// spec:` comments.
6. From now on, every `zig build` runs all four checks.

`zig build spec-init` is a separate step, not gated by the other checks,
so it works on a fresh project that has no `SPEC.md` yet.

---

## 4. Configuration (`guardian.toml`)

Optional. Defaults are designed to be sensible without any config file.

```toml
spec_file = "SPEC.md"             # default
max_file_lines = 500               # default
file_size_exclude = ["generated/*", "*/vendor_*.zig"]

[[boundary]]
module = "src/core/*"
forbidden = ["utils", "shell"]
```

Pattern syntax used in both `file_size_exclude` and `[[boundary]].module`:
- `*` is a wildcard matching any characters.
- A pattern with no `*` is treated as a plain substring match (backward compat).
- `forbidden` entries are always substring matches against the resolved import
  path (after `..`/`.` normalization).

Malformed values are silently ignored and fall back to defaults (this is a
deliberate choice — no parse error halts the build).

---

## 5. Internal architecture

```
src/
  check.zig          # Entry point; arg parsing; subcommand dispatch;
                     # glob matcher; path normalizer; @import extractor;
                     # directory walkers
  config.zig         # Tiny TOML reader for guardian.toml
  spec/
    parser.zig       # SPEC.md → sections + behaviors; key normalization
    matcher.zig      # // spec: tag scanner; coverage analysis
                     # (unverified / unlinked / duplicate)
    init.zig         # pub fn scanner; generates starter SPEC.md
```

Self-hosting: Guardian runs all of its own checks on its own source. Its own
`SPEC.md` has 17 behaviors covered by 26 tests. Its own `guardian.toml`
forbids `src/spec/*` from importing `config`.

---

## 6. Principles (from `CLAUDE.md`)

These are load-bearing — feature ideas should align with them.

1. **AI-first** — Exists to catch AI-agent mistakes.
2. **Hard block** — Every check fails the build. No warnings, no bypass.
3. **Zero-config** — Works with sensible defaults; config only overrides.
4. **Opinionated** — `SPEC.md` + `// spec:` tags **are** the workflow.
5. **Invisible** — Runs on every `zig build`; the user doesn't think about it.
6. **Self-hosting** — Guardian verifies itself.
7. **Zig-only** — Purpose-built for Zig.
8. **Missing `SPEC.md` = error** — Clear message, don't create files magically.
9. **1:1 spec/test mapping** — Every behavior needs exactly one matching tag.

---

## 7. Explicit non-goals

Don't propose features that would turn Guardian into any of these:

- A general-purpose linter (style/idiom checks beyond `zig fmt`).
- A test runner (Zig's test infra runs tests; Guardian only checks coverage).
- A documentation generator (`SPEC.md` is human-authored, not derived).
- A CI/CD service or cloud product.
- A "soft" tool with warnings, severity levels, or `--allow` bypass flags.
- A multi-language tool.
- A code-mod / autofixer that rewrites user code.
- A formatter (delegates to `zig fmt`).

The 1:1 spec-to-test rule is also intentionally strict — proposals to relax it
(e.g. "allow N tests per behavior") should explicitly justify why the rigidity
is wrong.

---

## 8. Test fixture (for reference)

`test-project/` is a minimal consumer that demonstrates the full flow: it
deliberately imports from `utils` inside `src/core/*` to exercise the
boundary check, sets `max_file_lines = 50` to make the size check trip
easily, and ships a `SPEC.md` with matching `// spec:` tags. Useful as a
sandbox when prototyping new checks.

---

## 9. Suggested research directions

Open-ended starting points for the researcher — not commitments:

- **Other AI-failure modes worth catching.** What classes of mistake do AI
  agents make in Zig codebases that none of the four current checks would
  detect? (e.g. dead `pub fn`s, untested error returns, `unreachable` in
  production paths, leaked allocators, mis-sized `comptime` work.)
- **Spec quality, not just coverage.** Behaviors today are free-text bullets.
  Are there cheap structural checks on the spec itself (e.g. behaviors that
  are too vague, sections with zero behaviors, behaviors that look like
  implementation notes rather than observable behavior)?
- **Drift detection.** When a `pub fn` signature changes, is there value in
  surfacing that the corresponding behavior in `SPEC.md` may now be stale?
- **Cross-check signals.** With access to the AST and the spec, are there
  cheap consistency checks (e.g. error sets declared but never returned in
  any tagged test)?
- **Onboarding ergonomics.** Is `spec-init` doing enough, or are there
  follow-on generators that would shorten the path from "fresh repo" to
  "all checks green"?

The researcher should weigh each idea against the principles in §6 and the
non-goals in §7, and explain how a proposed feature would integrate as a
hard-blocking build step (since that is the only delivery mechanism Guardian
has).

---

## 10. Deferred ideas

Ideas that surfaced during scoping but were ruled out for now, with the
reason. Listed so future passes don't re-relitigate them without context.

### `allocator-hygiene` — partial: hardcoded-global form shipped, ownership form still deferred

**Shipped.** The `allocator-hygiene` check rejects hardcoded references to
`std.heap.page_allocator`, `std.heap.c_allocator`, `std.heap.smp_allocator`,
`std.heap.GeneralPurposeAllocator`, and `std.testing.allocator` outside two
permissive scopes: `test {…}` blocks and `pub fn main(…) {…}`. Implemented as
a token-pattern scanner over `std.zig.Tokenizer` (which strips strings and
comments for free) plus a brace-depth state machine that pushes/pops a
permissive-scope frame at the body brace of `test` and `fn main`. Catches the
specific AI-agent mistake of conjuring a global allocator inline instead of
threading the allocator through as a parameter — a real, syntactically
decidable failure mode with zero false positives in practice (the rule is
"the literal token text appears here," and every match is a true bypass).

**Still deferred: arena/ownership analysis.** A second class of allocator
mistakes — leaked allocs, freeing memory owned by an arena, returning slices
allocated from a function-scoped arena — is *not* token-pattern decidable.
The `Allocator` interface is opaque by design: the same vtable backs
`GeneralPurposeAllocator`, arenas, fixed-buffer allocators, and
`testing.allocator`, so the static text of an `alloc`/`free`/`deinit` call
can't tell you whether a free is required, forbidden, or harmless. Any sound
check has to model data flow through that opaque interface — an
interprocedural analysis problem, not a token-pattern problem.

**What an ownership check would still need.** Two viable narrower forms, both
non-trivial:
1. **Arena-scoped lints only** — flag `free`/`destroy` on a value whose
   allocator is provably `ArenaAllocator.allocator()` in the same function.
   Requires AST-level type tracking, but the scope is local, so it's
   tractable.
2. **Convention-based** — require any `pub fn` that returns a heap-allocated
   slice to take an explicit `allocator: Allocator` parameter. Syntactic,
   shippable today, but the trigger ("returns a heap-allocated slice") is
   itself a heuristic — the same return type is used for borrowed slices
   into the input.

Until one of those lands, allocator-ownership mistakes remain Zig's
responsibility via runtime leak detection in `testing.allocator` and
`GeneralPurposeAllocator`. The shipped hygiene check raises the floor by
making sure the allocator-flow contract (caller passes the allocator in)
isn't bypassed in production code — it's the simpler, decidable half of the
original proposal.
