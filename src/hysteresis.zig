//! Hysteresis for the hard-cap ratchets: trip → no accept → shrink to recover.
//!
//! Why. On one consumer the three largest files sat at 100–103% of the 10000
//! code-line hard cap while nothing else was within 57% of it — organic growth
//! does not produce that shape; the gate pinned them there. Two leaks kept the
//! equilibrium: a crossing could be ratified with one env var (five
//! ceiling-raising accepts on one file in nine days), and an entry whose
//! subject dipped back under the cap PRUNED, restoring free regrowth to cap−1
//! (one file crossed at 10002, was trimmed under, pruned, and parked at 9983).
//! See AUDIT-2026-08-11-thresholds.md.
//!
//! What this adds for each check named in `[hysteresis] checks`:
//!
//!   1. A hard-cap crossing is UNACCEPTABLE. `accept` and
//!      `GUARDIAN_UPDATE_SNAPSHOT` refuse to record the new entry or to raise
//!      an existing one, the way `[baseline] deny_growth` already refuses
//!      growth. The failure leads with the fix and names the recover target.
//!   2. The trip is REMEMBERED. Dropping back under the hard cap no longer
//!      prunes the entry: it follows the measurement DOWN (a shrink lands green
//!      even while still over the cap) and clears only at the recover line,
//!      `recover_pct` below the hard cap — 8000 of 10000 at the default 20%.
//!   3. While tripped, GROWTH BLOCKS and SHRINKING LANDS. A commit that leaves
//!      the subject smaller is always green; one that grows it fails with no
//!      accept to reach for. That is the frozen-ceiling dynamic that produced
//!      the one real paydown in the evidence, minus the accept escape.
//!
//! Everything here is pure. It receives the recorded entries, this run's
//! blocking records and its advisory warnings, and returns the entry set the
//! ratchet lifecycle should compare — plus what recovered and what is
//! recovering, for the report. Below the hard cap a two-tier check emits only
//! ADVISORY records, and those carry `ratchet_key` + `metric`, so they ARE the
//! recovery-zone measurement: nothing here re-measures the tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ratchet = @import("ratchet.zig");
const reporter = @import("reporter.zig");
const config_mod = @import("config.zig");
const scope = @import("scope.zig");
const near_cap = @import("near_cap.zig");

/// The two-tier checks by name, spelled once so the list, the cap lookup and
/// the tests below cannot drift from each other.
const file_size_check = "file-size";
const function_length_check = "function-length";
const line_length_check = "line-length";

/// The only checks hysteresis can bind: the two-tier ones, which warn at a
/// recommended limit and block at a generous hard cap. A single-tier check
/// (nesting depth, params, fields) gates AT its cap, so it has no band between
/// "fine" and "blocked" for a trip to live in, and naming one is a config
/// error rather than a silently inert setting.
pub const supported = [_][]const u8{ file_size_check, function_length_check, line_length_check };

/// Lowest accepted `recover_pct`. Below 1% the dead-band rounds away on every
/// realistic cap and hysteresis would silently degrade to today's prune.
pub const min_recover_pct: u32 = 1;

/// Highest accepted `recover_pct`. Past 90% the recover line approaches zero,
/// which mandates deleting the subject rather than shrinking it.
pub const max_recover_pct: u32 = 90;

/// Denominator of every percentage below, named so the arithmetic reads as a
/// share rather than an unexplained literal.
const percent: u64 = 100;

/// True when `check_name` is one of the two-tier checks hysteresis can bind.
pub fn isSupported(check_name: []const u8) bool {
    for (supported) |name| {
        if (std.mem.eql(u8, name, check_name)) return true;
    }
    return false;
}

