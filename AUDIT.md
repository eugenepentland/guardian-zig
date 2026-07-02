# Guardian-Zig — Full Codebase Audit

**Date:** 2026-07-02
**Method:** 8 parallel agents, one per subsystem (core framework, AST layer, spec system,
banned-symbol/I-O checks, memory/error-handling checks, complexity/size checks,
naming/dedup/docs/test checks, and cross-cutting tests/docs/config-debt). Findings below
were verified empirically against Zig 0.15.1 wherever a claim was checkable (tokenizer
replicas, compiler-source cross-checks, and probe runs of the actual check code).

---

## Executive summary

Guardian-Zig is well-architected: a clean registry/dispatch core, a genuine parse-once AST
index, consistent arena allocation, and (mostly) good per-file unit tests. The tokenizer-based
checks correctly exclude strings and comments — the hard part — and the snapshot/baseline
lifecycle helpers are solid.

But the audit surfaced **three systemic problems that each defeat the project's own stated
principles** ("hard block, no bypass"; "1:1 spec-test mapping"; "self-hosting"), and they were
found *independently by multiple agents*, which is why they lead this report:

1. **~78 of 267 test blocks never run** (empirically: `zig test` reports 189 passing). The
   test root in `src/check.zig` was never updated for ~27 newer check files. Smoking gun:
   `ban_net.zig:43` calls `std.testing.expectGreaterThanOrEqual`, which **does not exist in any
   Zig version** — adding the import produces a compile error, yet the build is green. Worse,
   those files' `// spec:` tags still count as "coverage," so 27 spec behaviors are verified by
   tests that never execute.

2. **Every AST-based check is blind to code nested inside `struct`/`union`/`enum`** because all
   five primitive iterators in `src/ast/parser.zig` walk `tree.rootDecls()` only. Idiomatic Zig
   puts nearly all real code in container methods, so an agent can dodge ~15 checks
   (function-length, nesting-depth, returns-per-fn, param-count, naming, doc-comments,
   dead-pub, pub-api-surface, error-discipline, stub-body-ban, init/errdefer checks, type-size,
   …) simply by wrapping code in a struct. This is the single highest-leverage fix in the repo.

3. **The file walker fails open.** `src/walk.zig:44` swallows a failed `openDir` (missing/typo'd
   `src/` → every check reports OK against zero files) and `:78` `catch continue`s unreadable or
   >10 MB files (silently exempt from *every* check, including file-size). For a "no bypass"
   gate, I/O failure should be loud.

Beyond these, there are real per-check correctness bugs (a container-classification bug that
hides tagged unions; a `dup_const` parse bug that records the type `u8` as the const's name; a
`file-size` off-by-one; a `magic-number` `comptime` scope leak), a family of false
positives/negatives in the semantically-hard checks, ~2–3× redundant in-memory copies of the
whole source tree, and heavy copy-paste (`lineOf` reimplemented ~17×; the whole
`ScanCtx`/`run()` scaffold per check). Documentation has drifted badly (four contradictory
check counts; a README rollout snippet that silently does nothing). Finally, `guardian.toml`
pays down self-inflicted debt with blanket 2–5× limit raises instead of the per-item baseline
ratchet the project already ships.

None of this is structural rot — the bones are good. Most of the impact concentrates in ~6
fixes.

---

## Priority 0 — Fix these first (each breaks a core guarantee)

### P0-1 · ~78 test blocks never compile or run — `Bug/TestGap`
- **Where:** `src/check.zig:76-124` (the `test { _ = @import(...) }` aggregation block)
- **What:** In Zig, `test` decls only run when their file is referenced from a `test` block in
  the test root; importing a module via `cli/registry.zig` does **not** pull its tests in. The
  block stops at `test_coverage` + `import_graph`; everything added after is missing — the whole
  `ban_*` family, `banned_symbol_helper`, the constructor-hygiene checks
  (`compile_error_explanation`, `init_hygiene`, `static_factory_ban`, `init_deinit_symmetry`,
  `errdefer_in_init`), the test-hygiene checks (`test_has_assertion`, `test_no_conditional`,
  `no_test_imports_in_prod`), `bool_ops_per_condition`, `returns_per_function`, `line_length`,
  `vague_name_blacklist`, `boolean_param_ban`, `magic_number`, `repeated_string_literal`,
  `struct_method_cap`, `optional_density`, `stringly_typed_switches`, `repeated_switch_on_enum`.
- **Proof:** `zig test src/check.zig` → "All 189 tests passed" vs. 267 `test` blocks in source.
  `ban_net.zig:43` calls the nonexistent `std.testing.expectGreaterThanOrEqual` (also with its
  args reversed) — adding `_ = @import("checks/ban_net.zig");` fails to compile, yet the current
  build is green. (Same nonexistent call also sits in `bool_ops_per_condition.zig:168`,
  `vague_name_blacklist.zig:120`, `optional_density.zig:215`, `magic_number.zig:174`.)
- **Fix:** Replace the hand-maintained list with a registry-driven aggregator
  (`std.testing.refAllDeclsRecursive` over `cli/registry.zig` plus explicit imports for
  non-registry modules), then **add a meta-guard** — a check/test asserting every
  `src/checks/*.zig` file is referenced by the test root. This exact drift will recur otherwise.
  Fix the 5 nonexistent-assertion calls while you're in there.

### P0-2 · AST primitives only see top-level declarations — `Missing/FalseNegative`
- **Where:** `src/ast/parser.zig:110` (`pubFns`), `:192` (`fnDeclInfos`), `:267` (`allFns`),
  `:312` (`pubContainers`), `:372` (`pubConsts`) — all iterate `tree.rootDecls()`.
