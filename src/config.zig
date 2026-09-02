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

/// One [[ban]] entry — a symbol chain THIS project forbids, enforced by the
/// `ban` check. `chain` is the dotted token sequence to reject (`["optimizer",
/// "placeFromPoses"]` bans `optimizer.placeFromPoses`); `paths` scopes where the
/// ban applies (empty = the whole source tree); `allow` exempts paths inside
/// that scope (the sanctioned wrapper's own file); `reason` names what to reach
/// for instead and is appended to every violation.
///
/// The compiled ban-* checks encode Guardian's architectural opinions, so a
/// project could never ban a symbol of its own — a third-party API, or a
/// cross-layer call that must route through a wrapper. These entries are that
/// missing config-side path.
pub const BanRule = struct {
    chain: []const []const u8,
    paths: []const []const u8 = &.{},
    allow: []const []const u8 = &.{},
    reason: ?[]const u8 = null,
};

/// One [[layering]] entry — a DIRECTIONAL import rule this project declares,
/// enforced by the `import-layering` check. `name` is a kebab-case id that
/// names the rule in every violation and leads its baseline key; `from` globs
/// the source files the rule constrains; `to` globs the import targets those
/// files may not reach (matched on RESOLVED, project-relative paths); `allow`
/// globs source files exempt from the rule (the one sanctioned adapter);
/// `reason` says why the layer points this way and is appended to every
/// violation.
///
/// `name`, `from`, `to` and `reason` are all required — a rule missing any of
/// them is a config error rather than a stored entry, because each way of being
/// incomplete reads in the config like an enforced architecture while enforcing
/// nothing (no `from`/`to` matches no edge; no `reason` leaves a violation
/// nobody can act on; no `name` leaves the finding and its baseline row
/// anonymous).
///
/// `[[boundary]]` is the older, narrower form of the same idea and stays as it
/// is: one module glob, a bare substring `forbidden` list, no allow list and no
/// reason. That shape cannot express the carve-out every real layering rule
/// needs, which is why this one exists beside it.
pub const LayeringRule = struct {
    name: []const u8,
    from: []const []const u8,
    to: []const []const u8,
    allow: []const []const u8 = &.{},
    reason: []const u8,
};

/// A `[[concept]] literals_from` inline table — where the family's literals are
/// READ FROM instead of (or as well as) being listed by hand. `file` is a
/// project-relative path; `fragments` are plain substrings, and every
/// double-quoted string on a line of `file` containing ALL of them joins the
/// family.
///
/// It exists so a family can be TOTAL over an enum's emitting switch: a new
/// variant's wire string joins by itself, so a mirror that never learned it
/// fails without anyone editing guardian.toml. A hand-written `literals` list
/// is a snapshot of the day it was written, and the gap it leaves is exactly the
/// drift this check is for.
pub const LiteralsFrom = struct {
    file: []const u8,
    fragments: []const []const u8 = &.{},
};

/// One [[concept]] entry — a named concept whose literal spellings belong to one
/// owner module, enforced by the `concept` check. `literals` are exact
/// substrings and `patterns` are minimal `*` wildcards (see
/// `checks/concept.zig`); `literals_from` reads further literals out of the
/// owner source; `owner` lists the files/dirs where an occurrence is legal;
/// `require_in` names mirrors that must each spell EVERY literal; `files`
/// optionally replaces the default source scan with path globs (any extension,
/// so JS/CSS drift is reachable); `reason` names where the spelling comes from
/// and is appended to every violation.
///
/// Every other check is per-item — one file, one function. This one is
/// relational: it says a literal BELONGS somewhere, and anywhere else is a
/// duplicate that will drift. `[[ban]]` cannot express it (it matches Zig
/// identifier chains, not text, and has no notion of a home).
///
/// `owner` and `require_in` are the two DIRECTIONS of one relation. `owner` is
/// permissive — only these files may spell it. `require_in` is total — these
/// files must all spell it, every literal of the family, or the mirror has gone
/// quietly out of date.
pub const ConceptRule = struct {
    name: []const u8,
    literals: []const []const u8 = &.{},
    patterns: []const []const u8 = &.{},
    owner: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    require_in: []const []const u8 = &.{},
    literals_from: ?LiteralsFrom = null,
    reason: ?[]const u8 = null,
};

