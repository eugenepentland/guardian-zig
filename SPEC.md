# Guardian for Zig

## Overview

Build-step quality gates for Zig projects. Runs on every `zig build` with
blocking correctness checks and advisory maintainability guidance.

## Configuration

- Loads guardian.toml from target directory
- Falls back to defaults when no config file exists
- Hard-fails when the config file exists but cannot be read
- Hard-fails on an unknown section header naming the offender
- Hard-fails on an unknown key within a known section
- Hard-fails on malformed values and bare non-key lines with a located diagnostic
- Hard-fails on incomplete boundary and allow array tables
- Supports multiline string arrays with comments and trailing commas
- Rejects unsafe mutation ranges and zero timeouts
- Supports boundary rules via [[boundary]] sections
- Parses a top-level disabled list of check names
- Parses the baseline deny_growth check list
- Parses per-check allowed-path overrides via [[allow]] sections
- Parses a top-level exclude list of path globs dropped from the scan
- Defaults magic-number off and enables it via [magic_number] enabled
- Defaults stdout_flush off and promotes it to a hard block via [stdout_flush] enabled
- Parses the module_doc_header min_lines threshold
- Parses the mutation section score and budget settings
- Parses the mutation section timeout floor and multiplier
- Parses the change classification toggle and against ref
- Parses the change classification last-commit gate toggle
- Defaults completeness off and parses its enabled and exempt_sections settings
- Parses the dora sink path and enabled toggle
- Parses the fuzz_presence modules list
- Parses the int_from_float guard_fns and require_guard lists
- Parses the against and full command-line flags
- Parses the only, skip, and version command-line flags
- Parses the intent flag for the commit command
- Parses the gate command-line flag
- Parses the gate mode, test command, and hook install settings
- Parses the test_filter flag spelling
- Splits a comma-separated filter value into check names
- Rejects combining the only and skip filters
- Parses policy profiles, policy locks, doctor thresholds, and external argv gates
- Parses warning and hard limits for file size, function length, and line length
- Parses a top-level required input glob list

## Formatting

- Reports the first line where a file diverges from zig fmt output
- Names the file and the exact zig fmt command that fixes it

## Missing Inputs

- Extracts the zig file a rendered violation line refers to
- Extracts the file recorded in a stored baseline or ratchet key
- Treats a path as phantom only when it is absent and gitignored

## Spec Coverage

- Parses SPEC.md for section headers and behavior bullets
- Scans test and source files for // spec: tags
- Reports unverified behaviors and unlinked tags
- Enforces 1:1 mapping between spec behaviors and test tags
- Fails with clear error when SPEC.md is missing
- Fails when SPEC.md defines no behaviors
- Reports near-miss spec tags that miss the exact prefix
- Reports duplicate spec behavior bullets
- Requires each spec tag to sit directly on a test
- Links stable behavior IDs independently of specification wording
- Allows additional spec-case tests without weakening the required primary link

## Spec Lifecycle

- Generates starter SPEC.md from pub fn signatures via spec-init
- Normalizes spec keys for whitespace-insensitive comparison
- Strips trailing sentence punctuation when normalizing spec keys

## File Size

- Warns above a configurable recommended line limit and fails above a generous hard limit
- Respects file_size_exclude patterns
- Excludes test-block lines from the line count

## Required Inputs

- Fails before project analysis when a required input pattern matches nothing

## Boundaries

- Extracts @import paths from source files and normalizes relative paths
- Matches file paths against glob and prefix boundary patterns
- Checks against boundary rules defined in guardian.toml
- Reports forbidden import violations

## Usingnamespace Ban

- Hard-fails any usingnamespace keyword outside test files

## Deprecated Alias

- Flags the std.ArrayListUnmanaged deprecated 0.15 alias
- Flags a managed hashmap construction such as std.StringHashMap
- Flags the usingnamespace keyword removed in 0.15
- Flags the pre-0.15 getStdOut and getStdErr writer idioms
- Names the modern replacement for each flagged alias
- Allows the unmanaged and 0.15 replacement spellings

## Spec Quality

