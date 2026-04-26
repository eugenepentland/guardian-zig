# A framework for code that stays easy to change

The thesis you build the framework around is simple and well-supported: **a codebase's testability is a leading indicator of its change-cost**, and the structural traits that make code easy to test are largely the same ones that let teams iterate quickly as the code grows. Misko Hevery puts it bluntly — "whether or not a piece of code is easy to test is a function of the structure of the code, not what the code does." The implication is that the highest-leverage automated rules are not stylistic preferences but **rules that prevent hidden dependencies, enforce dependency direction, and bound complexity** so that pure-function testing remains the default rather than the exception.

Two ideas anchor the rest of this report. **First**, every code-quality concern decomposes into a *mechanically checkable component* (suitable for a linter or build-time fitness function) and a *judgment component* (suitable for a review checklist). Conflating them is what makes most "best practices" documents either toothless or annoying. **Second**, of the three forces in tension — easy to test, easy to change, easy to read — testability is the only one with concrete structural prerequisites you can enforce. Optimize for testability and the others largely follow; optimize for the others first and you'll keep paying a testability tax.

What follows is a framework specification: tier-ordered static rules with thresholds and rationales, a parallel review checklist with guiding questions, Zig-specific considerations, and an implementation roadmap.

---

## The philosophy of easy to test, easy to iterate

The empirical case rests on a few converging lines of evidence. **DORA's research** (Forsgren, Humble, Kim, *Accelerate*) shows that trunk-based development with small batch sizes and continuous testing strongly correlates with elite engineering performance — both throughput and stability. **Adam Tornhill's** crime-scene analysis finds that a small fraction of files (often around 4%) accounts for the majority of defects (~72% in his study), and these hotspots are reliably identifiable from change-coupling and complexity metrics. **John Ousterhout** argues that complexity is the cumulative effect of decisions (interface size, information leakage, change amplification), and that strategic programming — paying small ongoing costs to keep complexity down — is dominant over tactical programming on multi-year projects.

The structural traits that make code testable are the same ones that bound change cost. **Pure functions** require no setup, no mocks, no order dependencies; they're also trivially refactorable. **Injected dependencies** make seams visible at the type signature, which means both that a fake can substitute and that a maintainer can read the dependencies without grep. **Dependency direction rules** (domain ← infrastructure, never the reverse) keep the testable core insulated from volatile I/O, and they also keep the codebase replumbable. **Bounded complexity** keeps the human reviewer's working memory from saturating during refactoring. The rules in this framework are unified by the goal of keeping these traits the path of least resistance.

The framework is structured as **three layers** of enforcement: hard static rules that fail the build, soft static rules that warn, and review checklist items that prompt human conversation. Each rule is tagged by the priority tiers in the final section so you can roll the framework out incrementally.

---

## Statically enforceable rules

The rules below are all mechanically checkable. Recommended thresholds are drawn from established sources (McCabe, SonarSource, Clippy, golangci-lint, Clean Code, Code Complete) and tuned for a Zig-targeted but language-agnostic framework. Tooling-difficulty annotations: **E** = AST/regex; **M** = control-flow or type info; **H** = whole-program graph analysis.

### Complexity and size budgets

The single best-validated rule family. Defects rise sharply at the high tail of complexity, and high-complexity functions are also where bugs hide from review. Start strict; relax with explicit, reviewed exemptions.

