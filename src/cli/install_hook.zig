//! `install-hook` command — writes `.git/hooks/pre-commit` running the blocking
//! gate, so a raw `git commit` can't bypass Guardian now that a dev build only
//! reports. Binary resolution inside the hook is layered ($GUARDIAN_CHECK →
//! ./zig-out/bin/guardian-check → guardian-check on PATH → the installing
//! binary's baked absolute path → fail with guidance), because a consumer repo
//! often has guardian-check neither in zig-out nor on PATH. It never clobbers a
//! foreign pre-commit hook: an existing hook without Guardian's marker line
//! prints instructions instead of being overwritten. `commit` calls `ensure` to
//! auto-install best-effort. Dispatched specially by check.zig (never a gate), so
//! it may import the registry-adjacent modules without forming a cycle.

const std = @import("std");
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const git = @import("../git.zig");

const Allocator = std.mem.Allocator;

/// CLI name check.zig dispatches to this command.
pub const command_name = "install-hook";

/// Upper bound on an existing pre-commit hook we read to detect the marker.
const max_hook_bytes = 64 * 1024;
/// Executable mode for the written hook (owner rwx, group/other rx).
const hook_mode = 0o755;

/// Marker line identifying a Guardian-managed hook. Its presence authorizes an
/// overwrite (refresh); its absence protects a hand-written hook.
const marker = "# guardian-check managed pre-commit hook";

/// The hook file's name within the resolved hooks directory.
const hook_basename = "pre-commit";

/// The pre-commit hook body template. Shebang first, then the marker, then a
/// layered binary resolution and the blocking gate. `{s}` is the absolute path
/// of the binary that installed (or last refreshed) the hook — needed because a
/// consumer repo often has guardian-check neither in zig-out nor on PATH.
/// `exec` makes the gate's exit status the hook's, so a red gate aborts the
/// commit.
///
/// Resolution order is layered by *intent*: an explicit $GUARDIAN_CHECK always
/// wins, then a repo-local build, then PATH, then the baked path. The one
/// departure: when a local build AND the baked path both exist, the NEWER of
/// the two runs. A repo-local `zig-out` binary can be months old (ward and
/// wardd-deploy were judging with a 5-day-old 65-check build), and a gate
/// verdict from stale check semantics is worse than useless — it reads as a
/// pass. Picking the newer one is announced on stderr, never silent.
const hook_script_fmt =
    \\#!/bin/sh
    \\# guardian-check managed pre-commit hook
    \\baked="{s}"
    \\local_bin=./zig-out/bin/guardian-check
    \\if [ -n "$GUARDIAN_CHECK" ]; then
    \\  bin="$GUARDIAN_CHECK"
    \\elif [ -x "$local_bin" ] && [ -n "$baked" ] && [ -x "$baked" ]; then
    \\  if [ "$baked" -nt "$local_bin" ]; then
    \\    echo "guardian: $local_bin is older than $baked — gating with the newer binary" >&2
    \\    echo "guardian: rebuild ($local_bin) to gate with this repo's own build" >&2
    \\    bin="$baked"
    \\  else
    \\    bin="$local_bin"
    \\  fi
    \\elif [ -x "$local_bin" ]; then
    \\  bin="$local_bin"
    \\elif command -v guardian-check >/dev/null 2>&1; then
    \\  bin=guardian-check
    \\elif [ -n "$baked" ] && [ -x "$baked" ]; then
    \\  bin="$baked"
    \\else
    \\  echo "guardian: guardian-check not found — build it (zig build) or set GUARDIAN_CHECK" >&2
    \\  exit 1
    \\fi
    \\exec "$bin" all . --gate
    \\
;

/// Renders the hook script, baking this binary's absolute path in. An
/// unresolvable self path bakes an empty string, which every `baked` branch
/// guards with `-n`, degrading cleanly to the pre-baking behavior.
fn renderScript(allocator: Allocator) Allocator.Error![]const u8 {
    const self_path = std.fs.selfExePathAlloc(allocator) catch "";
    // The unresolved fallback is a comptime literal, not an allocation.
    defer if (self_path.len != 0) allocator.free(self_path);
    return std.fmt.allocPrint(allocator, hook_script_fmt, .{self_path});
}

/// What `installInto` did (or couldn't). `run` maps these to exit status;
/// `ensure` treats everything but a fresh install as a quiet no-op.
const Outcome = enum { installed, refreshed, foreign, unavailable, io_error };

