//! `[measurement]` — the instrumentation bridge.
//!
//! Profiling a hot path means patching in scaffolding the gate exists to
//! forbid: `pub var` per-cause counters, a `std.time.nanoTimestamp`
//! accumulator, a `std.debug.print` inside the loop. Those are not the code
//! being shipped — they are read once and deleted — but the gate cannot tell
//! them apart from production code, so the only supported workflow was "patch
//! it in, build with the gate failing, run, read, `git checkout` the file".
//! The gate and the diagnostic build were two different worlds with no bridge.
//!
//! `[measurement] paths = ["src/placement/router.zig", "src/bench"]` builds the
//! bridge and puts it on exactly the right half of the boundary:
//!
//!   * On an ordinary LOCAL run (a build-wired `all`, `guardian-check all
//!     <dir>`), an instrumentation-class finding inside a listed path is routed
//!     to a non-blocking MEASURE channel instead of failing the check. Every
//!     such run prints a standing one-line reminder naming the paths and live
//!     counts, so instrumentation cannot linger unnoticed.
//!   * At COMMIT time, under `--gate`, on `nightly`, and on any run that may
//!     WRITE `.guardian/` metadata (`accept`, `migrate`, a pending
//!     `GUARDIAN_UPDATE_SNAPSHOT` refresh), the exemption is VOID: the same
//!     findings block exactly as they do today, and no snapshot or baseline can
//!     be recorded from an exempted view. Nothing extra can ship — into history
//!     or into Guardian's own metadata.
//!   * An absent or empty `[measurement]` section is exactly today's behavior
//!     everywhere (`paths.len == 0` short-circuits every decision below).
//!
//! ## Which checks are instrumentation-class, and why
//!
//! The set is deliberately narrow: a check qualifies only when the thing it
//! flags IS the act of instrumenting, so that inside a measurement path its
//! finding carries no information the commit-time run won't carry identically.
//!
//!   * `ban-globals` — a profiling counter is a file-scope `pub var`
//!     (`pub var dbg_via_reason: [8]usize`). There is no other shape for
//!     "count this across calls without threading a parameter through a hot
//!     loop"; the check's own fix ("scope it to a struct field") is the change
//!     you are trying to avoid making while measuring.
//!   * `ban-time` — a phase timer is `std.time.nanoTimestamp` /
//!     `std.time.Timer.start`. The check's fix is to inject a Clock port, which
//!     is precisely the production plumbing a throwaway measurement must not
//!     grow.
//!   * `debug-print-ban` — `std.debug.print` in the loop under study is the
//!     canonical read-out. Its fix (route through a reporter/log port) again
//!     asks for plumbing that exists only to be deleted.
//!   * `stdout-flush` — the sibling of the above: a hand-rolled buffered dump
//!     of the counters at the end of a run. It is already report-only by
//!     default, so the exemption only matters for a project that promoted it.
//!   * `pub-api-surface` — a counter another module reads must be `pub`, so the
//!     API snapshot drifts for the lifetime of the experiment. Its drift is
//!     filtered per file, and the snapshot is never REWRITTEN from an exempted
//!     view (a refresh voids the exemption), so the surface a commit records is
//!     always the real one.
//!
//! Everything else is deliberately excluded, in particular: correctness and
//! safety checks (`catch-discipline`, `error-discipline`, `panic-budget`,
//! `unsafe-ops-budget`, `ban-secrets`, `allocator-hygiene`, `oom-discipline`),
//! which are exactly as load-bearing in a file being measured as anywhere else;
//! the spec workflow (`spec`, `completeness`, `change-classification`), which is
//! about the shape of the change rather than the shape of the code; and the
//! shape ratchets (`function-length`, `file-size`, `cognitive-complexity`, …),
//! which is a different and much larger request — an "experimental area" exempt
//! from the authoring tax — that this section deliberately does not answer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reporter = @import("reporter.zig");
const types = @import("cli/types.zig");
const snapshot_helper = @import("snapshot_helper.zig");
const Config = @import("config.zig").Config;

/// The check names a `[measurement]` path may defer on a local run. See the
/// module header for the per-check justification; membership is compiled in
/// (not configurable) so a project cannot widen the bridge into the safety,
/// spec, or shape checks by editing its own guardian.toml.
const instrumentation_checks = [_][]const u8{
    "ban-globals",
    "ban-time",
    "debug-print-ban",
    "stdout-flush",
    "pub-api-surface",
};

/// True when `check_name` is instrumentation-class — the only checks a
/// `[measurement]` path can defer.
pub fn isInstrumentationClass(check_name: []const u8) bool {
    for (instrumentation_checks) |name| {
        if (std.mem.eql(u8, name, check_name)) return true;
    }
    return false;
}

