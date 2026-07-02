# Guardian-Zig: Zig Compiler Practices Adoption Report

This report mines the Zig compiler source for design practices across seven lenses
(data-oriented design, memory allocators, error handling, module architecture,
complexity management, comptime/generics, naming/API, safety/assertions) and maps
each practice against guardian-zig's existing check inventory. Each practice is
classified as **already-covered**, **new-check-candidate**, or **judgment-only**
(review-checklist material).

---

## 1. Executive summary

- **Guardian's core mandate is well-covered.** The highest-ROI architectural and
  error-discipline practices from the Zig source — acyclic imports, layered
  boundaries, named error sets over `anyerror`, errdefer in init paths, catch
  discipline, init/deinit symmetry, doc-comment presence — already map cleanly onto
  existing checks (`imports`, `boundaries`, `error_discipline`, `errdefer_in_init`,
  `catch_discipline`, `init_deinit_symmetry`, `doc_comments`).
- **Five genuinely new check candidates emerged**, but only two are worth prioritizing:
  **snake_case field-name enforcement** (medium, high-frequency AI mistake, fully
  mechanical) and **module-level `//!` doc headers on large files** (medium, cheap
  navigation aid). The remaining three are lower-priority or partial-confidence.
- **One important caveat against guardian's own philosophy surfaced:** the Zig team
  *deliberately* keeps some functions long (e.g. `analyzeBodyInner` at ~870 LOC) when
  splitting would obscure a single coherent algorithmic stage. Guardian's hard-block
  `function_length`/`cognitive_complexity` caps need an **audited per-function
  baseline/suppression ratchet** so justified monoliths can be frozen rather than
  harmfully fragmented.
- **Most data-oriented-design, comptime, and safety-assertion idioms are judgment-only.**
  They are positive performance/design patterns whose *absence is not a defect*; a
  linter cannot adjudicate them without high noise. They belong in a review checklist.
- **The most defensible memory-safety candidate** is detecting slices/pointers into an
  `ArrayList(.items)` captured across a reallocating mutation (`append`/`resize`/
  `ensureTotalCapacity`) — a real use-after-free class, though it needs flow-sensitivity
  to stay low-noise.
- **Guardian should also dogfood** two of the mined practices on its own source:
  file-as-struct `@This()` naming and `//!` module headers.

---

## 2. Recommended new checks (prioritized)

Five distinct new-check-candidates were surfaced across lenses (de-duplicated below).
Ordered high → low by net priority/confidence.

### 2.1 `field_naming` — snake_case struct/union field names *(MEDIUM, checkable: yes)*

- **Practice (naming-api):** snake_case for struct/union field names and local variables.
- **Gap:** The existing `naming` check validates casing of pub fns and pub field-bearing
  *type* names only; it does **not** check that struct/union **field** names are
  snake_case. Zig's compiler does not enforce field casing either, so this is a real gap.
- **Why it matters:** AI agents frequently emit camelCase/PascalCase fields (carryover
  from other languages). High-frequency, mechanical, deterministic.
- **Mechanism:** For each `container_field_init`/struct-field AST node, extract the
  identifier; flag if `caseKind(name)` is `.pascal` or `.camel` (i.e. contains an
  uppercase letter). Reuse `naming.zig`'s `caseKind` helper. Allowlist all-uppercase
  single-segment SCREAMING_CASE for comptime-known consts. **Threshold:** any violation
  fails. Scope to fields (optionally container-level const non-type bindings); **skip
  local variables** to avoid noise on intentional acronyms.

### 2.2 `module_doc_header` — `//!` header on large files *(MEDIUM, checkable: partial)*

- **Practice (complexity-management):** Clear section headers via module-level `//!`
  doc comments at file start.
- **Gap:** `doc_comments` targets pub fn / pub type declarations, not file-level `//!`
  module docs. A leading `//!` block is a cheap, high-signal navigation aid for large
  files and an easy AI-agent miss when generating new modules.
- **Mechanism:** For each `.zig` file whose line count exceeds a threshold (e.g. 200 LOC,
  reuse `file_size` config), check that the first non-blank tokens form a contiguous
  `//!` doc-comment block of at least N characters (e.g. 40) before the first
  declaration. Fail if a large file has no leading `//!` block or only a stub. Exclude
  test and generated files. Presence + non-trivial length only; leave substance to review.

### 2.3 `arraylist_slice_escape` — captured slice/ptr across reallocation *(MEDIUM, checkable: partial)*

- **Practice (data-oriented-design):** Index Slices for stable lifetime references into
  dynamic arrays. The positive idiom is storing `{start,len}` indices and lazily
  dereferencing via `get()`; the *negative* case is the real defect.
- **Why it matters:** Holding `&list.items[i]` or a slice of `list.items` across an
  operation that may reallocate (use-after-free / aliasing) is a genuine, common
  memory-safety defect class — a better fit for guardian's mandate than the other DOD
  perf idioms.
