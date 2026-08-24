//! Read-only project-health diagnostics for Guardian metadata and integration.

const std = @import("std");
const fs = @import("../fs.zig");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");
const cache = @import("../cache.zig");
const benchmark = @import("../benchmark.zig");
const merge_driver = @import("merge_driver.zig");
const accept_session = @import("../accept_session.zig");
const journal = @import("../mutation/journal.zig");
const git = @import("../git.zig");
const config_mod = @import("../config.zig");
const snapshot = @import("../snapshot.zig");
const ratchet_mod = @import("../ratchet.zig");
const dora = @import("../dora.zig");
const retired_checks = @import("retired.zig");

const max_metadata_bytes = 16 * 1024 * 1024;
/// Characters of a commit hash a report prints to identify it.
const short_sha_len = 8;
const snapshots = [_][]const u8{
    "pub-api.txt",           "panic-budget.txt", "int-from-float-budget.txt",
    "unsafe-ops-budget.txt", "mutation.txt",     benchmark.leaf,
};

const Findings = struct {
    warnings: usize = 0,
    integrity: usize = 0,
};

/// Audits Guardian's local metadata without modifying project files. Only
/// corrupt/unreadable recognized metadata is fatal; stale files, cache growth,
/// and local path integration are advisory.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    var findings: Findings = .{};
    try inspectBaselines(ctx, &findings);
    try inspectSnapshots(ctx, &findings);
    try inspectMutationAdoption(ctx, &findings);
    try inspectMutationJournal(ctx, &findings);
    try inspectPendingAccepts(ctx, &findings);
    try inspectIntegration(ctx, &findings);
    inspectMergeDriver(ctx, &findings);
    try inspectCache(ctx, &findings);
    try inspectOperationalState(ctx, &findings);
    inspectBinaryIdentity(ctx, &findings);

    if (findings.integrity > 0) {
        reporter.fail("doctor found {d} metadata integrity problem(s) and {d} advisory warning(s)", .{
            findings.integrity, findings.warnings,
        });
        return error.CheckFailed;
    }
    reporter.ok("doctor: metadata integrity is healthy ({d} advisory warning(s))", .{findings.warnings});
}

fn inspectBaselines(ctx: *types.RunCtx, findings: *Findings) !void {
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/baselines", .{ctx.project_dir});
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => {
            integrity(findings, "cannot read baseline directory {s}: {s}", .{ path, @errorName(e) });
            return;
        },
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch |e| {
        integrity(findings, "cannot enumerate {s}: {s}", .{ path, @errorName(e) });
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const name = entry.name[0 .. entry.name.len - ".txt".len];
        if (!knownCheck(name)) {
            advisory(
                findings,
                "stale baseline: .guardian/baselines/{s} (preview with `debt --prune-stale`)",
                .{entry.name},
            );
        }
        const full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, entry.name });
        try inspectHeader(ctx.allocator, full, name, findings);
    }
}

fn inspectSnapshots(ctx: *types.RunCtx, findings: *Findings) !void {
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian", .{ctx.project_dir});
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => {
            integrity(findings, "cannot read metadata directory {s}: {s}", .{ path, @errorName(e) });
            return;
        },
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch |e| {
        integrity(findings, "cannot enumerate {s}: {s}", .{ path, @errorName(e) });
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        if (!contains(snapshots[0..], entry.name)) {
            advisory(findings, "unrecognized Guardian snapshot: .guardian/{s}", .{entry.name});
            continue;
        }
        const full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, entry.name });
        if (std.mem.eql(u8, entry.name, benchmark.leaf)) {
            _ = benchmark.read(ctx.allocator, full) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                integrity(findings, "corrupt benchmark ledger {s}: {s}; resolve the file or delete and re-record it", .{ full, @errorName(e) });
                continue;
            };
        } else {
            try inspectHeader(ctx.allocator, full, null, findings);
        }
    }
}

fn inspectHeader(allocator: std.mem.Allocator, path: []const u8, check_name: ?[]const u8, findings: *Findings) !void {
    const content = fs.cwd().readFileAlloc(allocator, path, max_metadata_bytes) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        integrity(findings, "cannot read recognized metadata {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    const parsed = snapshot.parseAnyVersion(allocator, content) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        integrity(findings, "corrupt Guardian metadata {s}: {s}; resolve merge damage or delete and re-accept the owning check", .{ path, @errorName(e) });
        return;
    };
    if (check_name) |name| {
        if (ratchet_mod.metricMode(name) != null) {
            for (parsed.lines, 0..) |line, i| {
                if (ratchet_mod.decodeLine(line) == null) integrity(
                    findings,
                    "corrupt ratchet row {s}:{d}: '{s}'; restore `<value> <key>` or re-accept {s}",
                    .{ path, i + 2, line, name },
                );
            }
        }
    }
}

