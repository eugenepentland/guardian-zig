//! Preflight for generated or otherwise mandatory project inputs. It runs
//! before analysis so an incomplete worktree cannot prune trustworthy debt.

const std = @import("std");
const walk = @import("walk.zig");
const reporter = @import("reporter.zig");
const types = @import("cli/types.zig");

/// Fails before project analysis when any configured exact path or `*` glob
/// matches no filesystem entry beneath the project directory.
pub fn validate(ctx: *types.RunCtx) types.RunError!void {
    const required = ctx.cfg.required_inputs;
    if (required.len == 0) return;

    var root = std.fs.cwd().openDir(ctx.project_dir, .{ .iterate = true }) catch |err| {
        reporter.fail("required-input preflight could not open {s}: {s}", .{ ctx.project_dir, @errorName(err) });
        return error.CheckFailed;
    };
    defer root.close();

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(ctx.allocator);
    for (required) |pattern| {
        const exists = patternExists(ctx.allocator, root, pattern) catch |err| {
            reporter.fail("required-input preflight could not scan {s}: {s}", .{ pattern, @errorName(err) });
            return error.CheckFailed;
        };
        if (!exists) try missing.append(ctx.allocator, pattern);
    }

    if (missing.items.len == 0) return;
    reporter.fail("required-input preflight FAILED ({d} unmatched pattern(s))", .{missing.items.len});
    for (missing.items) |pattern| reporter.detail("  missing: {s}\n", .{pattern});
    reporter.detail("  fix: generate or restore the inputs before Guardian runs, or correct `required_inputs`\n", .{});
    return error.CheckFailed;
}

fn patternExists(allocator: std.mem.Allocator, root: std.fs.Dir, pattern: []const u8) !bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        root.access(pattern, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    };
    const prefix = pattern[0..star];
    const scan_root = if (std.mem.lastIndexOfScalar(u8, prefix, '/')) |slash|
        prefix[0..slash]
    else
        ".";
    var dir = root.openDir(scan_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        const joined = if (std.mem.eql(u8, scan_root, "."))
            try std.fmt.allocPrint(allocator, "{s}", .{entry.path})
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scan_root, entry.path });
        defer allocator.free(joined);
        if (std.fs.path.sep != '/') {
            for (joined) |*c| if (c.* == std.fs.path.sep) {
                c.* = '/';
            };
        }
        if (matches(joined, pattern)) return true;
    }
    return false;
}

fn markMatches(required: []const []const u8, found: []bool, path: []const u8) usize {
    var newly_found: usize = 0;
    for (required, found) |pattern, *matched| {
        if (matched.* or !matches(path, pattern)) continue;
        matched.* = true;
        newly_found += 1;
    }
    return newly_found;
}

fn matches(path: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') != null) return walk.matchGlob(path, pattern);
    return std.mem.eql(u8, path, pattern);
}

fn missingFromPaths(
    allocator: std.mem.Allocator,
    required: []const []const u8,
    paths: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const found = try allocator.alloc(bool, required.len);
    @memset(found, false);
    for (paths) |path| _ = markMatches(required, found, path);
    var missing: std.ArrayList([]const u8) = .empty;
    for (required, found) |pattern, matched| {
        if (!matched) try missing.append(allocator, pattern);
    }
    return missing.toOwnedSlice(allocator);
}

// spec: Required Inputs - Fails before project analysis when a required input pattern matches nothing

test "required input matching supports exact paths and globs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const missing = try missingFromPaths(
        arena.allocator(),
        &.{ "src/generated/*.zig", "assets/schema.json", "missing.dat" },
        &.{ "src/generated/page.zig", "assets/schema.json", "assets/schema.json.bak" },
    );
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("missing.dat", missing[0]);
}

test "patternExists scans only the fixed glob prefix" {
    const dir_path = "zig-cache/test-required-inputs";
    std.fs.cwd().deleteTree(dir_path) catch {};
    defer std.fs.cwd().deleteTree(dir_path) catch {};
    try std.fs.cwd().makePath(dir_path ++ "/src/generated");
    var file = try std.fs.cwd().createFile(dir_path ++ "/src/generated/page.zig", .{});
    file.close();

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    try std.testing.expect(try patternExists(std.testing.allocator, dir, "src/generated/*.zig"));
    try std.testing.expect(try patternExists(std.testing.allocator, dir, "src/generated/page.zig"));
    try std.testing.expect(!try patternExists(std.testing.allocator, dir, "src/generated/*.json"));
}

test "validate blocks an unmatched required input before analysis" {
    const dir_path = "zig-cache/test-required-input-validation";
    std.fs.cwd().deleteTree(dir_path) catch {};
    defer std.fs.cwd().deleteTree(dir_path) catch {};
    try std.fs.cwd().makePath(dir_path);
    const cfg: @import("config.zig").Config = .{ .required_inputs = &.{"src/generated/*.zig"} };
    var ctx: types.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = dir_path,
        .cfg = &cfg,
        .quiet = true,
    };
    var capture: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &capture;
    try std.testing.expectError(error.CheckFailed, validate(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, capture.buf.items, "src/generated/*.zig") != null);
}