/// One check's resolved hysteresis rule: the cap a crossing trips, the line a
/// recovery clears at, and the aggregation mode (which decides whether the
/// recovery zone exists at all — see `tracksRecovery`).
pub const Policy = struct {
    check: []const u8,
    hard_cap: u64,
    recover: u64,
    mode: ratchet.AggMode,

    /// True when `value` is a hard-cap crossing — the state that may never be
    /// accepted. In `count` mode the ratcheted value is the NUMBER of records
    /// past the hard cap, so any non-zero count is a crossing.
    pub fn isCrossing(self: Policy, value: u64) bool {
        return switch (self.mode) {
            .max => value > self.hard_cap,
            .count => value > 0,
        };
    }

    /// True when `value` has reached the recover line, clearing the trip.
    pub fn hasRecovered(self: Policy, value: u64) bool {
        return value <= self.recover;
    }

    /// True when this policy has a recovery zone to track. Only `max` mode
    /// does: its advisory records measure the SAME dimension as the ratcheted
    /// value (a file's code lines, a function's line span), so a warning can be
    /// compared against the entry. A `count` ratchet holds the number of lines
    /// past the hard cap while its warnings count lines past the RECOMMENDED
    /// one — different dimensions, so its only recover line is zero, which is
    /// where the ordinary prune already fires.
    pub fn tracksRecovery(self: Policy) bool {
        return self.mode == .max;
    }
};

/// The recover line for `hard_cap` at `pct`: the cap less that share of it.
/// Integer arithmetic, so a truncating division only ever moves the line UP
/// (a tighter recovery), never below what was configured.
pub fn recoverLine(hard_cap: u64, pct: u32) u64 {
    return hard_cap - hard_cap * pct / percent;
}

/// The hysteresis rule in force for `check_name`, or null when there is none —
/// the section is disabled, the check is not listed, or it is not a two-tier
/// check. Callers treat null as "plain ratchet semantics, exactly as before",
/// which is what makes `enabled = false` a true parity switch.
pub fn policyFor(cfg: *const config_mod.Config, check_name: []const u8) ?Policy {
    if (!cfg.hysteresis.enabled) return null;
    if (!isSupported(check_name)) return null;
    if (!nameInList(cfg.hysteresis.checks, check_name)) return null;
    const mode = ratchet.metricMode(check_name) orelse return null;
    const hard_cap = hardCapFor(cfg, check_name) orelse return null;
    return .{
        .check = check_name,
        .hard_cap = hard_cap,
        // A count ratchet has no comparable band (see `tracksRecovery`), so its
        // trip clears exactly where the ordinary prune does: at zero.
        .recover = if (mode == .max) recoverLine(hard_cap, cfg.hysteresis.recover_pct) else 0,
        .mode = mode,
    };
}

/// The configured hard cap of a two-tier check, or null for any other name.
pub fn hardCapFor(cfg: *const config_mod.Config, check_name: []const u8) ?u64 {
    if (std.mem.eql(u8, check_name, file_size_check)) return cfg.hard_max_file_lines;
    if (std.mem.eql(u8, check_name, function_length_check)) return cfg.function_length.hard_max_lines;
    if (std.mem.eql(u8, check_name, line_length_check)) return cfg.line_length.hard_max_len;
    return null;
}

/// What a check's pre-trip alert should say a crossing costs. Under a bound
/// policy the usual escape — cross the cap, then accept the crossing — no
/// longer exists, and the last warning before the crossing must not imply it
/// does (see near_cap.Crossing).
pub fn crossingFor(cfg: *const config_mod.Config, check_name: []const u8) near_cap.Crossing {
    return if (policyFor(cfg, check_name) == null) .blocks else .unacceptable;
}

/// One entry whose subject reached the recover line: the trip clears and the
/// entry prunes. `value` is null when the subject reported nothing at all this
/// run — it fell below the recommended tier (or left the tree), which is far
/// under the recover line either way.
pub const Recovered = struct {
    key: []const u8,
    value: ?u64,
    recover: u64,
};

