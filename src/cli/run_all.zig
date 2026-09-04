//! The `all` command — the whole-suite runner. Loads config, honors the skip-
//! cache and `--only`/`--skip` filters, builds the shared AST index once when
//! any to-run check needs it, invokes each check, and aggregates pass/fail plus
//! the machine-readable JSONL sinks. A filtered run never writes the green
//! skip-cache stamp (it isn't the full suite).

const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");
const baseline = @import("../baseline.zig");
const ast_index = @import("../ast/index.zig");
const cache = @import("../cache.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const sink = @import("../sink.zig");
const dora = @import("../dora.zig");
const check_roi = @import("../check_roi.zig");
const config = @import("../config.zig");
const metadata_transaction = @import("../metadata_transaction.zig");
const scope = @import("../scope.zig");
const git = @import("../git.zig");
const ratchet = @import("../ratchet.zig");
const run_view = @import("run_view.zig");
const selfcheck = @import("selfcheck.zig");
const bench = @import("bench.zig");
const measurement = @import("../measurement.zig");
const writer_lock = @import("../writer_lock.zig");
const retired_checks = @import("retired.zig");
const walk = @import("../walk.zig");
const snapshot = @import("../snapshot.zig");
const check_formatting = @import("../checks/formatting.zig");
const build_options = @import("build_options");

const print = std.debug.print;
const fail = reporter.fail;

/// Format for a run-level line the caller has already rendered to text:
/// `guardian: ` (passed as the first argument) followed by the line. Used by
/// every always-visible run-level line — the verdict, a collapsed check, the
/// measurement reminder — so they share one spelling of the status prefix.
const prefixed_line = "{s}{s}\n";
const pub_api_check = "pub-api-surface";
const sink_drop_warning = "guardian: dropped a sink record: {s}";
const measurement_drop_warning = "guardian: dropped a measurement note: {s}";

pub const command_name = "all";
// spec-init is a generator; mutate rebuilds and re-tests the project per
// mutant; debt is a non-gating report;
// nightly composes `all` + `mutate --full`; commit gates then auto-commits.
// None is a build gate. (nightly and commit are dispatched specially and never
// appear in the registry, so their entries here are defensive — mirroring the
// long-standing `all` exclusion in build_helper — and guarantee they can never
// be run as a check.)
const non_gate_commands = [_][]const u8{ "spec-init", "mutate", "debt", "nightly", "commit" };

/// Runs every registered gate in this process (in parallel across
/// worker threads by default; see `runChecks`). Continues past failures so the
/// user sees every failing check at once; returns error.CheckFailed if any
/// check failed. Output is replayed in registry order, so a parallel run is
/// byte-for-byte deterministic.
///
/// When `cfg.baseline.enabled = true`, each check is run with output
/// captured: the first run records current violations into
/// `.guardian/baselines/<check>.txt` and reports success; subsequent
/// runs only fail when new violations appear above the baseline.
///
/// Skips `spec-init` (a generator, not a gate). The `all` command itself
/// is dispatched outside the registry, so it never recurses.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    return runCollecting(ctx, null);
}

/// What one pass found, for a caller that REPORTS on the pass instead of
/// letting it print — `accept --quiet`, whose whole output is the accepted
/// check's before/after counts. Filled from the same records the JSONL sink
/// stores, so the summary and `last-run.jsonl` can never disagree.
pub const PassSummary = struct {
    /// Blocking violation records this pass collected.
    findings: usize = 0,
    /// Checks that failed (blocking), 0 on a green pass.
    failed: u32 = 0,
};

/// Mutable facts accumulated across every exit path of one `all` invocation.
/// The defer at the top of `runCollecting` writes it even when validation,
/// source preparation, or a check ends in an environmental error.
const RoiState = struct {
    enabled: bool,
    commit: ?[]const u8 = null,
    scope_mode: check_roi.ScopeMode = .full,
    scope_files: u32 = 0,
    cached: bool = false,
    outcome: check_roi.RunOutcome = .@"error",
    check_phase_ms: u64 = 0,
    checks: []const check_roi.CheckRecord = &.{},
};

fn recordRoiInvocation(ctx: *types.RunCtx, stopwatch: *dora.Stopwatch, state: RoiState) void {
    if (!state.enabled) return;
    check_roi.recordRun(ctx.allocator, ctx.project_dir, .{
        .identity = .{
            .timestamp_ms = dora.unixMs(),
            .commit = state.commit,
            .guardian_digest = build_options.source_digest,
        },
        .context = .{
            .origin = ctx.roi_origin,
            .phase = ctx.roi_phase,
            .scope_mode = state.scope_mode,
            .scope_files = state.scope_files,
            .cached = state.cached,
        },
        .outcome = state.outcome,
        .timing = .{
            .duration_ms = stopwatch.elapsedMs(),
            .check_phase_ms = state.check_phase_ms,
        },
        .checks = state.checks,
    });
}

/// `run`, additionally reporting the pass's outcome through `out`. Every exit
/// path that ran checks fills it; a cache-skipped pass leaves it untouched
/// (a filtered pass — the only kind that asks — never skips).
pub fn runCollecting(ctx: *types.RunCtx, out: ?*PassSummary) types.RunError!void {
    // ROI starts before validation/cache/source preparation so its total is the
    // gate cost through verdict generation, not merely the parallel check
    // phase. The deferred JSON append itself happens after that sample. It is
    // local, best-effort, and shares `[dora] enabled` as the metrics opt-out
    // while retaining its own stream and semantics.
    var roi_stopwatch = dora.startStopwatch();
    var roi_state: RoiState = .{ .enabled = ctx.cfg.dora.enabled };
    if (roi_state.enabled) roi_state.commit = git.headHash(ctx.allocator, ctx.project_dir);
    const filtered = isFiltered(ctx);
    if (filtered) roi_state.scope_mode = .filtered;
    ctx.roi_commit = roi_state.commit;
    defer recordRoiInvocation(ctx, &roi_stopwatch, roi_state);

    // Validate the disabled list up front: a typo like "magic-numbers" would
    // otherwise silently disable nothing while the user believes it's off.
    try validateDisabled(ctx.cfg.disabled);
    // Validate --only / --skip the same way: an unknown or non-gate name must
    // hard-fail rather than silently narrow the run to nothing.
    try validateFilter(ctx);
    // Validate GUARDIAN_UPDATE_SNAPSHOT targets + [baseline] deny_growth names,
    // so a typo can't silently refresh nothing / guard nothing.
    try validateSelectiveConfig(ctx);

    // 4.2: `accept` is the one documented acceptance path. When the legacy
    // GUARDIAN_UPDATE_SNAPSHOT env var drives a named refresh, surface the
    // equivalent `accept` invocation so both baseline- and snapshot-class checks
    // converge on the single mechanism (the env var stays a thin alias).
    if (snapshot_helper.refreshTargetSummary(ctx.allocator)) |names|
        reporter.ok("note: GUARDIAN_UPDATE_SNAPSHOT={s} is an alias for `guardian-check accept {s} .`", .{ names, names });

    // The benchmark ledger is report-only and prints BEFORE the skip-cache
    // early return, so the measurements an agent already paid for are on screen
    // for every gate run — including a cache-skipped one. It can never fail the
    // run (see cli/bench.zig); only OOM propagates.
    try bench.report(ctx);

    // A filtered run (--only/--skip) is a subset, not the full suite, so it
    // must neither trust nor write the green skip-cache — recording green from
    // a partial run would mask a failure in the checks it didn't run.
    if (!filtered and shouldSkipRun(ctx)) {
        // The skip path prints its verdict on the always-visible channel like
        // every other path. It used to go through `ok`, which the build wiring's
        // `--quiet` suppresses — so a cached run emitted no guardian output at
        // all and was indistinguishable from a mistyped grep.
        printVerdict(ctx, .{ .cached = true });
        roi_state.cached = true;
        roi_state.outcome = .green;
        return;
    }

    // Stale-binary warning BEFORE any violation listing: a standalone binary a
    // build or two old reports snapshot/ratchet drift a fresh dep-built gate
    // does not (the phantom-red trap). Printing it up front turns a confusing
    // red into a one-line "rebuild first". Best-effort; a green run's stamp then
    // records this binary so it doesn't repeat.
    warnStaleBinary(ctx);

    // A transaction is only needed when this run can WRITE `.guardian/`: a
    // metadata-writable command (accept/migrate) or a pending
    // GUARDIAN_UPDATE_SNAPSHOT refresh. An ordinary run is read-only on metadata
    // — the baseline/ratchet/snapshot lifecycles defer every write — so it needs
    // no begin+restore dance at all (the biggest-evidence-base churn source is
    // simply gone for the common path).
    const writes = writesMetadata(ctx);
    var lock: ?writer_lock.Lock = null;
    if (writes and !ctx.writer_lock_held) {
        lock = writer_lock.acquire(ctx.allocator, ctx.project_dir) catch |err| {
            reportWriterLockFailure(ctx.project_dir, err);
            return error.CheckFailed;
        };
    }
    defer if (lock) |*held| held.deinit();
    var metadata: ?metadata_transaction.Transaction = null;
    if (writes) {
        metadata = metadata_transaction.Transaction.begin(ctx.allocator, ctx.project_dir) catch |err| {
            fail("cannot start Guardian metadata transaction: {s}", .{@errorName(err)});
            return error.CheckFailed;
        };
        // C2: a selectively-named refresh (GUARDIAN_UPDATE_SNAPSHOT=<check>) keeps
        // its freshly-written metadata even when a DIFFERENT check reds the gate —
        // the transaction restores everything EXCEPT the named checks' files.
        if (metadata) |*m| m.preserveMetadata(snapshot_helper.preservedMetadataPathsForCtx(ctx) catch &.{});
    }
    defer if (metadata) |*m| m.deinit();
    var metadata_active = writes;
    defer if (metadata_active) {
        if (metadata) |*m| m.rollback() catch |err|
            fail("could not roll back Guardian metadata after an interrupted run: {s}", .{@errorName(err)});
    };

    // Resolve the diff scope and build the shared parsed-source index. Both
    // storages are stack-scoped here; the ctx pointers are cleared on return so
    // a caller that reuses ctx afterward (nightly → mutate) can't dereference a
    // dangling index. Workers copy ctx before this fires, so the current run is
    // unaffected.
    var index_storage: ast_index.Index = undefined;
    var scoped_storage: ast_index.Index = undefined;
    defer ctx.source_index = null;
    defer ctx.scoped = null;
    defer ctx.renames = null;
    try prepareSources(ctx, &index_storage, &scoped_storage, writes);
    try prepareRenames(ctx);
    if (!filtered and ctx.scoped != null) roi_state.scope_mode = .diff;
    roi_state.scope_files = sourceFileCount(ctx);
    // Cold-cache marker: a whole-tree run with no prior green stamp is the
    // "first gate" whose verdict an agent should not treat as cache-confirmed
    // (baseline mode records-then-enforces, and a cold tool cache is where a
    // stale compile hides). Naming it once lets the agent decide whether a
    // second run is worth its cost instead of rediscovering the ritual by
    // trial. A diff-scoped or filtered run never stamps green and is cold by
    // construction, so the marker would be permanent noise there.
    announceColdCache(ctx);

    // Time the run for the DORA sink. Started here (after the cache-skip guard)
    // so a cache-skipped run — which returns above — records nothing.
    var stopwatch = dora.startStopwatch();
    var check_stopwatch = dora.startStopwatch();
    var ran: u32 = 0;
    var acc: Sink = .{};
    const tally = runChecks(ctx, &ran, &acc) catch |err| {
        roi_state.check_phase_ms = check_stopwatch.elapsedMs();
        roi_state.checks = acc.roi_checks.items;
        return err;
    };
    roi_state.check_phase_ms = check_stopwatch.elapsedMs();
    roi_state.checks = acc.roi_checks.items;
    const failed = tally.failed;
    roi_state.outcome = if (failed == 0) .green else .red;
    if (out) |o| o.* = .{ .findings = acc.records.items.len, .failed = failed };

    // A diff-scoped run is partial in exactly the sense a --only/--skip run is:
    // some checks saw only part of the tree. It therefore shares the filtered
    // run's suppressions below (green stamp, delivery record) and is marked
    // partial in the machine-readable log.
    const partial = isPartial(filtered, ctx.scoped != null);

    // Write the machine-readable last-run log on every real run (green or red),
    // before the green/red branch. A skipped run (early return above) leaves the
    // last real run's log in place.
    writeSink(ctx, acc.records.items, ran, failed, partial);
    // Append the DORA delivery-metrics record for this run (non-gating,
    // best-effort; a nightly run records once via this nested `all` pass).
    // Skipped for a partial (--only/--skip or diff-scoped) run: a partial dev
    // iteration is not a delivery event, and its outcome would misrepresent the
    // stream — the same reason a partial run never stamps the green cache.
    if (!partial) recordDora(ctx, &stopwatch, failed, acc.failed_checks.items);

    // Standing reminder: every local run with live [measurement] exemptions
    // says so on one line, green or red, so instrumentation cannot linger in
    // the tree unnoticed between benchmark rounds. Routed through the
    // always-visible detail channel — the build wiring runs `all --quiet`.
    remindMeasurement(ctx, acc.measured.items);

    if (failed == 0) {
        // Separate blocking failures from report-only findings: a demoted check
        // still prints its finding, and a summary that only said "passed" left
        // the reader unsure whether those lines mattered. The scope suffix
        // keeps a diff-scoped green honest about its coverage either way.
        printVerdict(ctx, .{ .ran = ran, .reported = tally.reported });
        metadata_active = false;
        // Stamp the POST-write tree so an unchanged next run can skip. Never for
        // a partial (--only/--skip or diff-scoped) run — a partial suite must
        // not claim the full suite green — and never for a run that DEFERRED a
        // [measurement] finding (see stampsGreen): the commit-time gate skips
        // on a matching digest, so stamping would smuggle the exemption
        // through the boundary. A fully-green report-mode run is identical
        // work to a green blocking run, so it stamps too.
        if (stampsGreen(partial, acc.measured.items.len)) stampGreen(ctx);
        return;
    }

    // Name the failing checks in the summary so an agent fixes the right one
    // (shown even under --quiet, via the always-visible failure channel).
    const names = joinNames(ctx.allocator, acc.failed_checks.items);
    printVerdict(ctx, .{ .ran = ran, .failed = failed, .reported = tally.reported, .names = names });
    // Concise output groups a bounded sample under each failing check. Verbose
    // output already replayed every check in full, so it keeps the historical
    // one-line offender echo instead of duplicating the grouped sample.
    if (verbosityOf(ctx) == .summary)
        printFailureGroups(ctx, &acc)
    else
        echoOffenders(ctx, &acc);

    // A run that found violations restores metadata when a transaction is active
    // (a writable/refresh run) — half-written snapshots/baselines from the
    // failing checks must not persist. An ordinary read-only run wrote nothing,
    // so there is nothing to restore.
    if (metadata) |*m| {
        m.rollback() catch |err| {
            fail("could not roll back Guardian metadata after the failed run: {s}", .{@errorName(err)});
            metadata_active = false;
            return error.CheckFailed;
        };
        metadata_active = false;
        reporter.detail("  metadata: restored pre-run .guardian snapshots and baselines\n", .{});
        // C2: name what the restore deliberately kept, so the operator knows the
        // selective refresh persisted rather than silently reverting.
        if (snapshot_helper.refreshTargetSummaryForCtx(ctx)) |kept|
            reporter.detail("  metadata: kept named refresh(es) despite the red run: {s}\n", .{kept});
    }

    if (!blocks(ctx.gate, ctx.cfg.gate.on_build)) {
        // Report mode: surface what would block a commit, then exit 0 so the dev
        // build still produces a binary. No green stamp — this run wasn't green.
        // Emitted through the always-visible channel: the build wiring runs
        // `all --quiet`, where `ok` is suppressed but this summary must still show.
        fail(
            "{d} check(s) would block commit ({s}) — run guardian-check commit to gate",
            .{ failed, names },
        );
        return;
    }

    // Block mode: fail the build. If the failures look like snapshot/ratchet
    // re-keying and the binary differs from the last green stamp's, hint that a
    // stale binary — not the tree — is the likely cause.
    reporter.detail("{s}", .{stale_artifact_caution});
    binaryDriftHint(ctx, acc.failed_checks.items);
    return error.CheckFailed;
}

