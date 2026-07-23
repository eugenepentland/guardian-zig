//! `commit` command — intent-driven auto-commit, bringing guardian-zig into
//! the sibling guardians' workflow. `guardian-check commit --intent "<msg>"
//! [dir]` runs the full `all` gate; on green it stages the working-tree change
//! set and commits it with the intent as the subject. On red it prints the
//! violations and leaves git untouched.
//!
//! Staging is safety-railed (modelled on guardian-sveltekit/src/commit.ts):
//! never `git add -A` / `.`; the path list comes from `git status --porcelain`
//! (modified + untracked); *untracked* secret/build-artifact paths are skipped
//! with a loud always-shown warning — never a tracked path, and never a `.zig`
//! source, so a legitimate `credentials.zig` module can't be silently dropped
//! and leave the commit desynced from the gated tree; `.guardian/` metadata and
//! SPEC.md are always included so the baseline/snapshot churn a run produced
//! rides the commit that caused it.
//!
//! Because it gates the exact working-tree diff it is about to commit,
//! change-classification's diff-timing hole is structurally closed for this
//! flow. Dispatched specially by check.zig (like nightly): its run composes
//! run_all.run, and run_all imports the registry, so a registry entry would
//! close an @import cycle. The run_all SKIP list and build_helper name it
//! defensively so it can never be treated as a gate.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const run_all = @import("run_all.zig");
const install_hook = @import("install_hook.zig");
const git = @import("../git.zig");

const Allocator = std.mem.Allocator;

/// CLI name that check.zig dispatches to this command.
pub const command_name = "commit";

/// Env var set on the `zig build test` child so its wired guardian gate no-ops
/// (see check.zig) while the tests still compile and run — the commit already
/// gated this exact tree in-process. Read by check.zig's main() short-circuit.
pub const child_skip_env = "GUARDIAN_SKIP_CHECKS";

/// Output cap for the captured child test run (a full suite's log).
const max_test_output_bytes: usize = 16 * 1024 * 1024;

/// Entry point for the commit command. Requires a non-empty `--intent`, runs
/// the full gate, and on green stages + commits the eligible change set. On a
/// red gate (or a missing intent) it returns error.CheckFailed with git
/// untouched.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const intent = validIntent(ctx.intent) orelse {
        reporter.fail("commit: --intent \"<message>\" is required (missing or empty)", .{});
        return error.CheckFailed;
    };

    // commit always BLOCKS, regardless of [gate] on_build: nothing enters
    // history unverified even when a dev build only reports.
    ctx.gate = true;
    // commit is a metadata-writable run: it persists the baseline/ratchet/
    // snapshot prune/create/re-key that ordinary runs defer, so the `.guardian/`
    // change the gate produced rides the commit that caused it (the same diff
    // the old always-writing auto-path staged).
    ctx.metadata_writable = true;

    // Gate the exact working tree we're about to commit. On red the check output
    // was already printed by run_all; git state is left untouched.
    run_all.run(ctx) catch |e| switch (e) {
        error.CheckFailed => {
            reporter.fail("commit: gate failed — nothing committed", .{});
            return error.CheckFailed;
        },
        else => return e,
    };

    // The static gate is green; the project's own tests must also pass before
    // anything enters history.
    try runTests(ctx);

    // A raw `git commit` must not be able to bypass the gate now that a dev
    // build only reports, so ensure a blocking pre-commit hook exists (best
    // effort; a hook problem never blocks a commit whose gate + tests passed).
    if (ctx.cfg.gate.install_hook) install_hook.ensure(ctx);

    return stageAndCommit(ctx, intent);
}

