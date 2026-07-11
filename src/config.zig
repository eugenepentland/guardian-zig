//! guardian.toml configuration types. The parser lives in config_parser.zig
//! (kept separate so this stays a std-only type-definition leaf and both files
//! stay under the file-size cap).

const std = @import("std");

/// One [[boundary]] entry — a module glob and the import substrings forbidden inside it.
pub const BoundaryRule = struct {
    module_pattern: []const u8,
    forbidden_imports: []const []const u8,
};

/// One [[allow]] entry — extra allowed-path globs for a named check, merged with
/// that check's compiled architectural defaults. Lets a project (Guardian
/// included) grant path-scoped exemptions in guardian.toml instead of hardcoding
/// its own filenames into check source, which would silently punch the same
/// holes in every downstream repo that happens to share those paths.
pub const AllowRule = struct {
    check: []const u8,
    paths: []const []const u8 = &.{},
};

/// Per-check config for the spec-quality lint.
pub const SpecQualityCfg = struct {
    enabled: bool = true,
    forbidden_phrases: []const []const u8 = &.{},
};

/// Per-check config for the function-size cap.
pub const FunctionSizeCfg = struct {
    enabled: bool = true,
    /// Max parameters per function. Default 6 (not 4) because Zig's explicit
    /// style routinely threads `self` + an `Allocator` + a `writer` alongside
    /// 2-3 real payload params; the cap targets genuinely over-parameterized
    /// functions (7+) that should bundle args into a struct.
    max_params: u32 = 6,
};

/// Per-check config for cognitive-complexity scoring.
pub const ComplexityCfg = struct {
    enabled: bool = true,
    /// Cognitive-complexity cap. Default 25 (not 15): the fixed low caps in
    /// the FRAMEWORK have no research basis, and a real production codebase
    /// relaxed every shape threshold — 25 flags genuinely tangled control
    /// flow while sparing idiomatic dispatch/parser functions.
    max_score: u32 = 25,
};

/// Per-check config for the anytype-budget cap.
pub const AnytypeBudgetCfg = struct {
    enabled: bool = true,
    max_per_file: u32 = 2,
    /// Files (glob/substring, walker-relative) exempt from the cap — for
    /// legitimate variadic/formatting boundaries (e.g. a reporter module)
    /// where `anytype` is the idiomatic printf-style forwarding mechanism.
    exclude: []const []const u8 = &.{},
};

/// Per-check config for the orphan-files reachability scan.
pub const OrphanFilesCfg = struct {
    enabled: bool = true,
    /// Explicit root files for reachability. Paths are walker-relative
    /// (e.g. "src/main.zig"). When empty, every top-level src/*.zig
    /// is treated as a root.
    roots: []const []const u8 = &.{},
};

/// Per-check config for doc-quality (content lint on /// doc comments).
pub const DocQualityCfg = struct {
    enabled: bool = true,
    /// Minimum non-whitespace character count after the `///` prefix.
    min_chars: u32 = 12,
    /// Extra decl names exempt from the doc-comment *presence* requirement,
    /// merged with the compiled protocol/trivial defaults (deinit, format,
    /// next, reset). Matched on the bare fn/type name. The doc *quality*
    /// check still applies to any doc that is present.
    exempt_names: []const []const u8 = &.{},
};

/// Per-check config for the type-size cap on pub containers.
pub const TypeSizeCfg = struct {
    enabled: bool = true,
    /// Max fields per `pub const X = struct { ... }` (or variants for enums,
    /// fields for unions). Methods and inner const decls don't count.
    max_fields: u32 = 7,
    /// Pub containers (glob/substring, walker-relative) exempt from the cap —
    /// for legitimate flat aggregation structs (e.g. a config bag with one
    /// field per setting) where a high field count isn't a "god struct" smell.
    exclude: []const []const u8 = &.{},
};

