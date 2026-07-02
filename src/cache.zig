const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const walk = @import("walk.zig");

/// SHA-256 digest of guardian's input set.
pub const Digest = [Sha256.digest_length]u8;

/// Errors from computing or persisting the skip-cache digest.
pub const Error = walk.WalkError;

// Bump when the hashed input set below changes, so a stale cache written by
// an older guardian can never produce a wrong skip.
const VERSION = "guardian-cache-v2";
const CACHE_LEAF = ".guardian/cache/inputs.sha256";
const MAX_FILE_BYTES = 16 * 1024 * 1024;
const STORED_MAX_BYTES = 128;
const HEX_LEN = Sha256.digest_length * 2;

const Item = struct { path: []const u8, content: []const u8 };

fn lessThan(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const Collector = struct {
    arena: Allocator,
    items: *std.ArrayListUnmanaged(Item),
};

fn collect(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *Collector = @ptrCast(@alignCast(raw_ctx));
    try ctx.items.append(ctx.arena, .{
        .path = try ctx.arena.dupe(u8, entry.rel_path),
        .content = try ctx.arena.dupe(u8, entry.content),
    });
}

fn readSingle(
    arena: Allocator,
    items: *std.ArrayListUnmanaged(Item),
    project_dir: []const u8,
    leaf: []const u8,
) Error!void {
    const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, leaf });
    const content = std.fs.cwd().readFileAlloc(arena, p, MAX_FILE_BYTES) catch return;
    try items.append(arena, .{ .path = try arena.dupe(u8, leaf), .content = content });
}

/// Identity of the running guardian-check binary: absolute path, size, and
/// mtime. Run via `zig build`, the binary lives in a content-addressed
/// `o/<hash>/` artifact dir, so any guardian source or config change lands
/// at a new path with a fresh mtime — the same invalidation guarantee as
/// hashing the binary's bytes without paying a content hash of a multi-MB
/// executable on every run. Errors propagate: no identity means no skip.
fn selfBinaryId(arena: Allocator) ![]const u8 {
    const exe_path = try std.fs.selfExePathAlloc(arena);
    const st = try std.fs.cwd().statFile(exe_path);
    return std.fmt.allocPrint(arena, "{s}\x00{d}\x00{d}", .{ exe_path, st.size, st.mtime });
}

/// Digest over every file guardian reads as a check input: the `.zig` files
/// under src/ and test/, the root build.zig, the spec file, guardian.toml,
/// and the `.guardian/` tree (baselines + snapshots, minus the cache
/// itself) — plus the identity of the guardian binary itself, so upgrading
/// guardian (new or changed checks) re-scans even when the project's own
/// files are untouched. Files outside this set — e.g. design sources —
/// never affect it, which is what lets an unrelated edit skip the whole run.
///
/// Keep this in sync with what the checks actually read: if a new check
/// reads a new path, add it here and bump VERSION, or the cache could
/// wrongly skip a real change.
pub fn inputDigest(arena: Allocator, project_dir: []const u8, spec_file: []const u8) Error!Digest {
    return digestWithBinaryId(arena, project_dir, spec_file, try selfBinaryId(arena));
}

