//! `install-merge-driver` — teaches this repository's git to resolve
//! `.guardian/` conflicts with `guardian-check merge-file`.
//!
//! Two halves, both LOCAL to the clone and both idempotent:
//!
//!   * `.git/info/attributes` gains `.guardian/** merge=guardian`. Deliberately
//!     NOT the tracked `.gitattributes`: a consumer should not have to commit a
//!     file (and re-review it) to get a local merge convenience, and a tracked
//!     attribute pointing at a driver that is not configured would silently do
//!     nothing on everybody else's clone.
//!   * `git config merge.guardian.name/driver` names the command: a small shell
//!     snippet that resolves guardian-check the way the pre-commit hook does and
//!     hands it `%O %A %B %P` — git's own placeholder order (base, ours,
//!     theirs, pathname), with the result written back to `%A`.
//!
//! `install-hook` calls `ensure` so the two arrive together; `doctor` calls
//! `isInstalled` to report whether they did.

const std = @import("std");
const fs = @import("../fs.zig");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const reporter = @import("../reporter.zig");
const git = @import("../git.zig");
const merge_file = @import("merge_file.zig");

/// CLI name check.zig dispatches to this command.
pub const command_name = "install-merge-driver";

/// Upper bound on an existing attributes file we read before extending it.
const max_attributes_bytes = 256 * 1024;

/// git config keys naming the driver.
const name_key = "merge.guardian.name";
const driver_key = "merge.guardian.driver";

/// Human-readable driver name shown in git's own messages.
const driver_name = "guardian .guardian metadata merge";

/// Marker line that identifies Guardian's block inside `.git/info/attributes`,
/// so a re-run extends nothing and a hand-written attributes file is preserved.
const marker = "# guardian-check managed merge attributes";

/// The attributes block. Both patterns say the same thing — the explicit
/// pub-api line documents the file most likely to conflict, and re-stating a
/// covered path is harmless (git applies the last matching rule).
const attributes_block = marker ++
    "\n.guardian/** merge=guardian\n.guardian/pub-api.txt merge=guardian\n";

/// What `installInto` did, in the order `run` reports them.
const Outcome = enum { installed, already_present, no_repo, io_error, config_failed };

/// CLI entry: install (or confirm) the local merge driver for this repository.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    switch (try installInto(ctx.allocator, ctx.project_dir)) {
        .installed => reporter.ok(
            "install-merge-driver: .guardian/** now merges with `guardian-check {s}`",
            .{merge_file.command_name},
        ),
        .already_present => reporter.ok("install-merge-driver: already installed", .{}),
        .no_repo => {
            reporter.fail("install-merge-driver: could not locate .git (not a git repository?)", .{});
            return error.CheckFailed;
        },
        .io_error => {
            reporter.fail("install-merge-driver: could not write .git/info/attributes", .{});
            return error.CheckFailed;
        },
        .config_failed => {
            reporter.fail("install-merge-driver: `git config {s}` failed", .{driver_key});
            return error.CheckFailed;
        },
    }
}

/// Best-effort install used by `install-hook`/`commit`: a repository that
/// already has the driver, or cannot take it, is a silent no-op — the driver is
/// a merge convenience and must never fail a commit.
pub fn ensure(ctx: *types.RunCtx) void {
    const outcome = installInto(ctx.allocator, ctx.project_dir) catch return;
    if (outcome != .installed) return;
    reporter.ok("install-merge-driver: .guardian/** conflicts now resolve automatically", .{});
}

/// True when both halves are in place: the driver command is configured and the
/// attributes file routes `.guardian` at it. Read-only — `doctor` reports it.
pub fn isInstalled(allocator: Allocator, project_dir: []const u8) bool {
    if (git.configValue(allocator, project_dir, driver_key) == null) return false;
    const path = attributesPath(allocator, project_dir) orelse return false;
    const existing = readExisting(allocator, path) orelse return false;
    return std.mem.indexOf(u8, existing, "merge=guardian") != null;
}

/// Writes the attributes block (unless it is already there) and sets the two
/// config keys (always, so a stale driver path is refreshed in place).
fn installInto(allocator: Allocator, project_dir: []const u8) Allocator.Error!Outcome {
    const path = attributesPath(allocator, project_dir) orelse return .no_repo;
    const existing = readExisting(allocator, path) orelse "";
    const had_block = std.mem.indexOf(u8, existing, marker) != null;
    if (!had_block) {
        const merged = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            existing,
            if (endsCleanly(existing)) "" else "\n",
            attributes_block,
        });
        writeFile(path, merged) catch return .io_error;
    }
    const driver = try driverCommand(allocator);
    if (!git.setConfig(allocator, project_dir, name_key, driver_name)) return .config_failed;
    if (!git.setConfig(allocator, project_dir, driver_key, driver)) return .config_failed;
    return if (had_block) .already_present else .installed;
}

/// True when appending a line to `content` needs no separating newline.
fn endsCleanly(content: []const u8) bool {
    return content.len == 0 or content[content.len - 1] == '\n';
}

