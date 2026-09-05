//! assert-density: an AGGREGATE, per-module ratchet on assertion density, plus
//! the measurement the `debt --assert-density` appendix prints. One module here
//! measures it for both, so the gate and the report cannot drift (the same
//! single-source rule `file_size.codeLines` already enforces for line counts).
//!
//! WHY. TigerBeetle's `docs/TIGER_STYLE.md` states it normatively and verbatim:
//! "The assertion density of the code must average a minimum of two assertions
//! per function", in the context "Assert all function arguments and return
//! values, pre/postconditions and invariants." The same rule is NASA/JPL's
//! Power of Ten Rule 5, so two independent safety-critical traditions state it
//! — it is not an invented Guardian rule.
//!
//! WHAT IS ACTUALLY CHECKED, AND WHAT IS NOT. AUDIT-2026-07-10-ZIG-PATTERNS.md
//! line 42 already recorded the honest verdict for this idea: "metric: yes;
//! placement: no". Density is decidable by counting; TIGER_STYLE's real
//! substance is PLACEMENT — asserting arguments, return values, preconditions,
//! postconditions, invariants, and the paired assertion on both sides of a
//! two-path computation — and counting cannot verify any of it. A module can
//! hit any density number with every assertion in the wrong place. This check
//! measures the metric and says so; it does not claim to enforce the style.
//!
//! THREE DELIBERATE LIMITS.
//! 1. AGGREGATE, NOT PER-FUNCTION. TIGER_STYLE mandates an AVERAGE. A
//!    per-function hard floor would be strictly stricter than the source
//!    states, so the ratchet is one floor per top-level `src/` module and the
//!    normative 2-per-function figure is reported tree-wide as context only.
//! 2. TRIVIALITY FILTER. The risk here is gaming, not false positives: an agent
//!    can clear any density ratchet with `assert(true)`. Power of Ten
//!    anticipates exactly that in the rule text — an assertion a static checker
//!    can prove never fails (or never holds) does not satisfy the rule. An
//!    assert whose whole argument is constant-foldable (no identifier other
//!    than `true`/`false`/`null`/`undefined`, no builtin) is therefore not
//!    counted, and each such site is named. `assert(x == x)` still slips
//!    through: deciding that needs the semantic analysis Guardian does not have.
//! 3. ADVISORY, NEVER BLOCKING. `run` has no failing exit path. A fallen floor
//!    is a `reporter.warn`, so nothing about assertion counting can refuse a
//!    commit — which is also why the anti-gaming pressure stays low. Reporting
//!    also sits inside a 10% band: the FLOOR is strict (it never drifts down by
//!    a hair) but a warning needs a real dilution, since adding one line to an
//!    11k-line module otherwise printed a finding.
//!
//! SCOPE. Density is a whole-tree aggregate, so a diff-scoped run HOLDS the
//! recorded floor: it compares and reports, and writes nothing. That is
//! Guardian's standing rule that a scoped run never prunes, lowers or rewrites
//! a ratchet, applied to a metric a partial file set cannot even compute.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const text = @import("../text.zig");
const file_size = @import("file_size.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;
const ok = reporter.ok;

pub const check_name = "assert-density";
const snapshot_leaf = "assert-density.txt";
const snapshot_version: u32 = 1;

/// Lines per KLOC — the denominator scale the density metric is quoted in.
const lines_per_kloc: u64 = 1000;

/// TIGER_STYLE's normative average, in hundredths of an assertion per function
/// ("must average a minimum of two assertions per function"). Reported, never
/// enforced: see the module header's limit 1.
const tiger_style_centi_per_fn: u64 = 200;

/// The four bare words Zig tokenizes as identifiers but which are compile-time
/// constants, not references to anything. An assertion built only from these
/// (and literals and operators) is the padding the triviality filter exists to
/// reject.
const constant_idents = [_][]const u8{ "true", "false", "null", "undefined" };

/// One module's aggregate measurement. `asserts` counts only SUBSTANTIVE
/// assertion sites outside `test { ... }` blocks; `trivial` counts the
/// constant-foldable ones that were rejected; `code_lines` is `file_size`'s
/// production-line metric, so the denominator excludes blanks, comments and
/// test bodies exactly as the file-size gate does.
pub const ModuleStats = struct {
    module: []const u8,
    asserts: u64 = 0,
    trivial: u64 = 0,
    fns: u64 = 0,
    code_lines: u64 = 0,
};

/// What one whole-tree measurement produced: the per-module rows (ascending by
/// density, sparsest first) and every rejected constant-foldable site.
pub const Report = struct {
    modules: []const ModuleStats,
    trivial_sites: []const reporter.Violation,
};

/// One file's contribution, before it is folded into its module.
pub const FileCounts = struct {
    asserts: u32 = 0,
    trivial: u32 = 0,
    fns: u32 = 0,
    code_lines: u32 = 0,
};

/// One file's counts plus the 1-indexed line of each rejected trivial assert,
/// so the check can name the padding rather than only subtract it.
pub const FileMeasure = struct {
    counts: FileCounts = .{},
    trivial_lines: []const u32 = &.{},
};

// ── Measurement ────────────────────────────────────────────────────────

/// The top-level `src/` module of `rel_path`: the first path segment under
/// `src/` (a subdir name like `ast`, or a loose file name like `snapshot.zig`)
/// — the same top-level structure the project's module layout is organized
/// around, and the granularity at which an "average" is a fair statement.
pub fn moduleOf(rel_path: []const u8) []const u8 {
    const prefix = "src/";
    const rest = if (std.mem.startsWith(u8, rel_path, prefix)) rel_path[prefix.len..] else rel_path;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return rest;
    return rest[0..slash];
}

/// True when `name` is one of Zig's bare constant words. Those tokenize as
/// identifiers, so without this list `assert(true)` would read as substantive.
fn isConstantIdent(name: []const u8) bool {
    for (constant_idents) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

/// True when a token inside an assert's argument list refers to something the
/// compiler cannot fold away: any identifier that is not a bare constant word,
/// or any builtin call. Literals, operators and keywords are all foldable.
fn isSubstantiveToken(z: [:0]const u8, t: std.zig.Token) bool {
    return switch (t.tag) {
        .identifier => !isConstantIdent(z[t.loc.start..t.loc.end]),
        .builtin => true,
        else => false,
    };
}

/// True when the argument list opened by the `(` at `open` is constant-foldable
/// — `assert(true)`, `assert(1 == 1)`, `assert(!false)`, `assert()`. Power of
/// Ten Rule 5 excludes exactly these: an assertion a static checker can decide
/// does not satisfy the rule, which is what makes them useless as ratchet
/// currency. Scans to the matching `)` so a nested call's arguments are seen.
fn argIsConstantFoldable(z: [:0]const u8, toks: []const std.zig.Token, open: usize) bool {
    var depth: u32 = 0;
    var i = open;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        switch (t.tag) {
            .l_paren => {
                depth += 1;
                continue;
            },
            .r_paren => {
                depth -= 1;
                if (depth == 0) return true;
                continue;
            },
            // An unbalanced tail cannot be judged; treat it as padding rather
            // than credit an assertion the parser would reject anyway.
            .eof => return true,
            else => {},
        }
        if (isSubstantiveToken(z, t)) return false;
    }
    return true;
}

/// Every token of `z` including the final `.eof`, so the scan below can look
/// one token ahead without bounds-checking against the tokenizer.
fn tokenize(allocator: Allocator, z: [:0]const u8) Allocator.Error![]std.zig.Token {
    var list: std.ArrayList(std.zig.Token) = .empty;
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        try list.append(allocator, t);
        if (t.tag == .eof) break;
    }
    return list.toOwnedSlice(allocator);
}

