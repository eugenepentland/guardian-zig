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
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const reporter = @import("reporter.zig");
const types = @import("cli/types.zig");
const snapshot_helper = @import("snapshot_helper.zig");
const ratchet = @import("ratchet.zig");
const accept_session = @import("accept_session.zig");
const violation_key = @import("violation_key.zig");

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

/// Multiset diff of a stored v3 baseline (identity keys) against the current
/// violations. Matching is by `Keyed.key` alone, so anything the key ignores —
/// source line numbers, counts and caps, and (for a check that sets an explicit
/// `identity`) the entire message wording — is neither added nor removed.
/// Multiplicity is preserved: N hits sharing one key still diff correctly, and a
/// genuinely new violation still surfaces as `added`, reported as its rendered
/// line rather than its key.
fn diffKeys(arena: Allocator, old: snapshot.Snapshot, current: []const Keyed) Allocator.Error!snapshot.Diff {
    const order = struct {
        fn lt(_: void, a: Keyed, b: Keyed) bool {
            const c = std.mem.order(u8, a.key, b.key);
            return if (c != .eq) c == .lt else std.mem.order(u8, a.line, b.line) == .lt;
        }
    }.lt;
    const olds = try arena.dupe([]const u8, old.lines);
    const news = try arena.dupe(Keyed, current);
    std.mem.sort([]const u8, olds, {}, lessThan);
    std.mem.sort(Keyed, news, {}, order);

    var added: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < olds.len and j < news.len) {
        switch (std.mem.order(u8, olds[i], news[j].key)) {
            .eq => {
                i += 1;
                j += 1;
            },
            .lt => {
                try removed.append(arena, olds[i]);
                i += 1;
            },
            .gt => {
                try added.append(arena, news[j].line);
                j += 1;
            },
        }
    }
    while (i < olds.len) : (i += 1) try removed.append(arena, olds[i]);
    while (j < news.len) : (j += 1) try added.append(arena, news[j].line);
    return .{ .added = try added.toOwnedSlice(arena), .removed = try removed.toOwnedSlice(arena) };
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
fn keyedViolations(
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
    const write_allowed = ctx.metadata_writable;
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    const violations = try keyedViolations(a, check_name, captured, records);

    // deny_growth: a refresh (global or selective) may only rewrite this
    // check's baseline if it doesn't grow. Guards the flagship 1:1 spec map —
    // today's fastest-growing frozen debt — from being ratified upward.
    try denyGrowthGuard(a, ctx, check_name, path, violations.len, force_refresh);

    const outcome = lifecycle(a, path, violations, force_refresh, write_allowed) catch |e| {
        reporter.fail("{s}: baseline I/O failed: {s}", .{ check_name, @errorName(e) });
        return error.CheckFailed;
    };

    return reportOutcome(check_name, outcome, write_allowed);
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

fn processRatchet(
    a: std.mem.Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    input: RatchetInput,
) types.RunError!void {
    std.debug.assert(ratchet.metricMode(check_name) != null);
    const path = try pathFor(a, ctx.project_dir, check_name);
    const blocking = try ratchet.aggregate(a, input.records, ratchet.metricMode(check_name).?);
    const entries = try preserveAdvisoryRatchets(a, path, blocking, input.warnings, input.force_refresh);
    try ratchetDenyGrowthGuard(a, ctx, check_name, path, entries, input.force_refresh);

    const outcome = ratchet.lifecycle(a, path, entries, input.force_refresh, input.write_allowed) catch |e| {
        reporter.fail("{s}: ratchet I/O failed: {s}", .{ check_name, @errorName(e) });
        return error.CheckFailed;
    };
    // Session accepts: an already-accepted check regrowing in the SAME
    // working session (no commit since the accept) re-accepts with a notice
    // instead of failing — the accept's intent was "this feature grows this
    // subject", and that intent holds until the commit locks the ratchet.
    // deny_growth still wins: a guarded check never rides a session note.
    if (outcome == .regressed and accept_session.isPending(a, ctx.project_dir, check_name)) {
        try ratchetDenyGrowthGuard(a, ctx, check_name, path, entries, true);
        // On a metadata-writable run the re-lock persists (commit locks the
        // ratchet). On an ordinary read-only run the growth is tolerated green
        // under the session note but nothing is written — the same read-only
        // contract as every other lifecycle write.
        if (input.write_allowed) {
            const relocked = ratchet.lifecycle(a, path, entries, true, true) catch |e| {
                reporter.fail("{s}: ratchet I/O failed: {s}", .{ check_name, @errorName(e) });
                return error.CheckFailed;
            };
            reporter.ok(
                "{s}: ratchet re-accepted under this session's pending accept ({d} key(s); locked)",
                .{ check_name, relocked.refreshed },
            );
        } else {
            reporter.ok(
                "{s}: ratchet growth tolerated under this session's pending accept (locks at commit)",
                .{check_name},
            );
        }
        return;
    }
    return reportRatchet(check_name, outcome, firstFixHint(input.captured), input.write_allowed);
}

/// Keeps a legacy ratchet entry while the same subject is still being reported
/// as advisory. Advisory findings never create or lower debt, but an upgrade
/// from a recommended-threshold ratchet to a warning/hard split must not erase
/// the committed entry merely because the finding moved out of the blocking
/// record set. Once the warning itself disappears, normal auto-pruning applies.
fn preserveAdvisoryRatchets(
    a: std.mem.Allocator,
    path: []const u8,
    blocking: []const ratchet.Entry,
    warnings: []const reporter.Violation,
    force_refresh: bool,
) types.RunError![]const ratchet.Entry {
    if (force_refresh or warnings.len == 0) return blocking;
    const snap = snapshot.read(a, path, ratchet.version) catch return blocking;
    const old = try ratchet.decodeLines(a, snap.lines);
    return mergeAdvisoryEntries(a, old, blocking, warnings);
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

/// deny_growth for a ratchet check: on a refresh of a listed check, refuse to
/// rewrite when the new state would raise any key's value or add a key. A
/// missing / v1 (pre-migration) file reads as no prior ratchet — a refresh that
/// first-records or migrates is never "growth", so it is allowed.
fn ratchetDenyGrowthGuard(
    a: std.mem.Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    path: []const u8,
    entries: []const ratchet.Entry,
    force_refresh: bool,
) types.RunError!void {
    if (!force_refresh) return;
    if (!nameInList(ctx.cfg.baseline.deny_growth, check_name)) return;
    const snap = snapshot.read(a, path, ratchet.version) catch return;
    const old = try ratchet.decodeLines(a, snap.lines);
    if (!try ratchet.wouldGrow(a, old, entries)) return;
    reporter.fail(
        "refusing to refresh {s}: ratchet would raise a value or add a key; " ++
            "fix the regressions or remove {s} from deny_growth",
        .{ check_name, check_name },
    );
    return error.CheckFailed;
}

/// Reports a ratchet outcome; `regressed` prints each grown / new-offender key
/// (with the check's own fix hint, scraped from its captured output) and fails.
fn reportRatchet(check_name: []const u8, outcome: ratchet.Outcome, fix_hint: ?[]const u8, write_allowed: bool) types.RunError!void {
    // On a read-only run the create/migrate/improve outcomes were classified but
    // not persisted — word them as pending, all green.
    if (!write_allowed) switch (outcome) {
        .created => |n| {
            reporter.ok("ok: {s}: {d} key(s) grandfathered (run `guardian-check accept {s} .` to record)", .{ check_name, n, check_name });
            return;
        },
        .migrated => |n| {
            reporter.ok("ok: {s}: legacy ratchet format ({d} key(s); run `guardian-check migrate .` to re-key)", .{ check_name, n });
            return;
        },
        .improved => |imp| {
            reporter.ok("ok: {s}: {d} lowered, {d} prunable (run `guardian-check accept {s} .` to record)", .{ check_name, imp.lowered, imp.pruned, check_name });
            return;
        },
        else => {},
    };
    switch (outcome) {
        .created => |n| reporter.ok("{s}: ratchet baselined ({d} key(s))", .{ check_name, n }),
        .migrated => |n| reporter.ok("{s}: migrated to per-item ratchet ({d} key(s))", .{ check_name, n }),
        .matched => |n| reporter.ok("ok: {s}: ratchet matches ({d} key(s))", .{ check_name, n }),
        .improved => |imp| reporter.ok(
            "{s}: {d} ratchet(s) lowered, {d} pruned (now {d} key(s))",
            .{ check_name, imp.lowered, imp.pruned, imp.remaining },
        ),
        .refreshed => |n| reporter.ok("{s}: ratchet refreshed ({d} key(s))", .{ check_name, n }),
        .regressed => |reg| return reportRegressed(check_name, reg, fix_hint),
    }
}

/// The failing half of `reportRatchet`, worded by growth class. A `volume`
/// check (file/type size) usually grew because a feature landed, so the header
/// says growth and the accept guidance leads; a `shape` check regressed
/// structurally, so the fix guidance leads and accept stays the last resort.
fn reportRegressed(check_name: []const u8, reg: ratchet.Regression, fix_hint: ?[]const u8) types.RunError!void {
    const n = reg.grown.len + reg.new_offenders.len;
    const class = ratchet.growthClass(check_name);
    switch (class) {
        .volume => reporter.fail(
            "{s}: {d} key(s) grew past ratchet — volume growth; review, then accept if intended",
            .{ check_name, n },
        ),
        .shape => reporter.fail("{s}: {d} key(s) regressed above ratchet", .{ check_name, n }),
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
    // A type-size subject that grew was sitting exactly at its frozen cap; make
    // the "you can't just add a field" insight explicit rather than implied.
    if (std.mem.eql(u8, check_name, "type-size") and reg.grown.len > 0) reporter.detail(
        "  this container is at its frozen cap; reduce a field or split it before adding another.\n",
        .{},
    );
    switch (class) {
        .volume => {
            reportAcceptCommand(check_name);
            if (fix_hint) |h| reporter.detail("  {s} (if the growth is accidental)\n", .{h});
        },
        .shape => {
            if (fix_hint) |h| reporter.detail("  {s}\n", .{h});
            reportAcceptCommand(check_name);
        },
    }
    return error.CheckFailed;
}

/// The first `fix:` hint line in a check's captured output (dedented), or null.
/// Reuses the check's own hint text for the ratchet regression message instead
/// of duplicating it in a table.
fn firstFixHint(captured: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, captured, '\n');
    while (it.next()) |raw| {
        const trimmed = leftTrim(raw);
        if (std.mem.startsWith(u8, trimmed, "fix:")) return trimmed;
    }
    return null;
}

/// Fails the run when `check_name` is in `[baseline] deny_growth` and a refresh
/// would grow its baseline. Only fires on the refresh path; an existing
/// baseline is required (initial creation is not "growth"). A no-op otherwise.
fn denyGrowthGuard(
    arena: Allocator,
    ctx: *types.RunCtx,
    check_name: []const u8,
    path: []const u8,
    new_count: usize,
    force_refresh: bool,
) types.RunError!void {
    const old_count = baselineViolationCount(arena, path);
    if (!growthDenied(ctx.cfg.baseline.deny_growth, check_name, old_count, new_count, force_refresh)) return;
    reporter.fail(
        "refusing to refresh {s}: baseline would grow {d}→{d}; " ++
            "fix the new violations or remove {s} from deny_growth",
        .{ check_name, old_count.?, new_count, check_name },
    );
    return error.CheckFailed;
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
        .created => |n| {
            reporter.ok("ok: {s}: {d} violation(s) grandfathered (run `guardian-check accept {s} .` to record)", .{ check_name, n, check_name });
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
        .created => |n| reporter.ok("{s}: baselined {d} violation(s)", .{ check_name, n }),
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
            reportAcceptCommand(check_name);
            return error.CheckFailed;
        },
        .grown => |g| {
            reporter.fail(
                "{s}: {d} new violation(s) above baseline of {d}",
                .{ check_name, g.new_lines.len, g.baseline_size },
            );
            for (g.new_lines) |line| reporter.detail("  {s}\n", .{line});
            reportAcceptCommand(check_name);
            return error.CheckFailed;
        },
    }
}

/// Prints both accept forms after a baseline/ratchet failure (C4). Raw CLI
/// leads because it always works; the `guardian-accept` build step exists only
/// when the consumer's build wired it, so it is qualified rather than assumed.
/// Keeps the `accept:` marker `reportRegressed` orders against the `fix:` hint.
fn reportAcceptCommand(check_name: []const u8) void {
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
    std.fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) }),
    };
}

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
        .check = "file-size",
        .file = "src/x.zig",
        .message = "1200 lines (recommended 1000; hard limit 10000)",
    });
}