/// Runs the configured test suite (`[gate] test_command`, default `zig build
/// test`) before committing. The child build runs with `child_skip_env` set so
/// its own wired guardian gate no-ops while the real tests still compile and run
/// (the commit already gated this tree in-process). A non-zero exit prints the
/// captured output and hard-fails with nothing committed.
fn runTests(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    const argv = try splitCommand(a, ctx.cfg.gate.test_command);
    if (argv.len == 0) {
        reporter.fail("commit: [gate] test_command is empty — nothing to run", .{});
        return error.CheckFailed;
    }
    reporter.ok("commit: running tests (`{s}`) before committing ...", .{ctx.cfg.gate.test_command});
    const outcome = spawnTests(a, ctx.project_dir, argv) catch |e| {
        reporter.fail("commit: could not run tests ({s}) — nothing committed", .{@errorName(e)});
        return error.CheckFailed;
    };
    if (!outcome.passed) {
        reporter.fail("commit: tests failed — nothing committed", .{});
        reporter.detail("{s}\n", .{outcome.output});
        return error.CheckFailed;
    }
    reporter.ok("commit: tests passed", .{});
}

/// Splits a `test_command` string into an argv vector on ASCII whitespace
/// (`zig build test` → {zig, build, test}). Pure, so the split is tested without
/// spawning a build. No shell semantics — the argv runs directly.
fn splitCommand(a: Allocator, cmd: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    while (it.next()) |tok| try list.append(a, tok);
    return list.toOwnedSlice(a);
}

/// Result of the child test run: whether it exited 0, and its captured output
/// (stderr preferred — where a Zig test failure report lands — else stdout).
const TestOutcome = struct { passed: bool, output: []const u8 };

/// Spawns `argv` in `project_dir` with `child_skip_env` set, capturing output.
fn spawnTests(a: Allocator, project_dir: []const u8, argv: []const []const u8) !TestOutcome {
    var env = try std.process.getEnvMap(a);
    try env.put(child_skip_env, "1");
    const res = try std.process.Child.run(.{
        .allocator = a,
        .argv = argv,
        .cwd = project_dir,
        .env_map = &env,
        .max_output_bytes = max_test_output_bytes,
    });
    const passed = res.term == .Exited and res.term.Exited == 0;
    const output = if (res.stderr.len > 0) res.stderr else res.stdout;
    return .{ .passed = passed, .output = output };
}