- **What:** Methods and nested types inside containers are invisible. Confirmed to silently
  exempt (non-exhaustive): `function_length`, `nesting_depth`, `returns_per_function`,
  `function_size` (param cap), `cognitive_complexity`, `naming`, `doc_comments`, `doc_quality`,
  `dead_pub`, `pub_api_surface`, `error_discipline`, `stub_body_ban`, `errdefer_in_init`,
  `init_hygiene`, `type_size`. Guardian passes its own gate largely because its code is
  file-as-struct (top-level fns) — masking the gap.
- **Fix:** Add a recursive member walk: for each root decl whose init is a container, iterate
  `fullContainerDecl(...).ast.members` and recurse, yielding fns/consts with qualified names
  (`Outer.method`). Roll out check-by-check (start with `pub_api_surface`, `doc_comments`,
  `stub_body_ban`; exempt `init`/`deinit` from `dead_pub`). One parser change repairs ~15 checks.

### P0-3 · Walker fails open on unreadable/oversized files and missing `src/` — `ErrorHandling`
- **Where:** `src/walk.zig:44` (`openDir(...) catch return;`), `:78`
  (`readFileAlloc(...) catch continue;`).
- **What:** A missing/typo'd project dir yields zero files → every check reports success
  vacuously. Any file over `max_file_bytes` (10 MB) or with a read/permission error is silently
  excluded from *all* checks, including `file-size`. Inconsistent, too: subdirectory open errors
  *do* propagate (`walk.zig:65` uses `try`) — loud one level down, silent at the root.
- **Fix:** Propagate root `openDir` failure (or fail in `run_all` when 0 files were scanned).
  On a per-file read error, `reporter.fail` naming the file rather than `continue`. This same
  fail-open pattern was flagged independently by 6 of the 8 agents.

### P0-4 · `// spec:` tags aren't required to be on tests → "1:1 spec-test" is really "1:1 spec-comment" — `Correctness`
- **Where:** `src/spec/matcher.zig:55-69` (`extractTags`), `src/checks/spec.zig:40-45`.
- **What:** `extractTags` accepts a `// spec:` line *anywhere* in any file; nothing checks it
  precedes a `test` block. In Guardian's own source, 92/103 tags sit on production
  declarations, not tests — e.g. `src/checks/spec.zig:18` "covers" *"Fails with clear error when
  SPEC.md is missing"* with a comment inside the very production branch it describes.
- **Fix:** In `extractTags`, only accept a tag whose next non-comment/non-blank line begins a
  `test` decl (allow stacked tags for multi-behavior tests); report tags on non-test code as a
  distinct violation. Then migrate Guardian's own tags onto real tests. Combined with P0-1, this
  is what makes the flagship guarantee actually true.

---

## Priority 1 — Correctness bugs (wrong results on valid input)

### AST layer
- **[High] Tagged unions and `packed`/`extern` structs are misclassified as `.value`** —
  `src/ast/parser.zig:320-329, 380-384, 455-464`. `union(enum)` parses as `tagged_union_*`
  (absent from both switches); `classifyContainer` reads `tree.firstToken`, which returns the
  layout keyword `packed`/`extern` for those forms, so the text compare fails. Result:
  `type-size`, `naming`, `doc-comments`, `doc-quality` all skip these common types. **Fix:** add
  the six `tagged_union*` tags; classify via `tree.nodeMainToken` (always the container keyword)
  comparing token *tags* (`.keyword_struct`, …), not text. *(Verified against Zig 0.15.1.)*
- **[Low] `fnDeclInfosFromTree` locates the body by scanning tokens for `{`** —
  `src/ast/parser.zig:208-226`. The body node is directly available as
  `tree.nodeData(decl).node_and_node[1]`; the scan's no-return-type fallback could match a `{`
  inside a param list, and `orelse continue` silently drops decls. **Fix:** use the body node.
- **[Low] `tree.errors` is never checked** — `src/ast/index.zig:46`, `parser.zig` wrappers.
  Syntax errors produce a partial/empty tree; standalone single-check runs (no `zig fmt` gate)
  then analyze an "empty" file and pass vacuously. **Fix:** one `if (tree.errors.len != 0)`
  guard in `index.collect` and the shared source-parse wrapper.

### Checks
- **[High] `dup_const` records the *type* as the const name** — `src/checks/dup_const.zig:51-56`.
  For `pub const A: []const u8 = "x";` the `const` inside `[]const u8` re-triggers the handler and
  captures `u8` as the name. Two differently-named typed string consts with the same value are
  flagged as dupes (with the nonsense name `u8`); a typed-vs-untyped genuine dupe is missed.
  **Fix:** only honor `.keyword_const` at declaration position, or use `Ast.fullVarDecl`.
  *(Verified against 0.15.1 tokenizer.)*
- **[High] `enabled = false` is silently ignored** for `bool_ops_per_condition`,
  `returns_per_function`, and `line_length` — `bool_ops_per_condition.zig:117-126`,
  `returns_per_function.zig:87-96`, `line_length.zig:59-68`. Config parses the flag
  (`config.zig:84,92,98,365-382`) but these three `run()`s never read it. **Fix:** add the
  early-return guard the sibling checks have, or standardize on the top-level `disabled` list and
  drop the dead per-check `enabled` fields.
- **[Medium] `file-size` off-by-one** — `src/checks/file_size.zig:21-24`. `lines` starts at 1 and
  increments per `\n`; since `zig fmt` guarantees a trailing newline, a file of exactly
  `max_file_lines` reports `max+1` and fails — the effective limit is `max-1`. **Fix:** count
  `\n` and add 1 only if content doesn't end in `\n`.
