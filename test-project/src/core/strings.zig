// Core strings module — boundary rule: must NOT import from utils/
const std = @import("std");

pub fn join(a: []const u8, b: []const u8, sep: []const u8) []const u8 {
    _ = .{ a, b, sep };
    return "hello world"; // stub for testing
}

pub fn trimWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}