| Rule | Threshold | Source | Difficulty |
|---|---|---|---|
| **Cyclomatic complexity per function** | ≤ 10 (≤ 15 with rationale) | McCabe 1976; NIST 500-235; SonarSource | M |
| **Cognitive complexity per function** | ≤ 15 | Campbell, SonarSource white paper | M |
| **Function length (LOC, non-blank/non-comment)** | ≤ 60 | golangci-lint funlen, Clean Code stricter at 20 | E |
| **Function length (statements)** | ≤ 40 | golangci-lint funlen.statements | E |
| **Parameter count** | ≤ 4 (≤ 7 hard cap) | Clean Code; ESLint `max-params` 3; Sonar S107 default 7 | E |
| **Nesting/block depth** | ≤ 4 | ESLint `max-depth`; SonarQube S134; Linux kernel | E |
| **Boolean operators per condition** | ≤ 3 | Checkstyle `BooleanExpressionComplexity` | E |
| **Returns per function** | ≤ 3 | SonarQube S1142 | E |
| **File length** | ≤ 500 lines (≤ 1000 hard cap) | Google Java Style; Sonar S104 | E |
| **Module/struct length** | ≤ 300 lines, ≤ 20 public methods, ≤ 7 fields | PMD; Clean Code; Metz | E |
| **Line length** | ≤ 100 (or ≤ 120) | Google Java Style; Black 88; PEP 8 80 | E |
| **NPath complexity** | ≤ 200 (rough indicator only) | Nejmeh 1988; Checkstyle | M |

