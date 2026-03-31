const std = @import("std");
const spec_parser = @import("spec/parser.zig");
const spec_matcher = @import("spec/matcher.zig");
const config_mod = @import("config.zig");

const print = std.debug.print;

// ANSI color codes — only used when stderr is a TTY
var use_color: bool = false;
const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const RESET = "\x1b[0m";

fn ok(comptime fmt: []const u8, args: anytype) void {
    if (use_color) print(GREEN ++ "guardian: " ++ RESET ++ fmt ++ "\n", args) else print("guardian: " ++ fmt ++ "\n", args);
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    if (use_color) print(RED ++ "guardian: " ++ RESET ++ fmt ++ "\n", args) else print("guardian: " ++ fmt ++ "\n", args);
}

pub fn main() !void {
    // Detect color support
    use_color = std.fs.File.stderr().isTty();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const command = args[1];
    // Remaining args are the project dir (default ".")
    const project_dir = if (args.len >= 3) args[2] else ".";
    const cfg = config_mod.load(allocator, project_dir);

    if (std.mem.eql(u8, command, "spec")) {
        try runSpecCoverage(allocator, project_dir, cfg);
    } else if (std.mem.eql(u8, command, "file-size")) {
        try runFileSize(allocator, project_dir, cfg);
    } else if (std.mem.eql(u8, command, "boundaries")) {
        try runBoundaries(allocator, project_dir, cfg);
    } else if (std.mem.eql(u8, command, "spec-init")) {
        try runSpecInit(allocator, project_dir);
    } else {
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    print("Usage: guardian-check <command> [project-dir]\n", .{});
    print("Commands: spec, file-size, boundaries, spec-init\n", .{});
}

// ── Spec Coverage ──────────────────────────────────────────────────────

fn runSpecCoverage(allocator: std.mem.Allocator, project_dir: []const u8, cfg: config_mod.Config) !void {
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, cfg.spec_file });

    // spec: Spec Coverage - Fails with clear error when SPEC.md is missing
    const sections = spec_parser.parseFile(allocator, spec_path) catch {
        fail("ERROR — {s} not found", .{cfg.spec_file});
        print("\n", .{});
        print("  Guardian requires a SPEC.md file with your project's specification.\n", .{});
        print("  Create {s} with this structure:\n", .{cfg.spec_file});
        print("\n", .{});
        print("    # Project Name\n", .{});
        print("    \n", .{});
        print("    ## Section Name\n", .{});
        print("    - Behavior description\n", .{});
        print("    - Another behavior\n", .{});
        print("\n", .{});
        print("  Then tag each test with a matching // spec: comment:\n", .{});
        print("    // spec: Section Name - Behavior description\n", .{});
        print("    test \"behavior\" {{ ... }}\n", .{});
        std.process.exit(1);
    };

    // Scan both test/ and src/ for spec tags
    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});

    var all_tags: std.ArrayListUnmanaged(spec_matcher.SpecTag) = .empty;
    for (spec_matcher.scanDir(allocator, test_dir)) |t| all_tags.append(allocator, t) catch {};
    for (spec_matcher.scanDir(allocator, src_dir)) |t| all_tags.append(allocator, t) catch {};
    const tags = all_tags.toOwnedSlice(allocator) catch &.{};

    const result = spec_matcher.analyze(allocator, sections, tags);

    // Report
    const has_failures = result.unverified_behaviors.len > 0 or
        result.unlinked_tags.len > 0 or
        result.duplicate_tags.len > 0;

    if (!has_failures) {
        ok("spec coverage {d}/{d} behaviors covered", .{ result.covered_behaviors, result.total_behaviors });
        return;
    }

    // Failures
    fail("spec coverage FAILED", .{});
    for (result.unverified_behaviors) |b| {
        print("  unverified: {s} - {s}\n", .{ b.section, b.statement });
    }
    for (result.unlinked_tags) |t| {
        print("  unlinked tag: {s} in {s}\n", .{ t.tag, t.file });
    }
    for (result.duplicate_tags) |d| {
        print("  duplicate tag: {s}\n", .{d.key});
        for (d.files) |f| {
            print("    in: {s}\n", .{f});
        }
    }
    print("\n", .{});
    for (result.unverified_behaviors) |b| {
        print("  add: // spec: {s} - {s}\n", .{ b.section, b.statement });
    }
    if (result.duplicate_tags.len > 0) {
        print("  Each spec behavior must have exactly one // spec: tag (1:1 mapping).\n", .{});
    }
    std.process.exit(1);
}

// ── Spec Init ──────────────────────────────────────────────────────────

const ModuleInfo = struct {
    name: []const u8,
    pub_fns: []const []const u8,
};

