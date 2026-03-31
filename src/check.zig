const std = @import("std");
const spec_parser = @import("spec/parser.zig");
const spec_matcher = @import("spec/matcher.zig");
const config_mod = @import("config.zig");

const print = std.debug.print;

pub fn main() !void {
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
    } else {
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    print("Usage: guardian-check <command> [project-dir]\n", .{});
    print("Commands: spec, file-size, boundaries\n", .{});
}

// ── Spec Coverage ──────────────────────────────────────────────────────

fn runSpecCoverage(allocator: std.mem.Allocator, project_dir: []const u8, cfg: config_mod.Config) !void {
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, cfg.spec_file });

    // spec: Spec Coverage - Fails with clear error when SPEC.md is missing
    const sections = spec_parser.parseFile(allocator, spec_path) catch {
        print("guardian: ERROR — {s} not found\n", .{cfg.spec_file});
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
        print("guardian: spec coverage {d}/{d} behaviors covered\n", .{ result.covered_behaviors, result.total_behaviors });
        return;
    }

    // Failures
    print("guardian: spec coverage FAILED\n", .{});
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

// ── File Size ──────────────────────────────────────────────────────────
// spec: File Size - Checks source files against configurable line limit
// spec: File Size - Respects file_size_exclude patterns

fn runFileSize(allocator: std.mem.Allocator, project_dir: []const u8, cfg: config_mod.Config) !void {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});

    var dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch {
        print("guardian: no src/ directory, skipping file size check\n", .{});
        return;
    };
    defer dir.close();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    walkFileSize(allocator, dir, "", cfg.max_file_lines, cfg.file_size_exclude, &violations) catch {};

    if (violations.items.len == 0) {
        print("guardian: all files within {d} line limit\n", .{cfg.max_file_lines});
        return;
    }

    print("guardian: file size FAILED\n", .{});
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
                    const msg = try std.fmt.allocPrint(allocator, "src/{s}: {d} lines (limit: {d})", .{ rel, lines, max_lines });
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
        print("guardian: no boundary rules configured\n", .{});
        return;
    }

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    var dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch {
        print("guardian: no src/ directory, skipping boundary check\n", .{});
        return;
    };
    defer dir.close();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    walkBoundaries(allocator, dir, "src", cfg.boundary_rules, &violations) catch {};

    if (violations.items.len == 0) {
        print("guardian: all imports comply with boundary rules\n", .{});
        return;
    }

    print("guardian: boundary check FAILED\n", .{});
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
                    const resolved = std.fmt.allocPrint(allocator, "{s}/{s}", .{ file_path[0..dir_end], import_path }) catch continue;
                    imports.append(allocator, resolved) catch {};
                } else {
                    imports.append(allocator, import_path) catch {};
                }
            }
        }
    }
    return imports.toOwnedSlice(allocator) catch &.{};
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
    try std.testing.expectEqualStrings("src/stages/../spec/parser.zig", imports[1]);
}