- **[Medium] `magic-number` `comptime` exempts the whole enclosing scope** —
  `src/checks/magic_number.zig:81-89`. A `comptime` *param modifier* or expression prefix (not a
  block) sets `comptime_depth`, exempting the entire function. Every generic fn is thus exempt.
  Also `:91-96`: the const-initializer exemption only covers the first token after `=`
  (`const t = base * 30_000;` flags `30_000`), while `prev_tag == .equal` over-exempts every
  assignment and struct-literal field. **Fix:** only enter comptime-exempt state when `comptime`
  is immediately followed by `l_brace`; track an in-const-init flag from `=` to `;`.
  *(Both verified.)*
- **[Medium] `returns_per_function` fn-depth heuristic** — `src/checks/returns_per_function.zig:51-72`.
  A fn-pointer *type* in a body inflates depth (suppresses a real return → undercount); the first
  inner `}` of a nested fn zeroes depth (nested returns leak to the outer fn → overcount).
  **Fix:** track brace balance from the fn's opening `{`, or count via AST once P0-2 lands.
- **[Medium] `nesting-depth` counts data-literal braces as control nesting** —
  `src/checks/nesting_depth.zig:28-49`. `.{ .a = .{...} }`, array inits, and enum-literal switch
  arms all raise "depth." A flat fn building one nested config literal can hit depth 5. **Fix:**
  skip braces preceded by `.period`/type-init, or compute depth from block/if/while/for/switch
  AST nodes.
- **[Medium] `struct_method_cap` miscounts modifiers and nested containers** —
  `src/checks/struct_method_cap.zig:95-116`. The `else` arm resets `saw_pub` on `inline`, so
  `pub inline fn` isn't counted; `countPubFns` consumes the outer container's braces so nested
  `pub const Inner = struct` is never independently capped. **Fix:** preserve `saw_pub` across
  `inline`/`extern`/`export`/callconv; ideally count via AST container members.
- **[Medium] `spec-init` ignores `cfg.spec_file`** — `src/checks/spec_init.zig:16` hard-codes
  `"{s}/SPEC.md"` while `checks/spec.zig:16` honors `cfg.spec_file`. A project with
  `spec_file = "docs/SPEC.md"` gets a root `SPEC.md` the coverage check never reads. **Fix:** use
  `ctx.cfg.spec_file` for the existence check, write path, and message.
- **[Low] `matchGlob` non-backtracking false-negative** — `src/walk.zig:88-114`.
  `matchGlob("a.zig.zig", "*.zig")` returns `false` (consumes the trailing literal at its first
  occurrence, then demands exact end). Affects `file_size_exclude` (fail-closed, annoying) and
  `[[boundary]]` module patterns (fail-open). **Fix:** match a trailing non-`*` part with
  `endsWith`. *(Verified.)*
- **[Low] `stripDocPrefix` trims all whitespace** — `src/ast/parser.zig:429-433`, contradicting
  its own doc ("a single space per line"); flattens intentional indentation in doc text.

---

## Priority 2 — False positives (block correct code — worst in a hard-block tool)

- **`init_deinit_symmetry`: a fn param named `allocator`/`gpa` counts as an owned field** —
  `src/checks/init_deinit_symmetry.zig:128-157`. `collectStructBody` tracks only brace depth, not
  parens, so `pub fn clone(self: T, allocator: Allocator) !T` in a struct with no allocator field
  hard-fails "owns an allocator but has no deinit." This directly punishes the per-call-allocator
  style `allocator_hygiene` *encourages* — the two checks fight. **Fix:** track paren depth, or
  walk `container_field` AST nodes.
- **`errdefer_in_init`: presence-anywhere heuristic** — `src/checks/errdefer_in_init.zig:58-73`.
  Rule is "≥2 `try`, zero `errdefer` anywhere." FPs: `defer`-based cleanup doesn't count; two
  non-resource `try parseInt(...)` calls are flagged. FN: `errdefer` registered *after* both
  allocs still passes (order-insensitive); a literal `errdefer {}` silences it. **Fix:** make it
  order-aware (flag a 2nd `try` with no `defer`/`errdefer` between it and the 1st); optionally
  restrict to allocation-shaped calls.
- **`allocator_hygiene`: `error{...}` in `main`'s return type steals the permissive scope** —
  `src/checks/allocator_hygiene.zig:75-82`. `pending_permissive` latches onto the first `l_brace`
  after `fn main`, which for `pub fn main() error{Oops}!void` is the error-set brace; the real
  body is then non-permissive and `page_allocator` in `main` is flagged. **Fix:** detect the
  body via AST, or skip brace pairs that close before depth returns. *(Verified via tokenizer.)*
- **`catch_discipline` / `unwrap_discipline` scan inline `test` blocks despite claiming exemption**
  — `catch_discipline.zig:107`, `unwrap_discipline.zig:72`. The exemption only covers files
  outside `src/`, but Zig tests are inline `test {}` in the same files. `x catch unreachable` in a
  test hard-fails. `allocator_hygiene.zig:51-88` already has the needed test/main scope tracking —
  lift it into a shared helper.
- **`catch_discipline`: `catch {}` inside `defer`/`errdefer`** — `catch_discipline.zig:39-81`.
  Inside a `defer` an error can't propagate, so `defer w.flush() catch {};` is often the only
  option, yet it's flagged. **Fix:** track defer scope. (Also FN: `catch { unreachable; }` and
  `catch |e| { _ = e; }` are identical swallows that pass.)