/// True when the token at `i` opens an `assert(` call: the identifier `assert`
/// followed immediately by `(`. Matching on the identifier alone covers both
/// `assert(...)` and `std.debug.assert(...)`; tokenizing (rather than substring
/// matching) means an `assert(` inside a string or comment never counts, and
/// `const assert = std.debug.assert;` is a binding, not a call.
fn opensAssertCall(z: [:0]const u8, toks: []const std.zig.Token, i: usize) bool {
    const t = toks[i];
    if (t.tag != .identifier) return false;
    if (!std.mem.eql(u8, z[t.loc.start..t.loc.end], "assert")) return false;
    return i + 1 < toks.len and toks[i + 1].tag == .l_paren;
}

/// True when the token at `i` declares a NAMED function (`fn <ident>`), the
/// denominator of TIGER_STYLE's per-function average. An anonymous `fn (…) T`
/// in a function-pointer type is not a declaration and is not counted.
fn declaresFn(toks: []const std.zig.Token, i: usize) bool {
    return toks[i].tag == .keyword_fn and i + 1 < toks.len and toks[i + 1].tag == .identifier;
}

/// Measures one file: substantive assert sites, rejected trivial sites (with
/// their lines), named function declarations, and production code lines.
/// Everything inside a `test { ... }` block is skipped on both sides of the
/// ratio — a test suite's own assertions are not the production invariants
/// TIGER_STYLE is about, and counting them would let adding tests raise the
/// floor of the code they test. Pure: takes source text, touches no filesystem.
pub fn measureFile(allocator: Allocator, content: [:0]const u8) Allocator.Error!FileMeasure {
    const toks = try tokenize(allocator, content);
    var scope: text.TestScope = .{};
    var counts: FileCounts = .{ .code_lines = try file_size.codeLines(content) };
    var trivial_lines: std.ArrayList(u32) = .empty;
    for (toks, 0..) |t, i| {
        scope.update(t.tag);
        if (scope.in_test) continue;
        if (declaresFn(toks, i)) counts.fns += 1;
        if (!opensAssertCall(content, toks, i)) continue;
        if (argIsConstantFoldable(content, toks, i + 1)) {
            counts.trivial += 1;
            try trivial_lines.append(allocator, text.lineOf(content, t.loc.start));
        } else {
            counts.asserts += 1;
        }
    }
    return .{ .counts = counts, .trivial_lines = try trivial_lines.toOwnedSlice(allocator) };
}

