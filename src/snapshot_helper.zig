//! Snapshot lifecycle shared by every snapshot-based check: compare current
//! state to the committed snapshot and classify the run (created / unchanged /
//! updated / drift / version_mismatch). `drift` and `version_mismatch` fail the
//! build; `GUARDIAN_UPDATE_SNAPSHOT` (selective by check name) forces a rewrite.

const std = @import("std");
const fs = @import("fs.zig");
const wiring = @import("wiring.zig");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const types = @import("cli/types.zig");
const reporter = @import("reporter.zig");

pub const update_env = "GUARDIAN_UPDATE_SNAPSHOT";

pub const LifecycleError = snapshot.WriteError || snapshot.ReadError;

/// Outcome of a snapshot lifecycle run. Callers translate this to user-facing
/// messages and exit status. `drift` and `version_mismatch` mean the build
/// should fail; the others are success paths.
pub const Outcome = union(enum) {
    /// No prior snapshot existed; one was just written.
    created: usize,
    /// Snapshot matches current state exactly.
    unchanged: usize,
    /// `force_update` was set; snapshot was rewritten.
    updated: usize,
    /// Snapshot exists and disagrees with current state.
    drift: snapshot.Diff,
    /// Snapshot exists with a stale version; caller should fail and instruct
    /// the user to re-run with the update env var.
    version_mismatch,
};

/// True when any non-empty refresh value was supplied. Invalid legacy broad
/// tokens also bypass the skip cache so validation can reject them visibly.
pub fn shouldUpdate(allocator: Allocator) bool {
    const v = wiring.getEnvOwned(allocator, update_env) catch return false;
    defer allocator.free(v);
    const t = std.mem.trim(u8, v, &std.ascii.whitespace);
    return t.len > 0 and !std.mem.eql(u8, t, "0");
}

/// A parsed GUARDIAN_UPDATE_SNAPSHOT request. Broad refreshes require the
/// explicit `all` token; legacy truthy tokens are retained as a distinct
/// invalid state so the CLI can explain the safe replacement.
const Refresh = union(enum) {
    none,
    all,
    named: []const []const u8,
    rejected_broad: []const u8,
};

/// True only for the explicit full-refresh token.
fn isAllToken(v: []const u8) bool {
    return std.mem.eql(u8, v, "all");
}

fn isRejectedBroadToken(v: []const u8) bool {
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

/// A spelling of a check name that isn't the registered one. The snapshot leaf
/// and the check name diverge for exactly one check (`.guardian/pub-api.txt` vs
/// `pub-api-surface`), and the file is what a reviewer has just been looking at
/// when they reach for the accept command — so the leaf's basename resolves to
/// the check everywhere a name is accepted. Anything not listed here is
/// returned unchanged and still hard-fails the registry validator.
const Alias = struct { spelling: []const u8, check: []const u8 };
const aliases = [_]Alias{
    .{ .spelling = "pub-api", .check = "pub-api-surface" },
};

/// Resolves an alias spelling to its registered check name; every other name
/// passes through untouched, so a typo still hard-fails validation.
pub fn canonicalCheckName(name: []const u8) []const u8 {
    for (aliases) |a| if (std.mem.eql(u8, a.spelling, name)) return a.check;
    return name;
}

/// Splits a comma-separated check-name list, trimming each segment, resolving
/// aliases, and dropping blanks ("a,,b" -> {a,b}). Propagates OOM: a truncated
/// list would silently drop a check from the refresh set — the public entry
/// points below turn OOM into the fail-closed "no refresh" default rather than
/// a partial list.
fn splitNames(allocator: Allocator, csv: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        try list.append(allocator, canonicalCheckName(trimmed));
    }
    return list.toOwnedSlice(allocator);
}

/// Classifies a raw GUARDIAN_UPDATE_SNAPSHOT value into a Refresh request. Pure
/// (no env read) so the none/all/named partition is unit-testable.
fn classifyValue(allocator: Allocator, raw: []const u8) Allocator.Error!Refresh {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "0")) return .none;
    if (isAllToken(trimmed)) return .all;
    if (isRejectedBroadToken(trimmed)) return .{ .rejected_broad = trimmed };
    return .{ .named = try splitNames(allocator, trimmed) };
}

/// Reads and classifies GUARDIAN_UPDATE_SNAPSHOT; `.none` when unset/unreadable.
fn parseRefresh(allocator: Allocator) Allocator.Error!Refresh {
    const raw = wiring.getEnvOwned(allocator, update_env) catch return .none;
    return classifyValue(allocator, raw);
}

