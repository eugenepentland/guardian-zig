//! Baseline mode (v3 identity baselines): grandfather a check's *existing*
//! violations so only newly-added ones fail the build. Capture-once,
//! diff-by-identity, auto-prune when the set shrinks; `grown` is the single
//! failing outcome. Threshold checks use per-item ratchets (ratchet.zig)
//! instead, which this module self-migrates to.
//!
//! v1 stored the *rendered violation text*, which made a diagnostic rewording
//! re-key every consumer's baseline and red their gate on unchanged code. v3
//! stores `violation_key` identities instead, so rendering may change freely.
//! A v1 file self-migrates on first run (see `migrate`) — consumers upgrade with
//! no manual refresh.

const std = @import("std");
const fs = @import("fs.zig");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const reporter = @import("reporter.zig");
const sink = @import("sink.zig");
const types = @import("cli/types.zig");
const snapshot_helper = @import("snapshot_helper.zig");
const ratchet = @import("ratchet.zig");
const relocation = @import("relocation.zig");
const hysteresis = @import("hysteresis.zig");
const git = @import("git.zig");
const accept_session = @import("accept_session.zig");
const violation_key = @import("violation_key.zig");
const scope = @import("scope.zig");
const config_mod = @import("config.zig");
const ast_index = @import("ast/index.zig");
const missing_inputs = @import("missing_inputs.zig");

/// Read cap for a stored baseline/ratchet file when scanning it for paths that
/// no longer exist. Generous: the largest real baselines are a few hundred KiB.
const max_baseline_bytes: usize = 8 * 1024 * 1024;

/// Baseline file format version. Bump if the format changes meaningfully.
/// v1 stored rendered violation text; v3 stores content-derived identities.
/// (v2 is the per-item ratchet format owned by `ratchet.zig`.)
pub const version: u32 = 3;

/// The text-keyed format v3 replaces; read only by `migrate`.
pub const legacy_version: u32 = 1;

/// One current violation: the identity the baseline stores plus the rendered
/// line used to report it. Keeping both is what lets the file be keyed by
/// identity while failures still read as human diagnostics.
pub const Keyed = struct { key: []const u8, line: []const u8 };

/// Outcome of one check's baseline lifecycle. Maps to user-visible
/// reporter output: `created`, `matched`, `shrunk` and `refreshed`
/// are success paths; `grown` fails the build.
pub const Outcome = union(enum) {
    /// No prior baseline existed; one was just written.
    created: usize,
    /// Current set matches baseline exactly.
    matched: usize,
    /// Some baselined violations were resolved; the baseline file was
    /// auto-pruned to the current (smaller) set. Removing entries is
    /// monotone-safe, so pruning never needs a refresh env var.
    shrunk: struct { remaining: usize, removed: usize },
    /// `force_refresh` was set; baseline was rewritten.
    refreshed: usize,
    /// A v1 text-keyed baseline was re-keyed to v3 identities in place.
    migrated: usize,
    /// A v1 baseline could not be re-keyed because a file now holds more
    /// violations than it recorded. `lines` are that file's current violations —
    /// after a re-key the new one can no longer be told apart from the
    /// grandfathered ones, so all of them are shown.
    migration_blocked: struct { lines: []const []const u8, baseline_size: usize },
    /// New violations beyond the baseline.
    grown: struct { new_lines: []const []const u8, baseline_size: usize },
};

/// Pulls violation lines out of a check's captured stdout.
///
/// A check's failing output is `[header] [violation lines…] [trailing hint /
/// suggestion block]`. Only the middle is real violations. A violation line is
/// indented (two spaces or a tab); the trailing block is everything from the
/// first hint marker (`fix:` / `add:`) or the first blank line after violations
/// began — whichever comes first. This excludes multi-line `fix:` continuations
/// (e.g. `       or re-run …`) and the spec check's `add:` suggestion block,
/// which earlier only-`fix:`-prefixed skipping miscounted as violations.
///
/// The returned lines are dedented (leading whitespace stripped) and
/// allocator-owned.
pub fn extract(arena: Allocator, output: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, output, '\n');
    var collected_any = false;
    while (iter.next()) |raw| {
        if (raw.len == 0) {
            // A blank line after violations began ends the violation block;
            // the trailing hint/suggestion prose follows (spec prints exactly
            // one such blank before its `add:` block).
            if (collected_any) break;
            continue;
        }
        if (!isIndented(raw)) continue;
        const trimmed = leftTrim(raw);
        if (isHintStart(trimmed)) break;
        try out.append(arena, try arena.dupe(u8, trimmed));
        collected_any = true;
    }
    return out.toOwnedSlice(arena);
}

fn isIndented(line: []const u8) bool {
    if (line.len == 0) return false;
    return line[0] == ' ' or line[0] == '\t';
}

fn leftTrim(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[i..];
}

/// Labels that begin a check's trailing prose block. Everything from the first
/// one onward is guidance, not violations.
///
/// This list is the contract for check authors: **trailing prose emitted after
/// a check's violation lines must start with one of these labels.** A check that
/// invents a new one has its prose silently scraped as a violation — which is
/// how `test-no-conditional`'s `why:` rationale line ended up counted as debt,
/// polluting the baseline and blocking eda's migration with an
/// unactionable one-line "candidate" that was really the rationale text.
///
/// Note that a violation body may itself start with a label (the spec check
/// emits `unverified: <behavior>`), so this cannot be generalized to "any
/// leading word followed by a colon" — the set has to stay explicit.
const hint_labels = [_][]const u8{
    "fix:", // universal remediation hint
    "add:", // spec check's suggested `// spec:` tags
    "why:", // rationale (test-no-conditional)
    "note:", // aside (stdout-flush)
    "stdout:", // captured child output (external-gates)
    "stderr:",
};

/// True when `trimmed` starts a check's trailing prose block (see `hint_labels`).
fn isHintStart(trimmed: []const u8) bool {
    for (hint_labels) |label| {
        if (std.mem.startsWith(u8, trimmed, label)) return true;
    }
    return false;
}

/// A check's current violations split three ways against a stored key set.
///
/// The gate needs two of the three (`added` fails a run, `removed` prunes), and
/// read-only introspection needs the third: `live` is the frozen debt that is
/// STILL REAL, which a baselined check's `N resolved` summary can't express.
/// One split serves both, so a `--list` can never disagree with the gate about
/// which row is new.
pub const Split = struct {
    /// Firing with no recorded counterpart — the violations that fail a run.
    added: []const Keyed,
    /// Firing AND recorded: grandfathered debt that still fires today.
    live: []const Keyed,
    /// Recorded keys with nothing firing behind them any more.
    removed: []const []const u8,
};

/// Accumulators for `splitAgainst`, held together so the merge stays one loop.
const Groups = struct {
    added: std.ArrayList(Keyed) = .empty,
    live: std.ArrayList(Keyed) = .empty,
    removed: std.ArrayList([]const u8) = .empty,
};

/// Multiset split of a stored v3 baseline (identity keys) against the current
/// violations. Matching is by `Keyed.key` alone, so anything the key ignores —
/// source line numbers, counts and caps, and (for a check that sets an explicit
/// `identity`) the entire message wording — lands in `live` rather than moving
/// between added and removed. Multiplicity is preserved: N hits sharing one key
/// still split correctly.
pub fn splitAgainst(arena: Allocator, stored: []const []const u8, current: []const Keyed) Allocator.Error!Split {
    const olds = try arena.dupe([]const u8, stored);
    const news = try arena.dupe(Keyed, current);
    std.mem.sort([]const u8, olds, {}, lessThan);
    std.mem.sort(Keyed, news, {}, keyedLessThan);

    var groups: Groups = .{};
    var i: usize = 0;
    var j: usize = 0;
    while (i < olds.len and j < news.len) {
        switch (std.mem.order(u8, olds[i], news[j].key)) {
            .eq => {
                try groups.live.append(arena, news[j]);
                i += 1;
                j += 1;
            },
            .lt => {
                try groups.removed.append(arena, olds[i]);
                i += 1;
            },
            .gt => {
                try groups.added.append(arena, news[j]);
                j += 1;
            },
        }
    }
    while (i < olds.len) : (i += 1) try groups.removed.append(arena, olds[i]);
    while (j < news.len) : (j += 1) try groups.added.append(arena, news[j]);
    return .{
        .added = try groups.added.toOwnedSlice(arena),
        .live = try groups.live.toOwnedSlice(arena),
        .removed = try groups.removed.toOwnedSlice(arena),
    };
}

fn keyedLessThan(_: void, a: Keyed, b: Keyed) bool {
    const c = std.mem.order(u8, a.key, b.key);
    return if (c != .eq) c == .lt else std.mem.order(u8, a.line, b.line) == .lt;
}

/// The lifecycle's view of `splitAgainst`: additions reported as their rendered
/// lines (a failure reads as a diagnostic, not as a key) and removals as the
/// stored keys the prune drops.
fn diffKeys(arena: Allocator, old: snapshot.Snapshot, current: []const Keyed) Allocator.Error!snapshot.Diff {
    const parts = try splitAgainst(arena, old.lines, current);
    const added = try arena.alloc([]const u8, parts.added.len);
    for (parts.added, 0..) |k, i| added[i] = k.line;
    return .{ .added = added, .removed = parts.removed };
}

/// Writes `current`'s identity keys as the baseline file contents. Uses the
/// content-identical short-circuit so re-emitting the same key set leaves the
/// committed baseline (and the diff) untouched.
fn writeKeys(arena: Allocator, path: []const u8, current: []const Keyed) snapshot.WriteError!void {
    const keys = try arena.alloc([]const u8, current.len);
    for (current, 0..) |k, i| keys[i] = k.key;
    _ = try snapshot.writeChecked(arena, path, version, keys);
}

/// Run the baseline lifecycle for a check.
///
/// `force_refresh = true` rewrites the baseline regardless of state (the accept
/// path). `write_allowed` gates every OTHER persistence — first-record creation,
/// auto-prune, and v1→v3 re-keying: an ordinary (read-only) run leaves it false
/// and computes the outcome in memory without touching disk, so a plain build's
/// `git status` stays clean; `commit`/`migrate` flip it so the same writes the
/// old auto-path produced ride the deliberate command.
pub fn lifecycle(
    arena: Allocator,
    baseline_path: []const u8,
    current: []const Keyed,
    force_refresh: bool,
    write_allowed: bool,
) (snapshot.WriteError || snapshot.ReadError)!Outcome {
    if (force_refresh) {
        try writeKeys(arena, baseline_path, current);
        return .{ .refreshed = current.len };
    }

    const loaded = try readOrInit(arena, baseline_path, current, write_allowed);
    const old = switch (loaded) {
        .initialized => |outcome| return outcome,
        .existing => |snap| snap,
    };

    const d = try diffKeys(arena, old, current);
    const outcome = classify(d, old.lines.len, current.len);
    // Auto-prune: a pure shrink (violations resolved, none added) rewrites the
    // baseline with the current smaller set — but only on a metadata-writable
    // run. An ordinary run reports the shrink and leaves the file in place, so a
    // source-only diff never carries an incidental prune. Removing entries is
    // monotone-safe, so deferring it never risks a false failure.
    switch (outcome) {
        .shrunk => if (write_allowed) try writeKeys(arena, baseline_path, current),
        else => {},
    }
    return outcome;
}

/// Result of loading (and possibly initializing) a baseline before diffing.
const Loaded = union(enum) {
    /// No usable baseline existed; `current` was written and this is the
    /// final outcome (`created` when absent, `refreshed` when stale).
    initialized: Outcome,
    /// A usable baseline was loaded.
    existing: snapshot.Snapshot,
};

/// Read the baseline, initializing it when absent or migrating it when it is
/// still v1 text-keyed. `write_allowed` gates the two init writes: on a
/// read-only run both are computed but the file is left untouched.
fn readOrInit(
    arena: Allocator,
    baseline_path: []const u8,
    current: []const Keyed,
    write_allowed: bool,
) (snapshot.WriteError || snapshot.ReadError)!Loaded {
    const snap = snapshot.read(arena, baseline_path, version) catch |e| switch (e) {
        // Missing → fresh `created`; but a check with nothing to record gets NO
        // baseline file (C1b): an empty baseline is indistinguishable from an
        // absent one, and auto-creating it dirties a source-only diff on every
        // green run. Report matched(0) and leave the tree clean.
        error.Missing => {
            if (current.len == 0) return .{ .initialized = .{ .matched = 0 } };
            if (write_allowed) try writeKeys(arena, baseline_path, current);
            return .{ .initialized = .{ .created = current.len } };
        },
        // A stale version is a v1 text baseline in the wild → re-key, but only
        // persist the re-key on a metadata-writable run.
        error.VersionMismatch => return .{ .initialized = try migrate(arena, baseline_path, current, write_allowed) },
        else => return e,
    };
    return .{ .existing = snap };
}

/// Self-migrates a v1 text-keyed baseline to v3 identity keys, mirroring the
/// v1→v2 ratchet migration: the consumer upgrades guardian and the next run
/// re-keys their committed baseline with no manual refresh.
///
/// The rewrite is *guarded* rather than blind, which is what makes it
/// no-op-shaped — the same violations, new keys:
///
///   * It can never **drop** baselined debt, because every violation the check
///     currently reports is written to the new baseline. An old entry with no
///     current counterpart is one the check no longer reports — precisely the
///     `shrunk` auto-prune case, which is monotone-safe (a recurrence keys as a
///     new violation and reds the build again).
///   * It can never **add** a violation, because `migrationGrowth` refuses the
///     migration when any file's violation count rose above what v1 recorded
///     for it. Per-file counts are the strongest invariant available across a
///     re-key: the old text keys can't be compared to the new identity keys, but
///     a rewording moves violations *between* keys within a file, it never
///     creates one. A file that gained a violation therefore gained real debt,
///     and is reported as `grown` exactly as v1 would have.
///
/// An unreadable v1 file (corrupt, or some other version) carries no counts to
/// guard against, so it is re-keyed unconditionally.
///
/// `write_allowed` gates the persistence: a read-only run classifies the
/// migration (so genuine `migration_blocked` debt still reds the build) but
/// leaves the v1 file on disk, deferring the re-key to `accept`/`migrate`.
fn migrate(
    arena: Allocator,
    baseline_path: []const u8,
    current: []const Keyed,
    write_allowed: bool,
) (snapshot.WriteError || snapshot.ReadError)!Outcome {
    const old = snapshot.read(arena, baseline_path, legacy_version) catch {
        if (write_allowed) try writeKeys(arena, baseline_path, current);
        return .{ .migrated = current.len };
    };
    if (try migrationGrowth(arena, old.lines, current)) |gained| {
        return .{ .migration_blocked = .{ .lines = gained, .baseline_size = old.lines.len } };
    }
    if (write_allowed) try writeKeys(arena, baseline_path, current);
    return .{ .migrated = current.len };
}

/// The current violation lines belonging to files that hold *more* violations
/// than the v1 baseline recorded for them, or null when no file gained any (the
/// migration is then provably a pure re-key or a shrink).
fn migrationGrowth(
    arena: Allocator,
    old_lines: []const []const u8,
    current: []const Keyed,
) Allocator.Error!?[]const []const u8 {
    var old_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (old_lines) |l| try bump(arena, &old_counts, violation_key.fileOf(l));
    var new_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (current) |k| try bump(arena, &new_counts, violation_key.fileOf(k.line));

    var gained: std.ArrayList([]const u8) = .empty;
    for (current) |k| {
        const file = violation_key.fileOf(k.line);
        if ((new_counts.get(file) orelse 0) <= (old_counts.get(file) orelse 0)) continue;
        try gained.append(arena, k.line);
    }
    if (gained.items.len == 0) return null;
    return try gained.toOwnedSlice(arena);
}

