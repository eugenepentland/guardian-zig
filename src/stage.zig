const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StageResult = union(enum) {
    passed: Passed,
    failed: Failed,
};

pub const Passed = struct {
    name: []const u8,
    detail: []const u8,
};

pub const Failed = struct {
    name: []const u8,
    issues: []const []const u8,
    remediation: []const []const u8,
};

pub fn passed(name: []const u8, detail: []const u8) StageResult {
    return .{ .passed = .{ .name = name, .detail = detail } };
}

pub fn failed(name: []const u8, issues: []const []const u8, remediation: []const []const u8) StageResult {
    return .{ .failed = .{ .name = name, .issues = issues, .remediation = remediation } };
}

pub fn failedAlloc(allocator: std.mem.Allocator, name: []const u8, issue: []const u8, remediation_text: []const u8) StageResult {
    const issues = allocator.alloc([]const u8, 1) catch return failed(name, &.{}, &.{});
    issues[0] = issue;
    const rems = allocator.alloc([]const u8, 1) catch return failed(name, &.{}, &.{});
    rems[0] = remediation_text;
    return .{ .failed = .{ .name = name, .issues = issues, .remediation = rems } };
}
