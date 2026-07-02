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
const VERSION = "guardian-cache-v1";
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

fn readSingle(arena: Allocator, items: *std.ArrayListUnmanaged(Item), project_dir: []const u8, leaf: []const u8) Error!void {
    const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, leaf });
    const content = std.fs.cwd().readFileAlloc(arena, p, MAX_FILE_BYTES) catch return;
    try items.append(arena, .{ .path = try arena.dupe(u8, leaf), .content = content });
}

/// Digest over every file guardian reads as a check input: the `.zig` files
/// under src/ and test/, the root build.zig, the spec file, guardian.toml,
/// and the `.guardian/` tree (baselines + snapshots, minus the cache
/// itself). Files outside this set — e.g. design sources — never affect it,
/// which is what lets an unrelated edit skip the whole run.
///
/// Keep this in sync with what the checks actually read: if a new check
/// reads a new path, add it here and bump VERSION, or the cache could
/// wrongly skip a real change.
pub fn inputDigest(arena: Allocator, project_dir: []const u8, spec_file: []const u8) Error!Digest {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    var ctx: Collector = .{ .arena = arena, .items = &items };
    const v: walk.Visitor = .{ .ctx = @ptrCast(&ctx), .visit = collect };

    const src = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    try walk.walkZigFiles(arena, src, "src", .{}, v);
    const tst = try std.fmt.allocPrint(arena, "{s}/test", .{project_dir});
    try walk.walkZigFiles(arena, tst, "test", .{}, v);
    const grd = try std.fmt.allocPrint(arena, "{s}/.guardian", .{project_dir});
    try walk.walkZigFiles(arena, grd, ".guardian", .{ .extension = "", .excludes = &.{"cache"} }, v);

    try readSingle(arena, &items, project_dir, "build.zig");
    try readSingle(arena, &items, project_dir, spec_file);
    try readSingle(arena, &items, project_dir, "guardian.toml");

    std.mem.sort(Item, items.items, {}, lessThan);

    var h = Sha256.init(.{});
    h.update(VERSION);
    var len_buf: [@sizeOf(usize)]u8 = undefined;
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

/// Digest recorded by the last all-green run, or null when none exists or
/// the cache file is unreadable/malformed.
pub fn readStored(arena: Allocator, project_dir: []const u8) ?Digest {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, CACHE_LEAF }) catch return null;
    const raw = std.fs.cwd().readFileAlloc(arena, path, STORED_MAX_BYTES) catch return null;
    const hex = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (hex.len != HEX_LEN) return null;
    var out: Digest = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// Records `digest` as the last all-green input state. Best-effort: write
/// failures are swallowed so the cache can never fail the build.
pub fn writeStored(arena: Allocator, project_dir: []const u8, digest: Digest) void {
    const dir = std.fmt.allocPrint(arena, "{s}/.guardian/cache", .{project_dir}) catch return;
    std.fs.cwd().makePath(dir) catch return;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, CACHE_LEAF }) catch return;
    const hex = std.fmt.bytesToHex(digest, .lower);
    const f = std.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    f.writeAll(&hex) catch return;
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