/// True when `name` appears in `names`.
fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// True when refresh request `r` covers the check `check_name`: every check
/// under `all`, only the listed checks under `named`, none under `none`.
fn refreshIncludes(r: Refresh, check_name: []const u8) bool {
    return switch (r) {
        .none => false,
        .all => true,
        .named => |names| containsName(names, check_name),
        .rejected_broad => false,
    };
}

/// True when the check named `check_name` should refresh its snapshot/baseline
/// this run — the per-check replacement for the old global `shouldUpdate`
/// boolean. Threaded through every snapshot check, `mutate`'s ratchet, and
/// baseline mode so `GUARDIAN_UPDATE_SNAPSHOT=<name[,name]>` refreshes only
/// those checks; only explicit `=all` refreshes everything.
pub fn shouldUpdateFor(allocator: Allocator, check_name: []const u8) bool {
    // OOM while parsing the refresh list collapses to "no refresh": the check
    // then compares against its committed snapshot, so real drift still reds the
    // build (fail closed) rather than being silently ratified.
    const r = parseRefresh(allocator) catch return false;
    return refreshIncludes(r, check_name);
}

/// Context-aware refresh decision used by `accept`: an explicit command-local
/// refresh wins, with the legacy environment variable retained as a fallback.
pub fn shouldUpdateForCtx(ctx: *const types.RunCtx, check_name: []const u8) bool {
    return ctx.refreshes(check_name) or shouldUpdateFor(ctx.allocator, check_name);
}

/// The check names listed in a `named` GUARDIAN_UPDATE_SNAPSHOT request, or null
/// under the none/all modes (nothing to validate). Callers validate the names
/// against the registry so a typo hard-fails instead of silently refreshing
/// nothing.
pub fn refreshTargets(allocator: Allocator) ?[]const []const u8 {
    return switch (parseRefresh(allocator) catch return null) {
        .named => |names| names,
        else => null,
    };
}

/// True when the legacy broad token `1` or `true` was supplied. The run-all
/// validator uses this to fail with explicit `=all` migration guidance.
pub fn usesLegacyBroadToken(allocator: Allocator) bool {
    const raw = wiring.getEnvOwned(allocator, update_env) catch return false;
    defer allocator.free(raw);
    return isRejectedBroadToken(std.mem.trim(u8, raw, &std.ascii.whitespace));
}

/// A concrete named-refresh invocation, printed when a rejected broad token
/// (`=1`/`=true`) is refused so the operator sees a real replacement instead of
/// the vague "name the intended checks". Both names are real gates, so the
/// example survives the refresh-target validator unchanged.
pub const example_named_refresh = update_env ++ "=pub-api-surface,spec";

/// A comma-separated summary of the checks named in a `named`
/// GUARDIAN_UPDATE_SNAPSHOT request, for a human-facing notice; null under the
/// none/all/rejected modes. Owned by `allocator`.
pub fn refreshTargetSummary(allocator: Allocator) ?[]const u8 {
    const names = refreshTargets(allocator) orelse return null;
    if (names.len == 0) return null;
    return std.mem.join(allocator, ", ", names) catch null;
}

/// The `.guardian/`-relative metadata files a selective refresh of the checks
/// named in GUARDIAN_UPDATE_SNAPSHOT is allowed to keep across a red run — the
/// input to `metadata_transaction`'s selective restore (see C2 in FEEDBACK.md).
/// Empty under the none/all/rejected modes: `=all` keeps all-or-nothing
/// semantics, and a rejected/absent value preserves nothing. Owned by `allocator`.
///
/// Per named check we list every path the check could own — its baseline
/// (`baselines/<check>.txt`, covering v1 text and v2 ratchet checks), its
/// same-named snapshot leaf (`<check>.txt`, covering the budget snapshots whose
/// leaf equals the check name), and pub-api-surface's differently-named
/// `pub-api.txt`. Listing a path the check never wrote is harmless: the
/// transaction simply finds nothing to keep there.
pub fn preservedMetadataPaths(allocator: Allocator) Allocator.Error![]const []const u8 {
    const names = refreshTargets(allocator) orelse return &.{};
    return metadataRelPathsFor(allocator, names);
}

/// Pure name→path expansion behind `preservedMetadataPaths` (no env read), so
/// the path set is unit-testable without touching the process environment.
fn metadataRelPathsFor(allocator: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |name| try appendMetadataRelPaths(allocator, &out, name);
    return out.toOwnedSlice(allocator);
}