/// Validates ignored operational state that the ordinary metadata-directory
/// sweep deliberately skips: green stamp, last-run sink, and DORA stream.
fn inspectOperationalState(ctx: *types.RunCtx, findings: *Findings) !void {
    try inspectGreenStamp(ctx, findings);
    try inspectJsonLines(ctx, findings, ".guardian/cache/last-run.jsonl", .last_run);
    try inspectJsonLines(ctx, findings, ctx.cfg.dora.sink_path, .dora);
}

fn inspectGreenStamp(ctx: *types.RunCtx, findings: *Findings) !void {
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/cache/inputs.sha256", .{ctx.project_dir});
    const raw = fs.cwd().readFileAlloc(ctx.allocator, path, 1024) catch |e| switch (e) {
        error.FileNotFound => return,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            integrity(findings, "cannot read green stamp {s}: {s}; delete it to force a full gate", .{ path, @errorName(e) });
            return;
        },
    };
    if (!cache.validStoredBytes(raw)) integrity(
        findings,
        "corrupt green stamp {s}; delete it to force a full gate",
        .{path},
    );
}

const LogKind = enum { last_run, dora };

fn inspectJsonLines(ctx: *types.RunCtx, findings: *Findings, configured_path: []const u8, kind: LogKind) !void {
    const path = if (std.fs.path.isAbsolute(configured_path))
        configured_path
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, configured_path });
    const raw = fs.cwd().readFileAlloc(ctx.allocator, path, max_metadata_bytes) catch |e| switch (e) {
        error.FileNotFound => return,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            integrity(findings, "cannot read operational log {s}: {s}", .{ path, @errorName(e) });
            return;
        },
    };
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;
        const valid = switch (kind) {
            .dora => dora.parseRecord(ctx.allocator, line) != null,
            .last_run => blk: {
                _ = std.json.parseFromSliceLeaky(std.json.Value, ctx.allocator, line, .{}) catch break :blk false;
                break :blk true;
            },
        };
        if (!valid) integrity(findings, "corrupt JSON record {s}:{d}; remove or repair that line", .{ path, line_no });
    }
}

fn inspectMutationAdoption(ctx: *types.RunCtx, findings: *Findings) !void {
    const config_path = try std.fmt.allocPrint(ctx.allocator, "{s}/guardian.toml", .{ctx.project_dir});
    const cfg = fs.cwd().readFileAlloc(ctx.allocator, config_path, 1024 * 1024) catch |e| blk: {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        break :blk "";
    };
    const marker = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/cache/last-mutate.jsonl", .{ctx.project_dir});
    const explicitly_configured = std.mem.indexOf(u8, cfg, "[mutation]") != null;
    const previously_run = blk: {
        fs.cwd().access(marker, .{}) catch break :blk false;
        break :blk true;
    };
    if (!explicitly_configured and !previously_run) return;
    const ratchet = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/mutation.txt", .{ctx.project_dir});
    fs.cwd().access(ratchet, .{}) catch {
        advisory(
            findings,
            "mutation is adopted but its ratchet is missing; run `guardian-check mutate --full {s}`",
            .{ctx.project_dir},
        );
    };
}

/// Reports a journal a previous `mutate` left behind. The case a fresh worktree
/// actually meets is a journal naming a file this checkout never contained: an
/// interrupted run in *another* checkout wrote it, nothing here is at risk, and
/// the next `mutate` drops it. That reads as a leftover to delete, not as an
/// alarm about a file the reader cannot even find.
fn inspectMutationJournal(ctx: *types.RunCtx, findings: *Findings) !void {
    const left = (try journal.leftover(ctx.allocator, ctx.project_dir)) orelse return;
    if (left.file_present) {
        advisory(findings, "mutation journal present for {s}: an interrupted run may have left a" ++
            " mutant applied; the next `guardian-check mutate` reverts it", .{left.rel_path});
        return;
    }
    advisory(findings, "stale mutation journal naming {s}, a file this checkout does not contain:" ++
        " an interrupted run in another checkout left it, so it is inert — delete {s}", .{ left.rel_path, journal.leaf });
}

/// Lists the session accept notes nothing else surfaces. A note suppresses
/// ratchet growth only while HEAD is unchanged (see accept_session.zig), so one
/// recorded at any other commit is inert — and invisible, because no command
/// prints it and nothing removes it. Both kinds are reported, aged in commits.
fn inspectPendingAccepts(ctx: *types.RunCtx, findings: *Findings) !void {
    const entries = try accept_session.recorded(ctx.allocator, ctx.project_dir);
    if (entries.len == 0) return;
    const head = git.headHash(ctx.allocator, ctx.project_dir);
    for (entries) |entry| reportPendingAccept(ctx, findings, entry, head);
}