/// Increments `map`'s counter for `key`.
fn bump(arena: Allocator, map: *std.StringHashMapUnmanaged(usize), key: []const u8) Allocator.Error!void {
    const gop = try map.getOrPut(arena, key);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

/// Turn a position-insensitive diff into a lifecycle outcome:
/// `grown` on additions, `shrunk` on removals, else `matched`.
fn classify(d: snapshot.Diff, baseline_len: usize, current_len: usize) Outcome {
    if (d.added.len > 0) {
        return .{ .grown = .{ .new_lines = d.added, .baseline_size = baseline_len } };
    }
    if (d.removed.len > 0) {
        return .{ .shrunk = .{ .remaining = current_len, .removed = d.removed.len } };
    }
    return .{ .matched = current_len };
}

/// Build the per-check baseline file path: `<project_dir>/.guardian/baselines/<check>.txt`.
pub fn pathFor(arena: Allocator, project_dir: []const u8, check_name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.guardian/baselines/{s}.txt", .{ project_dir, check_name });
}

/// Run `cmd` with output captured, then apply the baseline lifecycle.
/// Used by both `run-all` and the single-check dispatch in `check.zig`.
pub fn runWithBaseline(ctx: *types.RunCtx, cmd: types.Command) types.RunError!void {
    // Selective refresh: GUARDIAN_UPDATE_SNAPSHOT=<name> refreshes only that
    // check's baseline, so accepting one intended change can't ratify unrelated
    // baseline growth in the same run.
    const force_refresh = snapshot_helper.shouldUpdateForCtx(ctx, cmd.name);
    var capture: reporter.Capture = .{ .allocator = ctx.allocator };
    defer capture.deinit();

    // Inner scope so the capture is restored *before* processOutcome runs —
    // otherwise the outcome's reporter.fail / detail would route into the
    // capture buffer instead of stderr.
    {
        const prior = reporter.default.capture;
        defer reporter.default.capture = prior;
        reporter.default.capture = &capture;

        cmd.run(ctx) catch |e| switch (e) {
            error.CheckFailed => {},
            else => return e,
        };
    }

    // Advisory findings are deliberately outside baseline/ratchet state. Replay
    // them through the prior reporter so `all` can show them even in quiet mode,
    // while only the blocking records below participate in debt metadata.
    for (capture.warnings.items) |warning| reporter.warn(warning);

    return processOutcome(
        ctx,
        cmd.name,
        capture.buf.items,
        capture.records.items,
        capture.warnings.items,
        force_refresh,
    );
}

/// Keyed violations for the baseline diff. Prefers the structured records a
/// migrated check emitted through `reporter.emit` — which can carry an explicit
/// `identity`, the rendering-independent top tier of the key — and falls back to
/// scraping the captured prose for checks that still report only text. Both
/// paths produce the same `<check>|<file>|<discriminator>` key shape, so a check
/// gains precision by adding an identity without any baseline disruption beyond
/// that check's own re-key.
///
/// Public so read-only introspection (`--list` / `--dry-run`, cli/introspect.zig)
/// keys a check's current findings through the SAME function the gate does — a
/// listing derived any other way could disagree with the gate about which row
/// is new, which is the one thing it must never do.
pub fn keyedViolations(
    arena: Allocator,
    check_name: []const u8,
    captured: []const u8,
    records: []const reporter.Violation,
) Allocator.Error![]const Keyed {
    if (records.len > 0) {
        const out = try arena.alloc(Keyed, records.len);
        for (records, 0..) |v, i| out[i] = .{
            .key = try violation_key.fromRecord(arena, check_name, v),
            .line = try reporter.flatLine(arena, v),
        };
        return out;
    }
    const lines = try extract(arena, captured);
    const out = try arena.alloc(Keyed, lines.len);
    for (lines, 0..) |l, i| out[i] = .{
        .key = try violation_key.fromLine(arena, check_name, l),
        .line = l,
    };
    return out;
}

fn processOutcome(
    ctx: *types.RunCtx,
    check_name: []const u8,
    captured: []const u8,
    records: []const reporter.Violation,
    warnings: []const reporter.Violation,
    force_refresh: bool,
) types.RunError!void {
    // write_allowed rides on the context — accept/commit/migrate flip it; an
    // ordinary run leaves it false and every lifecycle write below is deferred.
    // A check that only read the changed files never writes, whatever the
    // command asked for: reconciling recorded debt from a partial view would
    // prune entries that are merely out of scope. (The scoping resolver already
    // refuses to scope a metadata-writing run; this is the second lock.)
    const view = viewFor(ctx);
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A worktree missing a check's gitignored generated inputs is a PARTIAL
    // view of the tree its stored metadata describes. Nothing may be pruned or
    // re-recorded from it — a missing file's frozen entries are unread, not
    // resolved — so such a run is forced read-only on metadata.
    // …and a diff-scoped run is a partial view by construction, so it is
    // locked read-only on metadata for exactly the same reason.
    const partial = try storedPhantoms(a, ctx, check_name);
    const write_allowed = ctx.metadata_writable and partial == 0 and view == .whole_tree;

    // A threshold check with a stable key + metric uses the per-item ratchet
    // lifecycle (baseline v2): each offender gets an only-shrinks ceiling, so a
    // metric change on a grandfathered offender no longer reds the build. Every
    // other check keeps the v3 identity-diff lifecycle below. Selection is by
    // check name (not the presence of records), so a metric check with zero
    // current violations still ratchets — it prunes its whole baseline.
    if (ratchet.metricMode(check_name) != null) {
        return processRatchet(a, ctx, check_name, .{
            .captured = captured,
            .records = records,
            .warnings = warnings,
            .force_refresh = force_refresh,
            .write_allowed = write_allowed,
        });
    }

    const path = try pathFor(a, ctx.project_dir, check_name);
    const all_violations = try keyedViolations(a, check_name, captured, records);

    // Findings about a file that is missing AND gitignored describe generated
    // output this worktree never built — they are reported as skipped, never
    // counted, and (because a partial view must not rewrite frozen state) they
    // also make this run read-only on metadata.
    const scan = try scanPhantoms(a, ctx, check_name, all_violations);
    const violations = scan.kept;
    const may_write = write_allowed and scan.skipped == 0;

    // deny_growth: a refresh (global or selective) may only rewrite this
    // check's baseline if it doesn't grow. Guards the flagship 1:1 spec map —
    // today's fastest-growing frozen debt — from being ratified upward.
    try denyGrowthGuard(a, ctx, check_name, path, violations, force_refresh);

    const outcome = lifecycle(a, path, violations, force_refresh and may_write, may_write) catch |e| {
        reporter.fail("{s}: baseline I/O failed: {s}", .{ check_name, @errorName(e) });
        return error.CheckFailed;
    };

    const shown = underPartialView(view, outcome);
    // The findings this run REPORTED go to the machine-readable sink as the
    // check's own structured records. Without this the sink only ever saw the
    // prose printed below, because the check's records were consumed by the
    // nested capture above (see `runWithBaseline`).
    try sinkReported(ctx.allocator, check_name, .{
        .records = records,
        .keyed = violations,
        .captured = captured,
    }, shown);
    return reportOutcome(check_name, shown, may_write);
}

/// Where a reported line's structured detail comes from: the check's own
/// records (index-aligned with `keyed`, which was rendered from them) plus its
/// captured prose, the fallback for a check that reports text only.
const SinkSource = struct {
    records: []const reporter.Violation,
    keyed: []const Keyed,
    captured: []const u8,

    /// The record behind one reported line, or null for a check whose findings
    /// were scraped rather than emitted (no records to align against).
    fn recordFor(self: SinkSource, line: []const u8) ?reporter.Violation {
        if (self.records.len != self.keyed.len) return null;
        for (self.keyed, self.records) |k, v| {
            if (std.mem.eql(u8, k.line, line)) return v;
        }
        return null;
    }
};

/// Forwards the violations this run reported — the ones beyond the baseline —
/// to the JSONL sink, so `last-run.jsonl` carries file/line/metric/fix_hint for
/// a baselined check instead of the scraped summary text. Only reported
/// findings are forwarded: grandfathered debt is not what this run flagged, and
/// the sink's rows have always meant "what the run reported".
///
/// `a` must outlive this check's baseline arena and the inner capture (the run
/// allocator), because the sink is serialized after every check has finished.
fn sinkReported(
    a: Allocator,
    check_name: []const u8,
    src: SinkSource,
    outcome: Outcome,
) Allocator.Error!void {
    const lines = switch (outcome) {
        .grown => |g| g.new_lines,
        .migration_blocked => |m| m.lines,
        else => return,
    };
    const hint = if (firstFixHint(src.captured)) |h| try a.dupe(u8, h) else null;
    for (lines) |line| {
        if (src.recordFor(line)) |v| {
            // The check's own `fix:` line, captured with its findings, is the
            // remedy for any record that carries none of its own.
            var row = v;
            if (row.fix_hint == null) row.fix_hint = sink.hintText(hint);
            reporter.sink(row);
            continue;
        }
        reporter.sink(sink.scrapedRecord(check_name, try a.dupe(u8, line), hint));
    }
}

/// The view this check ran under: `partial` when a diff-scoped run handed it
/// only the changed files (run_all narrows the marker per check), `whole_tree`
/// otherwise.
fn viewFor(ctx: *const types.RunCtx) scope.View {
    return if (ctx.scoped == null) .whole_tree else .partial;
}

/// Reinterprets a v3 identity-baseline outcome for a partial view. A check that
/// read only the changed files cannot tell a *resolved* violation from one that
/// is merely out of scope, so a pure shrink is reported as a match against the
/// recorded size — never as resolved work, and (with write_allowed already
/// forced false) never pruned. `grown` is untouched: a new violation in a file
/// the run DID read fails exactly as it would whole-tree.
fn underPartialView(view: scope.View, outcome: Outcome) Outcome {
    if (view == .whole_tree) return outcome;
    return switch (outcome) {
        .shrunk => |s| .{ .matched = s.remaining + s.removed },
        else => outcome,
    };
}

/// The ratchet twin of `underPartialView`: an `improved` verdict from a partial
/// view may be nothing but out-of-scope keys vanishing, so it is reported as a
/// match. `regressed` still fails — a raised value or a new offender in a file
/// the run read is real.
fn ratchetUnderPartialView(view: scope.View, outcome: ratchet.Outcome) ratchet.Outcome {
    if (view == .whole_tree) return outcome;
    return switch (outcome) {
        // A relocation survives the reinterpretation: only git's whole-tree
        // rename detection can produce one under a partial view, so the move is
        // real even though the lower/prune counts beside it are not.
        .improved => |i| if (i.moved > 0) .{ .improved = .{
            .lowered = 0,
            .pruned = 0,
            .remaining = i.remaining + i.pruned,
            .moved = i.moved,
        } } else .{ .matched = i.remaining + i.pruned },
        else => outcome,
    };
}

/// How many files this check's stored baseline/ratchet names that are missing
/// from the working tree AND gitignored — i.e. generated inputs this worktree
/// has never built. Non-zero means the run sees only part of the tree the
/// metadata describes; it reports the skip and the caller stops writing.
/// Best-effort: an unreadable/absent metadata file means nothing to compare.
fn storedPhantoms(a: Allocator, ctx: *types.RunCtx, check_name: []const u8) Allocator.Error!usize {
    const path = try pathFor(a, ctx.project_dir, check_name);
    const raw = fs.cwd().readFileAlloc(a, path, max_baseline_bytes) catch return 0;
    var candidates: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (missing_inputs.pathFromStoredKey(line)) |p| try candidates.append(a, p);
    }
    if (candidates.items.len == 0) return 0;
    const phantoms = try missing_inputs.phantomPaths(a, ctx.project_dir, candidates.items);
    if (phantoms.len == 0) return 0;
    try noticeStoredPhantom(a, check_name, phantoms);
    return phantoms.len;
}

/// Reports a partial-view worktree through the advisory channel: what is
/// unreadable, why the run will not rewrite this check's metadata, and the
/// one-line fix. Never a violation record, so it can neither block nor accept.
fn noticeStoredPhantom(
    a: Allocator,
    check_name: []const u8,
    phantoms: []const []const u8,
) Allocator.Error!void {
    const message = try std.fmt.allocPrint(
        a,
        "{d} file(s) in the stored {s} metadata are missing here (e.g. {s}) — {s}; " ++
            "skipped, and this run will not prune or re-record {s}",
        .{ phantoms.len, check_name, phantoms[0], missing_inputs.hint, check_name },
    );
    reporter.warn(.{ .check = check_name, .message = message });
}

/// One check's findings split by whether their file can be read at all.
const PhantomScan = struct {
    /// Findings that still describe a readable (or non-file) subject.
    kept: []const Keyed,
    /// How many findings were dropped as unreadable generated output.
    skipped: usize,
};

/// Partitions `violations`, dropping the ones whose file is missing AND
/// gitignored, and reports the drop as a SKIP (never as debt). A deleted
/// tracked file is not gitignored, so its findings stay in `kept` and keep
/// failing the gate — this must never become a hole for a real removal.
fn scanPhantoms(
    a: Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    violations: []const Keyed,
) Allocator.Error!PhantomScan {
    var candidates: std.ArrayList([]const u8) = .empty;
    for (violations) |v| {
        if (missing_inputs.pathFromLine(v.line)) |p| try candidates.append(a, p);
    }
    if (candidates.items.len == 0) return .{ .kept = violations, .skipped = 0 };
    const phantoms = try missing_inputs.phantomPaths(a, ctx.project_dir, candidates.items);
    if (phantoms.len == 0) return .{ .kept = violations, .skipped = 0 };

    var kept: std.ArrayList(Keyed) = .empty;
    for (violations) |v| {
        const p = missing_inputs.pathFromLine(v.line) orelse {
            try kept.append(a, v);
            continue;
        };
        if (!missing_inputs.contains(phantoms, p)) try kept.append(a, v);
    }
    const skipped = violations.len - kept.items.len;
    try noticePhantom(a, check_name, skipped, phantoms);
    return .{ .kept = try kept.toOwnedSlice(a), .skipped = skipped };
}

/// Reports skipped-because-unreadable findings through the advisory channel:
/// always visible (even under --quiet, even inside baseline capture), never a
/// violation record, so nothing here can be counted or accepted.
fn noticePhantom(
    a: Allocator,
    check_name: []const u8,
    skipped: usize,
    phantoms: []const []const u8,
) Allocator.Error!void {
    if (skipped == 0) return;
    const message = try std.fmt.allocPrint(
        a,
        "{d} finding(s) skipped in {d} missing file(s) (e.g. {s}) — {s}; " ++
            "not counted, and this run will not rewrite {s} metadata",
        .{ skipped, phantoms.len, phantoms[0], missing_inputs.hint, check_name },
    );
    reporter.warn(.{ .check = check_name, .message = message });
}

/// Ratchet (baseline v2) path for a threshold check: aggregate its records to
/// one value per key, guard a deny_growth refresh, run the lifecycle, and report.
/// Asserts `check_name` is a threshold (ratchet) check — processOutcome only
/// dispatches here when `metricMode(check_name)` is non-null, which the two
/// `metricMode(check_name).?` unwraps below then rely on.
const RatchetInput = struct {
    captured: []const u8,
    records: []const reporter.Violation,
    warnings: []const reporter.Violation,
    force_refresh: bool,
    /// Gates the auto-lower / first-record / migrate writes: false on an
    /// ordinary run (report-only), true on accept/commit/migrate.
    write_allowed: bool,
};

/// The hysteresis standing of one check's run: the policy in force (null when
/// `[hysteresis]` does not bind this check, which restores plain ratchet
/// semantics everywhere below), what its reconciliation decided, and whether a
/// same-session accept note was found and deliberately not honored.
const Trip = struct {
    policy: ?hysteresis.Policy = null,
    plan: hysteresis.Plan = .{},
    session_note: bool = false,
};

fn processRatchet(
    a: std.mem.Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    input: RatchetInput,
) types.RunError!void {
    std.debug.assert(ratchet.metricMode(check_name) != null);
    const path = try pathFor(a, ctx.project_dir, check_name);
    const blocking = try ratchet.aggregate(a, input.records, ratchet.metricMode(check_name).?);
    // Relocation runs in two passes around the advisory merge: git's renames
    // first (they re-key entries whether or not anything reported), so a
    // preserved advisory entry is matched against the path its warning names,
    // then the content-matched extract tier against the reconciled set.
    const recorded = try readRecorded(a, path);
    const renamed = try relocation.renamedFiles(a, recorded orelse &.{}, try renamesFor(a, ctx, recorded));
    var trip: Trip = .{ .policy = hysteresis.policyFor(ctx.cfg, check_name) };
    const entries = if (trip.policy) |policy| blk: {
        // A tripped check reconciles against the ADVISORY records instead of
        // preserving its entries at their recorded value: below the hard cap
        // those warnings are the live measurement, so the ordinary classifier
        // then reads a shrink as an auto-lower and any growth as a regression.
        // It runs on a refresh too — an accept must not prune a trip.
        trip.plan = try hysteresis.reconcile(
            a,
            policy,
            renamed.entries,
            blocking,
            input.warnings,
            viewFor(ctx),
        );
        break :blk trip.plan.entries;
    } else try preserveAdvisoryRatchets(a, renamed.entries, blocking, input.warnings, input.force_refresh);
    const reloc = try relocation.extractedItems(a, renamed, entries, viewFor(ctx));
    const guard: GuardInput = .{
        .recorded = if (recorded == null) null else reloc.entries,
        .entries = entries,
        .force_refresh = input.force_refresh,
    };
    try ratchetDenyGrowthGuard(a, ctx, check_name, guard);
    try hysteresisRefreshGuard(check_name, trip, guard);

    const outcome = ratchet.lifecycle(a, path, entries, .{
        .force_refresh = input.force_refresh,
        .write_allowed = input.write_allowed,
        .transfers = reloc.transfers,
    }) catch |e| {
        reporter.fail("{s}: ratchet I/O failed: {s}", .{ check_name, @errorName(e) });
        return error.CheckFailed;
    };
    // Session accepts: an already-accepted check regrowing in the SAME
    // working session (no commit since the accept) re-accepts with a notice
    // instead of failing — the accept's intent was "this feature grows this
    // subject", and that intent holds until the commit locks the ratchet.
    // deny_growth still wins: a guarded check never rides a session note, and
    // neither does a tripped one (a note must not let a trip grow back).
    if (outcome == .regressed and accept_session.isPending(a, ctx.project_dir, check_name)) {
        if (trip.policy == null) return sessionReaccept(a, ctx, check_name, path, entries, .{
            .guard = guard,
            .write_allowed = input.write_allowed,
        });
        trip.session_note = true;
    }
    const shown = ratchetUnderPartialView(viewFor(ctx), outcome);
    // A hysteresis report cites recovery-zone keys, which were reported as
    // WARNINGS — their file, line and metric exist in no blocking record.
    const cited = if (trip.policy == null)
        input.records
    else
        try withAdvisory(a, input.records, input.warnings);
    // A regressed ratchet is the one blocking finding this path reports, so it
    // is what the sink must carry: the check's own record for each offending
    // key (file, line, metric) plus the ceiling it broke. Scraping the report
    // below instead is what left `last-run.jsonl` with no usable file-size row.
    if (shown == .regressed) try sinkRegressed(ctx.allocator, check_name, shown.regressed, cited, trip.policy);
    return reportRatchet(check_name, shown, .{
        .allocator = a,
        .fix_hint = firstFixHint(input.captured),
        .records = cited,
        .write_allowed = input.write_allowed,
        .reloc = reloc,
        .trip = trip,
    });
}