/// Walk state: the arena, the module → totals map, and the trivial-site list.
const ScanCtx = struct {
    allocator: Allocator,
    tallies: *std.StringHashMapUnmanaged(ModuleStats),
    trivial_sites: *std.ArrayList(reporter.Violation),
};

/// The advisory line a rejected constant-foldable assertion prints.
const trivial_message = "constant-foldable assert() — not counted toward assert density";

/// The remedy attached to a rejected constant-foldable assertion.
const trivial_fix = "assert a real condition, or delete the line — a constant-foldable " ++
    "assert satisfies neither TIGER_STYLE nor Power of Ten Rule 5";

/// The remedy attached to a module that fell below its floor. Lowering a floor
/// takes an accept that NAMES this check; a broad refresh will not do it.
const regression_fix = "assert a real precondition/postcondition in the module, or accept the " ++
    "lower floor with `guardian-check accept assert-density .`";

/// Visitor: fold one src file's measurement into its module and record any
/// padding it contains.
fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const m = try measureFile(ctx.allocator, entry.content);
    const gop = try ctx.tallies.getOrPut(ctx.allocator, moduleOf(entry.rel_path));
    if (!gop.found_existing) gop.value_ptr.* = .{ .module = moduleOf(entry.rel_path) };
    gop.value_ptr.asserts += m.counts.asserts;
    gop.value_ptr.trivial += m.counts.trivial;
    gop.value_ptr.fns += m.counts.fns;
    gop.value_ptr.code_lines += m.counts.code_lines;
    for (m.trivial_lines) |line| try ctx.trivial_sites.append(ctx.allocator, .{
        .check = check_name,
        .file = entry.rel_path,
        .line = line,
        .message = trivial_message,
        .identity = trivial_message,
    });
}

/// Measures every `src/` file, grouped by top-level module and sorted ascending
/// (sparsest module first). `index` is the run's shared parsed-source index when
/// there is one; whole-tree checks always receive the FULL index, so this is the
/// whole tree even on a diff-scoped run.
pub fn collect(
    allocator: Allocator,
    project_dir: []const u8,
    index: ?*const ast_index.Index,
) registry.RunError!Report {
    var tallies: std.StringHashMapUnmanaged(ModuleStats) = .empty;
    var trivial_sites: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .tallies = &tallies, .trivial_sites = &trivial_sites };
    try ast_index.runSrc(index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    var rows: std.ArrayList(ModuleStats) = .empty;
    var it = tallies.valueIterator();
    while (it.next()) |v| try rows.append(allocator, v.*);
    const slice = try rows.toOwnedSlice(allocator);
    sortByDensityAsc(slice);
    return .{ .modules = slice, .trivial_sites = try trivial_sites.toOwnedSlice(allocator) };
}

// ── The metric ─────────────────────────────────────────────────────────