fn reportWriterLockFailure(project_dir: []const u8, err: anyerror) void {
    const remedy = switch (err) {
        error.Busy => "another Guardian writer holds the kernel lock; wait for that process to finish (crashes release it automatically)",
        error.FileLocksUnsupported => "this filesystem does not support the advisory lock Guardian requires for safe writes",
        else => "the lock could not be created or inspected",
    };
    fail("cannot acquire {s}/{s}: {s} ({s})", .{ project_dir, writer_lock.leaf, remedy, @errorName(err) });
}

/// Resolves the diff scope, builds the shared parsed-source index when this run
/// needs one, and installs both on `ctx` — then announces the scope.
///
/// Scoping is decided BEFORE the index is built (see scope.zig): every unknown
/// resolves to a whole-tree run, so this can only ever remove work that is
/// provably irrelevant to the diff. The index is built when any check needs it
/// — so the ~17 AST checks share one read+parse per file instead of repeating
/// it — and also whenever the run is scoped, because the narrowed view is a
/// filtered slice of those very entries.
///
/// `index` and `scoped` are caller-owned storage that must outlive every check.
fn prepareSources(
    ctx: *types.RunCtx,
    index: *ast_index.Index,
    scoped: *ast_index.Index,
    writes_metadata: bool,
) types.RunError!void {
    const decision = try scope.resolve(ctx.allocator, ctx.project_dir, ctx.against, .{
        .full = ctx.full,
        .gate = ctx.gate,
        .writes_metadata = writes_metadata,
    });
    if (decision.wholeTree()) |reason| reporter.ok("run-all: whole-tree run — {s}", .{reason});
    const plan: ?scope.Plan = decision.plan();
    if (!anyNeedsAst(ctx) and plan == null) return;
    if (parsesTree(ctx.source_index != null, anyNeedsAst(ctx), plan != null)) {
        index.* = ast_index.buildWithSizeExcludes(
            ctx.allocator,
            ctx.project_dir,
            ctx.cfg.exclude,
            ctx.cfg.file_size_exclude,
        ) catch |err| {
            reportEnvironmentalError(ctx, err, walk.lastErrorPath());
            return error.CheckFailed;
        };
        ctx.source_index = index;
    }
    if (plan) |p| {
        scoped.* = try p.indexSubset(ctx.allocator, index);
        ctx.scoped = .{
            .base = p.base,
            .file_count = scoped.files.len,
            .changed_paths = p.files,
            .index = scoped,
        };
    }
    announceScope(ctx);
}

/// Whether this pass must read and parse the tree itself. It needs an index
/// when any check needs an AST or the run is scoped (the narrowed view is a
/// slice of those entries) — but it parses only when the CALLER has not already
/// installed one. `accept` runs three passes over one unchanged tree (preview,
/// update, verify), and re-parsing it per pass was two thirds of the command's
/// cost on a project where a check costs real seconds. Nothing a pass writes is
/// source, so a shared parse cannot go stale mid-command.
fn parsesTree(caller_supplied: bool, needs_ast: bool, scoped: bool) bool {
    if (caller_supplied) return false;
    return needs_ast or scoped;
}

/// Resolves git's whole-file renames once, for the relocation-aware ratchets
/// (relocation.zig). Done here rather than inside a check because the per-check
/// pass runs in parallel over copied contexts — a lazy memo there would spawn
/// one git per ratchet check, or race. A project whose ratchets are all
/// disabled (Guardian's own default) never shells out at all.
fn prepareRenames(ctx: *types.RunCtx) types.RunError!void {
    if (!anyRatchetBaselined(ctx)) return;
    ctx.renames = try git.renamesAgainst(ctx.allocator, ctx.project_dir, "HEAD");
}

/// True when any threshold check would take the ratchet lifecycle on this run —
/// the only consumer of rename data.
fn anyRatchetBaselined(ctx: *const types.RunCtx) bool {
    for (ratchet.names) |name| {
        if (ctx.cfg.policy.usesBaselineFor(name, ctx.cfg.baseline)) return true;
    }
    return false;
}

/// The one-line banner a diff-scoped run prints before any check runs. Routed
/// through the always-visible detail channel (the build wiring runs `all
/// --quiet`, where `ok` is suppressed) because the whole point is that a reader
/// can never mistake a scoped green for a whole-tree green: it names the base,
/// how much of the tree the per-file checks saw, and how to get the full run.
/// A whole-tree run prints nothing here.
fn announceScope(ctx: *const types.RunCtx) void {
    const s = ctx.scoped orelse return;
    const total = if (ctx.source_index) |idx| idx.files.len else s.file_count;
    reporter.detail(
        reporter.prefix ++ "diff-scoped vs {s}: {d}/{d} source file(s) in scope for the " ++
            "{d} per-file check(s); {d} whole-tree check(s) still read everything. " ++
            "NOT a whole-tree verification — use --full, or `guardian-check commit`.\n",
        .{ s.base, s.file_count, total, countScope(ctx, .per_file), countScope(ctx, .whole_tree) },
    );
}

/// How many checks this run will actually execute with the given scope
/// capability — used by the banner so the split between narrowed and
/// whole-tree work is a measured number, not a claim.
fn countScope(ctx: *const types.RunCtx, want: types.CheckScope) u32 {
    var n: u32 = 0;
    for (registry.all) |cmd| {
        if (excluded(ctx, cmd.name)) continue;
        if (cmd.scope == want) n += 1;
    }
    return n;
}

/// The `" (diff-scoped vs <base>, N file(s))"` tail appended to the run
/// summary, or an empty string on a whole-tree run. Keeps the verdict line
/// itself honest about how much of the tree it covers.
fn scopeSuffix(ctx: *const types.RunCtx) []const u8 {
    const s = ctx.scoped orelse return "";
    return std.fmt.allocPrint(ctx.allocator, " — diff-scoped vs {s}, {d} file(s) in scope", .{
        s.base,
        s.file_count,
    }) catch " — diff-scoped (partial tree)";
}

/// Whether a green run may record the skip-cache stamp. A filtered
/// (`--only`/`--skip`) run may not: a partial suite must not claim the full
/// suite green. Neither may a run that DEFERRED a `[measurement]` finding — its
/// green is conditional on an exemption the next run may not have, and the
/// commit-time gate skips on a matching digest, so stamping would smuggle the
/// exemption straight through the boundary it exists to respect. Not stamping
/// costs one full re-run at commit and keeps the block airtight. (The DORA sink
/// still records the run: an exempted local run IS a real local outcome, and
/// that telemetry gates nothing.)
fn stampsGreen(filtered: bool, deferred_count: usize) bool {
    return !filtered and deferred_count == 0;
}

/// Prints the run-level `[measurement]` standing reminder when any finding was
/// deferred. Best-effort: an OOM while rendering drops the line rather than
/// failing a run whose checks already reported their own MEASURE headers.
fn remindMeasurement(ctx: *types.RunCtx, records: []const reporter.Measured) void {
    const line = measurement.standingReminder(ctx.allocator, records) catch return orelse return;
    reporter.detail(prefixed_line, .{ reporter.prefix, line });
}

/// Pure gate decision: a run BLOCKS (fails the build on any violation) only when
/// the caller forced it (`--gate`, or the always-blocking commit/nightly/accept
/// paths) or `[gate] on_build = "block"`. Default report mode surfaces findings
/// but exits 0, so a dev build always produces a binary.
fn blocks(forced: bool, on_build: config.GateMode) bool {
    return forced or on_build == .block;
}

/// Comma-joins the failed-check names for the run summary; "?" when the
/// telemetry list is empty (every failure records its name, so this is only a
/// defensive floor for an OOM-dropped note).
fn joinNames(allocator: std.mem.Allocator, names: []const []const u8) []const u8 {
    if (names.len == 0) return "?";
    return std.mem.join(allocator, ", ", names) catch names[0];
}

/// Prints the run's single `run-all:` verdict line — the same grep-stable
/// opener on the green, failing, and cache-skipped paths. A failing verdict goes
/// through the red failure channel; the others through the always-visible detail
/// channel, because the build wiring runs `all --quiet`, where `ok` is
/// suppressed and a silent green (or a silent cache skip) reads as "no output".
fn printVerdict(ctx: *types.RunCtx, v: run_view.Verdict) void {
    const line = run_view.verdictLine(ctx.allocator, v, scopeSuffix(ctx));
    if (v.failed > 0) return fail("{s}", .{line});
    reporter.detail(prefixed_line, .{ reporter.prefix, line });
}

/// Prints one line per failing check naming its first recorded finding —
/// `<check>: <file>:<line>: <message> (+N more)` — under the run summary. Uses
/// the same records the JSONL sink stores, so the console and `last-run.jsonl`
/// agree. The `(+N more)` tail exists because a check that flagged five things
/// and echoed one read as a checker coverage gap. Routed through the
/// always-visible detail channel (a --quiet build gate must still show it) and
/// silently skipped for a check with no structured record.
fn echoOffenders(ctx: *types.RunCtx, acc: *const Sink) void {
    for (acc.failed_checks.items) |name| {
        const v = firstRecordFor(acc.records.items, name) orelse continue;
        const line = reporter.flatLine(ctx.allocator, v) catch continue;
        const more = run_view.moreSuffix(ctx.allocator, countRecordsFor(acc.records.items, name));
        // A scraped baseline detail line already opens with the check name;
        // printing the prefix again would just read as a stutter.
        if (std.mem.startsWith(u8, line, name))
            reporter.detail("  {s}{s}\n", .{ line, more })
        else
            reporter.detail("  {s}: {s}{s}\n", .{ name, line, more });
    }
}