- Flags vague behavior phrases in SPEC.md
- Rejects behaviors shorter than the minimum length
- Fails when SPEC.md is missing instead of silently skipping

## Naming

- PascalCase pub fn must return type
- camelCase pub fn must not return type
- snake_case pub fn is rejected
- pub const struct/enum/union with fields must be PascalCase
- SCREAMING_SNAKE container-scope const is rejected

## Function Size

- Caps parameter count per function
- Excludes comptime specialization parameters from the runtime parameter cap
- Reports the offending function's source line with the file

## Doc Comments

- Requires /// on every pub fn
- Requires /// on every pub struct/enum/union/opaque
- Rejects empty or stub doc comments on public declarations
- Exempts protocol and trivial method names from the presence requirement

## Imports

- Detects cycles in the @import graph

## AST Index

- Builds a parsed-source index by reading and parsing each file once
- Iterates the index exposing each file's pre-parsed syntax tree to a visitor
- Returns the shared index when present and builds a private one otherwise
- Drops files matching a config exclude glob from the built index

## Skip Cache

- Hashes the guardian input set into a stable digest
- Round-trips the digest through the cache file
- Mixes the guardian binary identity into the digest so an upgrade invalidates the cache
- Reflects a rewritten .guardian baseline in a fresh input digest
- Includes declared external gate input files in the green-run digest
- Includes files referenced by project-local embedFile calls
- Invalidates a green stamp when the Git HEAD changes
- Records the guardian binary identity in the green stamp for a drift hint
- Reads the stamp and binary timestamps behind the stale-binary direction hint

## Run All

- Skips checks whose name appears in the disabled config list
- Rejects unknown check names in the disabled list
- Tolerates retired check names in the disabled list
- Emits captured output when not quiet or when a check fails or warns
- Runs only the checks named by an only filter
- Excludes the checks named by a skip filter
- Rejects an only or skip name that is not a runnable check
- Detects a filtered run so the green cache stamp is suppressed
- Skips a full run when the input digest matches the last green run and no refresh is pending
- Rejects an unknown refresh target or deny_growth check name
- Cautions on failure that zig-out binaries predate the red run
- Blocks the build only when forced or configured to block
- Names the failing checks in the run summary
- Hints a stale binary when re-keying failures follow a binary change
- Warns before the run when the binary differs from the last green stamp
- Runs a metadata transaction only when the run can write metadata
- Names a check that runs past the heartbeat threshold
- Runs the cheapest formatting gate before the rest of the suite
- Names each failing check's first finding under the run summary

## Run Summary

- Renders one verdict line for the green failing and cached exit paths
- Separates blocking failures from report-only findings in the summary
- Replays blocking check output before advisory output
- Collapses an out-of-scope report-only check to one counted line
- Names the finding count and scope in a collapsed check line
- Counts a finding as in scope when its file changed or it has no file
- Counts a check's findings and their diff-scope overlap
- Prints only the verdict and blocking detail in summary mode
- Keeps every check's full output under the verbose flag
- Parses the summary and verbose output flags
- Resolves the verbose flag ahead of the summary flag
- Appends a plus-N-more count when a failing check has several findings
- Names which binary is newer when the gating binary differs from the last green stamp

## Nightly

- Fails when either the suite or the whole-tree mutation ratchet fails
- Runs the whole-tree mutation tier by setting the full flag

## Migrate

- Persists a deferred metadata format re-key as one deliberate step

## Explain

- Returns the explanation text for a registered check name
- Signals an unknown check name
- Provides an explanation entry for every registered command
- Resolves a summary for checks and documented meta commands
- Documents the commit meta command

## Commit

- Requires a non-empty intent message
- Excludes untracked secret and build-artifact paths from staging
- Skips secret-like names regardless of letter case
- Never skips an already-tracked path
- Never skips a Zig source file for a secret-like name
- Warns loudly listing every skipped path
- Always stages guardian metadata and the spec file
- Reports nothing to commit when no eligible paths remain
- Splits the configured test command into an argv vector
- Excludes suffixed zig build cache directories from staging
- Excludes untracked agent session-state directories from staging
- Excludes its own generated pre-commit hook from staging
- Never stages the git-ignored guardian cache directory
- Reports a gate and test timing split
- Reports up front when the change set contains no gate inputs