/// Assert calls per KLOC of production code, in HUNDREDTHS. Whole asserts/KLOC
/// — what the debt appendix printed before this check existed — is too coarse:
/// Guardian's own tree measures under 1/KLOC almost everywhere, so every module
/// rounded to the same `0` and no ratchet could be stated against it.
pub fn centiPerKloc(asserts: u64, lines: u64) u64 {
    if (lines == 0) return 0;
    return asserts * lines_per_kloc * 100 / lines;
}

/// Assertions per function in hundredths — TIGER_STYLE's own unit. 0 when the
/// module declares no functions.
fn centiPerFn(asserts: u64, fns: u64) u64 {
    if (fns == 0) return 0;
    return asserts * 100 / fns;
}

/// True when the density `a_asserts/a_lines` is strictly below `b_asserts/b_lines`.
/// Cross-multiplied so the comparison is exact: rounding either side to whole
/// asserts/KLOC would make every 0-density module compare equal, and rounding to
/// hundredths would still hide a real dilution.
fn densityBelow(a_asserts: u64, a_lines: u64, b_asserts: u64, b_lines: u64) bool {
    if (a_lines == 0 or b_lines == 0) return false;
    return a_asserts * b_lines < b_asserts * a_lines;
}

/// Orders rows by ascending density, breaking ties by module name so the report
/// and the recorded file are both stable.
fn densityLessThan(_: void, a: ModuleStats, b: ModuleStats) bool {
    if (densityBelow(a.asserts, a.code_lines, b.asserts, b.code_lines)) return true;
    if (densityBelow(b.asserts, b.code_lines, a.asserts, a.code_lines)) return false;
    return std.mem.order(u8, a.module, b.module) == .lt;
}

/// Sorts rows ascending by density (sparsest module first).
pub fn sortByDensityAsc(rows: []ModuleStats) void {
    std.mem.sort(ModuleStats, rows, {}, densityLessThan);
}

// ── The ratchet ────────────────────────────────────────────────────────

/// One recorded floor: the module and the exact `asserts / code_lines` pair the
/// floor was measured at. The PAIR is stored rather than a rounded rate so the
/// comparison stays exact, and so a reader of `.guardian/assert-density.txt`
/// can see what the number was derived from.
const Floor = struct {
    module: []const u8,
    asserts: u64,
    code_lines: u64,
};

/// Parses `<module> <asserts> <code_lines>`; null for any malformed line, which
/// is skipped rather than treated as a zero floor.
fn parseFloor(line: []const u8) ?Floor {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const module = it.next() orelse return null;
    const asserts = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const lines = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return .{ .module = module, .asserts = asserts, .code_lines = lines };
}

/// Reads a snapshot's lines into floors, dropping malformed ones.
fn parseFloors(allocator: Allocator, lines: []const []const u8) Allocator.Error![]Floor {
    var out: std.ArrayList(Floor) = .empty;
    for (lines) |line| {
        if (parseFloor(line)) |f| try out.append(allocator, f);
    }
    return out.toOwnedSlice(allocator);
}

/// The recorded floor for `module`, or null when the module is new.
fn floorFor(floors: []const Floor, module: []const u8) ?Floor {
    for (floors) |f| if (std.mem.eql(u8, f.module, module)) return f;
    return null;
}

/// The floor a write-allowed run should store for one module: the current pair
/// when density held or improved, the RECORDED pair when it fell — the ratchet
/// holds, so a broad refresh (`GUARDIAN_UPDATE_SNAPSHOT=all`, or another
/// check's metadata-writable pass) can never quietly ratify a regression it was
/// not aimed at. `lower_allowed` is the escape hatch, set only by an accept
/// that NAMES this check: lowering a floor is then a deliberate, reviewed act
/// rather than a side effect. Modules absent from `floors` are adopted at their
/// current measurement; modules absent from the tree are dropped by the caller
/// simply by never being visited.
fn ratchetedFloor(floors: []const Floor, m: ModuleStats, lower_allowed: bool) Floor {
    const current: Floor = .{ .module = m.module, .asserts = m.asserts, .code_lines = m.code_lines };
    const old = floorFor(floors, m.module) orelse return current;
    if (lower_allowed) return current;
    if (densityBelow(m.asserts, m.code_lines, old.asserts, old.code_lines)) return old;
    return current;
}

/// The snapshot body for the current measurement, ratcheted against `floors`
/// and sorted by module so the committed file has a stable order.
fn floorLines(
    allocator: Allocator,
    floors: []const Floor,
    modules: []const ModuleStats,
    lower_allowed: bool,
) Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (modules) |m| {
        const f = ratchetedFloor(floors, m, lower_allowed);
        try out.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s} {d} {d}",
            .{ f.module, f.asserts, f.code_lines },
        ));
    }
    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, lineLessThan);
    return slice;
}