/// Maximum findings printed inside one concise failure group. The full set is
/// retained in last-run.jsonl and returns under `--verbose`.
const failure_sample_limit: usize = 3;

fn sampleLimitFor(check_name: []const u8, total: usize) usize {
    // pub-api-surface has one remedy — review the complete snapshot delta, then
    // accept it. Hiding additions behind a generic truncation makes the only
    // safe action impossible from the default output.
    return if (std.mem.eql(u8, check_name, pub_api_check)) total else failure_sample_limit;
}

/// Heading for one concise failure group.
fn failureGroupLine(arena: std.mem.Allocator, check: []const u8, findings: usize) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s} ({d} finding{s})", .{
        check,
        findings,
        if (findings == 1) "" else "s",
    });
}

/// Tail following the sampled findings in a concise failure group.
fn omittedLine(arena: std.mem.Allocator, total: usize, shown: usize) std.mem.Allocator.Error!?[]const u8 {
    if (shown >= total) return null;
    return try std.fmt.allocPrint(arena, "+{d} more — use --verbose for full detail", .{total - shown});
}

/// Prints blocking failures as compact per-check groups. At most three findings
/// from each check are shown except pub-api-surface, whose accept-only workflow
/// requires the full review delta. The machine-readable sink retains every row.
fn printFailureGroups(ctx: *types.RunCtx, acc: *const Sink) void {
    reporter.detail(
        reporter.prefix ++ "failures grouped by check ({d}):\n",
        .{acc.failed_checks.items.len},
    );
    for (acc.failed_checks.items) |name| {
        const total = countRecordsFor(acc.records.items, name);
        const heading = failureGroupLine(ctx.allocator, name, total) catch name;
        reporter.detail("  {s}\n", .{heading});
        var shown: usize = 0;
        const sample_limit = sampleLimitFor(name, total);
        var last_hint: []const u8 = "";
        for (acc.records.items) |v| {
            if (!std.mem.eql(u8, v.check, name)) continue;
            if (shown == sample_limit) break;
            const line = reporter.flatLine(ctx.allocator, v) catch continue;
            reporter.detail("    - {s}\n", .{line});
            // Each sampled finding carries its own remedy when it has one —
            // formatting's `zig fmt <file>` differs per file, a ban rule names
            // its own subject — deduped so a check whose findings share one
            // remedy (a ratchet's accept command) still prints it once.
            if (v.fix_hint) |hint| {
                if (!std.mem.eql(u8, hint, last_hint)) reporter.detail("      fix: {s}\n", .{hint});
                last_hint = hint;
            }
            shown += 1;
        }
        if (total == 0) {
            reporter.detail("    - no structured detail; use --verbose for the captured check output\n", .{});
        } else if (omittedLine(ctx.allocator, total, shown) catch null) |line| {
            reporter.detail("    - {s}\n", .{line});
        }
        // Fall back to the first finding's remedy when none of the sampled
        // findings carried their own hint (concise mode hides the check's own
        // output, so a hintless group would otherwise say what broke and never
        // what to do about it).
        if (last_hint.len == 0) printGroupHint(acc.records.items, name);
    }
}

/// Fallback remedy for a failure group whose sampled findings carried no hint
/// of their own: the first finding's `fix_hint` (a prose check's trailing
/// `fix:` line, a ratchet regression's ceiling + accept command). Silent when
/// the check supplied no hint (better an absent line than filler).
fn printGroupHint(records: []const reporter.Violation, name: []const u8) void {
    const v = firstRecordFor(records, name) orelse return;
    const hint = v.fix_hint orelse return;
    reporter.detail("    fix: {s}\n", .{hint});
}

// spec: Run Summary - Prints one remedy line under a concise failure group

test "a concise failure group ends in its first finding's fix hint" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const records = [_]reporter.Violation{
        .{ .check = "catch-discipline", .file = "src/x.zig", .line = 16, .message = "catch block is empty", .fix_hint = "handle the error explicitly with a switch or named return" },
        .{ .check = "spec", .message = "unverified: Auth - Validates tokens" },
    };
    // Concise mode hides the check's own output, so the group repeats its remedy.
    printGroupHint(&records, "catch-discipline");
    try std.testing.expectEqualStrings(
        "    fix: handle the error explicitly with a switch or named return\n",
        cap.buf.items,
    );

    // A check with no hint prints no line at all rather than an empty one.
    cap.buf.clearRetainingCapacity();
    printGroupHint(&records, "spec");
    try std.testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

// spec: Run Summary - Prints each sampled finding's own remedy, deduping repeats

test "a concise failure group prints per-finding hints and dedupes repeats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };

    // Two findings with DIFFERENT per-file remedies: each sampled finding must
    // carry its own `fix:` — the first finding's alone would leave the second
    // file's command to be guessed.
    var acc: Sink = .{};
    defer acc.records.deinit(a);
    defer acc.failed_checks.deinit(a);
    try acc.records.append(a, .{ .check = "formatting", .file = "src/a.zig", .line = 1, .message = "non-conforming", .fix_hint = "zig fmt src/a.zig" });
    try acc.records.append(a, .{ .check = "formatting", .file = "src/b.zig", .line = 2, .message = "non-conforming", .fix_hint = "zig fmt src/b.zig" });
    try acc.failed_checks.append(a, "formatting");
    printFailureGroups(&ctx, &acc);
    const out = cap.buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "fix: zig fmt src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fix: zig fmt src/b.zig") != null);

    // A check whose findings SHARE one remedy prints it once, not once per
    // finding — a ratchet regression names one accept command for the group.
    cap.buf.clearRetainingCapacity();
    var acc2: Sink = .{};
    defer acc2.records.deinit(a);
    defer acc2.failed_checks.deinit(a);
    const shared = "reduce it, or `guardian-check accept file-size .`";
    try acc2.records.append(a, .{ .check = "file-size", .file = "src/x.zig", .message = "m", .fix_hint = shared });
    try acc2.records.append(a, .{ .check = "file-size", .file = "src/y.zig", .message = "m", .fix_hint = shared });
    try acc2.failed_checks.append(a, "file-size");
    printFailureGroups(&ctx, &acc2);
    const out2 = cap.buf.items;
    var remaining: []const u8 = out2;
    var hits: usize = 0;
    while (std.mem.indexOf(u8, remaining, "fix: reduce it, or")) |i| {
        hits += 1;
        remaining = remaining[i + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
}

// spec: Run Summary - Groups blocking failures by check with a bounded sample

test "failure groups name counts and bound their visible sample" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("spec (1 finding)", try failureGroupLine(a, "spec", 1));
    try std.testing.expectEqualStrings("pub-api-surface (5 findings)", try failureGroupLine(a, "pub-api-surface", 5));
    try std.testing.expect((try omittedLine(a, 3, 3)) == null);
    try std.testing.expectEqualStrings(
        "+7 more — use --verbose for full detail",
        (try omittedLine(a, 10, failure_sample_limit)).?,
    );
    try std.testing.expectEqual(@as(usize, 12), sampleLimitFor("pub-api-surface", 12));
    try std.testing.expectEqual(failure_sample_limit, sampleLimitFor("spec", 12));
}

test "environmental error renderer names the path and remedy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cap: reporter.Capture = .{ .allocator = arena.allocator() };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    const cfg: config.Config = .{};
    const ctx: types.RunCtx = .{ .allocator = arena.allocator(), .project_dir = ".", .cfg = &cfg, .quiet = true };
    reportEnvironmentalError(&ctx, error.FileTooBig, "src/generated.zig");
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "src/generated.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "file_size_exclude") != null);
}

/// How many findings `check` recorded this run — the number behind the echoed
/// finding's `(+N more)` tail.
fn countRecordsFor(records: []const reporter.Violation, check: []const u8) usize {
    var n: usize = 0;
    for (records) |v| {
        if (std.mem.eql(u8, v.check, check)) n += 1;
    }
    return n;
}

/// The first recorded finding belonging to `check`, or null when the check
/// reported no line-level detail (a snapshot summary, an I/O failure).
fn firstRecordFor(records: []const reporter.Violation, check: []const u8) ?reporter.Violation {
    for (records) |v| if (std.mem.eql(u8, v.check, check)) return v;
    return null;
}

/// Checks whose baselines/snapshots re-key when the guardian binary itself
/// changes: a stale zig-out binary reds exactly these against an unchanged tree
/// (the ~180-false-positive stale-binary trap). Ordinary content checks aren't
/// listed, so an unrelated failure never triggers the hint.
const identity_sensitive_checks = [_][]const u8{
    pub_api_check,     "panic-budget",  "int-from-float-budget",  "unsafe-ops-budget",
    "function-length", "nesting-depth", "cognitive-complexity",   "function-size",
    "type-size",       "file-size",     "bool-ops-per-condition", "line-length",
};