/// The driver command git runs, as a shell snippet that resolves the binary the
/// same layered way the pre-commit hook does: `$GUARDIAN_CHECK`, then a
/// repo-local build, then PATH, then the absolute path of the binary that
/// installed this. The layering is not decoration — a consumer's guardian-check
/// often runs out of `.zig-cache/o/<hash>/`, a path that changes on the next
/// rebuild, so a baked path alone would rot within a day.
///
/// The placeholders are passed as positional arguments in git's own order
/// (`%O %A %B %P` = base, ours, theirs, pathname) and the inner shell forwards
/// them positionally. Note the asymmetric quoting, verified against git 2.34:
/// the three temp files are substituted RAW (so we quote them), while `%P` is
/// substituted ALREADY single-quoted by git — quoting it again delivers a path
/// with literal `'` on both ends, which silently costs the format hint.
const driver_fmt =
    "sh -c 'if [ -n \"$GUARDIAN_CHECK\" ] && [ -x \"$GUARDIAN_CHECK\" ]; then b=\"$GUARDIAN_CHECK\"; " ++
    "elif [ -x ./zig-out/bin/guardian-check ]; then b=./zig-out/bin/guardian-check; " ++
    "elif command -v guardian-check >/dev/null 2>&1; then b=guardian-check; " ++
    "elif [ -n \"{s}\" ] && [ -x \"{s}\" ]; then b=\"{s}\"; " ++
    "else echo \"guardian: guardian-check not found — .guardian conflict left for you\" >&2; exit 1; fi; " ++
    "exec \"$b\" " ++ merge_file.command_name ++ " \"$0\" \"$1\" \"$2\" --path \"$3\"' \"%O\" \"%A\" \"%B\" %P";

/// Renders `driver_fmt` with this binary's absolute path baked into its
/// last-resort branch. An unresolvable self path bakes an empty string, which
/// every branch guards with `-n`, degrading to the three layers above it.
fn driverCommand(allocator: Allocator) Allocator.Error![]const u8 {
    const self_path = fs.selfExePathAlloc(allocator) catch "";
    return std.fmt.allocPrint(allocator, driver_fmt, .{ self_path, self_path, self_path });
}

/// `.git/info/attributes` for this working tree — resolved through git so a
/// linked worktree points at the common dir, and created lazily by the write.
fn attributesPath(allocator: Allocator, project_dir: []const u8) ?[]const u8 {
    const info = git.gitPath(allocator, project_dir, "info/attributes") orelse return null;
    if (std.fs.path.isAbsolute(info)) return info;
    return std.fs.path.join(allocator, &.{ project_dir, info }) catch null;
}

/// Existing attributes bytes, or null when the file is absent/unreadable.
fn readExisting(allocator: Allocator, path: []const u8) ?[]const u8 {
    return fs.cwd().readFileAlloc(allocator, path, max_attributes_bytes) catch null;
}

/// Writes `content`, creating the `info/` directory when git has not yet.
fn writeFile(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try fs.cwd().makePath(dir);
    try fs.cwd().writeFile(.{ .sub_path = path, .data = content });
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Merge - Routes .guardian conflicts at the driver through local git attributes

test "the attributes block is self-marked and covers the metadata tree" {
    // Self-marked, so a second install extends nothing.
    try testing.expect(std.mem.indexOf(u8, attributes_block, marker) != null);
    try testing.expect(std.mem.indexOf(u8, attributes_block, ".guardian/** merge=guardian") != null);
    // pub-api.txt is called out by name: it is the file that conflicts most.
    try testing.expect(std.mem.indexOf(u8, attributes_block, ".guardian/pub-api.txt merge=guardian") != null);
    // Appending is newline-safe whether or not the existing file ended in one.
    try testing.expect(endsCleanly(""));
    try testing.expect(endsCleanly("*.png binary\n"));
    try testing.expect(!endsCleanly("*.png binary"));
}

// spec: Merge - Configures the driver with git's own placeholder order

test "the driver command passes base, ours, theirs, and the pathname" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cmd = try driverCommand(arena.allocator());
    // The placeholders go in git's own order — %O %A %B is base, ours, theirs,
    // which is the order merge-file's positionals take, and %A is where git
    // expects the result — and the inner shell forwards them positionally.
    // %P is deliberately unquoted: git substitutes it already single-quoted.
    try testing.expect(std.mem.indexOf(u8, cmd, "\"%O\" \"%A\" \"%B\" %P") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "merge-file \"$0\" \"$1\" \"$2\" --path \"$3\"") != null);
    // Layered binary resolution, hook-style: env override, repo-local build,
    // PATH, then the installing binary's own path as a last resort — a
    // consumer's guardian-check often lives at a .zig-cache path that moves.
    try testing.expect(std.mem.indexOf(u8, cmd, "$GUARDIAN_CHECK") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "./zig-out/bin/guardian-check") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "command -v guardian-check") != null);
    const self_path = try fs.selfExePathAlloc(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, cmd, self_path) != null);
    // Every use of the baked path is `-n`-guarded, so an unresolvable self path
    // degrades to the layers above instead of testing `-x ""`.
    try testing.expectEqual(
        std.mem.count(u8, driver_fmt, "-x \"{s}\""),
        std.mem.count(u8, driver_fmt, "-n \"{s}\""),
    );
}

// spec: Merge - Reports whether the merge driver is installed

test "isInstalled requires both the config key and the attribute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A directory that is not a repository can never look installed, and the
    // probe is read-only: nothing is created by asking.
    try testing.expect(!isInstalled(arena.allocator(), "/nonexistent-guardian-project"));
    _ = &ensure;
}
