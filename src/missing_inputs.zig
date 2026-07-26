//! Missing-generated-input detection: which of a check's findings describe a
//! file that is **absent from the working tree and gitignored** — i.e. build
//! output nobody has generated in this worktree yet.
//!
//! A fresh `git worktree add` lacks every gitignored generated file, so a
//! snapshot/baseline recorded elsewhere reports its symbols as violations in a
//! file that does not exist. That reads as real debt (one report was 49
//! "violations" in an absent file), and both obvious responses are wrong:
//! accepting ratifies phantoms, and skipping the gate is banned. Such findings
//! are reported as SKIPPED instead — never counted, never acceptable.
//!
//! The partition is deliberately narrow. A path must be BOTH missing and
//! gitignored: a deleted *tracked* file is still absent but not ignored (git's
//! index makes that distinction — see `git.ignoredPaths`), so a real API
//! removal keeps failing exactly as before.

const std = @import("std");
const Allocator = std.mem.Allocator;
const git = @import("git.zig");

/// Appended to every skip notice: the mechanical diagnosis an operator would
/// otherwise reach only by running `git check-ignore` on the reported paths.
pub const hint = "gitignored build outputs missing — run your build once in this worktree";

/// The paths in `paths` that are absent from the working tree AND gitignored.
/// Deduplicated. Empty when git is unavailable or nothing qualifies — the
/// fail-closed direction, where every finding keeps counting.
pub fn phantomPaths(
    allocator: Allocator,
    project_dir: []const u8,
    paths: []const []const u8,
) Allocator.Error![]const []const u8 {
    var absent: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (contains(absent.items, p)) continue;
        if (try present(allocator, project_dir, p)) continue;
        try absent.append(allocator, p);
    }
    if (absent.items.len == 0) return &.{};
    return git.ignoredPaths(allocator, project_dir, absent.items);
}

/// True when `<project_dir>/<rel>` exists. Allocation failure propagates: a
/// phantom must never be invented out of an OOM.
fn present(allocator: Allocator, project_dir: []const u8, rel: []const u8) Allocator.Error!bool {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, rel });
    defer allocator.free(full);
    std.fs.cwd().access(full, .{}) catch return false;
    return true;
}

/// True when `path` is one of `paths`.
pub fn contains(paths: []const []const u8, path: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

/// The `.zig` file a rendered violation line refers to, or null when the line
/// names no file. Handles the three shapes checks print — `file:line: msg`,
/// `file: msg`, and a snapshot diff's `- file::symbol …` — and accepts only a
/// `.zig` suffix, so a prose line that merely starts with a word can never be
/// mistaken for a path (and so never earn skip semantics).
pub fn pathFromLine(line: []const u8) ?[]const u8 {
    var rest = std.mem.trim(u8, line, &std.ascii.whitespace);
    for ([_][]const u8{ "- ", "+ " }) |marker| {
        if (std.mem.startsWith(u8, rest, marker)) rest = rest[marker.len..];
    }
    const end = std.mem.indexOfAny(u8, rest, ": \t") orelse rest.len;
    const candidate = rest[0..end];
    return if (std.mem.endsWith(u8, candidate, ".zig")) candidate else null;
}

/// The `.zig` path recorded inside a stored baseline/ratchet key line, or null.
/// Both stored formats embed the file as a `|`-delimited segment — a v2 ratchet
/// line as `<value> <file>|<item>`, a v3 identity key as `<check>|<file>|<disc>`
/// — so the file is the first segment (after any leading value) ending `.zig`.
pub fn pathFromStoredKey(line: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, &std.ascii.whitespace);
        const tail = if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |sp| trimmed[sp + 1 ..] else trimmed;
        if (std.mem.endsWith(u8, tail, ".zig")) return tail;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Missing Inputs - Extracts the zig file a rendered violation line refers to

test "pathFromLine reads the file from every rendered violation shape" {
    // file:line: message — the common structured shape.
    try std.testing.expectEqualStrings("src/x.zig", pathFromLine("src/x.zig:12: fn f has 7 params").?);
    // file: message — a whole-file metric.
    try std.testing.expectEqualStrings("src/x.zig", pathFromLine("src/x.zig: 1200 code lines").?);
    // A snapshot diff line, indented and marker-prefixed.
    try std.testing.expectEqualStrings(
        "src/serve/templates/library.zig",
        pathFromLine("  - src/serve/templates/library.zig::Args value").?,
    );
    // Prose with no path stays prose: a spec bullet must never be read as a file.
    try std.testing.expect(pathFromLine("unverified: Auth - Validates tokens") == null);
    try std.testing.expect(pathFromLine("duplicate const foo across 2 files") == null);
    // Non-Zig paths are out of scope for the skip rule.
    try std.testing.expect(pathFromLine("assets/app.js: minified") == null);
}

// spec: Missing Inputs - Extracts the file recorded in a stored baseline or ratchet key

test "pathFromStoredKey reads the file out of both stored formats" {
    // v2 ratchet: "<value> <file>|<item>".
    try std.testing.expectEqualStrings(
        "src/convert/footprint.zig",
        pathFromStoredKey("9 src/convert/footprint.zig|emitCustomPolyPad").?,
    );
    // v3 identity: "<check>|<file>|<discriminator>".
    try std.testing.expectEqualStrings(
        "src/bom.zig",
        pathFromStoredKey("dead-pub|src/bom.zig|:applyBomUuids: unused public declaration").?,
    );
    // A key with no file (a spec bullet) yields nothing to test for presence.
    try std.testing.expect(pathFromStoredKey("spec|Auth - Validates tokens") == null);
}

// spec: Missing Inputs - Treats a path as phantom only when it is absent and gitignored

test "phantomPaths skips missing build output but keeps a deleted tracked file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Run against this repo: `zig-out/…` is gitignored, `src/…` is tracked.
    // A missing gitignored path is phantom; a missing TRACKED path is a real
    // deletion and must keep counting (no hole for a real API removal).
    const paths = [_][]const u8{
        "zig-out/generated/absent.zig",
        "src/definitely_not_a_file.zig",
        "src/check.zig",
    };
    const phantoms = try phantomPaths(a, ".", &paths);
    try std.testing.expect(contains(phantoms, "zig-out/generated/absent.zig"));
    try std.testing.expect(!contains(phantoms, "src/definitely_not_a_file.zig"));
    // A file that exists is never phantom, ignored or not.
    try std.testing.expect(!contains(phantoms, "src/check.zig"));
}