/// What hysteresis makes of this run: the entry set to compare, the trips it
/// cleared, and the entries now measuring inside the recovery zone (carried at
/// their RECORDED ceiling, so a report can say what the subject grew from).
pub const Plan = struct {
    entries: []const ratchet.Entry = &.{},
    recovered: []const Recovered = &.{},
    recovering: []const ratchet.Entry = &.{},

    /// The recorded ceiling of `key` when it is recovering, else null — how the
    /// report tells a below-the-cap regression from an above-the-cap one.
    pub fn recoveringCeiling(self: Plan, key: []const u8) ?u64 {
        for (self.recovering) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

/// Reconciles the recorded entries against this run for a hysteresis check,
/// replacing the plain advisory-preserve merge.
///
/// `recorded` is the ratchet on file with any relocation already applied,
/// `blocking` this run's aggregated over-the-hard-cap records, and `warnings`
/// its advisory records (the recovery-zone measurement). The returned
/// `entries` feed `ratchet.lifecycle` unchanged, so the ordinary classifier
/// produces the hysteresis verdicts: a recovering subject that grew reads as a
/// grown key (fail), one that shrank as a lowered key (auto-lower), and a
/// cleared trip as a pruned one.
///
/// A `partial` view HOLDS every entry that reported nothing, at its recorded
/// value: a diff-scoped run cannot tell a recovered subject from one that was
/// simply out of scope, and clearing a trip on that guess would hand back the
/// prune loophole. Entries the run DID see are compared normally, so growth
/// while tripped still fails on a scoped run.
pub fn reconcile(
    a: Allocator,
    policy: Policy,
    recorded: []const ratchet.Entry,
    blocking: []const ratchet.Entry,
    warnings: []const reporter.Violation,
    view: scope.View,
) Allocator.Error!Plan {
    const advisory = if (policy.tracksRecovery())
        try ratchet.aggregate(a, warnings, policy.mode)
    else
        &[_]ratchet.Entry{};
    var entries: std.ArrayList(ratchet.Entry) = .empty;
    try entries.appendSlice(a, blocking);
    var recovered: std.ArrayList(Recovered) = .empty;
    var recovering: std.ArrayList(ratchet.Entry) = .empty;
    for (recorded) |e| {
        if (valueFor(blocking, e.key) != null) continue; // still over the hard cap
        const current = valueFor(advisory, e.key) orelse {
            if (view == .partial) {
                try entries.append(a, e); // unseen, not resolved
                continue;
            }
            try recovered.append(a, .{ .key = e.key, .value = null, .recover = policy.recover });
            continue;
        };
        if (policy.hasRecovered(current)) {
            try recovered.append(a, .{ .key = e.key, .value = current, .recover = policy.recover });
            continue;
        }
        // The live measurement becomes the compared value, so shrinking
        // auto-lowers the ceiling and growing fails — the trip's whole point.
        try entries.append(a, .{ .key = e.key, .value = current });
        try recovering.append(a, e);
    }
    return .{
        .entries = try entries.toOwnedSlice(a),
        .recovered = try recovered.toOwnedSlice(a),
        .recovering = try recovering.toOwnedSlice(a),
    };
}

/// Why a refresh of a hysteresis check is refused.
pub const RefusalKind = enum {
    /// A key the ratchet never held, measuring past the hard cap.
    crossing,
    /// An existing key whose ceiling the refresh would raise.
    raise,
};

/// The first thing an accept must not record, with the numbers its message
/// needs.
pub const Refusal = struct {
    kind: RefusalKind,
    key: []const u8,
    value: u64,
    /// The ceiling a `raise` would replace; 0 for a `crossing`.
    ceiling: u64 = 0,
};

/// The first entry a refresh may not write, or null when the refresh only
/// holds, lowers, prunes or RELOCATES entries — the moves and improvements an
/// accept still exists to record. Entries are key-sorted, so the answer is
/// deterministic. Never called with `recorded == null`: creating a ratchet for
/// the first time grandfathers its offenders, tripped, exactly as before.
pub fn refusalFor(
    policy: Policy,
    recorded: []const ratchet.Entry,
    entries: []const ratchet.Entry,
) ?Refusal {
    for (entries) |e| {
        const old = valueFor(recorded, e.key) orelse {
            if (policy.isCrossing(e.value)) return .{ .kind = .crossing, .key = e.key, .value = e.value };
            continue;
        };
        if (e.value > old) return .{ .kind = .raise, .key = e.key, .value = e.value, .ceiling = old };
    }
    return null;
}

/// The detail line for a hard-cap crossing: what it measures, that it cannot be
/// accepted, and the number that clears it.
pub fn crossingDetail(
    a: Allocator,
    policy: Policy,
    key: []const u8,
    value: u64,
    unit: []const u8,
) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        a,
        "{s}: {s} — {d} {s} exceeds the hard cap {d} — a hard-cap crossing cannot be accepted; " ++
            "reduce to <={d} (the recover line) to clear",
        .{ policy.check, key, value, unit, policy.hard_cap, policy.recover },
    );
}

