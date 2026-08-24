//! Explicit, named baseline/snapshot acceptance workflow. It previews the
//! selected failures, refreshes only those checks, then reruns them without a
//! refresh so the command cannot report success on unverifiable metadata.
//!
//! Those three passes are the minimum: the preview is the review artifact (what
//! the accept is agreeing to), the update is the one metadata-writable step, and
//! the verify is what stops the command reporting success on metadata nobody
//! re-read. What they must NOT do is three parses of one unchanged tree, so the
//! source index is built once here and shared (see run_all.parsesTree). Under
//! `--quiet` each pass's own output is captured and dropped, leaving the accepted
//! checks' before/after counts and the `.guardian/` paths that moved.

const std = @import("std");
const types = @import("types.zig");
const run_all = @import("run_all.zig");
const reporter = @import("../reporter.zig");
const ratchet = @import("../ratchet.zig");
const snapshot_file = @import("../snapshot.zig");
const baseline = @import("../baseline.zig");
const accept_session = @import("../accept_session.zig");
const ast_index = @import("../ast/index.zig");
const metadata_transaction = @import("../metadata_transaction.zig");
const writer_lock = @import("../writer_lock.zig");

pub const command_name = "accept";

/// One captured `.guardian/` file, as the metadata transaction records it.
const Original = metadata_transaction.Original;

/// Reviews, accepts, and verifies the checks named in `ctx.refresh`.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    if (ctx.refresh.len == 0) {
        reporter.fail("accept: name at least one check (comma-separated)", .{});
        reporter.detail("  usage: zig build guardian-accept -Dguardian-checks=file-size,line-length\n", .{});
        reporter.detail("         raw CLI fallback: guardian-check accept file-size,line-length .\n", .{});
        return error.CheckFailed;
    }
    try rejectDashNames(ctx.refresh);
    try run_all.validateCheckNames(ctx.refresh, "accept");

    var lock = writer_lock.acquire(ctx.allocator, ctx.project_dir) catch |err| {
        reporter.fail("accept: cannot acquire {s}/{s} ({s}) — wait for the current writer; a crashed process releases the kernel lock automatically", .{
            ctx.project_dir, writer_lock.leaf, @errorName(err),
        });
        return error.CheckFailed;
    };
    defer lock.deinit();
    ctx.writer_lock_held = true;

    // Acceptance depends on run_all returning the blocking verdict (CheckFailed
    // on drift) so preview/update/verify partition correctly — force blocking
    // regardless of [gate] on_build. The copies below inherit this.
    ctx.gate = true;
    // One parse for all three passes over one unchanged tree.
    try shareSourceIndex(ctx);
    const quiet = ctx.quiet;
    var before_metadata = metadataState(ctx);
    defer if (before_metadata) |*state| state.deinit();

    var before: run_all.PassSummary = .{};
    var preview = ctx.*;
    preview.only = ctx.refresh;
    preview.refresh = &.{};
    runPass(&preview, quiet, &before, .drift_expected) catch |e| switch (e) {
        error.CheckFailed => if (!quiet)
            reporter.ok("accept: preview complete; applying only the named refreshes", .{}),
        else => return e,
    };

    var update = ctx.*;
    update.only = ctx.refresh;
    // The update pass is the one metadata-writable step: it persists the named
    // checks' refreshes AND any deferred prune/create/re-key on those checks.
    update.metadata_writable = true;
    runPass(&update, quiet, null, .must_pass) catch |e| {
        try preservePriorRatchetCeilings(ctx, if (before_metadata) |*state| state else null);
        return e;
    };
    try preservePriorRatchetCeilings(ctx, if (before_metadata) |*state| state else null);

    var after: run_all.PassSummary = .{};
    var verify = ctx.*;
    verify.only = ctx.refresh;
    verify.refresh = &.{};
    try runPass(&verify, quiet, &after, .must_pass);
    recordSession(ctx);
    if (!quiet) {
        reporter.ok("accept: verified {d} named check(s); review and commit the .guardian/ diff", .{ctx.refresh.len});
        return;
    }
    reportQuiet(ctx, before, after, if (before_metadata) |*state| state else null);
}