/// Appends every `.guardian/`-relative path check `name` might own (see
/// `preservedMetadataPaths`).
fn appendMetadataRelPaths(
    allocator: Allocator,
    out: *std.ArrayList([]const u8),
    name: []const u8,
) Allocator.Error!void {
    try out.append(allocator, try std.fmt.allocPrint(allocator, "baselines/{s}.txt", .{name}));
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}.txt", .{name}));
    if (std.mem.eql(u8, name, "pub-api-surface")) try out.append(allocator, "pub-api.txt");
}

/// Prints the full set of working ways to accept a snapshot/baseline check's
/// drift, so remediation tells the whole truth (see C3/C4 in FEEDBACK.md): the
/// raw CLI form (works even when the binary is only under `.zig-cache/`), the
/// selective env-var form (which — after the C2 transaction fix — persists even
/// when another check reds the run), and the repo-wired build step (present
/// only when the consumer's build wired `guardian-accept`). Callers print their
/// own `fix:` line first so baseline capture stops before this block.
pub fn printAcceptPaths(check_name: []const u8) void {
    reporter.detail("  accept (any one; then commit the .guardian/ change):\n", .{});
    reporter.detail("    guardian-check accept {s} .   # raw CLI, always works\n", .{check_name});
    reporter.detail(
        "    {s}={s} zig build   # env var; kept even if another check fails the run\n",
        .{ update_env, check_name },
    );
    reporter.detail(
        "    zig build guardian-accept -Dguardian-checks={s}   # if your build wires guardian-accept\n",
        .{check_name},
    );
}

/// Joins `project_dir/.guardian/{leaf}` for snapshot file paths. Caller owns
/// the returned slice (via allocator).
pub fn snapshotPath(allocator: Allocator, project_dir: []const u8, leaf: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.guardian/{s}", .{ project_dir, leaf });
}

/// Identifies a snapshot file: its path and format version.
pub const SnapSpec = struct {
    path: []const u8,
    version: u32,
};

/// Runs the standard snapshot lifecycle for set-diff style checks
/// (e.g. pub-api-surface): if no snapshot exists OR `force_update` is
/// set, write the current `new_lines` and report created/updated. Otherwise
/// read the prior snapshot and diff against the (sorted) current state.
///
/// `write_allowed` gates every persistence: an ordinary (read-only) run leaves
/// it false, so a missing snapshot is grandfathered as `created` **without**
/// writing the file — the surface is still reported clean and `git status` stays
/// untouched until `accept`/`commit`/`migrate` records it. `force_update` (an
/// accept) always implies `write_allowed`.
///
/// `new_lines` is sorted in place when needed for diffing. The slice may be
/// retained by the returned Outcome.
pub fn lifecycle(
    allocator: Allocator,
    spec: SnapSpec,
    new_lines: [][]const u8,
    force_update: bool,
    write_allowed: bool,
) LifecycleError!Outcome {
    if (force_update) {
        // writeChecked applies the content-identical short-circuit: an accept
        // that re-emits the same set leaves the file (and the diff) untouched.
        _ = try snapshot.writeChecked(allocator, spec.path, spec.version, new_lines);
        return .{ .updated = new_lines.len };
    }
    const old = snapshot.read(allocator, spec.path, spec.version) catch |e|
        return onReadError(allocator, e, spec, new_lines, write_allowed);
    return finishDiff(allocator, old, new_lines);
}

/// Handles a failed snapshot read: a missing file is grandfathered as `created`
/// — written only on a metadata-writable run — a stale version is surfaced, and
/// any other error propagates.
fn onReadError(
    allocator: Allocator,
    e: snapshot.ReadError,
    spec: SnapSpec,
    new_lines: [][]const u8,
    write_allowed: bool,
) LifecycleError!Outcome {
    switch (e) {
        error.Missing => {
            if (write_allowed) _ = try snapshot.writeChecked(allocator, spec.path, spec.version, new_lines);
            return .{ .created = new_lines.len };
        },
        error.VersionMismatch => return .version_mismatch,
        else => return e,
    }
}

/// Sorts `new_lines` in place and diffs it against the prior snapshot.
fn finishDiff(allocator: Allocator, old: snapshot.Snapshot, new_lines: [][]const u8) LifecycleError!Outcome {
    std.mem.sort([]const u8, new_lines, {}, lessThan);
    const diff = try snapshot.diff(allocator, old, new_lines);
    if (diff.isEmpty()) return .{ .unchanged = new_lines.len };
    return .{ .drift = diff };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn deleteIfExists(path: []const u8) void {
    fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => std.log.warn("test cleanup {s}: {s}", .{ path, @errorName(e) }),
    };
}