/// Byte order over rendered snapshot lines (module name first, so this orders
/// by module).
fn lineLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Whether this run may PERSIST a floor: a refresh that covers this check
/// (`accept assert-density`, `GUARDIAN_UPDATE_SNAPSHOT=assert-density|all`), or
/// a metadata-writable run adopting a first record where no file exists yet —
/// the same grandfathering the budget snapshots do. An unrelated `accept` of
/// some other check is deliberately NOT enough to rewrite existing floors.
///
/// A diff-scoped run never may, whatever else is true: the aggregate it would
/// write was computed for a tree the run did not fully judge, and Guardian's
/// rule is that a scoped run never prunes, lowers or rewrites a ratchet. Pure,
/// so the rule is testable without a run.
fn mayWrite(scoped: bool, refresh: bool, adopting: bool) bool {
    if (scoped) return false;
    return refresh or adopting;
}

// ── Reporting ──────────────────────────────────────────────────────────

/// How far under its floor a module must fall before it is REPORTED, as a
/// percentage of the floor. The floor itself is still strict — `ratchetedFloor`
/// never drifts down by a hair — but reporting needs a band or the check is
/// noise: measured on this tree, adding ONE line to the 11364-line `checks`
/// module moved its density by 0.001% and produced a warning. A dilution worth
/// a reader's attention is a tenth of the module's assertion coverage, not a
/// rounding step.
const regression_tolerance_pct: u64 = 10;

/// One module whose density fell far enough below its recorded floor to report.
const Regression = struct {
    module: ModuleStats,
    floor: Floor,
};

/// True when `m`'s density is below `f`'s by more than `regression_tolerance_pct`.
/// Cross-multiplied against the percentage in one expression so no intermediate
/// rounding can decide the answer.
fn fellBelowFloor(m: ModuleStats, f: Floor) bool {
    if (m.code_lines == 0 or f.code_lines == 0) return false;
    const current = m.asserts * f.code_lines * 100;
    const allowed = f.asserts * m.code_lines * (100 - regression_tolerance_pct);
    return current < allowed;
}

/// Every module now meaningfully below its recorded floor. A module with no
/// floor is new and cannot regress; a module whose density held, improved, or
/// slipped inside the tolerance band is silent.
fn regressions(allocator: Allocator, floors: []const Floor, modules: []const ModuleStats) Allocator.Error![]Regression {
    var out: std.ArrayList(Regression) = .empty;
    for (modules) |m| {
        const f = floorFor(floors, m.module) orelse continue;
        if (!fellBelowFloor(m, f)) continue;
        try out.append(allocator, .{ .module = m, .floor = f });
    }
    return out.toOwnedSlice(allocator);
}

/// The advisory line for one fallen module, in hundredths of an assert/KLOC on
/// both sides plus the raw counts the ratio came from.
fn regressionMessage(allocator: Allocator, r: Regression) Allocator.Error![]const u8 {
    const now = centiPerKloc(r.module.asserts, r.module.code_lines);
    const was = centiPerKloc(r.floor.asserts, r.floor.code_lines);
    return std.fmt.allocPrint(
        allocator,
        "assert density fell to {d}.{d:0>2}/KLOC ({d} assert(s) / {d} code line(s)); " ++
            "recorded floor {d}.{d:0>2}/KLOC ({d} / {d}), tolerance {d}%",
        .{
            now / 100,                now % 100,
            r.module.asserts,         r.module.code_lines,
            was / 100,                was % 100,
            r.floor.asserts,          r.floor.code_lines,
            regression_tolerance_pct,
        },
    );
}

/// Tree-wide totals, for the one line that states the metric against
/// TIGER_STYLE's own unit.
const Totals = struct {
    asserts: u64 = 0,
    trivial: u64 = 0,
    fns: u64 = 0,
    code_lines: u64 = 0,
};

/// Sums every module. The average TIGER_STYLE names is tree-wide, so the
/// context line has to be too.
fn totalsOf(modules: []const ModuleStats) Totals {
    var t: Totals = .{};
    for (modules) |m| {
        t.asserts += m.asserts;
        t.trivial += m.trivial;
        t.fns += m.fns;
        t.code_lines += m.code_lines;
    }
    return t;
}

