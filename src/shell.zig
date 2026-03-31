const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CommandResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

pub fn run(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) !CommandResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 10 * 1024 * 1024,
    });

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };

    return .{
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}