/// Trims `intent`; null when absent or blank — so a missing/empty `--intent`
/// is a clean error with no side effects.
fn validIntent(intent: ?[]const u8) ?[]const u8 {
    const s = intent orelse return null;
    const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// Stages the eligible change set (skipping/reporting forbidden paths) and
/// commits it with `intent`. A green gate with an empty stage set is a no-op.
fn stageAndCommit(ctx: *types.RunCtx, intent: []const u8) types.RunError!void {
    const a = ctx.allocator;
    const changed = (try git.changedPaths(a, ctx.project_dir)) orelse {
        reporter.fail("commit: `git status` failed — not a git repo, or git unavailable", .{});
        return error.CheckFailed;
    };
    // Resolved here, not inside the planner, so the staging rails stay pure over
    // their inputs and unit-testable without touching git.
    const hook_path = install_hook.relativeHookPath(a, ctx.project_dir);
    const plan = try planStaging(a, changed, ctx.cfg.spec_file, hook_path);

    warnSkipped(plan.skipped);
    if (plan.stage.len == 0) {
        reporter.ok("commit: nothing to commit", .{});
        return;
    }
    if (!try git.addPaths(a, ctx.project_dir, plan.stage)) {
        reporter.fail("commit: `git add` failed — nothing committed", .{});
        return error.CheckFailed;
    }
    if (!git.commit(a, ctx.project_dir, intent)) {
        reporter.fail("commit: `git commit` failed", .{});
        return error.CheckFailed;
    }
    const hash = git.headHash(a, ctx.project_dir) orelse "(unknown)";
    reporter.ok("commit: {s} — \"{s}\" ({d} path(s) staged)", .{ hash, intent, plan.stage.len });
}

/// Prints the loud skip warning through the reporter's failure channel, which
/// is shown even in quiet mode — a silently dropped path leaves the commit not
/// matching the tree the gate just verified, and that must never go unnoticed.
/// The commit itself still proceeds; only the listed paths are left out.
fn warnSkipped(skipped: []const []const u8) void {
    if (skipped.len == 0) return;
    reporter.fail("commit: WARNING — {d} untracked secret-like/build path(s) skipped, NOT committed:", .{skipped.len});
    for (skipped) |p| reporter.detail("  skipped: {s}\n", .{p});
    reporter.detail("  fix: gitignore it, rename it, or `git add` it yourself to include it\n", .{});
}

/// The staging split: paths to stage vs the forbidden paths that were skipped.
const StagePlan = struct {
    stage: []const []const u8,
    skipped: []const []const u8,
};

/// Partitions `changed` into the stage set and the skipped-forbidden set. Pure
/// over its inputs so the rails are unit-tested without touching git.
fn planStaging(
    a: Allocator,
    changed: []const git.ChangedPath,
    spec_file: []const u8,
    hook_path: ?[]const u8,
) Allocator.Error!StagePlan {
    var stage: std.ArrayList([]const u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (changed) |c| {
        switch (stagingDecision(c, spec_file, hook_path)) {
            .stage => try stage.append(a, c.path),
            .skip_forbidden => try skipped.append(a, c.path),
            .skip_generated => {},
        }
    }
    return .{ .stage = try stage.toOwnedSlice(a), .skipped = try skipped.toOwnedSlice(a) };
}

/// What to do with one changed path. `skip_generated` is warning-free — see
/// `stagingDecision` for why that one silent drop is safe.
const StageAction = enum { stage, skip_forbidden, skip_generated };

/// Per-path staging decision: the always-include set (guardian metadata + the
/// spec file) wins; the filters apply only to untracked paths — a tracked path
/// was deliberately added to the repo, and skipping its change would desync the
/// commit from the gated tree; the default is staging.
///
/// The hook check comes first and is the one drop that is *not* warned about:
/// `run` had `install_hook.ensure` write that exact file moments earlier, so
/// warning would fire on every single commit. Silence is safe here in a way it
/// is not for a forbidden path — the hook is Guardian's own machine-local
/// output (it embeds an absolute binary path, so it must never enter history),
/// it is never gated source, and dropping it cannot desync the commit from the
/// tree the gate verified.
fn stagingDecision(c: git.ChangedPath, spec_file: []const u8, hook_path: ?[]const u8) StageAction {
    // Guardian's own operational cache is git-ignored, digest-excluded state that
    // must never enter history — checked BEFORE alwaysInclude, which otherwise
    // carries everything under `.guardian/` wholesale. Silent, like the hook: it
    // is never tracked source and dropping it can't desync the gated tree.
    if (isGuardianCache(c.path)) return .skip_generated;
    if (alwaysInclude(c.path, spec_file)) return .stage;
    if (!c.tracked and isGeneratedHook(c.path, hook_path)) return .skip_generated;
    if (!c.tracked and isForbidden(c.path)) return .skip_forbidden;
    return .stage;
}

/// True when `path` is guardian's operational cache tree — the git-ignored,
/// digest-excluded `.guardian/cache/` (inputs.sha256, last-run.jsonl, …). It is
/// the one cache-pattern hole sitting under an always-include prefix; the
/// zig-out / .zig-cache rail (`isBuildArtifactPath`) never sees it because its
/// first path segment is `.guardian`.
fn isGuardianCache(path: []const u8) bool {
    return underDir(path, ".guardian/cache");
}

/// True when `path` is the pre-commit hook Guardian manages for this project.
/// `hook_path` is null when git couldn't resolve a hooks dir inside the project,
/// in which case there is nothing to exclude.
fn isGeneratedHook(path: []const u8, hook_path: ?[]const u8) bool {
    const hook = hook_path orelse return false;
    return std.mem.eql(u8, path, hook);
}

/// True for paths always carried by the commit: `.guardian/` metadata (so
/// baseline/snapshot churn rides the commit that caused it) and the spec file.
fn alwaysInclude(path: []const u8, spec_file: []const u8) bool {
    if (underDir(path, ".guardian")) return true;
    if (std.mem.eql(u8, path, spec_file)) return true;
    return false;
}

/// True for an untracked path that looks like a secret or build artifact and
/// must not be silently staged — the safety rail against committing a
/// credential the project's .gitignore missed. Name matching ignores letter
/// case: a capitalized Credentials.json is as much a secret as a lowercase
/// one. The fuzzy name heuristic (`credentials`/`secret` substrings) never
/// fires on a `.zig` source: the gate just compiled and tested it, and a
/// credentials.zig store module is code, not a secret. Mirrors
/// guardian-sveltekit's forbidden list, Zig-flavored.
fn isForbidden(path: []const u8) bool {
    const base = baseName(path);
    if (isBuildArtifactPath(path)) return true;
    if (isSessionStatePath(path)) return true;
    if (std.ascii.eqlIgnoreCase(base, ".env") or std.ascii.startsWithIgnoreCase(base, ".env.")) return true;
    if (std.ascii.startsWithIgnoreCase(base, "id_rsa")) return true;
    if (endsWithAny(base, &.{ ".pem", ".key", ".p12" })) return true;
    if (std.ascii.endsWithIgnoreCase(base, ".zig")) return false;
    if (containsAny(path, &.{ "credentials", "secret" })) return true;
    return false;
}

/// True when `path` sits inside the directory `dir` (`<dir>/…`).
fn underDir(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
}

/// True when `path`'s first segment is a Zig build-output directory. Matches
/// `zig-out/`, `.zig-cache/`, and — critically — the *suffixed* isolated caches
/// the mutation runner creates (`.zig-cache-c/`, `.zig-cache-rfaudit/`, …). The
/// old exact-`.zig-cache` boundary missed those suffixed names, so three
/// separate reports had them swept into a commit (441 binary blobs in one).
fn isBuildArtifactPath(path: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    const seg = path[0..slash];
    return std.mem.eql(u8, seg, "zig-out") or
        std.mem.startsWith(u8, seg, ".zig-cache") or
        std.mem.startsWith(u8, seg, "zig-cache");
}

/// True when `path`'s first segment is a coding-agent session-state directory.
/// These hold another tool's per-session scratch (worktree registries, local
/// settings, transcripts), not project source: one commit swept a stray
/// `.codex/worktrees/…` entry in alongside real code. Untracked only, so a
/// project that deliberately tracks `.claude/settings.json` is unaffected, and
/// the skip warning tells the author how to include it on purpose.
fn isSessionStatePath(path: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return false;
    const seg = path[0..slash];
    return std.mem.eql(u8, seg, ".codex") or std.mem.eql(u8, seg, ".claude");
}

/// The final path segment after the last `/` (the whole string if none).
fn baseName(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

/// True when `s` ends with any of `suffixes`, ignoring letter case.
fn endsWithAny(s: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suf| if (std.ascii.endsWithIgnoreCase(s, suf)) return true;
    return false;
}

/// True when `s` contains any of `needles`, ignoring letter case.
fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.ascii.indexOfIgnoreCase(s, n) != null) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Commit - Requires a non-empty intent message

test "validIntent rejects null and blank, trims otherwise" {
    try testing.expect(validIntent(null) == null);
    try testing.expect(validIntent("") == null);
    try testing.expect(validIntent("   ") == null);
    try testing.expectEqualStrings("fix bug", validIntent("  fix bug  ").?);
}

/// Test shorthand for an untracked porcelain entry (`??`).
fn untracked(path: []const u8) git.ChangedPath {
    return .{ .path = path, .tracked = false };
}

/// Test shorthand for a tracked porcelain entry (anything but `??`).
fn tracked(path: []const u8) git.ChangedPath {
    return .{ .path = path, .tracked = true };
}

// spec: Commit - Splits the configured test command into an argv vector

test "splitCommand tokenizes the configured test command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try splitCommand(a, "zig build test");
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("zig", argv[0]);
    try testing.expectEqualStrings("build", argv[1]);
    try testing.expectEqualStrings("test", argv[2]);
    // Extra whitespace collapses; a blank command yields an empty argv.
    const spaced = try splitCommand(a, "  zig   build\ttest  ");
    try testing.expectEqual(@as(usize, 3), spaced.len);
    try testing.expectEqual(@as(usize, 0), (try splitCommand(a, "   ")).len);
}

// spec: Commit - Excludes suffixed zig build cache directories from staging

test "planStaging skips suffixed zig cache dirs the exact-prefix rail missed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The mutation runner's isolated caches (.zig-cache-c, .zig-cache-rfaudit)
    // and zig-out are all build artifacts, never committed — only real source is.
    const changed = [_]git.ChangedPath{
        untracked(".zig-cache-c/o/deadbeef/app.o"),
        untracked(".zig-cache-rfaudit/h/xyz.bin"),
        untracked("zig-out/bin/app"),
        untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 3), plan.skipped.len);
}