/// True when at least one failed check is snapshot/ratchet-based — the shape of
/// failure a stale guardian binary produces against an unchanged tree.
fn failuresLookLikeRekey(failed_checks: []const []const u8) bool {
    for (failed_checks) |name|
        for (identity_sensitive_checks) |s|
            if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Pure hint decision: warn about a stale binary only when the failures look
/// like re-keying AND the running binary differs from the last green stamp's.
fn binaryDriftHintApplies(rekey_failures: bool, binary_drifted: bool) bool {
    return rekey_failures and binary_drifted;
}

/// Prints the stale-binary rebuild hint when a blocking failure's shape matches
/// snapshot/ratchet re-keying and the running guardian build differs from the
/// last green stamp's. Best-effort: any missing stamp or I/O failure skips it.
fn binaryDriftHint(ctx: *types.RunCtx, failed_checks: []const []const u8) void {
    if (!failuresLookLikeRekey(failed_checks)) return;
    const stamped = cache.readStampedBinary(ctx.allocator, ctx.project_dir) catch return;
    const running = selfcheck.runningIdentity(ctx.allocator) catch return;
    if (!binaryDriftHintApplies(true, cache.binaryDrifted(stamped, running))) return;
    reporter.detail(
        "  hint: guardian-check binary differs from the last green run — {s}\n",
        .{run_view.binaryAgeNote(binaryAgeVsStamp(ctx, stamped))},
    );
}

/// Which side of a guardian-build mismatch is newer: the binary running now, or
/// the one that stamped this tree green.
///
/// The comparison is binary-mtime against binary-mtime. The stamp FILE's mtime
/// is only a fallback for a stamp written before the gating binary's own mtime
/// was recorded, because that file is dated when the gate ran, not when its
/// binary was built — so a binary built after the stamping one, but before that
/// run, was told it was "OLDER than the one that last gated the tree".
fn binaryAgeVsStamp(ctx: *types.RunCtx, stamped: cache.StampedBinary) run_view.BinaryAge {
    return run_view.binaryAge(
        cache.currentBinaryMtime(ctx.allocator),
        stamped.mtime orelse cache.stampMtime(ctx.project_dir),
    );
}

/// True when this run may WRITE `.guardian/` metadata and therefore needs the
/// restore-on-red transaction: a metadata-writable command (accept/migrate) or
/// a pending GUARDIAN_UPDATE_SNAPSHOT refresh (accept-set or env).
/// An ordinary run is read-only on metadata — every lifecycle defers its writes
/// — so it needs no begin+restore transaction.
fn writesMetadata(ctx: *types.RunCtx) bool {
    if (ctx.metadata_writable) return true;
    if (ctx.refresh.len > 0) return true;
    return snapshot_helper.shouldUpdate(ctx.allocator);
}

/// Prints a one-line stale-binary warning when a green stamp records a guardian
/// build that differs from the running one — before any check runs, so a re-key
/// red reads as "rebuild first". The identity compared is the SOURCE digest the
/// binary was built from (`cache.binaryDrifted`), so a binary that would pass
/// `selfcheck` against the stamped source can never be accused: six eda
/// worktrees, each freshly gated behind a passing selfcheck, were all told
/// their binary was older than the one that had just gated the same tree.
/// Best-effort: a missing stamp or any I/O error skips it silently.
fn warnStaleBinary(ctx: *types.RunCtx) void {
    const stamped = cache.readStampedBinary(ctx.allocator, ctx.project_dir) catch return;
    const running = selfcheck.runningIdentity(ctx.allocator) catch return;
    if (!cache.binaryDrifted(stamped, running)) return;
    reporter.detail(
        reporter.prefix ++ "warning: this guardian-check binary is a different build from the one that " ++
            "last gated this tree — {s}; snapshot/ratchet drift below may come from that, not the tree\n",
        .{run_view.binaryAgeNote(binaryAgeVsStamp(ctx, stamped))},
    );
}

/// Pure decision for the cold-cache marker: a run is "cold" (the first gate on
/// this tree) exactly when no prior green stamp was recorded.
fn coldGate(stored: ?cache.Digest) bool {
    return stored == null;
}

/// Prints a one-line cold-cache note when this whole-tree run has never been
/// stamped green — the first gate, where a false green (a stale tool/test
/// cache, or baseline mode's record-then-enforce first pass) is most likely. A
/// re-run after a green populates the skip-cache, and its `cached` verdict is
/// the confirmation; an agent can then skip the "run twice" ritual on every
/// other gate. Routed through the always-visible detail channel (the build
/// wiring runs `all --quiet`). Best-effort: an unreadable stamp prints nothing.
fn announceColdCache(ctx: *types.RunCtx) void {
    // Only a whole-tree, unfiltered run may stamp green, so only it has a
    // meaningful "first gate"; a diff-scoped or filtered run is cold by
    // construction and the marker would fire on every dev build.
    if (ctx.scoped != null or isFiltered(ctx)) return;
    const stored = cache.readStored(ctx.allocator, ctx.project_dir) catch return;
    if (!coldGate(stored)) return;
    reporter.detail(
        reporter.prefix ++ "cold gate — no prior green stamp on this tree; " ++
            "a re-run after a green will skip via the cache and confirm\n",
        .{},
    );
}

/// Printed under every run-all failure. With install gating (the build-helper
/// default) a red gate withholds artifact installs — and `zig build test`
/// never installs — so whatever sits in zig-out predates this failure. The
/// one-liner exists because a stale last-green binary otherwise LOOKS current
/// and gets "verified" against changes it does not contain.
const stale_artifact_caution =
    "  caution: zig-out binaries predate this failed run " ++
    "(installs are gated on green) — rebuild green before running them\n";

/// Collects every check's findings across the run for the JSONL sink. Owned by
/// the run allocator so records outlive the per-worker arenas that produced them.
/// `failed_checks` is the distinct registry names that failed, for the DORA
/// telemetry record (names are static registry literals — no copy needed).
const Sink = struct {
    records: std.ArrayList(reporter.Violation) = .empty,
    failed_checks: std.ArrayList([]const u8) = .empty,
    /// Per-check timing/outcome/observation facts for the ROI stream. Entries
    /// are in registry order, matching the deterministic terminal replay.
    roi_checks: std.ArrayList(check_roi.CheckRecord) = .empty,
    /// Findings deferred by a live `[measurement]` exemption, gathered across
    /// checks so the run prints ONE standing reminder naming every exempted
    /// path and its live counts.
    measured: std.ArrayList(reporter.Measured) = .empty,
};

/// A run's outcome counts, split by what they mean for the build: `failed` is
/// blocking, `reported` is a policy-demoted finding that never blocks. Keeping
/// them apart is what lets the summary say "0 blocking, 8 report-only".
const Tally = struct {
    failed: u32 = 0,
    reported: u32 = 0,
};

/// Writes the machine-readable last-run log for a real (non-skipped) run.
/// `skipped` is the registry entries that didn't execute this pass (built-in
/// non-gates, disabled, and filtered-out checks). Best-effort (never fails the
/// build) and always written — a green run yields a summary-only log.
fn writeSink(ctx: *types.RunCtx, records: []const reporter.Violation, ran: u32, failed: u32, filtered: bool) void {
    const total_checks: u32 = @intCast(registry.all.len);
    sink.write(ctx.allocator, ctx.project_dir, records, .{
        .passed = ran - failed,
        .failed = failed,
        .skipped = total_checks - ran,
        .filtered = filtered,
    });
}

/// Appends the DORA delivery-metrics record for a real (non-skipped) run:
/// outcome, the failed-check names, and wall-clock duration. Non-gating and
/// best-effort — `dora.recordRun` swallows a disabled sink or an I/O failure.
fn recordDora(ctx: *types.RunCtx, stopwatch: *dora.Stopwatch, failed: u32, failed_checks: []const []const u8) void {
    const outcome: dora.Outcome = if (failed == 0) .green else .red;
    dora.recordRun(ctx.allocator, ctx.project_dir, ctx.cfg.dora, outcome, failed_checks, stopwatch.elapsedMs());
}

/// True when an --only / --skip selection is active for this run.
fn isFiltered(ctx: *const types.RunCtx) bool {
    return ctx.only.len > 0 or ctx.skip.len > 0;
}

/// True when `name` is a check that `all` actually runs: a registered command
/// that isn't a built-in non-gate (spec-init / mutate / nightly). Used to
/// validate --only / --skip names before running.
pub fn isAllCheck(name: []const u8) bool {
    if (registry.find(name) == null) return false;
    for (non_gate_commands) |s| if (std.mem.eql(u8, name, s)) return false;
    return true;
}

/// Fails the run when --only or --skip names a check that `all` does not run
/// (unknown, or a non-gate like `mutate`). Mirrors validateDisabled so a typo
/// can't silently narrow the suite to nothing.
fn validateFilter(ctx: *const types.RunCtx) types.RunError!void {
    for (ctx.only) |name| try requireAllCheck(name, "--only");
    for (ctx.skip) |name| try requireAllCheck(name, "--skip");
}

fn requireAllCheck(name: []const u8, flag: []const u8) types.RunError!void {
    if (isAllCheck(name)) return;
    fail("unknown check name in {s}: {s}", .{ flag, name });
    fail("  run `guardian-check explain` to list valid check names", .{});
    return error.CheckFailed;
}

/// Validates a caller-supplied list of runnable gate names. Used by `accept`
/// as well as the `all` filters so typos can never refresh or skip silently.
pub fn validateCheckNames(names: []const []const u8, origin: []const u8) types.RunError!void {
    for (names) |name| try requireAllCheck(name, origin);
}

fn validatePolicy(ctx: *const types.RunCtx) types.RunError!void {
    for (ctx.cfg.policy.block) |name| try requireKnownCheck(name, "[policy] block");
    for (ctx.cfg.policy.ratchet) |name| try requireKnownCheck(name, "[policy] ratchet");
    for (ctx.cfg.policy.report) |name| try requireKnownCheck(name, "[policy] report");
}

/// A check removed by a merge/fold. Its name is still tolerated in `disabled`
/// (and silently ignored) so a consumer's guardian.toml — and any leftover
/// baseline/snapshot file — doesn't break the build when a check is folded into
/// another. `[[allow]]` entries for a retired name are already inert (nothing
/// looks them up). Guardian emits a one-line migration notice instead.
/// Fails the run when the `disabled` config names a check that doesn't exist,
/// except for retired names (folded into another check), which are tolerated
/// with a migration notice so folds don't break downstream config.
fn validateDisabled(disabled: []const []const u8) types.RunError!void {
    for (disabled) |name| {
        if (registry.find(name) != null) continue;
        if (retired_checks.find(name)) |r| {
            reporter.ok("note: '{s}' is retired (folded into {s})", .{ r.name, r.folded_into });
            continue;
        }
        fail("unknown check name in `disabled`: {s}", .{name});
        return error.CheckFailed;
    }
}

/// Validates GUARDIAN_UPDATE_SNAPSHOT named targets and [baseline] deny_growth
/// names against the registry, hard-failing on a typo (mirrors validateDisabled
/// / validateFilter). Exported so single-check dispatch validates them too.
pub fn validateSelectiveConfig(ctx: *const types.RunCtx) types.RunError!void {
    try validateRefreshTargets(ctx.allocator);
    try validateCheckNames(ctx.refresh, "accept refresh");
    try validateDenyGrowth(ctx.cfg.baseline.deny_growth);
    try validatePolicy(ctx);
}

/// Rejects a GUARDIAN_UPDATE_SNAPSHOT check-name list with an unknown name —
/// a typo must hard-fail, not silently refresh nothing. No-op in the none/all
/// modes (refreshTargets returns null).
fn validateRefreshTargets(allocator: std.mem.Allocator) types.RunError!void {
    if (snapshot_helper.usesLegacyBroadToken(allocator)) {
        fail("{s}=1/true is no longer accepted for a broad refresh", .{snapshot_helper.update_env});
        fail(
            "  use {s}=all for everything, or name only the intended checks — e.g. {s}",
            .{ snapshot_helper.update_env, snapshot_helper.example_named_refresh },
        );
        return error.CheckFailed;
    }
    const names = snapshot_helper.refreshTargets(allocator) orelse return;
    for (names) |name| try requireKnownCheck(name, snapshot_helper.update_env);
}

/// Rejects a [baseline] deny_growth list with an unknown check name.
fn validateDenyGrowth(names: []const []const u8) types.RunError!void {
    for (names) |name| try requireKnownCheck(name, "[baseline] deny_growth");
}

/// Fails the run when `name` is neither a registered check nor a tolerated
/// retired (folded) name; `origin` names the setting for the diagnostic.
fn requireKnownCheck(name: []const u8, origin: []const u8) types.RunError!void {
    if (registry.find(name) != null) return;
    if (retired_checks.find(name)) |r| {
        reporter.ok("note: '{s}' is retired (folded into {s})", .{ r.name, r.folded_into });
        return;
    }
    fail("unknown check name in {s}: {s}", .{ origin, name });
    fail("  run `guardian-check explain` to list valid check names", .{});
    return error.CheckFailed;
}

/// Whether an unchanged re-run may skip the whole suite, and — separately —
/// the post-run stamp so a green run records its final input state.
///
/// The stamp is recomputed AFTER checks finish (see `stampGreen`), never reused
/// from the skip check: a green run can rewrite `.guardian/` (auto-pruned
/// baselines, freshly created/refreshed snapshots), so the pre-run digest would
/// describe a tree state that is no longer on disk — storing it would force a
/// spurious re-run next build (and, if that stale state were ever restored,
/// wrongly skip it).
fn shouldSkipRun(ctx: *types.RunCtx) bool {
    // A --full run is a request to actually verify the tree, so it must not be
    // answered by the green cache: "whole-tree run" and "cached verdict" are
    // contradictions. The bypass sits before the digest walk, so the expensive
    // walk isn't paid for a run that cannot skip.
    const enabled = ctx.cfg.cache_enabled and !ctx.full;
    const refresh = ctx.refresh.len > 0 or snapshot_helper.shouldUpdate(ctx.allocator);
    // Only pay for the digest walk when a skip is still possible (cache on, no
    // refresh) — the `and` short-circuits otherwise. A Git-clean tree is NOT a
    // precondition: the digest hashes every file each check reads (see the audit
    // in `skipDecision`), so a content-identical tree is safe to skip whether or
    // not git reports uncommitted edits.
    const digest_matches = enabled and !refresh and digestMatchesStored(ctx);
    return skipDecision(enabled, refresh, digest_matches);
}

/// True when the current input digest equals the last green run's stored digest.
fn digestMatchesStored(ctx: *types.RunCtx) bool {
    const d = cache.inputDigest(
        ctx.allocator,
        ctx.project_dir,
        ctx.cfg.spec_file,
        ctx.cfg.external_gates,
    ) catch return false;
    // Any failure to read the stored digest (OOM or absent) means "can't confirm
    // a match" — run the full suite (fail closed), never skip.
    const stored = (cache.readStored(ctx.allocator, ctx.project_dir) catch return false) orelse return false;
    return cache.eql(stored, d);
}

/// Records the current (post-check) input digest as the last green state, so an
/// unchanged next run can skip. Recomputes the digest now — after checks may
/// have written `.guardian/` — so the stamp always reflects the tree on disk.
/// Best-effort: a disabled cache or a digest/write failure simply skips the
/// stamp (never fails the build).
fn stampGreen(ctx: *types.RunCtx) void {
    if (!ctx.cfg.cache_enabled) return;
    const d = cache.inputDigest(ctx.allocator, ctx.project_dir, ctx.cfg.spec_file, ctx.cfg.external_gates) catch return;
    // Record the running guardian build alongside the digest so a later
    // blocking failure can distinguish a stale-binary re-key from real drift.
    const bin = selfcheck.runningIdentity(ctx.allocator) catch {
        cache.writeStored(ctx.allocator, ctx.project_dir, d);
        return;
    };
    cache.writeGreenStamp(ctx.allocator, ctx.project_dir, d, bin);
}

/// Pure skip decision, factored out for testing: a run skips only when the
/// cache is enabled, no refresh was requested, and the input digest matches the
/// stored green digest. A refresh or a digest mismatch always executes fully.
///
/// There is deliberately no clean-worktree precondition. The input digest
/// (`cache.inputDigest`) hashes every file each registered gate reads —
/// src/ + test/ `.zig`, build.zig(.zon), the SPEC file, guardian.toml,
/// `.guardian/` (excluding cache/), declared `[[external]]` inputs, project
/// `@embedFile` assets — plus the Git HEAD hash and the guardian binary's own
/// identity. So a matching digest means every check's inputs are byte-identical
/// to the last green run. The two git-diff gates (change-classification,
/// policy-drift) diff the working tree against HEAD, but that diff is a pure
/// function of (working-tree content, HEAD) — both digest-covered — never of the
/// git index or staging state, so a "dirty" tree cannot change their verdict
/// while the digest matches. Files git calls dirty but the digest ignores
/// (README, docs, loose JSON) are read by no gate. The clean-tree requirement
/// was therefore redundant, and dropping it lets the extremely common no-change
/// rebuild — the agent edit/build loop, and eda's long-lived `.guardian/`
/// baseline drift — skip instead of paying the full suite every time.
fn skipDecision(cache_enabled: bool, refresh_requested: bool, digest_matches: bool) bool {
    return cache_enabled and !refresh_requested and digest_matches;
}

/// One check's outcome + captured output, filled by the worker that ran it.
/// `records` are the structured Violations the check emitted (empty for an
/// unmigrated check, whose findings are scraped from `output` instead).
const CheckResult = struct {
    ran: bool = false,
    failed: bool = false,
    reported: bool = false,
    /// True when this check's output was already printed (the preflight prints
    /// immediately, before the suite runs), so the end-of-run replay skips it.
    emitted: bool = false,
    /// Advisory (non-blocking) findings. Kept as records, not a bare count, so
    /// the printer can place each one against a diff-scoped run's changed files
    /// and collapse a check whose warnings all miss the diff.
    warnings: []const reporter.Violation = &.{},
    err: ?types.RunError = null,
    err_path: ?[]const u8 = null,
    output: []const u8 = "",
    records: []const reporter.Violation = &.{},
    /// Findings a live `[measurement]` exemption deferred (see measurement.zig).
    /// Never blocking — they only feed the run's standing reminder.
    measured: []const reporter.Measured = &.{},
    /// Wall-clock ms this check took (dora clock seam). A check over the
    /// heartbeat threshold gets a named "slow check" line so a long run reads as
    /// alive, not hung, and the bottleneck is identifiable.
    elapsed_ms: u64 = 0,
};

/// A check at or beyond this wall time gets a heartbeat line naming it — the
/// signal that turns a silent long run into "check X is still the slow one".
const slow_check_ms: u64 = 5000;

/// True when a check's wall time reached the heartbeat threshold.
fn isSlowCheck(elapsed_ms: u64) bool {
    return elapsed_ms >= slow_check_ms;
}

/// Shared handle passed to each worker thread.
const WorkerJob = struct {
    base: *types.RunCtx,
    arena: *std.heap.ArenaAllocator,
    next: *usize,
    results: []CheckResult,
};

/// Runs every non-skipped check into `results` (parallel across worker threads
/// when enabled and multi-core, else sequentially in this thread), then replays
/// captured output in registry order and tallies. Each check's findings are
/// gathered into `acc` for the JSONL sink. Returns the blocking/report-only
/// tally; propagates the first non-CheckFailed error. Output is deterministic
/// (registry order) regardless of the path taken.
fn runChecks(ctx: *types.RunCtx, ran: *u32, acc: *Sink) types.RunError!Tally {
    const results = try ctx.allocator.alloc(CheckResult, registry.all.len);
    for (results) |*r| r.* = .{};
    runPreflight(ctx, results);

    const workers = if (ctx.cfg.parallel) threadCount() else 1;
    if (workers > 1) {
        const arenas = try ctx.allocator.alloc(std.heap.ArenaAllocator, workers);
        // allocator-ok: page_allocator is thread-safe and each worker owns a private arena
        for (arenas) |*ar| ar.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // Deinit runs after emitAndTally (which copies worker-arena records into
        // the run allocator for `acc`), so the sink never reads freed memory.
        defer for (arenas) |*ar| ar.deinit();
        if (try spawnAndJoin(ctx, arenas, results) > 0)
            return emitAndTally(ctx, results, ran, acc);
        // Threads unsupported: fall through to the sequential fill.
    }
    fillSequential(ctx, results);
    return emitAndTally(ctx, results, ran, acc);
}

/// The one gate run ahead of the suite: formatting is the cheapest check by a
/// wide margin (a parse + render per file, no cross-file analysis) and its fix
/// is a single command, so paying the whole run before reporting it was pure
/// waste. Its result is filled in before the fan-out and its output flushed
/// immediately, which is what makes the failure land in the first seconds.
const preflight_name = check_formatting.check_name;

/// Runs the preflight gate in this thread and prints its captured output right
/// away (the rest of the suite replays only at the end). Leaves `results`
/// untouched — so the check simply runs in the pool — when it is filtered out,
/// disabled, or missing from the registry.
fn runPreflight(ctx: *types.RunCtx, results: []CheckResult) void {
    const i = preflightIndex(ctx) orelse return;
    var r = runCaptured(ctx, ctx.allocator, registry.all[i]);
    // Print immediately only when this run would show the check in full — that
    // is the entire point of the preflight (a formatting failure lands in the
    // first seconds instead of after the suite). When the run would collapse or
    // hide it (`--summary`, an out-of-scope advisory), leave `emitted` false so
    // the ordinary replay applies that decision instead.
    if (run_view.renderFor(verbosityOf(ctx), outcomeOf(ctx, r)) == .full) {
        r.emitted = true;
        if (shouldEmit(ctx.quiet, r)) print("{s}", .{r.output});
    }
    results[i] = r;
}

/// Registry index of the preflight check when it runs this pass; null when it
/// is excluded (--only/--skip, `disabled`) or not registered.
fn preflightIndex(ctx: *const types.RunCtx) ?usize {
    for (registry.all, 0..) |cmd, i| {
        if (!std.mem.eql(u8, cmd.name, preflight_name)) continue;
        return if (excluded(ctx, cmd.name)) null else i;
    }
    return null;
}

/// Usable worker count: one per core, capped at the number of checks.
fn threadCount() usize {
    const cpus = std.Thread.getCpuCount() catch return 1;
    return @max(@min(cpus, registry.all.len), 1);
}

/// Sequential fill: run each non-excluded check in this thread with its own
/// capture (over the run allocator), for replay by emitAndTally. Used when
/// parallelism is off, on a single core, or when thread spawn is unsupported.
fn fillSequential(ctx: *types.RunCtx, results: []CheckResult) void {
    for (registry.all, 0..) |cmd, i| {
        if (excluded(ctx, cmd.name)) continue;
        if (results[i].ran) continue; // already done by the preflight
        results[i] = runCaptured(ctx, ctx.allocator, cmd);
    }
}

/// Spawns one worker per arena (fewer if `spawn` is unsupported), each draining
/// the shared atomic work counter, then joins them. Returns the count spawned.
fn spawnAndJoin(ctx: *types.RunCtx, arenas: []std.heap.ArenaAllocator, results: []CheckResult) !usize {
    const a = ctx.allocator;
    const jobs = try a.alloc(WorkerJob, arenas.len);
    const threads = try a.alloc(std.Thread, arenas.len);
    var next: usize = 0;
    var spawned: usize = 0;
    for (arenas, 0..) |*ar, t| {
        jobs[t] = .{ .base = ctx, .arena = ar, .next = &next, .results = results };
        threads[t] = std.Thread.spawn(.{}, worker, .{&jobs[t]}) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |th| th.join();
    return spawned;
}

/// Worker loop: claim check indices atomically until exhausted, running each
/// into this thread's own arena + capture. Skipped checks leave `ran = false`.
fn worker(job: *WorkerJob) void {
    const a = job.arena.allocator();
    // This thread's reporter; per-check output is captured, replayed by main.
    reporter.default = .{ .quiet = job.base.quiet, .use_color = false };
    while (true) {
        const i = @atomicRmw(usize, job.next, .Add, 1, .monotonic);
        if (i >= registry.all.len) break;
        const cmd = registry.all[i];
        if (excluded(job.base, cmd.name)) continue;
        if (job.results[i].ran) continue; // already done by the preflight
        job.results[i] = runCaptured(job.base, a, cmd);
    }
}

/// The parsed-source index one check runs against. On a diff-scoped run a
/// `per_file` check gets the narrowed changed-files view; a `whole_tree` check
/// keeps the full index, because its verdict depends on files the diff never
/// touched (import cycles, cross-file duplicates, coverage maps, tree-wide
/// snapshots) — narrowing it would make it unsound, not merely faster. On a
/// whole-tree run every check gets the same full index, exactly as before.
fn indexFor(ctx: *const types.RunCtx, check_scope: types.CheckScope) ?*const ast_index.Index {
    const s = ctx.scoped orelse return ctx.source_index;
    return if (check_scope == .per_file) s.index else ctx.source_index;
}

/// The scope marker one check runs under. A `whole_tree` check read the entire
/// tree even on a diff-scoped run, so from its own — and its baseline's — point
/// of view the run was not scoped at all, and its metadata may be reconciled
/// normally. A `per_file` check inherits the run's scope, which is what makes
/// its baseline report-or-fail instead of prunable (see baseline.zig).
fn scopedFor(ctx: *const types.RunCtx, check_scope: types.CheckScope) ?types.ScopedRun {
    return if (check_scope == .per_file) ctx.scoped else null;
}

/// True when this run covered only part of the suite or only part of the tree
/// — a `--only`/`--skip` filter, or a diff-scoped pass. A partial run must
/// never stamp the green cache (a later whole-tree run would then skip on it)
/// and is not a delivery event.
fn isPartial(filtered: bool, diff_scoped: bool) bool {
    return filtered or diff_scoped;
}

/// Number of source files represented by this run's parsed view. A diff run
/// reports its narrowed count; a whole-tree/filtered run reports the full
/// shared index. Zero is the honest fallback when no check needed an index.
fn sourceFileCount(ctx: *const types.RunCtx) u32 {
    if (ctx.scoped) |scoped| return std.math.cast(u32, scoped.file_count) orelse std.math.maxInt(u32);
    const index = ctx.source_index orelse return 0;
    return std.math.cast(u32, index.files.len) orelse std.math.maxInt(u32);
}

/// Runs one check into a fresh capture over the worker's allocator, returning
/// its result. A copied RunCtx carries the per-worker allocator so no check
/// allocates through the shared arena.
fn runCaptured(base: *types.RunCtx, a: std.mem.Allocator, cmd: types.Command) CheckResult {
    var cap: reporter.Capture = .{ .allocator = a };
    // Restore rather than clear: a worker thread starts with no capture, but the
    // preflight and the sequential fill run on the MAIN thread, which a caller
    // (accept --quiet) may already be capturing. Clearing dropped that caller's
    // capture for the rest of the run.
    const prior = reporter.default.capture;
    reporter.default.capture = &cap;
    defer reporter.default.capture = prior;

    var wctx = base.*;
    wctx.allocator = a;
    // Diff scoping is applied here and nowhere else (see `indexFor`). The
    // scope marker is narrowed the same way, so a whole-tree check — which
    // really did read everything — and its baseline never see a partial view.
    wctx.source_index = indexFor(base, cmd.scope);
    wctx.scoped = scopedFor(base, cmd.scope);

    var res: CheckResult = .{ .ran = true };
    const mode = base.cfg.policy.modeFor(cmd.name);
    const baseline_on = base.cfg.policy.usesBaselineFor(cmd.name, base.cfg.baseline);
    // A demoted check's own status lines print REPORT, not FAILED — decided
    // here (the runner knows the policy) so no check consults policy itself.
    reporter.default.report_only = mode == .report;
    defer reporter.default.report_only = false;
    // Time each check via the dora clock seam so a slow one can be named.
    var sw = dora.startStopwatch();
    const outcome = if (baseline_on) baseline.runWithBaseline(&wctx, cmd) else cmd.run(&wctx);
    res.elapsed_ms = sw.elapsedMs();
    outcome catch |e| switch (e) {
        error.CheckFailed => if (mode == .report) {
            res.reported = true;
        } else {
            res.failed = true;
        },
        else => {
            res.failed = true;
            res.err = e;
            res.err_path = walk.lastErrorPath() orelse snapshot.lastErrorPath();
        },
    };
    res.output = cap.buf.items;
    res.records = cap.records.items;
    res.warnings = cap.warnings.items;
    res.measured = cap.measured.items;
    return res;
}

/// Replays each ran check's captured output in registry order and tallies
/// pass/fail, gathering findings into `acc` for the JSONL sink. Quiet mode
/// prints only failures. The first non-CheckFailed error (if any) is propagated
/// after all output is shown. Single-threaded (main), so the sink append is
/// race-free even though checks ran in parallel.
fn emitAndTally(ctx: *types.RunCtx, results: []CheckResult, ran: *u32, acc: *Sink) types.RunError!Tally {
    var tally: Tally = .{};
    var first_err: ?types.RunError = null;
    var first_err_path: ?[]const u8 = null;
    for (results, registry.all) |r, cmd| {
        if (!r.ran) continue;
        ran.* += 1;
        if (r.reported) tally.reported += 1;
        if (r.failed) {
            tally.failed += 1;
            // Best-effort: a dropped name only omits one entry from telemetry.
            acc.failed_checks.append(ctx.allocator, cmd.name) catch |e|
                std.log.warn("guardian: dropped a failed-check telemetry note: {s}", .{@errorName(e)});
        }
        if (r.err) |e| {
            if (first_err == null) {
                first_err = e;
                first_err_path = r.err_path;
            }
        }
        const finding_start = acc.records.items.len;
        collectSink(ctx, acc, cmd.name, r);
        collectRoiCheck(ctx, acc, cmd.name, r, acc.records.items[finding_start..]);
        collectMeasured(ctx, acc, r);
    }
    // Blocking detail first, advisory second. Output was already captured per
    // check for deterministic replay, so ordering it costs a second walk of the
    // same in-memory array — no extra buffering, no per-finding allocation.
    emitPass(ctx, results, .blocking);
    emitPass(ctx, results, .advisory);
    if (first_err) |e| {
        reportEnvironmentalError(ctx, e, first_err_path);
        return error.CheckFailed;
    }
    return tally;
}

/// Renders non-policy failures at the process boundary. Every path through here
/// is one located line plus a remedy, never Zig's raw error-return trace.
pub fn reportEnvironmentalError(ctx: *const types.RunCtx, err: anyerror, path_hint: ?[]const u8) void {
    const path = path_hint orelse snapshot.lastErrorPath() orelse walk.lastErrorPath() orelse ctx.project_dir;
    switch (err) {
        error.FileTooBig, error.StreamTooLong => fail(
            "cannot analyze {s}: input exceeds Guardian's read ceiling ({s}) — exclude generated files with `exclude` or `file_size_exclude`",
            .{ path, @errorName(err) },
        ),
        error.BadFormat => fail(
            "corrupt Guardian state {s} (BadFormat) — resolve merge damage or delete it and run the named `guardian-check accept <check> {s}`",
            .{ path, ctx.project_dir },
        ),
        error.VersionMismatch => fail(
            "stale Guardian state format in {s} — run `guardian-check migrate {s}`",
            .{ path, ctx.project_dir },
        ),
        error.ConflictMarkers => fail(
            "unresolved merge markers in Guardian state {s} — resolve the file or run the installed .guardian merge driver",
            .{path},
        ),
        error.GitSpawnFailed, error.GitCommandFailed => fail(
            "git-dependent analysis failed for {s} ({s}) — see the git diagnostic above",
            .{ path, @errorName(err) },
        ),
        else => fail(
            "environmental analysis failure at {s}: {s} — check file permissions, filesystem state, and generated-file exclusions",
            .{ path, @errorName(err) },
        ),
    }
}

/// Which half of the replay is being printed. Blocking output goes first so a
/// reader reaches the thing that fails the build without scrolling through
/// advisory findings; the verdict + echoed offenders then close the log.
const Pass = enum { blocking, advisory };

/// Replays every ran check belonging to `pass`, in registry order.
fn emitPass(ctx: *types.RunCtx, results: []const CheckResult, pass: Pass) void {
    const want_blocking = pass == .blocking;
    for (results, registry.all) |r, cmd| {
        if (!r.ran or r.failed != want_blocking) continue;
        emitCheck(ctx, cmd.name, r);
    }
}

/// Prints one check's captured output at whatever fidelity this run's verbosity
/// and diff scope call for, plus its report-only note and slow-check heartbeat.
/// The preflight (`emitted`) already printed live, so only its heartbeat is due.
fn emitCheck(ctx: *types.RunCtx, name: []const u8, r: CheckResult) void {
    const outcome = outcomeOf(ctx, r);
    const render = run_view.renderFor(verbosityOf(ctx), outcome);
    if (!r.emitted) {
        switch (render) {
            .hidden => {},
            .collapsed => printCollapsed(ctx, name, outcome),
            .full => {
                if (shouldEmit(ctx.quiet, r)) print("{s}", .{r.output});
                if (r.reported) reporter.ok("{s}: report-only finding (policy did not block)", .{name});
            },
        }
        // A collapsed or hidden check has had its output dropped; its alerts
        // must not go with it.
        if (run_view.showsAlerts(render)) printAlerts(ctx, name, r);
    }
    // Heartbeat: a check over the threshold is named with its wall time, so a
    // long run reads as alive and its slowest check is obvious. Routed through
    // the always-visible detail channel so it shows even under --quiet.
    if (isSlowCheck(r.elapsed_ms)) reporter.detail(
        reporter.prefix ++ "heartbeat: {s} took {d}s (slow check)\n",
        .{ name, r.elapsed_ms / std.time.ms_per_s },
    );
}

/// Prints the one-line stand-in for a collapsed check on the always-visible
/// channel: the count is the whole point, so `--quiet` must not eat it.
/// Best-effort — an allocation failure drops the line, never the run.
fn printCollapsed(ctx: *types.RunCtx, name: []const u8, outcome: run_view.Outcome) void {
    const line = run_view.collapseLine(ctx.allocator, name, outcome) catch return;
    reporter.detail(prefixed_line, .{ reporter.prefix, line });
}

/// Replays the `alert` findings of a check this run collapsed or hid — the
/// pre-trip warnings that something is one edit from a blocking limit. Twice
/// recorded, a file crossed the 10000-line hard cap from one line under it
/// while its warning sat in a 45-finding advisory pile; a count-only line is the
/// same failure. Routed through the always-visible detail channel, named with
/// its check, and printed exactly once (a `.full` render already showed it).
fn printAlerts(ctx: *types.RunCtx, name: []const u8, r: CheckResult) void {
    for (r.warnings) |w| {
        if (!w.alert) continue;
        const line = reporter.flatLine(ctx.allocator, w) catch continue;
        // A fileless alert whose message already opens with its check name
        // would otherwise read `guardian: twin-drift: twin-drift: …`.
        if (namesItself(line, name)) {
            reporter.detail("{s}{s}\n", .{ reporter.prefix, line });
            continue;
        }
        reporter.detail("{s}{s}: {s}\n", .{ reporter.prefix, name, line });
    }
}

/// True when a rendered finding already begins `<check>: `.
fn namesItself(line: []const u8, name: []const u8) bool {
    return line.len > name.len + 1 and
        std.mem.startsWith(u8, line, name) and
        line[name.len] == ':';
}

// spec: Run Summary - Replays an alert finding when a check's own output is collapsed or hidden

test "an alert survives the collapse that hides the rest of its check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // Only `.full` replays the check's own output, so only `.full` needs no
    // separate alert line — the other two would otherwise drop it.
    try std.testing.expect(!run_view.showsAlerts(.full));
    try std.testing.expect(run_view.showsAlerts(.collapsed));
    try std.testing.expect(run_view.showsAlerts(.hidden));

    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };
    const warnings = [_]reporter.Violation{
        .{ .check = "file-size", .file = "src/mid.zig", .message = "1200 code lines (recommended: 1000)" },
        .{
            .check = "file-size",
            .file = "src/router.zig",
            .message = "NEAR HARD CAP  9612 of 10000 code lines (96%)",
            .alert = true,
        },
    };
    printAlerts(&ctx, "file-size", .{ .ran = true, .warnings = &warnings });
    // The one line that matters is named, attributed, and complete...
    try std.testing.expectEqualStrings(
        "guardian: file-size: src/router.zig: NEAR HARD CAP  9612 of 10000 code lines (96%)\n",
        cap.buf.items,
    );
    // ...and the 44 ordinary advisory findings it was buried in stay collapsed.
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "src/mid.zig") == null);
}

