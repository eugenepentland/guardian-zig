const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const config = @import("../config.zig");
const StageResult = stage.StageResult;

pub fn run(ctx: *pipeline.Context) StageResult {
    if (ctx.config.boundary_rules.len == 0) {
        return stage.passed("Boundaries", "No boundary rules configured");
    }

    const src_path = std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.target_dir}) catch
        return stage.passed("Boundaries", "Could not check src/");

    var dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch
        return stage.passed("Boundaries", "No src/ directory");
    defer dir.close();

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    walkAndCheck(ctx.allocator, dir, "src", ctx.config.boundary_rules, &violations) catch {};

    if (violations.items.len == 0) {
        return stage.passed("Boundaries", "All imports comply with boundary rules");
    }

    var remediation: std.ArrayListUnmanaged([]const u8) = .empty;
    for (violations.items) |_| {
        remediation.append(ctx.allocator, "Remove or restructure the forbidden import") catch {};
    }

    return stage.failed("Boundaries", violations.toOwnedSlice(ctx.allocator) catch &.{}, remediation.toOwnedSlice(ctx.allocator) catch &.{});
}

fn walkAndCheck(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    rules: []const config.BoundaryRule,
    violations: *std.ArrayListUnmanaged([]const u8),
) !void {
    var walker = dir.iterate();
    while (try walker.next()) |entry| {
        const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try walkAndCheck(allocator, sub, rel_path, rules, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

                const content = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
                const imports = extractImports(allocator, content, rel_path);

                for (rules) |rule| {
                    if (!matchesPattern(rel_path, rule.module_pattern)) continue;

                    for (imports) |imp| {
                        if (isForbidden(imp, rule.forbidden_imports)) {
                            const msg = std.fmt.allocPrint(allocator, "{s}: forbidden import '{s}' (rule: {s} cannot import {s})", .{
                                rel_path, imp, rule.module_pattern, rule.forbidden_imports[0],
                            }) catch continue;
                            violations.append(allocator, msg) catch {};
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
            const start = idx + 9; // len of @import("
            if (std.mem.indexOfScalarPos(u8, trimmed, start, '"')) |end| {
                const import_path = trimmed[start..end];
                if (std.mem.eql(u8, import_path, "std")) continue;
                const resolved = resolveImport(allocator, file_path, import_path) catch continue;
                imports.append(allocator, resolved) catch {};
            }
        }
    }
    return imports.toOwnedSlice(allocator) catch &.{};
}

fn resolveImport(allocator: std.mem.Allocator, from_file: []const u8, import_path: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, import_path, ".") and std.mem.indexOfScalar(u8, import_path, '/') == null) {
        if (std.mem.lastIndexOfScalar(u8, from_file, '/')) |dir_end| {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ from_file[0..dir_end], import_path });
        }
        return import_path;
    }

    if (std.mem.lastIndexOfScalar(u8, from_file, '/')) |dir_end| {
        const dir = from_file[0..dir_end];
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, import_path });
    }

    return import_path;
}

fn matchesPattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 2];
        return std.mem.startsWith(u8, path, prefix);
    }
    if (std.mem.endsWith(u8, pattern, "/")) {
        return std.mem.startsWith(u8, path, pattern);
    }
    if (std.mem.eql(u8, path, pattern)) return true;
    if (std.mem.startsWith(u8, path, pattern) and path.len > pattern.len and path[pattern.len] == '/') return true;
    return false;
}

fn isForbidden(import_path: []const u8, forbidden: []const []const u8) bool {
    for (forbidden) |f| {
        if (std.mem.indexOf(u8, import_path, f) != null) return true;
    }
    return false;
}