/// Prints the tree-wide measurement beside the cited target. Never a verdict:
/// TIGER_STYLE's figure is an average over code written to its style, and
/// naming it as a threshold here would be the overselling the module header
/// refuses.
fn printContext(t: Totals) void {
    const per_fn = centiPerFn(t.asserts, t.fns);
    const per_kloc = centiPerKloc(t.asserts, t.code_lines);
    print(
        "  tree: {d}.{d:0>2} assert(s)/fn over {d} fn(s), {d}.{d:0>2}/KLOC over {d} code line(s)" ++
            " — TIGER_STYLE averages {d}.{d:0>2}/fn (reference, not a gate)\n",
        .{
            per_fn / 100,                   per_fn % 100,
            t.fns,                          per_kloc / 100,
            per_kloc % 100,                 t.code_lines,
            tiger_style_centi_per_fn / 100, tiger_style_centi_per_fn % 100,
        },
    );
}

/// True when THIS check was named in the refresh request — `accept
/// assert-density .`, or `GUARDIAN_UPDATE_SNAPSHOT=assert-density`. A broad
/// `=all` is deliberately not enough: naming the check is what makes lowering a
/// floor a reviewed decision instead of collateral from accepting something else.
fn namedExplicitly(ctx: *const registry.RunCtx) bool {
    if (ctx.refreshes(check_name)) return true;
    const names = snapshot_helper.refreshTargets(ctx.allocator) orelse return false;
    for (names) |n| {
        if (std.mem.eql(u8, snapshot_helper.canonicalCheckName(n), check_name)) return true;
    }
    return false;
}

/// Entry point for the assert-density check. Advisory by construction: there is
/// no `return error.CheckFailed` anywhere below it.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const report = try collect(allocator, ctx.project_dir, ctx.source_index);
    const totals = totalsOf(report.modules);

    const snap_path = try snapshot_helper.snapshotPath(allocator, ctx.project_dir, snapshot_leaf);
    const old = snapshot.read(allocator, snap_path, snapshot_version) catch |e| switch (e) {
        error.Missing, error.VersionMismatch => null,
        else => return e,
    };
    const floors = if (old) |o| try parseFloors(allocator, o.lines) else &.{};

    const named = namedExplicitly(ctx);
    const refresh = named or snapshot_helper.shouldUpdateForCtx(ctx, check_name);
    if (mayWrite(ctx.scoped != null, refresh, ctx.metadata_writable and old == null)) {
        try snapshot.write(snap_path, snapshot_version, try floorLines(allocator, floors, report.modules, named));
        ok("assert density recorded ({d} module(s))", .{report.modules.len});
        printContext(totals);
        return reportTrivial(report.trivial_sites);
    }

    if (old == null) return reportUnrecorded(report, totals);
    return reportAgainstFloors(allocator, ctx, report, totals, floors);
}

/// The no-floor-yet path. Green and read-only: nothing is written outside an
/// accept, and the message names the command that would record the starting set.
fn reportUnrecorded(report: Report, totals: Totals) registry.RunError!void {
    ok("assert density: no floor recorded ({d} module(s) would be recorded)", .{report.modules.len});
    printContext(totals);
    print("  record the starting floors (advisory ratchet, never blocks):\n", .{});
    print("    guardian-check accept {s} .\n", .{check_name});
    return reportTrivial(report.trivial_sites);
}

/// The comparison path: warn per fallen module, then print the context line.
fn reportAgainstFloors(
    allocator: Allocator,
    ctx: *registry.RunCtx,
    report: Report,
    totals: Totals,
    floors: []const Floor,
) registry.RunError!void {
    const fallen = try regressions(allocator, floors, report.modules);
    const held = if (ctx.scoped != null) " — diff-scoped, floors held" else "";
    if (fallen.len == 0) {
        ok("assert density at or above every recorded floor ({d} module(s)){s}", .{ report.modules.len, held });
    } else {
        ok("assert density: {d} module(s) below floor — advisory{s}", .{ fallen.len, held });
        for (fallen) |r| reporter.warn(.{
            .check = check_name,
            .file = try std.fmt.allocPrint(allocator, "src/{s}", .{r.module.module}),
            .message = try regressionMessage(allocator, r),
            .identity = r.module.module,
            .fix_hint = regression_fix,
        });
    }
    printContext(totals);
    return reportTrivial(report.trivial_sites);
}