/// What `sessionReaccept` needs beyond the entries themselves: the guard input
/// deny_growth is re-checked with, and whether this run may persist the re-lock.
const SessionInput = struct {
    guard: GuardInput,
    write_allowed: bool,
};

/// Re-accepts a regression under this session's pending accept. On a
/// metadata-writable run the re-lock persists (commit locks the ratchet); on an
/// ordinary read-only run the growth is tolerated green but nothing is written
/// — the same read-only contract as every other lifecycle write.
fn sessionReaccept(
    a: std.mem.Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    path: []const u8,
    entries: []const ratchet.Entry,
    input: SessionInput,
) types.RunError!void {
    var guard = input.guard;
    guard.force_refresh = true;
    try ratchetDenyGrowthGuard(a, ctx, check_name, guard);
    if (!input.write_allowed) {
        reporter.ok(
            "{s}: ratchet growth tolerated under this session's pending accept (locks at commit)",
            .{check_name},
        );
        return;
    }
    const relocked = ratchet.lifecycle(a, path, entries, .{
        .force_refresh = true,
        .write_allowed = true,
    }) catch |e| {
        reporter.fail("{s}: ratchet I/O failed: {s}", .{ check_name, @errorName(e) });
        return error.CheckFailed;
    };
    reporter.ok(
        "{s}: ratchet re-accepted under this session's pending accept ({d} key(s); locked)",
        .{ check_name, relocked.refreshed },
    );
}

/// The records a report may cite for a tripped check: its blocking findings
/// plus every keyed advisory one. A recovery-zone key is measured by a WARNING,
/// so without this the offender line for one degrades to a bare ratchet key.
/// Alerts carry no ratchet key (by construction) and so are never cited.
fn withAdvisory(
    a: Allocator,
    records: []const reporter.Violation,
    warnings: []const reporter.Violation,
) Allocator.Error![]const reporter.Violation {
    var out: std.ArrayList(reporter.Violation) = .empty;
    try out.appendSlice(a, records);
    for (warnings) |w| {
        if (w.ratchet_key == null) continue;
        try out.append(a, w);
    }
    return out.toOwnedSlice(a);
}

/// Refuses a refresh of a tripped check that would record a hard-cap crossing
/// or raise a tripped ceiling — the two moves hysteresis exists to remove, and
/// the reason `accept` stopped being one env var away from a parked-at-103%
/// equilibrium. Everything else an accept does (a shrink, a prune, a
/// relocation) still goes through. Runs after `ratchetDenyGrowthGuard`, which
/// returns first when both apply, so a listed check never prints two refusals.
fn hysteresisRefreshGuard(
    check_name: []const u8,
    trip: Trip,
    in: GuardInput,
) types.RunError!void {
    if (!in.force_refresh) return;
    const policy = trip.policy orelse return;
    // Nothing recorded yet: first-record adoption grandfathers its offenders
    // (born tripped), exactly as it did before hysteresis.
    const old = in.recorded orelse return;
    const refusal = hysteresis.refusalFor(policy, old, in.entries) orelse return;
    const unit = ratchet.unitLabel(check_name);
    switch (refusal.kind) {
        .crossing => reporter.fail(
            "refusing to accept {s}: {s} is a hard-cap crossing at {d} {s} (hard cap {d}) — " ++
                "a crossing cannot be ratcheted; reduce it to <={d} to clear",
            .{ check_name, refusal.key, refusal.value, unit, policy.hard_cap, policy.recover },
        ),
        .raise => reporter.fail(
            "refusing to accept {s}: {s} would raise a tripped ceiling {d} -> {d} {s} — " ++
                "a tripped entry only ever shrinks (clears at <={d})",
            .{ check_name, refusal.key, refusal.ceiling, refusal.value, unit, policy.recover },
        ),
    }
    emitHysteresisRefusal(check_name);
    return error.CheckFailed;
}

/// The structured twin of the refusal above, so concise mode cannot collapse an
/// acceptance refusal to "no findings". Allocation-free for the same reason
/// `emitDenyGrowthDetail` is: the emitted record outlives this check's arena.
fn emitHysteresisRefusal(check_name: []const u8) void {
    reporter.emit(.{
        .check = check_name,
        .message = "acceptance refused because hysteresis holds this check's hard cap — " ++
            "a crossing or a ceiling raise cannot be recorded",
        .fix_hint = "shrink the subject to the recover line (`guardian-check debt . --live` prints it), " ++
            "or take the check out of [hysteresis] checks",
        .identity = "hysteresis-refusal",
    });
}

/// The v2 ratchet entries this check has on file, or null when there is no
/// readable one (absent, or still a v1 text baseline) — the two cases that are
/// not recorded debt at all, and that the lifecycle re-reads to tell apart.
/// Read once per check and shared by the relocation plan, the advisory-preserve
/// merge, and the deny_growth guard.
fn readRecorded(a: Allocator, path: []const u8) Allocator.Error!?[]const ratchet.Entry {
    // An unreadable file is "nothing recorded" — the lifecycle reads it again
    // and is the one place that decides create-vs-migrate. A failure to
    // ALLOCATE, though, is not an absent ratchet: it propagates.
    const snap = snapshot.read(a, path, ratchet.version) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return try ratchet.decodeLines(a, snap.lines);
}

/// Git's whole-file renames for this run. `all` resolves them once up front and
/// parks them on the context, because the per-check pass runs in parallel over
/// copied contexts and would otherwise spawn one git per ratchet check; a
/// single-check run has no such pass and resolves them here. A check with
/// nothing recorded has nothing to relocate, so it never asks git at all.
fn renamesFor(
    a: Allocator,
    ctx: *types.RunCtx,
    recorded: ?[]const ratchet.Entry,
) Allocator.Error![]const git.Rename {
    const none: []const git.Rename = &.{};
    if (recorded == null or recorded.?.len == 0) return none;
    if (ctx.renames) |resolved| return resolved;
    return git.renamesAgainst(a, ctx.project_dir, "HEAD");
}

/// Sends one sink row per regressed ratchet key. The row is the check's own
/// violation record (so it keeps file, line and the measured metric) with its
/// fix hint replaced by the ratchet's: the ceiling and the overshoot are the
/// numbers a reader needs here, and they exist nowhere in the check's own
/// message. `a` is the run allocator — the sink is written after every check
/// has finished, so the baseline arena's memory would already be gone.
fn sinkRegressed(
    a: Allocator,
    check_name: []const u8,
    reg: ratchet.Regression,
    records: []const reporter.Violation,
    policy: ?hysteresis.Policy,
) Allocator.Error!void {
    const unit = ratchet.unitLabel(check_name);
    // A tripped check has no accept to offer, so every row carries the one
    // remedy that exists: the recover target.
    if (policy) |p| {
        const hint = try hysteresis.fixHint(a, p, unit);
        for (reg.grown) |g| sinkRatchetKey(check_name, records, g.key, hint);
        for (reg.new_offenders) |o| sinkRatchetKey(check_name, records, o.key, hint);
        return;
    }
    for (reg.grown) |g| sinkRatchetKey(check_name, records, g.key, try std.fmt.allocPrint(
        a,
        "{d} {s} over its frozen ratchet ceiling of {d} — reduce it, or accept: `guardian-check accept {s} .` " ++
            "(or `zig build guardian-accept -Dguardian-checks={s}`)",
        .{ g.new - g.old, unit, g.old, check_name, check_name },
    ));
    for (reg.new_offenders) |o| sinkRatchetKey(check_name, records, o.key, try std.fmt.allocPrint(
        a,
        "a new offender at {d} {s} — reduce it below the cap, or accept: `guardian-check accept {s} .` " ++
            "(or `zig build guardian-accept -Dguardian-checks={s}`)",
        .{ o.value, unit, check_name, check_name },
    ));
}

/// One regressed key's sink row: the check's record for that key when it has
/// one, else a bare row naming the key so the sink still lists the offender.
fn sinkRatchetKey(
    check_name: []const u8,
    records: []const reporter.Violation,
    key: []const u8,
    hint: []const u8,
) void {
    if (recordForKey(records, key)) |v| {
        var row = v;
        row.fix_hint = hint;
        reporter.sink(row);
        return;
    }
    reporter.sink(.{ .check = check_name, .message = key, .ratchet_key = key, .fix_hint = hint });
}

/// Keeps a legacy ratchet entry while the same subject is still being reported
/// as advisory. Advisory findings never create or lower debt, but an upgrade
/// from a recommended-threshold ratchet to a warning/hard split must not erase
/// the committed entry merely because the finding moved out of the blocking
/// record set. Once the warning itself disappears, normal auto-pruning applies.
fn preserveAdvisoryRatchets(
    a: std.mem.Allocator,
    recorded: []const ratchet.Entry,
    blocking: []const ratchet.Entry,
    warnings: []const reporter.Violation,
    force_refresh: bool,
) types.RunError![]const ratchet.Entry {
    if (force_refresh or warnings.len == 0) return blocking;
    return mergeAdvisoryEntries(a, recorded, blocking, warnings);
}

fn mergeAdvisoryEntries(
    a: std.mem.Allocator,
    old: []const ratchet.Entry,
    blocking: []const ratchet.Entry,
    warnings: []const reporter.Violation,
) std.mem.Allocator.Error![]const ratchet.Entry {
    var merged: std.ArrayList(ratchet.Entry) = .empty;
    try merged.appendSlice(a, blocking);
    for (old) |entry| {
        if (entryPresent(blocking, entry.key)) continue;
        if (!warningPresent(warnings, entry.key)) continue;
        try merged.append(a, entry);
    }
    return merged.toOwnedSlice(a);
}

fn entryPresent(entries: []const ratchet.Entry, key: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.key, key)) return true;
    return false;
}

fn warningPresent(warnings: []const reporter.Violation, key: []const u8) bool {
    for (warnings) |warning| {
        const warning_key = warning.ratchet_key orelse continue;
        if (std.mem.eql(u8, warning_key, key)) return true;
    }
    return false;
}

/// What the deny_growth guard compares: the ratchet on file with this run's
/// relocations already applied (null when there is none to grow — a first
/// record or a v1 migration is not growth), and the state a refresh would
/// write. Comparing against the RELOCATED recording is what lets a listed check
/// still move an entry between keys: nothing grew, so nothing is denied.
const GuardInput = struct {
    recorded: ?[]const ratchet.Entry,
    entries: []const ratchet.Entry,
    force_refresh: bool,
};

/// deny_growth for a ratchet check: on a refresh of a listed check, refuse to
/// rewrite when the new state would raise any key's value or add a key.
fn ratchetDenyGrowthGuard(
    a: std.mem.Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    in: GuardInput,
) types.RunError!void {
    if (!in.force_refresh) return;
    if (!nameInList(ctx.cfg.baseline.deny_growth, check_name)) return;
    const old = in.recorded orelse return;
    if (!try ratchet.wouldGrow(a, old, in.entries)) return;
    reporter.fail(
        "refusing to refresh {s}: ratchet would raise a value or add a key; " ++
            "fix the regressions or remove {s} from deny_growth",
        .{ check_name, check_name },
    );
    const names = try ratchetGrowthNames(a, check_name, old, in.entries);
    reportGrowthNames(names);
    reportGrowthEscape(check_name);
    try emitDenyGrowthDetail(a, check_name, names);
    return error.CheckFailed;
}

/// The ratchet keys a refused refresh would raise or add, each rendered with
/// what changed about it. The ratchet twin of `growthNames`: without it the
/// refusal says only that *something* would grow, which is not enough to decide
/// whether lifting the policy is legitimate.
fn ratchetGrowthNames(
    a: std.mem.Allocator,
    check_name: []const u8,
    old: []const ratchet.Entry,
    new: []const ratchet.Entry,
) Allocator.Error![]const []const u8 {
    const reg = switch (try ratchet.classify(a, old, new)) {
        .regressed => |r| r,
        else => return &.{},
    };
    const unit = ratchet.unitLabel(check_name);
    var names: std.ArrayList([]const u8) = .empty;
    for (reg.grown) |g| try names.append(a, try std.fmt.allocPrint(
        a,
        "{s} ({d} -> {d} {s})",
        .{ g.key, g.old, g.new, unit },
    ));
    for (reg.new_offenders) |o| try names.append(a, try std.fmt.allocPrint(
        a,
        "{s} (a new key at {d} {s})",
        .{ o.key, o.value, unit },
    ));
    return names.toOwnedSlice(a);
}

/// What `reportRatchet` needs beyond the outcome itself: the run allocator (for
/// rendering an offender line), the check's own scraped fix hint, its structured
/// violation records — the source of the file:line and cap text a regression
/// line inlines — and whether this run may persist metadata.
const RatchetReport = struct {
    allocator: std.mem.Allocator,
    fix_hint: ?[]const u8,
    records: []const reporter.Violation,
    write_allowed: bool,
    /// What this run recognized as relocation rather than new debt.
    reloc: relocation.Plan = .{},
    /// What hysteresis made of this run (no policy = plain ratchet wording).
    trip: Trip = .{},
};

/// Reports a ratchet outcome, then every entry it re-keyed or un-tripped. Both
/// print UNDER the verdict — for a regression too, where the relocations and
/// recoveries that did resolve are exactly the context for what did not.
fn reportRatchet(check_name: []const u8, outcome: ratchet.Outcome, rep: RatchetReport) types.RunError!void {
    const verdict = reportVerdict(check_name, outcome, rep);
    for (rep.reloc.moved) |m| {
        if (m.item.len == 0)
            reporter.detail("  moved: {s} -> {s}\n", .{ m.from, m.to })
        else
            reporter.detail("  moved: {s} -> {s} :: {s}\n", .{ m.from, m.to, m.item });
    }
    reportRecovered(check_name, rep);
    return verdict;
}

/// Names every trip this run cleared. A recovery is the one event that ENDS a
/// hysteresis entry's life, so it is said out loud rather than folded into the
/// `N pruned` count — the reader has been shrinking toward this line.
fn reportRecovered(check_name: []const u8, rep: RatchetReport) void {
    const unit = ratchet.unitLabel(check_name);
    for (rep.trip.plan.recovered) |rec| {
        const line = hysteresis.recoveredLine(rep.allocator, rec, unit) catch continue;
        reporter.detail("  recovered: {s}\n", .{line});
    }
}

/// The verdict half of `reportRatchet`; `regressed` prints each grown /
/// new-offender key (with the check's own fix hint, scraped from its captured
/// output) and fails.
fn reportVerdict(check_name: []const u8, outcome: ratchet.Outcome, rep: RatchetReport) types.RunError!void {
    const write_allowed = rep.write_allowed;
    // On a read-only run the create/migrate/improve outcomes were classified but
    // not persisted — word them as pending, all green.
    if (!write_allowed) switch (outcome) {
        // "no ratchet exists" rather than "grandfathered": a first run says in
        // words that it is RECORDING a starting set, so a deliberate probe of a
        // new rule cannot read as an established, matched ratchet.
        .created => |n| {
            reporter.ok(
                "ok: {s}: no ratchet exists — {d} key(s) would be recorded as the starting set " ++
                    "(`--list` to see them; `guardian-check accept {s} .` to record)",
                .{ check_name, n, check_name },
            );
            return;
        },
        .migrated => |n| {
            reporter.ok("ok: {s}: legacy ratchet format ({d} key(s); run `guardian-check migrate .` to re-key)", .{ check_name, n });
            return;
        },
        .improved => |imp| return reportPendingImproved(check_name, imp),
        else => {},
    };
    switch (outcome) {
        .created => |n| reporter.ok(
            "{s}: no ratchet existed — recording {d} key(s) as the starting set",
            .{ check_name, n },
        ),
        .migrated => |n| reporter.ok("{s}: migrated to per-item ratchet ({d} key(s))", .{ check_name, n }),
        .matched => |n| reporter.ok("ok: {s}: ratchet matches ({d} key(s))", .{ check_name, n }),
        .improved => |imp| if (imp.moved > 0) reporter.ok(
            "{s}: {d} ratchet(s) moved, {d} lowered, {d} pruned (now {d} key(s))",
            .{ check_name, imp.moved, imp.lowered, imp.pruned, imp.remaining },
        ) else reporter.ok(
            "{s}: {d} ratchet(s) lowered, {d} pruned (now {d} key(s))",
            .{ check_name, imp.lowered, imp.pruned, imp.remaining },
        ),
        .refreshed => |n| reporter.ok("{s}: ratchet refreshed ({d} key(s))", .{ check_name, n }),
        .regressed => |reg| return reportRegressed(check_name, reg, rep),
    }
}