- **`test_has_assertion`: substring `"expect"` + decltests** — `test_has_assertion.zig:50-54,85`.
  Matches `expected` variable names/comments (14 uses in `src/checks/` alone defeat it) yet
  misses `try`-only assertions and custom helpers; identifier-named decltests (`test foo {}`) are
  wrongly treated as anonymous and exempt. **Fix:** tokenize; match `expect`-prefixed identifiers,
  count bare `try` as a weak assertion; set `has_name` on `.identifier`.
- **`test_no_conditional`: flags idiomatic tests** — `test_no_conditional.zig:73-80`. Hard-fails
  the standard skip idiom `if (cond) return error.SkipZigTest;`, expression-`if`, iterator
  `while (it.next()) |e|` (the only way to iterate a HashMap — used in Guardian's own
  `repeated_switch_on_enum.run`), and error-triage `catch |e| switch (e)`. **Fix:** whitelist
  `SkipZigTest`; use AST to flag only statement-position `if`/`switch`.
- **`dead_pub`: library-exported API flagged dead; recursive fns never flagged** —
  `dead_pub.zig:30-44,104-120`. A `pub` symbol that exists for downstream consumers counts only
  its decl site unless referenced internally (Guardian's own `build.zig` saves it; consumer
  libraries won't be). No `exempt_names`/`exempt_files` knob. **Fix:** add per-check config for
  consumer-facing roots.
- **`repeated_switch_on_enum` ships Guardian-internal path exemptions to all consumers** —
  `repeated_switch_on_enum.zig:18-24`. Hard-coded `allowed_paths` (`src/checks/*`, `src/ast/*`,
  …) exempt any downstream project with those (common!) directory names; `src/snapshot.zig` lacks
  a `*` so it's a *substring* match. Also two different enums with matching prong names collide
  (FP). **Fix:** move self-host exemptions to `guardian.toml`; include the switch operand in the
  signature.
- **`compile_error_explanation` flags valid non-literal / multiline messages** —
  `compile_error_explanation.zig:44-53`. `@compileError(comptimePrint(...))`,
  `@compileError(const_msg)`, and `\\` multiline args are the *most* informative forms yet are
  flagged; `" "` passes. **Fix:** accept identifiers/builtins/calls and multiline literals; trim
  before the emptiness test.

---

## Priority 3 — False negatives (real problems slip through)

- **Namespace aliasing launders every banned symbol** — `banned_symbol_helper.zig:50-66`. Chains
  must begin with the literal identifier `std`, so `const time = std.time; time.timestamp()`,
  `const std2 = std;`, `@import("std").time.timestamp()`, and re-exports all pass. `const fs =
  std.fs;` is idiomatic, so this is a routine miss, not an adversarial one. **Fix:** first-pass
  collect file-level `const X = std[...]` aliases and expand each rule's accepted chain roots;
  treat `@import("std")` as equivalent to `std`. *(All verified, 0 violations each.)*
- **`allow_in_main` / `allow_in_tests` exempt any `fn main` anywhere** —
  `banned_symbol_helper.zig:177-182` (and the same pattern in `allocator_hygiene`). A method
  `fn main(self: S)` in a deep file makes its body permissive for all bans. **Fix:** require
  `pub` + top-level (`saw_pub` like `ban_globals` does), ideally file `src/main*`.
- **Ban rule tables have material gaps** — `ban_fs.zig:7-17` (misses `*Absolute`/`*Z`/`*W`
  variants, `selfExePath`, `realpathAlloc`), `ban_rng.zig:7-12` (misses `DefaultCsprng`,
  `ChaCha`, `Isaac64`, `Xoroshiro128`, `Sfc64`, `SplitMix64`, …), `ban_env.zig:7-12` (misses
  `hasEnvVar*`, `parseEnvVarInt`, `std.c.getenv`, `std.posix.environ`), `ban_sleep`/`ban_time`
  (miss `std.posix.nanosleep`/`clock_gettime`). `std.posix`/`std.c` are a systemic escape hatch
  across the whole family. **Fix:** complete the tables or invert `ban_fs` to a `std.fs` prefix
  ban with a pure-decl allowlist; add `std.posix`/`std.c` chains. *(Verified against 0.15.1.)*
- **`ban_hardcoded_paths`: multiline strings and mid-string URLs evade** —
  `ban_hardcoded_paths.zig:67,79-89`. `\\/etc/passwd` (a `.multiline_string_literal_line` token)
  and mid-string `"...https://..."` both pass (`startsWith`-only). Missing `/Users/`, `/mnt/`,
  `/proc/`, `/sys/`. **Fix:** inspect multiline tokens; use `indexOf` for URL schemes.
- **`boolean_param_ban` misses `pub inline/export/extern fn`; flags `[]const bool`** —
  `boolean_param_ban.zig:56-64,88-101`. Modifier clears `saw_pub`; any `bool` at paren-depth 1 is
  flagged even as `[]const bool`/`*bool` data. **Fix:** preserve `saw_pub` across modifiers; only
  flag a bare `: bool` param.
- **`pub_api_surface` snapshots names only — signature changes are invisible** —
  `pub_api_surface.zig:28-37`. Changing `parse(a) !Ast` → `parse(a, opts) Ast` is zero drift.
  `PubFn.proto_span` already exists and is unused here. **Fix:** append `proto_span`; bump
  `SNAPSHOT_VERSION`.
- **`panic_budget`: `std.debug.panic` uncounted; `//` in strings counts as comments** —
  `panic_budget.zig:45-52,57-67`. Only `@panic` is counted, so converting to `std.debug.panic`
  "reduces" the budget; `"https://.../TODO"` counts a fake TODO. **Fix:** count the
  identifier-chain form; scan comment markers via tokens.
- **`naming`: snake_case fns pass, contradicting the check's own summary** — `naming.zig:40-53`
  (registry claims "camelCase fns" at `registry.zig:73`). `pub fn do_the_thing()` (Rust/Python
  bleed) passes. Also `pub fn Foo() !type` is misclassified. No file-name convention check.
  **Fix:** flag `.snake` pub fns; treat `!type`/`?type` as type-returning; add file-name rules.
- **`orphan_files`: top-level files self-legitimize** — `orphan_files.zig:17-27`,
  `import_graph.zig:51-58`. Default roots = *every* `src/*.zig`, so a dead top-level
  `src/scratch.zig` is its own root and can't be flagged; the graph also has no edges from
  `test/` or `build.zig` (FPs). **Fix:** parse `build.zig` for roots; add `test/` `@import`s.
- **`test_coverage`/`dead_pub` match by bare name** — `test_coverage.zig:90-97`,
  `dead_pub.zig:65-71`. One reference to *any* `run` marks *all* `run`s covered/alive (every
  check file has `pub fn run`). **Fix:** resolve references per-file via the import graph
  (qualified `alias.name` + same-file bare refs).
- **`stub_body_ban` misses functions inside containers** — via `parser.zig:192` (see P0-2);
  most AI-generated stubs are methods.

### Spec-parser correctness (each produces phantom or misattributed behaviors)
- **Mid-file `## Overview`/`## Planned` skip leaks bullets into the previous section** —
  `src/spec/parser.zig:42` (`continue`s before flushing `current_section`). A trailing
  `## Planned` (its exact use case) makes every planned item a required behavior of the preceding
  section.
- **Fenced code blocks are parsed as spec content** — `parser.zig:34-81` (no fence tracking).
  Any `- `/`## ` line inside ``` ``` ``` mints phantom behaviors — likely, since agents author
  these files. **Fix:** track an `in_fence` toggle.
- **Empty / behavior-less SPEC.md passes** — `checks/spec.zig:47-53`, `matcher.zig:126-132`.
  A `# Title`-only file reports "0/0 covered" and is green — the path of least resistance for an
  agent is to gut the spec. **Fix:** fail when `total_behaviors == 0`.
- **Nested markdown bullets flattened into behaviors** — `parser.zig:36,69` (trims before the
  `"- "` test). **Fix:** check raw-line indentation.
- **Duplicate spec *bullets* not detected** — `matcher.zig:73-124` groups only tags, so two
  identical behaviors both count as covered by one tag (violates 1:1 on the behavior side).
- **Malformed tags silently ignored** — `matcher.zig:8,59` (exact `"// spec: "` only). `//
  spec:Foo` (no space) never registers; the user only sees "unverified." **Fix:** detect
  near-miss `spec:` lines and report "malformed spec tag" with `file:line` (add a line number to
  `SpecTag`).

---

## Priority 4 — Fail-open error handling (silent green on failure)

Beyond the P0-3 walker, a "hard block, no bypass" tool should never degrade to a pass:
- **Snapshot/quota auto-create on missing** — `comptime_quota.zig:127-132` (and the pattern in
  the snapshot helper). Deleting `.guardian/comptime-quota.txt` ratifies whatever the current
  totals are as the new baseline — a bypass. **Fix:** fail with "snapshot missing — re-run with
  `GUARDIAN_UPDATE_SNAPSHOT=1`" instead of silently writing.
- **Baseline `VersionMismatch` silently grandfathers new violations** — `baseline.zig:154-158`
  auto-rewrites with *current* violations and reports success; inconsistent with
  `snapshot_helper.lifecycle:64`, which fails. **Fix:** align — fail on version mismatch.
- **Config fails open everywhere** — `config.zig:145-149` (unreadable `guardian.toml` == missing,
  silent defaults), `:276-278` (inline `# comment` breaks the value → silent default; valid
  TOML), `run_all.zig:80-84` (unknown names in `disabled = [...]` silently disable nothing);
  `config.zig:552-569` even has a *test enshrining* that top-level keys after a `[section]` are
  dropped. **Fix:** strip inline comments; distinguish `FileNotFound` from other errors; validate
  `disabled` against the registry and fail on typos.
- **Swallowed OOM in check bodies** — `errdefer_in_init.zig:35`, `init_hygiene.zig:41`,
  `panic_budget.zig:40`, `vague_name_blacklist.zig:51,63`, `spec/parser.zig:111` (`normalizeKey`
  returns `""` on OOM → empty key matches empty key = false coverage). `RunError = anyerror`
  already allows propagation. **Fix:** `try` instead of `catch return`.
- **`imports`/cycle finder degrade to "acyclic" or false cycles on OOM** —
  `import_graph.zig:79` (leaves a node gray → false cycle later), `:108,123-124` (`catch return
  null` → "no cycle"). Both wrong directions from one function. **Fix:** propagate
  `Allocator.Error`.
- **`snapshot.read` maps OOM/AccessDenied to `BadFormat`** — `snapshot.zig:32-35`, misdirecting
  diagnosis ("your snapshot is corrupt"). **Fix:** pass non-ENOENT errors through.
- **"SPEC.md not found" reported for *any* read failure** — `spec/parser.zig:22-26` collapses
  `AccessDenied`, `IsDir`, >1 MB, and OOM into `CouldNotReadSpec`, sending the user to create a
  file that already exists. **Fix:** `switch` on the error; only the not-found case gets the
  create-a-file guidance.

---

## Priority 5 — Memory & performance

- **Source tree copied 2–3× into the run-lifetime arena** — `walk.zig:78` (copy 1), then
  `ast/index.zig:45` `dupeZ` (copy 2, to get the sentinel `Ast.parse` needs), then every
  tokenizer check `dupeZ`s again because `walk.FileEntry.content` is `[]const u8` not
  `[:0]const u8` (`allocator_hygiene.zig:43`, `catch_discipline.zig:31`,
  `banned_symbol_helper.zig:122`, `dead_pub.zig:63`, `ast.imports` at `parser.zig:72`, +more).
  Nothing is freed (arena) so the whole tree is resident 2–3× for the run. **Fix:** read
  null-terminated at the source (`readFileAllocOptions(..., 0)`) and type `FileEntry.content` as
  `[:0]const u8`; then `index.collect` stores it directly and every downstream `dupeZ` is
  deleted. High leverage — flagged by 4 agents.
- **`import_graph.build` ignores the shared index** — `import_graph.zig:51-58`. Both `imports`
  and `orphan_files` re-`walkZigFiles` and re-tokenize the whole tree from disk in an `all` run.
  **Fix:** add `buildFromIndex(allocator, index)`.
- **`cognitive_complexity` re-parses each file** — `cognitive_complexity.zig:47-51` ignores
  `entry.tree` and calls `Ast.parse` again. **Fix:** use `entry.tree` when present.
- **Cache digest recomputed pre-run goes stale after a green run that writes `.guardian/`** —
  `run_all.zig:34-46`, `cache.zig:34-40`. Guarantees one wasted full re-run after every
  snapshot/baseline write; also `dupe`s every file's content just to sort before hashing (~2×
  memory). **Fix:** hash each file to a per-file digest immediately, keep only `(path, digest)`;
  recompute the digest after a green run.