// spec: Commit - Excludes untracked agent session-state directories from staging

test "planStaging skips agent session dirs but stages a tracked one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        // The exact entry a real commit swept in, plus its sibling agent dir.
        untracked(".codex/worktrees/embed-cache-integrity"),
        untracked(".claude/settings.local.json"),
        // A project that deliberately tracks its agent config keeps it: the
        // rail only ever drops UNtracked paths.
        tracked(".claude/settings.json"),
        untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 2), plan.stage.len);
    try testing.expectEqualStrings(".claude/settings.json", plan.stage[0]);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[1]);
    // Both untracked session paths are reported, never silently dropped.
    try testing.expectEqual(@as(usize, 2), plan.skipped.len);
    // A same-named file outside a session dir is ordinary source, not scratch.
    try testing.expect(!isSessionStatePath("src/.codex/x"));
    try testing.expect(!isSessionStatePath(".codexrc/x"));
}

// spec: Commit - Excludes its own generated pre-commit hook from staging

test "planStaging drops the managed hook silently and warns for everything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        // ensure() wrote this moments earlier; it embeds a machine-specific
        // absolute binary path, so it must never enter history.
        untracked(".githooks/pre-commit"),
        untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", ".githooks/pre-commit");
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    // Silent: warning on the file guardian itself writes would fire every commit.
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
    // A tracked hook is the author's deliberate choice — dropping it would
    // desync the commit from the gated tree, so the rail leaves it alone.
    const tracked_hook = [_]git.ChangedPath{tracked(".githooks/pre-commit")};
    const kept = try planStaging(a, &tracked_hook, "SPEC.md", ".githooks/pre-commit");
    try testing.expectEqual(@as(usize, 1), kept.stage.len);
    // With no resolvable hook path there is nothing to exclude.
    try testing.expect(!isGeneratedHook(".githooks/pre-commit", null));
    // Only the exact hook file is dropped, not its neighbors in the same dir.
    try testing.expect(!isGeneratedHook(".githooks/post-checkout", ".githooks/pre-commit"));
}