/// The four run facts the exemption decision reads, bundled so the decision is
/// one testable pure function over plain data (and so no caller passes three
/// anonymous booleans).
pub const RunFacts = struct {
    /// How many `[measurement] paths` entries are configured. Zero disables
    /// the bridge outright — an absent section is today's behavior.
    path_count: usize = 0,
    /// The run BLOCKS on violations: `--gate`, `commit`, `nightly`, `accept`,
    /// `migrate`.
    gate: bool = false,
    /// The run may PERSIST `.guardian/` metadata.
    metadata_writable: bool = false,
    /// A snapshot/baseline refresh is pending (`accept` set, or the
    /// `GUARDIAN_UPDATE_SNAPSHOT` env alias), which writes without the gate flag.
    refresh_pending: bool = false,
};

/// Pure exemption decision, factored out so the airtight half is testable
/// without a run: the bridge is live only for a run that neither BLOCKS nor
/// WRITES `.guardian/` metadata. Voiding on the writing runs is what keeps an
/// exempted view out of every recorded snapshot and baseline, not just out of
/// git history.
pub fn liveFor(facts: RunFacts) bool {
    if (facts.path_count == 0) return false;
    return !facts.gate and !facts.metadata_writable and !facts.refresh_pending;
}

/// True when this run has a snapshot/baseline refresh pending — an explicit
/// `accept` set or the `GUARDIAN_UPDATE_SNAPSHOT` env alias.
fn refreshPending(ctx: *const types.RunCtx) bool {
    return ctx.refresh.len > 0 or snapshot_helper.shouldUpdate(ctx.allocator);
}

/// True when the `[measurement]` bridge is live for this run (see `liveFor`).
pub fn active(ctx: *const types.RunCtx) bool {
    return liveFor(.{
        .path_count = ctx.cfg.measurement.paths.len,
        .gate = ctx.gate,
        .metadata_writable = ctx.metadata_writable,
        .refresh_pending = refreshPending(ctx),
    });
}

/// True when `rel_path` (walker-relative, e.g. "src/placement/router.zig") sits
/// under `pattern`: an exact file match, or a directory prefix ("src/bench" or
/// "src/bench/"). Deliberately NOT the substring/glob matcher the `[[allow]]`
/// path lists use — an instrumentation allowlist is a boundary, and a stray `*`
/// or a bare filename that happens to be a substring of another path must not
/// silently widen it. A pattern with a wildcard therefore matches nothing (the
/// parser rejects one outright, so this is only the second line of defence).
pub fn pathCovers(pattern: []const u8, rel_path: []const u8) bool {
    const prefix = std.mem.trimEnd(u8, pattern, "/");
    if (prefix.len == 0) return false;
    if (std.mem.eql(u8, prefix, rel_path)) return true;
    if (rel_path.len <= prefix.len) return false;
    return std.mem.startsWith(u8, rel_path, prefix) and rel_path[prefix.len] == '/';
}

/// One check's live exemption for one run: the paths it may defer findings
/// into, plus the findings it actually deferred. A zero-value handle is inert —
/// `covers` is always false — which is what every non-instrumentation check,
/// and every gating run, gets.
pub const Exemption = struct {
    allocator: Allocator,
    check: []const u8 = "",
    /// Empty when the bridge is not live for this check/run.
    paths: []const []const u8 = &.{},
    deferred: std.ArrayList(reporter.Measured) = .empty,

    /// Frees the deferred-finding list. The findings themselves are borrowed
    /// (arena-owned by the running check), so only the list is released.
    pub fn deinit(self: *Exemption) void {
        self.deferred.deinit(self.allocator);
    }

    /// True when `rel_path` is inside one of this exemption's measurement
    /// paths, so its findings must be deferred rather than blocked.
    pub fn covers(self: *const Exemption, rel_path: []const u8) bool {
        for (self.paths) |pattern| {
            if (pathCovers(pattern, rel_path)) return true;
        }
        return false;
    }

    /// Defers one finding (already rendered to its violation line) into the
    /// measurement channel. Callers must drop it from their blocking list.
    pub fn record(self: *Exemption, rel_path: []const u8, line: []const u8) Allocator.Error!void {
        try self.deferred.append(self.allocator, .{
            .check = self.check,
            .path = rel_path,
            .message = line,
        });
    }

    /// Prints this check's MEASURE report (a distinct, non-blocking verb) and
    /// hands each deferred finding to the reporter so the run-level standing
    /// reminder can aggregate it. No-op when nothing was deferred.
    pub fn report(self: *Exemption) Allocator.Error!void {
        if (self.deferred.items.len == 0) return;
        reporter.ok("MEASURE {s} ({d} in {s} — exempt locally, blocks commit)", .{
            self.check,
            self.deferred.items.len,
            try joinPaths(self.allocator, self.deferred.items),
        });
        for (self.deferred.items) |m| reporter.measure(m);
    }
};