## Install Hook

- Writes a pre-commit hook that runs the blocking gate
- Refuses to overwrite a foreign pre-commit hook
- Bakes the installing binary as the hook's last-resort fallback
- Resolves the hook path relative to the project root
- Gates with the newer of a local build and the baked binary

## Debt

- Counts non-header lines for baseline and pub-api debt
- Notes a per-item ratchet's worst offender
- Sums snapshot counts while ignoring magnitude keys
- Reads the mutation kill score from its snapshot
- Classifies each .guardian file into a labelled debt source
- Sorts the debt rows by count descending
- Formats a committed-state delta and omits it when unchanged or absent
- Omits a clean source with zero debt and no committed change
- Reports source files over the recommended size against both limits
- Reports assert-call density per top-level src module sorted ascending

## Maintenance

- Doctor distinguishes advisory warnings from integrity failures
- Doctor reports a stale gating binary
- Gates artifact copies without delaying generators that prepare analysis inputs
- Spec sync suggests missing bullets without editing SPEC.md
- Debt emits JSON and filters by check
- Debt previews stale baseline pruning before explicit confirmation
- Parses maintenance command flags independently of the project directory
- Accept refreshes only named checks and verifies them after updating metadata
- Accept records a session note that expires when the head commit changes
- Parses named accept checks before the optional project directory
- Run context recognizes only explicitly named accept refreshes
- Registers a canonical build runner for the current Guardian binary

## Policy Modes

- Resolves strict, agent, and safety profiles with explicit per-check overrides

## Policy Protection

- Blocks protected Guardian metadata drift unless trusted CI approves it

## External Gates

- Runs configured argv commands without a shell and blocks on nonzero exit

## Versioning

- Reports a non-empty dotted guardian version string

## Snapshot Lifecycle

- Atomically replaces snapshot files after fully writing their contents
- Skips an identical rewrite and leaves the file untouched
- Defers snapshot creation to a metadata-writable run
- Creates snapshot file on first run with no prior snapshot
- Reports drift when current state differs from prior snapshot
- Honors GUARDIAN_UPDATE_SNAPSHOT to regenerate snapshot
- Refreshes only the checks named in a GUARDIAN_UPDATE_SNAPSHOT list
- Requires the explicit all token for a full refresh
- Treats an unset, empty, or zero value as no refresh
- Accept command refreshes only its explicit context-local check names
- Lists the metadata files a named refresh keeps through a failed gate
- Prints every working accept path for a snapshot check's drift
- Offers a concrete named-refresh example when a broad token is rejected

## Pub Api Surface

- Snapshots every public declaration
- Diff fails on unexpected pub additions or removals
- Diff fails when an existing pub fn signature changes
- Classifies surface drift as new, changed, and removed symbols
- Skips removed symbols whose file is unbuilt generated output

## Panic Budget

- Tracks panic and unreachable token counts against a snapshot
- Tracks TODO and FIXME comment counts against a snapshot
- Tracks @setEvalBranchQuota call count and max value against a snapshot

## Catch Discipline

- Rejects catch unreachable in production code
- Rejects catch with empty block (silent error swallow)
- Rejects catch undefined assigning undefined on error

## Unwrap Discipline

- Rejects orelse unreachable in production code
- Rejects orelse undefined in production code

## Error Discipline

- Rejects inferred error sets on pub fn
- Rejects anyerror on pub fn
- Rejects a const that aliases anyerror and any pub fn returning that alias

## Cognitive Complexity

- Caps per-function cognitive complexity score

## Anytype Budget

- Caps anytype parameter count per file
- Skips files matching the exclude patterns
- Excludes writer-typed anytype parameters

## Dead Pub

- Flags public declarations referenced only by themselves
- Skips test-block references toward liveness when configured

## Allocator Hygiene

- Rejects hardcoded global allocators outside test blocks and pub fn main
- Honors a // allocator-ok justification comment to suppress a site

## Duplicate Const

- Rejects duplicate file-scope string-literal consts (same name and value) across files
- Ignores cross-file consts shorter than the in-file minimum length