/// The detail line for a tripped entry that grew while still over the hard cap:
/// the ceiling only ever tightens, and no accept can loosen it.
pub fn overCapDetail(
    a: Allocator,
    policy: Policy,
    key: []const u8,
    grown: ratchet.GrownKey,
    unit: []const u8,
) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        a,
        "{s}: {s} — {d} {s} over its tripped ceiling of {d}, still past the hard cap {d} — " ++
            "the ceiling cannot be raised; only a shrink lands (clears at <={d})",
        .{ policy.check, key, grown.new, unit, grown.old, policy.hard_cap, policy.recover },
    );
}

/// The detail line for growth inside the recovery zone — the state that used to
/// be free, because the entry had been pruned the moment the subject dipped
/// under the cap.
pub fn recoveringDetail(
    a: Allocator,
    policy: Policy,
    key: []const u8,
    grown: ratchet.GrownKey,
    unit: []const u8,
) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        a,
        "{s}: {s} — {d} {s}, grew while recovering from a hard-cap trip (was {d}) — " ++
            "growth blocks until it reaches <={d}; shrinking commits land freely",
        .{ policy.check, key, grown.new, unit, grown.old, policy.recover },
    );
}

/// The sink's `fix_hint` for a blocked key: the recover target, always, because
/// a machine reader has no accept command to fall back on here.
pub fn fixHint(a: Allocator, policy: Policy, unit: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        a,
        "reduce to <={d} {s} (the recover line, {d}% under the hard cap {d}); " ++
            "a hard-cap trip cannot be accepted — only a shrink clears it",
        .{ policy.recover, unit, pctBelow(policy), policy.hard_cap },
    );
}

/// The green line for a cleared trip, printed like relocation's `moved:` lines
/// so every "this entry changed identity or status" report reads the same way.
pub fn recoveredLine(a: Allocator, rec: Recovered, unit: []const u8) Allocator.Error![]const u8 {
    const value = rec.value orelse return std.fmt.allocPrint(
        a,
        "{s} — now below the warning tier, under the recover line {d}; hard-cap trip cleared",
        .{ rec.key, rec.recover },
    );
    return std.fmt.allocPrint(
        a,
        "{s} — {d} {s} at or below the recover line {d}; hard-cap trip cleared",
        .{ rec.key, value, unit, rec.recover },
    );
}

/// The standing note under a hysteresis failure: where the policy is configured
/// and what an accept can still do, so "no accept" never reads as "no path".
pub fn policyNote(a: Allocator, policy: Policy) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        a,
        "hysteresis: [hysteresis] in guardian.toml holds {s} at a {d}% recover band " ++
            "(hard cap {d}, clears at {d}); accept still records shrinks, prunes and moves",
        .{ policy.check, pctBelow(policy), policy.hard_cap, policy.recover },
    );
}

/// The share of the hard cap the recover line sits below it, recomputed from
/// the two numbers so a rendered message can never disagree with the policy it
/// describes (the configured percentage is not carried on `Policy`).
fn pctBelow(policy: Policy) u64 {
    if (policy.hard_cap == 0) return 0;
    return (policy.hard_cap - policy.recover) * percent / policy.hard_cap;
}

/// The recorded value for `key`, or null when `entries` has no such key.
fn valueFor(entries: []const ratchet.Entry, key: []const u8) ?u64 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

fn nameInList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// One advisory (below-the-hard-cap) record, the shape the two-tier checks emit
/// for a file between their recommended and hard limits.
fn warned(key: []const u8, metric: u64) reporter.Violation {
    return .{ .check = file_size_check, .message = "advisory", .ratchet_key = key, .metric = metric };
}

/// The default file-size policy: 10000 hard cap, 20% band → clears at 8000.
fn filePolicy() Policy {
    const cfg: config_mod.Config = .{};
    return policyFor(&cfg, file_size_check).?;
}

// spec: Hysteresis - Derives each check's recover line from its hard cap and recover percentage