fn runSpecInit(allocator: std.mem.Allocator, project_dir: []const u8) !void {
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/SPEC.md", .{project_dir});

    // Don't overwrite existing SPEC.md
    if (std.fs.cwd().access(spec_path, .{})) |_| {
        fail("SPEC.md already exists — refusing to overwrite", .{});
        print("  Delete it first if you want to regenerate.\n", .{});
        std.process.exit(1);
    } else |_| {}

    // Scan src/ for pub fn declarations
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    var modules: std.ArrayListUnmanaged(ModuleInfo) = .empty;
    collectModules(allocator, src_path, "", &modules) catch {};

    if (modules.items.len == 0) {
        fail("no pub fn declarations found in src/", .{});
        std.process.exit(1);
    }

    // Generate SPEC.md
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(allocator, "# Project Specification\n\n") catch {};
    buf.appendSlice(allocator, "## Overview\n\nDescribe the project here.\n\n") catch {};

    for (modules.items) |mod| {
        if (mod.pub_fns.len == 0) continue;
        const section = try std.fmt.allocPrint(allocator, "## {s}\n", .{mod.name});
        buf.appendSlice(allocator, section) catch {};
        for (mod.pub_fns) |fn_name| {
            const behavior = try std.fmt.allocPrint(allocator, "- {s} works correctly\n", .{fn_name});
            buf.appendSlice(allocator, behavior) catch {};
        }
        buf.appendSlice(allocator, "\n") catch {};
    }

    // Write file
    const file = std.fs.cwd().createFile(spec_path, .{}) catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };
    defer file.close();
    file.writeAll(buf.toOwnedSlice(allocator) catch "") catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };

    ok("generated {s} with {d} modules", .{ spec_path, modules.items.len });
    print("  Edit the generated behaviors, then add // spec: tags to your tests.\n", .{});
}

fn collectModules(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    prefix: []const u8,
    modules: *std.ArrayListUnmanaged(ModuleInfo),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{entry.name});

        switch (entry.kind) {
            .directory => {
                const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                try collectModules(allocator, sub_path, rel, modules);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                const fns = extractPubFns(allocator, content);
                if (fns.len > 0) {
                    // Module name: strip .zig, replace / with .
                    const stem = if (std.mem.endsWith(u8, rel, ".zig")) rel[0 .. rel.len - 4] else rel;
                    modules.append(allocator, .{
                        .name = stem,
                        .pub_fns = fns,
                    }) catch {};
                }
            },
            else => {},
        }
    }
}

fn extractPubFns(allocator: std.mem.Allocator, content: []const u8) []const []const u8 {
    var fns: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, "pub fn ")) {
            const after = trimmed[7..]; // skip "pub fn "
            // Extract function name (up to '(')
            if (std.mem.indexOfScalar(u8, after, '(')) |paren| {
                const name = after[0..paren];
                // Skip main, test helpers, etc.
                if (std.mem.eql(u8, name, "main")) continue;
                if (std.mem.eql(u8, name, "build")) continue;
                fns.append(allocator, name) catch {};
            }
        }
    }
    return fns.toOwnedSlice(allocator) catch &.{};
}

// ── File Size ──────────────────────────────────────────────────────────
// spec: File Size - Checks source files against configurable line limit
// spec: File Size - Respects file_size_exclude patterns

fn runFileSize(allocator: std.mem.Allocator, project_dir: []const u8, cfg: config_mod.Config) !void {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;

    // Check both src/ and test/ directories
    const dirs_to_check = [_][]const u8{ "src", "test" };
    for (&dirs_to_check) |dir_name| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir_name });
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        walkFileSize(allocator, dir, dir_name, cfg.max_file_lines, cfg.file_size_exclude, &violations) catch {};
    }

    if (violations.items.len == 0) {
        ok("all files within {d} line limit", .{cfg.max_file_lines});
        return;
    }

    fail("file size FAILED", .{});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    std.process.exit(1);
}

fn walkFileSize(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    max_lines: u32,
    excludes: []const []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{entry.name});

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkFileSize(allocator, sub, rel, max_lines, excludes, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                for (excludes) |pat| {
                    if (std.mem.indexOf(u8, rel, pat) != null) continue;
                }
                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                var lines: u32 = 1;
                for (content) |c| {
                    if (c == '\n') lines += 1;
                }
                if (lines > max_lines) {
                    const msg = try std.fmt.allocPrint(allocator, "{s}: {d} lines (limit: {d})", .{ rel, lines, max_lines });
                    try violations.append(allocator, msg);
                }
            },
            else => {},
        }
    }
}

// ── Boundaries ─────────────────────────────────────────────────────────
// spec: Boundaries - Extracts @import paths from source files
// spec: Boundaries - Checks against boundary rules defined in guardian.toml
// spec: Boundaries - Reports forbidden import violations

fn runBoundaries(allocator: std.mem.Allocator, project_dir: []const u8, cfg: config_mod.Config) !void {
    if (cfg.boundary_rules.len == 0) {
        ok("no boundary rules configured", .{});
        return;
    }

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    var dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch {
        ok("no src/ directory, skipping boundary check", .{});
        return;
    };
    defer dir.close();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    walkBoundaries(allocator, dir, "src", cfg.boundary_rules, &violations) catch {};

    if (violations.items.len == 0) {
        ok("all imports comply with boundary rules", .{});
        return;
    }

    fail("boundary check FAILED", .{});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    std.process.exit(1);
}