## Debug Print Ban

- Rejects std.debug.print call expressions outside test blocks and pub fn main
- Rejects std.log.* call expressions outside test blocks and pub fn main
- Exempts CLI command modules where printing to stdout is the program working

## Orphan Files

- Reports .zig files under src/ unreachable from any configured root via @import

## Stub Body Ban

- Rejects single-statement stub bodies (undefined, placeholder panic, unreachable in value fn)

## Int From Float Budget

- Tracks @intFromFloat call count against a snapshot
- Exempts an @intFromFloat inside a configured guard function body
- Flags each unguarded cast under a require_guard path

## Unsafe Ops Budget

- Tracks unsafe-cast builtin counts against a snapshot
- Tracks undefined re-assignment count against a snapshot
- Excludes declaration-init undefined and test blocks from counts

## Type Size

- Caps fields per pub struct/union/opaque
- Exempts enums from the field cap
- Skips pub containers in files matching the exclude patterns

## Function Length

- Warns on long functions and fails only above a configurable hard line limit

## Nesting Depth

- Caps brace-nesting depth inside fn bodies

## Stack Escape

- Flags returning the address of a stack local variable
- Flags returning a slice of a stack array local
- Flags returning the address of a field of a stack local
- Flags returning a const alias bound directly to a stack local address
- Allows returning the address of a parameter owned by the caller
- Allows returning a pointer derived from a parameter field
- Allows returning a local whose initializer calls a function
- Allows returning a local that is itself a pointer or slice
- Allows returning the address of a comptime local
- Handles returned stack addresses through an error union return type
- Skips returns that appear inside a test block

## Test Coverage

- Requires every pub fn to be referenced from at least one test block

## Constructor Hygiene

- Rejects @compileError without a non-empty string explanation
- Rejects init bodies with loops, conditionals, or switch statements
- Rejects static factory / singleton patterns in business logic
- Requires structs that own an allocator field to declare a pub fn deinit
- Requires init bodies with multiple try calls to use errdefer

## Tier 2 Anti-patterns

- Warns on long source lines and fails only above a configurable hard length
- Skips multiline-string literal lines from the length cap
- Exempts spec tag comment lines from the length cap
- Rejects vague identifier names on public declarations
- Rejects bool parameters in public functions
- Rejects bare integer literals outside a small allowlist
- Rejects identical string literals appearing 3 or more times in a single file
- Names the line of each repeated-literal occurrence
- Identifies a repeated literal by the literal itself
- Caps pub fn methods per pub struct/enum/union
- Caps the percentage of optional fields in a public struct
- Rejects switch expressions whose case keys are string literals

## Tier 3 Architectural Fitness

- Flags the same enum dot-prong set switched in 2+ files
- Ignores repeated enum switches that occur only inside test blocks
- Names every file sharing a repeated enum prong set
- Renders each colliding switch location as file and line

## Transactional Metadata

- Restores all non-cache Guardian metadata after a failed gate
- Preserves a named refresh's metadata across a failed gate

## Baseline Mode

- Captures each check's current violations on first run and only fails on additions
- Defers first-record and prune writes to a metadata-writable run
- Wraps a single check run with capture, diff, and outcome reporting
- Prunes the baseline file when resolved violations shrink it
- Refuses to refresh a deny_growth baseline that would grow
- Prefers structured records over scraped text when present
- Leaves a matched baseline untouched when only line numbers shifted
- Records no baseline file for a check with nothing to record
- Prefixes a matching baseline or ratchet report with an ok marker
- Keeps a baselined violation matched when its message text is reworded
- Re-keys a stale text baseline to stable identities without failing
- Refuses to migrate a stale baseline when a file gained violations
- Stops scraping violations at every trailing prose label
- Preserves the count of same-key violations across a stored baseline
- Skips findings whose file is missing and gitignored instead of counting them

## Violation Identity

- Collapses standalone digit runs while keeping digits glued to identifiers
- Keys a record by its explicit identity then ratchet key then message skeleton
- Derives the same fallback key from a scraped line as from a record
- Reports the file a rendered violation line names
- Identifies a banned symbol hit by its file and symbol rather than its wording
- Ignores a path inside a message when locating the violation's file