/// One [[idiom]] entry — a named EXPRESSION SHAPE that belongs to one canonical
/// implementation, enforced by the `canonical-idiom` check. A LINE matches when
/// every one of `fragments` (plain substrings, no regex) appears on it; `files`
/// scopes the scan (default `src/*.zig`); `allow` lists the globs where the
/// idiom is legal — its canonical home; `reason` names what to call instead and
/// closes every violation.
///
/// `[[ban]]` owns a named call chain and `[[concept]]` owns a literal spelling.
/// Neither can express a SHAPE built out of ordinary std calls: nothing in
/// `std.mem.lastIndexOfScalar(u8, ref, '/')` is bannable — that ban would fire
/// on every legitimate use of the same std function — and there is no single
/// literal to own. The fragment conjunction is what narrows it back to the one
/// expression: `lastIndexOfScalar` AND `'/'` on one line.
///
/// `reason` has NO default: an idiom violation is unactionable without the name
/// of the canonical helper, so the type refuses a rule that omits it rather than
/// printing a placeholder the way `[[ban]]` and `[[concept]]` do for theirs.
pub const IdiomRule = struct {
    /// The scan set a rule that names no `files` gets. Guardian's `*` spans `/`
    /// (see `walk.matchGlob`), so `src/*.zig` already means every `.zig` file in
    /// the whole `src` subtree — a `**` spelling would instead read as "requires
    /// an intermediate directory" and silently miss `src/main.zig`.
    pub const default_files = [_][]const u8{"src/*.zig"};

    name: []const u8,
    fragments: []const []const u8,
    files: []const []const u8 = &default_files,
    allow: []const []const u8 = &.{},
    reason: []const u8,
};

/// One [[twin]] entry — one capability a project exposes on two or more
/// surfaces, enforced by the `twin-parity` check. `name` is the kebab-case id
/// every violation and baseline row is built from; `surfaces` are free-form
/// labels naming where the capability is reachable (`"http:/api/pcb-fence"`,
/// `"mcp:generate_fence"`, `"cli:export-pdf"`) and are DOCUMENTATION — nothing
/// resolves them; `parity_test` is a substring of the name of the test that
/// asserts the surfaces agree.
///
/// The registry is the point. A capability reimplemented per surface drifts
/// silently, and the only durable record of "these two are supposed to be the
/// same answer" is a committed fact a gate can read. Measured in the consumer
/// project (eda, 2026-08-14): ~19 capabilities on 2+ surfaces, exactly ONE with
/// a test asserting the surfaces return the same bytes — while the
/// reimplemented pairs had already drifted into different BOM-merge gating,
/// different clamps, and different JSON for the same field.
pub const TwinRule = struct {
    name: []const u8,
    surfaces: []const []const u8 = &.{},
    parity_test: ?[]const u8 = null,
};

/// How wide `divergent-const` casts its net. `units` (the default) groups only
/// names whose trailing `_`-separated segment is a unit (`_mm`, `_bytes`,
/// `_ms`, `_hz`, …) — a physical quantity is where a silent disagreement
/// actually ships, and the filter keeps the zero-config run near-silent. `all`
/// groups every file-scope numeric const name.
pub const DivergentConstMode = enum { units, all };

/// Per-check config for divergent-const, the same-name-different-value scan.
/// `ignore_names` exempts generic names that legitimately differ per module
/// (`eps`, `margin`), matched on the whole const name; `mode` widens the
/// grouping past unit-suffixed names. Neither affects the `mirror-of:`
/// annotation rule, which is an explicit author claim and is always verified.
pub const DivergentConstCfg = struct {
    ignore_names: []const []const u8 = &.{},
    mode: DivergentConstMode = .units,
};

