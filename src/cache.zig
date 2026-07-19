//! Skip-cache: a SHA-256 digest over guardian's whole input set (src/test,
//! build metadata, spec/config/.guardian, embedded/external inputs, Git HEAD,
//! plus the guardian binary's own identity)
//! so an `all` run whose inputs are unchanged since the last green run is
//! skipped. Fail-open by design — any digest error makes run_all fall back to a
//! full run, never to a wrong skip.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const walk = @import("walk.zig");
const config = @import("config.zig");
const git = @import("git.zig");

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
const cache_version = "guardian-cache-v3";
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

/// Digest over every file Guardian reads as a check input: `.zig` files under
/// src/ and test/, build.zig/build.zig.zon, the spec/config, `.guardian`
/// metadata, declared external inputs, and project-local `@embedFile` assets.
/// Git HEAD and the running Guardian binary identity are mixed into the prefix,
/// so a commit or Guardian upgrade re-scans even when project bytes are stable.
///
/// Keep this in sync with what the checks actually read: if a new check
/// reads a new path, add it here and bump version, or the cache could
/// wrongly skip a real change.
pub fn inputDigest(
    arena: Allocator,
    project_dir: []const u8,
    spec_file: []const u8,
    external_gates: []const config.ExternalGate,
) Error!Digest {
    const binary_id = try selfBinaryId(arena);
    const head = git.headHash(arena, project_dir) orelse "no-git-head";
    const run_identity = try runIdentity(arena, binary_id, head);
    return digestWithBinaryId(arena, project_dir, spec_file, external_gates, run_identity);
}

fn runIdentity(arena: Allocator, binary_id: []const u8, head: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ binary_id, head });
}

/// Testable core of `inputDigest`: takes the guardian binary identity as an
/// explicit argument instead of reading the running executable's.
fn digestWithBinaryId(
    arena: Allocator,
    project_dir: []const u8,
    spec_file: []const u8,
    external_gates: []const config.ExternalGate,
    binary_id: []const u8,
) Error!Digest {
    var items: std.ArrayList(Item) = .empty;
    var ctx: Collector = .{ .arena = arena, .items = &items };
    const v: walk.Visitor = .{ .ctx = @ptrCast(&ctx), .visit = collect };

    const src = try std.fmt.allocPrint(arena, "{s}/src", .{project_dir});
    try walk.walkZigFiles(arena, src, .{ .display_root = "src" }, v);
    const tst = try std.fmt.allocPrint(arena, "{s}/test", .{project_dir});
    try walk.walkZigFiles(arena, tst, .{ .display_root = "test" }, v);
    try collectEmbeddedAssets(arena, &items, project_dir);
    const grd = try std.fmt.allocPrint(arena, "{s}/.guardian", .{project_dir});
    try walk.walkZigFiles(arena, grd, .{ .display_root = ".guardian", .extension = "", .excludes = &.{"cache"} }, v);

    try readSingle(arena, &items, project_dir, "build.zig");
    try readSingle(arena, &items, project_dir, "build.zig.zon");
    try readSingle(arena, &items, project_dir, spec_file);
    try readSingle(arena, &items, project_dir, "guardian.toml");
    for (external_gates) |gate| {
        for (gate.inputs) |input| try readSingle(arena, &items, project_dir, input);
    }

    std.mem.sort(Item, items.items, {}, lessThan);
    return hashItems(cache_version, binary_id, items.items);
}

/// Adds project-local files named by literal `@embedFile("...")` calls in the
/// collected Zig sources. These assets affect shipped behavior even though no
/// Zig-oriented check scans their contents; hashing them prevents Guardian's
/// green-run cache from hiding a changed JS/CSS/template behind a stale stamp.
fn collectEmbeddedAssets(
    arena: Allocator,
    items: *std.ArrayList(Item),
    project_dir: []const u8,
) Error!void {
    // Appending assets may reallocate `items`; iterate a stable copy of the
    // source descriptors rather than retaining a slice into that array list.
    const sources = try arena.dupe(Item, items.items);
    for (sources) |source| {
        if (!std.mem.endsWith(u8, source.path, ".zig")) continue;
        const z = try arena.dupeZ(u8, source.content);
        var tok = std.zig.Tokenizer.init(z);
        while (true) {
            const builtin = tok.next();
            if (builtin.tag == .eof) break;
            if (builtin.tag != .builtin or !std.mem.eql(u8, z[builtin.loc.start..builtin.loc.end], "@embedFile")) {
                continue;
            }
            if (tok.next().tag != .l_paren) continue;
            const literal = tok.next();
            if (literal.tag != .string_literal) continue;
            const raw = z[literal.loc.start..literal.loc.end];
            if (raw.len < 2 or std.mem.indexOfScalar(u8, raw[1 .. raw.len - 1], '\\') != null) continue;
            const rel = (try resolveEmbeddedPath(arena, source.path, raw[1 .. raw.len - 1])) orelse continue;
            try readSingle(arena, items, project_dir, rel);
        }
    }
}