/// One note's line: live at HEAD (a plain note — this is the mechanism working),
/// or expired, with how far back it was taken.
fn reportPendingAccept(
    ctx: *types.RunCtx,
    findings: *Findings,
    entry: accept_session.Entry,
    head: ?[]const u8,
) void {
    if (head != null and std.mem.eql(u8, head.?, entry.head)) {
        // A note, not a warning: this is the session mechanism working.
        reporter.detail("  note: pending accept: {s} is live for this session, recorded at HEAD {s}\n", .{
            entry.check, shortSha(entry.head),
        });
        return;
    }
    if (git.commitsBehindHead(ctx.allocator, ctx.project_dir, entry.head)) |behind| {
        advisory(findings, "expired pending accept: {s}, recorded at {s} — {d} commit(s) behind" ++
            " HEAD, so it suppresses nothing; delete {s}", .{ entry.check, shortSha(entry.head), behind, accept_session.leaf });
        return;
    }
    advisory(findings, "expired pending accept: {s}, recorded at {s} — not an ancestor of HEAD" ++
        " (another branch, or rewritten history); delete {s}", .{ entry.check, shortSha(entry.head), accept_session.leaf });
}

/// The leading characters of a commit hash, for a report that only needs to
/// identify it.
fn shortSha(sha: []const u8) []const u8 {
    return sha[0..@min(sha.len, short_sha_len)];
}

fn inspectIntegration(ctx: *types.RunCtx, findings: *Findings) !void {
    const zon_path = try std.fmt.allocPrint(ctx.allocator, "{s}/build.zig.zon", .{ctx.project_dir});
    const zon = fs.cwd().readFileAlloc(ctx.allocator, zon_path, 4 * 1024 * 1024) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    if (usesPathIntegration(zon)) {
        advisory(findings, "Guardian dependency uses a local path; pin a release URL + hash in CI/release builds", .{});
    }
}

fn usesPathIntegration(zon: []const u8) bool {
    return std.mem.indexOf(u8, zon, ".guardian =") != null and
        (std.mem.indexOf(u8, zon, ".path =") != null or std.mem.indexOf(u8, zon, "../guardian") != null);
}

/// Reports whether this clone resolves `.guardian/` conflicts automatically.
/// Advisory: a repository with one branch never needs the driver, and it is a
/// local convenience — nothing about the metadata is wrong without it.
fn inspectMergeDriver(ctx: *types.RunCtx, findings: *Findings) void {
    if (merge_driver.isInstalled(ctx.allocator, ctx.project_dir)) {
        reporter.detail("  ok: .guardian merge driver installed (conflicts resolve automatically)\n", .{});
        return;
    }
    advisory(
        findings,
        "no .guardian merge driver in this clone; run `guardian-check install-merge-driver {s}`",
        .{ctx.project_dir},
    );
}

fn inspectCache(ctx: *types.RunCtx, findings: *Findings) !void {
    try inspectOneCache(ctx, findings, ".guardian/cache", ctx.cfg.doctor.guardian_cache_warn_mib);
    for ([_][]const u8{ ".zig-cache", "zig-cache" }) |leaf|
        try inspectOneCache(ctx, findings, leaf, ctx.cfg.doctor.zig_cache_warn_mib);
}

fn inspectOneCache(ctx: *types.RunCtx, findings: *Findings, leaf: []const u8, warn_mib: u32) !void {
    if (warn_mib == 0) return;
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, leaf });
    const bytes = (try dirSize(ctx.allocator, path)) orelse return;
    const warn_bytes = @as(u64, warn_mib) * 1024 * 1024;
    if (bytes >= warn_bytes) {
        advisory(findings, "derived cache {s} is {d} MiB; consider clearing it when no build is running", .{
            leaf, bytes / (1024 * 1024),
        });
    }
}

fn dirSize(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?u64 {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next() catch return null) |entry| {
        if (entry.kind == .file) {
            total += (dir.statFile(entry.name) catch continue).size;
        } else if (entry.kind == .directory) {
            const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
            total += (try dirSize(allocator, child)) orelse 0;
        }
    }
    return total;
}

/// Advises when the last green run recorded a guardian binary identity that
/// differs from the running one — the phantom-red trap (a stale binary reports
/// snapshot/ratchet drift a fresh dep-built gate does not). Best-effort: a
/// missing stamp / I/O error is simply not reported.
fn inspectBinaryIdentity(ctx: *types.RunCtx, findings: *Findings) void {
    const stored = cache.readStoredBinaryId(ctx.allocator, ctx.project_dir) catch return;
    const current = cache.currentBinaryIdHash(ctx.allocator) catch return;
    if (staleGatingBinary(stored, current)) advisory(
        findings,
        "the last green run was gated by a different guardian-check binary; rebuild (zig build) before trusting any snapshot/ratchet drift",
        .{},
    );
}