/// One [[shadow]] entry — a named constant whose VALUE must not reappear as a
/// bare literal anywhere else, enforced by the `shadowed-const` check.
/// `const_ref` is the TOML `const` key: the `<path>.zig.<name>` referent
/// spelling `divergent-const`'s `/// mirror-of:` annotation already uses.
/// `files` are path globs restricting the scan (empty = every indexed source
/// file); `ignore` exempts paths inside that scan; `reason` names why the
/// constant is the single source of truth and is appended to every violation.
///
/// This is the precise gate half of the check: a project declares the handful
/// of constants whose silent re-derivation elsewhere would actually ship a bug,
/// rather than turning on the whole-tree sweep and living with its noise.
pub const ShadowRule = struct {
    const_ref: []const u8,
    files: []const []const u8 = &.{},
    ignore: []const []const u8 = &.{},
    reason: ?[]const u8 = null,
};

/// How `shadowed-const` picks the values it looks for. `declared` (the default)
/// looks only at the `[[shadow]]` rules a project wrote, so zero rules is a
/// zero-config pass. `auto` sweeps every unit-suffixed file-scope const in the
/// tree — a MEASUREMENT tier for finding out how much shadowing a codebase
/// carries, not a gate.
pub const ShadowedConstMode = enum { declared, auto };

/// Numeric spellings `auto` mode never treats as a shadowable value: too common
/// to mean anything on their own, so a bare one carries no claim about the
/// constant that happens to share it. Compared FOLDED (via `const_fold`), so
/// `0.5` here also silences a bare `.5e0`.
pub const default_shadow_ignore_values = [_][]const u8{
    "0", "1", "-1", "2", "0.5", "10", "100", "1000",
};

/// Per-check config for shadowed-const, the value-reappears-as-a-bare-literal
/// scan. Everything here tunes `auto` mode only; `declared` mode is governed by
/// the `[[shadow]]` rules themselves. `ignore_values` is a folded-compare deny
/// list (set it to `[]` to ignore nothing), and the two digit floors are the
/// significance test a swept value must pass: a float needs `min_float_digits`
/// significant digits and an integer `min_int_digits` digits before a bare
/// occurrence of it says anything.
pub const ShadowedConstCfg = struct {
    mode: ShadowedConstMode = .declared,
    ignore_values: []const []const u8 = &default_shadow_ignore_values,
    min_float_digits: u32 = 2,
    min_int_digits: u32 = 3,
};

/// Per-check config for twin-referent, the "mirrors X / same as Y" comment
/// scan. `ignore` holds path globs (Guardian's ordinary `*` syntax) matched
/// against the commenting file's path AND against the referent text, so a
/// project can silence one stale claim without disabling the check.
pub const TwinReferentCfg = struct {
    ignore: []const []const u8 = &.{},
};

/// Per-check config for twin-drift, the same-named-function drift scan.
pub const TwinDriftCfg = struct {
    /// Normalised body lines a function needs before it is compared at all.
    /// Below this a body is scaffolding — a guard, a delegation, a two-line
    /// accessor — and two files agreeing on it means nothing. Must be >= 2.
    min_statements: u32 = 8,
    /// How much of two bodies must overlap for the pair to be a drifted twin,
    /// as `2·|LCS| / (|A| + |B|)`. Must be in (0, 1) — 1.0 is an identical
    /// pair, which is `report_identical`'s subject, not this floor's. The
    /// motivating eda pair measures 0.82, so the 0.6 default catches it with
    /// margin while a shared-scaffolding-only pair stays below.
    min_similarity: f64 = 0.6,
    /// Report pairs whose normalised bodies are EQUAL. Off by default:
    /// identical copies are duplication debt, and listing them buries the pair
    /// that is actively wrong under the ones that are merely repeated.
    report_identical: bool = false,
    /// Bare function names never paired — the ones a project implements once
    /// per file as an interface rather than copying (`run`, `deinit`).
    ignore: []const []const u8 = &.{},
    /// Longest body the quadratic comparison will read. A pair where either
    /// side is longer is counted and skipped rather than silently costing
    /// seconds on a whole-tree pass.
    max_lines: u32 = 400,
};