/// Builds `check_name`'s exemption handle for this run: live paths when the
/// bridge applies, an inert handle otherwise.
pub fn forCheck(allocator: Allocator, ctx: *const types.RunCtx, check_name: []const u8) Exemption {
    if (!isInstrumentationClass(check_name) or !active(ctx)) return .{ .allocator = allocator };
    return .{
        .allocator = allocator,
        .check = check_name,
        .paths = ctx.cfg.measurement.paths,
    };
}

/// Distinct paths named by `records`, comma-joined in first-seen order.
fn joinPaths(allocator: Allocator, records: []const reporter.Measured) Allocator.Error![]const u8 {
    const paths = try distinctPaths(allocator, records);
    return std.mem.join(allocator, ", ", paths);
}

/// The distinct `path` values of `records`, in first-seen order.
fn distinctPaths(allocator: Allocator, records: []const reporter.Measured) Allocator.Error![]const []const u8 {
    var seen: std.ArrayList([]const u8) = .empty;
    for (records) |m| {
        if (!containsPath(seen.items, m.path)) try seen.append(allocator, m.path);
    }
    return seen.toOwnedSlice(allocator);
}

fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

/// Renders the run-level standing reminder — one line naming every measurement
/// path with live findings and its per-check counts — or null when nothing was
/// deferred. Printed on every local run with active exemptions so scaffolding
/// cannot sit in the tree silently: the counts are the "you still have this
/// patched in" signal, and the tail names the boundary it will hit.
pub fn standingReminder(allocator: Allocator, records: []const reporter.Measured) Allocator.Error!?[]const u8 {
    if (records.len == 0) return null;
    const paths = try distinctPaths(allocator, records);
    var segments: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        const counts = try checkCounts(allocator, records, path);
        try segments.append(allocator, try std.fmt.allocPrint(allocator, "{s} ({s})", .{ path, counts }));
    }
    const line = try std.fmt.allocPrint(
        allocator,
        "MEASURE: {d} finding(s) exempt by [measurement] — {s} — void at commit; strip before you ship",
        .{ records.len, try std.mem.join(allocator, "; ", segments.items) },
    );
    return line;
}

/// Renders `<check> <count>` pairs for every check with findings under `path`.
fn checkCounts(allocator: Allocator, records: []const reporter.Measured, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (instrumentation_checks) |name| {
        const n = countFor(records, path, name);
        if (n == 0) continue;
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s} {d}", .{ name, n }));
    }
    return std.mem.join(allocator, ", ", parts.items);
}

