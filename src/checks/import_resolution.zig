//! import-resolution — every PATH-SHAPED `@import` must name a file that is
//! actually there.
//!
//! This is the Zig-native form of API/package hallucination: an agent invents
//! `@import("../util/strings.zig")` because that is where the helper *ought* to
//! live, and nothing contradicts it. The compiler only contradicts it for files
//! reachable from the build graph — an orphaned module, a test-only helper, or
//! a file whose sole importer is itself orphaned never gets analyzed, so a
//! fabricated path sits in the tree compiling nothing and reporting green.
//! Guardian reads the tree off disk rather than off the build graph, so it sees
//! the import the compiler never reaches.
//!
//! Prior art: DonIsaac/zlint ships the same rule as `no-unresolved`, category
//! `correctness`, default-on at ERROR — its highest severity, notable because
//! zlint defaults nearly everything else to `warn`. Its doc: "Checks for imports
//! to files that do not exist... Modules added by `build.zig` are not checked.
//! More precisely, imports to paths ending in `.zig` will be resolved." zlint's
//! gate is `if (!isDotSlash(pathname) and !eql(ext, ".zig")) return;` followed by
//! `dir.statFile()`. zlint is wired into Bun's CI.
//!
//! WHAT IS A PATH: the literal ends in `.zig`, or begins `./` or `../`. Anything
//! else is a build.zig module name (`std`, `builtin`, `root`, `guardian`,
//! `guardian-fakes`, a dependency) and is deliberately NOT resolved — Guardian
//! cannot see the consumer's `build.zig` module graph, and guessing would flag
//! every correct package import.
//!
//! SYMLINKS are allowed and are NOT followed: the stat is `follow_symlinks =
//! false`, so a symlinked module resolves on the link entry itself and the path
//! is never canonicalized. A link out of the tree is therefore never chased into
//! some other project's file.
//!
//! Two things are deliberately not judged. An import that climbs ABOVE the
//! project root (`../../vendor/x.zig`) is skipped: the file is outside the tree
//! Guardian was pointed at, so "missing" would be a guess. And a stat that fails
//! for an environmental reason (permissions, a filesystem error) warns on the
//! advisory channel instead of blocking — a hard gate must say what it could not
//! verify rather than invent a verdict.
//!
//! Residual false positive, exactly one: a `build.zig` module whose NAME ends in
//! `.zig` is indistinguishable from a sibling-file import and gets stat'd as a
//! path. Rename the module (module names are the project's to choose) or exempt
//! the importing file with `[[allow]] check = "import-resolution"`.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;

/// One path-shaped `@import` of a file, with its literal resolved against the
/// importing file's directory into a project-relative path. Produced without
/// touching the filesystem, so the classification and the join are unit-testable
/// on their own; `run` is the part that stats `target`.
pub const Candidate = struct {
    /// 1-indexed line of the `@import` builtin.
    line: u32,
    /// The literal string as written inside `@import("...")`.
    spec: []const u8,
    /// `spec` joined onto the importer's directory and normalized.
    target: []const u8,
};

/// True when `spec` is a filesystem path rather than a build.zig module name.
/// The two shapes zlint uses, and the only two Zig itself gives a reader: a
/// `.zig` suffix, or an explicitly relative prefix.
pub fn pathShaped(spec: []const u8) bool {
    if (std.mem.endsWith(u8, spec, ".zig")) return true;
    if (std.mem.startsWith(u8, spec, "./")) return true;
    if (std.mem.startsWith(u8, spec, "../")) return true;
    return false;
}

/// Joins `spec` onto the directory holding `importer_rel` and normalizes the
/// `.`/`..` segments, returning the project-relative target — or null when the
/// result would climb above the project root, which is a file Guardian was not
/// pointed at and may not judge.
///
/// Written here rather than reusing `walk.normalizePath` because that function
/// SILENTLY CLAMPS a `..` at the root: `src/a.zig` importing `../../out.zig`
/// would normalize to `out.zig` and then be reported missing from a directory it
/// never named. The escape has to be a distinct answer, not a clamped one.
pub fn resolveTarget(
    allocator: Allocator,
    importer_rel: []const u8,
    spec: []const u8,
) Allocator.Error!?[]const u8 {
    // An absolute import is not project-relative and cannot be placed in the
    // tree; treat it like an escape and say nothing about it.
    if (spec.len > 0 and spec[0] == '/') return null;

    var parts: std.ArrayList([]const u8) = .empty;
    const slash = std.mem.lastIndexOfScalar(u8, importer_rel, '/');
    // The importer's own directory can never escape: it is already a
    // project-relative path with no `..` in it.
    if (slash) |idx| _ = try appendSegments(allocator, &parts, importer_rel[0..idx]);
    if (!try appendSegments(allocator, &parts, spec)) return null;
    if (parts.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    const joined: []const u8 = try out.toOwnedSlice(allocator);
    return joined;
}

/// Appends `path`'s segments onto `parts`, resolving `.` and `..`. Returns false
/// when a `..` would pop past the root — the escape signal `resolveTarget` turns
/// into "not judged".
fn appendSegments(
    allocator: Allocator,
    parts: *std.ArrayList([]const u8),
    path: []const u8,
) Allocator.Error!bool {
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return false;
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, seg);
    }
    return true;
}

