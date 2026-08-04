//! Content digest of Guardian's own source tree — the one number that decides
//! whether an already-built `guardian-check` still speaks for the source sitting
//! next to it.
//!
//! Both sides of that question import THIS file, so they cannot drift:
//! `build.zig` computes the digest at configure time and embeds it in the
//! binary, and the binary's `selfcheck` command recomputes it over a source root
//! and compares. Sharing one implementation is also why this file is std-only —
//! `build.zig` has no module graph to pull anything else through.
//!
//! Covered: `build.zig`, `build.zig.zon`, and every `.zig` file under `src/` —
//! everything whose edit can change what the binary does. `.zig-cache/`,
//! `zig-out/`, `.git/` and `.guardian/` sit outside that set by construction, so
//! a rebuild or an accepted snapshot never moves the digest. Paths are sorted
//! and length-prefixed alongside their contents, so adding, deleting, or
//! renaming a file moves the digest exactly as surely as editing one.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Hex characters in a rendered digest.
pub const hex_len = 2 * Sha256.digest_length;

/// A rendered digest: lowercase hex over the covered file set.
pub const Hex = [hex_len]u8;

/// Failure modes. Every filesystem reason the tree cannot be read (absent,
/// unreadable, oversize) collapses into one error on purpose: they all have the
/// same remedy, and a digest that "mostly" read the tree would be worse than no
/// digest at all.
pub const Error = std.mem.Allocator.Error || error{SourceRootUnreadable};

/// Domain separation plus format version. Bump it whenever the covered set or
/// the record framing changes, so a digest computed under old rules can never
/// accidentally equal one computed under new rules.
const format_tag = "guardian-source-v1";

/// The directory walked recursively for source files.
const source_dir = "src";

/// Extension of the files that get compiled into the binary.
const source_ext = ".zig";

/// Covered files outside `src/`: the build graph and the manifest, both of which
/// change what a build produces without any `src/` file changing.
const root_files = [_][]const u8{ "build.zig", "build.zig.zon" };

/// Upper bound on one covered file. Guardian's largest source is two orders of
/// magnitude under it; exceeding it is a source-root problem, not a digest one.
const max_file_bytes = 4 * 1024 * 1024;

/// Width of the length prefix that frames every hashed field.
const Len = u64;

/// Digests every source input reachable from `root`. Deterministic: the file
/// list is sorted by path, and each record is the length-prefixed path followed
/// by the length-prefixed contents, so no two different trees can produce the
/// same byte stream.
pub fn compute(allocator: std.mem.Allocator, root: std.fs.Dir) Error!Hex {
    const paths = try collect(allocator, root);
    std.mem.sort([]const u8, paths, {}, byPath);

    var hasher = Sha256.init(.{});
    hasher.update(format_tag);
    for (paths) |path| {
        const content = root.readFileAlloc(allocator, path, max_file_bytes) catch
            return error.SourceRootUnreadable;
        defer allocator.free(content);
        updateField(&hasher, path);
        updateField(&hasher, content);
    }
    // The record count closes the stream, so a truncated tree can never hash to
    // the same value as a longer one whose extra records were simply dropped.
    updateLength(&hasher, paths.len);

    var raw: [Sha256.digest_length]u8 = undefined;
    hasher.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Lists every covered path, relative to `root`. A missing root file or an
/// unreadable `src/` is fatal: silently digesting a partial tree would let a
/// stale binary pass its own staleness check.
fn collect(allocator: std.mem.Allocator, root: std.fs.Dir) Error![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (root_files) |name| {
        root.access(name, .{}) catch return error.SourceRootUnreadable;
        try paths.append(allocator, name);
    }

    var sources = root.openDir(source_dir, .{ .iterate = true }) catch
        return error.SourceRootUnreadable;
    defer sources.close();
    var walker = sources.walk(allocator) catch return error.SourceRootUnreadable;
    defer walker.deinit();
    while (walker.next() catch return error.SourceRootUnreadable) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, source_ext)) continue;
        try paths.append(allocator, try sourcePath(allocator, entry.path));
    }
    return paths.toOwnedSlice(allocator);
}

/// Re-roots a walker-relative path under `src/` and normalizes the path
/// separator, so the same tree digests identically on every host.
fn sourcePath(allocator: std.mem.Allocator, walked: []const u8) std.mem.Allocator.Error![]const u8 {
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, walked });
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, joined, std.fs.path.sep, '/');
    return joined;
}