/// CLI entry: install (or refresh) the blocking pre-commit hook for the project.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    switch (installInto(ctx.allocator, ctx.project_dir)) {
        .installed => reporter.ok("install-hook: wrote .git/hooks/pre-commit (blocking gate)", .{}),
        .refreshed => reporter.ok("install-hook: refreshed the guardian pre-commit hook", .{}),
        .foreign => {
            reporter.fail("install-hook: a non-guardian pre-commit hook already exists — not overwriting", .{});
            reporter.detail("  add `guardian-check all . --gate` to it, or remove it and re-run install-hook\n", .{});
            return error.CheckFailed;
        },
        .unavailable => {
            reporter.fail("install-hook: could not locate the git hooks directory (not a git repository?)", .{});
            return error.CheckFailed;
        },
        .io_error => {
            reporter.fail("install-hook: could not write the pre-commit hook", .{});
            return error.CheckFailed;
        },
    }
}

/// Best-effort auto-install used by `commit`: writes/refreshes the guardian hook
/// but never fails the commit — a foreign or unwritable hook is only noted, since
/// the commit's own gate + tests already passed.
pub fn ensure(ctx: *types.RunCtx) void {
    switch (installInto(ctx.allocator, ctx.project_dir)) {
        .installed => reporter.ok("commit: installed the guardian pre-commit hook", .{}),
        .foreign => reporter.ok("commit: left the existing non-guardian pre-commit hook in place", .{}),
        else => {},
    }
}

/// Resolves the hooks dir, inspects any existing pre-commit hook, and writes the
/// guardian hook unless a foreign one is present. Returns the Outcome.
fn installInto(allocator: Allocator, project_dir: []const u8) Outcome {
    const hooks = git.hooksDir(allocator, project_dir) orelse return .unavailable;
    const path = hookPath(allocator, project_dir, hooks) catch return .io_error;
    const script = renderScript(allocator) catch return .io_error;
    switch (decide(readExisting(allocator, path))) {
        .foreign => return .foreign,
        .write_new => return if (writeHook(path, script)) .installed else |_| .io_error,
        .write_refresh => return if (writeHook(path, script)) .refreshed else |_| .io_error,
    }
}

/// The write decision for an existing (or absent) pre-commit hook.
const Decision = enum { write_new, write_refresh, foreign };

/// Pure decision: no hook → write new; a guardian-marked hook → refresh; any
/// other existing hook → foreign (protected, never overwritten).
fn decide(existing: ?[]const u8) Decision {
    const content = existing orelse return .write_new;
    return if (hasMarker(content)) .write_refresh else .foreign;
}

/// True when `content` carries Guardian's hook marker line.
fn hasMarker(content: []const u8) bool {
    return std.mem.indexOf(u8, content, marker) != null;
}

/// Joins the pre-commit hook path: `hooks` as-is when absolute, else resolved
/// under `project_dir` (git returns a project-relative path from within it).
fn hookPath(allocator: Allocator, project_dir: []const u8, hooks: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(hooks)) return std.fs.path.join(allocator, &.{ hooks, hook_basename });
    return std.fs.path.join(allocator, &.{ project_dir, hooks, hook_basename });
}

/// The hook file's path *relative to the project root*, in the same shape git
/// porcelain reports (`.githooks/pre-commit`) — so `commit` can keep the file it
/// just wrote out of the change set it stages. Null when git can't resolve the
/// hooks dir or that dir sits outside the project (a hooks dir shared across
/// repos, e.g. ward + wardd-deploy: nothing project-relative to exclude, and
/// nothing inside the project for porcelain to report either).
pub fn relativeHookPath(allocator: Allocator, project_dir: []const u8) ?[]const u8 {
    const hooks = git.hooksDir(allocator, project_dir) orelse return null;
    // A relative hooks dir is already project-relative (`.git/hooks`, which
    // porcelain never reports anyway — the exclusion is simply inert there).
    if (!std.fs.path.isAbsolute(hooks)) {
        return std.fs.path.join(allocator, &.{ hooks, hook_basename }) catch null;
    }
    const root = std.fs.cwd().realpathAlloc(allocator, project_dir) catch return null;
    const rel_dir = relativeTo(root, hooks) orelse return null;
    return std.fs.path.join(allocator, &.{ rel_dir, hook_basename }) catch null;
}

/// `path` expressed relative to `root`, or null when it isn't strictly inside
/// `root`. The separator check keeps a sibling prefix (`/repo-backup` under
/// `/repo`) from reading as a child.
fn relativeTo(root: []const u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, root)) return null;
    const rest = path[root.len..];
    if (rest.len < 2 or rest[0] != std.fs.path.sep) return null;
    return rest[1..];
}

/// Existing hook bytes, or null when the file is absent/unreadable.
fn readExisting(allocator: Allocator, path: []const u8) ?[]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_hook_bytes) catch null;
}

