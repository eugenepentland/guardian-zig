# Zig-Source Pattern Audit — guardian-zig & eda vs ziglang/zig 0.15.1

**Date:** 2026-07-10
**Question:** Which design patterns does the Zig team follow in its own source (`~/ai/canopy/zig`, 0.15.1: lib/std 403k LOC + compiler src/ 524k LOC) that guardian-zig (24.8k LOC) and eda/netlisp (120.6k LOC) do not — and which gaps can static analysis enforce vs which need human judgment?
**Method:** Three parallel investigations — (1) pattern extraction from the Zig tree with measured densities, (2) a guardian-zig self-audit, (3) an eda audit — followed by spot-verification of every load-bearing count (guardian assert count, `RunError = anyerror`, dupeZ sites, eda `@intFromFloat`/`checkedInt` counts, eda guardian.toml contents, eda deploy optimize mode were all re-verified directly).
**Relation to prior docs:** ZIG-PRACTICES-ADOPTION.md asked "what checks should guardian offer users." This audit asks "do guardian and eda *themselves* follow zig-core practice." AUDIT.md (07-02) and AUDIT-2026-07-08.md were bug/feature audits. Several of their claims are now stale — see §6.

---

## 1. Ground truth: how the Zig team actually writes Zig (measured, 0.15.1 tree)