## Per-Item Ratchets

- Selects the ratchet lifecycle only for threshold checks
- Defers the auto-lower write to a metadata-writable run
- Aggregates violation records to the max metric per key
- Counts over-limit records per key in count mode
- Encodes and decodes a value key line
- Fails when a key value exceeds its recorded ceiling
- Fails an unrecorded key as a new offender over the default cap
- Lowers a key whose value decreased and stays green
- Prunes keys absent from the current violations
- Matches when every key holds its recorded value
- Creates then auto-lowers a ratchet file across runs
- Re-records a stale-version baseline as a ratchet
- Refuses a deny_growth refresh that raises a value or adds a key
- Summarizes a ratchet file's worst offender
- Presents file and type growth as volume with accept-first guidance
- Notes that a grown ratchet item was already sitting at its frozen cap
- Names each threshold check's metric unit for regression messages
- Scrapes the check's own fix hint for the regression message
- Retains legacy ratchet entries while the same subjects remain advisory warnings
- Names the offending file line and metric in the regression status line

## Measurement Mode

- Defers only the instrumentation-class checks
- Voids the exemption for gating and metadata-writing runs
- Matches a measurement path by exact file or directory prefix
- Hands each check an inert exemption unless the bridge applies
- Reports deferred findings under a non-blocking MEASURE verb
- Prints a standing reminder naming every exempted path and count
- Parses the measurement paths list and rejects a wildcard entry
- Passes an exempt finding locally and blocks the same finding at commit
- Defers public-surface drift inside a measurement path
- Withholds the green skip-cache stamp from a run with deferred findings

## Reporter

- Renders a Violation to the same indented line the emitter prints
- Keeps advisory warnings separate from blocking violation records
- Prints a report-only verb instead of FAILED for a policy-demoted check

## Machine-Readable Sink

- Serializes each violation as a JSON line escaping message and path text
- Appends a run summary record with pass fail skip counts
- Writes the last-run log under the git-ignored guardian cache dir
- Writes a summary-only log when the run passes with no violations

## Delivery Metrics

- Renders a run record as one JSON line with outcome and failed checks
- Includes the git branch and commit or null when absent
- Appends a run record to the sink without overwriting
- Writes nothing when the dora sink is disabled
- Converts elapsed nanoseconds to whole milliseconds
- Reads zero elapsed for an unavailable stopwatch and a non-decreasing value otherwise

## Git Diff

- Parses unified diff hunk headers into added line spans
- Groups unified diff output into per-file added spans
- Returns no spans for deletion-only hunks and deleted files
- Counts a commit's parents from a rev-list line
- Extracts changed and untracked paths from porcelain status resolving renames
- Distinguishes untracked entries from tracked ones in porcelain status
- Classifies a not-a-git-repository failure as a skip, not a hard error
- Hard-fails a diff-scoped git command that fails for any other reason
- Resolves the merge base with a branch and reports null when it cannot

## Diff Scoping

- Falls back to the whole tree for full, gate, and metadata-writing runs
- Falls back to the whole tree when guardian config or recorded debt changed
- Resolves a whole-tree decision when the base or the diff cannot be read
- Reports whether a changed-file plan covers a given path
- Narrows the shared parsed-source index to the changed files
- Classifies every cross-file and tree-wide check as whole-tree
- Hands the narrowed index only to per-file checks
- Treats a diff-scoped run as partial so it never stamps the green cache
- Reports a partial view's baseline shrink as a match instead of resolved work
- Reports a partial view's ratchet improvement as a match instead of progress
- Refuses every metadata write for a check that read only part of the tree

## Test Filter

- Derives the test names declared by each changed file
- Counts unnamed test blocks as tests no name filter can select
- Derives names only from changed files and deduplicates them
- Reports changed files that declare no test and changed paths that are not indexed source
- Reports the tests of every unchanged file that transitively imports a changed one
- Emits no filter arguments when no test name was derived
- Reports no filter when the run cannot be diff-scoped
- Leaves the commit gate running the whole configured test command