/// Pure decision behind `inspectBinaryIdentity`: stale only when a green stamp
/// recorded a binary identity (present) that differs from the running binary's.
fn staleGatingBinary(stored: ?cache.Digest, current: cache.Digest) bool {
    const s = stored orelse return false;
    return !cache.eql(s, current);
}

fn knownCheck(name: []const u8) bool {
    if (registry.find(name) != null) return true;
    return retired_checks.find(name) != null;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn advisory(findings: *Findings, comptime fmt: []const u8, args: anytype) void {
    findings.warnings += 1;
    reporter.detail("  warning: " ++ fmt ++ "\n", args);
}

fn integrity(findings: *Findings, comptime fmt: []const u8, args: anytype) void {
    findings.integrity += 1;
    reporter.detail("  integrity: " ++ fmt ++ "\n", args);
}

// spec: Maintenance - Doctor distinguishes advisory warnings from integrity failures

test "knownCheck accepts live and intentionally retired names" {
    try std.testing.expect(knownCheck("spec"));
    try std.testing.expect(knownCheck("doc-quality"));
    try std.testing.expect(!knownCheck("removed-without-migration"));
}

test "path integration detector ignores the package paths field" {
    try std.testing.expect(!usesPathIntegration(".name = .guardian, .paths = .{ \"src\" }"));
    try std.testing.expect(usesPathIntegration(".guardian = .{ .path = \"../guardian-zig\" }"));
}

// spec: Maintenance - Doctor reports a stale gating binary

test "staleGatingBinary flags only a present, differing stamp" {
    var a: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("binary-A", &a, .{});
    var b: cache.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("binary-B", &b, .{});
    // No stamp recorded yet: nothing to compare, so no finding.
    try std.testing.expect(!staleGatingBinary(null, a));
    // The same binary that last gated the tree: healthy.
    try std.testing.expect(!staleGatingBinary(a, a));
    // A different binary than the last green run's: stale, worth a warning.
    try std.testing.expect(staleGatingBinary(a, b));
}

// spec: Maintenance - Doctor ages every pending accept and warns about an expired one

test "pending accepts read as live at HEAD and expired anywhere else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/doctor-pending-accepts";
    fs.cwd().deleteTree(dir) catch |e| std.log.warn("doctor test setup: {s}", .{@errorName(e)});
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("doctor test cleanup: {s}", .{@errorName(e)});
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default;
    defer reporter.default = prior;
    reporter.default = .{ .capture = &cap };

    const cfg: config_mod.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &cfg, .quiet = true };
    var findings: Findings = .{};
    // Live at HEAD: the session mechanism working, so a note and not a warning.
    reportPendingAccept(&ctx, &findings, .{ .head = "aaaa1111bbbb", .check = "file-size" }, "aaaa1111bbbb");
    try std.testing.expectEqual(@as(usize, 0), findings.warnings);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "note: pending accept: file-size is live") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "aaaa1111") != null);

    // Recorded at some other commit: inert, invisible without this line, and
    // named with the file to delete.
    reportPendingAccept(&ctx, &findings, .{ .head = "cccc2222dddd", .check = "type-size" }, "aaaa1111bbbb");
    try std.testing.expectEqual(@as(usize, 1), findings.warnings);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "expired pending accept: type-size") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, accept_session.leaf) != null);
}

// spec: Maintenance - Doctor reports a mutation journal for an absent file as an inert leftover

test "a journal naming a file this checkout lacks reads as a leftover to delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/doctor-mutation-journal";
    fs.cwd().deleteTree(dir) catch |e| std.log.warn("doctor test setup: {s}", .{@errorName(e)});
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("doctor test cleanup: {s}", .{@errorName(e)});
    try fs.cwd().makePath(dir ++ "/src");
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default;
    defer reporter.default = prior;
    reporter.default = .{ .capture = &cap };

    const cfg: config_mod.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = dir, .cfg = &cfg, .quiet = true };
    var findings: Findings = .{};
    // No journal at all: the normal state, and doctor says nothing about it.
    try inspectMutationJournal(&ctx, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.warnings);

    const rel = "src/gone.zig";
    const abs = try std.fs.path.join(a, &.{ dir, rel });
    try fs.cwd().writeFile(.{ .sub_path = abs, .data = "return a < b;\n" });
    journal.begin(a, dir, .{
        .rel_path = rel,
        .abs_path = abs,
        .original = "return a < b;\n",
        .mutated = "return a <= b;\n",
        .start = 9,
        .end = 10,
    });
    try fs.cwd().deleteFile(abs);
    try inspectMutationJournal(&ctx, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.warnings);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "stale mutation journal naming src/gone.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "inert") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, journal.leaf) != null);
}