The function-length rule is the one place where authorities disagree most: Sandi Metz says 5 lines, Clean Code says 20, Code Complete tolerates 200. Empirical research finds a U-shape — very short and very long both correlate with higher defects. **A 60-line ceiling with a hard 100-line cap, plus a strict cyclomatic limit, captures the practical benefit without inviting over-shattered code (Ousterhout's "classitis").**

### Dependency direction and architectural fitness

These are the highest-leverage architectural rules — a single layer-import policy delivers more design value than any complexity threshold. **Acyclic Dependencies and a layered import allow-list together comprise the architecture-as-code core.**

| Rule | What to check | Source | Difficulty |
|---|---|---|---|
| **Acyclic Dependencies Principle** | 0 cycles in module/package import graph | Martin, *Clean Architecture* | H |
| **Layered import allow-list** | `domain/` cannot import `adapters/`/`infra/`/framework code; `adapters/` cannot import other adapters; only `main`/`wiring` may import concrete adapters | Cockburn (Hexagonal); Martin | M |
| **Forbidden imports per layer** | Configurable deny-list (e.g., `std.fs.*`, `std.net.*` outside `infra/`) | ArchUnit, dependency-cruiser | M |
| **No production code imports test code** | `*_test.zig`/`tests/` not imported from prod | dependency-cruiser `not-to-test` | E |
| **Stable Dependencies Principle** | Dependencies point toward more stable (lower I) modules; flag upward edges | Martin 1994 | H |
| **Distance from main sequence** | D = \|A + I − 1\| ≤ 0.3 per package | Martin 1994; NDepend | H |
| **Public API surface budget** | Track and cap `pub` symbols per module | Custom; cargo-public-api equivalent | M |
| **Each port has ≥ 2 implementations** | Real adapter + in-memory fake required for every port interface | Cockburn; GOOS | M |

### Hidden dependency bans (the testability core)

Every nondeterminism source must be injected, not acquired. **This rule family is the single highest-ROI testability investment** — it eliminates the most common reason tests become slow, flaky, or impossible to write. Implement as scoped banned-symbol lists per directory.

| Hidden dep | What to ban outside the wiring layer | Zig-specific symbols |
|---|---|---|
| Time | All "now" calls outside `infra/clock.zig` | `std.time.timestamp`, `std.time.nanoTimestamp`, `std.time.Instant.now` |
| Randomness | Direct construction of RNGs outside `infra/random.zig` | `std.crypto.random`, `std.Random.DefaultPrng.init` |
| Filesystem | All FS calls outside `infra/fs.zig` | `std.fs.*`, `@cImport` to `<stdio.h>` |
| Network | Sockets/HTTP outside `adapters/http/` | `std.net.*`, `std.http.*` |
| Process/env | Env reads outside `config/`/`main` | `std.process.getEnvVarOwned`, `std.posix.getenv` |
| Logging | Direct prints outside the logger adapter | `std.debug.print`, `std.log.*` |
| Sleep | Outside test infra | `std.Thread.sleep` |
| Globals | Mutable file-scope state in non-wiring modules | `pub var` of struct types |
| Hardcoded paths/URLs | Regex check on string literals | `/etc/*`, `C:\\*`, `http://*` literals |
| Construction of "heavy" types | DB clients, HTTP clients, file handles outside `main`/`wiring` | Project-defined deny-list |

### Construction and dependency injection

Misko Hevery's "Flaw #1" — constructors doing real work — is the diagnostic that catches most untestable code. The static check is straightforward: `init` must be straight-line field assignments.

The rule is that **`init`/constructors contain no loops, no conditional branching, no I/O, and only trivial calls** (typically other `init`s of subcomponents). Constructor parameter count caps at 5–7; more signals an SRP violation. Static factory calls inside business logic (`Database.getDefault()`, `Registry.get(T)`) are forbidden — they reintroduce hidden dependencies the type system can't see. Singletons via `var instance: ?T = null; pub fn get()` are flagged. Zig adds an allocator-specific rule: **any `pub fn` that allocates must take an `Allocator` parameter or be a method on a struct with an `allocator:` field**, and any struct with that field must declare `pub fn deinit`.

### Code duplication

| Rule | Threshold | Tools |
|---|---|---|
| **Project duplication ratio** | < 3% of LOC | SonarQube quality gate; jscpd |
| **Token-based clone min size** | ≥ 50–100 tokens / ≥ 5 lines | PMD CPD; jscpd; golangci-lint `dupl` |
| **Repeated string literal → constant** | ≥ 3 occurrences | golangci-lint `goconst`; SonarQube S1192 |
| **Identical switch-case bodies** | 0 | SonarQube S1871; Clippy `match_same_arms` |
| **Magic numbers** | Allowlist `-1, 0, 1, 2`; named constant otherwise | ESLint `no-magic-numbers`; SonarQube S109 |

The DRY caveat (Sandi Metz, "the wrong abstraction is more expensive than duplication") matters here: **duplication detectors should report, not block.** Surface candidates for review; let humans decide whether the duplication is knowledge (extract) or coincidence (leave alone). The Rule of Three — wait for the third occurrence before extracting — should be a team norm, not a tool rule.

### Dead code and unused symbols

Zig's compiler already enforces unused locals, parameters, imports, and shadowing as **hard errors**, which puts it ahead of most languages. The framework adds whole-program rules:

The static checks: unreachable code after `return`/`unreachable`/`break`; unused private fields and functions; unused public APIs (whole-workspace reachability); orphan modules with no incoming dependencies; permanently-disabled feature flags. Empty catch / suppressed-error patterns (`catch unreachable`, `catch {}`) outside narrow whitelisted contexts are flagged — Zig's equivalent of Java's empty catch and a top source of swallowed bugs.

### Error handling

| Rule | Detail |
|---|---|
| **Errors must be handled** | No silent discard of error returns; Zig already requires `try`/`catch`/`_ =` |
| **No `catch unreachable` outside whitelist** | Whitelist: `comptime` blocks, tests, immediately preceding sized-buffer guarantees |
| **No empty catch without comment justifying** | Suppressed-error rule (zlint `suppressed-errors`) |
| **No `anyerror` in public function returns** | Forces narrow error sets; preserves caller's exhaustive `switch` |
| **Required diagnostic out-param when error is informational** | If error needs context beyond a tag, take `*Diagnostics` (RFC #2647 pattern) |
| **Resource cleanup paired** | Every alloc/open call needs matching `defer`/`errdefer`/free |

### Naming conventions

For Zig, follow the official style guide mechanically: `TitleCase` for types and type-returning functions, `camelCase` for callable functions and methods, `snake_case` for variables/fields/parameters/namespace files, no `SCREAMING_SNAKE` (even constants are `snake_case`), acronyms as words (`HttpServer` not `HTTPServer`). Files named `TitleCase.zig` if the file is itself a struct, `snake_case.zig` if it's a namespace. Beyond casing, **the framework should ban a curated list of vague names** (`tmp`, `data`, `info`, `obj`, `foo`, `bar`, `mgr`, `Helper`, `Util`, `Manager`, `Processor`) outside specific contexts; flag boolean variables/methods that don't begin with `is`/`has`/`can`/`should`/`will`/`does`.

### Anti-pattern detectors

The mechanically detectable subset of Fowler's catalog:

| Smell | Detection |
|---|---|
| **Long parameter list** | Parameter count > 4–5 |
| **Boolean parameter / flag argument** | Any `bool` parameter in `pub fn`; warn or block |
| **Same-type-adjacent parameters** | Two consecutive parameters of identical type — positional confusion risk |
| **Data clumps** | Recurring 3+ parameter tuples across signatures (clique analysis) |
| **Train wreck / Law of Demeter** | Member-access depth > 2 (excluding fluent chains) |
| **Repeated switch on same enum** | Same discriminant switched in > 1 file |
| **Middle man** | Class where > 50% of methods are `return other.method(...)` |
| **Feature envy** | Method's foreign-class accesses outnumber self-accesses |
| **Optional density** | > N% of struct fields are `?T`; unwrap chains > 2 deep |
| **Stringly-typed switches** | `switch` over string literals where enum/union exists |

### Tests as code

Apply the framework's static rules to test files too, with one critical addition: **every `test` block must contain at least one `try std.testing.expect*` call**, ensuring no assertion-free tests slip through. Other rules: limit assertions per test (warn ≥ 8 — eager-test smell); ban conditional logic (`if`/`for`) in test bodies beyond table-driven cases; cap mock/spy count per test (warn ≥ 3 — over-mocking is a design smell); ban `std.fs` outside designated fixtures directory (mystery-guest); enforce per-test timeouts (unit < 100 ms, integration < 1 s). Tests must be order-independent and parallel-safe, which Zig's per-test `std.testing.allocator` already encourages.

A higher-leverage policy for adoption on legacy code is **freezing baselines** (ArchUnit's `FreezingArchRule` model): record current violations, fail only on new ones. This converts the framework from a wall into a ratchet.

---

## Review checklist items

These require human judgment. Frame them as guiding questions, not verdicts; the goal is to prompt reviewer attention rather than block PRs.

### The single-responsibility lens

The "actor" formulation Robert Martin clarified in 2014 is the most useful: a module should be responsible to one actor, not "do one thing." Ask: **Which actor (role/stakeholder) drives changes to this module — and is there more than one?** If business rules and serialization both touch this file for unrelated reasons, the module sits on two axes of change and should split. Other prompts: Could this module's purpose be stated in one sentence without "and"? When two unrelated developers need to change this module for unrelated reasons, do their changes conflict? Does the name end in `Manager`, `Helper`, `Util`, or `Processor` — vague names that mask SRP violations?

### Abstraction quality (Ousterhout)

Ask: **Is this module deep (small interface, much hidden) or shallow (interface as complex as implementation)?** Shallow modules — the "classitis" pattern — multiply complexity rather than reducing it. Other prompts: How many concepts must a caller learn to use this module? Are pass-through methods and pass-through variables threading data through indifferent middlemen? Is information about format, structure, or algorithm leaking through method names or required call sequences? Does the interface comment describe implementation details the caller doesn't need? Was this name "hard to pick"? — a red flag for an ill-formed abstraction.

### Liskov and inheritance substitutes

Even in Zig, where there's no inheritance, the LSP question maps to vtable interfaces and tagged unions: **does each implementation actually satisfy the contract callers expect?** Ask: Does any implementation throw or no-op where the interface promised success? Does it return null/empty where the contract promised populated results? Does it strengthen preconditions or weaken postconditions? Are there `instanceof`/type-switches at call sites that special-case one implementation — a sign the contract is broken upstream?

### DRY discipline and the wrong abstraction

The framework should resist the DRY reflex. Ask: **Is this duplication of *knowledge* (must change together for correctness) or coincidental similarity?** If the rule changed in the future, would all copies need to change in lockstep? Have we seen this pattern at least three times before extracting? Is the proposed abstraction sprouting boolean parameters or conditional flags — Sandi Metz's diagnostic for the wrong abstraction? In tests specifically, is DRY costing readability? Tests should be DAMP (Descriptive And Meaningful Phrases), even at the cost of duplication.

### DDD modeling judgment

These cannot be automated at all. Ask: Does this aggregate model true (transactional) invariants only, or has it grown by compositional convenience? Are aggregates referenced by ID across boundaries, or by direct object reference (Vernon's rule 3)? When this concept has identity that matters across time, is it an entity; when it's defined by attributes only, is it a value object? Where do invariants live — on entities (proper) or on services (anemic-domain-model smell, Fowler)? Within this bounded context, does every term have one consistent meaning?

### Errors and Ousterhout's "define out of existence"

Ask: **Could this error be designed away by API choice?** (Ousterhout: Unix `unlink` doesn't error if the file is already gone; Tcl's `lindex` clamps out-of-range; this reduces handler proliferation.) Is the failure expected (use `Result`/`!T`) or a programmer error (panic)? Are we throwing because we couldn't think of what else to do, pushing complexity onto callers? Is validation at the boundary (good) or scattered defensively inside (bloat)? Are we silently swallowing errors callers genuinely need? This is contested — defensiveness has its place — so the question is the prompt, not the answer.

### Connascence and coupling type

Counting couplings is less informative than classifying them (Page-Jones). Ask: What kind of connascence couples these modules — name, type, position, algorithm, value, identity? Could a strong form (positional 5-arg call) be weakened to a name form (struct of named options)? Does strong connascence cross an encapsulation boundary? Train wrecks (`a.b.c.d`) signal that a caller depends on internals of others — could behavior move to the data (Tell, Don't Ask)?

### Tests as design feedback

Borrow Freeman & Pryce's "listen to your tests" — test pain is design pain in disguise. Ask: Is test setup huge? — too many collaborators (SRP). Need to mock a chain `a.b.c`? — Law of Demeter violation. Need to mock a third-party type? — missing adapter. Test changes whenever implementation changes? — coupled to internals. Tests assert call sequences with no real result? — tautological tests, often missing a return-value abstraction. Hard to construct the SUT? — constructor doing real work or missing DI. Tests slow or flaky? — hidden time/I/O/concurrency dependency.

### Strategic vs. tactical and Tidy First

Two prompts borrowed from Beck and Ousterhout: **Did this PR leave the code structurally better than it found it, or accumulate debt?** Could 5–15 minutes of tidying have made this change easier? Is this PR mixing structural changes with behavioral changes — should they be split into separate PRs? Is this a one-way door (irreversible — DB migration, public API) or a two-way door (reversible — internal refactor)? One-way doors deserve disproportionate scrutiny.

### Optimizing for change cost

Tef's "easy to delete" lens: **If we deleted this abstraction tomorrow, how much would the system protest?** Is this flexibility justified by current need or by speculation? Is there a second user, or is this an abstraction with one implementation? Carmack's variant: minimize "area under ifs"; consider inlining single-use helpers when the inline version makes execution-state surprises visible.

### Pace layering and shearing layers

Stewart Brand's insight applied to software: things that change at different rates belong in different layers. Ask: Which pace layer does this concern belong to (slow: data model, public API; mid: business workflows; fast: UI copy, A/B variants)? Does this commit cross pace layers — coupling slow-changing to fast-changing? Are rapidly-changing values (copy, prices, flags) embedded in compiled code where they should live in config?

---

## Zig-specific considerations

Zig (targeting 0.15.x as of April 2026) has properties that change which rules matter and how they're enforced. The big picture: **Zig's compiler is already a strict linter for many traditional concerns** — unused vars/params/imports, shadowing, unhandled error returns, non-exhaustive switches, mutable `var` that should be `const`. The framework should not redo this work; it should focus on what the compiler can't see.

### What the compiler already enforces (free wins)

Hard compile errors include unused locals/parameters/captures; identifier shadowing; non-mutated `var`; unreachable code; discarded error unions; non-exhaustive switches over enums and tagged unions without `else`; `@import` cycles. ReleaseSafe/Debug builds add runtime integer-overflow and pointer-bounds checks. `std.heap.DebugAllocator` (renamed from `GeneralPurposeAllocator` in 0.15) detects leaks, double-frees, and most use-after-frees. **These collectively cover ~30% of what other languages need linters for.**

### Patterns that don't translate (drop from rule catalog)

Skip anything assuming inheritance: classic Liskov machinery, Template Method, abstract-factory hierarchies, refused-bequest detection. Skip class-based DI containers; Zig idiom is parameter passing. Skip `null`-check rules; `?T` and `if (x) |val|` are the language solution. Skip exception-hierarchy rules; Zig's flat error sets carry no payload (RFC #2647 still open). Skip `usingnamespace` and mixin patterns — `usingnamespace` was removed in 0.15.

### Zig-specific rules to add

The defining idiom is **allocator injection**: any `pub fn` that allocates must take `std.mem.Allocator` or be a method on a struct holding one. Pair it with **`init`/`deinit` symmetry**: any struct with an `allocator:`/`gpa:` field must declare `pub fn deinit`. Forbid direct use of `std.heap.page_allocator`, `std.heap.c_allocator`, and `std.heap.smp_allocator` outside `main`/test setup. Prefer **unmanaged containers** (`std.ArrayListUnmanaged`, `std.AutoHashMapUnmanaged`) over the deprecated managed wrappers — and require module-level consistency.

Forbid `anyerror` in public function return types; require explicit error sets for public APIs and recursive functions. Limit `anytype` in `pub fn` signatures; it kills IDE help, defeats documentation, and was the explicit motivation for the 0.15 `std.Io` rewrite away from `anytype`-poisoned `Reader`/`Writer` interfaces. Require `errdefer` between sequential `try`s in `init` functions that allocate. Forbid `catch unreachable` outside narrow whitelisted contexts (comptime blocks, tests, sized-buffer guarantees). Forbid `@compileError` without a string-literal explanation.

### Tooling state

`zig fmt` handles all whitespace and structural formatting, intentionally non-configurable. **`zlint`** (DonIsaac, v0.8.x as of 2026) is the de-facto community linter with a semantic analyzer independent of the compiler — its `unsafe-undefined`, `homeless-try`, and `suppressed-errors` rules are immediately useful. `ZLS` provides parser-level diagnostics but cannot resolve complex `comptime`; the workaround is a build-on-save `check` step. There's no native coverage tool (issue #352 still open); **kcov** with Zig's DWARF info is the de-facto standard. The 0.14/0.15 fuzzer is experimental but pairs well with `testing.allocator` and `FailingAllocator` for memory-safety property testing.

### Zig-specific review prompts

For PR review, add: Is the allocator API consistent (caller-passes vs. owner-stores) within this module? Who owns the returned memory and which allocator frees it? If `init` returns by value, are `errdefer`s on individual fields rather than on `self` (which would double-free)? Are pointers into growable containers held across mutations? Is `comptime` generating types where a tagged union would suffice (binary-bloat risk)? Could `anytype` be replaced with `comptime T: type` (more legible) or a vtable interface (better for users)? Is there an OOM test using `FailingAllocator` or `checkAllAllocationFailures` for any code with multiple internal allocations?

---

## Suggested priority tiers for implementation

Roll out the framework in tiers; each tier should be stable before adding the next. **Tier 0 is what Zig's compiler gives you for free; Tiers 1–3 are where the framework adds value.**

### Tier 1 — Highest ROI, implement first

These six rule families together deliver most of the testability and change-cost benefits with modest implementation cost.

The first is **dependency direction enforcement**: layered import allow-list (`domain/` cannot import `adapters/`/`infra/`), 0 cyclic dependencies, only `main`/`wiring` may import concrete adapters. This single policy is more valuable than any complexity threshold — it guarantees the testable core stays insulated from volatile I/O, and the test suite naturally pyramids.

The second is **the hidden-dependency ban list**: time, randomness, filesystem, network, env, logging, sleep, and globals all forbidden outside their specific infrastructure modules. This is what makes pure-function testing the default rather than the exception.

The third is **constructor and DI hygiene**: `init` does no real work, no static factory calls in business logic, no service-locator/singleton patterns, no construction of "heavy" types outside the wiring layer. In Zig terms: allocator injection + `init`/`deinit` symmetry.

The fourth is **complexity and size budgets** at the function level: cyclomatic ≤ 10, cognitive ≤ 15, length ≤ 60 lines, parameters ≤ 4, nesting ≤ 4. Cheap to implement (mostly AST counting) and well-validated against defect data.

The fifth is **error handling discipline**: no `catch unreachable` outside whitelist, no empty catches without comment, no `anyerror` in public APIs, `errdefer` paired with allocating operations.

The sixth is **test hygiene**: every `test` block has ≥ 1 assertion; tests use `testing.allocator`; per-test timeouts; no FS/env outside designated fixtures.

### Tier 2 — Strong leverage, implement second

Module-level size and cohesion (file ≤ 500 lines; struct ≤ 300, ≤ 20 methods, ≤ 7 fields). Public API surface budget per module (track and cap `pub` symbols). Naming conventions per official style guide plus the curated vague-name blacklist (`Manager`, `Util`, `tmp`, etc.). Boolean-parameter detection (zero in public APIs). Magic-number and repeated-string-literal detection. Train-wreck / Law of Demeter depth ≤ 2. Same-type-adjacent parameter detection. Dead public-API and orphan-module detection.

### Tier 3 — Architectural fitness functions

Stable Dependencies Principle and Distance from Main Sequence (per-package instability/abstractness with D ≤ 0.3). Each port interface requires a corresponding in-memory fake. Code duplication ratio < 3% (with the caveat that this should report, not block). Mutation testing baseline tracking on the core/domain layer. Change-coupling/hotspot reports from git history (Tornhill-style) surfacing the top-N files for refactoring attention. Freezing baselines on legacy code.

### Tier 4 — Process and review affordances

PR size limits (warn at thresholds). Structure-vs-behavior PR tagging (Beck's Tidy First) with stricter review gates on behavior changes. ADR template required for tagged architecture decisions. Conventional Commits or equivalent for `refactor:` vs. `feat:` differentiation. Review checklist as a PR template, organized by the judgment categories above so reviewers don't miss an angle.

---

## Conclusion

The shape of the framework that emerges from this research is narrower than a typical "code quality" suite and more opinionated. **Drop the bottom 30% of style rules other linters obsess over** — Zig's compiler already handles the highest-leverage ones, and stylistic rules deliver diminishing returns past `zig fmt`. **Concentrate on the middle 50%** — dependency direction, hidden-dependency bans, complexity bounds, error-handling discipline — where each rule directly reduces both test cost and change cost. **Treat the top 20% as conversational** — DRY, abstraction quality, modeling decisions, naming beyond casing — surfaced through review checklists rather than build failures.

A non-obvious takeaway is that **the testability framing absorbs most other quality goals**. SOLID, hexagonal architecture, functional core/imperative shell, even the DDD distinction between aggregates and services — they all reduce, mechanically, to "make pure functions the default and inject everything else." If you build the framework around that single objective, you don't need separate enforcement campaigns for "good architecture" and "testable code"; they're the same campaign.

For Zig specifically, the framework should lean on three properties the language gives you free: a strict compiler that already enforces ~30% of traditional lint concerns, an explicit-allocator idiom that *is* dependency injection by another name, and a build system flexible enough to host fitness functions without adding a separate tool. The biggest implementation risk is Zig's pre-1.0 churn — pin a Zig version range, monitor zlint's evolution, and budget for per-release adjustment when 0.16 lands.

The final framing: this isn't really a code-quality framework, it's a **change-cost framework** that happens to use code-quality signals as its measurement points. The success metric isn't "fewer violations"; it's "the codebase still feels light to work in at year three." Every rule should be evaluable against that test.