## Change Classification

- Counts added lines inside test blocks as test changes
- Counts added spec-tag comment lines as test changes
- Ignores added blank and comment-only lines
- Counts remaining added source lines as behavioral changes
- Passes when behavioral changes are accompanied by test changes
- Fails when behavioral changes have no test or spec change
- Treats an added SPEC.md behavior bullet as a spec change
- Ignores SPEC.md edits confined to prose, headers, or fenced code
- Gates the last commit when the working tree is clean against HEAD
- Skips the last-commit fallback at a merge or root commit
- Uses the working tree when the base is overridden or the gate is disabled

## Mutation Testing

- Reports running elapsed and survivor count per mutant
- Generates mutants by flipping comparison operators outside test blocks
- Generates mutants by swapping binary plus and minus operators
- Skips unary minus when generating arithmetic mutants
- Generates mutants by swapping boolean and/or keywords
- Generates mutants by flipping true and false literals
- Restricts fast-tier mutants to added line spans
- Samples mutants deterministically down to the configured cap
- Samples mutants by stable identity hash
- Distinguishes repeated mutation sites on one line in the cohort identity
- Applies a mutant by splicing the replacement into the source
- Classifies mutant outcomes from the build and test phases
- Excludes inconclusive timeouts from the mutation score
- Derives a per-mutant timeout from the clean-suite baseline and a floor
- Kills the whole child process group when a mutant run exceeds its deadline
- Recovers an interrupted run by reverting the journaled in-flight mutant
- Fails a run whose score drops below the configured minimum
- Gates on the kill percentage only at or above the min_mutants floor
- Ratchets the full-run mutation score against a snapshot
- Rejects malformed mutation ratchets instead of recreating them
- Skips every check while a mutation test run is in progress
- Excludes a mutate-ok waived line from generation and counts the waiver
- Records the original source line on each generated mutant
- Keys the result cache on a suite digest that changes with any source or test edit
- Serializes and reparses a cached mutant outcome name
- Builds a stable mutant identity key from its file span and operator
- Renders a cached mutant outcome as one JSON record
- Retains bounded exact suite-digest cache cohorts
- Reuses appended outcomes on load and bypasses the cache under refresh
- Records each surviving mutant with its operator and original source line
- Records a mutation summary with the tier, score, and outcome counts
- Writes the survivor report under the git-ignored mutate cache dir
- Persists the exact sampled mutation cohort
- Uses and cleans a campaign-local Zig cache

## Benchmark Ledger

A plain-text record of measurements agents already paid for
(`.guardian/benchmarks.txt`): one sorted line per named metric with its value,
unit, direction, commit, date, and a one-line note. Guardian never runs a
benchmark — it stores what was measured, prints it back on every gate run, and
(only for metrics named in `[benchmark] gate`) refuses to record a regression
without an explained `--force`.

- Round-trips a recorded metric through its stored line
- Rejects a malformed stored line rather than guessing
- Refuses a value that is not a finite number
- Validates metric names, units, and notes as storable text
- Prints one compact summary line per recorded metric
- Replaces an existing metric's line instead of appending a duplicate
- Removes a named metric and reports an unknown one
- Persists the ledger sorted by metric name
- Fails closed on a corrupt ledger instead of rewriting it
- Formats a measurement date as an ISO calendar day
- Treats only a worsening move as a regression for a directional metric
- Gates only the metrics named in the benchmark gate list
- Parses the opt-in list of gated benchmark metrics
- Parses a bench recording's positionals and flags into one argument bag
- Assigns bench positionals per subcommand before the project directory
- Rejects an unstorable set invocation naming the offending input
- Defaults an omitted direction to the undirected info metric
- Requires an explanatory note when forcing a recording
- Refuses a gated metric's regression unless the recording is forced
- Surfaces every recorded metric on each gate run without blocking it

## Complexity Bounds

- Caps boolean operators per condition

## Test Hygiene

- Requires every test block to contain at least one std.testing.expect call
- Rejects if/while/switch and extra for loops at the top level of a test body
- Identifies a flagged construct by its test and keyword
- Rejects production code @import-ing test files

