//! `merge-file` — the git merge-driver entry point for `.guardian/` metadata.
//!
//! **Argument order is git's, not English's.** git invokes a driver with
//! `%O %A %B`, which is BASE, OURS, THEIRS, and the driver must leave the merged
//! result in the file named by `%A`. This command takes its three positionals in
//! exactly that order so the configured driver line and the help text cannot
//! drift apart:
//!
//! ```
//! guardian-check merge-file <base> <ours> <theirs> [--path <repo-relative>]
//! ```
//!
//! `--path` is git's `%P` (the real pathname), a hint only: the three files it
//! is handed are temporaries, so format detection cannot depend on their names.
//!
//! Exit 0 means the result was written. Any refusal — a format with no safe
//! automatic resolution, headers that disagree, an input that is itself an
//! unresolved conflict — exits non-zero WITHOUT writing, so git records an
//! ordinary conflict and the human resolves it by regenerating.

const std = @import("std");
const fs = @import("../fs.zig");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const snapshot = @import("../snapshot.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const artifact = @import("../merge/artifact.zig");
const three_way = @import("../merge/three_way.zig");

/// CLI name check.zig dispatches to this command.
pub const command_name = "merge-file";

/// Upper bound on a metadata file the driver will merge.
const max_bytes = 16 * 1024 * 1024;

/// One side of the merge: where it came from and what it holds.
const Side = struct {
    path: []const u8,
    content: []const u8,
    file: artifact.File,
};

/// CLI entry: merge the three files named on the command line, writing the
/// result over the `ours` path. Returns `error.CheckFailed` on any refusal.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    const args = ctx.merge;
    if (!args.complete()) return usage();
    const hint = args.hint();
    const base = try load(a, args.base);
    const ours = try load(a, args.ours);
    const theirs = try load(a, args.theirs);

    const sides = [_]Side{ base, ours, theirs };
    for (sides) |s| {
        if (try problemIn(a, s)) |_| return error.CheckFailed;
    }
    const version = versionOf(sides) orelse
        return refuse(hint, "the three sides declare different snapshot versions");
    const kind = artifact.classify(hint, version, try pooledRows(a, sides));
    if (kind == .unmergeable) return refuse(hint, "no automatic resolution exists for this format");

    const merged = try resolve(a, kind, sides);
    const marked = merged.needs_regen or base.file.pending_regen or
        ours.file.pending_regen or theirs.file.pending_regen;
    const rendered = try render(a, version, merged.lines, if (marked) try markerLine(a, hint) else null);
    fs.cwd().writeFile(.{ .sub_path = args.ours, .data = rendered }) catch {
        reporter.fail("merge-file: could not write the merged result to {s}", .{args.ours});
        return error.CheckFailed;
    };
    report(kind, merged, marked, hint);
}

/// The merged rows for one artifact kind, plus whether the result is a guess
/// that has to be regenerated (only a contested counter ever is).
const Merged = struct {
    lines: []const []const u8,
    needs_regen: bool,
};

/// Applies the rule for `kind` to the three sides' rows.
fn resolve(a: Allocator, kind: artifact.Kind, sides: [3]Side) Allocator.Error!Merged {
    const base = sides[0].file.rows;
    const ours = sides[1].file.rows;
    const theirs = sides[2].file.rows;
    return switch (kind) {
        .identity_baseline, .pub_api => .{
            .lines = try three_way.mergeRows(a, base, ours, theirs),
            .needs_regen = false,
        },
        .ratchet => .{
            .lines = try three_way.mergeRatchets(a, base, ours, theirs),
            .needs_regen = false,
        },
        .counters => blk: {
            const c = try three_way.mergeCounters(a, base, ours, theirs);
            break :blk .{ .lines = c.lines, .needs_regen = c.needs_regen };
        },
        // Refused before `resolve` is reached; listed so a new kind must decide.
        .unmergeable => .{ .lines = &.{}, .needs_regen = false },
    };
}

/// Reads one side. A missing file is the empty side (git omits the base when
/// both branches added the path), never an error.
fn load(a: Allocator, path: []const u8) Allocator.Error!Side {
    const content = fs.cwd().readFileAlloc(a, path, max_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => "",
    };
    const parsed = try artifact.parse(a, content);
    return .{ .path = path, .content = content, .file = parsed.value() };
}

/// Reports (and returns) the located parse failure in `side`, if any. Re-parses
/// rather than threading the Parsed union through `Side`, so the happy path
/// carries no error state.
fn problemIn(a: Allocator, side: Side) Allocator.Error!?artifact.Problem {
    const parsed = try artifact.parse(a, side.content);
    const p = parsed.failure() orelse return null;
    reporter.fail("merge-file: {s}:{d}: {s}", .{ side.path, p.line, describe(p.kind) });
    reporter.detail("  row: {s}\n", .{p.text});
    return p;
}