| Pattern | Measured reality in the Zig tree |
|---|---|
| Assertions | **4.5/KLOC in lib/std, 4.0/KLOC in src/** (3,911 asserts total); 244 `/// Asserts …` doc-comment preconditions paired with a first-statement assert |
| `catch unreachable` | 674 uses, but only ~3.5% comment-justified — justification is *structural* (write into pre-sized buffer, post-`ensureCapacity`), not prose |
| `unreachable` comments | Only ~26% of statement-form `unreachable` carry an adjacent comment; exhaustive-switch structure is the usual justification |
| Error sets | 242 named `pub const XError = error{…}`; pub fns named:inferred ≈ 2:1 in std, *inverted* in compiler internals. `anyerror` only at type-erased boundaries |
| Selective handling | `catch \|err\| switch (err)` ×853 — THE recover-some-rethrow-rest idiom |
| User-input errors | **Errors-as-data**: `Ast.errors` slice, `json.Diagnostics`, `zon`, `tar`, `zip`, ErrorBundle. Error codes reserved for environmental failure (OOM, I/O) |
| Containers | Unmanaged fully landed; `= .empty` decl-literal ×951; allocator stored only in orchestration structs (`Zcu.gpa`), passed per-call to data structures |
| Allocator naming | Semantic: `gpa` (individually freed, ×462), `arena` (never freed, ×171+), `allocator` (strategy-agnostic std code, ×419) |
| main() template | `src/main.zig:170-188` — DebugAllocator + `defer deinit()` leak check in Debug/ReleaseSafe, `smp_allocator` in ReleaseFast; `page_allocator` essentially never (5 uses in 930k LOC) |
| Naming | snake_case consts (SCREAMING only in C/OS-mirror files — ~97% of all hits); camelCase fns; TitleCase file-as-struct ×222 with `@This()` |
| Doc comments | `//!` on only **25-28%** of files (the load-bearing ones); `///` on ~53% of pub decls — "document when non-obvious," not 100% |
| Tests | 56% colocated decltests / 44% dedicated files; `std.testing.allocator` ×1,271; **`checkAllAllocationFailures` only ×5 and `std.testing.fuzz` ×1 even upstream** |
| I/O (Writergate) | Buffer-in-interface writers + **explicit `flush()`** (missing flush = truncated output = correctness bug in 0.15); `std.debug.print` ×23 in the entire compiler (debug dumps only); `std.log.scoped` ×96; `std.Progress` for long ops |
| CLI | `fatal = std.process.fatal` ×281; usage as comptime consts; `argsAlloc(arena)`; `cleanExit()`; typed `EnvVar` enum centralizing env access |
| DOD | `enum(u32)` index newtypes ×144 with `.none = maxInt` sentinels; MultiArrayList ×51; string interning; u32 (not usize/pointers) in stored structures |
| State machines | Labeled `switch` + `continue :state` in tokenizer, json Scanner (×62), aarch64 Select (×212) |
| Globals | Only process-lifetime singletons in main.zig + threadlocal crash state; the 400k-LOC library core threads all state through structs |
| Ship mode | Binaries ship **ReleaseFast** — compensated by 4+ asserts/KLOC and Debug/ReleaseSafe CI passes. `@setRuntimeSafety` never used casually |
| Misc idioms | `comptime assert` ×136; deinit poisoning `self.* = undefined` ×43; soft deprecation `/// Deprecated;` ×134; `usingnamespace` extinct (0) |

---

## 2. Gap matrix

Status: ✓ follows · ◐ partial · ✗ deviates · — N/A. "Auto" = enforceable by AST/tokenizer-level analysis.

| Pattern | Zig tree | guardian-zig | eda | Auto? |
|---|---|---|---|---|
| Assert density | 4-4.5/KLOC | ✗ **0 in 24.8k LOC** | ✗ **4 in 120.6k LOC** (policy) | metric: yes; placement: no |
| OOM propagation | always propagate | ✗ ~10 gate paths fail **green** on OOM | ✗ 707 soft-swallow catches | yes (check exists, off) |
| Named error sets | 2:1 public | ✗ `RunError`/`WalkError` **= anyerror** aliases | ✓ 296 named vs 22 inferred | yes (close alias loophole) |
| Errors-as-data diagnostics | systematic | ◐ violations yes; own config **silent fail-open** | ◐ eval yes (caret UX); parse errors span-less, fail-fast | no (design) |
| `catch unreachable` / `catch {}` | structural only | ✓ 0 / 3 justified | ✓ 0 / 0 | already enforced |
| Unmanaged containers | landed | ✓ (but 350× deprecated alias name, 28 managed hashmaps) | ✓ (1,305× deprecated alias name) | yes |
| main() allocator template | DebugAllocator+leak | ◐ arena-over-page_allocator, no DebugAllocator | ✗ page_allocator GPA, never-free convention | partial |
| Const naming (snake_case) | snake_case | ✗ 71 SCREAMING | ✗ ~400-900 SCREAMING | yes |
| `//!` module headers | 25-28% (important files) | ◐ 25/103 files | ✓ 84/167 files | yes |
| Colocated decltests + testing.allocator | standard | ✓ 355 uses + meta-guards | ✓ 908 tests, 847 uses | already enforced |
| OOM-path tests (FailingAllocator) | rare even upstream (×5) | ✗ 0 | ✓ **leak_tests suite w/ fail-index sweeps** | presence: yes |
| Fuzzing | infra exists, thin upstream | ✗ 0 (TOML/glob/scanner targets) | ✗ 0 (sexpr/DEFLATE/kicad/ZIP targets) | presence: yes |
| Buffered output + flush | required in 0.15 | ◐ all output = unbuffered debug.print→stderr (capture/replay mitigates); file writes correct | ◐ whole-buffer-then-writeAll (fine); 124 debug.print, std.log ≈unused | yes |
| fatal() helper | 281 calls | ✗ 10 hand-rolled print+exit | ✗ 69 hand-rolled print+exit | yes |
| Guarded narrowing casts | assert-or-math.cast | ◐ 21 bounded @intCast, unasserted | ✗ **95 raw `@intFromFloat` vs 10 `checkedInt`** (frozen at 88) | yes |
| DOD / interning | core discipline | ◐ rides std.zig.Ast properly; own layer string-heavy; 40 dupeZ file copies | ◐ optimizer hot loop allocation-free; IR string-keyed, 726 StringHashMaps, no interning | partial |
| Globals | ≈0 in library code | ✓ 1 (exempted) | ✗ 30 mutex-guarded serve/ singletons | yes (extend check) |
| Labeled switch state machines | tokenizers/decoders | — | ✗ while+if/else (cosmetic) | partial |
| Pinned ship mode | explicit ReleaseFast | ✓ consumers choose; eda builds it ReleaseSafe deliberately | ✗ **unpinned** → systemd deploy currently ships a Debug binary | policy check |
| Comptime dispatch tables | StaticStringMap ×43 | ✓ comptime registry | ✓✓ exceeds upstream (compile-error doc-drift gates) | — |

---

## 3. Findings — shared gaps (both projects)

### 3.1 Assert starvation (the single biggest philosophical divergence)
The Zig team's primary in-code bug detector is `std.debug.assert` at ~4-4.5/KLOC with the `/// Asserts` doc convention. guardian has **zero** asserts in 24.8k LOC — preconditions exist only as prose ("Precondition: name[0] is a lower-case ASCII letter", src/checks/naming.zig:39-41) enforced by nothing. eda has 4, by explicit policy (panic-budget pins `panics 0, unreachables 0`).

eda's "server must not crash" policy conflates two things zig-core keeps separate: *release behavior* and *debug-build diagnostics*. Asserts are active in Debug/ReleaseSafe and compile out of ReleaseFast/Small; since eda currently deploys Debug (§6.2) and runs its 908-test suite in Debug, asserts would cost nothing in production posture today while converting silent geometry/net-merge corruption into localized test-time traps. The zig-core posture is explicitly "crash in dev, corrupt never."

### 3.2 OOM demoted instead of propagated
Zig core propagates `error.OutOfMemory` everywhere (853 `catch |err| switch` sites). Both projects demote it:
- **guardian (severe — gate integrity):** ~10 paths where allocation failure yields a *passing* result: `dupeZ … catch return 0` (checks/int_from_float_budget.zig:29 — OOM ⇒ "zero casts counted"), `catch return c` undercounts (checks/panic_budget.zig:44,122), `append … catch return list.items` silently truncates `--only`/snapshot-refresh lists (check.zig:175, snapshot_helper.zig:64), `allocPrint … catch return null` (git.zig:136, cache.zig:175, checks/change_classification.zig:343). A gate's failure mode must be red, never green.
- **eda (moderate — silent data loss):** 707 `catch return-fallback/continue/return null` sites; sampled dominant class is OOM-as-soft-skip, e.g. `readFileAlloc(...) catch continue` silently omits a STEP model from an export package (export_kicad.zig:452).

Guardian *ships a check for exactly this* (`oom-discipline`, catches `alloc catch return <literal>`) — and it is **not enabled on either project**. Enabling it on guardian itself would red guardian's own build today. This is the clearest dogfooding failure found.

### 3.3 Deprecated container spelling (mechanical time bomb)
Both projects are semantically correct (0 managed ArrayLists, `.empty` decl-literals everywhere: guardian 273, eda 1,177) but spell the type `std.ArrayListUnmanaged` — a 0.15 **deprecated alias** of `std.ArrayList` (guardian ×350, eda ×1,305). Plus 28 managed `StringHashMap.init(allocator)` in guardian while std has moved to unmanaged maps. Zero cost today; a guaranteed tree-wide breaking diff when 0.16 drops the alias. Rename now while it's `sed`-grade.

### 3.4 SCREAMING_SNAKE consts
Zig std uses snake_case for consts (`std.fs.max_path_bytes`); SCREAMING appears only in C/OS-ABI-mirror files (~97% of all hits). guardian has 71 SCREAMING file-scope consts (`GREEN/RED/PREFIX`, `MAX_GIT_OUTPUT_BYTES`, `SNAPSHOT_LEAF`…), eda has hundreds (`MODEL_MAX_BYTES`, `K_DECOUPLE`, `MAX_PARSE_DEPTH`…; 391 by the strictest file-scope regex, ~892 counting all scopes). **Guardian's own `naming` check never inspects const casing** — a self-blind spot: it classifies these as "pascal" and moves on.

### 3.5 No fuzzing, anywhere
`std.testing.fuzz` exists since 0.14. Neither project has a single fuzz test, and both are built around textbook fuzz targets fed by untrusted input:
- guardian: hand-rolled TOML parser, `matchWildcard` glob, TestScope brace tracker, oom_discipline's 3-phase scan state machine — its entire job is "scan arbitrary source text."
- eda: hand-rolled S-expr parser (reachable via MCP/HTTP writes), from-scratch DEFLATE/PNG encoder, `.kicad_pcb` reader, ZIP writer.
Calibration note: even upstream, unit-level `std.testing.fuzz` is thin (×1) — the recommendation is "adopt the capability on the handful of parser/codec modules where it pays," not "fuzz everything."

### 3.6 CLI output & process idioms
Zig core: buffered `File.stdout().writer(&buf)` + explicit `flush()` (a **correctness** requirement in 0.15 — missing flush truncates output), `std.process.fatal` (×281), `std.log.scoped` (×96), `std.debug.print` only for debug dumps (×23 in 930k LOC).
- guardian: 100% of human output is unbuffered `std.debug.print` → stderr; stdout carries nothing (so `guardian-check | grep` reads nothing). Mitigated: parallel runs capture per-check output and replay once. File writes DO use the new Io API with flush correctly (snapshot.zig:91-99). No fatal helper — 10 hand-rolled fail+exit sites.
- eda: 124 `std.debug.print` in non-test src (50 frozen by its own debug-print-ban); `infra/log.zig` exists but CLI files are carved out; `std.log` ≈ unused (2 refs, no scoped loggers in a long-running server); 69 hand-rolled print+`exit(1)` pairs. The whole-artifact-into-memory-then-`writeAll` render pattern is fine (no flush bug exposure).

---

## 4. Findings — project-specific

### 4.1 guardian-zig
1. **`pub const RunError = anyerror` / `WalkError = anyerror`** (src/cli/types.zig:5-12, src/walk.zig:38) — the comment openly states it exists to pass guardian's own error-discipline check ("treats this as an explicit named set"). Consequences: 78 `anyerror` occurrences, compile-time exhaustiveness forfeited, and five `else => unreachable` runtime narrowings (function_length.zig:53, nesting_depth.zig:114, type_size.zig:70, doc_comments.zig:129, stub_body_ban.zig:122) that a precise error set would turn into compile errors. The checks' true error space is tiny (OutOfMemory + a few walker/fs errors).
2. **guardian.toml parsing is silent fail-open** (src/config_parser.zig:1-2,13-14): unreadable/malformed config ⇒ all-defaults with zero diagnostics; unknown sections ignored. A typo'd `[baseline]` header silently drops boundaries/allows/thresholds. Only check-name lists are validated. For a hard gate this is the worst fail-open after §3.2. Zig-core pattern: user input gets diagnostics (§1 errors-as-data) and a gate should `fatal` on config it cannot parse.
3. **git shell-outs return null on any failure** (git.zig:244-258) ⇒ change-classification and diff-scoped mutation silently degrade to "skip" when git breaks mid-run. Documented for the no-repo case; still a silent bypass in the broken-git case.
4. **40 whole-file `dupeZ(u8, content)` copies** across check files because helper signatures take `[]const u8` although the walker already hands out `[:0]` sentinel slices (walk.zig:10-13 — whose "no per-check dupeZ" comment is now stale); plus ~30 re-tokenizations per file per run alongside the (excellent) parse-once AST index. Cold enough not to hurt today; not compiler-grade.
5. **Self-improvement adoption from ZIG-PRACTICES-ADOPTION §4:** per-item ratchet **adopted** (ratchet.zig, c36513b); `//!` headers **partial** (25/103, core files still bare — and the §2.2 `module_doc_header` check was never shipped); file-as-struct **not adopted** (vacuously — no TitleCase modules exist; §2.5 check also unshipped).
6. Snapshot-frozen self-debt is honest and small: unsafe-ops 119 (63 `@ptrCast` + 56 `@alignCast` — the `*anyopaque` visitor tax), panic-budget 5 unreachables / 3 TODOs. No baselines at all; passes all 59 checks at stock defaults with magic-number and test-coverage opted in. That is genuinely rare.

### 4.2 eda / netlisp
1. **Cast-guard adoption stalled at ~10%:** `numeric.checkedInt` is a textbook guard with excellent rationale comments, but 10 call sites vs **95 raw `@intFromFloat`** across 20 files (router.zig:259-260 computes grid dims this way). Frozen at 88 in int-from-float-budget so it can't grow — but it isn't shrinking. In any future safety-off build this is the NaN⇒UB class the old bug audit flagged; in today's Debug deploy it's a remote-panic class.
2. **Build mode is unpinned.** `standardOptimizeOption(.{})` with no `-Doptimize` in systemd/scripts ⇒ the deployed server binary is a **Debug** build. (The guardian-check dependency, by contrast, is deliberately pinned ReleaseSafe with a written rationale — build.zig:105-109 — which is exactly the zig-core "decide and document" pattern.) Decide the server's mode on purpose: ReleaseSafe is the natural fit for an internet-facing service that lacks zig-core's compensating assert density.
3. **Parse errors are second-class:** `ParseError` is a bare error enum with no span; a module syntax error surfaces as `"syntax error in '<path>': ErrName"` pinned to 1:1 (modules.zig:138), while *eval* errors get spans, source-line + caret, module call stacks, and did-you-mean suggestions. Zig-core treats syntax errors as data (`Ast.errors` — parse continues, all errors reported). One fix per rebuild round-trip is agent-hostile.
4. **30 file-scope mutable globals in serve/** (sessions, users, oauth stores, caches, live versions) — all mutex-guarded and documented, but process-singleton state zig-core would hang off the Handler/server struct; blocks per-test/multi-instance servers. Guardian's ban-globals froze only the 6 `pub var`s; the 24 file-private ones are invisible to it.
5. **String-keyed IR without interning:** 726 StringHashMap uses re-hash/compare `[]const u8` net/ref names everywhere; 0 MultiArrayList. Mitigations are real (slices borrow from never-freed source buffers; boundary `idx_of` maps; evaluator caches; the optimizer inner loop verified allocation-free) — so this is a scale/profile question, not a defect.
6. **Monoliths:** optimizer.zig 9.4k code lines, 21 files frozen over the 1,000-line cap. Note zig-core *tolerates* cohesive monoliths (Sema.zig is famously enormous) — the actionable signal isn't size, it's the drift bugs the old audit found (the `isGroundName` fix applied to optimizer.zig but not router.zig's copy). Duplicated-helper drift, not LOC, is the argument for splitting shared helpers out.
7. Baseline debt is measured and ratcheted, not hidden (§6.1) — 991 baseline lines across ~20 checks (function-size 136, doc-comments 129, line-length 124, spec 109 w/ deny_growth, debug-print 50, allocator-hygiene 29, error-discipline 20, file-size 21…), mutation kill-score floored at a *measured* 32% with documented survivor campaigns. The completeness check exempts 79 of ~80 sections — an honest TODO ledger, but effectively the check isn't biting yet.

---

## 5. What both projects do BETTER than zig-core practice (calibration)

- **guardian:** true self-hosting at stock strictness with zero baselines; mutation-tests its own suite with a kill-score ratchet; byte-deterministic parallel runner with per-worker arenas; fail-loud walker ("a silently skipped file would be exempt from every check"); test-root meta-guards stronger than `refAllDecls`, born from a real incident.
- **eda:** comptime dispatch registries where an undocumented DSL form is a **compile error** plus a build-time docs drift gate (exceeds upstream's own docs discipline); arena-per-request with an audited ownership boundary and the leak history written into the code; a 2.8k-line leak_tests suite with FailingAllocator fail-index sweeps (denser OOM-path testing than lib/std itself); gerber read-back verification ("fails the test, not a fab three weeks later"); bounded parser recursion with rationale + regression test; 908 colocated decltests; eval-error caret diagnostics of std.zig quality.

The gaps in this report are relative to the best open-source Zig reference there is; neither codebase is in bad shape by community standards.

---

## 6. Corrections to prior audit claims (now stale)

1. **AUDIT-2026-07-08:** "every shape cap is relaxed 1.7–10× (file-size at 10,000 lines)" — **false today.** eda's guardian.toml contains **no cap overrides at all**; every deviation is baseline-frozen with per-item only-shrink ratchets. The migration to ratchets (item 5 of that audit) evidently absorbed the old relaxations.
2. **eda AUDIT.md (07-01):** "the shipping ReleaseSmall build" — **stale.** The current deploy path (`systemd` rebuild via plain `zig build`, no `-Doptimize` anywhere) ships Debug. The @intFromFloat findings are therefore currently "remote panic," not "silent UB" — until the day someone pins a fast mode, which is why §4.2.2 says pin it deliberately.
3. **guardian walk.zig:10-13** "no per-check dupeZ" comment — stale; 40 sites do exactly that.
4. **ZIG-PRACTICES-ADOPTION §2.4** (`unreachable_explanation` check): upstream data argues against it — only ~26% of zig-core `unreachable`s carry comments; justification is structural. Recommend **not** shipping it as a hard block; panic-budget's count ratchet already covers growth.

---

## 7. Statically enforceable — concrete guardian actions

Ranked by reliability impact. "Both" = apply to guardian self-build and eda.

| # | Action | Type | Mechanism | Applies |
|---|---|---|---|---|
| S1 | **Enable `oom-discipline`** (exists, opt-in, off everywhere) and extend its patterns to `catch return null`, `catch return <expr>`, `catch continue` on allocating calls | flip + extend | token/AST pattern on catch-of-allocating-call | both |
| S2 | **Close the anyerror-alias loophole in `error-discipline`**: resolve `pub const X = anyerror;` one level so aliases count as anyerror | extend | decl-alias resolution in-file + across imports of known modules | both (guardian is the offender) |
| S3 | **`naming` → const casing**: snake_case consts, SCREAMING banned outside a C/ABI-mirror allowlist | extend | container-level `const` identifier caseKind | both (71 + ~400) |
| S4 | **New `deprecated-alias` check**: `ArrayListUnmanaged`→`ArrayList`, managed `StringHashMap(…).init(alloc)` discouraged, `usingnamespace` (extinct), old `getStdOut` writer idioms | new | token match against a versioned alias table | both (350+28 / 1,305) |
| S5 | **`int-from-float-budget` → sanctioned-wrapper mode**: recognize a configured guard fn (`numeric.checkedInt`) as compliant; optional `require_guard` path globs; add to `deny_growth` | extend | call-site parent-expression check | eda (88→0 campaign) |
| S6 | **Assert-density debt metric** (report-only, in `debt`): asserts/KLOC per module vs configurable floor; plus a hard-block **`/// Asserts` ⇄ body-assert consistency** check (doc claims it, body must have it) | new | trivial counting; doc-comment scan + first-N-statements scan | both |
| S7 | **`fatal-exit` check**: `std.process.exit(nonzero)` outside main/registered fatal helper ⇒ suggest `std.process.fatal`/central helper | new | call-site scan with fn allowlist | both (10 / 69) |
| S8 | **`fuzz-presence` check** (report-only or opt-in): configured parser/decoder modules must contain ≥1 `std.testing.fuzz` block | new | per-file token presence against config list | both |
| S9 | **`ban-globals` → include non-pub file-scope `var`** (allowlist main/wiring/threadlocal-with-comment); zig-core library code is ≈0 | extend | AST container-level var scan | eda (24 currently invisible) |
| S10 | **Stdout-flush check**: fn creates a buffered `File.stdout()/stderr()` writer and can return without reachable `flush()` | new | intra-procedural; partial (report-only first) | both (0.15 correctness class) |
| S11 | **Ship `module_doc_header`** (§2.2, never shipped) calibrated to reality: require `//!` only on files > ~200 LOC; report-only first (upstream is 25-28% overall but consistent on big modules) | new | first-token scan + line count | both (guardian 78 files lack; eda 83) |
| S12 | **Point `anytype-budget` at legacy writer params** and ratchet the migration (212 `anytype` writers in eda) | config/extend | signature scan for `anytype` writer-position params | eda |
| S13 | **DebugAllocator-in-main template** (report-only): main modules should construct DebugAllocator under `builtin.mode == .Debug` (zig main.zig:170-188 template) | new (crude) | presence scan in root/main files | both |

Explicitly **not** recommended as checks: unreachable-comment enforcement (§6.4), interning/DOD suggestions (§4.2.5 — judgment), labeled-switch rewrites (cosmetic), file-as-struct (§4.1.5 — vacuous here).

## 8. Not automatable — design/judgment work

Ranked. Each is real engineering, not a lint rule.

1. **Make guardian fail closed** (with S1): config parse errors ⇒ `fatal` with a diagnostic (not silent defaults, config_parser.zig:13-14); unknown sections/keys ⇒ error; broken git mid-run ⇒ loud "gate skipped: <reason>" or hard fail, never a silent pass (git.zig:244-258). Cover with golden tests. *A gate whose own inputs fail open cannot be trusted at exactly the moment things are broken.*
2. **Thread real error sets through guardian's plumbing** — delete `RunError = anyerror`/`WalkError = anyerror`, define the true set (≈ OutOfMemory ∥ Walk/fs errors), let the five `else => unreachable` narrowings become compile-time exhaustive switches. ~60 signature edits, one afternoon, permanent compile-time guarantee (then S2 keeps it honest).
3. **eda: spans on parse errors + (stretch) collect-multiple-errors parsing** — carry token spans into `ParseError` diagnostics so syntax errors render with the same caret UX as eval errors; optionally adopt the `Ast.errors`-style errors-are-data model so agents fix all syntax errors in one round trip.
4. **Assert placement** — the metric (S6) says *how many*; humans decide *where*. Highest-value targets: eda geometry/net-merge/board-write invariants (silent-wrong-copper class), guardian AST-walk/index invariants documented today as prose. Requires settling eda's policy: asserts are Debug/ReleaseSafe-only, hence compatible with a no-crash *release* posture — adopt "assert in dev, never corrupt" and revise the panic-budget=0 stance for `std.debug.assert` specifically.
5. **eda: pin the server's build mode deliberately** — ReleaseSafe recommended (zig-core ships ReleaseFast only because it also carries 4.5 asserts/KLOC + Debug/ReleaseSafe CI, compensations eda doesn't have). Document it in build.zig like the guardian-dep pin already does. Decide crash-vs-corrupt: with `Restart=on-failure` already in systemd, a safety panic is a 2-second blip; silent UB is a wrong board.
6. **OOM-swallow triage (eda)** — S1 will flag ~hundreds of sites; classifying each as legitimate best-effort vs must-propagate is judgment. Suggest a `// oom-ok: <reason>` waiver convention (mirroring `// mutate-ok`) so accepted sites are visible and audited.
7. **serve/ globals → Handler-owned state** — mechanical-ish refactor, but deciding the ownership/injection seams (sessions, oauth, caches) is design; unlocks multi-instance tests.
8. **Interning/DOD for eda's IR** — profile first at target board sizes (200+ parts); borrow-don't-copy already removes the worst cost. Only act on measured hash/compare hotspots.
9. **Monolith decomposition** — split *shared helpers* (the isGroundName-drift class) out of optimizer/router rather than chasing the LOC number; zig-core precedent (Sema.zig) says cohesive-huge is acceptable, duplicated-diverging is not.
10. **Fuzz harness authoring** — S8 checks presence; choosing targets, oracles (round-trip: parse→print→parse; DEFLATE: inflate(deflate(x))==x), and corpora is manual. Start: guardian TOML parser + matchWildcard; eda sexpr parser + DEFLATE.

## 9. Suggested order of attack

1. S1 + judgment item 1: guardian fail-closed (OOM, config, git). Gate integrity first.
2. Judgment item 2 + S2: kill the anyerror aliases; close the loophole.
3. S5 + judgment item 5: eda checkedInt campaign to zero + pin the build mode.
4. S3 + S4: const-casing and deprecated-alias — big, mechanical, near-autofixable; do while cheap.
5. S6 + judgment item 4: assert metric + targeted placement (geometry/board-write, AST invariants).
6. S8 + judgment item 10: fuzz presence + first two harnesses per project.
7. S7/S10/S13 CLI-and-I/O hygiene; S11 module headers; S9 globals visibility; S12 writer-migration ratchet.
