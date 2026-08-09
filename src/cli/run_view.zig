//! Presentation policy for an `all` run: the one `run-all:` verdict line every
//! exit path prints, how much of each check's captured output is replayed, and
//! how a stale-binary mismatch is described. Every decision here is pure — the
//! runner owns the terminal — so the *shape* of a gate's output is testable
//! without running a single check.
//!
//! Why it exists. A green whole-tree gate used to emit tens of thousands of
//! tokens of advisory detail ahead of its verdict, and a cache-skipped run
//! under `--quiet` emitted nothing at all — so an agent grepping for the
//! verdict could not tell "green" from "my pattern was wrong", and re-ran the
//! gate to find out. Three rules follow from that:
//!
//! 1. Every exit path — green, failing, cache-skipped — ends in one grep-stable
//!    `run-all:` line, printed on the always-visible channel.
//! 2. Default output groups a bounded sample beneath each blocking check;
//!    `--verbose` restores the original blocking-first replay.
//! 3. A non-blocking check whose findings all fall outside a diff-scoped run's
//!    changed files collapses to a single counted line; the detail stays in
//!    `.guardian/cache/last-run.jsonl` and returns under `--verbose`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reporter = @import("../reporter.zig");

/// Grep-stable opener every verdict line carries, on every exit path. An agent
/// that matches this one token can never mistake "no output" for "green".
pub const verdict_prefix = "run-all: ";

/// The verdict a cache-skipped run prints. Spelled out rather than composed so
/// the skip path cannot silently lose its line to an allocation failure.
const cached_verdict = verdict_prefix ++
    "cached — 0 blocking (inputs unchanged since last green run)";

/// How much of a run's output the caller asked for. `summary` is the default:
/// passing checks disappear, advisory checks collapse to counts, and blocking
/// findings move into a compact per-check group. `normal` preserves the former
/// scope-aware behavior for internal callers. `verbose` (`--verbose`) restores
/// every captured line.
pub const Verbosity = enum { summary, normal, verbose };

/// How one check's captured output is replayed: in full, as a single counted
/// stand-in line, or not at all (`summary` mode, for a check with no findings).
pub const Render = enum { full, collapsed, hidden };

/// What one check's finding set looks like to the printer. `in_scope` is how
/// many of those findings land in a diff-scoped run's changed files; on a
/// whole-tree run every finding is in scope, so `in_scope == findings` and
/// nothing ever collapses for scope reasons.
pub const Outcome = struct {
    /// True when the check failed and will block — never collapsed or hidden.
    blocking: bool = false,
    /// Blocking violations plus advisory warnings the check recorded.
    findings: usize = 0,
    /// Of those, how many fall inside the run's changed-file scope.
    in_scope: usize = 0,
};

/// How much of `o`'s check output to replay under verbosity `v`.
///
/// `--verbose` shows everything in full. Summary mode suppresses a blocking
/// check's raw capture because the runner prints its bounded group afterward;
/// advisory checks collapse to counts and passes disappear. Normal mode keeps
/// the historical scope-aware behavior.
pub fn renderFor(v: Verbosity, o: Outcome) Render {
    if (v == .verbose) return .full;
    if (v == .summary) return if (o.findings == 0 or o.blocking) .hidden else .collapsed;
    if (o.blocking) return .full;
    if (o.findings == 0) return .full;
    return if (o.in_scope == 0) .collapsed else .full;
}

/// The single line that stands in for a collapsed check: its name, how many
/// findings it has, whether any of them touch the diff, and where the detail
/// went. Deliberately carries the count — "44 finding(s)" is the number the
/// reader would otherwise have scrolled past to learn.
pub fn collapseLine(arena: Allocator, check: []const u8, o: Outcome) Allocator.Error![]const u8 {
    const scope_note = if (o.in_scope == 0) ", none in scope" else "";
    return std.fmt.allocPrint(
        arena,
        "{s}: {d} finding(s){s} — report-only (--verbose for detail)",
        .{ check, o.findings, scope_note },
    );
}

/// The counts one verdict line reports. `cached` marks the skip path, whose
/// verdict is fixed text; `names` is the comma-joined failing checks.
pub const Verdict = struct {
    /// How many checks executed this pass (0 on the cache-skip path).
    ran: u32 = 0,
    /// How many of them blocked.
    failed: u32 = 0,
    /// How many produced a policy-demoted, non-blocking finding.
    reported: u32 = 0,
    /// True when the suite was skipped because the inputs were unchanged.
    cached: bool = false,
    /// Comma-joined names of the failing checks ("?" when telemetry dropped).
    names: []const u8 = "?",
};