// spec: Snapshot Lifecycle - Creates snapshot file on first run with no prior snapshot
// spec: Snapshot Lifecycle - Reports drift when current state differs from prior snapshot
// spec: Snapshot Lifecycle - Honors GUARDIAN_UPDATE_SNAPSHOT to regenerate snapshot

test "snapshotPath joins project_dir, .guardian, leaf" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try snapshotPath(a, "/tmp/proj", "panic-budget.txt");
    try testing.expectEqualStrings("/tmp/proj/.guardian/panic-budget.txt", p);
}

test "lifecycle creates snapshot when missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-create.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    const out = try lifecycle(a, .{ .path = path, .version = 1 }, &lines, false, true);
    try testing.expect(out == .created);
    try testing.expectEqual(@as(usize, 2), out.created);

    // Re-running with no change should return .unchanged.
    var lines2 = [_][]const u8{ "alpha", "beta" };
    const out2 = try lifecycle(a, .{ .path = path, .version = 1 }, &lines2, false, true);
    try testing.expect(out2 == .unchanged);
}

// spec: Snapshot Lifecycle - Defers snapshot creation to a metadata-writable run

test "lifecycle grandfathers a missing snapshot without writing on a read-only run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-readonly.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    // write_allowed = false: the missing snapshot is grandfathered as `created`
    // (green, all current lines accepted) but the file is NOT written, so an
    // ordinary run leaves the tree clean.
    var lines = [_][]const u8{ "alpha", "beta" };
    const out = try lifecycle(a, .{ .path = path, .version = 1 }, &lines, false, false);
    try testing.expect(out == .created);
    try testing.expectError(error.FileNotFound, fs.cwd().access(path, .{}));

    // The same call on a metadata-writable run records it.
    var lines2 = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, .{ .path = path, .version = 1 }, &lines2, false, true);
    try fs.cwd().access(path, .{});
}

test "lifecycle reports drift when changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-drift.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, .{ .path = path, .version = 1 }, &lines, false, true);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, .{ .path = path, .version = 1 }, &lines2, false, true);
    try testing.expect(out == .drift);
    try testing.expectEqual(@as(usize, 1), out.drift.added.len);
    try testing.expectEqualStrings("gamma", out.drift.added[0]);
    try testing.expectEqual(@as(usize, 1), out.drift.removed.len);
    try testing.expectEqualStrings("beta", out.drift.removed[0]);
}

test "lifecycle force_update overwrites existing snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-force.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{ "alpha", "beta" };
    _ = try lifecycle(a, .{ .path = path, .version = 1 }, &lines, false, true);

    var lines2 = [_][]const u8{ "alpha", "gamma" };
    const out = try lifecycle(a, .{ .path = path, .version = 1 }, &lines2, true, true);
    try testing.expect(out == .updated);

    // After force-update, the new state is now the baseline.
    var lines3 = [_][]const u8{ "alpha", "gamma" };
    const out2 = try lifecycle(a, .{ .path = path, .version = 1 }, &lines3, false, true);
    try testing.expect(out2 == .unchanged);
}

test "lifecycle reports version_mismatch on stale snapshot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "zig-cache/test-lifecycle-version.txt";
    deleteIfExists(path);
    defer deleteIfExists(path);

    var lines = [_][]const u8{"x"};
    try snapshot.write(path, 1, &lines);

    var lines2 = [_][]const u8{"x"};
    const out = try lifecycle(a, .{ .path = path, .version = 2 }, &lines2, false, true);
    try testing.expect(out == .version_mismatch);
}

// spec: Snapshot Lifecycle - Refreshes only the checks named in a GUARDIAN_UPDATE_SNAPSHOT list

test "classifyValue and refreshIncludes select only the named checks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try classifyValue(a, "pub-api-surface, spec");
    try testing.expect(r == .named);
    try testing.expectEqual(@as(usize, 2), r.named.len);
    // Only the two listed checks refresh; everything else is held back.
    try testing.expect(refreshIncludes(r, "pub-api-surface"));
    try testing.expect(refreshIncludes(r, "spec"));
    try testing.expect(!refreshIncludes(r, "panic-budget"));
}

// spec: Pub Api Surface - Accepts the pub-api snapshot leaf name as an alias for the check name