/// The read-only wording for an improvement: classified, not written. A
/// relocation is pending in exactly the same sense — the entry re-keys in
/// memory so the gate stays green, and `accept` is what records it.
fn reportPendingImproved(check_name: []const u8, imp: ratchet.Improved) void {
    if (imp.moved > 0) {
        reporter.ok(
            "ok: {s}: {d} moved, {d} lowered, {d} prunable (run `guardian-check accept {s} .` to record)",
            .{ check_name, imp.moved, imp.lowered, imp.pruned, check_name },
        );
        return;
    }
    reporter.ok(
        "ok: {s}: {d} lowered, {d} prunable (run `guardian-check accept {s} .` to record)",
        .{ check_name, imp.lowered, imp.pruned, check_name },
    );
}

/// The check's own violation record for ratchet key `key` — the record carries
/// the file, line, and the message naming the metric and its cap, which the
/// regression report inlines so the console says as much as last-run.jsonl.
fn recordForKey(records: []const reporter.Violation, key: []const u8) ?reporter.Violation {
    for (records) |v| {
        const rk = v.ratchet_key orelse continue;
        if (std.mem.eql(u8, rk, key)) return v;
    }
    return null;
}

/// `file:line: message` for the first regressed key (grown keys first, then new
/// offenders), or the bare key when the check emitted no structured record for
/// it. This is what turns "a shape check failed" into "which function, where,
/// what value, what cap" without leaving the terminal.
fn firstOffender(a: std.mem.Allocator, reg: ratchet.Regression, records: []const reporter.Violation) []const u8 {
    const key = if (reg.grown.len > 0)
        reg.grown[0].key
    else if (reg.new_offenders.len > 0)
        reg.new_offenders[0].key
    else
        return "";
    const v = recordForKey(records, key) orelse return key;
    return reporter.flatLine(a, v) catch key;
}

/// The failing half of `reportRatchet`, worded by growth class and by whether
/// accepting would RAISE a frozen ceiling. A `volume` check (file/type size)
/// whose regression is only new offenders usually grew because a feature
/// landed, so the accept guidance leads; a `shape` regression, and any
/// regression that would raise a ceiling, lead with the fix instead — raising a
/// frozen ceiling is not an ordinary option (see `AcceptTone`).
fn reportRegressed(check_name: []const u8, reg: ratchet.Regression, rep: RatchetReport) types.RunError!void {
    if (rep.trip.policy) |policy| return reportTripped(check_name, reg, rep, policy);
    const n = reg.grown.len + reg.new_offenders.len;
    const class = ratchet.growthClass(check_name);
    const tone = toneFor(reg);
    // The status line names the offender itself — file:line, the item, the
    // measured value and its cap — not just the check. Without it the only
    // place with that detail was .guardian/cache/last-run.jsonl.
    const offender = firstOffender(rep.allocator, reg, rep.records);
    switch (headlineFor(class, tone)) {
        .raise => reporter.fail(
            "{s}: {d} key(s) grew past a frozen ratchet ceiling — {s}",
            .{ check_name, n, offender },
        ),
        .volume => reporter.fail(
            "{s}: {d} key(s) grew past ratchet — volume growth; review, then accept if intended — {s}",
            .{ check_name, n, offender },
        ),
        .shape => reporter.fail("{s}: {d} key(s) regressed above ratchet — {s}", .{ check_name, n, offender }),
    }
    // Name the metric's unit (ratchet.unitLabel) so a bare number reads as
    // "8 params" / "8 fields" / "3 over-length lines" instead of leaving the
    // reader to guess what was measured.
    const unit = ratchet.unitLabel(check_name);
    for (reg.grown) |g| reporter.detail(
        "  {s}: {s} grew {d} -> {d} {s} (frozen ratchet ceiling was {d})\n",
        .{ check_name, g.key, g.old, g.new, unit, g.old },
    );
    for (reg.new_offenders) |o| reporter.detail(
        "  {s}: {s} — {d} {s}, a new offender at or above the cap (accept to ratchet, or reduce)\n",
        .{ check_name, o.key, o.value, unit },
    );
    // A new offender that LOOKS relocated says so on the spot: the reader's
    // next question is always "wasn't this already baselined somewhere?", and
    // the answer is a lookup they would otherwise do by hand.
    reportUnresolvedMoves(check_name, rep);
    // A ratchet freezes each item at the value it recorded, so a key that grew
    // had ZERO headroom — it was sitting exactly at its own cap and the change
    // tipped it over, with no baseline escape. That is invisible from the
    // numbers alone (a reader sees "17 -> 18 fields", not "17 was the ceiling"),
    // so say it: the fix is to reduce or split, never to raise the cap.
    if (atFrozenCap(reg)) reporter.detail(
        "  this item is at its frozen cap; reduce or split before adding.\n",
        .{},
    );
    switch (guidanceOrder(class, tone)) {
        .accept_first => {
            reportAcceptCommand(check_name, tone);
            if (rep.fix_hint) |h| reporter.detail("  {s} (if the growth is accidental)\n", .{h});
        },
        .fix_first => {
            if (rep.fix_hint) |h| reporter.detail("  {s}\n", .{h});
            reportAcceptCommand(check_name, tone);
        },
    }
    return error.CheckFailed;
}

/// The failing half for a check hysteresis binds. It differs from
/// `reportRegressed` in exactly one way that matters: there is no accept
/// command anywhere in it. A hard-cap crossing and a raise of a tripped ceiling
/// are both unacceptable by policy, so every line leads with the number that
/// clears the trip instead of the command that would ratify it.
fn reportTripped(
    check_name: []const u8,
    reg: ratchet.Regression,
    rep: RatchetReport,
    policy: hysteresis.Policy,
) types.RunError!void {
    const n = reg.grown.len + reg.new_offenders.len;
    reporter.fail(
        "{s}: {d} key(s) held by a hard-cap trip — {s}",
        .{ check_name, n, firstOffender(rep.allocator, reg, rep.records) },
    );
    const unit = ratchet.unitLabel(check_name);
    for (reg.grown) |g| reporter.detail("  {s}\n", .{trippedDetail(rep, policy, g, unit)});
    for (reg.new_offenders) |o| reporter.detail("  {s}\n", .{
        hysteresis.crossingDetail(rep.allocator, policy, o.key, o.value, unit) catch o.key,
    });
    reportUnresolvedMoves(check_name, rep);
    // A pending session accept covers ordinary ratchet growth, never a trip —
    // say so, or the note's absence reads as the note having failed.
    if (rep.trip.session_note) reporter.detail(
        "  note: this session's pending accept does not cover a hard-cap trip; only a shrink clears it.\n",
        .{},
    );
    if (rep.fix_hint) |h| reporter.detail("  {s}\n", .{h});
    reporter.detail("  {s}\n", .{hysteresis.policyNote(rep.allocator, policy) catch check_name});
    return error.CheckFailed;
}

/// One grown key's line, worded by which side of the hard cap it grew on: over
/// the cap it is a ceiling that may not be raised, under it a recovery the
/// growth interrupted. Rendering failures fall back to the bare key rather than
/// propagating — this is detail beneath a failure that already stands alone.
fn trippedDetail(
    rep: RatchetReport,
    policy: hysteresis.Policy,
    grown: ratchet.GrownKey,
    unit: []const u8,
) []const u8 {
    if (rep.trip.plan.recoveringCeiling(grown.key) != null) {
        return hysteresis.recoveringDetail(rep.allocator, policy, grown.key, grown, unit) catch grown.key;
    }
    return hysteresis.overCapDetail(rep.allocator, policy, grown.key, grown, unit) catch grown.key;
}

/// Names the recorded entry behind every new key this run refused to treat as a
/// relocation (see relocation.zig for the three refusals). Rendering failures
/// are dropped rather than propagated: this is guidance printed alongside a
/// failure that already stands on its own.
fn reportUnresolvedMoves(check_name: []const u8, rep: RatchetReport) void {
    for (rep.reloc.unresolved) |u| {
        const hint = relocation.hintText(rep.allocator, check_name, u) catch continue;
        reporter.detail("  {s}: {s}\n", .{ u.key, hint });
    }
}

/// Whether accepting this regression would RAISE a frozen ceiling (`raises`) or
/// only record a subject the ratchet never held (`plain`). The distinction is
/// the whole point: lowering or pruning a ceiling is always fine and reads as a
/// routine accept, while raising one is the move a project's own rules usually
/// forbid — so the two must not share a tone.
const AcceptTone = enum { plain, raises };

/// A grown key is one the ratchet froze at exactly its current value, so the
/// only way to accept it is to raise that ceiling. A regression made only of
/// new offenders raises nothing — those keys were never on file.
fn toneFor(reg: ratchet.Regression) AcceptTone {
    return if (atFrozenCap(reg)) .raises else .plain;
}

/// Which status line the regression gets. A ceiling-raising regression is
/// named as such whatever its growth class; otherwise the class decides.
const Headline = enum { raise, volume, shape };

fn headlineFor(class: ratchet.GrowthClass, tone: AcceptTone) Headline {
    if (tone == .raises) return .raise;
    return switch (class) {
        .volume => .volume,
        .shape => .shape,
    };
}

/// Which guidance leads. Volume growth that ratifies a brand-new offender
/// leads with accept (it is usually the right call); everything else leads with
/// the fix, because raising a frozen ceiling should be the last thing a reader
/// reaches, not the first.
const GuidanceOrder = enum { accept_first, fix_first };

fn guidanceOrder(class: ratchet.GrowthClass, tone: AcceptTone) GuidanceOrder {
    if (tone == .raises) return .fix_first;
    return switch (class) {
        .volume => .accept_first,
        .shape => .fix_first,
    };
}

/// True when a regression includes a key that GREW — i.e. an item that was
/// frozen at exactly its own current value, leaving no room to add. A
/// regression made only of new offenders is different: those tripped the
/// check's default cap and were never ratcheted, so the at-cap note would
/// misdescribe them.
fn atFrozenCap(reg: ratchet.Regression) bool {
    return reg.grown.len > 0;
}

/// The first `fix:` hint line in a check's captured output (dedented), or null.
/// Reuses the check's own hint text for the ratchet regression message instead
/// of duplicating it in a table. Public so the JSONL sink can attach the same
/// hint to the rows it scrapes from a prose-reporting check's output — one
/// definition of "where a check's fix hint lives", shared by both readers.
pub fn firstFixHint(captured: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, captured, '\n');
    while (it.next()) |raw| {
        const trimmed = leftTrim(raw);
        if (std.mem.startsWith(u8, trimmed, "fix:")) return trimmed;
    }
    return null;
}

/// How many offending keys a deny_growth refusal names before collapsing to a
/// `(+N more)` tail. Bounded because a refusal on a wide new rule can involve
/// hundreds of rows and the point is to make the growth *identifiable*, not to
/// reprint the baseline.
const max_listed_growth: usize = 10;

/// Fails the run when `check_name` is in `[baseline] deny_growth` and a refresh
/// would grow its baseline. Only fires on the refresh path; an existing
/// baseline is required (initial creation is not "growth"). A no-op otherwise.
fn denyGrowthGuard(
    arena: Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    path: []const u8,
    violations: []const Keyed,
    force_refresh: bool,
) types.RunError!void {
    const old_count = baselineViolationCount(arena, path);
    if (!growthDenied(ctx.cfg.baseline.deny_growth, check_name, old_count, violations.len, force_refresh)) return;
    reporter.fail(
        "refusing to refresh {s}: baseline would grow {d}→{d}; " ++
            "fix the new violations or remove {s} from deny_growth",
        .{ check_name, old_count.?, violations.len, check_name },
    );
    const names = try growthNames(arena, path, violations);
    reportGrowthNames(names);
    reportGrowthEscape(check_name);
    try emitDenyGrowthDetail(arena, check_name, names);
    return error.CheckFailed;
}

/// The identity keys a refused refresh would ADD. Returned rather than printed
/// because the same set has to ride BOTH channels — the bounded detail block and
/// the structured record concise `accept` output replays — and a refusal that
/// names its keys on only one of them names them to only half its readers.
/// Best-effort on the read: an unreadable baseline just yields no names.
fn growthNames(arena: Allocator, path: []const u8, violations: []const Keyed) Allocator.Error![]const []const u8 {
    const snap = snapshot.read(arena, path, version) catch return &.{};
    const parts = try splitAgainst(arena, snap.lines, violations);
    const out = try arena.alloc([]const u8, parts.added.len);
    for (parts.added, 0..) |k, i| out[i] = k.key;
    return out;
}

/// Names what a refusal would record, bounded. The refusal used to print only a
/// count, so a reader could not tell a deliberately declared new rule from an
/// accidental regression without re-deriving the diff by hand — which is the
/// whole cost this removes.
fn reportGrowthNames(names: []const []const u8) void {
    if (names.len == 0) return;
    reporter.detail("  {d} key(s) would be added or raised:\n", .{names.len});
    for (names, 0..) |n, i| {
        if (i == max_listed_growth) {
            reporter.detail("    (+{d} more)\n", .{names.len - max_listed_growth});
            break;
        }
        reporter.detail("    {s}\n", .{n});
    }
}

/// The sanctioned way out for a DELIBERATELY declared new rule, named at the
/// point of failure. The two-step is defensible policy, but an agent meeting the
/// refusal cold cannot tell it from "you are being told no", and editing
/// guardian.toml unprompted reads as gate-tampering rather than as the
/// documented path — so the refusal has to say which it is.
fn reportGrowthEscape(check_name: []const u8) void {
    reporter.detail(
        "  if this growth is a deliberately DECLARED new rule (not a regression), the sanctioned two-step is:\n" ++
            "    1. remove \"{s}\" from [baseline] deny_growth in guardian.toml\n" ++
            "    2. guardian-check accept {s} .\n" ++
            "    3. restore the deny_growth entry, in the same commit\n",
        .{ check_name, check_name },
    );
}

/// A structured copy of the policy reason. `run-all` keeps structured records in
/// concise mode, so an `accept` refusal can never collapse to "zero findings /
/// no structured detail" while its useful prose is hidden behind `--verbose` —
/// which is why the offending keys are named HERE too and not only in the
/// detail block above.
fn emitDenyGrowthDetail(
    arena: Allocator,
    check_name: []const u8,
    names: []const []const u8,
) Allocator.Error!void {
    reporter.emit(.{
        .check = check_name,
        .message = try refusalMessage(arena, names),
        .fix_hint = "fix the new violations, or — for a deliberately declared new rule — remove this check " ++
            "from [baseline] deny_growth, run the accept, and restore the entry in the same commit",
        .identity = "deny-growth-refusal",
    });
}

/// The frozen half of the refusal message. Split out so the identity-keyed
/// record keeps one reason string whether or not any key could be named.
const refusal_reason = "acceptance refused because the configured deny_growth policy would grow recorded debt";

/// How many keys the one-line refusal record names inline. Short, because it
/// rides a summary line; the full bounded list is in the detail block.
const max_named_growth: usize = 3;

/// The refusal line with a bounded sample of the keys it refuses appended.
/// Concise output replays this record rather than the detail block, so a
/// refusal that names nothing here names nothing at all to the reader who did
/// not think to add `--verbose`.
fn refusalMessage(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    if (names.len == 0) return refusal_reason;
    const shown = @min(names.len, max_named_growth);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, refusal_reason ++ ": ");
    for (names[0..shown], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, n);
    }
    if (names.len > shown) try buf.appendSlice(
        arena,
        try std.fmt.allocPrint(arena, " (+{d} more)", .{names.len - shown}),
    );
    return buf.toOwnedSlice(arena);
}

/// Pure decision for denyGrowthGuard: a refresh of a deny_growth check with an
/// existing baseline is denied exactly when the new count exceeds the old.
/// `old_count` is null when no baseline exists yet — initial creation is never
/// "growth", so it is always allowed.
fn growthDenied(
    deny_list: []const []const u8,
    check_name: []const u8,
    old_count: ?usize,
    new_count: usize,
    force_refresh: bool,
) bool {
    if (!force_refresh) return false;
    if (!nameInList(deny_list, check_name)) return false;
    const oc = old_count orelse return false;
    return new_count > oc;
}

/// Current recorded violation count in a baseline file, or null when it is
/// absent/unreadable (so initial creation isn't treated as growth).
fn baselineViolationCount(arena: Allocator, path: []const u8) ?usize {
    const snap = snapshot.read(arena, path, version) catch return null;
    return snap.lines.len;
}