/// Per-check config for the function-length cap.
pub const FunctionLengthCfg = struct {
    enabled: bool = true,
    /// Max source lines per fn decl, counted from the `fn` keyword line
    /// through the closing `}` line. Default 120 (not 60): the low cap has no
    /// research basis and forced artificial splits; a real codebase relaxed it.
    max_lines: u32 = 120,
};

/// Per-check config for the nesting-depth cap.
pub const NestingDepthCfg = struct {
    enabled: bool = true,
    /// Max brace-nesting depth inside a function body. Body itself
    /// counts as depth 1; nested blocks each add 1. Default 5 (not 4): the
    /// low cap has no research basis and a real codebase relaxed it.
    max_depth: u32 = 5,
};

/// Project-wide baseline mode. When enabled, every check's current
/// violations are recorded on first run and only NEW violations fail
/// the build thereafter — converting the hard-block wall into a ratchet.
/// Designed for adopting Guardian on legacy codebases.
pub const BaselineCfg = struct {
    enabled: bool = false,
    /// Registered check names whose baseline may never grow, even under a
    /// refresh: a refresh that would raise the recorded violation count fails
    /// instead of rewriting. The 1:1 spec map is the flagship guarantee and
    /// the fastest-growing frozen debt, so `["spec"]` is the canonical use.
    /// Validated like `disabled` — a typo hard-fails the run.
    deny_growth: []const []const u8 = &.{},
};

/// Per-check config for the line-length cap.
pub const LineLengthCfg = struct {
    enabled: bool = true,
    /// Max codepoints per line. Framework recommends 100-120.
    max_len: u32 = 120,
};

/// Per-check config for the bool-ops-per-condition cap.
pub const BoolOpsCfg = struct {
    enabled: bool = true,
    /// Max `and` / `or` / `!` tokens inside a single `if`/`while` condition.
    max_ops: u32 = 3,
};

/// Per-check config for escape-discipline (raw interpolation into markup).
/// Opt-in: heuristic, most valuable for projects that render HTML/SVG from
/// attacker-influenced text (servers, doc generators).
pub const EscapeDisciplineCfg = struct {
    enabled: bool = false,
};

/// Per-check config for oom-discipline (allocation errors silently conflated
/// with domain absence). Opt-in: strict, catches `catch return null`/
/// `catch continue` on allocating calls that drop data on OOM.
pub const OomDisciplineCfg = struct {
    enabled: bool = false,
};

/// Per-check config for the magic-number check. Opt-in (default off): in
/// literal-heavy domains (geometry, electrical constants) the bare-integer
/// rule is pure noise, so a production user disabled it wholesale. Projects
/// that want it opt in via `[magic_number] enabled = true`.
pub const MagicNumberCfg = struct {
    enabled: bool = false,
};

/// Per-check config for the stdout-flush check. Default off keeps the check
/// REPORT-ONLY: it surfaces a buffered stdout/stderr writer with no reachable
/// flush but never fails the build, because the intra-procedural heuristic has
/// unproven precision. `[stdout_flush] enabled = true` promotes it to a gating
/// hard-block once a project trusts the signal.
pub const StdoutFlushCfg = struct {
    enabled: bool = false,
};

/// Per-check config for the module-doc-header check. `min_lines` is the line
/// count above which a file must open with a `//!` module doc block; files at
/// or below it are exempt. Default 200 — calibrated to zig-core reality, where
/// `//!` headers land consistently on the large, load-bearing modules. Lower it
/// to require headers on smaller files.
pub const ModuleDocHeaderCfg = struct {
    min_lines: u32 = 200,
};

/// Per-check config for the dead-pub check.
pub const DeadPubCfg = struct {
    /// When true, references from inside `test {...}` blocks (and the test/
    /// tree) don't count toward a pub decl's liveness — so production-dead code
    /// kept alive only by its own test is flagged. Off by default: the
    /// tested-pure-function-seam idiom (a `pub fn analyzeContent` exercised only
    /// by tests) is legitimate, so opting in is a per-project decision.
    ignore_test_refs: bool = false,
};