/// How much output this run was asked for. `--verbose` wins over `--summary`:
/// the two are contradictory, and the one that shows MORE is the safe reading
/// of a contradictory request.
fn verbosityOf(ctx: *const types.RunCtx) run_view.Verbosity {
    if (ctx.verbose) return .verbose;
    if (ctx.summary) return .summary;
    return .normal;
}

/// One check's finding set as the printer sees it: blocking or not, how many
/// findings, and how many of those touch a diff-scoped run's changed files. On
/// a whole-tree run every finding is in scope, so scoping never collapses.
fn outcomeOf(ctx: *const types.RunCtx, r: CheckResult) run_view.Outcome {
    const findings = r.records.len + r.warnings.len;
    const s = ctx.scoped orelse return .{ .blocking = r.failed, .findings = findings, .in_scope = findings };
    return .{
        .blocking = r.failed,
        .findings = findings,
        .in_scope = run_view.inScope(s.changed_paths, r.records) +
            run_view.inScope(s.changed_paths, r.warnings),
    };
}

/// Adds a check's findings to the JSONL sink accumulator: its structured
/// records when migrated (each string copied into the run allocator so it
/// outlives the worker arena), else the scraped violation lines tagged with the
/// check name. Best-effort — a copy/append OOM drops the record, never fails.
fn collectSink(ctx: *types.RunCtx, acc: *Sink, check_name: []const u8, r: CheckResult) void {
    // A check prints its remedy once, as a `fix:` line beneath its findings.
    // The sink has no "beneath the findings", so that line becomes the hint on
    // every row the check produced — unless the record already carries a more
    // specific one of its own (formatting's `zig fmt <file>`, the ban family's
    // per-rule rename).
    const hint = baseline.firstFixHint(r.output);
    if (r.records.len > 0) {
        // Best-effort telemetry: a dropped sink record is logged, not swallowed
        // silently, and never fails the gate (the check's own verdict already
        // stands). log is fine here — cli/ is exempt from debug-print-ban.
        for (r.records) |v| {
            const owned = dupViolation(ctx.allocator, withHint(v, hint)) catch |e| {
                std.log.warn(sink_drop_warning, .{@errorName(e)});
                continue;
            };
            acc.records.append(ctx.allocator, owned) catch |e|
                std.log.warn(sink_drop_warning, .{@errorName(e)});
        }
        return;
    }
    // Unmigrated check: scrape indented violation lines (baseline.extract shares
    // the same indentation rules), tagging each with the check name. The line's
    // own `<file>[:<line>]: ` prefix is lifted into the record's fields and the
    // check's single trailing `fix:` line becomes every row's hint, so a prose
    // check's rows carry the same actionable detail a migrated check's do.
    const lines = baseline.extract(ctx.allocator, r.output) catch return;
    for (lines) |line| {
        const v = sink.scrapedRecord(check_name, line, hint);
        const owned = dupViolation(ctx.allocator, v) catch |e| {
            std.log.warn(sink_drop_warning, .{@errorName(e)});
            continue;
        };
        acc.records.append(ctx.allocator, owned) catch |e|
            std.log.warn(sink_drop_warning, .{@errorName(e)});
    }
}