- **`lineOf`/`lineOfByte` is O(file) per call, called up to 2× per fn/violation** —
  `ast/parser.zig:245-252` and its ~17 copies. Quadratic-feeling on large downstream files.
  **Fix:** precompute a newline-offset table per file (could live on the index `Entry`).
- **Quadratic graph lookups** — `import_graph.zig:69-74` (linear `nodeIndex` in DFS),
  `:145-156` (`orderedRemove(0)` BFS). Fine at 77 files, not at the thousand-file projects
  Guardian targets. **Fix:** one `StringHashMap(path→index)`; index cursor instead of
  `orderedRemove`.

---

## Priority 6 — Duplication & simplification

- **`lineOf` reimplemented ~17× across checks** (plus `ast/parser.zig:245` `lineOfByte`).
  **Fix:** one shared `lineOfByte` in `walk.zig` or a new `src/text.zig`.
- **`reporter.Violation` + `Reporter.emit/emitTo/emitDirect` are dead** — `reporter.zig:11-16,
  72-103`. Zero checks construct a `Violation`; every check hand-formats `"{s}:{d}: ..."`, and
  `baseline.extract` then *re-parses* that text by scraping indentation (`baseline.zig:40-51`) —
  an invisible coupling that any format change silently breaks. **Fix:** either migrate checks to
  emit `Violation` (and have baseline capture structured records), or delete the unused API. The
  two emit paths also duplicate the format logic verbatim (drift risk).