/// One project-defined command that participates in Guardian's `all` gate.
/// `command` is an argv array (no shell interpolation); `inputs` are exact or
/// `*`-globbed project-relative files mixed into the green-run cache digest so
/// a changed non-Zig asset can never be hidden by a stale Guardian cache stamp.
/// An exact `{input}` argv token runs the command once per expanded input.
///
/// Expensive gates may opt into performance budgets. `paths` restricts them to
/// diffs touching a named hot path; `benchmark` compares elapsed seconds with a
/// lower-is-better record in `.guardian/benchmarks.txt`; timeout and peak RSS
/// are independent hard ceilings. Zero ceilings disable their respective rule.
pub const ExternalGate = struct {
    name: []const u8,
    command: []const []const u8,
    inputs: []const []const u8 = &.{},
    paths: []const []const u8 = &.{},
    benchmark: ?[]const u8 = null,
    max_regression_pct: u32 = 25,
    timeout_secs: u32 = 0,
    max_rss_mib: u32 = 0,
};

/// Built-in severity presets. `strict` preserves Guardian's historical
/// behavior. `agent` keeps architecture/safety checks blocking while reporting
/// low-signal style heuristics, and `safety` reports broader maintainability
/// advice while retaining correctness/security/process gates as hard blocks.
pub const PolicyProfile = enum {
    strict,
    agent,
    safety,
};

/// Per-check disposition after profile defaults and explicit overrides.
pub const PolicyMode = enum {
    block,
    ratchet,
    report,
};

/// Check severity and policy-file protection settings.
pub const PolicyCfg = struct {
    profile: PolicyProfile = .strict,
    /// Explicit overrides; `block` wins over `report`, which wins over
    /// `ratchet`, so a narrow project exception can tighten a broad profile.
    block: []const []const u8 = &.{},
    ratchet: []const []const u8 = &.{},
    report: []const []const u8 = &.{},
    /// Opt-in CI rail: changes to `protected_paths` fail `policy-drift` unless
    /// GUARDIAN_POLICY_APPROVED is set by the trusted CI/review environment.
    lock_enabled: bool = false,
    lock_against: []const u8 = "HEAD",
    protected_paths: []const []const u8 = &.{ "guardian.toml", ".guardian/" },

    /// Resolves one check's mode. Explicit lists take priority over the profile.
    pub fn modeFor(self: PolicyCfg, check_name: []const u8) PolicyMode {
        // The lock must not be able to downgrade itself through the very policy
        // diff it is reviewing.
        if (std.mem.eql(u8, check_name, "policy-drift")) return .block;
        if (containsName(self.block, check_name)) return .block;
        if (containsName(self.report, check_name)) return .report;
        if (containsName(self.ratchet, check_name)) return .ratchet;
        return profileMode(self.profile, check_name);
    }

    /// Resolves whether a gate uses baseline/ratchet handling. A ratchet always
    /// does; report-only never does; explicit blocks and policy protection
    /// bypass legacy project-wide baseline mode.
    pub fn usesBaselineFor(self: PolicyCfg, check_name: []const u8, global: BaselineCfg) bool {
        const mode = self.modeFor(check_name);
        if (mode == .report) return false;
        if (mode == .ratchet) return true;
        if (std.mem.eql(u8, check_name, "policy-drift")) return false;
        if (containsName(self.block, check_name)) return false;
        return global.enabled;
    }
};

/// Maintenance-command tuning. A zero cache threshold disables the general
/// Zig-cache warning; Guardian-owned mutation/cache state is still audited.
pub const DoctorCfg = struct {
    zig_cache_warn_mib: u32 = 4096,
    guardian_cache_warn_mib: u32 = 1024,
};

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
    return false;
}

fn profileMode(profile: PolicyProfile, check_name: []const u8) PolicyMode {
    const style_advice = [_][]const u8{
        "line-length",
        "repeated-string-literal",
    };
    const maintainability_advice = [_][]const u8{
        "naming",         "doc-comments",           "module-doc-header",
        "function-size",  "function-length",        "file-size",
        "nesting-depth",  "cognitive-complexity",   "type-size",
        "anytype-budget", "bool-ops-per-condition",
    };
    if (profile != .strict and containsName(&style_advice, check_name)) return .report;
    if (profile == .safety and containsName(&maintainability_advice, check_name)) return .report;
    return .block;
}