test "runWithBaseline replays warnings without ratcheting them" {
    const dir = "zig-cache/test-baseline-warning";
    std.fs.cwd().deleteTree(dir) catch {};
    defer std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);

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

// spec: Per-Item Ratchets - Presents file and type growth as volume with accept-first guidance

test "reportRegressed words volume growth accept-first and shape regressions fix-first" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const reg: ratchet.Regression = .{
        .grown = &.{.{ .key = "src/x.zig", .old = 100, .new = 120 }},
        .new_offenders = &.{},
        .remaining = 1,
    };
    // file-size is a volume check: growth header, accept guidance first.
    try std.testing.expectError(error.CheckFailed, reportRegressed("file-size", reg, "fix: split the file"));
    const volume_out = try cap.buf.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(volume_out);
    try std.testing.expect(std.mem.indexOf(u8, volume_out, "volume growth") != null);
    const v_accept = std.mem.indexOf(u8, volume_out, "accept:").?;
    const v_fix = std.mem.indexOf(u8, volume_out, "fix:").?;
    try std.testing.expect(v_accept < v_fix);

    // function-length is a shape check: regression header, fix guidance first.
    try std.testing.expectError(error.CheckFailed, reportRegressed("function-length", reg, "fix: extract helpers"));
    const shape_out = cap.buf.items;
    try std.testing.expect(std.mem.indexOf(u8, shape_out, "regressed above ratchet") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_out, "volume growth") == null);
    const s_fix = std.mem.indexOf(u8, shape_out, "fix:").?;
    const s_accept = std.mem.indexOf(u8, shape_out, "accept:").?;
    try std.testing.expect(s_fix < s_accept);
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
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));

    // Record it with a writable run, then resolve one violation on a read-only
    // run: the shrink is reported but the committed baseline is left untouched.
    _ = try lifecycle(a, path, two, false, true);
    const before = try std.fs.cwd().readFileAlloc(a, path, 4096);
    const one = try keyedLines(a, "demo", &.{"alpha"});
    try std.testing.expect((try lifecycle(a, path, one, false, false)) == .shrunk);
    const after = try std.fs.cwd().readFileAlloc(a, path, 4096);
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
    const before = try std.fs.cwd().readFileAlloc(a, path, 4096);

    // The same violation, only shifted to a new line (an unrelated edit grew the
    // file above it), must match — and must NOT rewrite the committed baseline,
    // so a source-only diff stays clean (C1a).
    const at_42 = try keyedLines(a, "ban-fs", &.{"src/x.zig:42: std.fs.cwd reference outside allowed paths"});
    try std.testing.expect((try lifecycle(a, path, at_42, false, true)) == .matched);
    const after = try std.fs.cwd().readFileAlloc(a, path, 4096);
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
    const on_disk = try std.fs.cwd().readFileAlloc(a, path, 4096);

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
    try std.testing.expectEqualStrings(on_disk, try std.fs.cwd().readFileAlloc(a, path, 4096));

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
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
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

    try reportRatchet("file-size", .{ .matched = 3 }, null, true);
    try reportOutcome("naming", .{ .matched = 2 }, true);
    // The captured (uncolored) pass lines carry an explicit "ok:" marker so the
    // last line above a run summary can't be misread as the failing check.
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "ok: file-size: ratchet matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "ok: naming: baseline matches") != null);
}