/// Names every rejected constant-foldable assert. These are the gaming vector
/// the triviality filter exists for, so they are reported rather than silently
/// subtracted — a site that was added to move a number should be visible.
fn reportTrivial(sites: []const reporter.Violation) registry.RunError!void {
    for (sites) |v| {
        var w = v;
        w.fix_hint = trivial_fix;
        reporter.warn(w);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Assert Density - Counts assert call sites outside test blocks per top-level src module

test "measureFile counts real asserts outside tests and moduleOf groups by top-level segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // moduleOf collapses a subdir to its name and keeps a loose file's name.
    try testing.expectEqualStrings("ast", moduleOf("src/ast/parser.zig"));
    try testing.expectEqualStrings("snapshot.zig", moduleOf("src/snapshot.zig"));
    const src =
        \\fn f(x: u32) void {
        \\    std.debug.assert(x > 0);
        \\    assert(x < 9);
        \\    const s = "assert(nope)"; // assert( here is not a call either
        \\    _ = s;
        \\}
        \\fn g() void {}
        \\test "t" {
        \\    assert(g() == {});
        \\}
    ;
    const m = try measureFile(a, src);
    // Two production asserts; the string literal, the comment and the one in
    // the `test` block are all excluded.
    try testing.expectEqual(@as(u32, 2), m.counts.asserts);
    try testing.expectEqual(@as(u32, 0), m.counts.trivial);
    // Two named fn declarations — the denominator TIGER_STYLE states its
    // average over.
    try testing.expectEqual(@as(u32, 2), m.counts.fns);
}

// spec: Assert Density - Ignores a constant-foldable assertion so padding cannot raise the ratchet

test "measureFile rejects constant-foldable asserts and records where they are" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\fn f(x: u32) void {
        \\    assert(true);
        \\    assert(1 == 1);
        \\    assert(!false);
        \\    assert(x != 0);
        \\}
    ;
    const m = try measureFile(a, src);
    // Only the assertion over a runtime value counts. The other three are the
    // padding Power of Ten Rule 5 excludes by name.
    try testing.expectEqual(@as(u32, 1), m.counts.asserts);
    try testing.expectEqual(@as(u32, 3), m.counts.trivial);
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, m.trivial_lines);
    // A nested call is substantive: the builtin/identifier inside it is not
    // foldable, so the whole argument is not either.
    const nested = try measureFile(a, "fn g() void { assert(@intFromBool(true) == 1); }");
    try testing.expectEqual(@as(u32, 1), nested.counts.asserts);
}

// spec: Assert Density - Raises a floor on improvement and lowers one only for an accept naming the check

test "ratchetedFloor holds a fallen floor unless the accept named this check" {
    const floors = [_]Floor{.{ .module = "ast", .asserts = 4, .code_lines = 1000 }};
    const diluted: ModuleStats = .{ .module = "ast", .asserts = 4, .code_lines = 2000 };
    // Diluted: same asserts over more code. The floor HOLDS, so a broad
    // `GUARDIAN_UPDATE_SNAPSHOT=all` cannot ratify a regression it never aimed at.
    const held = ratchetedFloor(&floors, diluted, false);
    try testing.expectEqual(@as(u64, 4), held.asserts);
    try testing.expectEqual(@as(u64, 1000), held.code_lines);
    // Naming the check IS the review, and is the only way a floor comes down.
    const lowered = ratchetedFloor(&floors, diluted, true);
    try testing.expectEqual(@as(u64, 2000), lowered.code_lines);
    // Improved: the new, higher pair is locked in either way.
    const improved = ratchetedFloor(&floors, .{ .module = "ast", .asserts = 9, .code_lines = 1000 }, false);
    try testing.expectEqual(@as(u64, 9), improved.asserts);
    // A module with no recorded floor is adopted at whatever it measures.
    const fresh = ratchetedFloor(&floors, .{ .module = "spec", .asserts = 1, .code_lines = 500 }, false);
    try testing.expectEqualStrings("spec", fresh.module);
    try testing.expectEqual(@as(u64, 1), fresh.asserts);
}

// spec: Assert Density - Reports a density regression as an advisory warning rather than a failure