/// Captures the facts needed to judge one executed check's usefulness and
/// development cost. `findings` is the normalized slice just appended to the
/// last-run sink, so prose and structured checks receive identical identities.
/// Advisory warnings are included as observations too, but remain a separate
/// count. Every allocation failure only shortens telemetry; it cannot gate.
fn collectRoiCheck(
    ctx: *types.RunCtx,
    acc: *Sink,
    check_name: []const u8,
    r: CheckResult,
    findings: []const reporter.Violation,
) void {
    if (!ctx.cfg.dora.enabled) return;
    const a = ctx.allocator;
    const seed: check_roi.ObservationSeed = .{
        .commit = ctx.roi_commit,
        .guardian_digest = build_options.source_digest,
        .check = check_name,
    };
    var observations: std.ArrayList(check_roi.Observation) = .empty;
    for (findings) |finding| {
        const observation = check_roi.observationFromRecord(a, seed, finding) catch |err| {
            std.log.warn("guardian: dropped a check ROI observation: {s}", .{@errorName(err)});
            continue;
        };
        observations.append(a, observation) catch |err|
            std.log.warn("guardian: dropped a check ROI observation: {s}", .{@errorName(err)});
    }
    for (r.warnings) |borrowed| {
        const observation = check_roi.observationFromRecord(a, seed, borrowed) catch |err| {
            std.log.warn("guardian: dropped a check ROI warning observation: {s}", .{@errorName(err)});
            continue;
        };
        observations.append(a, observation) catch |err|
            std.log.warn("guardian: dropped a check ROI warning observation: {s}", .{@errorName(err)});
    }
    acc.roi_checks.append(a, .{
        .check = check_name,
        .policy = roiPolicy(ctx.cfg.policy.modeFor(check_name)),
        .outcome = roiCheckOutcome(r),
        .duration_ms = r.elapsed_ms,
        .counts = .{
            .findings = countU32(findings.len),
            .warnings = countU32(r.warnings.len),
            .deferred = countU32(r.measured.len),
        },
        .observations = observations.items,
    }) catch |err| std.log.warn("guardian: dropped a check ROI result: {s}", .{@errorName(err)});
}