/// Writes the executable hook script, creating the hooks directory if needed.
fn writeHook(path: []const u8, script: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const f = try std.fs.cwd().createFile(path, .{ .mode = hook_mode });
    defer f.close();
    try f.writeAll(script);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Install Hook - Writes a pre-commit hook that runs the blocking gate

test "hook script resolves a binary and runs the blocking gate" {
    // The script is self-marked (so a refresh recognizes its own prior write).
    try testing.expect(hasMarker(hook_script_fmt));
    // It invokes the blocking gate, not a plain report run.
    try testing.expect(std.mem.indexOf(u8, hook_script_fmt, "all . --gate") != null);
    // Layered binary resolution: env override, local build output, then PATH.
    try testing.expect(std.mem.indexOf(u8, hook_script_fmt, "$GUARDIAN_CHECK") != null);
    try testing.expect(std.mem.indexOf(u8, hook_script_fmt, "./zig-out/bin/guardian-check") != null);
    try testing.expect(std.mem.indexOf(u8, hook_script_fmt, "command -v guardian-check") != null);
    // `ensure` stays part of the auto-install surface commit relies on.
    _ = &ensure;
}

// spec: Install Hook - Gates with the newer of a local build and the baked binary

test "hook prefers the newer binary and says so, with the env override winning" {
    // The staleness comparison exists and is announced, not silent: a verdict
    // from a months-old local build reads as a pass and must be recognizable.
    try testing.expect(std.mem.indexOf(u8, hook_script_fmt, "-nt") != null);
    try testing.expect(std.mem.indexOf(u8, hook_script_fmt, "is older than") != null);
    // An explicit override still wins outright — it is checked before any
    // staleness comparison runs.
    const env_at = std.mem.indexOf(u8, hook_script_fmt, "$GUARDIAN_CHECK").?;
    try testing.expect(env_at < std.mem.indexOf(u8, hook_script_fmt, "-nt").?);
    // Every use of the baked path is `-n`-guarded, so an unresolvable self
    // path (empty bake) degrades to the pre-baking layering instead of
    // testing `-x ""` and falling through to a spurious not-found error.
    var it = std.mem.splitScalar(u8, hook_script_fmt, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "-x \"$baked\"") == null) continue;
        try testing.expect(std.mem.indexOf(u8, line, "-n \"$baked\"") != null);
    }
}

// spec: Install Hook - Bakes the installing binary as the hook's last-resort fallback

test "rendered hook bakes the installer's own absolute path" {
    const rendered = try renderScript(testing.allocator);
    defer testing.allocator.free(rendered);
    // The rendered script still carries the marker and the blocking gate.
    try testing.expect(hasMarker(rendered));
    try testing.expect(std.mem.indexOf(u8, rendered, "all . --gate") != null);
    // The `{s}` placeholders are gone: the self path (absolute in a test
    // binary) was substituted into the last-resort `-x` branch.
    try testing.expect(std.mem.indexOf(u8, rendered, "{s}") == null);
    const self_path = try std.fs.selfExePathAlloc(testing.allocator);
    defer testing.allocator.free(self_path);
    try testing.expect(std.mem.indexOf(u8, rendered, self_path) != null);
}

// spec: Install Hook - Resolves the hook path relative to the project root

test "relativeTo yields a project-relative hooks dir and rejects outsiders" {
    // The custom core.hooksPath case: an absolute dir inside the project
    // becomes the porcelain-shaped path `commit` compares against.
    try testing.expectEqualStrings(".githooks", relativeTo("/repo", "/repo/.githooks").?);
    try testing.expectEqualStrings("a/b", relativeTo("/repo", "/repo/a/b").?);
    // A hooks dir shared across repos (ward + wardd-deploy) is outside this
    // project: nothing project-relative to exclude.
    try testing.expect(relativeTo("/repo", "/elsewhere/.githooks") == null);
    // A sibling whose name merely starts with the root is not a child.
    try testing.expect(relativeTo("/repo", "/repo-backup/.githooks") == null);
    // The root itself has no relative remainder.
    try testing.expect(relativeTo("/repo", "/repo") == null);
    // relativeHookPath is the surface commit calls to keep the hook unstaged.
    _ = &relativeHookPath;
}

// spec: Install Hook - Refuses to overwrite a foreign pre-commit hook

test "decide protects a foreign hook and refreshes a guardian one" {
    // No hook yet: write a fresh one.
    try testing.expect(decide(null) == .write_new);
    // A hand-written hook (no marker) is protected, never clobbered.
    try testing.expect(decide("#!/bin/sh\nnpm test\n") == .foreign);
    // A previously-installed guardian hook is refreshed in place.
    try testing.expect(decide(hook_script_fmt) == .write_refresh);
}