// spec: Commit - Excludes untracked secret and build-artifact paths from staging

test "planStaging skips untracked secrets and build artifacts, keeps ordinary source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        untracked(".env"),                 untracked("config/.env.local"),
        untracked("certs/server.pem"),     untracked("deploy/id_rsa"),
        untracked("aws_credentials.json"), untracked("zig-out/bin/app"),
        untracked(".zig-cache/x.o"),       untracked("src/keep.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    // Only the ordinary source file is staged; the seven risky paths are skipped.
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/keep.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 7), plan.skipped.len);
}

// spec: Commit - Never skips an already-tracked path

test "planStaging stages every tracked path even with a secret-like name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Tracked paths were deliberately added to the repo; skipping their changes
    // would produce a commit that doesn't match the tree the gate verified.
    const changed = [_]git.ChangedPath{
        tracked("src/server/store/credentials.zig"),
        tracked("certs/server.pem"),
        tracked(".env"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 3), plan.stage.len);
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
}

// spec: Commit - Never skips a Zig source file for a secret-like name

test "planStaging keeps an untracked credentials.zig but skips credentials.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The fuzzy name heuristic must not eat source modules the gate just
    // compiled and tested — only data-shaped files stay behind the rail.
    const changed = [_]git.ChangedPath{
        untracked("src/server/store/credentials.zig"),
        untracked("src/auth/secret_box.zig"),
        untracked("credentials.json"),
        untracked("notes/secret-plan.md"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 2), plan.stage.len);
    try testing.expectEqualStrings("src/server/store/credentials.zig", plan.stage[0]);
    try testing.expectEqualStrings("src/auth/secret_box.zig", plan.stage[1]);
    try testing.expectEqual(@as(usize, 2), plan.skipped.len);
}