/// One-line explanation of a parse failure.
fn describe(kind: artifact.ProblemKind) []const u8 {
    return switch (kind) {
        .conflict_markers => "unresolved conflict markers in a merge input",
        .missing_header => "no `# guardian-snapshot v<N>` header",
        .malformed_row => "row does not parse in this file's format",
    };
}

/// The version all three sides agree on, or null when two of them declare
/// different ones (a self-migration mid-branch — regenerate, never guess).
/// A side with no header of its own (version 0) abstains.
fn versionOf(sides: [3]Side) ?u32 {
    var agreed: ?u32 = null;
    for (sides) |s| {
        if (s.file.version == 0) continue;
        const v = agreed orelse {
            agreed = s.file.version;
            continue;
        };
        if (v != s.file.version) return null;
    }
    return agreed;
}

/// Every side's rows in one slice, so format detection cannot be fooled by an
/// empty side.
fn pooledRows(a: Allocator, sides: [3]Side) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (sides) |s| try out.appendSlice(a, s.file.rows);
    return out.toOwnedSlice(a);
}

/// The bytes to write: the version header, `marker` when the result contains a
/// guessed value, then one row per line.
fn render(
    a: Allocator,
    version: u32,
    lines: []const []const u8,
    marker: ?[]const u8,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}{d}\n", .{ snapshot.magic_prefix, version }));
    if (marker) |m| try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}\n", .{m}));
    for (lines) |line| try buf.appendSlice(a, try std.fmt.allocPrint(a, "{s}\n", .{line}));
    return buf.toOwnedSlice(a);
}

/// The comment stamped on a guessed merge, naming the refresh that replaces the
/// guess with a measurement (a `<check>` placeholder when git gave no pathname —
/// the `merge-state` check derives the real name from the file it finds).
fn markerLine(a: Allocator, hint: ?[]const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s} ({s}={s})", .{
        snapshot.regen_marker,
        snapshot_helper.update_env,
        checkNameFor(hint),
    });
}

/// The check whose refresh regenerates the file at `path` — its leaf without
/// the `.txt`, with the one leaf that is spelled differently from its check
/// (`pub-api.txt`) resolved. `<check>` when there is no pathname to read.
fn checkNameFor(path: ?[]const u8) []const u8 {
    const p = path orelse return "<check>";
    const leaf = std.fs.path.basename(p);
    if (!std.mem.endsWith(u8, leaf, ".txt")) return "<check>";
    return snapshot_helper.canonicalCheckName(leaf[0 .. leaf.len - ".txt".len]);
}

/// Prints the one-line outcome, plus the regeneration command when the result
/// contains a guessed counter.
fn report(kind: artifact.Kind, merged: Merged, marked: bool, hint: ?[]const u8) void {
    reporter.ok("merge-file: merged {d} {s} row(s)", .{ merged.lines.len, @tagName(kind) });
    if (!marked) return;
    reporter.detail(
        "  both sides moved a counter — the file is marked for regeneration: {s}={s} zig build\n",
        .{ snapshot_helper.update_env, checkNameFor(hint) },
    );
}

/// Refuses the merge: git records an ordinary conflict, and the message names
/// the resolution that always works — regenerate on the merged tree.
fn refuse(hint: ?[]const u8, why: []const u8) types.RunError {
    reporter.fail("merge-file: cannot merge {s} — {s}", .{ hint orelse "this file", why });
    reporter.detail("  git will record an ordinary conflict; resolve it by regenerating on the\n", .{});
    reporter.detail(
        "  merged tree — for a check's snapshot that is `{s}={s} zig build`,\n",
        .{ snapshot_helper.update_env, checkNameFor(hint) },
    );
    reporter.detail("  and for a ledger (mutation, benchmarks) the command that owns it.\n", .{});
    return error.CheckFailed;
}