/// Restores only monotone ratchet improvements that happened incidentally
/// inside an accepted check. For each named threshold check, union the old and
/// refreshed rows and keep the larger value per key: intended raises/new keys
/// remain accepted, while unrelated lowerings/prunes wait for their own
/// maintenance diff. Snapshot-style checks retain their normal full refresh.
fn preservePriorRatchetCeilings(
    ctx: *types.RunCtx,
    before: ?*const metadata_transaction.Transaction,
) (snapshot_file.ReadError || snapshot_file.WriteError)!void {
    const state = before orelse return;
    const a = ctx.allocator;
    for (ctx.refresh) |name| {
        if (ratchet.metricMode(name) == null) continue;
        const rel = try std.fmt.allocPrint(a, "baselines/{s}.txt", .{name});
        const prior_content = findPath(state.originals, rel) orelse continue;
        const prior_snap = snapshot_file.parse(a, prior_content, ratchet.version) catch |e| switch (e) {
            error.VersionMismatch, error.BadFormat => continue,
            else => return e,
        };
        const path = try baseline.pathFor(a, ctx.project_dir, name);
        const refreshed_snap = try snapshot_file.read(a, path, ratchet.version);
        const prior = try ratchet.decodeLines(a, prior_snap.lines);
        const refreshed = try ratchet.decodeLines(a, refreshed_snap.lines);
        try ratchet.writeEntries(a, path, try ratchet.mergeAccepted(a, prior, refreshed));
    }
}

/// Whether a pass is expected to report drift. The preview is (that IS the
/// thing being accepted), so a quiet run drops its captured output; the update
/// and verify passes must pass, and a quiet run replays their output when they
/// do not — a silent failure would leave nothing to diagnose from.
const PassKind = enum { drift_expected, must_pass };

/// `guardian-check accept --help` parses `--help` as a check name (the CLI has
/// no accept-specific flag parsing); the unknown-name error that follows is
/// correct but terminal. A name beginning with a dash is a flag-shaped typo, so
/// say so and print the usage instead of a bare "unknown check name".
fn rejectDashNames(names: []const []const u8) types.RunError!void {
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, "-")) continue;
        reporter.fail("accept: {s} is not a check name (did you mean `guardian-check accept <check> .`?)", .{name});
        reporter.detail("  usage: zig build guardian-accept -Dguardian-checks=file-size,line-length\n", .{});
        reporter.detail("         raw CLI fallback: guardian-check accept file-size,line-length .\n", .{});
        return error.CheckFailed;
    }
}

