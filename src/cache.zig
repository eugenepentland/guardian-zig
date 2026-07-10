const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const walk = @import("walk.zig");

/// SHA-256 digest of guardian's input set.
pub const Digest = [Sha256.digest_length]u8;

/// Errors from computing or persisting the skip-cache digest: the walker's
/// (fs + OOM) surface, plus the extra failures of resolving and stat-ing the
/// running guardian binary (`selfExePathAlloc` + `statFile`) mixed into the
/// digest. Callers in run_all catch these and fall back to a full run.
pub const Error = walk.WalkError ||
    error{ NotSupported, FileSystem, NotLink, UnrecognizedVolume, UnknownName };

// Bump when the hashed input set below changes, so a stale cache written by
// an older guardian can never produce a wrong skip.
const cache_version = "guardian-cache-v2";
// Version tag for the mutation suite digest (see `suiteDigest`). Distinct from
// cache_version so the two digests can never collide even over an identical item set.
const suite_version = "guardian-mutation-suite-v1";
const cache_leaf = ".guardian/cache/inputs.sha256";
const max_file_bytes = 16 * 1024 * 1024;
const stored_max_bytes = 128;
const hex_len = Sha256.digest_length * 2;

const Item = struct { path: []const u8, content: []const u8 };

fn lessThan(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const Collector = struct {
    arena: Allocator,
    items: *std.ArrayList(Item),
};

fn collect(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *Collector = @ptrCast(@alignCast(raw_ctx));
    try ctx.items.append(ctx.arena, .{
        .path = try ctx.arena.dupe(u8, entry.rel_path),
        .content = try ctx.arena.dupe(u8, entry.content),
    });
}

fn readSingle(
    arena: Allocator,
    items: *std.ArrayList(Item),
    project_dir: []const u8,
    leaf: []const u8,
) Error!void {
    const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, leaf });
    const content = std.fs.cwd().readFileAlloc(arena, p, max_file_bytes) catch return;
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
/// reads a new path, add it here and bump version, or the cache could
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
    var items: std.ArrayList(Item) = .empty;
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
    return hashItems(cache_version, binary_id, items.items);
}

/// SHA-256 over a `version` tag, a length-prefixed `prefix` string (the
/// guardian binary identity for the skip-cache; empty for the mutation suite
/// digest), and each item's length-prefixed path + content. Length prefixes
/// make the concatenation unambiguous — no path/content pair can be reframed as
/// another. Callers sort `items` first for a stable digest.
fn hashItems(version: []const u8, prefix: []const u8, items: []const Item) Digest {
    var h = Sha256.init(.{});
    h.update(version);
    var len_buf: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &len_buf, prefix.len, .little);
    h.update(&len_buf);
    h.update(prefix);
    for (items) |it| {
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

/// Digest over every input whose change could alter a *mutation* outcome: every
/// `.zig` file under src/ and test/, plus the root build.zig, build.zig.zon, and
/// guardian.toml. Deliberately excludes `.guardian/` and the guardian binary
/// identity that `inputDigest` mixes in — a mutant's build+test cycle runs with
/// guardian no-op'd (GUARDIAN_MUTATION_RUN), so neither guardian's own snapshots
/// nor its binary can change whether a mutant is killed. Keys the per-mutant
/// result cache: any source or test edit changes this digest and so invalidates
/// every cached outcome (correctness first; see mutation/cache.zig).
pub fn suiteDigest(arena: Allocator, project_dir: []const u8) Error!Digest {
    var items: std.ArrayList(Item) = .empty;
    var ctx: Collector = .{ .arena = arena, .items = &items };
    const v: walk.Visitor = .{ .ctx = @ptrCast(&ctx), .visit = collect };

    const src = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    try walk.walkZigFiles(arena, src, .{ .display_root = "src" }, v);
    const tst = try std.fmt.allocPrint(arena, "{s}/test", .{project_dir});
    try walk.walkZigFiles(arena, tst, .{ .display_root = "test" }, v);

    try readSingle(arena, &items, project_dir, "build.zig");
    try readSingle(arena, &items, project_dir, "build.zig.zon");
    try readSingle(arena, &items, project_dir, "guardian.toml");

    std.mem.sort(Item, items.items, {}, lessThan);
    return hashItems(suite_version, "", items.items);
}

/// True when two digests are equal.
pub fn eql(a: Digest, b: Digest) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Parses a trimmed hex string into a digest, or null when it is the wrong
/// length or contains non-hex bytes.
fn parseHexDigest(hex: []const u8) ?Digest {
    if (hex.len != hex_len) return null;
    var out: Digest = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// Digest recorded by the last all-green run, or null when none exists or
/// the cache file is unreadable/malformed. OOM building the path propagates so
/// the caller can decide (it maps any failure to a full, cache-miss run).
pub fn readStored(arena: Allocator, project_dir: []const u8) Allocator.Error!?Digest {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, cache_leaf });
    // A missing/unreadable cache file is a legitimate cache miss (first run).
    const raw = std.fs.cwd().readFileAlloc(arena, path, stored_max_bytes) catch return null;
    return parseHexDigest(std.mem.trim(u8, raw, &std.ascii.whitespace));
}

