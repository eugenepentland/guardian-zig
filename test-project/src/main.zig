const std = @import("std");
const math = @import("core/math.zig");
const strings = @import("core/strings.zig");

pub fn main() !void {
    const result = math.add(2, 3);
    std.debug.print("2 + 3 = {d}\n", .{result});

    const product = math.multiply(4, 5);
    std.debug.print("4 * 5 = {d}\n", .{product});
}

// spec: Math - Adds two numbers correctly
test "add" {
    try std.testing.expectEqual(@as(i32, 5), math.add(2, 3));
    try std.testing.expectEqual(@as(i32, 0), math.add(-1, 1));
}

// spec: Math - Multiplies two numbers correctly
test "multiply" {
    try std.testing.expectEqual(@as(i32, 20), math.multiply(4, 5));
    try std.testing.expectEqual(@as(i32, 0), math.multiply(0, 99));
}

// spec: Strings - Concatenates strings with separator
test "join" {
    const result = strings.join("hello", "world", " ");
    try std.testing.expectEqualStrings("hello world", result);
}

test {
    _ = @import("core/math.zig");
    _ = @import("core/strings.zig");
}