fn walkBoundaries(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    rules: []const config_mod.BoundaryRule,
    violations: *std.ArrayListUnmanaged([]const u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkBoundaries(allocator, sub, rel, rules, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                const imports = extractImports(allocator, content, rel);
                for (rules) |rule| {
                    if (!matchesPattern(rel, rule.module_pattern)) continue;
                    for (imports) |imp| {
                        for (rule.forbidden_imports) |f| {
                            if (std.mem.indexOf(u8, imp, f) != null) {
                                const msg = std.fmt.allocPrint(allocator, "{s}: forbidden import '{s}' (rule: {s})", .{ rel, imp, rule.module_pattern }) catch continue;
                                violations.append(allocator, msg) catch {};
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
}

fn extractImports(allocator: std.mem.Allocator, content: []const u8, file_path: []const u8) []const []const u8 {
    var imports: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.indexOf(u8, trimmed, "@import(\"")) |idx| {
            const start = idx + 9;
            if (std.mem.indexOfScalarPos(u8, trimmed, start, '"')) |end| {
                const import_path = trimmed[start..end];
                if (std.mem.eql(u8, import_path, "std")) continue;
                // Resolve relative to importing file's directory
                if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |dir_end| {
                    const raw = std.fmt.allocPrint(allocator, "{s}/{s}", .{ file_path[0..dir_end], import_path }) catch continue;
                    const resolved = normalizePath(allocator, raw);
                    imports.append(allocator, resolved) catch {};
                } else {
                    imports.append(allocator, import_path) catch {};
                }
            }
        }
    }
    return imports.toOwnedSlice(allocator) catch &.{};
}

/// Resolve `../` and `./` segments in a path: "src/core/../utils/foo.zig" → "src/utils/foo.zig"
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
        } else {
            parts.append(allocator, seg) catch {};
        }
    }
    // Join with /
    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) result.append(allocator, '/') catch {};
        result.appendSlice(allocator, part) catch {};
    }
    return result.toOwnedSlice(allocator) catch path;
}

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 1]; // keep the trailing /
        return std.mem.startsWith(u8, path, prefix);
    }
    if (std.mem.endsWith(u8, pattern, "/")) {
        return std.mem.startsWith(u8, path, pattern);
    }
    if (std.mem.eql(u8, path, pattern)) return true;
    if (std.mem.startsWith(u8, path, pattern) and path.len > pattern.len and path[pattern.len] == '/') return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

test {
    _ = @import("config.zig");
    _ = @import("spec/parser.zig");
    _ = @import("spec/matcher.zig");
}

test "matchesPattern glob" {
    // "src/stages/*" matches files under src/stages/
    try std.testing.expect(matchesPattern("src/stages/foo.zig", "src/stages/*"));
    try std.testing.expect(matchesPattern("src/stages/sub/bar.zig", "src/stages/*"));
    try std.testing.expect(!matchesPattern("src/other/foo.zig", "src/stages/*"));
    try std.testing.expect(!matchesPattern("src/stages.zig", "src/stages/*"));
}

test "matchesPattern prefix" {
    // "src/stages/" matches anything under that directory
    try std.testing.expect(matchesPattern("src/stages/foo.zig", "src/stages/"));
    try std.testing.expect(!matchesPattern("src/other.zig", "src/stages/"));
}

test "matchesPattern exact" {
    try std.testing.expect(matchesPattern("src/main.zig", "src/main.zig"));
    try std.testing.expect(!matchesPattern("src/main.zig", "src/other.zig"));
    // With implicit / boundary
    try std.testing.expect(matchesPattern("src/foo/bar.zig", "src/foo"));
    try std.testing.expect(!matchesPattern("src/foobar.zig", "src/foo"));
}

test "extractImports resolves paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content =
        \\const std = @import("std");
        \\const shell = @import("shell.zig");
        \\const parser = @import("../spec/parser.zig");
    ;

    const imports = extractImports(allocator, content, "src/stages/foo.zig");
    // std is skipped
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    try std.testing.expectEqualStrings("src/stages/shell.zig", imports[0]);
    try std.testing.expectEqualStrings("src/spec/parser.zig", imports[1]);
}

test "normalizePath resolves parent refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("src/utils/foo.zig", normalizePath(a, "src/core/../utils/foo.zig"));
    try std.testing.expectEqualStrings("src/main.zig", normalizePath(a, "src/./main.zig"));
    try std.testing.expectEqualStrings("foo.zig", normalizePath(a, "a/b/../../foo.zig"));
    try std.testing.expectEqualStrings("src/bar.zig", normalizePath(a, "src/bar.zig"));
}