test "recoverLine and the default policies put the band 20% under each hard cap" {
    const cfg: config_mod.Config = .{};
    const file = policyFor(&cfg, file_size_check).?;
    try testing.expectEqual(@as(u64, 10_000), file.hard_cap);
    try testing.expectEqual(@as(u64, 8000), file.recover);
    const func = policyFor(&cfg, function_length_check).?;
    try testing.expectEqual(@as(u64, 400), func.hard_cap);
    try testing.expectEqual(@as(u64, 320), func.recover);
    // Each cap comes from that check's own configured hard limit, and only a
    // two-tier check has one to read.
    try testing.expectEqual(@as(?u64, 10_000), hardCapFor(&cfg, file_size_check));
    try testing.expectEqual(@as(?u64, 240), hardCapFor(&cfg, line_length_check));
    try testing.expect(hardCapFor(&cfg, "type-size") == null);
    // The recover line is the boundary: on it recovers, one above does not.
    try testing.expect(file.hasRecovered(8000));
    try testing.expect(!file.hasRecovered(8001));
    // A bound check's pre-trip alert says the crossing is unacceptable.
    try testing.expect(crossingFor(&cfg, file_size_check) == .unacceptable);
    try testing.expect(crossingFor(&cfg, "type-size") == .blocks);
    // The arithmetic itself, including a truncating division (which can only
    // tighten the line, never loosen it).
    try testing.expectEqual(@as(u64, 8000), recoverLine(10_000, 20));
    try testing.expectEqual(@as(u64, 5000), recoverLine(10_000, 50));
    try testing.expectEqual(@as(u64, 4), recoverLine(7, 50)); // 7 - 3 (3.5 truncated)
    // line-length is supported but not listed by default, so no policy binds.
    try testing.expect(policyFor(&cfg, line_length_check) == null);
    // A single-tier check gates AT its cap and can never be listed.
    try testing.expect(!isSupported("type-size"));
    try testing.expect(isSupported(line_length_check));
    // Listing it does bind it — with a zero recover line, because its ratcheted
    // value counts records rather than measuring the capped dimension.
    const counting: config_mod.Config = .{ .hysteresis = .{ .checks = &.{"line-length"} } };
    const lines = policyFor(&counting, line_length_check).?;
    try testing.expect(!lines.tracksRecovery());
    try testing.expectEqual(@as(u64, 0), lines.recover);
    try testing.expect(lines.isCrossing(1));
    try testing.expect(!lines.isCrossing(0));
}

// spec: Hysteresis - Restores plain ratchet behavior when hysteresis is disabled

test "a disabled section or an unlisted check binds no policy at all" {
    const off: config_mod.Config = .{ .hysteresis = .{ .enabled = false } };
    try testing.expect(policyFor(&off, file_size_check) == null);
    try testing.expect(policyFor(&off, function_length_check) == null);
    // Enabled, but the check is not in the list.
    const narrowed: config_mod.Config = .{ .hysteresis = .{ .checks = &.{"function-length"} } };
    try testing.expect(policyFor(&narrowed, file_size_check) == null);
    try testing.expect(policyFor(&narrowed, function_length_check) != null);
    // A non-two-tier name never binds even if it somehow reached the list.
    const bogus: config_mod.Config = .{ .hysteresis = .{ .checks = &.{"type-size"} } };
    try testing.expect(policyFor(&bogus, "type-size") == null);
}

// spec: Hysteresis - Keeps a tripped entry recorded while its subject stays above the recover line

test "reconcile follows a recovering subject down without clearing the trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const policy = filePolicy();
    const recorded = [_]ratchet.Entry{.{ .key = "src/big.zig", .value = 10_273 }};

    // 8900 code lines: under the hard cap, over the recover line. Today the
    // entry would prune here and the file could regrow to 9999 for free.
    const plan = try reconcile(a, policy, &recorded, &.{}, &.{warned("src/big.zig", 8900)}, .whole_tree);
    try testing.expectEqual(@as(usize, 0), plan.recovered.len);
    try testing.expectEqual(@as(usize, 1), plan.entries.len);
    try testing.expectEqual(@as(u64, 8900), plan.entries[0].value);
    // The recorded ceiling rides along so a report can say what it grew from.
    try testing.expectEqual(@as(?u64, 10_273), plan.recoveringCeiling("src/big.zig"));
    // Which the ordinary classifier reads as an auto-lower: green, and the
    // entry keeps its (now tighter) ceiling.
    const lowered = try ratchet.classify(a, &recorded, plan.entries);
    try testing.expect(lowered == .improved);
    try testing.expectEqual(@as(usize, 1), lowered.improved.lowered);
}