/// Resolves an embed literal against its source file while rejecting absolute
/// paths and `..` traversal above the project root.
fn resolveEmbeddedPath(arena: Allocator, source_path: []const u8, raw: []const u8) Allocator.Error!?[]const u8 {
    if (std.fs.path.isAbsolute(raw)) return null;
    var parts: std.ArrayList([]const u8) = .empty;
    if (std.fs.path.dirname(source_path)) |dir| {
        var base = std.mem.splitScalar(u8, dir, '/');
        while (base.next()) |part| if (part.len > 0) try parts.append(arena, part);
    }
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, part);
    }
    if (parts.items.len == 0) return null;
    const joined: []const u8 = try std.mem.join(arena, "/", parts.items);
    return joined;
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
    const d1 = try inputDigest(a, "test-project", "SPEC.md", &.{});
    const d2 = try inputDigest(a, "test-project", "SPEC.md", &.{});
    try std.testing.expect(eql(d1, d2));
}

// spec: Skip Cache - Mixes the guardian binary identity into the digest so an upgrade invalidates the cache
test "a different guardian binary identity changes the digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d1 = try digestWithBinaryId(a, "test-project", "SPEC.md", &.{}, "guardian-build-1");
    const d2 = try digestWithBinaryId(a, "test-project", "SPEC.md", &.{}, "guardian-build-2");
    const d3 = try digestWithBinaryId(a, "test-project", "SPEC.md", &.{}, "guardian-build-1");
    try std.testing.expect(!eql(d1, d2));
    try std.testing.expect(eql(d1, d3));
}

// spec: Skip Cache - Invalidates a green stamp when the Git HEAD changes

test "a different Git head changes the run identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id1 = try runIdentity(a, "guardian-build", "head-1");
    const id2 = try runIdentity(a, "guardian-build", "head-2");
    const d1 = try digestWithBinaryId(a, "test-project", "SPEC.md", &.{}, id1);
    const d2 = try digestWithBinaryId(a, "test-project", "SPEC.md", &.{}, id2);
    try std.testing.expect(!eql(d1, d2));
}

// spec: Skip Cache - Includes declared external gate input files in the green-run digest

test "a changed external gate input invalidates the digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/external-digest-proj";
    std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir);
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("external digest cleanup: {s}", .{@errorName(e)});

    const gates = &[_]config.ExternalGate{.{
        .name = "asset-syntax",
        .command = &.{ "node", "--check", "asset.js" },
        .inputs = &.{"asset.js"},
    }};
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/asset.js", .data = "const value = 1;\n" });
    const d1 = try digestWithBinaryId(a, dir, "SPEC.md", gates, "guardian-build");
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/asset.js", .data = "const value = 2;\n" });
    const d2 = try digestWithBinaryId(a, dir, "SPEC.md", gates, "guardian-build");
    try std.testing.expect(!eql(d1, d2));
}

// spec: Skip Cache - Includes files referenced by project-local embedFile calls

test "a changed embedded asset invalidates the digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/embedded-digest-proj";
    std.fs.cwd().deleteTree(dir) catch {};
    try std.fs.cwd().makePath(dir ++ "/src");
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("embedded digest cleanup: {s}", .{@errorName(e)});

    try std.fs.cwd().writeFile(.{
        .sub_path = dir ++ "/src/main.zig",
        .data = "const script = @embedFile(\"../www/app.js\");\n",
    });
    try std.fs.cwd().makePath(dir ++ "/www");
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/www/app.js", .data = "const value = 1;\n" });
    const d1 = try digestWithBinaryId(a, dir, "SPEC.md", &.{}, "guardian-build");
    try std.fs.cwd().writeFile(.{ .sub_path = dir ++ "/www/app.js", .data = "const value = 2;\n" });
    const d2 = try digestWithBinaryId(a, dir, "SPEC.md", &.{}, "guardian-build");
    try std.testing.expect(!eql(d1, d2));
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
    const d1 = try inputDigest(a, dir, "SPEC.md", &.{});

    // Auto-prune rewrites the baseline smaller → digest d2.
    try std.fs.cwd().writeFile(.{ .sub_path = bpath, .data = "# guardian-snapshot v1\na\n" });
    const d2 = try inputDigest(a, dir, "SPEC.md", &.{});

    // A .guardian/ rewrite changes the digest, so storing the pre-write digest
    // (d1) can never match the on-disk tree — that is the spurious re-run.
    try std.testing.expect(!eql(d1, d2));

    // Stamping the POST-write digest (d2) makes the next unchanged run a cache
    // hit; the pre-write digest (d1) would miss it.
    writeStored(a, dir, d2);
    const stored = (try readStored(a, dir)) orelse return error.TestExpectedStored;
    const current = try inputDigest(a, dir, "SPEC.md", &.{});
    try std.testing.expect(eql(stored, current));
    try std.testing.expect(!eql(d1, current));
}