/// Renders the run's single verdict line — the same `run-all:` opener for the
/// green, failing, and cache-skipped paths, so one grep covers all three.
/// `scope_suffix` is the caller's " — diff-scoped vs …" tail (empty on a
/// whole-tree run). Never fails: an allocation failure degrades to a static
/// line that still carries the verdict and the prefix.
pub fn verdictLine(arena: Allocator, v: Verdict, scope_suffix: []const u8) []const u8 {
    return renderVerdict(arena, v, scope_suffix) catch verdictFallback(v);
}

fn renderVerdict(arena: Allocator, v: Verdict, scope_suffix: []const u8) Allocator.Error![]const u8 {
    if (v.cached) return cached_verdict;
    if (v.failed > 0) return std.fmt.allocPrint(
        arena,
        verdict_prefix ++ "{d}/{d} failed ({s}){s}{s}",
        .{ v.failed, v.ran, v.names, try reportedSuffix(arena, v.reported), scope_suffix },
    );
    if (v.reported > 0) return std.fmt.allocPrint(
        arena,
        verdict_prefix ++ "{d} checks — 0 blocking, {d} report-only{s}",
        .{ v.ran, v.reported, scope_suffix },
    );
    return std.fmt.allocPrint(arena, verdict_prefix ++ "{d} check(s) passed{s}", .{ v.ran, scope_suffix });
}

/// Tail naming how many checks only reported (the policy-demoted ones); empty
/// when nothing was demoted, so the common strict-profile summary is unchanged.
fn reportedSuffix(arena: Allocator, reported: u32) Allocator.Error![]const u8 {
    if (reported == 0) return "";
    return std.fmt.allocPrint(arena, " — {d} report-only", .{reported});
}

/// Static verdict used when rendering runs out of memory: the counts are lost
/// but the outcome and the grep-stable prefix survive.
fn verdictFallback(v: Verdict) []const u8 {
    if (v.cached) return cached_verdict;
    if (v.failed > 0) return verdict_prefix ++ "failed (verdict text unavailable)";
    return verdict_prefix ++ "passed (verdict text unavailable)";
}

/// The `" (+N more)"` tail appended to a failing check's echoed first finding.
/// Empty for a single finding, so the common case reads unchanged — and a check
/// that flagged five things can no longer look like it flagged one. Best-effort:
/// an allocation failure drops the tail rather than the finding.
pub fn moreSuffix(arena: Allocator, findings: usize) []const u8 {
    if (findings < 2) return "";
    return std.fmt.allocPrint(arena, " (+{d} more)", .{findings - 1}) catch "";
}

/// How many of `records` fall inside the changed-file set of a diff-scoped run.
/// A finding with no file attribution counts as in scope: scoping may only hide
/// what it can *prove* irrelevant, never what it cannot place.
pub fn inScope(changed: []const []const u8, records: []const reporter.Violation) usize {
    var n: usize = 0;
    for (records) |v| {
        const file = v.file orelse {
            n += 1;
            continue;
        };
        if (pathInScope(changed, file)) n += 1;
    }
    return n;
}

/// True when `file` names one of the run's changed paths. Exact match first;
/// otherwise either path may carry a directory prefix the other lacks (a check
/// reporting `src/a.zig` against a git path of the same file), so a `/`-boundary
/// suffix match counts too. Deliberately generous — a false "in scope" only
/// prints more, a false "out of scope" would hide something.
fn pathInScope(changed: []const []const u8, file: []const u8) bool {
    for (changed) |p| {
        if (std.mem.eql(u8, p, file)) return true;
        if (suffixPath(p, file) or suffixPath(file, p)) return true;
    }
    return false;
}

/// True when `long` ends with `short` at a path-separator boundary.
fn suffixPath(long: []const u8, short: []const u8) bool {
    if (short.len == 0 or long.len <= short.len) return false;
    if (!std.mem.endsWith(u8, long, short)) return false;
    return long[long.len - short.len - 1] == '/';
}

/// Which side of a guardian-binary mismatch is newer: the binary running now,
/// or the one that wrote the last green stamp. `unknown` when either timestamp
/// is unavailable or the two are identical.
pub const BinaryAge = enum { running_newer, stamp_newer, unknown };