/// Runs one `all` pass, recording what it found. Under `--quiet` the pass's own
/// output is captured instead of printed, so the command's whole output is its
/// own summary — except for an unexpected failure, whose captured detail is the
/// only diagnosis available.
fn runPass(
    pass: *types.RunCtx,
    quiet: bool,
    out: ?*run_all.PassSummary,
    kind: PassKind,
) types.RunError!void {
    if (!quiet) return run_all.runCollecting(pass, out);
    var cap: reporter.Capture = .{ .allocator = pass.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    reporter.default.capture = &cap;
    defer reporter.default.capture = prior;
    run_all.runCollecting(pass, out) catch |e| {
        reporter.default.capture = prior;
        if (kind == .must_pass) reporter.detail("{s}", .{cap.buf.items});
        return e;
    };
}

/// Builds the parsed-source index once for the whole command. Every pass reads
/// the same unchanged tree, and an accept forces a whole-tree run, so one parse
/// serves all three. Failure propagates: the first pass would have hit the same
/// unreadable tree, and an accept that cannot read the source must not go on to
/// rewrite metadata about it.
fn shareSourceIndex(ctx: *types.RunCtx) types.RunError!void {
    const storage = try ctx.allocator.create(ast_index.Index);
    storage.* = try ast_index.build(ctx.allocator, ctx.project_dir, ctx.cfg.exclude);
    ctx.source_index = storage;
}

/// Snapshots the checked-in `.guardian/` tree so the quiet report can name what
/// the accept actually moved. Null when it cannot be read — the summary then
/// says so rather than claiming nothing changed.
fn metadataState(ctx: *types.RunCtx) ?metadata_transaction.Transaction {
    return metadata_transaction.Transaction.begin(ctx.allocator, ctx.project_dir) catch null;
}

/// The whole output of a quiet accept: what each named check found before and
/// after, and which metadata files moved. Everything else the three passes
/// printed is in `.guardian/cache/last-run.jsonl`.
fn reportQuiet(
    ctx: *types.RunCtx,
    before: run_all.PassSummary,
    after: run_all.PassSummary,
    metadata: ?*metadata_transaction.Transaction,
) void {
    const names = std.mem.join(ctx.allocator, ",", ctx.refresh) catch ctx.refresh[0];
    reporter.detail(reporter.prefix ++ "accept: {s} — {d} finding(s) before, {d} after\n", .{
        names, before.findings, after.findings,
    });
    const state = metadata orelse {
        reporter.detail(reporter.prefix ++ "accept: could not read .guardian/ — " ++
            "check `git status .guardian` for what moved\n", .{});
        return;
    };
    reportMetadataChanges(ctx, state);
}

/// Names every `.guardian/` file the update pass wrote, changed, or removed, by
/// re-reading the tree and diffing it against the pre-update snapshot.
fn reportMetadataChanges(ctx: *types.RunCtx, before: *metadata_transaction.Transaction) void {
    var after = metadata_transaction.Transaction.begin(ctx.allocator, ctx.project_dir) catch {
        reporter.detail(reporter.prefix ++ "accept: could not re-read .guardian/ — " ++
            "check `git status .guardian` for what moved\n", .{});
        return;
    };
    defer after.deinit();
    var changed: usize = 0;
    for (after.originals) |now| changed += reportOne(before.originals, now);
    for (before.originals) |was| changed += reportRemoved(after.originals, was);
    if (changed == 0) reporter.detail(reporter.prefix ++ "accept: .guardian/ unchanged\n", .{});
}

/// Prints one metadata path when it is new or its bytes moved; returns how many
/// lines it printed (0 or 1) so the caller can report an unchanged tree.
fn reportOne(before: []const Original, now: Original) usize {
    const was = findPath(before, now.rel_path) orelse {
        reporter.detail(reporter.prefix ++ "accept: .guardian/{s} created\n", .{now.rel_path});
        return 1;
    };
    if (std.mem.eql(u8, was, now.content)) return 0;
    reporter.detail(reporter.prefix ++ "accept: .guardian/{s} updated\n", .{now.rel_path});
    return 1;
}

/// Prints a metadata path that existed before the accept and no longer does.
fn reportRemoved(after: []const Original, was: Original) usize {
    if (findPath(after, was.rel_path) != null) return 0;
    reporter.detail(reporter.prefix ++ "accept: .guardian/{s} removed\n", .{was.rel_path});
    return 1;
}

/// The recorded bytes of `rel_path` in a metadata snapshot; null when absent.
fn findPath(entries: []const Original, rel_path: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.rel_path, rel_path)) return e.content;
    }
    return null;
}

/// Upper bound on names the session note records per accept — comfortably
/// above the ten ratchet checks that exist, so the bound never truncates a
/// real invocation.
const max_session_names = 16;