- **Mechanism (heuristic, report candidates):** Flag a slice/pointer derived from an
  `ArrayList(.items)` (or `list[i]`) bound to a field, or to a local later read after an
  `append`/`insert`/`ensureTotalCapacity`/`resize` call on the *same* list within the
  function. **Threshold:** only fire when a mutation call on the same receiver appears
  between capture and last use. Needs flow-sensitivity to avoid noise (do not flag
  immediate uses).

### 2.4 `unreachable_explanation` — comment on bare `unreachable` *(MEDIUM, checkable: partial)*

- **Practice (safety-assertions):** Unreachable with explicit reason comments for
  impossible branches.
- **Gap:** `panic_budget` only *counts* `unreachable`/`@panic` tokens and ratchets them
  down; it does not require each to carry justification. `stub_body_ban` catches
  lone-statement `unreachable` bodies but not inline `unreachable` branches inside
  switch/if. AI agents emit bare `unreachable` as lazy fallthrough.
- **Mechanism:** Tokenize; for each `keyword_unreachable` token that is NOT a function-body
  stub (already covered by `stub_body_ban`), require either a `//` comment on the same
  line after it or a comment line immediately preceding the enclosing prong/branch. Flag
  bare `unreachable` with no adjacent comment. Optional allowlist for `else => unreachable`
  if too noisy. Pair with `panic_budget` rather than duplicate counting. *Cannot judge
  comment meaningfulness — hence partial.*

### 2.5 `file_as_struct` — TitleCase file ⇄ `@This()` self-type *(LOW, checkable: partial)*

- **Practice (module-architecture):** File-as-Struct naming convention (TitleCase for
  major modules). Verified: `Air.zig`/`Sema.zig`/`Zcu.zig` all use `const X = @This();`
  matching the filename.
- **Gap:** `naming` enforces casing of pub decls but not the file-as-struct convention.
- **Mechanism (one-directional, filename-driven):** For each `.zig` file whose basename is
  TitleCase, require a top-level `const <Basename> = @This();` and at least one file-scope
  field. Conversely, flag a `const X = @This()` whose name does not match the filename.
  **Caveat:** lowercase namespace files (`codegen.zig`, `target.zig`, `link.zig`) are
  legitimately NOT structs, so the check must be filename-driven and one-directional.

### Lower-confidence / advisory-only candidates (do NOT hard-block)

- **Predicate-prefix naming** (naming-api): a pub fn matching `/^(is|has|can|should)[A-Z]/`
  whose return type is not `bool` is the high-confidence direction; the reciprocal
  (bool-returning fns lacking an `is/has/...` prefix) is noisy (`eql`, `contains`,
  `matches`). Ship advisory/report-only at most, never hard-block.
- **Allocator-passing-vs-storage** (memory-allocators): **NOT recommended.** Directly
  contradicts guardian's allocator-injection model and `init_deinit_symmetry`, which assume
  structs *do* store an allocator field. High noise, low signal.
- **Index newtype suggestion** (data-oriented-design): flagging bare `u32`/`usize` fields
  named `*_index`/`*_idx` to suggest `enum(u32)` newtypes is extremely noisy in normal
  application code and specific to arena-heavy compiler code. Likely too noisy to ship.

---

## 3. Already covered (confirmation)

| Practice (lens) | Existing guardian check |
| --- | --- |
| Explicit named error sets over `anyerror` (error-handling) | `error_discipline` |
| Avoidance of `anyerror` in public APIs (error-handling) | `error_discipline` |
| Exhaustive error handling via switch (error-handling) | `catch_discipline` (+ Zig compiler exhaustiveness, Tier 0) |
| errdefer for allocation cleanup in init paths (memory-allocators) | `errdefer_in_init` |
| Paired allocation/deallocation w/ ownership (memory-allocators) | `init_deinit_symmetry` + `errdefer_in_init` |
| Explicit imports at top; no circular imports (module-architecture) | `imports` (+ `boundaries`, `orphan_files`) |
| Subdirs import parent via `../`; parent re-exports (module-architecture) | `boundaries` + `imports` (configuration) |
| Public vs private struct boundary as contract (module-architecture) | `pub_api_surface` (+ `dead_pub`, `spec_drift`) |
| `@setEvalBranchQuota` to manage comptime cost (comptime-generics) | `comptime_quota` |
| TitleCase types/type-fns, camelCase fns (naming-api) | `naming` |
| Minimal public surface via nesting/private details (naming-api) | `pub_api_surface` + `struct_method_cap` + `type_size` + `dead_pub` |
| Multi-level switch nesting / leaf extraction (complexity-management) | `nesting_depth` + `cognitive_complexity` |
| Extracting tight leaf functions (complexity-management) | `function_length` (forcing function) |
| Dense doc comments on pub decls (complexity-management) | `doc_comments` + `doc_quality` |

**Notable refinement (not a gap):** `errdefer_in_init` currently passes if *any* single
`errdefer` appears in a body with multiple `try`s — a fn with three allocations guarded by
one errdefer still passes. A stricter version would pair errdefer count/position against
allocating-try count, but that risks false positives. Current heuristic is a reasonable
high-ROI gate.