/// Refuses an invocation that did not name all three files.
fn usage() types.RunError {
    reporter.fail("merge-file: needs three paths in git's own order", .{});
    reporter.detail("  usage: guardian-check merge-file <base> <ours> <theirs> [--path <repo-relative>]\n", .{});
    reporter.detail("  git spells that `%O %A %B`; the merged result is written to <ours> (%A)\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Merge - Names the refreshing check for the file being merged

test "checkNameFor maps a metadata leaf to its refresh check" {
    try testing.expectEqualStrings("unsafe-ops-budget", checkNameFor(".guardian/unsafe-ops-budget.txt"));
    try testing.expectEqualStrings("file-size", checkNameFor(".guardian/baselines/file-size.txt"));
    // The one leaf spelled differently from its check name.
    try testing.expectEqualStrings("pub-api-surface", checkNameFor(".guardian/pub-api.txt"));
    // No pathname (git ran the driver without %P): the command keeps a
    // placeholder rather than naming the wrong check.
    try testing.expectEqualStrings("<check>", checkNameFor(null));
}

// spec: Merge - Renders the merged file with its header and regenerate marker

test "render writes the header, the optional marker, and one row per line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = [_][]const u8{ "@alignCast 67", "@bitCast 0" };
    const clean = try render(a, 1, &rows, null);
    try testing.expectEqualStrings("# guardian-snapshot v1\n@alignCast 67\n@bitCast 0\n", clean);

    // The marked variant names the exact refresh command for that file, and
    // parses back as a normal snapshot (the marker is a comment).
    const marked = try render(a, 1, &rows, try markerLine(a, ".guardian/unsafe-ops-budget.txt"));
    try testing.expect(snapshot.hasRegenMarker(marked));
    try testing.expect(std.mem.indexOf(u8, marked, "GUARDIAN_UPDATE_SNAPSHOT=unsafe-ops-budget") != null);
    try testing.expectEqual(@as(usize, 2), (try snapshot.parse(a, marked, 1)).lines.len);
}

/// Scratch directory for the fixture merges below (created on demand, and each
/// fixture removes its own three files).
const fixture_dir = "zig-cache";

/// Writes the three sides of one merge to real files, runs the command over
/// them exactly as git would, and returns what it left in the `ours` file.
/// Every side is deleted before returning, so a run leaves no scratch behind.
fn runFixture(a: Allocator, stem: []const u8, hint: []const u8, sides: [3][]const u8) ![]const u8 {
    var ctx = try fixtureCtx(a, stem, hint, sides);
    defer removeFixture(ctx.merge);
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    try run(&ctx);
    return fs.cwd().readFileAlloc(a, ctx.merge.ours, max_bytes);
}

/// The refusal twin of `runFixture`: returns the error the command raised (and
/// the untouched `ours` bytes are checked by the caller through `sides`).
fn runFixtureFailing(a: Allocator, stem: []const u8, hint: []const u8, sides: [3][]const u8) !void {
    var ctx = try fixtureCtx(a, stem, hint, sides);
    defer removeFixture(ctx.merge);
    var cap: reporter.Capture = .{ .allocator = a };
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    try testing.expectError(error.CheckFailed, run(&ctx));
    // A refusal must not have touched the worktree's own copy.
    const after = try fs.cwd().readFileAlloc(a, ctx.merge.ours, max_bytes);
    try testing.expectEqualStrings(sides[1], after);
}

/// Builds a run context over three freshly written fixture files.
fn fixtureCtx(a: Allocator, stem: []const u8, hint: []const u8, sides: [3][]const u8) !types.RunCtx {
    const config = @import("../config.zig");
    try fs.cwd().makePath(fixture_dir);
    const suffixes = [_][]const u8{ "base", "ours", "theirs" };
    var paths: [3][]const u8 = undefined;
    for (suffixes, sides, 0..) |suffix, body, i| {
        paths[i] = try std.fmt.allocPrint(a, "{s}/merge-{s}-{s}.txt", .{ fixture_dir, stem, suffix });
        try fs.cwd().writeFile(.{ .sub_path = paths[i], .data = body });
    }
    const cfg = try a.create(config.Config);
    cfg.* = .{};
    return .{
        .allocator = a,
        .project_dir = ".",
        .cfg = cfg,
        .quiet = true,
        .merge = .{ .base = paths[0], .ours = paths[1], .theirs = paths[2], .path = hint },
    };
}

/// Deletes one fixture's three files.
fn removeFixture(inputs: types.MergeInputs) void {
    for ([_][]const u8{ inputs.base, inputs.ours, inputs.theirs }) |p| {
        fs.cwd().deleteFile(p) catch |e|
            std.log.warn("test cleanup {s}: {s}", .{ p, @errorName(e) });
    }
}

// spec: Merge - Merges a counter file both sides grew and marks it for regeneration

test "merge-file resolves a budget counter conflict from real files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const merged = try runFixture(a, "counters", ".guardian/unsafe-ops-budget.txt", .{
        "# guardian-snapshot v1\n@alignCast 65\n@constCast 47\n",
        "# guardian-snapshot v1\n@alignCast 66\n@constCast 47\n",
        "# guardian-snapshot v1\n@alignCast 67\n@constCast 50\n",
    });
    // The counter both branches grew takes the larger value and the file says
    // so; the one only theirs moved is adopted without comment.
    try testing.expect(std.mem.indexOf(u8, merged, "@alignCast 67\n") != null);
    try testing.expect(std.mem.indexOf(u8, merged, "@constCast 50\n") != null);
    try testing.expect(snapshot.hasRegenMarker(merged));
    try testing.expect(std.mem.indexOf(u8, merged, "GUARDIAN_UPDATE_SNAPSHOT=unsafe-ops-budget") != null);
}