/// Filesystem-free core: every path-shaped `@import` in `content`, resolved
/// against `rel_path`'s directory. Module-name imports and escapes above the
/// root are already dropped, so each returned `target` is a project-relative
/// path `run` can stat directly. Empty slice = nothing to resolve.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    for (ast.imports(allocator, content)) |imp| {
        if (!pathShaped(imp.path)) continue;
        const target = try resolveTarget(allocator, rel_path, imp.path) orelse continue;
        try out.append(allocator, .{ .line = imp.line, .spec = imp.path, .target = target });
    }
    return out.toOwnedSlice(allocator);
}

/// Whether the entry at `target` counts as a resolved import.
const Verdict = enum {
    /// A file, or a symlink we deliberately did not follow.
    resolved,
    /// Nothing is there.
    missing,
    /// Something is there, but it is a directory — `@import` needs a file.
    directory,
    /// The stat failed for a reason that is not about existence.
    unverifiable,
};

/// Stats one resolved target inside `dir`, never following a final symlink.
fn classify(dir: fs.Dir, target: []const u8) Verdict {
    const st = dir.statFileNoFollow(target) catch |e| switch (e) {
        // The three ways the path itself says "no such file": nothing there, a
        // non-directory used as a directory component, and a name the platform
        // cannot even represent. All three mean the import does not resolve.
        error.FileNotFound, error.NotDir, error.BadPathName => return .missing,
        else => return .unverifiable,
    };
    return switch (st.kind) {
        .directory => .directory,
        else => .resolved,
    };
}

const ScanCtx = struct {
    allocator: Allocator,
    dir: fs.Dir,
    violations: *std.ArrayList(reporter.Violation),
    allowed: []const []const u8,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    for (ctx.allowed) |pat| {
        if (walk.matchGlob(entry.rel_path, pat)) return;
    }
    // The walker's rel_path is only valid for this visit and the records outlive
    // the walk, so every path that rides on one is copied.
    const file = try a.dupe(u8, entry.rel_path);
    for (try analyzeContent(a, entry.rel_path, entry.content)) |cand| {
        switch (classify(ctx.dir, cand.target)) {
            .resolved => {},
            .unverifiable => reporter.warn(.{
                .check = check_name,
                .file = file,
                .line = cand.line,
                .message = try std.fmt.allocPrint(
                    a,
                    "could not stat \"{s}\" ({s}) — not judged",
                    .{ cand.spec, cand.target },
                ),
            }),
            .missing => try ctx.violations.append(a, try record(a, file, cand, "no file at")),
            .directory => try ctx.violations.append(a, try record(a, file, cand, "a directory, not a file, at")),
        }
    }
}

/// Builds one violation record. The identity is `<file>|<spec>` — the import the
/// agent wrote, not the rendered sentence — so rewording this diagnostic cannot
/// re-key a consumer's baseline (see src/violation_key.zig).
fn record(
    a: Allocator,
    file: []const u8,
    cand: Candidate,
    what: []const u8,
) Allocator.Error!reporter.Violation {
    return .{
        .check = check_name,
        .file = file,
        .line = cand.line,
        .message = try std.fmt.allocPrint(
            a,
            "unresolved import \"{s}\" — {s} {s}",
            .{ cand.spec, what, cand.target },
        ),
        .fix_hint = try std.fmt.allocPrint(
            a,
            "create {s}, fix the path, or — if \"{s}\" is a build.zig module name — rename the module so it does not end in .zig",
            .{ cand.target, cand.spec },
        ),
        .identity = try std.fmt.allocPrint(a, "{s}|{s}", .{ file, cand.spec }),
    };
}

const check_name = "import-resolution";