/// True when `name` appears in `list`.
fn nameInList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn reportOutcome(check_name: []const u8, outcome: Outcome, write_allowed: bool) types.RunError!void {
    // On a read-only run the create/prune/re-key outcomes were classified but
    // NOT persisted, so word them as pending rather than as done — an honest
    // "run accept to record it" instead of a "baselined/pruned/re-keyed" that
    // never touched disk. All stay green.
    if (!write_allowed) switch (outcome) {
        // A CREATION must not read like a match. `grandfathered` said only that
        // the findings were accepted, so a deliberate probe of a brand-new
        // [[ban]] / [[concept]] rule — the run where "did my rule fire?" is the
        // whole question — was indistinguishable from an established baseline
        // holding steady. Say instead that there is no baseline yet and that
        // these N findings are what would be frozen.
        .created => |n| {
            reporter.ok(
                "ok: {s}: no baseline exists — {d} violation(s) would be recorded as the starting set " ++
                    "(`--list` to see them; `guardian-check accept {s} .` to record)",
                .{ check_name, n, check_name },
            );
            return;
        },
        .shrunk => |s| {
            reporter.ok("ok: {s}: {d} resolved (run `guardian-check accept {s} .` to prune the baseline)", .{ check_name, s.removed, check_name });
            return;
        },
        .migrated => |n| {
            reporter.ok("ok: {s}: legacy baseline format ({d} violation(s); run `guardian-check migrate .` to re-key)", .{ check_name, n });
            return;
        },
        else => {},
    };
    switch (outcome) {
        .created => |n| reporter.ok(
            "{s}: no baseline existed — recording {d} violation(s) as the starting set",
            .{ check_name, n },
        ),
        .matched => |n| reporter.ok("ok: {s}: baseline matches ({d} violation(s))", .{ check_name, n }),
        .shrunk => |s| reporter.ok(
            "{s}: {d} resolved, baseline pruned (now {d})",
            .{ check_name, s.removed, s.remaining },
        ),
        .refreshed => |n| reporter.ok("{s}: baseline refreshed ({d} violation(s))", .{ check_name, n }),
        .migrated => |n| reporter.ok(
            "{s}: baseline re-keyed to stable identities ({d} violation(s); commit .guardian/)",
            .{ check_name, n },
        ),
        .migration_blocked => |m| {
            reporter.fail(
                "{s}: cannot re-key the legacy baseline — a file now holds more violations " ++
                    "than its {d} recorded entries grandfathered",
                .{ check_name, m.baseline_size },
            );
            // The new violation can't be singled out after a re-key, so show the
            // whole affected file(s) and say so, rather than implying all are new.
            reporter.detail("  one or more of these is new debt:\n", .{});
            for (m.lines) |line| reporter.detail("    {s}\n", .{line});
            // An identity baseline records violations, not per-item ceilings:
            // accepting adds a key, it never raises a frozen number.
            reportAcceptCommand(check_name, .plain);
            return error.CheckFailed;
        },
        .grown => |g| {
            reporter.fail(
                "{s}: {d} new violation(s) above baseline of {d}",
                .{ check_name, g.new_lines.len, g.baseline_size },
            );
            for (g.new_lines) |line| reporter.detail("  {s}\n", .{line});
            reportAcceptCommand(check_name, .plain);
            return error.CheckFailed;
        },
    }
}

/// Prints both accept forms after a baseline/ratchet failure (C4). Raw CLI
/// leads because it always works; the `guardian-accept` build step exists only
/// when the consumer's build wired it, so it is qualified rather than assumed.
/// Keeps the `accept:` marker `reportRegressed` orders against the `fix:` hint.
///
/// A `.raises` tone prefixes the commands with what accepting them would do.
/// Without it the accept line reads as a normal option in exactly the case a
/// project's own rules forbid — raising a frozen ceiling — while a tightening
/// (a lowered or pruned key, which never reaches this path) is always fine.
fn reportAcceptCommand(check_name: []const u8, tone: AcceptTone) void {
    if (tone == .raises) reporter.detail(
        "  this raises a frozen ceiling — prefer moving code to a cohesive module boundary; " ++
            "accept only when the larger item is genuinely the right shape.\n",
        .{},
    );
    reporter.detail("  accept: guardian-check accept {s} .   # raw CLI, always works\n", .{check_name});
    reporter.detail(
        "          zig build guardian-accept -Dguardian-checks={s}   # if your build wires guardian-accept\n",
        .{check_name},
    );
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── Tests ──────────────────────────────────────────────────────────────

fn deleteIfExists(path: []const u8) void {
    fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) }),
    };
}

/// The threshold check every ratchet/hysteresis test below drives. Named once:
/// spelled inline it is both a repeated literal and (with the same name and
/// value in the check's own file) a cross-file duplicate const.
const size_check = "file-size";

/// The over-cap file the ratchet/hysteresis fixtures below drive through the
/// lifecycle, named for the same reason `size_check` is.
const trip_subject = "src/big.zig";

/// Test helper: keys plain violation lines the way an unmigrated (prose) check's
/// scraped output is keyed, so lifecycle tests can work in readable text.
fn keyedLines(arena: Allocator, check_name: []const u8, lines: []const []const u8) Allocator.Error![]const Keyed {
    const out = try arena.alloc(Keyed, lines.len);
    for (lines, 0..) |l, i| out[i] = .{ .key = try violation_key.fromLine(arena, check_name, l), .line = l };
    return out;
}

// spec: Baseline Mode - Captures each check's current violations on first run and only fails on additions
// spec: Baseline Mode - Wraps a single check run with capture, diff, and outcome reporting

// spec: Baseline Mode - Prefers structured records over scraped text when present

test "keyedViolations renders records when present and scrapes text otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // With structured records, the keys and lines come from the records — the
    // captured prose (here a decoy indented line) is ignored, proving the
    // baseline no longer re-parses a migrated check's output.
    const records = [_]reporter.Violation{
        .{ .check = "function-length", .file = "src/x.zig", .line = 5, .message = "fn foo is 246 lines (cap 200)" },
    };
    const from_records = try keyedViolations(a, "function-length", "guardian: FAILED\n  DECOY TEXT\n", &records);
    try std.testing.expectEqual(@as(usize, 1), from_records.len);
    try std.testing.expectEqualStrings("src/x.zig:5: fn foo is 246 lines (cap 200)", from_records[0].line);
    // The stored key drops the line number and the measured/cap numbers.
    try std.testing.expectEqualStrings(
        "function-length|src/x.zig|fn foo is # lines (cap #)",
        from_records[0].key,
    );

    // With no records (an unmigrated check), it falls back to scraping the text
    // and keys the scraped line the same way.
    const from_text = try keyedViolations(a, "ban-fs", "guardian: ban-fs FAILED\n  src/y.zig:8: bad\n", &.{});
    try std.testing.expectEqual(@as(usize, 1), from_text.len);
    try std.testing.expectEqualStrings("src/y.zig:8: bad", from_text[0].line);
    try std.testing.expectEqualStrings("ban-fs|src/y.zig|bad", from_text[0].key);
}

fn warningOnly(_: *types.RunCtx) types.RunError!void {
    reporter.warn(.{
        .check = size_check,
        .file = "src/x.zig",
        .message = "1200 lines (recommended 1000; hard limit 10000)",
    });
}

test "runWithBaseline replays warnings without ratcheting them" {
    const dir = "zig-cache/test-baseline-warning";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir);

    const cfg: @import("config.zig").Config = .{ .baseline = .{ .enabled = true } };
    // metadata_writable so the (empty) ratchet is actually recorded — the test
    // asserts warnings add zero ratchet debt even on a writing run.
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = dir,
        .cfg = &cfg,
        .quiet = true,
        .metadata_writable = true,
    };
    var outer: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer outer.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &outer;

    try runWithBaseline(&ctx, .{
        .name = "file-size",
        .summary = "test",
        .scope = .per_file,
        .run = warningOnly,
    });
    try std.testing.expectEqual(@as(usize, 1), outer.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), outer.records.items.len);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const snap = try snapshot.read(
        arena.allocator(),
        try pathFor(arena.allocator(), dir, "file-size"),
        ratchet.version,
    );
    try std.testing.expectEqual(@as(usize, 0), snap.lines.len);
}

/// A file-size run over the hard limit: one structured record carrying the
/// file, the measured line count and the ratchet key — the exact shape the real
/// check emits, and the one the sink was losing under baseline mode.
fn fileSizeOverHardLimit(_: *types.RunCtx) types.RunError!void {
    reporter.emit(.{
        .check = size_check,
        .file = trip_subject,
        .message = "10 code lines (hard limit: 5)",
        .ratchet_key = trip_subject,
        .metric = 10,
    });
    return error.CheckFailed;
}

// spec: Per-Item Ratchets - Sends each regressed key to the sink with its record and the ceiling it broke

test "a regressed file-size key reaches the JSONL sink with its file, metric and ceiling" {
    const dir = "zig-cache/test-baseline-ratchet-sink";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Freeze src/big.zig at 8 lines, then run the check measuring 10: a
    // regression against a frozen ceiling, which is what eda's router.zig hit.
    const path = try pathFor(a, dir, "file-size");
    _ = try ratchet.lifecycle(a, path, &.{.{ .key = "src/big.zig", .value = 8 }}, .{
        .force_refresh = true,
        .write_allowed = true,
    });

    // Hysteresis off: this is the PLAIN ratchet hint (the ceiling and the
    // accept command). The tripped wording has its own test below.
    const cfg: @import("config.zig").Config = .{
        .baseline = .{ .enabled = true },
        .hysteresis = .{ .enabled = false },
    };
    // The arena stands in for the run allocator: the forwarded sink records
    // outlive the check, exactly as they do under `all`.
    var ctx: types.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &cfg,
        .quiet = true,
    };
    var outer: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer outer.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &outer;

    try std.testing.expectError(error.CheckFailed, runWithBaseline(&ctx, .{
        .name = "file-size",
        .summary = "test",
        .scope = .per_file,
        .run = fileSizeOverHardLimit,
    }));

    // Exactly the regressed key, as the check measured it — file, message and
    // metric survive the baseline layer instead of being scraped back out of
    // its prose (which yielded a fileless row, or none at all).
    try std.testing.expectEqual(@as(usize, 1), outer.records.items.len);
    const row = outer.records.items[0];
    try std.testing.expectEqualStrings("file-size", row.check);
    try std.testing.expectEqualStrings("src/big.zig", row.file.?);
    try std.testing.expectEqual(@as(?u64, 10), row.metric);
    // The hint carries what the check itself cannot know: the ceiling it broke,
    // by how much, and the command that would ratify it — in both the raw CLI
    // and repo-wired `guardian-accept` forms, so neither consumer shape has to
    // translate the remedy.
    try std.testing.expect(std.mem.indexOf(u8, row.fix_hint.?, "frozen ratchet ceiling of 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.fix_hint.?, "2 code lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.fix_hint.?, "guardian-check accept file-size .") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.fix_hint.?, "zig build guardian-accept -Dguardian-checks=file-size") != null);
}

// ── Hysteresis: trip → no accept → shrink to recover ───────────────────

/// A project directory a hysteresis test can run a ratchet lifecycle in: the
/// source files its stored keys name must EXIST, or the stored-phantom guard
/// (a key naming a missing, gitignored file) locks the run read-only for an
/// unrelated reason and every write assertion below silently stops meaning
/// anything. Under zig-cache every missing path is gitignored, so this is not
/// optional here.
fn tripDir(a: Allocator, dir: []const u8, files: []const []const u8) !void {
    fs.cwd().deleteTree(dir) catch |e| std.log.warn("test setup {s}: {s}", .{ dir, @errorName(e) });
    try fs.cwd().makePath(dir);
    for (files) |f| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, f });
        try fs.cwd().makePath(fs.path.dirname(path) orelse dir);
        (try fs.cwd().createFile(path, .{})).close();
    }
}

/// One file-size measurement as the check reports it: over the hard cap it is a
/// blocking record, under it the advisory warning that carries the same ratchet
/// key and metric — which is what the recovery zone is measured from.
fn sizeRecord(file: []const u8, metric: u64, hard_cap: u64) reporter.Violation {
    return .{
        .check = size_check,
        .file = file,
        .message = "measured",
        .ratchet_key = file,
        .metric = metric,
        .alert = metric <= hard_cap,
    };
}

/// Runs one check's ratchet lifecycle with an explicit set of blocking records
/// and advisory warnings — `runWithBaseline` with the check itself replaced by
/// its output, so a test can walk a file through several measurements without a
/// mutable global to carry the next one.
fn stepRatchet(
    ctx: *types.RunCtx,
    blocking: []const reporter.Violation,
    advisory: []const reporter.Violation,
    force_refresh: bool,
) types.RunError!void {
    return processOutcome(ctx, size_check, "", blocking, advisory, force_refresh);
}

/// The context every hysteresis test runs through: baseline mode on, the
/// default `[hysteresis]` policy (file-size at a 20% band → 8000 of 10000).
fn tripCtx(a: Allocator, dir: []const u8, cfg: *const config_mod.Config) types.RunCtx {
    return .{
        .allocator = a,
        .project_dir = dir,
        .cfg = cfg,
        .quiet = true,
        .renames = &.{},
    };
}

const trip_cfg: config_mod.Config = .{ .baseline = .{ .enabled = true } };

// spec: Hysteresis - Blocks a hard-cap crossing with the recover target and no accept command

test "a crossing fails with nothing to accept, and the sink row says what clears it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-hysteresis-crossing";
    defer fs.cwd().deleteTree(dir) catch {};
    try tripDir(a, dir, &.{"src/router.zig"});
    // An empty (but present) ratchet: this check has adopted, so a new key is
    // a crossing rather than first-run grandfathering.
    _ = try ratchet.lifecycle(a, try pathFor(a, dir, "file-size"), &.{}, .{
        .force_refresh = true,
        .write_allowed = true,
    });

    var ctx = tripCtx(a, dir, &trip_cfg);
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const crossing = [_]reporter.Violation{sizeRecord("src/router.zig", 10_007, 10_000)};
    try std.testing.expectError(error.CheckFailed, stepRatchet(&ctx, &crossing, &.{}, false));

    const out = cap.buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "10007 code lines exceeds the hard cap 10000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a hard-cap crossing cannot be accepted") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "reduce to <=8000 (the recover line)") != null);
    // The whole point: no accept command anywhere in the failure.
    try std.testing.expect(std.mem.indexOf(u8, out, "guardian-check accept file-size") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-Dguardian-checks=") == null);
    // …and the machine-readable row carries the recover target instead.
    try std.testing.expectEqual(@as(usize, 1), cap.records.items.len);
    const hint = cap.records.items[0].fix_hint.?;
    try std.testing.expect(std.mem.indexOf(u8, hint, "reduce to <=8000 code lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "only a shrink clears it") != null);
}

// spec: Hysteresis - Fails an accept run rather than recording a refused crossing or raise

test "the refresh guard turns an accept of a tripped check into a failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const trip: Trip = .{ .policy = hysteresis.policyFor(&trip_cfg, "file-size") };
    const recorded = [_]ratchet.Entry{.{ .key = "src/big.zig", .value = 10_273 }};
    const crossed = [_]ratchet.Entry{ recorded[0], .{ .key = "src/new.zig", .value = 10_100 } };

    try std.testing.expectError(error.CheckFailed, hysteresisRefreshGuard("file-size", trip, .{
        .recorded = &recorded,
        .entries = &crossed,
        .force_refresh = true,
    }));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "is a hard-cap crossing at 10100") != null);
    // Structured too, so a concise run cannot collapse the refusal to nothing.
    try std.testing.expectEqualStrings("hysteresis-refusal", cap.records.items[0].identity.?);

    cap.buf.clearRetainingCapacity();
    const raised = [_]ratchet.Entry{.{ .key = "src/big.zig", .value = 10_520 }};
    try std.testing.expectError(error.CheckFailed, hysteresisRefreshGuard("file-size", trip, .{
        .recorded = &recorded,
        .entries = &raised,
        .force_refresh = true,
    }));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "raise a tripped ceiling 10273 -> 10520") != null);

    // What the guard must NOT touch: an ordinary (non-refresh) run, a check
    // hysteresis does not bind, a shrink, and first-record adoption.
    try hysteresisRefreshGuard("file-size", trip, .{
        .recorded = &recorded,
        .entries = &crossed,
        .force_refresh = false,
    });
    try hysteresisRefreshGuard("file-size", .{}, .{
        .recorded = &recorded,
        .entries = &crossed,
        .force_refresh = true,
    });
    try hysteresisRefreshGuard("file-size", trip, .{
        .recorded = &recorded,
        .entries = &.{.{ .key = "src/big.zig", .value = 9000 }},
        .force_refresh = true,
    });
    try hysteresisRefreshGuard("file-size", trip, .{
        .recorded = null,
        .entries = &crossed,
        .force_refresh = true,
    });
}

// spec: Hysteresis - Grandfathers over-cap subjects when a tripped check first records its ratchet