// spec: Merge - Merges a per-item ratchet from real files

test "merge-file resolves a ratchet conflict to the tighter ceilings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const merged = try runFixture(a, "ratchet", ".guardian/baselines/file-size.txt", .{
        "# guardian-snapshot v2\n10400 src/router.zig\n900 src/old.zig\n",
        "# guardian-snapshot v2\n10360 src/router.zig\n900 src/old.zig\n",
        "# guardian-snapshot v2\n10398 src/router.zig\n",
    });
    try testing.expectEqualStrings("# guardian-snapshot v2\n10360 src/router.zig\n", merged);
    // A clean ratchet merge is never a guess, so it carries no marker.
    try testing.expect(!snapshot.hasRegenMarker(merged));
}

// spec: Merge - Merges identity baselines and the public API surface as sets

test "merge-file unions baseline and pub-api rows from real files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both sides added an entry; theirs resolved one the base had.
    const baseline_out = try runFixture(a, "identities", ".guardian/baselines/spec.txt", .{
        "# guardian-snapshot v3\nspec|a\nspec|b\n",
        "# guardian-snapshot v3\nspec|a\nspec|b\nspec|ours\n",
        "# guardian-snapshot v3\nspec|a\nspec|theirs\n",
    });
    try testing.expectEqualStrings("# guardian-snapshot v3\nspec|a\nspec|ours\nspec|theirs\n", baseline_out);

    // The same rule over the surface list, from an empty base (both branches
    // created the file) — a union with nothing to subtract.
    const api_out = try runFixture(a, "pubapi", ".guardian/pub-api.txt", .{
        "",
        "# guardian-snapshot v2\nsrc/a.zig::f | fn f() void\n",
        "# guardian-snapshot v2\nsrc/b.zig::g | fn g() void\n",
    });
    try testing.expect(std.mem.indexOf(u8, api_out, "src/a.zig::f") != null);
    try testing.expect(std.mem.indexOf(u8, api_out, "src/b.zig::g") != null);
}

// spec: Merge - Merges an unsorted side and writes a canonically sorted result

test "merge-file accepts an unsorted side and sorts the output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `ours` is what a hand-union leaves: correct entries, arbitrary order.
    const merged = try runFixture(a, "unsorted", ".guardian/pub-api.txt", .{
        "# guardian-snapshot v2\nsrc/a.zig::f | fn f() void\n",
        "# guardian-snapshot v2\nsrc/z.zig::z | fn z() void\nsrc/a.zig::f | fn f() void\n",
        "# guardian-snapshot v2\nsrc/a.zig::f | fn f() void\nsrc/m.zig::m | fn m() void\n",
    });
    const expected = "# guardian-snapshot v2\n" ++
        "src/a.zig::f | fn f() void\nsrc/m.zig::m | fn m() void\nsrc/z.zig::z | fn z() void\n";
    try testing.expectEqualStrings(expected, merged);
}

// spec: Merge - Refuses an input that still holds conflict markers

test "merge-file refuses a side that is itself unresolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try runFixtureFailing(a, "conflicted", ".guardian/pub-api.txt", .{
        "# guardian-snapshot v2\nsrc/a.zig::f | fn f() void\n",
        "# guardian-snapshot v2\n<<<<<<< HEAD\nsrc/a.zig::f | fn f() void\n=======\n>>>>>>> theirs\n",
        "# guardian-snapshot v2\nsrc/b.zig::g | fn g() void\n",
    });
}

// spec: Merge - Refuses a format with no safe automatic resolution

test "merge-file refuses the mutation ledger rather than guessing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two cohorts, two scores, no correct union — git keeps the conflict.
    try runFixtureFailing(a, "mutation", ".guardian/mutation.txt", .{
        "# guardian-snapshot v2\ncohort=aaaa\nscore_pct=50\n",
        "# guardian-snapshot v2\ncohort=bbbb\nscore_pct=54\n",
        "# guardian-snapshot v2\ncohort=cccc\nscore_pct=51\n",
    });
}

// spec: Merge - Refuses a merge whose sides declare different snapshot versions

test "versionOf agrees across sides, abstaining for an empty base" {
    const s = struct {
        fn side(v: u32) Side {
            return .{ .path = "x", .content = "", .file = .{ .version = v, .rows = &.{}, .pending_regen = false } };
        }
    };
    // An absent base (version 0) abstains rather than blocking the merge.
    try testing.expectEqual(@as(u32, 2), versionOf(.{ s.side(0), s.side(2), s.side(2) }).?);
    // One side self-migrated mid-branch: there is no correct union, so refuse.
    try testing.expect(versionOf(.{ s.side(2), s.side(2), s.side(3) }) == null);
}
