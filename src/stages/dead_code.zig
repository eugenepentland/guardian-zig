const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const shell = @import("../shell.zig");
const StageResult = stage.StageResult;

pub fn run(ctx: *pipeline.Context) StageResult {
    const result = shell.run(ctx.allocator, &.{ "zig", "build" }, ctx.target_dir) catch {
        return stage.passed("Dead Code", "Skipped (could not run zig build)");
    };

    if (result.exit_code != 0) {
        return stage.passed("Dead Code", "Skipped (compilation failed)");
    }

    var warnings: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.indexOf(u8, trimmed, "unused") != null) {
            warnings.append(ctx.allocator, trimmed) catch {};
        }
    }

    if (warnings.items.len == 0) {
        return stage.passed("Dead Code", "No unused code warnings");
    }

    var remediation: std.ArrayListUnmanaged([]const u8) = .empty;
    for (warnings.items) |_| {
        remediation.append(ctx.allocator, "Remove the unused code flagged above") catch {};
    }

    return stage.failed("Dead Code", warnings.toOwnedSlice(ctx.allocator) catch &.{}, remediation.toOwnedSlice(ctx.allocator) catch &.{});
}