fn roiPolicy(mode: config.PolicyMode) check_roi.Policy {
    return switch (mode) {
        .block => .block,
        .ratchet => .ratchet,
        .report => .report,
    };
}

fn roiCheckOutcome(r: CheckResult) check_roi.CheckOutcome {
    if (r.err != null) return .@"error";
    if (r.failed) return .failed;
    if (r.reported) return .reported;
    return .passed;
}

fn countU32(n: usize) u32 {
    return std.math.cast(u32, n) orelse std.math.maxInt(u32);
}

/// Gathers a check's measurement-deferred findings into the run accumulator,
/// copying each borrowed string so it outlives the worker arena. Best-effort:
/// a dropped record only shortens the standing reminder, never fails the run.
fn collectMeasured(ctx: *types.RunCtx, acc: *Sink, r: CheckResult) void {
    const a = ctx.allocator;
    for (r.measured) |m| {
        const owned: reporter.Measured = .{
            .check = a.dupe(u8, m.check) catch |e| {
                std.log.warn(measurement_drop_warning, .{@errorName(e)});
                continue;
            },
            .path = a.dupe(u8, m.path) catch |e| {
                std.log.warn(measurement_drop_warning, .{@errorName(e)});
                continue;
            },
            .message = a.dupe(u8, m.message) catch |e| {
                std.log.warn(measurement_drop_warning, .{@errorName(e)});
                continue;
            },
        };
        acc.measured.append(a, owned) catch |e|
            std.log.warn(measurement_drop_warning, .{@errorName(e)});
    }
}

/// A record with `hint` filled in when it has none of its own, so a row's hint
/// reads the same whether the check emitted records or printed prose.
fn withHint(v: reporter.Violation, hint: ?[]const u8) reporter.Violation {
    if (v.fix_hint != null or hint == null) return v;
    var out = v;
    out.fix_hint = sink.hintText(hint);
    return out;
}

/// Copies a Violation's borrowed string fields into `a` so a record produced in
/// a per-worker arena survives that arena's deinit and can be serialized later.
fn dupViolation(a: std.mem.Allocator, v: reporter.Violation) std.mem.Allocator.Error!reporter.Violation {
    return .{
        .check = try a.dupe(u8, v.check),
        .file = try dupOpt(a, v.file),
        .line = v.line,
        .message = try a.dupe(u8, v.message),
        .fix_hint = try dupOpt(a, v.fix_hint),
        .identity = try dupOpt(a, v.identity),
        .ratchet_key = try dupOpt(a, v.ratchet_key),
        .metric = v.metric,
        .alert = v.alert,
    };
}

fn dupOpt(a: std.mem.Allocator, s: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (s) |x| try a.dupe(u8, x) else null;
}

/// A captured check's output is replayed when it has content and either we're
/// not quiet or the check failed (mirrors the live reporter's quiet behavior).
fn shouldEmit(quiet: bool, r: CheckResult) bool {
    return r.output.len > 0 and (!quiet or r.failed or r.reported or r.warnings.len > 0 or r.measured.len > 0);
}

fn expectedPolicyFinding(_: *types.RunCtx) types.RunError!void {
    reporter.fail("expected policy finding", .{});
    return error.CheckFailed;
}

fn shouldSkip(name: []const u8, disabled: []const []const u8) bool {
    for (non_gate_commands) |s| if (std.mem.eql(u8, name, s)) return true;
    for (disabled) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// True when `name` must not run this pass: a built-in non-gate or a disabled
/// check (shouldSkip), or filtered out by an active --only / --skip. With
/// --only, only the listed names run; --skip removes the listed names.
fn excluded(ctx: *const types.RunCtx, name: []const u8) bool {
    if (shouldSkip(name, ctx.cfg.disabled)) return true;
    if (ctx.only.len > 0) return !inList(ctx.only, name);
    return inList(ctx.skip, name);
}

/// True when at least one non-excluded check declares `needs_ast = .yes`,
/// meaning the shared parsed-source index is worth building for this run.
fn anyNeedsAst(ctx: *const types.RunCtx) bool {
    for (registry.all) |cmd| {
        if (excluded(ctx, cmd.name)) continue;
        if (cmd.needs_ast == .yes) return true;
    }
    return false;
}

// spec: Run All - Skips checks whose name appears in the disabled config list
// spec: Command Ergonomics - Parses the tree once for every pass of one accept

test "a caller-supplied source index is not rebuilt per pass" {
    // accept runs preview + update + verify over one unchanged tree: every pass
    // needs the index, none of them may re-parse for it.
    try std.testing.expect(!parsesTree(true, true, false));
    try std.testing.expect(!parsesTree(true, false, true));
    // Without a supplied index nothing changes: a pass parses when an AST check
    // runs or the run is diff-scoped, and skips the parse entirely otherwise.
    try std.testing.expect(parsesTree(false, true, false));
    try std.testing.expect(parsesTree(false, false, true));
    try std.testing.expect(!parsesTree(false, false, false));
}

// spec: Run All - Rejects unknown check names in the disabled list
// spec: Run All - Tolerates retired check names in the disabled list
// spec: Run All - Emits captured output when not quiet or when a check fails or warns

test "shouldEmit gates captured output by quiet failure and warnings" {
    const warning = [_]reporter.Violation{.{ .check = "line-length", .message = "130 chars" }};
    // Passing check: shown live, suppressed under --quiet.
    try std.testing.expect(shouldEmit(false, .{ .ran = true, .output = "ok" }));
    try std.testing.expect(!shouldEmit(true, .{ .ran = true, .output = "ok" }));
    // Failing check: always shown, even under --quiet.
    try std.testing.expect(shouldEmit(true, .{ .ran = true, .failed = true, .output = "bad" }));
    // Advisory findings are also visible under --quiet.
    try std.testing.expect(shouldEmit(true, .{ .ran = true, .warnings = &warning, .output = "warn" }));
    // No captured output: nothing to replay.
    try std.testing.expect(!shouldEmit(false, .{ .ran = true, .output = "" }));
}

test "threadCount is at least one" {
    try std.testing.expect(threadCount() >= 1);
}

// spec: Measurement Mode - Withholds the green skip-cache stamp from a run with deferred findings

test "stampsGreen refuses the stamp for a filtered or measurement-exempted run" {
    // The ordinary case: a full, unexempted green run stamps so the next
    // unchanged build can skip the suite.
    try std.testing.expect(stampsGreen(false, 0));
    // A partial suite never claims the full suite green.
    try std.testing.expect(!stampsGreen(true, 0));
    // A run whose green depended on a [measurement] exemption must not stamp:
    // the commit gate skips on a matching digest, so a stamp here would carry
    // the exemption through the boundary. One re-run at commit is the price.
    try std.testing.expect(!stampsGreen(false, 1));
    try std.testing.expect(!stampsGreen(true, 3));
}

// spec: Run All - Runs the cheapest formatting gate before the rest of the suite

test "preflightIndex picks the first registry entry and honors a skip filter" {
    const cfg: config.Config = .{};
    const base: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    // The preflight is the formatting gate, and it sits first in the registry —
    // so nothing expensive can be scheduled ahead of it.
    const i = preflightIndex(&base).?;
    try std.testing.expectEqual(@as(usize, 0), i);
    try std.testing.expectEqualStrings(preflight_name, registry.all[i].name);
    // Filtered or disabled, it simply runs in the pool like any other check.
    var skipped = base;
    skipped.skip = &[_][]const u8{preflight_name};
    try std.testing.expect(preflightIndex(&skipped) == null);
}

// spec: Run All - Blocks the build only when forced or configured to block

test "blocks only when forced or when on_build is block" {
    // Default report mode: an unforced run does not block (dev build succeeds).
    try std.testing.expect(!blocks(false, .report));
    // --gate / commit / nightly / accept force blocking even in report mode.
    try std.testing.expect(blocks(true, .report));
    // on_build = block preserves the historical hard-block on any build.
    try std.testing.expect(blocks(false, .block));
    try std.testing.expect(blocks(true, .block));
}

// spec: Run All - Names the failing checks in the run summary

test "joinNames comma-joins the failed check names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "type-size, cognitive-complexity",
        joinNames(a, &.{ "type-size", "cognitive-complexity" }),
    );
    // Defensive floor: a dropped telemetry list still yields a printable token.
    try std.testing.expectEqualStrings("?", joinNames(a, &.{}));
}

// spec: Run All - Names each failing check's first finding under the run summary

test "firstRecordFor picks the failing check's own first finding" {
    const records = [_]reporter.Violation{
        .{ .check = "line-length", .file = "src/a.zig", .line = 3, .message = "130 chars" },
        .{ .check = "function-size", .file = "src/b.zig", .line = 412, .message = "fn wide has 7 params (cap 6)" },
        .{ .check = "function-size", .file = "src/c.zig", .line = 9, .message = "fn other has 8 params (cap 6)" },
    };
    // The offender echoed under the summary is the failing check's first record —
    // file:line, the item, the metric and the cap, all already in the message.
    const v = firstRecordFor(&records, "function-size").?;
    try std.testing.expectEqualStrings("src/b.zig", v.file.?);
    try std.testing.expectEqual(@as(u32, 412), v.line.?);
    // A check that recorded no line-level detail echoes nothing.
    try std.testing.expect(firstRecordFor(&records, "pub-api-surface") == null);
    // The echo names how many findings it is standing in for, so a check that
    // flagged three things can't read as one.
    try std.testing.expectEqual(@as(usize, 2), countRecordsFor(&records, "function-size"));
    try std.testing.expectEqual(@as(usize, 0), countRecordsFor(&records, "pub-api-surface"));
}

// spec: Run Summary - Resolves the verbose flag ahead of the summary flag

test "verbosityOf reads the output flags with verbose winning" {
    const cfg: config.Config = .{};
    const base: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    // No flags: the default concise grouped mode.
    try std.testing.expectEqual(run_view.Verbosity.summary, verbosityOf(&base));
    var summary = base;
    summary.summary = true;
    try std.testing.expectEqual(run_view.Verbosity.summary, verbosityOf(&summary));
    var verbose = base;
    verbose.verbose = true;
    try std.testing.expectEqual(run_view.Verbosity.verbose, verbosityOf(&verbose));
    // Contradictory flags resolve to the one that shows more.
    var both = summary;
    both.verbose = true;
    try std.testing.expectEqual(run_view.Verbosity.verbose, verbosityOf(&both));
}

// spec: Run Summary - Replays blocking check output before advisory output

test "emitPass selects the blocking checks first and the rest second" {
    // The replay is two ordered walks of the same captured results, so a reader
    // meets every blocking failure before any advisory line.
    const blocking: CheckResult = .{ .ran = true, .failed = true, .output = "boom" };
    const advisory: CheckResult = .{ .ran = true, .output = "fyi" };
    const skipped: CheckResult = .{};
    try std.testing.expect(blocking.failed == (Pass.blocking == .blocking));
    try std.testing.expect(advisory.failed == (Pass.advisory == .blocking));
    try std.testing.expect(!skipped.ran);
}

// spec: Run Summary - Counts a check's findings and their diff-scope overlap

test "outcomeOf counts every finding and places it against the run scope" {
    const cfg: config.Config = .{};
    var index: ast_index.Index = .{ .files = &.{} };
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    const records = [_]reporter.Violation{
        .{ .check = "x", .file = "src/touched.zig", .message = "in the diff" },
        .{ .check = "x", .file = "src/untouched.zig", .message = "outside the diff" },
    };
    const warnings = [_]reporter.Violation{
        .{ .check = "x", .file = "src/untouched.zig", .message = "advisory, outside the diff" },
    };
    const r: CheckResult = .{ .ran = true, .records = &records, .warnings = &warnings };

    // Whole-tree run: every finding is in scope, so nothing can collapse.
    const whole = outcomeOf(&ctx, r);
    try std.testing.expectEqual(@as(usize, 3), whole.findings);
    try std.testing.expectEqual(@as(usize, 3), whole.in_scope);

    // Diff-scoped run: only the finding in a changed file counts as in scope.
    ctx.scoped = .{
        .base = "abc123",
        .file_count = 1,
        .changed_paths = &.{"src/touched.zig"},
        .index = &index,
    };
    const scoped_outcome = outcomeOf(&ctx, r);
    try std.testing.expectEqual(@as(usize, 3), scoped_outcome.findings);
    try std.testing.expectEqual(@as(usize, 1), scoped_outcome.in_scope);
}