test "adoption records an over-cap file as a born-tripped entry and stays green" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-hysteresis-adoption";
    defer fs.cwd().deleteTree(dir) catch {};
    try tripDir(a, dir, &.{"src/legacy.zig"});
    var ctx = tripCtx(a, dir, &trip_cfg);
    ctx.metadata_writable = true;
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // No ratchet on file yet: adopting Guardian on a legacy tree must not
    // demand a 2000-line refactor before the first green run.
    const over = [_]reporter.Violation{sizeRecord("src/legacy.zig", 12_000, 10_000)};
    try stepRatchet(&ctx, &over, &.{}, false);
    const path = try pathFor(a, dir, "file-size");
    const written = try ratchet.decodeLines(a, (try snapshot.read(a, path, ratchet.version)).lines);
    try std.testing.expectEqual(@as(u64, 12_000), written[0].value);
    // And the unchanged tree is green on the very next run — born tripped, not
    // born failing.
    try stepRatchet(&ctx, &over, &.{}, false);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "ratchet matches") != null);
}

// spec: Hysteresis - Withholds this session's pending accept from a tripped check

test "a pending session accept cannot let a tripped entry grow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-hysteresis-session";
    defer fs.cwd().deleteTree(dir) catch {};
    try tripDir(a, dir, &.{"src/big.zig"});
    _ = try ratchet.lifecycle(a, try pathFor(a, dir, size_check), &.{.{ .key = "src/big.zig", .value = 10_273 }}, .{
        .force_refresh = true,
        .write_allowed = true,
    });
    accept_session.record(a, dir, &.{size_check});

    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    try expectSessionNoteWithheld(a, dir, &cap);
}

/// The half of the session-note case that only exists inside a git checkout:
/// the note is keyed by HEAD, so outside one nothing was recorded, nothing is
/// pending, and there is no exclusion to observe.
fn expectSessionNoteWithheld(a: Allocator, dir: []const u8, cap: *reporter.Capture) !void {
    if (!accept_session.isPending(a, dir, size_check)) return;
    // The same growth an ordinary ratchet would wave through under the note.
    const grew = [_]reporter.Violation{sizeRecord(trip_subject, 10_400, 10_000)};
    var ctx = tripCtx(a, dir, &trip_cfg);
    try std.testing.expectError(error.CheckFailed, stepRatchet(&ctx, &grew, &.{}, false));
    try std.testing.expect(std.mem.indexOf(
        u8,
        cap.buf.items,
        "this session's pending accept does not cover a hard-cap trip",
    ) != null);

    // Contrast, so the exclusion is provably the hysteresis policy and not some
    // unrelated breakage: with the section off, the note tolerates it as before.
    cap.buf.clearRetainingCapacity();
    const plain: config_mod.Config = .{ .baseline = .{ .enabled = true }, .hysteresis = .{ .enabled = false } };
    var plain_ctx = tripCtx(a, dir, &plain);
    try stepRatchet(&plain_ctx, &grew, &.{}, false);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "tolerated under this session's pending accept") != null);
}

// spec: Hysteresis - Holds a legacy entry through the recovery zone from accept to recovered

test "a v2 entry re-measured under the new metric lowers, holds, blocks growth, then recovers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-hysteresis-upgrade";
    defer fs.cwd().deleteTree(dir) catch {};
    try tripDir(a, dir, &.{"src/big.zig"});
    const path = try pathFor(a, dir, "file-size");
    // The consumer's committed state: src/big.zig accepted at 10273 under the
    // OLD file-size metric (which counted comments and blanks).
    _ = try ratchet.lifecycle(a, path, &.{.{ .key = "src/big.zig", .value = 10_273 }}, .{
        .force_refresh = true,
        .write_allowed = true,
    });

    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // Run 1, ordinary report-mode build: the new metric measures 8900 code
    // lines, which is advisory — under the hard cap, over the recover line.
    // Green, classified as an improvement, and NOTHING is written.
    var ctx = tripCtx(a, dir, &trip_cfg);
    const at_8900 = [_]reporter.Violation{sizeRecord("src/big.zig", 8900, 10_000)};
    try stepRatchet(&ctx, &.{}, &at_8900, false);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "1 lowered, 0 prunable") != null);
    try std.testing.expectEqual(@as(u64, 10_273), (try readRecorded(a, path)).?[0].value);

    // The accept/commit pass: the entry auto-lowers to 8900 and is RETAINED —
    // 8900 is still 900 over the recover line, so the trip is not cleared. This
    // is the prune-then-regrow loophole closing.
    var writer = tripCtx(a, dir, &trip_cfg);
    writer.metadata_writable = true;
    try stepRatchet(&writer, &.{}, &at_8900, false);
    const lowered = (try readRecorded(a, path)).?;
    try std.testing.expectEqual(@as(usize, 1), lowered.len);
    try std.testing.expectEqual(@as(u64, 8900), lowered[0].value);

    // An unchanged tree is green with nothing to say.
    cap.buf.clearRetainingCapacity();
    try stepRatchet(&ctx, &.{}, &at_8900, false);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "ratchet matches") != null);

    // 50 lines of regrowth — free before hysteresis, because the entry would
    // have pruned the moment the file dipped under the cap — now fails, and an
    // accept of it is refused rather than recorded.
    cap.buf.clearRetainingCapacity();
    const at_8950 = [_]reporter.Violation{sizeRecord("src/big.zig", 8950, 10_000)};
    try std.testing.expectError(error.CheckFailed, stepRatchet(&ctx, &.{}, &at_8950, false));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "grew while recovering from a hard-cap trip") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "growth blocks until it reaches <=8000") != null);
    try std.testing.expectError(error.CheckFailed, stepRatchet(&writer, &.{}, &at_8950, true));

    // The campaign lands: 7990 is under the recover line, so the trip clears,
    // the entry prunes, and the run says so by name.
    cap.buf.clearRetainingCapacity();
    const at_7990 = [_]reporter.Violation{sizeRecord("src/big.zig", 7990, 10_000)};
    try stepRatchet(&writer, &.{}, &at_7990, false);
    try std.testing.expect(std.mem.indexOf(
        u8,
        cap.buf.items,
        "recovered: src/big.zig — 7990 code lines at or below the recover line 8000",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), (try readRecorded(a, path)).?.len);
}

// spec: Hysteresis - Carries a tripped entry to the new key when git renames its file

test "a renamed tripped file keeps its entry instead of failing as a crossing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-hysteresis-rename";
    defer fs.cwd().deleteTree(dir) catch {};
    // Both paths exist: the rename is git's to report, and a stored key naming
    // a missing gitignored file would lock the run read-only (see tripDir).
    try tripDir(a, dir, &.{ "src/old.zig", "src/new.zig" });
    const path = try pathFor(a, dir, "file-size");
    _ = try ratchet.lifecycle(a, path, &.{.{ .key = "src/old.zig", .value = 10_273 }}, .{
        .force_refresh = true,
        .write_allowed = true,
    });

    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    var ctx = tripCtx(a, dir, &trip_cfg);
    ctx.metadata_writable = true;
    ctx.renames = &.{.{ .from = "src/old.zig", .to = "src/new.zig" }};
    // Same file, new path, measured in the recovery zone. Untransferred this
    // would be a brand-new key — and under hysteresis a new key past the cap is
    // unacceptable, so a `git mv` would have become unfixable rather than free.
    const moved = [_]reporter.Violation{sizeRecord("src/new.zig", 9000, 10_000)};
    try stepRatchet(&ctx, &.{}, &moved, false);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "moved: src/old.zig -> src/new.zig") != null);
    const after = (try readRecorded(a, path)).?;
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("src/new.zig", after[0].key);
    // The trip moved with it: still recorded, now at the value it measures.
    try std.testing.expectEqual(@as(u64, 9000), after[0].value);
}

/// A type-size run reporting one 8-field struct from the file it was just
/// extracted into — the `PadObs` shape, whose ratchet entry is recorded under
/// the file it came from.
fn typeSizeAtNewHome(_: *types.RunCtx) types.RunError!void {
    reporter.emit(.{
        .check = "type-size",
        .file = "src/pad_obs.zig",
        .message = "PadObs has 8 fields (cap 7)",
        .ratchet_key = "src/pad_obs.zig|PadObs",
        .metric = 8,
    });
    return error.CheckFailed;
}

// spec: Ratchet Relocation - Prints each transferred entry as a moved line naming both files and the item

test "an extracted item passes the gate and re-keys its entry, reporting the move" {
    const dir = "zig-cache/test-baseline-relocation";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    // Both files exist: the struct left obs.zig, obs.zig did not leave the
    // tree. (A stored key naming a missing, gitignored file is a partial view,
    // which would lock this run read-only for an unrelated reason.)
    try fs.cwd().makePath(dir ++ "/src");
    (try fs.cwd().createFile(dir ++ "/src/obs.zig", .{})).close();
    (try fs.cwd().createFile(dir ++ "/src/pad_obs.zig", .{})).close();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try pathFor(a, dir, "type-size");
    _ = try ratchet.lifecycle(a, path, &.{.{ .key = "src/obs.zig|PadObs", .value = 8 }}, .{
        .force_refresh = true,
        .write_allowed = true,
    });

    const cfg: @import("config.zig").Config = .{ .baseline = .{ .enabled = true } };
    var ctx: types.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &cfg,
        .quiet = true,
        .metadata_writable = true,
        // Resolved (to nothing) by the run, as `all` does before its check pass.
        .renames = &.{},
    };
    var outer: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer outer.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &outer;

    // Green: the 8 fields were already grandfathered, just somewhere else.
    try runWithBaseline(&ctx, .{
        .name = "type-size",
        .summary = "test",
        .scope = .per_file,
        .run = typeSizeAtNewHome,
    });
    try std.testing.expect(std.mem.indexOf(
        u8,
        outer.buf.items,
        "moved: src/obs.zig -> src/pad_obs.zig :: PadObs",
    ) != null);

    // The recorded entry moved rather than multiplied: still one key, at the
    // ceiling it already had.
    const after = try ratchet.decodeLines(a, (try snapshot.read(a, path, ratchet.version)).lines);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("src/pad_obs.zig|PadObs", after[0].key);
    try std.testing.expectEqual(@as(u64, 8), after[0].value);
}

// spec: Ratchet Relocation - Allows a deny_growth refresh that only relocates recorded keys

test "deny_growth permits a relocated key and still refuses a raised one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const cfg: @import("config.zig").Config = .{
        .baseline = .{ .enabled = true, .deny_growth = &.{"type-size"} },
    };
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };

    // The guard compares against the RELOCATED recording, so an accept that
    // only re-keys an entry adds nothing and is allowed.
    const relocated = [_]ratchet.Entry{.{ .key = "src/pad_obs.zig|PadObs", .value = 8 }};
    const current = [_]ratchet.Entry{.{ .key = "src/pad_obs.zig|PadObs", .value = 8 }};
    try ratchetDenyGrowthGuard(a, &ctx, "type-size", .{
        .recorded = &relocated,
        .entries = &current,
        .force_refresh = true,
    });
    // Moving is not a licence to grow: a ninth field at the new key is refused
    // exactly as it would be at the old one.
    const grown = [_]ratchet.Entry{.{ .key = "src/pad_obs.zig|PadObs", .value = 9 }};
    try std.testing.expectError(error.CheckFailed, ratchetDenyGrowthGuard(a, &ctx, "type-size", .{
        .recorded = &relocated,
        .entries = &grown,
        .force_refresh = true,
    }));
}

/// A prose-reporting check: one indented violation line naming its own location
/// plus the trailing `fix:` hint every such check prints once.
fn proseViolation(_: *types.RunCtx) types.RunError!void {
    reporter.fail("catch-discipline FAILED (1 occurrence(s))", .{});
    reporter.detail("  src/x.zig:16: catch block is empty (silently swallows the error)\n", .{});
    reporter.detail("  fix: handle the error explicitly with a switch or named return.\n", .{});
    return error.CheckFailed;
}

// spec: Baseline Mode - Forwards a newly reported violation to the sink with its location and fix hint

test "a new violation above the baseline reaches the sink structured, not as prose" {
    const dir = "zig-cache/test-baseline-grown-sink";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    try fs.cwd().makePath(dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An existing baseline of one unrelated violation, so this run's finding is
    // new debt (`grown`) rather than a first-run capture.
    const path = try pathFor(a, dir, "catch-discipline");
    _ = try lifecycle(a, path, try keyedLines(a, "catch-discipline", &.{"src/other.zig:3: catch block is empty"}), true, true);

    const cfg: @import("config.zig").Config = .{ .baseline = .{ .enabled = true } };
    // The arena stands in for the run allocator: the forwarded sink records
    // outlive the check, exactly as they do under `all`.
    var ctx: types.RunCtx = .{
        .allocator = a,
        .project_dir = dir,
        .cfg = &cfg,
        .quiet = true,
    };
    var outer: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer outer.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &outer;

    try std.testing.expectError(error.CheckFailed, runWithBaseline(&ctx, .{
        .name = "catch-discipline",
        .summary = "test",
        .scope = .per_file,
        .run = proseViolation,
    }));

    try std.testing.expectEqual(@as(usize, 1), outer.records.items.len);
    const row = outer.records.items[0];
    try std.testing.expectEqualStrings("src/x.zig", row.file.?);
    try std.testing.expectEqual(@as(u32, 16), row.line.?);
    try std.testing.expectEqualStrings("catch block is empty (silently swallows the error)", row.message);
    try std.testing.expectEqualStrings(
        "handle the error explicitly with a switch or named return.",
        row.fix_hint.?,
    );
}

// spec: Per-Item Ratchets - Retains legacy ratchet entries while the same subjects remain advisory warnings

test "mergeAdvisoryEntries preserves old warning keys without creating advisory debt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]ratchet.Entry{
        .{ .key = "src/advisory.zig", .value = 1200 },
        .{ .key = "src/resolved.zig", .value = 1100 },
        .{ .key = "src/still-hard.zig", .value = 11_000 },
    };
    const blocking = [_]ratchet.Entry{
        .{ .key = "src/still-hard.zig", .value = 10_500 },
    };
    const warnings = [_]reporter.Violation{
        .{ .check = "file-size", .message = "warning", .ratchet_key = "src/advisory.zig", .metric = 1150 },
        // A warning with no prior baseline entry remains advisory-only.
        .{ .check = "file-size", .message = "warning", .ratchet_key = "src/new-warning.zig", .metric = 1050 },
    };
    const merged = try mergeAdvisoryEntries(a, &old, &blocking, &warnings);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expect(entryPresent(merged, "src/advisory.zig"));
    try std.testing.expect(entryPresent(merged, "src/still-hard.zig"));
    try std.testing.expect(!entryPresent(merged, "src/resolved.zig"));
    try std.testing.expect(!entryPresent(merged, "src/new-warning.zig"));
}

/// Test shorthand for the reporting context `reportRatchet`/`reportRegressed`
/// take: a read-only run with the given fix hint and violation records.
fn testReport(a: std.mem.Allocator, fix_hint: ?[]const u8, records: []const reporter.Violation) RatchetReport {
    return .{ .allocator = a, .fix_hint = fix_hint, .records = records, .write_allowed = false };
}

// spec: Per-Item Ratchets - Names the offending file line and metric in the regression status line

test "a ratchet regression status line names the offender, not just the check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // The check's own record carries file:line and the "N params (cap M)" text;
    // the regression must inline it instead of naming only the ratchet key.
    const records = [_]reporter.Violation{.{
        .check = "function-size",
        .file = "src/router.zig",
        .line = 412,
        .message = "fn exactItemClears has 7 params (cap 6)",
        .ratchet_key = "src/router.zig|exactItemClears",
        .metric = 7,
    }};
    const reg: ratchet.Regression = .{
        .grown = &.{},
        .new_offenders = &.{.{ .key = "src/router.zig|exactItemClears", .value = 7 }},
        .remaining = 1,
    };
    try std.testing.expectError(
        error.CheckFailed,
        reportRegressed("function-size", reg, testReport(a, null, &records)),
    );
    const out = cap.buf.items;
    const status_line = out[0 .. std.mem.indexOfScalar(u8, out, '\n') orelse out.len];
    try std.testing.expect(std.mem.indexOf(u8, status_line, "src/router.zig:412") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "exactItemClears") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_line, "7 params (cap 6)") != null);

    // With no matching record the key itself is still named — never a bare check.
    try std.testing.expectEqualStrings("src/x.zig|f", firstOffender(a, .{
        .grown = &.{.{ .key = "src/x.zig|f", .old = 3, .new = 4 }},
        .new_offenders = &.{},
        .remaining = 1,
    }, &.{}));
}

// spec: Per-Item Ratchets - Presents file and type growth as volume with accept-first guidance

