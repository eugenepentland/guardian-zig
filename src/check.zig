const std = @import("std");
const spec_parser = @import("spec/parser.zig");
const spec_matcher = @import("spec/matcher.zig");
const spec_init = @import("spec/init.zig");
const config_mod = @import("config.zig");

const print = std.debug.print;

// Output control
var use_color: bool = false;
var quiet: bool = false;
const GREEN = "\x1b[32m";
const RED = "\x1b[31m";
const RESET = "\x1b[0m";

fn ok(comptime fmt: []const u8, args: anytype) void {
    if (quiet) return;
    if (use_color) print(GREEN ++ "guardian: " ++ RESET ++ fmt ++ "\n", args) else print("guardian: " ++ fmt ++ "\n", args);
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    if (use_color) print(RED ++ "guardian: " ++ RESET ++ fmt ++ "\n", args) else print("guardian: " ++ fmt ++ "\n", args);
}

pub fn main() !void {
    use_color = std.fs.File.stderr().isTty();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    var command: ?[]const u8 = null;
    var project_dir: []const u8 = ".";
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (command == null) {
            command = arg;
        } else {
            project_dir = arg;
        }
    }
    if (command == null) {
        printUsage();
        std.process.exit(1);
    }
    const cfg = config_mod.load(allocator, project_dir);

    const cmd = command.?;
    if (std.mem.eql(u8, cmd, "spec")) {
        try runSpecCoverage(allocator, project_dir, cfg);
    } else if (std.mem.eql(u8, cmd, "file-size")) {
        try runFileSize(allocator, project_dir, cfg);
    } else if (std.mem.eql(u8, cmd, "boundaries")) {
        try runBoundaries(allocator, project_dir, cfg);
    } else if (std.mem.eql(u8, cmd, "spec-init")) {
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

    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});

    var all_tags: std.ArrayListUnmanaged(spec_matcher.SpecTag) = .empty;
    for (spec_matcher.scanDir(allocator, test_dir)) |t| all_tags.append(allocator, t) catch {};
    for (spec_matcher.scanDir(allocator, src_dir)) |t| all_tags.append(allocator, t) catch {};
    const tags = all_tags.toOwnedSlice(allocator) catch &.{};

    const result = spec_matcher.analyze(allocator, sections, tags);

    const has_failures = result.unverified_behaviors.len > 0 or
        result.unlinked_tags.len > 0 or
        result.duplicate_tags.len > 0;

    if (!has_failures) {
        ok("spec coverage {d}/{d} behaviors covered", .{ result.covered_behaviors, result.total_behaviors });
        return;
    }

    fail("spec coverage FAILED ({d}/{d} covered, {d} unverified, {d} unlinked, {d} duplicate)", .{
        result.covered_behaviors,
        result.total_behaviors,
        result.unverified_behaviors.len,
        result.unlinked_tags.len,
        result.duplicate_tags.len,
    });
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
// spec: Spec Lifecycle - Generates starter SPEC.md from pub fn signatures via spec-init

fn runSpecInit(allocator: std.mem.Allocator, project_dir: []const u8) !void {
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/SPEC.md", .{project_dir});

    if (std.fs.cwd().access(spec_path, .{})) |_| {
        fail("SPEC.md already exists — refusing to overwrite", .{});
        print("  Delete it first if you want to regenerate.\n", .{});
        std.process.exit(1);
    } else |_| {}

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    var modules: std.ArrayListUnmanaged(spec_init.ModuleInfo) = .empty;
    spec_init.collectModules(allocator, src_path, "", &modules) catch {};

    if (modules.items.len == 0) {
        fail("no pub fn declarations found in src/", .{});
        std.process.exit(1);
    }

    const content = spec_init.generateSpecContent(allocator, modules.items);
    const file = std.fs.cwd().createFile(spec_path, .{}) catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };
    defer file.close();
    file.writeAll(content) catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };

    ok("generated {s} with {d} modules", .{ spec_path, modules.items.len });
    print("  Edit the generated behaviors, then add // spec: tags to your tests.\n", .{});
}

// ── File Size ──────────────────────────────────────────────────────────
// spec: File Size - Checks source files against configurable line limit
// spec: File Size - Respects file_size_exclude patterns

fn runFileSize(allocator: std.mem.Allocator, project_dir: []const u8, cfg: config_mod.Config) !void {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;

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

    fail("file size FAILED ({d} file(s) over {d} line limit)", .{ violations.items.len, cfg.max_file_lines });
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    std.process.exit(1);
}

// ── Boundaries ─────────────────────────────────────────────────────────
// spec: Boundaries - Extracts @import paths from source files and normalizes relative paths
// spec: Boundaries - Matches file paths against glob and prefix boundary patterns
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

    fail("boundary check FAILED ({d} violation(s))", .{violations.items.len});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    std.process.exit(1);
}