// spec: Run All - Hints a stale binary when re-keying failures follow a binary change

test "binary drift hint fires only on re-keying failures after a binary change" {
    // Snapshot/ratchet checks are the re-key shape a stale binary produces.
    try std.testing.expect(failuresLookLikeRekey(&.{ "naming", "pub-api-surface" }));
    // A purely content failure never triggers the hint.
    try std.testing.expect(!failuresLookLikeRekey(&.{ "naming", "boundaries" }));
    // The hint fires only when the shape matches AND the binary drifted.
    try std.testing.expect(binaryDriftHintApplies(true, true));
    try std.testing.expect(!binaryDriftHintApplies(true, false));
    try std.testing.expect(!binaryDriftHintApplies(false, true));
}

// spec: Run All - Names a check that runs past the heartbeat threshold

test "isSlowCheck fires at or beyond the heartbeat threshold" {
    // A fast check (the common case) gets no heartbeat line.
    try std.testing.expect(!isSlowCheck(0));
    try std.testing.expect(!isSlowCheck(slow_check_ms - 1));
    // At or past ~5s the check is named as slow so a long run reads as alive.
    try std.testing.expect(isSlowCheck(slow_check_ms));
    try std.testing.expect(isSlowCheck(slow_check_ms * 3));
}

// spec: Run All - Warns before the run when the binary differs from the last green stamp

test "the pre-run warning clears a binary built from the stamped source" {
    var a: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("binary-A", &a, .{});
    var b: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("binary-B", &b, .{});
    var source: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("guardian-source", &source, .{});
    var other_source: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("older-guardian-source", &other_source, .{});

    // No stamp yet (first run): nothing to compare against, so no warning.
    try std.testing.expect(!cache.binaryDrifted(.{}, .{ .id = a, .source = source }));
    // Same guardian source, different executable bytes — a second dep root's
    // own build of the very source `selfcheck` just proved. Never a warning.
    try std.testing.expect(!cache.binaryDrifted(
        .{ .id = a, .source = source },
        .{ .id = b, .source = source },
    ));
    // A genuinely different guardian source: still warned about.
    try std.testing.expect(cache.binaryDrifted(
        .{ .id = a, .source = other_source },
        .{ .id = a, .source = source },
    ));
    // And the direction names the binaries, not the moment the stamp was
    // written: a binary newer than the stamping one reads as newer even when
    // the stamp file itself was touched later by that older build's run.
    try std.testing.expectEqual(run_view.BinaryAge.running_newer, run_view.binaryAge(200, 100));
}

// spec: Run All - Marks the first gate on a tree that has no prior green stamp

test "coldGate is true only with no stored green stamp" {
    var d: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("a prior green", &d, .{});
    // No stamp yet (first gate): cold.
    try std.testing.expect(coldGate(null));
    // A stored green digest means the tree has been gated before: not cold.
    try std.testing.expect(!coldGate(d));
}

// spec: Run All - Runs a metadata transaction only when the run can write metadata

test "writesMetadata is true only for a writable or refreshing run" {
    const cfg: config.Config = .{};
    const base: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    // accept/migrate flip metadata_writable → a transaction is needed.
    var writable = base;
    writable.metadata_writable = true;
    try std.testing.expect(writesMetadata(&writable));
    // A pending accept refresh set also writes (the named checks' baselines).
    var refreshing = base;
    refreshing.refresh = &.{"pub-api-surface"};
    try std.testing.expect(writesMetadata(&refreshing));
    // A plain run with no refresh env set is read-only → no transaction.
    var plain = base;
    try std.testing.expect(!writesMetadata(&plain));
}

// spec: Run All - Cautions on failure that zig-out binaries predate the red run

test "the failure caution names zig-out and the gated installs" {
    try std.testing.expect(std.mem.indexOf(u8, stale_artifact_caution, "zig-out") != null);
    try std.testing.expect(std.mem.indexOf(u8, stale_artifact_caution, "gated on green") != null);
    try std.testing.expect(std.mem.indexOf(u8, stale_artifact_caution, "rebuild green") != null);
}

test "shouldSkip honors the disabled list and built-in skips" {
    try std.testing.expect(shouldSkip("magic-number", &.{"magic-number"}));
    try std.testing.expect(shouldSkip("spec-init", &.{}));
    try std.testing.expect(!shouldSkip("spec", &.{"magic-number"}));
}

test "disabled list entries must be real check names" {
    // A retired check resolves through the compatibility table, not registry.
    try std.testing.expect(registry.find("magic-number") == null);
    try std.testing.expect(retired_checks.find("magic-number") != null);
    try std.testing.expect(registry.find("magic-numbers") == null);
}

test "retired check names are recognized (tolerated in disabled)" {
    // A retired name resolves via the shared compatibility ledger,
    // and reports where it was folded; a genuine typo does not.
    try std.testing.expect(retired_checks.find("spec-drift") != null);
    try std.testing.expectEqualStrings("pub-api-surface", retired_checks.find("spec-drift").?.folded_into);
    try std.testing.expectEqualStrings(retired_checks.style_tier, retired_checks.find("magic-number").?.folded_into);
    try std.testing.expect(retired_checks.find("history") != null);
    try std.testing.expect(retired_checks.find("not-a-real-check") == null);
}

// spec: Run All - Runs only the checks named by an only filter
// spec: Run All - Excludes the checks named by a skip filter
// spec: Run All - Rejects an only or skip name that is not a runnable check
// spec: Run All - Detects a filtered run so the green cache stamp is suppressed

test "excluded runs only the names listed by an only filter" {
    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .only = &[_][]const u8{"spec"},
    };
    try std.testing.expect(!excluded(&ctx, "spec"));
    try std.testing.expect(excluded(&ctx, "file-size"));
    // built-in non-gates stay excluded regardless of the filter
    try std.testing.expect(excluded(&ctx, "mutate"));
}

test "excluded removes the names listed by a skip filter" {
    const cfg: config.Config = .{};
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .skip = &[_][]const u8{"file-size"},
    };
    try std.testing.expect(excluded(&ctx, "file-size"));
    try std.testing.expect(!excluded(&ctx, "spec"));
}

test "isAllCheck accepts gates and rejects non-gates and typos" {
    try std.testing.expect(isAllCheck("spec"));
    try std.testing.expect(isAllCheck("file-size"));
    try std.testing.expect(!isAllCheck("mutate")); // non-gate step
    try std.testing.expect(!isAllCheck("nightly")); // composed, not in registry
    try std.testing.expect(!isAllCheck("commit")); // gate+commit, not in registry
    try std.testing.expect(!isAllCheck("spec-init")); // generator
    try std.testing.expect(!isAllCheck("bogus")); // typo
}

test "validateCheckNames accepts registered gates" {
    try validateCheckNames(&.{ "spec", "file-size" }, "test");
}

test "policy lists tolerate retired check and command names during upgrades" {
    const cfg: config.Config = .{ .policy = .{
        .block = &.{"stdout-flush"},
        .ratchet = &.{"magic-number"},
        .report = &.{"history"},
    } };
    const ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    try validatePolicy(&ctx);
}

test "isFiltered is true exactly when an only or skip selection is active" {
    const cfg: config.Config = .{};
    const base: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    try std.testing.expect(!isFiltered(&base));
    var only_ctx = base;
    only_ctx.only = &[_][]const u8{"spec"};
    try std.testing.expect(isFiltered(&only_ctx));
    var skip_ctx = base;
    skip_ctx.skip = &[_][]const u8{"spec"};
    try std.testing.expect(isFiltered(&skip_ctx));
}

// spec-case: Policy Protection - Blocks protected Guardian metadata drift unless trusted CI approves it

test "policy protection and explicit blocks bypass a global baseline" {
    const cfg: config.Config = .{
        .baseline = .{ .enabled = true },
        .policy = .{ .block = &.{"file-size"} },
    };
    try std.testing.expect(!cfg.policy.usesBaselineFor("policy-drift", cfg.baseline));
    try std.testing.expect(!cfg.policy.usesBaselineFor("file-size", cfg.baseline));
    try std.testing.expect(cfg.policy.usesBaselineFor("naming", cfg.baseline));
    var ratcheted = cfg.policy;
    ratcheted.ratchet = &.{"naming"};
    try std.testing.expect(ratcheted.usesBaselineFor("naming", .{}));
    var report = cfg.policy;
    report.report = &.{"naming"};
    try std.testing.expect(!report.usesBaselineFor("naming", cfg.baseline));
}

// spec-case: Policy Modes - Resolves strict, agent, and safety profiles with explicit per-check overrides

test "report policy preserves a finding without failing the captured check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg: config.Config = .{ .policy = .{ .profile = .agent } };
    var ctx: types.RunCtx = .{
        .allocator = a,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
    };
    const result = runCaptured(&ctx, a, .{
        .name = "line-length",
        .summary = "test",
        .scope = .per_file,
        .subject = .tree,
        .run = expectedPolicyFinding,
    });
    try std.testing.expect(result.reported);
    try std.testing.expect(!result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "expected policy finding") != null);
}

// spec: Run All - Skips a full run when the input digest matches the last green run and no refresh is pending

test "skipDecision requires cache on, a digest match, and no pending refresh" {
    // The skip case: cache enabled, no refresh, digest matches. A dirty working
    // tree is NOT a factor — a content-identical (digest-matching) tree skips
    // whether or not git reports uncommitted edits, because the digest covers
    // every file each check reads.
    try std.testing.expect(skipDecision(true, false, true));
    // A pending refresh always executes fully — it exists to rewrite snapshots,
    // and its post-write tree must be re-stamped, never skipped.
    try std.testing.expect(!skipDecision(true, true, true));
    // A changed source or .guardian/ tree (digest mismatch) re-runs — this is
    // what makes an auto-pruned baseline re-run instead of being masked.
    try std.testing.expect(!skipDecision(true, false, false));
    // A disabled cache never skips.
    try std.testing.expect(!skipDecision(false, false, true));
}

// spec: Run All - Runs the whole suite despite a matching digest when the full flag is set

test "the full flag bypasses the green cache before the digest walk" {
    // A --full run is a request to verify the tree, not to be told it is
    // unchanged, so it must run even with the cache enabled and a matching
    // digest. The bypass short-circuits before the digest is even computed.
    const cfg: config.Config = .{ .cache_enabled = true };
    var ctx: types.RunCtx = .{ .allocator = std.testing.allocator, .project_dir = ".", .cfg = &cfg, .full = true, .quiet = true };
    try std.testing.expect(!shouldSkipRun(&ctx));
}

// spec: Diff Scoping - Hands the narrowed index only to per-file checks

test "indexFor narrows per-file checks and leaves whole-tree checks intact" {
    const cfg: config.Config = .{};
    var full: ast_index.Index = .{ .files = &.{} };
    var narrow: ast_index.Index = .{ .files = &.{} };
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .source_index = &full,
    };
    // Whole-tree run (no scope): every check sees the same full index.
    try std.testing.expectEqual(@as(?*const ast_index.Index, &full), indexFor(&ctx, .per_file));
    try std.testing.expectEqual(@as(?*const ast_index.Index, &full), indexFor(&ctx, .whole_tree));

    // Diff-scoped run: only the per-file checks are narrowed. A whole-tree
    // check keeps the full index, which is what keeps it sound.
    ctx.scoped = .{ .base = "abc123", .file_count = 1, .index = &narrow };
    try std.testing.expectEqual(@as(?*const ast_index.Index, &narrow), indexFor(&ctx, .per_file));
    try std.testing.expectEqual(@as(?*const ast_index.Index, &full), indexFor(&ctx, .whole_tree));
}

// spec: Diff Scoping - Treats a diff-scoped run as partial so it never stamps the green cache

test "isPartial covers both filtered and diff-scoped runs" {
    // A whole-tree, unfiltered run is the only one that may stamp green.
    try std.testing.expect(!isPartial(false, false));
    try std.testing.expect(isPartial(true, false));
    try std.testing.expect(isPartial(false, true));
    try std.testing.expect(isPartial(true, true));
}

// spec: Run All - Rejects an unknown refresh target or deny_growth check name

test "validateDenyGrowth accepts real checks and rejects a typo" {
    // Capture so the expected failure diagnostics don't leak to the test log.
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    try validateDenyGrowth(&.{"spec"});
    try std.testing.expectError(error.CheckFailed, validateDenyGrowth(&.{"nonsense-check"}));
}