---

## 4. Guardian self-improvements

Concrete changes guardian-zig's **own source** could adopt:

1. **Add an audited per-function baseline/suppression ratchet for `function_length` and
   `cognitive_complexity`.** This is the most important self-improvement. The Zig team
   intentionally keeps `analyzeBodyInner` at ~870 LOC because it is one coherent
   algorithmic stage; splitting would hide control flow. Guardian's hard-block 60-LOC cap
   with no escape hatch would force harmful extraction on exactly the dispatcher pattern
   the complexity lens documents as *good*. A visible, auditable freeze (consistent with
   guardian's stated baseline/freezing principle) converts the wall into a ratchet.
2. **Adopt `//!` module-doc headers on guardian-zig's own modules** to model practice 2.2
   before/while shipping the `module_doc_header` check (dogfooding).
3. **Adopt the file-as-struct `@This()` idiom** in guardian-zig's TitleCase source modules
   to model practice 2.5.

---

## 5. Judgment-only practices (review-checklist material)

These are positive design idioms whose absence is not a defect, or whose correctness
requires semantic/whole-program reasoning beyond an AST/tokenizer linter. Capture them in a
review checklist, not a gate.

**Data-oriented design / memory layout**
- MultiArrayList (SoA) vs ArrayList(Struct) — access-pattern tradeoff; profile-and-decide.
- Payload indirection via extra-array indices; `@sizeOf(Data) == 8` comptime assertions
  live in the code that owns the layout.
- Packed structs for sub-byte encoding — density-vs-clarity tradeoff.
- InternPool content-addressed interning; thread-per-shard atomic acquire/release —
  large architecture / concurrency-correctness, out of charter.
- Wrap/Unwrap bit-packing of composite indices — too niche; encapsulation already
  culturally covered by `naming`/`boundaries`.

**Memory allocators (lifetime reasoning a linter cannot do)**
- Dual gpa+arena architecture; scoped arenas for transient work; arena at module creation;
  gpa for selectively-freed collections; explicit allocator-param-in-deinit (the codebase
  validly uses both stored-allocator and param-allocator forms — enforcing one yields
  false positives). `allocator_hygiene` already covers the orthogonal injection concern.

**Error handling (domain/diagnostics architecture)**
- Error-set union `||` composition; sentinel errors (`AlreadyReported`/`AnalysisFail`);
  recoverable-vs-unrecoverable out-param diagnostics; retryable-failure tracking;
  error messages as first-class owned values. All specific to a multi-pass
  compiler/diagnostics-collector architecture.

**Module architecture**
- Module split decision (Foo.zig + Foo/) — `file_size` is the actionable lever; PerThread
  wrappers; deep backend hierarchy with inline `importBackend()` dispatch; nested
  Tag/Data/Error helper grouping (`type_size` indirectly nudges decomposition).

**Complexity management**
- Massive switch dispatchers with delegating arms; semantic `zir*`/`failWith*` prefixes;
  grouping helpers by domain; **deliberate tolerance of long functions** (see §4.1).

**Comptime / generics** (positive idioms; absence ≠ defect)
- Enum/slice discriminators vs `comptime T: type`; `inline for` over comptime slices;
  if-else return-type expressions; tagged unions vs monomorphic generics; per-arm distinct
  return structs; inline dispatch vs overloads; comptime-int fixed-size array constraints.

**Naming / API**
- Index-newtype `.none` sentinel + Optional companion; `to*`/`from*` conversion prefixes;
  dual `*Ip` InternPool variants; nested-namespace organization depth.

**Safety / assertions** (semantic / whole-program; mostly out of scope)
- Semantic ops doubling as layout asserts; `if (std.debug.runtime_safety)` gating;
  comptime version/schema asserts (cannot know *where* warranted); lock-guarded
  cross-thread asserts; inter-phase precondition-documenting asserts; aggregate
  "at least one defined field" invariant; `*AssumeCapacity` precondition (needs
  interprocedural capacity tracking).

---

## 6. Caveats

- **Zig version drift.** The mined Zig compiler source may differ syntactically from the
  reader's version (e.g. `usingnamespace` removed in 0.15, AST node names evolve). All
  recommendations here are **design-level**; treat specific AST node names
  (`container_field_init`, `keyword_unreachable`, etc.) as illustrative and re-confirm
  against your tree's `std.zig.Ast` before implementing.
- **Partial-checkability candidates need real false-positive tuning.** Sections 2.2–2.5
  are marked partial because they either cannot judge *meaningfulness* (doc/comment
  substance) or require flow-sensitivity (slice-escape). Ship them report-only first and
  promote to hard-block only after measuring noise on real codebases.
- **Guardian deliberately scopes out concurrency-correctness and lifetime-semantics.**
  Several high-value Zig practices (atomic ordering, lock-guarded asserts, arena-vs-gpa
  lifetime choices) are real and important but fall outside a tokenizer/AST linter's
  charter; they are review-checklist items by design, not gaps.