test "reportRegressed words volume growth accept-first and shape regressions fix-first" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // A brand-new offender raises no ceiling — the routine volume case.
    const reg: ratchet.Regression = .{
        .grown = &.{},
        .new_offenders = &.{.{ .key = "src/x.zig", .value = 120 }},
        .remaining = 1,
    };
    // file-size is a volume check: growth header, accept guidance first.
    try std.testing.expectError(
        error.CheckFailed,
        reportRegressed("file-size", reg, testReport(std.testing.allocator, "fix: split the file", &.{})),
    );
    const volume_out = try cap.buf.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(volume_out);
    try std.testing.expect(std.mem.indexOf(u8, volume_out, "volume growth") != null);
    const v_accept = std.mem.indexOf(u8, volume_out, "accept:").?;
    const v_fix = std.mem.indexOf(u8, volume_out, "fix:").?;
    try std.testing.expect(v_accept < v_fix);

    // function-length is a shape check: regression header, fix guidance first.
    try std.testing.expectError(
        error.CheckFailed,
        reportRegressed("function-length", reg, testReport(std.testing.allocator, "fix: extract helpers", &.{})),
    );
    const shape_out = cap.buf.items;
    try std.testing.expect(std.mem.indexOf(u8, shape_out, "regressed above ratchet") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_out, "volume growth") == null);
    const s_fix = std.mem.indexOf(u8, shape_out, "fix:").?;
    const s_accept = std.mem.indexOf(u8, shape_out, "accept:").?;
    try std.testing.expect(s_fix < s_accept);
}

// spec: size introspection - Warns that accepting a grown ratchet key raises a frozen ceiling

test "a ceiling-raising regression leads with the raise warning before accept" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // A GROWN key can only be accepted by raising the ceiling the ratchet
    // froze it at — the move a project's own rules typically forbid. Even for
    // file-size, a volume check whose plain wording is accept-first, that must
    // not read as a routine option.
    const raising: ratchet.Regression = .{
        .grown = &.{.{ .key = "src/x.zig", .old = 10_000, .new = 10_005 }},
        .new_offenders = &.{},
        .remaining = 1,
    };
    try std.testing.expect(toneFor(raising) == .raises);
    try std.testing.expect(headlineFor(.volume, .raises) == .raise);
    try std.testing.expect(guidanceOrder(.volume, .raises) == .fix_first);
    try std.testing.expectError(
        error.CheckFailed,
        reportRegressed("file-size", raising, testReport(std.testing.allocator, "fix: split the file", &.{})),
    );
    const out = cap.buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "grew past a frozen ratchet ceiling") != null);
    const lead = "this raises a frozen ceiling — prefer moving code to a cohesive module boundary";
    const warning = std.mem.indexOf(u8, out, lead).?;
    // The warning leads; the accept commands come after it, never before.
    try std.testing.expect(warning < std.mem.indexOf(u8, out, "accept:").?);
    // The plain "accept if intended" wording is reserved for a regression that
    // raises nothing.
    try std.testing.expect(std.mem.indexOf(u8, out, "accept if intended") == null);
}

// spec: Per-Item Ratchets - Notes that a grown ratchet item was already sitting at its frozen cap

test "the at-cap note fires for a grown key on any ratchet, not just type-size" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // A grown key had ZERO headroom by construction — the ratchet froze it at
    // its own value — so "reduce or split" is the only move; there is no
    // baseline escape. The note used to be type-size-only, which left every
    // other ratchet's reader to infer it from the numbers.
    const grown: ratchet.Regression = .{
        .grown = &.{.{ .key = "src/x.zig|Params", .old = 17, .new = 18 }},
        .new_offenders = &.{},
        .remaining = 1,
    };
    try std.testing.expect(atFrozenCap(grown));
    try std.testing.expectError(error.CheckFailed, reportRegressed("function-size", grown, testReport(std.testing.allocator, null, &.{})));
    const grown_out = try cap.buf.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(grown_out);
    try std.testing.expect(std.mem.indexOf(u8, grown_out, "at its frozen cap; reduce or split") != null);

    // A regression made only of NEW offenders is a different situation: those
    // tripped the check's default cap and were never frozen at anything.
    const fresh: ratchet.Regression = .{
        .grown = &.{},
        .new_offenders = &.{.{ .key = "src/y.zig|g", .value = 9 }},
        .remaining = 1,
    };
    try std.testing.expect(!atFrozenCap(fresh));
    try std.testing.expectError(error.CheckFailed, reportRegressed("function-size", fresh, testReport(std.testing.allocator, null, &.{})));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "frozen cap") == null);
}

// spec: Per-Item Ratchets - Scrapes the check's own fix hint for the regression message

test "firstFixHint pulls the check's fix line out of captured output" {
    const captured =
        \\guardian: function length FAILED (1 fn(s) over 120 line cap)
        \\  src/x.zig:5: fn foo is 130 lines (cap 120)
        \\  fix: extract helpers to break the function into focused units.
    ;
    try std.testing.expectEqualStrings(
        "fix: extract helpers to break the function into focused units.",
        firstFixHint(captured).?,
    );
    // No fix line → null (the regression message just omits the hint).
    try std.testing.expect(firstFixHint("guardian: all good\n") == null);
}

test "pathFor builds the baseline file path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try pathFor(arena.allocator(), "proj", "magic-number");
    try std.testing.expectEqualStrings("proj/.guardian/baselines/magic-number.txt", p);
}

test "extract pulls violation lines and skips headers and fix hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample =
        \\guardian: ban-fs FAILED (3 occurrence(s))
        \\  src/x.zig:5: std.fs.cwd reference outside allowed paths
        \\  src/y.zig:8: std.fs.cwd reference outside allowed paths
        \\  src/z.zig:12: std.fs.cwd reference outside allowed paths
        \\  fix: inject a Filesystem port from infra/fs.
    ;
    const lines = try extract(a, sample);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("src/x.zig:5: std.fs.cwd reference outside allowed paths", lines[0]);
    try std.testing.expectEqualStrings("src/z.zig:12: std.fs.cwd reference outside allowed paths", lines[2]);
}

test "extract ignores multi-line fix-hint continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample =
        \\guardian: int-from-float budget FAILED (casts: 1 found, 0 budgeted)
        \\  src/x.zig:5: unguarded @intFromFloat
        \\  fix: guard the new @intFromFloat (isFinite + range check),
        \\       or run zig build guardian-accept -Dguardian-checks=int-from-float-budget
    ;
    const lines = try extract(a, sample);
    // Only the violation; both hint lines (incl. the non-`fix:` continuation)
    // are excluded.
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("src/x.zig:5: unguarded @intFromFloat", lines[0]);
}

// spec: Baseline Mode - Stops scraping violations at every trailing prose label

test "extract stops at a rationale label, not just fix and add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // test-no-conditional's real output: violations, then a `why:` rationale,
    // then `fix:`. Scraping only stopped at fix:/add:, so `why:` was counted as
    // a tenth violation — it polluted the baseline and, having no file, showed
    // up as a whole new file's worth of "debt" that blocked eda's migration
    // while printing the rationale text as the sole culprit.
    const sample =
        \\guardian: test-no-conditional FAILED (2 occurrence(s))
        \\  src/a.zig:1880: switch at top level of test body
        \\  src/b.zig:107: while at top level of test body
        \\  why: tests assert, helpers compute — a conditional can silently skip the assertion.
        \\  fix: one top-level loop is fine; split a branch into two independent tests.
    ;
    const lines = try extract(a, sample);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("src/b.zig:107: while at top level of test body", lines[1]);

    // The other labels checks use for trailing prose are covered too.
    const with_note =
        \\guardian: stdout-flush FAILED (1 occurrence(s))
        \\  src/c.zig:12: buffered writer never flushed
        \\  note: a missing flush() truncates output in 0.15.
    ;
    try std.testing.expectEqual(@as(usize, 1), (try extract(a, with_note)).len);
}

test "extract stops at the spec add: suggestion block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample =
        \\guardian: spec coverage FAILED (2 unverified)
        \\  unverified: Auth - Validates tokens
        \\  unverified: Auth - Rejects expired tokens
        \\
        \\  add: // spec: Auth - Validates tokens
        \\  add: // spec: Auth - Rejects expired tokens
        \\  Each spec behavior must have exactly one // spec: tag (1:1 mapping).
    ;
    const lines = try extract(a, sample);
    // The two unverified behaviors, not the add: block or the trailing prose.
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("unverified: Auth - Validates tokens", lines[0]);
    try std.testing.expectEqualStrings("unverified: Auth - Rejects expired tokens", lines[1]);
}

test "extract handles empty output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try extract(a, "");
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "extract skips ok-only output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample = "guardian: ban-fs: no forbidden references\n";
    const lines = try extract(a, sample);
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "lifecycle creates baseline on first run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-create.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    const lines = try keyedLines(a, "demo", &.{ "alpha", "beta" });
    const out = try lifecycle(a, path, lines, false, true);
    try std.testing.expect(out == .created);
    try std.testing.expectEqual(@as(usize, 2), out.created);
}

// spec: Baseline Mode - Defers first-record and prune writes to a metadata-writable run

test "lifecycle defers creation and pruning on a read-only run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-readonly.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // write_allowed = false: a missing baseline is grandfathered as `created`
    // (all current violations accepted, green) but NOT written, so an ordinary
    // run leaves the tree clean.
    const two = try keyedLines(a, "demo", &.{ "alpha", "beta" });
    try std.testing.expect((try lifecycle(a, path, two, false, false)) == .created);
    try std.testing.expectError(error.FileNotFound, fs.cwd().access(path, .{}));

    // Record it with a writable run, then resolve one violation on a read-only
    // run: the shrink is reported but the committed baseline is left untouched.
    _ = try lifecycle(a, path, two, false, true);
    const before = try fs.cwd().readFileAlloc(a, path, 4096);
    const one = try keyedLines(a, "demo", &.{"alpha"});
    try std.testing.expect((try lifecycle(a, path, one, false, false)) == .shrunk);
    const after = try fs.cwd().readFileAlloc(a, path, 4096);
    try std.testing.expectEqualStrings(before, after);
}

test "lifecycle returns matched on identical run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-match.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    _ = try lifecycle(a, path, try keyedLines(a, "demo", &.{ "alpha", "beta" }), false, true);
    const out = try lifecycle(a, path, try keyedLines(a, "demo", &.{ "alpha", "beta" }), false, true);
    try std.testing.expect(out == .matched);
}

test "lifecycle returns grown when new violations appear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-grown.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    _ = try lifecycle(a, path, try keyedLines(a, "demo", &.{"alpha"}), false, true);

    const out = try lifecycle(a, path, try keyedLines(a, "demo", &.{ "alpha", "gamma" }), false, true);
    try std.testing.expect(out == .grown);
    try std.testing.expectEqual(@as(usize, 1), out.grown.new_lines.len);
    // The failure reports the human line, not the stored key.
    try std.testing.expectEqualStrings("gamma", out.grown.new_lines[0]);
}

test "lifecycle returns shrunk when violations are resolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-shrunk.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    _ = try lifecycle(a, path, try keyedLines(a, "demo", &.{ "alpha", "beta", "gamma" }), false, true);

    const out = try lifecycle(a, path, try keyedLines(a, "demo", &.{"alpha"}), false, true);
    try std.testing.expect(out == .shrunk);
    try std.testing.expectEqual(@as(usize, 2), out.shrunk.removed);
    try std.testing.expectEqual(@as(usize, 1), out.shrunk.remaining);
}

// spec: Baseline Mode - Prunes the baseline file when resolved violations shrink it

test "lifecycle auto-prunes the baseline file after a shrink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-autoprune.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    _ = try lifecycle(a, path, try keyedLines(a, "demo", &.{ "alpha", "beta", "gamma" }), false, true);

    // Resolving two violations shrinks the set AND rewrites the file.
    const one = try keyedLines(a, "demo", &.{"alpha"});
    try std.testing.expect((try lifecycle(a, path, one, false, true)) == .shrunk);

    // The file was pruned to the surviving violation, so a re-run matches
    // (no lingering "resolved" entries to keep reporting).
    const out2 = try lifecycle(a, path, one, false, true);
    try std.testing.expect(out2 == .matched);
    try std.testing.expectEqual(@as(usize, 1), out2.matched);
}

// spec: Baseline Mode - Leaves a matched baseline untouched when only line numbers shifted

test "lifecycle does not rewrite a matched baseline whose entries only moved lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-norenumber.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // Record a baseline whose entry carries a source-line position.
    const at_10 = try keyedLines(a, "ban-fs", &.{"src/x.zig:10: std.fs.cwd reference outside allowed paths"});
    _ = try lifecycle(a, path, at_10, false, true);
    const before = try fs.cwd().readFileAlloc(a, path, 4096);

    // The same violation, only shifted to a new line (an unrelated edit grew the
    // file above it), must match — and must NOT rewrite the committed baseline,
    // so a source-only diff stays clean (C1a).
    const at_42 = try keyedLines(a, "ban-fs", &.{"src/x.zig:42: std.fs.cwd reference outside allowed paths"});
    try std.testing.expect((try lifecycle(a, path, at_42, false, true)) == .matched);
    const after = try fs.cwd().readFileAlloc(a, path, 4096);
    try std.testing.expectEqualStrings(before, after);
}

// spec: Baseline Mode - Keeps a baselined violation matched when its message text is reworded

test "rewording a violation's message leaves the baseline green" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-reword.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // A check that names what it flagged: the identity is the prong set, the
    // message is prose *about* that prong set. This is the real 2026-07-20
    // regression — enriching this check's message with a file list reported all
    // ten pre-existing violations as new.
    const before: reporter.Violation = .{
        .check = "repeated-switch-on-enum",
        .message = "switch on prongs (float,integer) appears in 2 files",
        .identity = "float,integer",
    };
    const baselined = try keyedViolations(a, "repeated-switch-on-enum", "", &.{before});
    try std.testing.expect((try lifecycle(a, path, baselined, false, true)) == .created);
    const on_disk = try fs.cwd().readFileAlloc(a, path, 4096);

    // Now reword the *same* underlying violation as freely as a diagnostics
    // batch would: new phrasing, an added count, and an appended file list. The
    // rendered line shares almost nothing with the baselined one...
    const after: reporter.Violation = .{
        .check = "repeated-switch-on-enum",
        .file = "src/a.zig",
        .line = 12,
        .message = "the 2-prong set (float,integer) is switched in 3 files: src/a.zig:12, src/b.zig:40, src/c.zig:7",
        .identity = "float,integer",
    };
    const reworded = try keyedViolations(a, "repeated-switch-on-enum", "", &.{after});
    try std.testing.expect(!std.mem.eql(u8, baselined[0].line, reworded[0].line));

    // ...yet the run stays green, and the committed baseline is not rewritten,
    // so a consumer's gate survives the upgrade with no accept and no churn.
    try std.testing.expect((try lifecycle(a, path, reworded, false, true)) == .matched);
    try std.testing.expectEqualStrings(on_disk, try fs.cwd().readFileAlloc(a, path, 4096));

    // The guard rail still holds: a *different* prong set is a real new
    // violation and reds the build.
    const other: reporter.Violation = .{
        .check = "repeated-switch-on-enum",
        .message = "switch on prongs (ok,err) appears in 2 files",
        .identity = "ok,err",
    };
    const grew = try keyedViolations(a, "repeated-switch-on-enum", "", &.{ after, other });
    try std.testing.expect((try lifecycle(a, path, grew, false, true)) == .grown);
}

// spec: Baseline Mode - Skips findings whose file is missing and gitignored instead of counting them

test "scanPhantoms drops unbuilt generated files and keeps a real deletion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const cfg: @import("config.zig").Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };

    // Three findings against this repo: one in gitignored build output that was
    // never generated here (phantom), one in a file that exists, and one prose
    // finding naming no file at all.
    const violations = try keyedLines(a, "pub-api-surface", &.{
        "- zig-out/generated/absent.zig::Args value",
        "src/check.zig:10: something real",
        "unverified: Auth - Validates tokens",
    });
    const scan = try scanPhantoms(a, &ctx, "pub-api-surface", violations);
    // Only the unbuildable one is skipped; it is reported, never counted.
    try std.testing.expectEqual(@as(usize, 1), scan.skipped);
    try std.testing.expectEqual(@as(usize, 2), scan.kept.len);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, missing_inputs.hint) != null);

    // A finding in a file that is merely absent but TRACKED (a real deletion)
    // stays in the counted set — the skip must never hide an API removal.
    const deleted = try keyedLines(a, "pub-api-surface", &.{"- src/deleted_module.zig::Args value"});
    const deleted_scan = try scanPhantoms(a, &ctx, "pub-api-surface", deleted);
    try std.testing.expectEqual(@as(usize, 0), deleted_scan.skipped);
}

// spec: Baseline Mode - Preserves the count of same-key violations across a stored baseline

