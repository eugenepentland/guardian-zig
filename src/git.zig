const std = @import("std");
const Allocator = std.mem.Allocator;
const shell = @import("shell.zig");

pub fn diffCachedNames(allocator: Allocator, dir: []const u8) ![]const []const u8 {
    const result = try shell.run(allocator, &.{ "git", "diff", "--cached", "--name-only" }, dir);
    if (result.exit_code != 0) return error.GitCommandFailed;
    return splitLines(allocator, result.stdout);
}

pub fn diffNames(allocator: Allocator, dir: []const u8) ![]const []const u8 {
    const result = try shell.run(allocator, &.{ "git", "diff", "--name-only", "HEAD" }, dir);
    if (result.exit_code != 0) return error.GitCommandFailed;
    return splitLines(allocator, result.stdout);
}

pub fn addAll(allocator: Allocator, dir: []const u8) !void {
    const result = try shell.run(allocator, &.{ "git", "add", "." }, dir);
    if (result.exit_code != 0) return error.GitCommandFailed;
}

pub fn commit(allocator: Allocator, dir: []const u8, message: []const u8) !void {
    const result = try shell.run(allocator, &.{ "git", "commit", "-m", message }, dir);
    if (result.exit_code != 0) return error.GitCommandFailed;
}

pub fn headHash(allocator: Allocator, dir: []const u8) ![]const u8 {
    const result = try shell.run(allocator, &.{ "git", "rev-parse", "HEAD" }, dir);
    if (result.exit_code != 0) return error.GitCommandFailed;
    return std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
}

fn splitLines(allocator: Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return &.{};

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, trimmed, '\n');
    while (iter.next()) |line| {
        const l = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (l.len > 0) {
            try lines.append(allocator, l);
        }
    }
    return lines.toOwnedSlice(allocator);
}