/// Records the accepted RATCHET checks as this session's pending accepts, so
/// the same subjects may keep growing until the next commit without another
/// accept round-trip (see accept_session.zig). Non-ratchet names are skipped —
/// only the ratchet lifecycle consults the note. Best-effort by design.
fn recordSession(ctx: *types.RunCtx) void {
    var names: [max_session_names][]const u8 = undefined;
    var n: usize = 0;
    for (ctx.refresh) |name| {
        if (ratchet.metricMode(name) == null) continue;
        if (n == names.len) break;
        names[n] = name;
        n += 1;
    }
    if (n == 0) return;
    accept_session.record(ctx.allocator, ctx.project_dir, names[0..n]);
}

// spec: Maintenance - Accept refreshes only named checks and verifies them after updating metadata

test "accept command name remains stable for build-helper integration" {
    try std.testing.expectEqualStrings("accept", command_name);
}

// spec: Maintenance - Accept preserves unrelated lowerings and prunes within a named ratchet check

test "named ratchet acceptance keeps prior ceilings outside the accepted growth" {
    _ = &preservePriorRatchetCeilings;
    const prior = [_]ratchet.Entry{
        .{ .key = "pruned", .value = 12 },
        .{ .key = "lowered", .value = 10 },
        .{ .key = "grown", .value = 4 },
    };
    const refreshed = [_]ratchet.Entry{
        .{ .key = "lowered", .value = 7 },
        .{ .key = "grown", .value = 6 },
    };
    const merged = try ratchet.mergeAccepted(std.testing.allocator, &prior, &refreshed);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqual(@as(u64, 6), merged[0].value);
    try std.testing.expectEqual(@as(u64, 10), merged[1].value);
    try std.testing.expectEqual(@as(u64, 12), merged[2].value);
}

// spec: Command Ergonomics - Prints the accept usage when an unknown check name begins with a dash

test "a dash-shaped accept name gets usage instead of a bare unknown-name error" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    // `accept --help` reaches the command as a check name; the message says it
    // is not one and names the working spelling.
    try std.testing.expectError(error.CheckFailed, rejectDashNames(&.{"--help"}));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "is not a check name") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "guardian-check accept <check>") != null);

    // A genuine check name passes straight through.
    cap.buf.clearRetainingCapacity();
    try rejectDashNames(&.{ "pub-api-surface", "type-size" });
    try std.testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

// spec: Command Ergonomics - Reports a quiet accept as before and after counts with the metadata paths that moved

test "a quiet accept names only what moved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The three passes each print a `run-all:` verdict for one named check; the
    // quiet summary replaces all of it with the counts the reader came for.
    const before: run_all.PassSummary = .{ .findings = 12, .failed = 1 };
    const after: run_all.PassSummary = .{};
    try std.testing.expectEqual(@as(usize, 12), before.findings);
    try std.testing.expectEqual(@as(usize, 0), after.findings);

    // The metadata half is a diff of two `.guardian/` snapshots, so an accept
    // that rewrote nothing says so instead of implying a change.
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default;
    defer reporter.default = prior;
    reporter.default = .{ .capture = &cap };
    const snapshot = [_]Original{.{ .rel_path = "pub-api.txt", .content = "a\n" }};
    try std.testing.expectEqual(@as(usize, 0), reportOne(&snapshot, snapshot[0]));
    // A rewritten file and a brand-new one each print exactly one line.
    try std.testing.expectEqual(@as(usize, 1), reportOne(&snapshot, .{ .rel_path = "pub-api.txt", .content = "b\n" }));
    try std.testing.expectEqual(@as(usize, 1), reportOne(&snapshot, .{ .rel_path = "mutation.txt", .content = "" }));
    try std.testing.expectEqual(@as(usize, 1), reportRemoved(&.{}, snapshot[0]));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, ".guardian/pub-api.txt updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, ".guardian/mutation.txt created") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, ".guardian/pub-api.txt removed") != null);
    // The pass entry points stay distinct: `run` reports nothing back,
    // `runCollecting` is the one a quiet accept measures with.
    try std.testing.expect(@TypeOf(run_all.run) != @TypeOf(run_all.runCollecting));
}