/// Hashes one length-prefixed field. The prefixes are what make the record
/// stream unambiguous: no path/content pair can be re-framed as another.
fn updateField(hasher: *Sha256, bytes: []const u8) void {
    updateLength(hasher, bytes.len);
    hasher.update(bytes);
}

/// Hashes one little-endian length, at a fixed width on every target.
fn updateLength(hasher: *Sha256, value: usize) void {
    var buf: [@sizeOf(Len)]u8 = undefined;
    std.mem.writeInt(Len, &buf, value, .little);
    hasher.update(&buf);
}

/// Orders covered paths lexicographically, the sort that makes the digest
/// independent of directory-iteration order.
fn byPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Writes a minimal Guardian-shaped tree so each test only has to state what it
/// changes: the two covered root files plus one source file.
fn writeTree(dir: std.fs.Dir, source: []const u8) !void {
    try dir.writeFile(.{ .sub_path = "build.zig", .data = "// build graph" });
    try dir.writeFile(.{ .sub_path = "build.zig.zon", .data = ".{ .name = .demo }" });
    try dir.makePath(source_dir);
    try dir.writeFile(.{ .sub_path = "src/main.zig", .data = source });
}

/// Digests `dir` into an owned hex string, so a test can hold several digests at
/// once without juggling arenas.
fn digestOf(arena: std.mem.Allocator, dir: std.fs.Dir) ![]const u8 {
    const hex = try compute(arena, dir);
    return arena.dupe(u8, &hex);
}

// spec: Prebuilt Binary - Digests an unchanged source tree to the same value on every run

test "compute is deterministic for an unchanged tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeTree(tmp.dir, "const answer = 1;");
    const first = try digestOf(a, tmp.dir);
    const second = try digestOf(a, tmp.dir);
    try testing.expectEqualStrings(first, second);
    try testing.expectEqual(@as(usize, hex_len), first.len);
}

// spec: Prebuilt Binary - Moves the digest when a covered file's contents change

test "editing a source file or a root file changes the digest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeTree(tmp.dir, "const answer = 1;");
    const before = try digestOf(a, tmp.dir);

    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const answer = 2;" });
    const edited_source = try digestOf(a, tmp.dir);
    try testing.expect(!std.mem.eql(u8, before, edited_source));

    // The build graph is covered too: a build.zig edit can change what the
    // binary does without any src/ file moving.
    try tmp.dir.writeFile(.{ .sub_path = "build.zig", .data = "// different graph" });
    try testing.expect(!std.mem.eql(u8, edited_source, try digestOf(a, tmp.dir)));
}

// spec: Prebuilt Binary - Moves the digest when a source file is added, removed, or renamed

test "adding, renaming and deleting a source file each change the digest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeTree(tmp.dir, "const answer = 1;");
    const base = try digestOf(a, tmp.dir);

    try tmp.dir.makePath("src/cli");
    try tmp.dir.writeFile(.{ .sub_path = "src/cli/extra.zig", .data = "const answer = 1;" });
    const added = try digestOf(a, tmp.dir);
    try testing.expect(!std.mem.eql(u8, base, added));

    // A rename keeps every byte of content: only the hashed path moves, which is
    // exactly why the path is part of the record.
    try tmp.dir.rename("src/cli/extra.zig", "src/cli/renamed.zig");
    const renamed = try digestOf(a, tmp.dir);
    try testing.expect(!std.mem.eql(u8, added, renamed));

    try tmp.dir.deleteFile("src/cli/renamed.zig");
    try testing.expectEqualStrings(base, try digestOf(a, tmp.dir));
}

// spec: Prebuilt Binary - Covers only the build files and the zig sources under src

test "uncompiled files and stray root files leave the digest alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeTree(tmp.dir, "const answer = 1;");
    const base = try digestOf(a, tmp.dir);

    // Golden fixtures, docs and accepted metadata are not compiled into the
    // binary, so touching them must not invalidate a prebuilt one.
    try tmp.dir.writeFile(.{ .sub_path = "src/fixture.zig.in", .data = "const bad = ;" });
    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "# docs" });
    try tmp.dir.makePath(".guardian");
    try tmp.dir.writeFile(.{ .sub_path = ".guardian/pub-api.txt", .data = "v1" });
    try testing.expectEqualStrings(base, try digestOf(a, tmp.dir));
}

// spec: Prebuilt Binary - Refuses to digest a source root that is missing its build files

test "a directory without the covered root files is not a guardian source root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try tmp.dir.makePath(source_dir);
    try testing.expectError(error.SourceRootUnreadable, compute(arena.allocator(), tmp.dir));
}