/// Per-check config for the spec-quality lint.
pub const SpecQualityCfg = struct {
    enabled: bool = true,
    forbidden_phrases: []const []const u8 = &.{},
};

/// Per-check config for the function-size cap.
pub const FunctionSizeCfg = struct {
    enabled: bool = true,
    /// Max runtime parameters per function; `comptime` specialization inputs
    /// are excluded. Default 6 (not 4) because Zig's explicit
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

/// Per-check config for the test-reachability scan: which files Zig actually
/// roots the test binary at. Paths are walker-relative ("src/check.zig",
/// "test/integration.zig"). When empty, the check looks for `src/main.zig`,
/// `src/root.zig`, and every `.zig` directly under `test/`; when none of those
/// exists either, it skips rather than reporting the whole tree as dead.
pub const TestReachabilityCfg = struct {
    enabled: bool = true,
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
    /// Recommended source lines per fn decl. Exceeding this emits a warning.
    max_lines: u32 = 120,
    /// Generous upper bound that still blocks genuinely extreme functions.
    hard_max_lines: u32 = 400,
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

/// `[hysteresis]` — trip → no accept → shrink to recover, for the two-tier
/// hard-cap ratchets (see hysteresis.zig). On by default: a hard-cap crossing
/// stops being one env var away from ratification, and the entry it creates
/// survives the subject dipping back under the cap, so the prune-then-regrow
/// loop closes. Everything below the cap is untouched — hysteresis binds only
/// what crossed.
pub const HysteresisCfg = struct {
    enabled: bool = true,
    /// How far under the hard cap a tripped subject must fall to clear the
    /// trip, as a percentage of the cap (10000 → 8000 at the default 20).
    /// Valid 1..90; anything else is a config error. 20 rather than 50 because
    /// the observed cohesive-extraction quantum is 200–900 lines per module, so
    /// a 2000-line band is an achievable campaign while a 5000-line one forces
    /// cutting past the cohesion frontier into mechanical bisection.
    recover_pct: u32 = 20,
    /// Which checks the rule binds. Only the two-tier hard-cap checks are
    /// valid (`hysteresis.supported`); an unknown or single-tier name is a
    /// config error rather than a silently inert setting.
    checks: []const []const u8 = &.{ "file-size", "function-length" },
};

/// How a build-wired gate behaves on a violation. `report` (the default) runs
/// every check and prints all findings but exits 0, so a dev build always
/// produces a binary; `block` fails the build on any violation (the historical
/// hard-block behavior).
pub const GateMode = enum { report, block };

/// `[gate]` — the report-during-dev, block-at-commit policy. In `report` mode a
/// plain `zig build` surfaces violations without refusing to produce a binary;
/// `commit`/`nightly` and `all --gate` always block regardless of `on_build`.
/// `test_command` is the suite `commit` runs (and must pass) before committing;
/// `install_hook` auto-installs the blocking pre-commit gate on a `commit` run.
pub const GateCfg = struct {
    on_build: GateMode = .report,
    test_command: []const u8 = "zig build test",
    install_hook: bool = true,
};

/// `[test_filter]` — how this project spells the flag that selects tests by
/// name on the *compiler* command line (Zig's `-Dtest-filter=` when the build
/// script wires `addTest(.filters = …)`; not every project spells it the same,
/// so it is configuration rather than an assumption).
///
/// Exactly one thing reads it: the read-only `test-filter` report, which prints
/// a suggested filter for a local edit loop. It is never appended to `[gate]
/// test_command` — a filtered build does not analyze the tests it skipped, so
/// it cannot prove the test binary compiles, and the gate must.
pub const TestFilterCfg = struct {
    flag: []const u8 = "-Dtest-filter=",
};

/// Per-check config for the line-length cap.
pub const LineLengthCfg = struct {
    enabled: bool = true,
    /// Recommended codepoints per line. Exceeding this emits a warning.
    max_len: u32 = 120,
    /// Extreme line length that remains a hard failure.
    hard_max_len: u32 = 240,
};

/// Per-check config for the bool-ops-per-condition cap.
pub const BoolOpsCfg = struct {
    enabled: bool = true,
    /// Max `and` / `or` / `!` tokens inside a single `if`/`while` condition.
    max_ops: u32 = 3,
};

/// Per-check config for oom-discipline (allocation errors silently conflated
/// with domain absence). Opt-in: strict, catches `catch return null`/
/// `catch continue` on allocating calls that drop data on OOM.
pub const OomDisciplineCfg = struct {
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

/// Config for local metrics (non-gating; see dora.zig and check_roi.zig). Each
/// full `all`/`nightly` run appends DORA while every invocation appends ROI;
/// `enabled = false` is the shared v1 opt-out. The streams remain separate
/// under `.guardian/cache/`, so writing them never invalidates the skip-cache.
pub const DoraCfg = struct {
    enabled: bool = true,
    sink_path: []const u8 = ".guardian/cache/dora.jsonl",
};

/// Config for the benchmark ledger (`.guardian/benchmarks.txt`; see
/// benchmark.zig). The ledger itself is always report-only — every gate run
/// prints what agents recorded. `gate` opts INDIVIDUAL metrics into a
/// mutation-ratchet-style ceiling: a listed metric may only improve or hold
/// when re-recorded, and `bench set` refuses a regression without an explained
/// `--force`. Empty by default: nothing is gated until a project names a metric.
pub const BenchmarkCfg = struct {
    gate: []const []const u8 = &.{},
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
    /// Cap on mutants exercised per full run; larger candidate sets are
    /// sampled deterministically by stable mutant-identity hash.
    max_mutants: u32 = 100,
    /// Smaller deterministic budget used by the fast/PR mutation tier. The
    /// full/nightly tier continues to use `max_mutants`.
    fast_max_mutants: u32 = 8,
    /// Optional build step run before the full test step for each mutant. A
    /// smoke failure kills the mutant; smoke survivors still run the full
    /// suite, so this can only save work without weakening coverage.
    smoke_step: ?[]const u8 = null,
    /// Floor (seconds) under the per-mutant timeout. The deadline is
    /// `max(timeout_floor_secs, timeout_multiplier × clean-suite baseline)`, so
    /// a fast suite still gets at least this long before a hang is called.
    /// Default 30 (cargo-mutants-style).
    timeout_floor_secs: u32 = 30,
    /// Multiplier on the measured clean-suite duration for the per-mutant
    /// timeout (see `timeout_floor_secs`). Default 5 — generous headroom over a
    /// normal run so only a genuine hang trips it.
    timeout_multiplier: u32 = 5,
    /// Multiplier applied to the first deadline when retrying an inconclusive
    /// timeout. Must be non-zero.
    timeout_retry_multiplier: u32 = 2,
    /// Safety cap on the clean-suite baseline measurement, and the fallback
    /// per-mutant timeout used when that baseline can't be measured (the clean
    /// suite errored or hung). A timed-out mutant is retried with an expanded
    /// deadline; a repeated timeout is inconclusive and excluded from scoring.
    timeout_secs: u32 = 300,
    /// Number of exact suite-digest mutation caches retained for reuse.
    retained_cache_suites: u32 = 3,
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

/// Per-check config for script-string-safety. `blob_files` names the JSON/string
/// serializers whose output is embedded verbatim into an HTML `<script>` element
/// (path globs, walker-relative). Inside a listed file, a JSON-string escaper —
/// one that opens a `"` and escapes `"` and `\` — that never escapes `<` (and a
/// file that emits JSON strings only through such an unsafe helper) is a stored-
/// XSS class: `</script>` in the data terminates the element. Opt-in by
/// construction: an empty list (the default) makes the check a no-op, because a
/// plain `application/json` writer legitimately need not escape `<` — only the
/// consumer knows which serializers actually feed a script blob.
pub const ScriptStringSafetyCfg = struct {
    blob_files: []const []const u8 = &.{},
};

/// One `[[dead_model_field]]` entry — a struct whose fields are checked for the
/// "surfaced but never enforced" drift, by the `dead-model-field` check.
/// `struct_name` names the owning struct (leads every finding and its baseline
/// key); `owner` is the file that declares it (used to auto-discover fields when
/// `fields` is empty); `fields` optionally pins the exact field names to check
/// (the precise mode — avoids conflating a field with a same-named field on
/// another struct); `output` globs the render/review files a field may be read
/// in and still be dead; `logic` globs the decision/enforcement files whose read
/// proves a field is live; `reason` closes every violation.
///
/// A field referenced under `output` but under none of `logic` is a contract
/// shown to the user and enforced by nobody — the drift this check exists for.
pub const DeadModelFieldRule = struct {
    struct_name: []const u8,
    owner: ?[]const u8 = null,
    fields: []const []const u8 = &.{},
    output: []const []const u8 = &.{},
    logic: []const []const u8 = &.{},
    reason: ?[]const u8 = null,
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

/// Per-check config for concurrency-test-presence. Each path in `modules` must
/// contain a test that spawns a second unit of execution (`Thread.spawn`,
/// `Thread.Pool`, or an `Io.concurrent` call), directly or through a helper the
/// test calls. Opt-in by construction: an empty list (the default) is a no-op,
/// so the check does nothing until a project names the files whose shared
/// mutable state it expects to keep under test. Paths are walker-relative,
/// resolved under the project dir; a listed file that is missing/unreadable or
/// carries no concurrency test is a hard failure, so a stale entry fails the
/// gate closed rather than silently passing.
pub const ConcurrencyPresenceCfg = struct {
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

/// `[measurement]` — the instrumentation bridge (see measurement.zig). Each
/// entry is a walker-relative file path ("src/placement/router.zig") or a
/// directory prefix ("src/bench"); wildcards are rejected by the parser, since
/// an instrumentation allowlist is a boundary rather than a convenience glob.
/// Inside these paths the instrumentation-class checks (ban-globals, ban-time,
/// debug-print-ban, pub-api-surface) report their findings under a
/// non-blocking MEASURE verb on a LOCAL run, and block exactly as they do today
/// at commit / `--gate` / on any metadata-writing run. Empty (the default) is
/// exactly today's behavior everywhere.
pub const MeasurementCfg = struct {
    paths: []const []const u8 = &.{},
};

/// Aggregated guardian.toml configuration; defaults are sensible.
pub const Config = struct {
    spec_file: []const u8 = "SPEC.md",
    /// Max lines per .zig file. Default 1000 (not 500): the low cap has no
    /// research basis and a real production codebase relaxed it.
    max_file_lines: u32 = 1000,
    /// Files above the recommended limit warn; only this extreme size blocks.
    hard_max_file_lines: u32 = 10_000,
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
    /// "line-length"). Lets a project disable individual checks that have no
    /// dedicated [section] toggle. Matched against each check's registry name.
    disabled: []const []const u8 = &.{},
    /// Project-relative paths or `*` globs that must match before Guardian runs
    /// analysis capable of creating or pruning baselines/snapshots.
    required_inputs: []const []const u8 = &.{},
    boundary_rules: []const BoundaryRule = &.{},
    spec_quality: SpecQualityCfg = .{},
    function_size: FunctionSizeCfg = .{},
    complexity: ComplexityCfg = .{},
    anytype_budget: AnytypeBudgetCfg = .{},
    orphan_files: OrphanFilesCfg = .{},
    test_reachability: TestReachabilityCfg = .{},
    doc_quality: DocQualityCfg = .{},
    type_size: TypeSizeCfg = .{},
    function_length: FunctionLengthCfg = .{},
    nesting_depth: NestingDepthCfg = .{},
    test_coverage: TestCoverageCfg = .{},
    bool_ops: BoolOpsCfg = .{},
    line_length: LineLengthCfg = .{},
    baseline: BaselineCfg = .{},
    hysteresis: HysteresisCfg = .{},
    gate: GateCfg = .{},
    test_filter: TestFilterCfg = .{},
    oom_discipline: OomDisciplineCfg = .{},
    module_doc_header: ModuleDocHeaderCfg = .{},
    dead_pub: DeadPubCfg = .{},
    change_classification: ChangeClassificationCfg = .{},
    mutation: MutationCfg = .{},
    benchmark: BenchmarkCfg = .{},
    completeness: CompletenessCfg = .{},
    dora: DoraCfg = .{},
    fuzz_presence: FuzzPresenceCfg = .{},
    concurrency_presence: ConcurrencyPresenceCfg = .{},
    script_string_safety: ScriptStringSafetyCfg = .{},
    int_from_float: IntFromFloatCfg = .{},
    divergent_const: DivergentConstCfg = .{},
    shadowed_const: ShadowedConstCfg = .{},
    twin_referent: TwinReferentCfg = .{},
    twin_drift: TwinDriftCfg = .{},
    measurement: MeasurementCfg = .{},
    policy: PolicyCfg = .{},
    doctor: DoctorCfg = .{},
    external_gates: []const ExternalGate = &.{},
    /// [[allow]] entries: per-check allowed-path overrides (see AllowRule).
    allow_rules: []const AllowRule = &.{},
    /// [[ban]] entries: project-declared banned symbol chains (see BanRule).
    /// Empty (the default) makes the `ban` check a trivial pass.
    ban_rules: []const BanRule = &.{},
    /// [[concept]] entries: project-declared owned concepts (see ConceptRule).
    /// Empty (the default) makes the `concept` check a trivial pass.
    concept_rules: []const ConceptRule = &.{},
    /// [[idiom]] entries: project-declared owned expression shapes (see
    /// IdiomRule). Empty (the default) makes `canonical-idiom` a trivial pass.
    idiom_rules: []const IdiomRule = &.{},
    /// [[shadow]] entries: project-declared single-source-of-truth constants
    /// (see ShadowRule). Empty (the default) makes `shadowed-const` a trivial
    /// pass in its default `declared` mode.
    shadow_rules: []const ShadowRule = &.{},
    /// [[layering]] entries: project-declared import directions (see
    /// LayeringRule). Empty (the default) makes the `import-layering` check a
    /// trivial pass.
    layering_rules: []const LayeringRule = &.{},
    /// [[twin]] entries: project-declared multi-surface capabilities (see
    /// TwinRule). Empty (the default) makes the `twin-parity` check a trivial
    /// pass.
    twin_rules: []const TwinRule = &.{},
    /// [[dead_model_field]] entries: project-declared model structs whose
    /// surfaced-but-unenforced fields the `dead-model-field` check flags. Empty
    /// (the default) makes that check a trivial pass.
    dead_model_field_rules: []const DeadModelFieldRule = &.{},

    /// Extra allowed-path globs configured for `check_name` via [[allow]]
    /// (empty when none). Checks merge these with their compiled defaults.
    pub fn extraAllowed(self: *const Config, check_name: []const u8) []const []const u8 {
        for (self.allow_rules) |r| {
            if (std.mem.eql(u8, r.check, check_name)) return r.paths;
        }
        return &.{};
    }
};

// spec: Policy Modes - Resolves strict, agent, and safety profiles with explicit per-check overrides

test "policy profiles separate blocking checks from report-only advice" {
    const strict: PolicyCfg = .{};
    try std.testing.expect(strict.modeFor("line-length") == .block);
    const agent: PolicyCfg = .{ .profile = .agent };
    try std.testing.expect(agent.modeFor("line-length") == .report);
    try std.testing.expect(agent.modeFor("ban-secrets") == .block);
    const safety: PolicyCfg = .{ .profile = .safety };
    try std.testing.expect(safety.modeFor("function-length") == .report);
    const overridden: PolicyCfg = .{
        .profile = .safety,
        .block = &.{"function-length"},
        .ratchet = &.{"dead-pub"},
    };
    try std.testing.expect(overridden.modeFor("function-length") == .block);
    try std.testing.expect(overridden.modeFor("dead-pub") == .ratchet);
    try std.testing.expect(overridden.modeFor("policy-drift") == .block);
    try std.testing.expect(!overridden.usesBaselineFor("function-length", .{ .enabled = true }));
    try std.testing.expect(!overridden.usesBaselineFor("policy-drift", .{ .enabled = true }));
    try std.testing.expect(overridden.usesBaselineFor("dead-pub", .{}));
    try std.testing.expect(safety.usesBaselineFor("ban-secrets", .{ .enabled = true }));
}