/// Testable core of `inputDigest`: takes the guardian binary identity as an
/// explicit argument instead of reading the running executable's.
fn digestWithBinaryId(
    arena: Allocator,
    project_dir: []const u8,
    spec_file: []const u8,
    binary_id: []const u8,
) Error!Digest {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    var ctx: Collector = .{ .arena = arena, .items = &items };
    const v: walk.Visitor = .{ .ctx = @ptrCast(&ctx), .visit = collect };

    const src = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    try walk.walkZigFiles(arena, src, .{ .display_root = "src" }, v);
    const tst = try std.fmt.allocPrint(arena, "{s}/test", .{project_dir});
    try walk.walkZigFiles(arena, tst, .{ .display_root = "test" }, v);
    const grd = try std.fmt.allocPrint(arena, "{s}/.guardian", .{project_dir});
    try walk.walkZigFiles(arena, grd, .{ .display_root = ".guardian", .extension = "", .excludes = &.{"cache"} }, v);

    try readSingle(arena, &items, project_dir, "build.zig");
    try readSingle(arena, &items, project_dir, spec_file);
    try readSingle(arena, &items, project_dir, "guardian.toml");

    std.mem.sort(Item, items.items, {}, lessThan);

    var h = Sha256.init(.{});
    h.update(VERSION);
    var len_buf: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &len_buf, binary_id.len, .little);
    h.update(&len_buf);
    h.update(binary_id);
    for (items.items) |it| {
        std.mem.writeInt(usize, &len_buf, it.path.len, .little);
        h.update(&len_buf);
        h.update(it.path);
        std.mem.writeInt(usize, &len_buf, it.content.len, .little);
        h.update(&len_buf);
        h.update(it.content);
    }
    var out: Digest = undefined;
    h.final(&out);
    return out;
}

/// True when two digests are equal.
pub fn eql(a: Digest, b: Digest) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Parses a trimmed hex string into a digest, or null when it is the wrong
/// length or contains non-hex bytes.
fn parseHexDigest(hex: []const u8) ?Digest {
    if (hex.len != HEX_LEN) return null;
    var out: Digest = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// Digest recorded by the last all-green run, or null when none exists or
/// the cache file is unreadable/malformed.
pub fn readStored(arena: Allocator, project_dir: []const u8) ?Digest {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, CACHE_LEAF }) catch return null;
    const raw = std.fs.cwd().readFileAlloc(arena, path, STORED_MAX_BYTES) catch return null;
    return parseHexDigest(std.mem.trim(u8, raw, &std.ascii.whitespace));
}

/// Creates the cache dir and writes the digest as lowercase hex. Any failure
/// propagates to the best-effort caller, which swallows it.
fn writeStoredInner(arena: Allocator, project_dir: []const u8, digest: Digest) !void {
    const dir = try std.fmt.allocPrint(arena, "{s}/.guardian/cache", .{project_dir});
    try std.fs.cwd().makePath(dir);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, CACHE_LEAF });
    const hex = std.fmt.bytesToHex(digest, .lower);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(&hex);
}

/// Records `digest` as the last all-green input state. Best-effort: write
/// failures are swallowed so the cache can never fail the build.
pub fn writeStored(arena: Allocator, project_dir: []const u8, digest: Digest) void {
    writeStoredInner(arena, project_dir, digest) catch return;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Skip Cache - Hashes the guardian input set into a stable digest
// spec: Skip Cache - Round-trips the digest through the cache file

test "inputDigest is deterministic for an unchanged input set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d1 = try inputDigest(a, "test-project", "SPEC.md");
    const d2 = try inputDigest(a, "test-project", "SPEC.md");
    try std.testing.expect(eql(d1, d2));
}

// spec: Skip Cache - Mixes the guardian binary identity into the digest so an upgrade invalidates the cache
test "a different guardian binary identity changes the digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d1 = try digestWithBinaryId(a, "test-project", "SPEC.md", "guardian-build-1");
    const d2 = try digestWithBinaryId(a, "test-project", "SPEC.md", "guardian-build-2");
    const d3 = try digestWithBinaryId(a, "test-project", "SPEC.md", "guardian-build-1");
    try std.testing.expect(!eql(d1, d2));
    try std.testing.expect(eql(d1, d3));
}

test "writeStored then readStored round-trips the digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/cache-test-proj";
    try std.fs.cwd().makePath(dir);
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("cache test cleanup: {s}", .{@errorName(e)});

    var d: Digest = undefined;
    Sha256.hash("hello", &d, .{});
    writeStored(a, dir, d);
    const got = readStored(a, dir) orelse return error.TestExpectedStored;
    try std.testing.expect(eql(d, got));
}