- **The `if (entry.tree) |t| XFromTree else X` dispatch is hand-written in ~12 checks** — and
  *forgotten* in `boundaries.zig:73` and `no_test_imports_in_prod.zig:30` (they re-tokenize every
  file even in indexed runs). Since `Index.forEach` always sets `tree`, the `else` branches are
  production-dead. **Fix:** add entry-level helpers (`pubFnsFor(arena, entry)`, `importsFromTree`,
  …) that dispatch once.
- **Per-check `ScanCtx`/`FileScanCtx`/`analyzeContent`/`run()` scaffolding (~40 lines) repeated
  in every token check.** `function_length`, `nesting_depth`, `returns_per_function` are the same
  "iterate fns, compute metric, compare to cap" shape. **Fix:** a `per_fn_metric.zig` helper and a
  shared `runAnalyze(ctx, name, fix_hint, allowed_paths, analyzeFn)`; each ban/metric file
  collapses to a rules table + tests.
- **Five identical `dupeZ`+`Ast.parse` wrappers** — `parser.zig:97-101,178-182,255-259,300-304,
  360-364`. **Fix:** one private `parseSource(arena, source)` (also the natural home for the
  `tree.errors` guard).
- **Byte-identical twins:** `isTestFile` vs `looksLikeTest` in `no_test_imports_in_prod.zig:44-56`;
  the `catch_discipline` and `unwrap_discipline` scanners differ only by keyword + message.
  **Fix:** delete one twin; merge the two discipline checks into one "crash-on-failure fallback"
  matcher (which would also catch the `orelse @panic(...)` / `catch @panic(...)` forms both miss).
- **Guardian-internal exemptions ship to downstream** — the `allowed_paths` in `ban_fs`,
  `ban_env`, `debug_print_ban`, `static_factory_ban`, `boolean_param_ban` mix downstream policy
  with self-host carve-outs (`src/walk*`, `src/cache*`, `src/config*` — and `*` crosses `/`).
  Several entries (`config/*`, `infra/fs*`, `adapters/http*`) can *never* match because the index
  only scans `src/`. **Fix:** split into two lists; apply the self-host list only when building
  Guardian itself; expose ban allow-paths in `guardian.toml`.
- **Dead code:** `hasPrecedingDocComment` (`parser.zig:397-401`, no callers); `FnInfo.return_kind`
  (`parser.zig:28,281`, unread); `dup_const.prev_was_pub` (written never read); the `ScanCtx` +
  `_ = &@as(ScanCtx, undefined);` keep-alive hack in `repeated_string_literal.zig:18-22,103`; the
  dead `"-1"` allowlist entry and `all_check_names` `RUN_ALL_NAME` filter (`build_helper.zig:5`);
  the untracked self-referential symlink `guardian-zig -> .` in the repo root.