/// Entry point for the import-resolution check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var dir = try fs.cwd().openDir(ctx.project_dir, .{});
    defer dir.close();

    var violations: std.ArrayList(reporter.Violation) = .empty;
    var scan_ctx: ScanCtx = .{
        .allocator = allocator,
        .dir = dir,
        .violations = &violations,
        .allowed = ctx.cfg.extraAllowed(check_name),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &scan_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("{s}: every path-shaped @import resolves to a file", .{check_name});
        return;
    }
    reporter.fail("{s} FAILED ({d} unresolved import(s))", .{ check_name, violations.items.len });
    for (violations.items) |v| reporter.emitQuiet(v);
    reporter.detail(
        "  fix: create the file or correct the path; a build.zig module name that ends in .zig " ++
            "is the one shape this cannot tell apart — rename it or use [[allow]] check = \"import-resolution\".\n",
        .{},
    );
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Import Resolution - Treats a literal ending in .zig or beginning with a relative prefix as a path

test "pathShaped separates file paths from build.zig module names" {
    try std.testing.expect(pathShaped("util.zig"));
    try std.testing.expect(pathShaped("../core/math.zig"));
    try std.testing.expect(pathShaped("./sibling"));
    // Module names are never resolved: Guardian cannot see the consumer's
    // build.zig module graph, so treating these as paths would flag every
    // correct package import.
    try std.testing.expect(!pathShaped("std"));
    try std.testing.expect(!pathShaped("builtin"));
    try std.testing.expect(!pathShaped("root"));
    try std.testing.expect(!pathShaped("guardian-fakes"));
}

// spec: Import Resolution - Resolves a path-shaped import against the importing file's directory

test "analyzeContent resolves relative imports and skips module names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const std = @import("std");
        \\const math = @import("../core/math.zig");
        \\const near = @import("helpers.zig");
    ;
    const out = try analyzeContent(a, "src/utils/thing.zig", content);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("src/core/math.zig", out[0].target);
    try std.testing.expectEqual(@as(u32, 2), out[0].line);
    try std.testing.expectEqualStrings("src/utils/helpers.zig", out[1].target);
}

// spec: Import Resolution - Skips an import that resolves above the project root

test "resolveTarget reports an escape above the root instead of clamping it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // walk.normalizePath would clamp this to "out.zig" and the check would then
    // report a file missing from a directory nobody named. Null is "not judged".
    try std.testing.expect(try resolveTarget(a, "src/a.zig", "../../out.zig") == null);
    try std.testing.expect(try resolveTarget(a, "src/a.zig", "/abs/out.zig") == null);
    // One level up from src/a.zig is still inside the project.
    const inside = (try resolveTarget(a, "src/a.zig", "../build_helper.zig")).?;
    try std.testing.expectEqualStrings("build_helper.zig", inside);
}

// spec: Import Resolution - Flags a path-shaped import with no file behind it

test "analyzeContent surfaces a fabricated sibling path for the stat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The hallucination shape: a helper that ought to exist and does not.
    const content =
        \\const strings = @import("strings_that_do_not_exist.zig");
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("src/strings_that_do_not_exist.zig", out[0].target);
    // Against the real tree that path is missing, which is the blocking verdict.
    var dir = try fs.cwd().openDir(".", .{});
    defer dir.close();
    try std.testing.expectEqual(Verdict.missing, classify(dir, out[0].target));
}

// spec: Import Resolution - Reports a directory named by an import as unresolved

test "classify separates a real file, a missing one, and a directory" {
    var dir = try fs.cwd().openDir(".", .{});
    defer dir.close();
    try std.testing.expectEqual(Verdict.resolved, classify(dir, "src/check.zig"));
    try std.testing.expectEqual(Verdict.missing, classify(dir, "src/definitely_absent.zig"));
    // `@import` needs a file; a directory that happens to sit at the path is
    // still an import that cannot compile.
    try std.testing.expectEqual(Verdict.directory, classify(dir, "src/checks"));
    // The stat behind `classify` never follows a final symlink, so the entry
    // answers for itself rather than for whatever it points at — which is what
    // keeps a symlinked module a legitimate import instead of a verdict about
    // some other project's file.
    const direct = try dir.statFileNoFollow("src/check.zig");
    try std.testing.expect(direct.kind == .file);
}

test "analyzeContent ignores an @import spelling inside a string or comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\// @import("ghost.zig")
        \\const s = "@import(\"ghost.zig\")";
    ;
    try std.testing.expectEqual(@as(usize, 0), (try analyzeContent(a, "src/x.zig", content)).len);
}