test "six identical-key violations round-trip through the file as six" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-multiplicity.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // eda's real shape: six occurrences in one file, identical message, differing
    // only by line — and line numbers are deliberately absent from the key, so
    // all six share one key. Storage is a multiset, not a set: the baseline must
    // still be able to tell six from one, or fixing five would go unnoticed.
    const six = try keyedLines(a, "test-no-conditional", &.{
        "src/eval/design_block.zig:1880: switch at top level of test body",
        "src/eval/design_block.zig:1902: switch at top level of test body",
        "src/eval/design_block.zig:1954: switch at top level of test body",
        "src/eval/design_block.zig:1980: switch at top level of test body",
        "src/eval/design_block.zig:2015: switch at top level of test body",
        "src/eval/design_block.zig:2042: switch at top level of test body",
    });
    // They really do collapse to one key...
    for (six) |k| try std.testing.expectEqualStrings(six[0].key, k.key);
    try std.testing.expect((try lifecycle(a, path, six, false, true)) == .created);
    // ...yet the stored file holds six lines, so the count survives.
    const stored = try snapshot.read(a, path, version);
    try std.testing.expectEqual(@as(usize, 6), stored.lines.len);

    // Re-running with all six still matches (no churn from the duplication).
    try std.testing.expect((try lifecycle(a, path, six, false, true)) == .matched);

    // Fixing five is an improvement the baseline notices and prunes to.
    const one = try keyedLines(a, "test-no-conditional", &.{
        "src/eval/design_block.zig:1880: switch at top level of test body",
    });
    const shrunk = try lifecycle(a, path, one, false, true);
    try std.testing.expect(shrunk == .shrunk);
    try std.testing.expectEqual(@as(usize, 5), shrunk.shrunk.removed);

    // ...and adding a seventh occurrence back is caught as new debt.
    const two = try keyedLines(a, "test-no-conditional", &.{
        "src/eval/design_block.zig:1880: switch at top level of test body",
        "src/eval/design_block.zig:1999: switch at top level of test body",
    });
    try std.testing.expect((try lifecycle(a, path, two, false, true)) == .grown);
}

// spec: Baseline Mode - Re-keys a stale text baseline to stable identities without failing

test "migrate re-keys a v1 text baseline in place and keeps enforcing afterwards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-migrate.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // Hand-write the pre-upgrade v1 baseline: rendered violation text.
    var v1 = [_][]const u8{
        "src/a.zig:5: std.fs.cwd reference outside allowed paths",
        "src/b.zig:9: std.fs.cwd reference outside allowed paths",
    };
    try snapshot.write(path, legacy_version, &v1);

    // The upgrade also reworded the message and shifted a line — the v1 text no
    // longer matches anything. Migration re-keys instead of reporting two new
    // violations, so the consumer stays green with no manual refresh.
    const current = try keyedLines(a, "ban-fs", &.{
        "src/a.zig:5: std.fs.cwd used outside the allowed paths",
        "src/b.zig:31: std.fs.cwd used outside the allowed paths",
    });
    const out = try lifecycle(a, path, current, false, true);
    try std.testing.expect(out == .migrated);
    try std.testing.expectEqual(@as(usize, 2), out.migrated);

    // The rewritten file is v3, and the migrated baseline still enforces: the
    // same two violations match, a third one reds the build.
    try std.testing.expect((try lifecycle(a, path, current, false, true)) == .matched);
    const plus_one = try keyedLines(a, "ban-fs", &.{
        "src/a.zig:5: std.fs.cwd used outside the allowed paths",
        "src/b.zig:31: std.fs.cwd used outside the allowed paths",
        "src/c.zig:2: std.fs.cwd used outside the allowed paths",
    });
    try std.testing.expect((try lifecycle(a, path, plus_one, false, true)) == .grown);
}

// spec: Baseline Mode - Refuses to migrate a stale baseline when a file gained violations

test "migrationGrowth allows a pure re-key but reports a file that gained debt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old = [_][]const u8{
        "src/a.zig:5: old wording",
        "src/a.zig:9: old wording",
        "src/b.zig:1: old wording",
    };

    // Same per-file counts (2 in a, 1 in b) under completely different text —
    // a rewording moves violations between keys but never creates one, so the
    // migration is a provable no-op re-key and adds nothing.
    const rekeyed = try keyedLines(a, "demo", &.{
        "src/a.zig:5: brand new wording",
        "src/a.zig:40: brand new wording",
        "src/b.zig:1: brand new wording",
    });
    try std.testing.expect((try migrationGrowth(a, &old, rekeyed)) == null);

    // Fewer violations than recorded is a shrink — also safe to adopt.
    const shrunk = try keyedLines(a, "demo", &.{"src/a.zig:5: brand new wording"});
    try std.testing.expect((try migrationGrowth(a, &old, shrunk)) == null);

    // src/b.zig went 1 → 2: that file gained real debt, so the migration is
    // refused and b's lines are reported as new.
    const grew = try keyedLines(a, "demo", &.{
        "src/a.zig:5: brand new wording",
        "src/a.zig:40: brand new wording",
        "src/b.zig:1: brand new wording",
        "src/b.zig:8: brand new wording",
    });
    const gained = (try migrationGrowth(a, &old, grew)).?;
    try std.testing.expectEqual(@as(usize, 2), gained.len);
    try std.testing.expectEqualStrings("src/b.zig:1: brand new wording", gained[0]);
}

// spec: Baseline Mode - Records no baseline file for a check with nothing to record

test "lifecycle creates no baseline file when there are no violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-empty.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // A passing check with no prior baseline reports matched(0) and writes
    // nothing, so a green run never dirties git with a header-only file (C1b).
    const out = try lifecycle(a, path, &.{}, false, true);
    try std.testing.expect(out == .matched);
    try std.testing.expectEqual(@as(usize, 0), out.matched);
    try std.testing.expectError(error.FileNotFound, fs.cwd().access(path, .{}));
}

// spec: Baseline Mode - Refuses to refresh a deny_growth baseline that would grow

test "growthDenied blocks refresh growth only for a listed check with a prior baseline" {
    const deny = &[_][]const u8{"spec"};
    // A refresh that would grow the listed check's baseline (5 > 3) is denied.
    try std.testing.expect(growthDenied(deny, "spec", 3, 5, true));
    // A refresh that holds or shrinks is fine (pruning is always safe).
    try std.testing.expect(!growthDenied(deny, "spec", 3, 3, true));
    try std.testing.expect(!growthDenied(deny, "spec", 3, 2, true));
    // A check not in deny_growth is never guarded.
    try std.testing.expect(!growthDenied(deny, "magic-number", 3, 5, true));
    // Without a refresh, growth is the ordinary `grown` failure, not this guard.
    try std.testing.expect(!growthDenied(deny, "spec", 3, 5, false));
    // No prior baseline (null) — initial creation is never "growth".
    try std.testing.expect(!growthDenied(deny, "spec", null, 5, true));
}

// spec: Baseline Introspection - Splits a check's current findings into new, live, and resolved rows

test "splitAgainst separates unrecorded, still-firing, and resolved rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stored = [_][]const u8{ "c|a.zig|one", "c|a.zig|one", "c|b.zig|two", "c|gone.zig|three" };
    const current = [_]Keyed{
        .{ .key = "c|a.zig|one", .line = "a.zig:1: one" },
        .{ .key = "c|b.zig|two", .line = "b.zig:2: two" },
        .{ .key = "c|new.zig|four", .line = "new.zig:4: four" },
    };
    const parts = try splitAgainst(a, &stored, &current);
    // `live` is the group a baselined check could never report: frozen debt
    // that STILL fires, as opposed to frozen debt something already fixed.
    try std.testing.expectEqual(@as(usize, 2), parts.live.len);
    // The second copy of the duplicated key has no current counterpart, so it
    // resolves alongside the vanished one — multiplicity is consumed, not
    // ignored, exactly as the gate's own pass/fail diff does it.
    try std.testing.expectEqual(@as(usize, 2), parts.removed.len);
    try std.testing.expectEqual(@as(usize, 1), parts.added.len);
    try std.testing.expectEqualStrings("new.zig:4: four", parts.added[0].line);
}

// spec: Baseline Introspection - Names the keys a refused deny_growth refresh would add

test "the deny-growth refusal names each key it would add, on both channels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "zig-cache/test-baseline-growth-keys.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);
    _ = try lifecycle(a, path, try keyedLines(a, "concept", &.{"alpha"}), false, true);

    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const grown = try keyedLines(a, "concept", &.{ "alpha", "beta", "gamma" });
    const names = try growthNames(a, path, grown);
    reportGrowthNames(names);
    try emitDenyGrowthDetail(a, "concept", names);
    // A count alone ("would grow 1→3") cannot tell a deliberately declared new
    // rule from an accidental regression; the keys can. The already-recorded
    // key is not growth, so it must not appear among them.
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "2 key(s) would be added or raised") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "gamma") != null);
    // Concise `accept` output replays the RECORD, not the detail block, so the
    // keys have to survive into the record's own message as well.
    try std.testing.expect(std.mem.indexOf(u8, cap.records.items[0].message, "beta") != null);
    // A bounded sample: three names inline, the rest counted.
    const many = [_][]const u8{ "k1", "k2", "k3", "k4", "k5" };
    try std.testing.expect(std.mem.endsWith(u8, try refusalMessage(a, &many), "k1, k2, k3 (+2 more)"));
}

// spec: Baseline Introspection - Names the sanctioned two-step for a deliberately declared new rule

test "the deny-growth refusal spells out the declare-a-new-rule escape" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    reportGrowthEscape("concept");
    // The refusal has to name the sanctioned path, not just say no: an agent
    // meeting it cold cannot otherwise tell the documented two-step from
    // routing around a real finding, and editing guardian.toml unprompted
    // reads as gate-tampering.
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "deny_growth in guardian.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "guardian-check accept concept .") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "restore the deny_growth entry") != null);
}

// spec: Baseline Introspection - Words a first-run baseline or ratchet creation as a recorded starting set

test "a created baseline or ratchet says so instead of reporting a grandfathered set" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // Recorded (a metadata-writable run) and pending (an ordinary one) both say
    // there was no baseline. "grandfathered" alone read as an established
    // baseline holding steady, which is the opposite of what a first probe of a
    // new [[ban]]/[[concept]] rule needs to hear.
    try reportOutcome("ban", .{ .created = 2 }, true);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "ban: no baseline existed — recording 2") != null);
    cap.buf.clearRetainingCapacity();
    try reportOutcome("ban", .{ .created = 2 }, false);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "no baseline exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "starting set") != null);
    // The ratchet half of the same lifecycle carries the same wording.
    cap.buf.clearRetainingCapacity();
    try reportRatchet("file-size", .{ .created = 3 }, .{
        .allocator = std.testing.allocator,
        .fix_hint = null,
        .records = &.{},
        .write_allowed = true,
    });
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "no ratchet existed — recording 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "grandfathered") == null);
}

// spec: Baseline Mode - Keeps the deny_growth policy reason visible in concise acceptance output
test "deny-growth refusal emits structured diagnostic detail" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    try emitDenyGrowthDetail(std.testing.allocator, "completeness", &.{});
    try std.testing.expectEqual(@as(usize, 1), cap.records.items.len);
    try std.testing.expectEqualStrings("completeness", cap.records.items[0].check);
    try std.testing.expect(std.mem.indexOf(u8, cap.records.items[0].message, "deny_growth") != null);
}

test "lifecycle force_refresh rewrites the baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-baseline-refresh.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    _ = try lifecycle(a, path, try keyedLines(a, "demo", &.{ "alpha", "beta" }), false, true);

    const next = try keyedLines(a, "demo", &.{ "alpha", "gamma" });
    const out = try lifecycle(a, path, next, true, true);
    try std.testing.expect(out == .refreshed);

    // After refresh, the new state is the baseline.
    const out2 = try lifecycle(a, path, next, false, true);
    try std.testing.expect(out2 == .matched);
}

test "diffKeys ignores a pure line-number shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old: snapshot.Snapshot = .{
        .version = version,
        .lines = &.{"function-length|src/x.zig|fn foo is # lines (cap #)"},
    };
    const current = try keyedLines(a, "function-length", &.{"src/x.zig:559: fn foo is 246 lines (cap 200)"});
    const d = try diffKeys(a, old, current);
    try std.testing.expect(d.isEmpty());
}

test "diffKeys still flags a genuinely new violation amid shifts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old: snapshot.Snapshot = .{
        .version = version,
        .lines = &.{"nesting-depth|src/x.zig|fn foo reaches nesting depth # (cap #)"},
    };
    const current = try keyedLines(a, "nesting-depth", &.{
        "src/x.zig:14: fn foo reaches nesting depth 7 (cap 6)", // same violation, only moved
        "src/y.zig:99: fn bar reaches nesting depth 8 (cap 6)", // genuinely new
    });
    const d = try diffKeys(a, old, current);
    try std.testing.expectEqual(@as(usize, 1), d.added.len);
    try std.testing.expectEqualStrings("src/y.zig:99: fn bar reaches nesting depth 8 (cap 6)", d.added[0]);
    try std.testing.expectEqual(@as(usize, 0), d.removed.len);
}

test "diffKeys preserves multiplicity for count-based checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two identical-message hits in one file, both shifted → still a match (no churn).
    const old: snapshot.Snapshot = .{ .version = version, .lines = &.{
        "ban-fs|src/x.zig|std.fs.cwd reference outside allowed paths",
        "ban-fs|src/x.zig|std.fs.cwd reference outside allowed paths",
    } };
    const shifted = try keyedLines(a, "ban-fs", &.{
        "src/x.zig:7: std.fs.cwd reference outside allowed paths",
        "src/x.zig:60: std.fs.cwd reference outside allowed paths",
    });
    try std.testing.expect((try diffKeys(a, old, shifted)).isEmpty());
    // A third hit appears → exactly one new violation.
    const grown = try keyedLines(a, "ban-fs", &.{
        "src/x.zig:7: std.fs.cwd reference outside allowed paths",
        "src/x.zig:60: std.fs.cwd reference outside allowed paths",
        "src/x.zig:80: std.fs.cwd reference outside allowed paths",
    });
    const d = try diffKeys(a, old, grown);
    try std.testing.expectEqual(@as(usize, 1), d.added.len);
}

// spec: Baseline Mode - Prefixes a matching baseline or ratchet report with an ok marker

test "matching ratchet and baseline reports carry an ok pass marker" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    var matched = testReport(std.testing.allocator, null, &.{});
    matched.write_allowed = true;
    try reportRatchet("file-size", .{ .matched = 3 }, matched);
    try reportOutcome("naming", .{ .matched = 2 }, true);
    // The captured (uncolored) pass lines carry an explicit "ok:" marker so the
    // last line above a run summary can't be misread as the failing check.
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "ok: file-size: ratchet matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "ok: naming: baseline matches") != null);
}

// spec: Diff Scoping - Reports a partial view's baseline shrink as a match instead of resolved work

test "underPartialView keeps a scoped shrink from reading as resolved debt" {
    const shrunk: Outcome = .{ .shrunk = .{ .remaining = 2, .removed = 5 } };
    // Whole-tree: the shrink is real — those violations were fixed.
    const whole = underPartialView(.whole_tree, shrunk);
    try std.testing.expect(whole == .shrunk);
    // Partial: the five "removed" entries are simply files this run never read,
    // so the outcome reports the recorded size as matched, claiming nothing.
    const partial = underPartialView(.partial, shrunk);
    try std.testing.expect(partial == .matched);
    try std.testing.expectEqual(@as(usize, 7), partial.matched);
    // A genuinely new violation still fails, scoped or not.
    const grown: Outcome = .{ .grown = .{ .new_lines = &.{"src/a.zig: bad"}, .baseline_size = 1 } };
    try std.testing.expect(underPartialView(.partial, grown) == .grown);
}

// spec: Diff Scoping - Reports a partial view's ratchet improvement as a match instead of progress

test "ratchetUnderPartialView keeps a scoped improvement from lowering debt" {
    const improved: ratchet.Outcome = .{ .improved = .{ .lowered = 1, .pruned = 4, .remaining = 3 } };
    try std.testing.expect(ratchetUnderPartialView(.whole_tree, improved) == .improved);
    const partial = ratchetUnderPartialView(.partial, improved);
    try std.testing.expect(partial == .matched);
    try std.testing.expectEqual(@as(usize, 7), partial.matched);
    // A regression is a raised value in a file the run actually read — it fails
    // under either view.
    const regressed: ratchet.Outcome = .{ .regressed = .{
        .grown = &.{},
        .new_offenders = &.{.{ .key = "src/a.zig", .value = 9 }},
        .remaining = 1,
    } };
    try std.testing.expect(ratchetUnderPartialView(.partial, regressed) == .regressed);
}

// spec: Diff Scoping - Refuses every metadata write for a check that read only part of the tree

test "viewFor marks a scoped run partial so its metadata stays read-only" {
    const cfg: config_mod.Config = .{};
    var narrow: ast_index.Index = .{ .files = &.{} };
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .metadata_writable = true,
    };
    // A whole-tree check on a writable command may reconcile its metadata.
    try std.testing.expect(viewFor(&ctx) == .whole_tree);
    try std.testing.expect(ctx.metadata_writable and viewFor(&ctx) == .whole_tree);
    // The same command's per-file check under a diff scope may not: the write
    // gate in processOutcome ANDs these two, so a partial view never persists.
    ctx.scoped = .{ .base = "abc123", .file_count = 1, .index = &narrow };
    try std.testing.expect(viewFor(&ctx) == .partial);
    try std.testing.expect(!(ctx.metadata_writable and viewFor(&ctx) == .whole_tree));
}