/// Per-check config for change-classification: the diff-scoped process
/// gate requiring behavioral src changes to arrive with a test or spec
/// change. On by default — the check skips itself outside a git repo.
pub const ChangeClassificationCfg = struct {
    enabled: bool = true,
    /// Git ref the working tree is diffed against when neither the
    /// `--against` flag nor the GUARDIAN_AGAINST env var names one.
    against: []const u8 = "HEAD",
    /// When true (default) and the effective diff base is HEAD with a clean
    /// working tree, gate the last commit (HEAD~1..HEAD) instead of passing on
    /// the empty diff — closing the commit-then-build hole. Skipped when HEAD is
    /// a merge (>1 parent) or the root (0 parents). Set false to keep the
    /// working-tree-only behavior.
    gate_last_commit: bool = true,
};

/// Per-check config for the completeness checklist. Opt-in (default off): it
/// requires every `## ` SPEC.md feature section to address (or explicitly
/// waive) each of the 8 scenario categories, which most existing specs need a
/// pass to satisfy. `exempt_sections` lists non-feature sections (changelog,
/// overview) skipped by name.
pub const CompletenessCfg = struct {
    enabled: bool = false,
    exempt_sections: []const []const u8 = &.{},
};

/// Config for the DORA delivery-metrics sink (non-gating; see dora.zig). Each
/// `all`/`nightly` run appends one JSON line unless disabled. The sink lives
/// under `.guardian/cache/` so rewriting it never invalidates the skip-cache.
pub const DoraCfg = struct {
    enabled: bool = true,
    sink_path: []const u8 = ".guardian/cache/dora.jsonl",
};

/// Config for the `mutate` command (an explicit step, never part of `all` —
/// each mutant costs a full build + test cycle; see cli/mutate.zig).
pub const MutationCfg = struct {
    /// Minimum percent of viable mutants the test suite must kill.
    min_score_pct: u32 = 80,
    /// Gating floor: a run with fewer viable (non-unviable) mutants than this
    /// reports its survivors informationally and passes, instead of failing on
    /// a meaningless percentage (1 survivor of 2 = 50% red). Below the floor the
    /// score ratchet is never written. Default 4; bites the fast tier, where a
    /// tiny diff can produce only a mutant or two.
    min_mutants: u32 = 4,
    /// Cap on mutants exercised per run; larger candidate sets are sampled
    /// deterministically (every k-th mutant) down to this budget.
    max_mutants: u32 = 100,
    /// Per-phase child build timeout. A timed-out mutant counts as killed:
    /// the mutation made the suite hang, so it was caught.
    timeout_secs: u32 = 300,
};

/// Per-check config for the test-coverage check (per-pub-fn).
pub const TestCoverageCfg = struct {
    /// Off by default: the check is intentionally strict (every pub fn
    /// must be referenced from some `test {…}` block) and most existing
    /// codebases need migration before they can satisfy it. Set to true
    /// in guardian.toml to opt in.
    enabled: bool = false,
    /// Pub fn names that are exempt from the requirement (commonly entry
    /// points like `main`, `build`, etc.). Matched on the bare fn name.
    exempt_names: []const []const u8 = &.{},
};

/// Per-check config for fuzz-presence. Each path in `modules` must contain at
/// least one `std.testing.fuzz` call. Opt-in by construction: an empty list (the
/// default) is a no-op, so the check does nothing until a project names the
/// parser/decoder modules it expects to keep fuzzed. Paths are walker-relative
/// (e.g. "src/config_parser.zig"), resolved under the project dir; a listed file
/// that is missing/unreadable or carries no fuzz call is a hard failure, so a
/// stale entry fails the gate closed rather than silently passing.
pub const FuzzPresenceCfg = struct {
    modules: []const []const u8 = &.{},
};