---

## Priority 7 — Documentation & spec alignment

- **[High] README's tier-by-tier rollout snippet silently does nothing** — `README.md:210-225`
  claims "every check has an `enabled` flag" and shows `[ban_time] enabled = false`. Only 14
  checks have config sections; `[ban_time]` parses as an *unknown section and is ignored* — the
  check stays on. Meanwhile the mechanism that works, top-level `disabled = ["ban-time", ...]`
  (`config.zig:126`, `SPEC.md:12`), is documented nowhere. **Fix:** replace the example with
  `disabled = [...]`; delete the "every check has an enabled flag" sentence.
- **[High] Four contradictory check counts** — `CLAUDE.md` says "23"; `README.md:38` "55";
  `LOOP_NOTES.md` "17/18"; `RESEARCH-BRIEF.md` describes a 4-check tool. Actual: 56 checks + the
  `spec-init` generator (57 registry entries). `unwrap-discipline` is also missing from the
  README check tables entirely. **Fix:** correct the live docs (or use "50+"); add the
  `unwrap-discipline` row; stamp `LOOP_NOTES.md`/`RESEARCH-BRIEF.md` as "Historical."
- **[Medium] Snapshot-check lists wrong in both docs** — `CLAUDE.md` says "Three… (lists four)";
  `README.md:172-174` omits `comptime-quota` (which does write `.guardian/comptime-quota.txt`).
  **Fix:** "Four checks are snapshot-based: pub-api-surface, panic-budget, spec-drift,
  comptime-quota."
- **[Medium] Undocumented features:** the run-all skip cache (`src/cache.zig`, changes behavior
  every build, has an undiscoverable `cache_enabled` off-switch) and `disabled`. `CLAUDE.md`'s
  project-structure list also omits `baseline.zig`, `cache.zig`, `testing/`. **Fix:** add a
  "Skip cache" section; refresh the structure list.
- **[Medium] `minimum_zig_version = "0.14.0"` is stale** — `build.zig.zon:5`. Code uses
  0.15-only APIs (`File.stderr().isTty()` at `reporter.zig:110`; the buffered
  `file.writer(&buf).interface` at `snapshot.zig:67-69`). A 0.14 consumer gets cryptic errors
  instead of the clear gate. **Fix:** bump to `"0.15.0"`.
- **[Medium] `spec-drift` is stricter than its own spec bullet and ~redundant with
  `pub-api-surface`** — `spec_drift.zig:24-52`. SPEC says "fails when an *existing* pub fn
  signature changes," but it also fails on pure additions (which `pub-api-surface` already
  catches → two failures, two snapshots for one action); it never actually reads SPEC.md despite
  its name/fix-hint. **Fix:** fold `proto_span` into the `pub-api-surface` snapshot and delete
  `spec-drift`, or make it fail only on changed prototypes of symbols present in both snapshots.
- **[Medium] Self-hosting is incomplete:** `test-coverage` is *not* enabled on Guardian itself
  (no `[test_coverage]` in `guardian.toml`) — the one check that would have hinted at the dead-test
  problem — while `README.md:38` claims all checks gate the self-build. **Fix:** enable it with
  `exempt_names` for entry points.
- **[Medium] `spec-init` placeholders are engineered to pass `spec-quality`** —
  `spec/init.zig:57-73`, `spec_quality.zig:13-23`. `- foo: describe its observable behavior`
  clears the 20-char min and contains no forbidden phrase, so an unedited generated spec stays
  green forever. **Fix:** add `"describe its observable behavior"` to the forbidden phrases.