// ── Analysis helpers ───────────────────────────────────────────────────

fn matchGlob(text: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        return std.mem.indexOf(u8, text, pattern) != null;
    }
    var ti: usize = 0;
    var parts = std.mem.splitScalar(u8, pattern, '*');
    var first = true;
    while (parts.next()) |part| {
        if (part.len == 0) {
            first = false;
            continue;
        }
        if (first) {
            if (!std.mem.startsWith(u8, text[ti..], part)) return false;
            ti += part.len;
            first = false;
        } else {
            if (std.mem.indexOf(u8, text[ti..], part)) |idx| {
                ti += idx + part.len;
            } else {
                return false;
            }
        }
    }
    if (std.mem.endsWith(u8, pattern, "*")) return true;
    return ti == text.len;
}

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
    var result: std.ArrayListUnmanaged(u8) = .empty;
    for (parts.items, 0..) |part, i| {
        if (i > 0) result.append(allocator, '/') catch {};
        result.appendSlice(allocator, part) catch {};
    }
    return result.toOwnedSlice(allocator) catch path;
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
                if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |dir_end| {
                    const raw = std.fmt.allocPrint(allocator, "{s}/{s}", .{ file_path[0..dir_end], import_path }) catch continue;
                    imports.append(allocator, normalizePath(allocator, raw)) catch {};
                } else {
                    imports.append(allocator, import_path) catch {};
                }
            }
        }
    }
    return imports.toOwnedSlice(allocator) catch &.{};
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
                const excluded = blk: {
                    for (excludes) |pat| {
                        if (matchGlob(rel, pat)) break :blk true;
                    }
                    break :blk false;
                };
                if (excluded) continue;
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
                    if (!matchGlob(rel, rule.module_pattern)) continue;
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

// ── Tests ──────────────────────────────────────────────────────────────

test {
    _ = @import("config.zig");
    _ = @import("spec/parser.zig");
    _ = @import("spec/matcher.zig");
    _ = @import("spec/init.zig");
}

test "matchGlob boundary patterns" {
    try std.testing.expect(matchGlob("src/stages/foo.zig", "src/stages/*"));
    try std.testing.expect(matchGlob("src/stages/sub/bar.zig", "src/stages/*"));
    try std.testing.expect(!matchGlob("src/other/foo.zig", "src/stages/*"));
    try std.testing.expect(!matchGlob("src/stages.zig", "src/stages/*"));
    try std.testing.expect(matchGlob("src/stages/foo.zig", "src/stages/"));
    try std.testing.expect(!matchGlob("src/other.zig", "src/stages/"));
    try std.testing.expect(matchGlob("src/main.zig", "src/main.zig"));
    try std.testing.expect(!matchGlob("src/main.zig", "src/other.zig"));
    try std.testing.expect(matchGlob("src/foo/bar.zig", "src/foo"));
}

test "matchGlob wildcards" {
    try std.testing.expect(matchGlob("src/core/math.zig", "math"));
    try std.testing.expect(!matchGlob("src/core/math.zig", "xyz"));
    try std.testing.expect(matchGlob("src/generated/output.zig", "*/output.zig"));
    try std.testing.expect(matchGlob("src/generated/foo.zig", "src/generated/*"));
    try std.testing.expect(!matchGlob("src/core/foo.zig", "src/generated/*"));
    try std.testing.expect(matchGlob("src/core/math.zig", "src/*/math.zig"));
    try std.testing.expect(matchGlob("a/b/c/d.zig", "a/*/c/*"));
    try std.testing.expect(matchGlob("anything", "*"));
}

test "extractImports resolves paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const std = @import("std");
        \\const shell = @import("shell.zig");
        \\const parser = @import("../spec/parser.zig");
    ;
    const imports = extractImports(a, content, "src/stages/foo.zig");
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
}

test "walkFileSize finds violations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    defer dir.close();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    try walkFileSize(a, dir, "src", 10, &.{}, &violations);
    try std.testing.expect(violations.items.len >= 3);
}

test "walkFileSize respects excludes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    defer dir.close();
    var without: std.ArrayListUnmanaged([]const u8) = .empty;
    try walkFileSize(a, dir, "src", 10, &.{}, &without);

    dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    var with: std.ArrayListUnmanaged([]const u8) = .empty;
    try walkFileSize(a, dir, "src", 10, &.{"main"}, &with);
    try std.testing.expect(with.items.len < without.items.len);
}

test "walkBoundaries detects violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = std.fs.cwd().openDir("test-project/src", .{ .iterate = true }) catch return;
    defer dir.close();
    const rules = &[_]config_mod.BoundaryRule{
        .{ .module_pattern = "src/core/*", .forbidden_imports = &.{"utils"} },
    };
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    walkBoundaries(a, dir, "src", rules, &violations) catch return;
    try std.testing.expect(violations.items.len > 0);
}