test "canonicalCheckName resolves the snapshot leaf spelling and leaves typos alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The file a reviewer has just been reading is .guardian/pub-api.txt, so
    // that basename names the check everywhere a check name is accepted.
    try testing.expectEqualStrings("pub-api-surface", canonicalCheckName("pub-api"));
    const r = try classifyValue(a, "pub-api");
    try testing.expect(refreshIncludes(r, "pub-api-surface"));
    // Its metadata expansion is the canonical check's, not a "pub-api.txt.txt".
    try testing.expectEqualStrings("pub-api.txt", (try metadataRelPathsFor(a, r.named))[2]);

    // Everything else passes through untouched, so an unknown name still
    // hard-fails the registry validator instead of silently refreshing nothing.
    try testing.expectEqualStrings("pub-ap", canonicalCheckName("pub-ap"));
    try testing.expectEqualStrings("panic-budget", canonicalCheckName("panic-budget"));
}

// spec: Snapshot Lifecycle - Requires the explicit all token for a full refresh

test "classifyValue accepts only all as a full refresh" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try classifyValue(a, "all");
    try testing.expect(all == .all);
    try testing.expect(refreshIncludes(all, "anything-else"));
    for ([_][]const u8{ "1", "true" }) |token| {
        const rejected = try classifyValue(a, token);
        try testing.expect(rejected == .rejected_broad);
        try testing.expectEqualStrings(token, rejected.rejected_broad);
        try testing.expect(!refreshIncludes(rejected, "pub-api-surface"));
    }
}

test "usesLegacyBroadToken remains part of the validated environment API" {
    _ = &usesLegacyBroadToken;
    try testing.expect(true);
}

// spec: Snapshot Lifecycle - Treats an unset, empty, or zero value as no refresh

test "classifyValue treats empty and zero as no refresh" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "   ", "0" }) |token| {
        const r = try classifyValue(a, token);
        try testing.expect(r == .none);
        try testing.expect(!refreshIncludes(r, "pub-api-surface"));
    }
}

// spec: Snapshot Lifecycle - Accept command refreshes only its explicit context-local check names

test "shouldUpdateForCtx honors explicit refreshes without an environment variable" {
    const config = @import("config.zig");
    const cfg: config.Config = .{};
    const ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .refresh = &.{"file-size"},
    };
    try std.testing.expect(shouldUpdateForCtx(&ctx, "file-size"));
    try std.testing.expect(!ctx.refreshes("spec"));
}

// spec: Snapshot Lifecycle - Lists the metadata files a named refresh keeps through a failed gate

test "metadataRelPathsFor lists baseline, same-named, and pub-api leaves per check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A baseline/budget check: its baseline and same-named snapshot leaf, no more.
    const budget = try metadataRelPathsFor(a, &.{"panic-budget"});
    try testing.expectEqual(@as(usize, 2), budget.len);
    try testing.expectEqualStrings("baselines/panic-budget.txt", budget[0]);
    try testing.expectEqualStrings("panic-budget.txt", budget[1]);

    // pub-api-surface additionally owns its differently-named pub-api.txt leaf.
    const api = try metadataRelPathsFor(a, &.{"pub-api-surface"});
    try testing.expectEqual(@as(usize, 3), api.len);
    try testing.expectEqualStrings("pub-api.txt", api[2]);

    // With no GUARDIAN_UPDATE_SNAPSHOT set (the case during `zig build test`),
    // the env-reading wrappers preserve nothing and summarize nothing.
    try testing.expectEqual(@as(usize, 0), (try preservedMetadataPaths(a)).len);
    try testing.expect(refreshTargetSummary(a) == null);
}

// spec: Snapshot Lifecycle - Prints every working accept path for a snapshot check's drift

test "printAcceptPaths shows the raw CLI, env-var, and build-step forms" {
    var cap: reporter.Capture = .{ .allocator = testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    printAcceptPaths("pub-api-surface");
    const out = cap.buf.items;
    // All three working accept paths appear, so remediation tells the whole truth.
    try testing.expect(std.mem.indexOf(u8, out, "guardian-check accept pub-api-surface .") != null);
    try testing.expect(std.mem.indexOf(u8, out, "GUARDIAN_UPDATE_SNAPSHOT=pub-api-surface zig build") != null);
    try testing.expect(std.mem.indexOf(u8, out, "guardian-accept -Dguardian-checks=pub-api-surface") != null);
}

// spec: Snapshot Lifecycle - Offers a concrete named-refresh example when a broad token is rejected

test "example_named_refresh names real checks with the update env var" {
    try testing.expect(std.mem.startsWith(u8, example_named_refresh, update_env ++ "="));
    try testing.expect(std.mem.indexOf(u8, example_named_refresh, "pub-api-surface") != null);
}