/// Compares the running binary's mtime against the last green stamp's, so the
/// stale-binary warning can name a direction instead of just a mismatch. A
/// missing timestamp yields `unknown` rather than a guess.
pub fn binaryAge(running_mtime: ?i128, stamp_mtime: ?i128) BinaryAge {
    const running = running_mtime orelse return .unknown;
    const stamp = stamp_mtime orelse return .unknown;
    if (running > stamp) return .running_newer;
    if (running < stamp) return .stamp_newer;
    return .unknown;
}

/// The direction-specific half of the stale-binary warning: which binary is
/// newer and what to do about it. A newer *running* binary means the recorded
/// green is what is stale (re-run to re-establish it); a newer *stamp* means
/// this binary predates the last gated state and must be rebuilt first.
pub fn binaryAgeNote(age: BinaryAge) []const u8 {
    return switch (age) {
        .running_newer => "this binary is NEWER than the last green run, so the recorded green is the " ++
            "stale side — re-run the gate to re-establish it",
        .stamp_newer => "this binary is OLDER than the one that last gated the tree — " ++
            "rebuild (zig build) and re-run before accepting",
        .unknown => "neither side's age could be read — rebuild (zig build) and re-run before accepting",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Run Summary - Renders one verdict line for the green failing and cached exit paths

test "verdictLine keeps the run-all prefix on every exit path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Green, whole-tree: the historical wording, unchanged.
    try testing.expectEqualStrings(
        "run-all: 68 check(s) passed",
        verdictLine(a, .{ .ran = 68 }, ""),
    );
    // Green with a scope tail: a scoped green never reads as a full-tree green.
    try testing.expectEqualStrings(
        "run-all: 68 check(s) passed — diff-scoped vs abc, 2 file(s) in scope",
        verdictLine(a, .{ .ran = 68 }, " — diff-scoped vs abc, 2 file(s) in scope"),
    );
    // Failing: names the failing checks and separates demoted findings.
    try testing.expectEqualStrings(
        "run-all: 2/68 failed (type-size, naming) — 3 report-only",
        verdictLine(a, .{ .ran = 68, .failed = 2, .reported = 3, .names = "type-size, naming" }, ""),
    );
    // The cache-skip path — the one that used to print nothing under --quiet —
    // now carries the same grep-stable opener as every other verdict.
    try testing.expectEqualStrings(
        "run-all: cached — 0 blocking (inputs unchanged since last green run)",
        verdictLine(a, .{ .cached = true }, ""),
    );
    // Even the OOM fallback keeps the prefix, so the grep can never come up dry.
    try testing.expect(std.mem.startsWith(u8, verdictFallback(.{ .failed = 1 }), verdict_prefix));
    try testing.expect(std.mem.startsWith(u8, verdictFallback(.{}), verdict_prefix));
}

// spec: Run Summary - Separates blocking failures from report-only findings in the summary

test "verdictLine reports a demoted-only run as zero blocking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A profile that demotes style checks: the run is green, and the summary
    // says so explicitly rather than leaving the printed findings ambiguous.
    try testing.expectEqualStrings(
        "run-all: 68 checks — 0 blocking, 8 report-only",
        verdictLine(a, .{ .ran = 68, .reported = 8 }, ""),
    );
    // Nothing demoted: the strict-profile wording is untouched.
    try testing.expectEqualStrings("", try reportedSuffix(a, 0));
}

// spec: Run Summary - Collapses an out-of-scope report-only check to one counted line

test "renderFor collapses a non-blocking check whose findings miss the diff" {
    // The eda case: a whole-tree advisory check with 44 findings, none of them
    // in the two files this branch touched. One line, not forty-four.
    try testing.expectEqual(Render.collapsed, renderFor(.normal, .{ .findings = 44, .in_scope = 0 }));
    // One finding inside the scope: the whole check prints in full.
    try testing.expectEqual(Render.full, renderFor(.normal, .{ .findings = 44, .in_scope = 1 }));
    // A whole-tree run reports every finding as in scope, so nothing collapses.
    try testing.expectEqual(Render.full, renderFor(.normal, .{ .findings = 44, .in_scope = 44 }));
    // A blocking failure is never collapsed, whatever the scope says.
    try testing.expectEqual(
        Render.full,
        renderFor(.normal, .{ .blocking = true, .findings = 44, .in_scope = 0 }),
    );
    // A passing check has nothing to collapse.
    try testing.expectEqual(Render.full, renderFor(.normal, .{}));
}

// spec: Run Summary - Uses concise grouped output by default