- **[Medium] `spec-init` bypasses the check contract** — `spec_init.zig:6,21,30-41` calls
  `std.process.exit(1)` (skipping cleanup) and aliases `std.debug.print` (which also sidesteps
  Guardian's own debug-print ban). **Fix:** `return error.CheckFailed`; print via `reporter`.
- **[Low] Help output omits `all`** (the primary command) — `registry.zig:135-142` iterates
  `registry.all`, which doesn't contain `all`; unknown commands aren't named; the `{s:<14}` column
  is narrower than several command names. **Fix:** print an explicit `all` entry; emit
  `unknown command: <name>`; widen the column.
- **[Low] `doc_quality` placeholder detection is effectively dead** — `doc_quality.zig:15-22,
  38-40`. Exact-match against phrases that are already below the 12-char `min_chars`; realistic
  `/// TODO: document this properly` passes. **Fix:** case-insensitive *contains*.
- **[Low] `stringly-typed-switches` guards a compiler-rejected pattern** — Zig 0.15.1 rejects
  `switch` on strings at compile time (Guardian gates `zig build`, so such code never compiles).
  The real idiom — `if (std.mem.eql(u8, s, "a")) ... else if (...)` chains (used in Guardian's
  own `config.zig:249-260`) — is undetected. **Fix:** repurpose to flag N+ `std.mem.eql` against
  the same subject (suggest `std.meta.stringToEnum`), or remove.
- **[Low] `usingnamespace-ban` spec/behavior mismatch** — spec says "outside test files"
  (`usingnamespace_ban.zig:11`) but it scans all of `src/`; and the construct no longer compiles
  on 0.15+, so it's a removal candidate once 0.14 support is dropped.

---

## Self-inflicted tech debt (`guardian.toml`)

Every current override is a **project-wide** limit raise to accommodate a handful of named
functions — which removes protection from *all* new code. Guardian already ships the right
mechanism (`[baseline]`) and its own `ZIG-PRACTICES-ADOPTION.md §4.1` calls the per-item ratchet
"the most important self-improvement," but baseline is not enabled on self. The single highest-value
move here is: **restore default thresholds + `[baseline] enabled = true`**, freezing today's
offenders as a shrinking ratchet.

| # | Knob | Set / default (×) | Named offenders | Pay down? |
|---|------|-------------------|-----------------|-----------|
| 1 | `[complexity] max_score` | 80 / 15 (5.3×) | `parse`, `analyze`, `parseContent` state machines | **Yes** — worst ratio; baseline at 15, then split token dispatch into per-tag handlers |
| 2 | `[function_length] max_lines` | 230 / 60 (3.8×) | `config.parse` (~217 lines), token visitors | **Yes** — table-drive `config.parse` (a Section→field map deletes ~150 lines) |
| 3 | `[anytype_budget] max_per_file` | 7 / 2 (3.5×) | `reporter.zig` format args | **No** — `args: anytype` is the only idiom; scope via baseline, not project-wide |
| 4 | `[returns_per_fn] max_returns` | 10 / 3 (3.3×) | `suspicious`, `classify` matchers | Partial — ratchet to ~6; early-return matchers are idiomatic |
| 5 | `[type_size] max_fields` | 30 / 7 (4.3×) | `Config` aggregator (20, climbing) | Partial — tighten to 21 now (free); sub-struct split is churn, defer |
| 6 | `[nesting_depth] max_depth` | 8 / 4 (2×) | alloc-hygiene / debug-print token chains | Yes, with #1 — same refactor |
| 7 | `[line_length] max_len` | 220 / 120 (1.8×) | registry one-liners; 106 lines >120 | **Yes, cheapest win** — wrap registry entries, ratchet to 140 |
| 8 | `max_file_lines` | 650 / 500 (1.3×) | `ast/parser.zig` (631) | Later — splitting six query families is real work |
| 9 | `[function_size] max_params` | 5 / 4 (1.25×) | `walk.walkZigFiles`, `snapshot_helper.lifecycle` | **No** — bundling touches 35 call sites for one param; accept + document |

Also: `GoldenError = anyerror` (`testing/golden_runner.zig:8-11`) exists, by its own admission, to
pass `error-discipline` while accepting arbitrary errors — simultaneously debt *and* proof that
`error-discipline` is blind to `pub const X = anyerror` aliases. Fix both: give the runner a real
error set and teach the check to resolve single-level `anyerror` aliases.

---

## Suggested additions

- **A meta-check: "test-root drift"** — every `src/checks/*.zig` must be referenced from the test
  root. This is a generic AI mistake and would have caught P0-1.
- **A general alloc-leak heuristic** (not just in `init`): flag `try allocator.alloc/create/dupe`
  whose result has no `defer`/`errdefer`/`toOwnedSlice`/return-transfer in the same block. The
  most common AI memory mistake; nothing catches it outside init-named fns today.
- **More bans on the existing engine:** `std.process.exit` outside main; `std.process.args*`
  outside main/config; `std.io.getStdOut/getStdErr` writes outside main/reporter. Each is one
  rules table.
- **`snake_case` fn enforcement + file-name conventions** in `naming` (highest value per line).
- **Expand the golden-fixture harness** — it covers only 3 of 56 checks; the rest assert only
  violation *counts*, so a check could report the wrong line for every violation and still pass.
  Migrate the semantically-hard checks (catch/alloc/complexity, the ban family) to golden
  scenarios and assert message + `file:line`.
- **`--version` flag** on `guardian-check`, and mix a Guardian build identifier into the cache
  digest so a dependency bump invalidates the skip-cache (today a downstream Guardian upgrade
  keeps skipping against a stale green state).

## Suggested removals

- `stringly-typed-switches` in its current (compiler-redundant) form.
- `spec-drift` (fold into `pub-api-surface`).
- `init_hygiene`'s blanket control-flow ban (or merge into `errdefer_in_init` as one
  "constructor discipline" check) — weakest signal-to-noise as a hard block.
- Dead code enumerated in Priority 6 (`hasPrecedingDocComment`, `FnInfo.return_kind`,
  `dup_const.prev_was_pub`, the `repeated_string_literal` keep-alive hack, the `guardian-zig`
  symlink).

---

## Recommended sequencing

1. **P0-1** (test root) — nothing else can be trusted until the tests actually run; it's also the
   only finding that breaks the product's core guarantee outright. Fix the 5 nonexistent-assertion
   calls it exposes.
2. **P0-3** (walker fail-open) and the **`FileEntry.content` → `[:0]const u8`** change together —
   small, and the latter deletes most of the memory waste *and* per-check `dupeZ` boilerplate.
3. **P0-2** (container recursion in `parser.zig`) — one change, ~15 checks upgraded. Roll out
   per check with regression tests.
4. **P0-4** (tags-on-tests) — makes the 1:1 guarantee real; do after P0-1 so the migrated tags
   land on tests that run.
5. Priority-1 correctness bugs (dup_const, file_size, magic_number, tagged-union classification,
   the ignored `enabled` flags).
6. Documentation pass (P7 highs: rollout snippet, check counts, zig version) — cheap, high
   credibility impact.
7. `guardian.toml` → defaults + `[baseline] enabled = true`, then chip away at the debt table.
8. Priority 2–3 FP/FN tuning and the Priority 6 consolidation refactor
   (`per_fn_metric`/`runAnalyze` helpers, shared `lineOf`, `Violation` adoption).