/// Creates the cache dir and writes the digest as lowercase hex. Any failure
/// propagates to the best-effort caller, which swallows it.
fn writeStoredInner(arena: Allocator, project_dir: []const u8, digest: Digest) !void {
    const dir = try std.fmt.allocPrint(arena, "{s}/.guardian/cache", .{project_dir});
    try std.fs.cwd().makePath(dir);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, cache_leaf });
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

// spec: Mutation Testing - Keys the result cache on a suite digest that changes with any source or test edit

test "suiteDigest is stable for an unchanged tree and shifts when a source file changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/suite-digest-proj";
    std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir ++ "/src");
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("suite digest cleanup: {s}", .{@errorName(e)});

    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/src/a.zig", .data = "pub fn f() u32 { return 1; }\n" });
    const d1 = try suiteDigest(a, dir);
    // Same tree, same digest.
    try std.testing.expect(eql(d1, try suiteDigest(a, dir)));
    // Editing a source file changes the digest — so every cached mutant outcome
    // keyed on the old digest is correctly invalidated.
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/src/a.zig", .data = "pub fn f() u32 { return 2; }\n" });
    try std.testing.expect(!eql(d1, try suiteDigest(a, dir)));
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
    const got = (try readStored(a, dir)) orelse return error.TestExpectedStored;
    try std.testing.expect(eql(d, got));
}

// spec: Skip Cache - Reflects a rewritten .guardian baseline in a fresh input digest

test "a post-write .guardian digest stamps clean while the pre-write digest goes stale" {
    // Regression for the ordering bug behind eda commit 8cbb775 ("refresh stale
    // baselines masked by inputs.sha256 cache") and the auto-prune churn: a green
    // run can rewrite .guardian/, so the stamp must be recomputed AFTER checks
    // run — the pre-run digest describes a tree state no longer on disk.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/cache-prune-proj";
    const bpath = dir ++ "/.guardian/baselines/foo.txt";
    try std.fs.cwd().makePath(dir ++ "/.guardian/baselines");
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("prune test cleanup: {s}", .{@errorName(e)});

    // Pre-prune baseline (three violations) → digest d1.
    try std.fs.cwd().writeFile(.{ .sub_path = bpath, .data = "# guardian-snapshot v1\na\nb\nc\n" });
    const d1 = try inputDigest(a, dir, "SPEC.md");

    // Auto-prune rewrites the baseline smaller → digest d2.
    try std.fs.cwd().writeFile(.{ .sub_path = bpath, .data = "# guardian-snapshot v1\na\n" });
    const d2 = try inputDigest(a, dir, "SPEC.md");

    // A .guardian/ rewrite changes the digest, so storing the pre-write digest
    // (d1) can never match the on-disk tree — that is the spurious re-run.
    try std.testing.expect(!eql(d1, d2));

    // Stamping the POST-write digest (d2) makes the next unchanged run a cache
    // hit; the pre-write digest (d1) would miss it.
    writeStored(a, dir, d2);
    const stored = (try readStored(a, dir)) orelse return error.TestExpectedStored;
    const current = try inputDigest(a, dir, "SPEC.md");
    try std.testing.expect(eql(stored, current));
    try std.testing.expect(!eql(d1, current));
}