/// Per-check config for int-from-float-budget's sanctioned-wrapper mode. An
/// `@intFromFloat` in the body of a function whose name is in `guard_fns` IS the
/// sanctioned guard (e.g. eda's `numeric.checkedInt`, which validates
/// isFinite+range in float space before converting), so it doesn't count toward
/// the snapshot budget; every other site still does. `require_guard` is an
/// optional strict mode: under those walker-relative path globs, ANY
/// `@intFromFloat` outside a guard fn hard-fails (not just snapshot drift), so a
/// chosen subtree can be driven to zero unguarded casts. Both empty by default,
/// which preserves the plain count-every-site budget.
pub const IntFromFloatCfg = struct {
    guard_fns: []const []const u8 = &.{},
    require_guard: []const []const u8 = &.{},
};

/// Aggregated guardian.toml configuration; defaults are sensible.
pub const Config = struct {
    spec_file: []const u8 = "SPEC.md",
    /// Max lines per .zig file. Default 1000 (not 500): the low cap has no
    /// research basis and a real production codebase relaxed it.
    max_file_lines: u32 = 1000,
    /// When true, `all` skips the whole run when its hashed input set is
    /// unchanged since the last all-green run (see cache.zig).
    cache_enabled: bool = true,
    /// When true, `all` runs checks across worker threads (one per core),
    /// replaying captured output in registry order so results stay
    /// deterministic. Set false to force the sequential path.
    parallel: bool = true,
    file_size_exclude: []const []const u8 = &.{},
    /// Path globs (walker-relative, e.g. "src/serve/templates") dropped from the
    /// whole source scan — no check ever sees a file whose path matches. Unlike
    /// [[allow]] (which each check honors or ignores), this excludes the file
    /// before any check runs, so it works uniformly. Use for GENERATED code
    /// (codegen output committed under src/) that shouldn't be linted at all.
    /// Substring match when a pattern has no `*` (see walk.matchGlob).
    exclude: []const []const u8 = &.{},
    /// Registry names of checks to skip entirely in `all` runs (e.g.
    /// "magic-number"). Lets a project disable individual checks that have no
    /// dedicated [section] toggle. Matched against each check's registry name.
    disabled: []const []const u8 = &.{},
    boundary_rules: []const BoundaryRule = &.{},
    spec_quality: SpecQualityCfg = .{},
    function_size: FunctionSizeCfg = .{},
    complexity: ComplexityCfg = .{},
    anytype_budget: AnytypeBudgetCfg = .{},
    orphan_files: OrphanFilesCfg = .{},
    doc_quality: DocQualityCfg = .{},
    type_size: TypeSizeCfg = .{},
    function_length: FunctionLengthCfg = .{},
    nesting_depth: NestingDepthCfg = .{},
    test_coverage: TestCoverageCfg = .{},
    bool_ops: BoolOpsCfg = .{},
    line_length: LineLengthCfg = .{},
    baseline: BaselineCfg = .{},
    escape_discipline: EscapeDisciplineCfg = .{},
    oom_discipline: OomDisciplineCfg = .{},
    magic_number: MagicNumberCfg = .{},
    stdout_flush: StdoutFlushCfg = .{},
    module_doc_header: ModuleDocHeaderCfg = .{},
    dead_pub: DeadPubCfg = .{},
    change_classification: ChangeClassificationCfg = .{},
    mutation: MutationCfg = .{},
    completeness: CompletenessCfg = .{},
    dora: DoraCfg = .{},
    fuzz_presence: FuzzPresenceCfg = .{},
    int_from_float: IntFromFloatCfg = .{},
    /// [[allow]] entries: per-check allowed-path overrides (see AllowRule).
    allow_rules: []const AllowRule = &.{},

    /// Extra allowed-path globs configured for `check_name` via [[allow]]
    /// (empty when none). Checks merge these with their compiled defaults.
    pub fn extraAllowed(self: *const Config, check_name: []const u8) []const []const u8 {
        for (self.allow_rules) |r| {
            if (std.mem.eql(u8, r.check, check_name)) return r.paths;
        }
        return &.{};
    }
};