test "summary mode hides captured blocking output and collapses advisory checks" {
    // Passing checks vanish: the verdict line already says they passed.
    try testing.expectEqual(Render.hidden, renderFor(.summary, .{}));
    // Advisory findings shrink to their count, in scope or not.
    try testing.expectEqual(Render.collapsed, renderFor(.summary, .{ .findings = 5, .in_scope = 5 }));
    try testing.expectEqual(Render.collapsed, renderFor(.summary, .{ .findings = 5, .in_scope = 0 }));
    // Blocking output is rendered later as a bounded, grouped summary.
    try testing.expectEqual(Render.hidden, renderFor(.summary, .{ .blocking = true, .findings = 1 }));
}

// spec: Run Summary - Keeps every check's full output under the verbose flag

test "verbose mode restores what scoping and summary would collapse" {
    // --verbose is the escape hatch: nothing is collapsed or hidden.
    try testing.expectEqual(Render.full, renderFor(.verbose, .{ .findings = 44, .in_scope = 0 }));
    try testing.expectEqual(Render.full, renderFor(.verbose, .{}));
    try testing.expectEqual(Render.full, renderFor(.verbose, .{ .blocking = true, .findings = 2 }));
}

// spec: Run Summary - Names the finding count and scope in a collapsed check line

test "collapseLine carries the count and where the detail went" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "repeated-string-literal: 44 finding(s), none in scope — report-only (--verbose for detail)",
        try collapseLine(a, "repeated-string-literal", .{ .findings = 44, .in_scope = 0 }),
    );
    // Under --summary the findings may well be in scope; the note drops out and
    // the count remains.
    try testing.expectEqualStrings(
        "line-length: 9 finding(s) — report-only (--verbose for detail)",
        try collapseLine(a, "line-length", .{ .findings = 9, .in_scope = 9 }),
    );
}

// spec: Run Summary - Appends a plus-N-more count when a failing check has several findings

test "moreSuffix names the findings the echo did not print" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // One finding: the echo is complete, so no tail.
    try testing.expectEqualStrings("", moreSuffix(a, 1));
    try testing.expectEqualStrings("", moreSuffix(a, 0));
    // Five new pub decls, one echoed line: the other four are named as a count
    // instead of looking like a checker coverage gap.
    try testing.expectEqualStrings(" (+4 more)", moreSuffix(a, 5));
}

// spec: Run Summary - Counts a finding as in scope when its file changed or it has no file

test "inScope places findings against the changed-file set" {
    const changed = [_][]const u8{ "src/a.zig", "src/sub/b.zig" };
    const records = [_]reporter.Violation{
        .{ .check = "x", .file = "src/a.zig", .message = "changed file" },
        .{ .check = "x", .file = "src/other.zig", .message = "untouched file" },
        .{ .check = "x", .message = "no file at all" },
    };
    // The changed file and the unplaceable finding count; the untouched one
    // does not — so a check with only untouched findings collapses.
    try testing.expectEqual(@as(usize, 2), inScope(&changed, &records));
    try testing.expectEqual(@as(usize, 0), inScope(&changed, &.{records[1]}));
    // A path reported with an extra directory prefix still matches at a
    // separator boundary, so a prefix mismatch can never hide a real finding.
    try testing.expect(pathInScope(&changed, "proj/src/a.zig"));
    try testing.expect(!pathInScope(&changed, "src/xa.zig"));
    try testing.expect(!suffixPath("src/a.zig", ""));
}

// spec: Run Summary - Names which binary is newer when the gating binary differs from the last green stamp

test "binaryAge names the newer side and its implied action" {
    // A rebuilt guardian against an older stamp: the recorded green is stale.
    try testing.expectEqual(BinaryAge.running_newer, binaryAge(200, 100));
    // A stale zig-out binary against a newer stamp: rebuild before believing it.
    try testing.expectEqual(BinaryAge.stamp_newer, binaryAge(100, 200));
    // No timestamp on either side, or a tie: no direction is claimed.
    try testing.expectEqual(BinaryAge.unknown, binaryAge(null, 200));
    try testing.expectEqual(BinaryAge.unknown, binaryAge(100, null));
    try testing.expectEqual(BinaryAge.unknown, binaryAge(100, 100));
    // Each direction names itself, and the stale-binary case says "rebuild".
    try testing.expect(std.mem.indexOf(u8, binaryAgeNote(.running_newer), "NEWER") != null);
    try testing.expect(std.mem.indexOf(u8, binaryAgeNote(.stamp_newer), "rebuild (zig build)") != null);
    try testing.expect(std.mem.indexOf(u8, binaryAgeNote(.unknown), "rebuild (zig build)") != null);
}