// spec: Commit - Skips secret-like names regardless of letter case

test "planStaging skips capitalized secret names like Credentials.json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The forbidden filter compares names case-insensitively: a capitalized
    // Credentials.json is as much a secret as a lowercase one, and the .zig
    // source exemption holds for a capitalized module name too.
    const changed = [_]git.ChangedPath{
        untracked("Credentials.json"), untracked("notes/Secret.txt"),
        untracked(".ENV"),             untracked("certs/Server.PEM"),
        untracked("deploy/ID_RSA"),    untracked("src/Credentials.zig"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings("src/Credentials.zig", plan.stage[0]);
    try testing.expectEqual(@as(usize, 5), plan.skipped.len);
}

// spec: Commit - Warns loudly listing every skipped path

test "warnSkipped names every skipped path and stays silent on none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cap: reporter.Capture = .{ .allocator = arena.allocator() };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    warnSkipped(&.{ "credentials.json", ".env" });
    // The header goes through the failure channel (shown even in quiet mode)
    // and every skipped path is listed by name.
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "WARNING") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "credentials.json") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, ".env") != null);

    cap.buf.clearRetainingCapacity();
    warnSkipped(&.{});
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

// spec: Commit - Always stages guardian metadata and the spec file

test "planStaging always includes guardian and spec even against the forbidden filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{
        untracked(".guardian/baselines/spec.txt"), tracked("SPEC.md"),
        tracked("src/x.zig"), untracked(".guardian/secret-notes.txt"), // 'secret' but under .guardian → still staged
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 4), plan.stage.len);
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
}

// spec: Commit - Never stages the git-ignored guardian cache directory

test "planStaging skips the guardian cache tree while keeping real metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // .guardian/cache/ is git-ignored operational state (a swept-in cache dir is
    // the 4.5 bug); it must be dropped silently even though it sits under the
    // always-include `.guardian/` prefix — while a real baseline still stages.
    const changed = [_]git.ChangedPath{
        untracked(".guardian/cache/inputs.sha256"),
        untracked(".guardian/cache/last-run.jsonl"),
        untracked(".guardian/baselines/spec.txt"),
    };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 1), plan.stage.len);
    try testing.expectEqualStrings(".guardian/baselines/spec.txt", plan.stage[0]);
    // Silent drop (git-ignored guardian output), so no skip warning fires.
    try testing.expectEqual(@as(usize, 0), plan.skipped.len);
    // A file literally named "cache" one level up is ordinary source, not the tree.
    try testing.expect(!isGuardianCache(".guardian/cache-notes.txt"));
    try testing.expect(isGuardianCache(".guardian/cache/x"));
}

// spec: Commit - Reports nothing to commit when no eligible paths remain

test "planStaging yields an empty stage set when every change is forbidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = [_]git.ChangedPath{ untracked(".env"), untracked("zig-out/bin/app") };
    const plan = try planStaging(a, &changed, "SPEC.md", null);
    try testing.expectEqual(@as(usize, 0), plan.stage.len);
    try testing.expectEqual(@as(usize, 2), plan.skipped.len);
}