/// How many records under `path` came from `check_name`.
fn countFor(records: []const reporter.Measured, path: []const u8, check_name: []const u8) usize {
    var n: usize = 0;
    for (records) |m| {
        if (std.mem.eql(u8, m.path, path) and std.mem.eql(u8, m.check, check_name)) n += 1;
    }
    return n;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn testCtx(cfg: *const Config) types.RunCtx {
    return .{
        .allocator = testing.allocator,
        .project_dir = ".",
        .cfg = cfg,
        .quiet = true,
    };
}

// spec: Measurement Mode - Defers only the instrumentation-class checks

test "isInstrumentationClass names the bridged checks and nothing else" {
    // The five checks that fire on the ACT of instrumenting.
    try testing.expect(isInstrumentationClass("ban-globals"));
    try testing.expect(isInstrumentationClass("ban-time"));
    try testing.expect(isInstrumentationClass("debug-print-ban"));
    try testing.expect(isInstrumentationClass("stdout-flush"));
    try testing.expect(isInstrumentationClass("pub-api-surface"));
    // Correctness/safety, spec-workflow, and shape checks are never bridged.
    try testing.expect(!isInstrumentationClass("catch-discipline"));
    try testing.expect(!isInstrumentationClass("panic-budget"));
    try testing.expect(!isInstrumentationClass("ban-secrets"));
    try testing.expect(!isInstrumentationClass("spec"));
    try testing.expect(!isInstrumentationClass("file-size"));
    // A sibling hidden-dependency ban that is NOT about instrumentation.
    try testing.expect(!isInstrumentationClass("ban-fs"));
}

// spec: Measurement Mode - Voids the exemption for gating and metadata-writing runs

test "liveFor exempts only a local read-only run" {
    // The one live case: paths configured, not gating, not writing metadata.
    try testing.expect(liveFor(.{ .path_count = 1 }));
    // --gate / commit / nightly / accept / migrate all force the block.
    try testing.expect(!liveFor(.{ .path_count = 1, .gate = true }));
    // A metadata-writable run must see the real violation set before it
    // records a baseline or snapshot from it.
    try testing.expect(!liveFor(.{ .path_count = 1, .metadata_writable = true }));
    // So must a pending accept / GUARDIAN_UPDATE_SNAPSHOT refresh, which writes
    // without going through the gate flag.
    try testing.expect(!liveFor(.{ .path_count = 1, .refresh_pending = true }));
    // An absent or empty [measurement] section is exactly today's behavior.
    try testing.expect(!liveFor(.{}));
}

// spec: Measurement Mode - Matches a measurement path by exact file or directory prefix

test "pathCovers matches a file and a directory prefix but never a substring" {
    // Exact file.
    try testing.expect(pathCovers("src/placement/router.zig", "src/placement/router.zig"));
    // Directory prefix, with or without the trailing slash.
    try testing.expect(pathCovers("src/bench", "src/bench/loop.zig"));
    try testing.expect(pathCovers("src/bench/", "src/bench/deep/loop.zig"));
    // A prefix that is not a path boundary must not match.
    try testing.expect(!pathCovers("src/bench", "src/benchmarks/loop.zig"));
    // Not a substring matcher: a bare leaf name never widens the bridge.
    try testing.expect(!pathCovers("router.zig", "src/placement/router.zig"));
    // A wildcard is not a glob here — it simply matches nothing.
    try testing.expect(!pathCovers("src/*", "src/placement/router.zig"));
    // Degenerate patterns are inert.
    try testing.expect(!pathCovers("", "src/x.zig"));
    try testing.expect(!pathCovers("/", "src/x.zig"));
}

// spec: Measurement Mode - Hands each check an inert exemption unless the bridge applies

test "forCheck arms only an instrumentation check on a live run" {
    const cfg: Config = .{ .measurement = .{ .paths = &.{"src/placement/router.zig"} } };
    var ctx = testCtx(&cfg);

    const armed = forCheck(testing.allocator, &ctx, "ban-globals");
    try testing.expect(armed.covers("src/placement/router.zig"));
    try testing.expect(!armed.covers("src/placement/solver.zig"));

    // A non-instrumentation check is inert even with paths configured.
    const other = forCheck(testing.allocator, &ctx, "catch-discipline");
    try testing.expect(!other.covers("src/placement/router.zig"));

    // A gating run disarms the instrumentation check too.
    ctx.gate = true;
    const gated = forCheck(testing.allocator, &ctx, "ban-globals");
    try testing.expect(!gated.covers("src/placement/router.zig"));

    // No [measurement] section: inert everywhere.
    const bare: Config = .{};
    const plain_ctx = testCtx(&bare);
    const plain = forCheck(testing.allocator, &plain_ctx, "ban-globals");
    try testing.expect(!plain.covers("src/placement/router.zig"));
    try testing.expect(!active(&plain_ctx));
}

// spec: Measurement Mode - Reports deferred findings under a non-blocking MEASURE verb

test "an exemption reports its deferred findings without failing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    var ex: Exemption = .{
        .allocator = a,
        .check = "ban-globals",
        .paths = &.{"src/placement/router.zig"},
    };
    defer ex.deinit();
    // Nothing deferred yet: no output at all.
    try ex.report();
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);

    const line = "src/placement/router.zig:41: mutable global var outside wiring/main";
    try ex.record("src/placement/router.zig", line);
    try ex.record("src/placement/router.zig", line);
    try ex.report();
    // The distinct verb, the count, and the path — never the word FAILED.
    const header = "MEASURE ban-globals (2 in src/placement/router.zig";
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, header) != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "blocks commit") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "FAILED") == null);
    // Each finding is recorded for the run-level reminder.
    try testing.expectEqual(@as(usize, 2), cap.measured.items.len);
    try testing.expectEqualStrings("ban-globals", cap.measured.items[0].check);
}

// spec: Measurement Mode - Prints a standing reminder naming every exempted path and count

test "standingReminder lists paths with per-check counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const records = [_]reporter.Measured{
        .{ .check = "ban-globals", .path = "src/router.zig", .message = "x" },
        .{ .check = "ban-globals", .path = "src/router.zig", .message = "y" },
        .{ .check = "ban-time", .path = "src/router.zig", .message = "z" },
        .{ .check = "debug-print-ban", .path = "src/bench/loop.zig", .message = "w" },
    };
    const line = (try standingReminder(a, &records)).?;
    try testing.expect(std.mem.indexOf(u8, line, "4 finding(s) exempt by [measurement]") != null);
    try testing.expect(std.mem.indexOf(u8, line, "src/router.zig (ban-globals 2, ban-time 1)") != null);
    try testing.expect(std.mem.indexOf(u8, line, "src/bench/loop.zig (debug-print-ban 1)") != null);
    try testing.expect(std.mem.indexOf(u8, line, "void at commit") != null);
    // No deferred findings: no reminder line at all.
    try testing.expect((try standingReminder(a, &.{})) == null);
}