test "a fallen module reports as a captured warning and the run still succeeds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    const floors = [_]Floor{
        .{ .module = "ast", .asserts = 4, .code_lines = 1000 },
        .{ .module = "spec", .asserts = 2, .code_lines = 1000 },
    };
    const modules = [_]ModuleStats{
        .{ .module = "ast", .asserts = 4, .code_lines = 2000 },
        .{ .module = "spec", .asserts = 3, .code_lines = 1000 },
        .{ .module = "new.zig", .asserts = 0, .code_lines = 100 },
    };
    // Only the diluted module. `spec` improved; `new.zig` has no floor, so it
    // cannot regress however sparse it is.
    const fallen = try regressions(a, &floors, &modules);
    try testing.expectEqual(@as(usize, 1), fallen.len);
    try testing.expectEqualStrings("ast", fallen[0].module.module);
    // Inside the tolerance band nothing is reported: appending a few lines to a
    // module is not a dilution worth a reader's attention, and without the band
    // a ONE-line addition to an 11k-line module warned on this very tree.
    try testing.expect(!fellBelowFloor(.{ .module = "ast", .asserts = 4, .code_lines = 1050 }, floors[0]));
    try testing.expect(fellBelowFloor(.{ .module = "ast", .asserts = 4, .code_lines = 1200 }, floors[0]));

    const cfg: @import("../config.zig").Config = .{};
    var ctx: registry.RunCtx = .{ .allocator = a, .project_dir = ".", .cfg = &cfg, .quiet = true };
    // No error: the whole check is advisory, so a fallen floor never refuses a
    // build the way a budget or a threshold ratchet does.
    try reportAgainstFloors(a, &ctx, .{ .modules = &modules, .trivial_sites = &.{} }, totalsOf(&modules), &floors);
    // ...and it lands on the WARNING channel, which baselines, ratchets and
    // snapshots exclude by construction — so it can never become accept work.
    try testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
    try testing.expectEqual(@as(usize, 0), cap.records.items.len);
    // Hundredths on both sides: whole asserts/KLOC would print "2/KLOC" against
    // a "4/KLOC" floor for a tree that mostly measures under 1.
    const msg = cap.warnings.items[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "2.00/KLOC") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "floor 4.00/KLOC") != null);
}

// spec: Assert Density - Holds the recorded floor on a diff-scoped run

test "mayWrite refuses every persistence on a diff-scoped run" {
    // A scoped run may not write even under an explicit accept: the aggregate
    // it measured describes a tree the run did not fully judge.
    try testing.expect(!mayWrite(true, true, true));
    try testing.expect(!mayWrite(true, false, false));
    // Whole-tree: a refresh covering this check, or the first-record adoption
    // of a tree that has no floor file yet.
    try testing.expect(mayWrite(false, true, false));
    try testing.expect(mayWrite(false, false, true));
    // An ordinary whole-tree build stays read-only, like every other ratchet.
    try testing.expect(!mayWrite(false, false, false));
}

test "parseFloor round-trips a snapshot line and rejects a malformed one" {
    const f = parseFloor("ast 3 2405").?;
    try testing.expectEqualStrings("ast", f.module);
    try testing.expectEqual(@as(u64, 3), f.asserts);
    try testing.expectEqual(@as(u64, 2405), f.code_lines);
    // A malformed row is skipped, never read as a zero floor: a zero floor
    // silently accepts any density at all.
    try testing.expect(parseFloor("ast 3") == null);
    try testing.expect(parseFloor("ast x 5") == null);
}

test "sortByDensityAsc puts the sparsest module first with an exact comparison" {
    var rows = [_]ModuleStats{
        .{ .module = "dense", .asserts = 8, .code_lines = 1000 },
        .{ .module = "sparse", .asserts = 1, .code_lines = 1000 },
        // Under whole-number asserts/KLOC this is 0, the same as any other
        // sub-1/KLOC module; cross-multiplication keeps it ordered.
        .{ .module = "faint", .asserts = 1, .code_lines = 4000 },
    };
    sortByDensityAsc(&rows);
    try testing.expectEqualStrings("faint", rows[0].module);
    try testing.expectEqualStrings("sparse", rows[1].module);
    try testing.expectEqualStrings("dense", rows[2].module);
    try testing.expectEqual(@as(u64, 25), centiPerKloc(1, 4000));
    // TIGER_STYLE's own unit, reported tree-wide beside the 2.00 reference.
    try testing.expectEqual(tiger_style_centi_per_fn, centiPerFn(20, 10));
    // No functions means no per-function average to state, not a division trap.
    try testing.expectEqual(@as(u64, 0), centiPerFn(3, 0));
}