// spec: Hysteresis - Fails a tripped entry that grew while recovering below the hard cap

test "reconcile turns growth inside the recovery zone into a ratchet regression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const policy = filePolicy();
    const recorded = [_]ratchet.Entry{.{ .key = "src/big.zig", .value = 8900 }};
    const plan = try reconcile(a, policy, &recorded, &.{}, &.{warned("src/big.zig", 8950)}, .whole_tree);
    const grew = try ratchet.classify(a, &recorded, plan.entries);
    try testing.expect(grew == .regressed);
    try testing.expectEqual(@as(u64, 8900), grew.regressed.grown[0].old);
    try testing.expectEqual(@as(u64, 8950), grew.regressed.grown[0].new);
    // Holding exactly still is green, with nothing to write.
    const held = try reconcile(a, policy, &recorded, &.{}, &.{warned("src/big.zig", 8900)}, .whole_tree);
    try testing.expect((try ratchet.classify(a, &recorded, held.entries)) == .matched);
}

// spec: Hysteresis - Clears the trip and prunes the entry at or below the recover line

test "reconcile clears a trip only once the subject reaches the recover line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const policy = filePolicy();
    const recorded = [_]ratchet.Entry{.{ .key = "src/big.zig", .value = 8900 }};

    // One line above the line: still tripped.
    const short = try reconcile(a, policy, &recorded, &.{}, &.{warned("src/big.zig", 8001)}, .whole_tree);
    try testing.expectEqual(@as(usize, 0), short.recovered.len);
    // Exactly on it: cleared.
    const on_line = try reconcile(a, policy, &recorded, &.{}, &.{warned("src/big.zig", 8000)}, .whole_tree);
    try testing.expectEqual(@as(usize, 1), on_line.recovered.len);
    try testing.expectEqual(@as(usize, 0), on_line.entries.len);
    try testing.expectEqual(@as(?u64, 8000), on_line.recovered[0].value);
    // And a subject that stopped reporting at all — below the warning tier, or
    // gone — is further below the line than any record could show.
    const silent = try reconcile(a, policy, &recorded, &.{}, &.{}, .whole_tree);
    try testing.expectEqual(@as(usize, 1), silent.recovered.len);
    try testing.expect(silent.recovered[0].value == null);
    try testing.expect((try ratchet.classify(a, &recorded, silent.entries)) == .improved);
}

// spec: Hysteresis - Leaves an unratcheted subject in the advisory band untouched

test "reconcile adds nothing for a warning with no recorded entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two files in the advisory band; only one was ever tripped. The free zone
    // has to stay free — hysteresis binds what crossed, nothing else.
    const recorded = [_]ratchet.Entry{.{ .key = "src/tripped.zig", .value = 9000 }};
    const warnings = [_]reporter.Violation{
        warned("src/tripped.zig", 8900),
        warned("src/free.zig", 9500),
    };
    const plan = try reconcile(a, filePolicy(), &recorded, &.{}, &warnings, .whole_tree);
    try testing.expectEqual(@as(usize, 1), plan.entries.len);
    try testing.expectEqualStrings("src/tripped.zig", plan.entries[0].key);
}

// spec: Hysteresis - Holds an entry that reported nothing on a diff-scoped run

test "a partial view holds an unseen entry and still judges the ones in scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recorded = [_]ratchet.Entry{
        .{ .key = "src/out.zig", .value = 9000 },
        .{ .key = "src/in.zig", .value = 8500 },
    };
    // Only src/in.zig was in scope, and it grew. src/out.zig reported nothing —
    // which on a scoped run means "not read", never "recovered".
    const plan = try reconcile(a, filePolicy(), &recorded, &.{}, &.{warned("src/in.zig", 8600)}, .partial);
    try testing.expectEqual(@as(usize, 0), plan.recovered.len);
    try testing.expectEqual(@as(u64, 9000), valueFor(plan.entries, "src/out.zig").?);
    const outcome = try ratchet.classify(a, &recorded, plan.entries);
    try testing.expect(outcome == .regressed);
    try testing.expectEqual(@as(usize, 1), outcome.regressed.grown.len);
    try testing.expectEqualStrings("src/in.zig", outcome.regressed.grown[0].key);
}