## Test Skip Ban

- Flags a test whose first statement is an unconditional SkipZigTest
- Allows a conditional SkipZigTest guard
- Flags a test with an empty body
- Allows a test with a real assertion body

## Completeness Checklist

- Fails when SPEC.md is missing while enabled instead of skipping
- Fails a feature section that omits a required completeness category
- Passes a section whose bullets address every completeness category
- Accepts a completeness-waiver bullet that gives a reason
- Rejects a completeness-waiver bullet that omits its reason
- Skips sections listed in the exempt_sections config
- Excludes completeness-waiver bullets from spec behavior mapping

## Escape Discipline

- Flags raw {s} interpolation into HTML/SVG markup

## Oom Discipline

- Flags allocation errors dropped by a swallowing catch
- Flags a dropped allocation error returned as a value expression
- Allows returning the caught error payload or an error value

## Hidden Dependency Bans

- Rejects std.time wall-clock reads outside infra/clock
- Rejects RNG construction outside infra/random
- Rejects std.fs I/O calls outside infra/fs
- Rejects std.net and std.http use outside adapters/http or infra/net
- Rejects environment-variable reads outside config or main
- Rejects sleep calls outside test infrastructure
- Rejects mutable pub var globals outside wiring/main
- Rejects non-pub file-scope var globals outside wiring/main
- Rejects hardcoded absolute paths and URLs in string literals

## Fakes

- FakeClock reads back its start time
- FakeClock advance accumulates elapsed nanoseconds
- FakeClock sleep advances the clock instead of blocking
- FakeClock reads through an injected Clock port
- SeededRandom reproduces a sequence for a given seed
- SeededRandom diverges for different seeds
- FakeFs round-trips bytes through writeFile and readFile
- FakeFs reports existence of written paths
- FakeFs deleteFile removes a stored file
- FakeFs readFile returns FileNotFound for a missing path
- FakeFs listPaths returns paths sorted ascending
- FakeEnv get returns a set value
- FakeEnv get returns null for an unset key
- FakeEnv unset removes a variable

## Ban Secrets

- Flags known-format vendor tokens like AWS and GitHub keys
- Flags PEM private-key headers even inside test and fixture paths
- Flags high-entropy secret-named assignments outside tests
- Ignores placeholder and env-var-name secret assignments
- Ignores publishable and test vendor keys
- Skips the entropy heuristic in test blocks and fixture paths
- Redacts the matched secret in the violation message

## Assertion Discipline

- Cycle detection visits a node reached by multiple import paths only once
- Snapshot diff merges two sorted inputs into their exact set difference
- Deterministic mutant sampling never selects an out-of-range candidate

## Assert Doc Consistency

- Flags a fn whose doc claims an assertion but whose body has none
- Accepts a claiming doc backed by an assert call
- Ignores lowercase or mid-word marker prose
- Reports the fn name and line of a missing assert

## Fatal Exit

- Flags a nonzero std.process.exit outside the entry file
- Allows std.process.exit(0)
- Exempts a file that defines pub fn main

## Stdout Flush

- Flags a buffered stdout writer with no flush
- Allows a buffered stdout writer that flushes before returning
- Ignores a stdout write that never buffers
- Hard-blocks a missing flush when the enabled toggle is on
- Stays report-only for a missing flush when the toggle is off

## Fuzzing

- Fuzzing the guardian.toml parser never panics and every reject populates its diagnostic
- Fuzzing the wildcard matcher never crashes and a star-free pattern matches iff equal
- Fuzzing the inline-test scope tracker never crashes and holds its depth invariant

## Fuzz Presence

- Passes each configured module that contains a std.testing.fuzz call
- Flags a configured module whose source has no fuzz call
- Hard-fails a configured module that is missing or unreadable
## Module Doc Header

- Flags a module over the line threshold with no module doc header
- Accepts an over-threshold module opening with a multi-line module doc
- Accepts a single module-doc line meeting the character minimum
- Rejects an over-threshold module whose lone header line is too short
- Exempts a module at or below the line threshold
- Skips a file matching a configured allow path
- Flags a module over a lowered min_lines threshold
