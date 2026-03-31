const std = @import("std");
const Allocator = std.mem.Allocator;
const pipeline = @import("pipeline.zig");

pub fn writeFeedback(allocator: Allocator, dir: []const u8, result: pipeline.PipelineResult) void {
    const content = buildFeedback(allocator, result);
    const path = std.fmt.allocPrint(allocator, "{s}/GUARDIAN_FEEDBACK.md", .{dir}) catch return;
    const cwd = std.fs.cwd();
    const file = cwd.createFile(path, .{}) catch return;
    defer file.close();
    file.writeAll(content) catch {};
}

fn buildFeedback(allocator: Allocator, result: pipeline.PipelineResult) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    appendStr(allocator, &buf, "# Guardian Feedback\n\n");
    appendStr(allocator, &buf, "**Status:** REJECTED\n\n");
    appendFmt(allocator, &buf, "**Failed stage:** {s}\n\n", .{result.failed_stage});
    appendStr(allocator, &buf, "## Stage Results\n\n");

    for (result.stages) |s| {
        switch (s) {
            .passed => |p| {
                appendFmt(allocator, &buf, "### \xe2\x9c\x93 {s}\n{s}\n\n", .{ p.name, p.detail });
            },
            .failed => |f| {
                appendFmt(allocator, &buf, "### \xe2\x9c\x97 {s}\n\n**Issues:**\n", .{f.name});
                for (f.issues) |issue| {
                    appendFmt(allocator, &buf, "- {s}\n", .{issue});
                }
                appendStr(allocator, &buf, "\n**Remediation:**\n");
                for (f.remediation) |rem| {
                    appendFmt(allocator, &buf, "- {s}\n", .{rem});
                }
                appendStr(allocator, &buf, "\n");
            },
        }
    }

    return buf.toOwnedSlice(allocator) catch "";
}

fn appendStr(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    buf.appendSlice(allocator, s) catch {};
}

fn appendFmt(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(allocator, fmt, args) catch return;
    buf.appendSlice(allocator, s) catch {};
}