// spec: Hysteresis - Refuses an accept that records a crossing or raises a tripped ceiling

test "refusalFor blocks a crossing and a raise but allows shrinks, prunes and moves" {
    const policy = filePolicy();
    const recorded = [_]ratchet.Entry{.{ .key = "src/big.zig", .value = 10_273 }};

    // A brand-new key past the hard cap: the accept eda ran five times in nine
    // days on one file.
    const crossed = [_]ratchet.Entry{ recorded[0], .{ .key = "src/new.zig", .value = 10_007 } };
    const crossing = refusalFor(policy, &recorded, &crossed).?;
    try testing.expect(crossing.kind == .crossing);
    try testing.expectEqualStrings("src/new.zig", crossing.key);
    try testing.expectEqual(@as(u64, 10_007), crossing.value);

    // Raising the tripped ceiling.
    const raised = [_]ratchet.Entry{.{ .key = "src/big.zig", .value = 10_520 }};
    const raise = refusalFor(policy, &recorded, &raised).?;
    try testing.expect(raise.kind == .raise);
    try testing.expectEqual(@as(u64, 10_273), raise.ceiling);

    // Everything an accept still exists for: a shrink, a prune, and a
    // relocation (the recorded set already carries the new key).
    try testing.expect(refusalFor(policy, &recorded, &.{.{ .key = "src/big.zig", .value = 9900 }}) == null);
    try testing.expect(refusalFor(policy, &recorded, &.{}) == null);
    const moved = [_]ratchet.Entry{.{ .key = "src/moved.zig", .value = 10_273 }};
    try testing.expect(refusalFor(policy, &moved, &moved) == null);
}

// spec: Hysteresis - Names the recover target in every blocked message and hint

test "the rendered lines name the cap, the recover line, and what accept can still do" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const policy = filePolicy();

    try testing.expectEqualStrings(
        "file-size: src/serve/router.zig — 10007 code lines exceeds the hard cap 10000 — " ++
            "a hard-cap crossing cannot be accepted; reduce to <=8000 (the recover line) to clear",
        try crossingDetail(a, policy, "src/serve/router.zig", 10_007, "code lines"),
    );
    try testing.expectEqualStrings(
        "file-size: src/big.zig — 8950 code lines, grew while recovering from a hard-cap trip " ++
            "(was 8900) — growth blocks until it reaches <=8000; shrinking commits land freely",
        try recoveringDetail(a, policy, "src/big.zig", .{ .key = "src/big.zig", .old = 8900, .new = 8950 }, "code lines"),
    );
    const over = try overCapDetail(a, policy, "src/big.zig", .{ .key = "x", .old = 10_273, .new = 10_400 }, "code lines");
    try testing.expect(std.mem.indexOf(u8, over, "over its tripped ceiling of 10273") != null);
    try testing.expect(std.mem.indexOf(u8, over, "only a shrink lands (clears at <=8000)") != null);

    // The machine-readable remedy carries the same target as the console.
    const hint = try fixHint(a, policy, "code lines");
    try testing.expect(std.mem.indexOf(u8, hint, "reduce to <=8000 code lines") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "20% under the hard cap 10000") != null);
    // The recovered line, both shapes.
    try testing.expectEqualStrings(
        "src/big.zig — 7990 code lines at or below the recover line 8000; hard-cap trip cleared",
        try recoveredLine(a, .{ .key = "src/big.zig", .value = 7990, .recover = 8000 }, "code lines"),
    );
    const quiet = try recoveredLine(a, .{ .key = "src/big.zig", .value = null, .recover = 8000 }, "code lines");
    try testing.expect(std.mem.indexOf(u8, quiet, "now below the warning tier") != null);
    // And the standing note points at the knobs rather than at an accept.
    const note = try policyNote(a, policy);
    try testing.expect(std.mem.indexOf(u8, note, "[hysteresis] in guardian.toml") != null);
    try testing.expect(std.mem.indexOf(u8, note, "accept still records shrinks, prunes and moves") != null);
}
