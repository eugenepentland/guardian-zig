const std = @import("std");
const Allocator = std.mem.Allocator;

const print = std.debug.print;

pub const UPDATE_ENV = "GUARDIAN_UPDATE_GOLDEN";

/// Errors propagated by `run` / `runWithCfg`. Aliasing anyerror so the
/// signatures pass the error-discipline check while still accepting
/// arbitrary errors from the analyze callback.
pub const GoldenError = anyerror;

/// One golden test scenario: an input file pinned via @embedFile and the
/// expected violation output. `expected_path` is a writable disk path
/// (relative to the project root) used when GUARDIAN_UPDATE_GOLDEN=1
/// is set, so callers can regenerate baselines without hand-editing.
pub const Scenario = struct {
    /// Logical name of the check (used only in failure messages).
    check_name: []const u8,
    /// Logical name of the scenario (used only in failure messages).
    name: []const u8,
    /// Source under test, embedded at compile time.
    input: []const u8,
    /// Expected violation output, embedded at compile time. Sorted lines
    /// joined with `\n` and a trailing newline. Empty = pass.
    expected: []const u8,
    /// Disk path to expected.txt for regeneration. Relative to the
    /// project root (CWD during `zig build test`).
    expected_path: []const u8,
};

/// Returns true if the user set GUARDIAN_UPDATE_GOLDEN=1.
fn shouldUpdate(allocator: Allocator) bool {
    const v = std.process.getEnvVarOwned(allocator, UPDATE_ENV) catch return false;
    defer allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Joins `lines` (sorted) with `\n` and appends a trailing newline if
/// non-empty, so empty == "" and "a", "b" => "a\nb\n". The lines are
/// sorted in place.
fn formatViolations(allocator: Allocator, lines: [][]const u8) ![]const u8 {
    if (lines.len == 0) return "";
    std.mem.sort([]const u8, lines, {}, lessThan);
    var buf: std.ArrayList(u8) = .empty;
    for (lines, 0..) |line, i| {
        if (i > 0) try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, line);
    }
    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

/// Runs `analyzeFn` against `s.input`, formats violations, and asserts
/// they match `s.expected`. When GUARDIAN_UPDATE_GOLDEN=1, writes the
/// new output to `s.expected_path` instead and skips the assertion.
///
/// `analyzeFn` is comptime so callers can pass any check's
/// `analyzeContent(allocator, rel_path, content) ![]const []const u8`.
pub fn run(allocator: Allocator, s: Scenario, comptime analyzeFn: anytype) GoldenError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const violations_const = try analyzeFn(a, "input.zig", s.input);
    const violations = try a.dupe([]const u8, violations_const);
    const actual = try formatViolations(a, violations);

    if (shouldUpdate(a)) {
        try writeFileAtomic(s.expected_path, actual);
        print("UPDATED {s}\n", .{s.expected_path});
        return;
    }

    std.testing.expectEqualStrings(s.expected, actual) catch |e| {
        print(
            "\ngolden mismatch [{s}/{s}]\n  expected_path: {s}\n  re-run with {s}=1 to refresh.\n",
            .{ s.check_name, s.name, s.expected_path, UPDATE_ENV },
        );
        return e;
    };
}

/// Same as `run` but for checks whose analyze takes an extra config struct.
pub fn runWithCfg(allocator: Allocator, s: Scenario, comptime analyzeFn: anytype, cfg: anytype) GoldenError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const violations_const = try analyzeFn(a, "input.zig", s.input, cfg);
    const violations = try a.dupe([]const u8, violations_const);
    const actual = try formatViolations(a, violations);

    if (shouldUpdate(a)) {
        try writeFileAtomic(s.expected_path, actual);
        print("UPDATED {s}\n", .{s.expected_path});
        return;
    }

    std.testing.expectEqualStrings(s.expected, actual) catch |e| {
        print(
            "\ngolden mismatch [{s}/{s}]\n  expected_path: {s}\n  re-run with {s}=1 to refresh.\n",
            .{ s.check_name, s.name, s.expected_path, UPDATE_ENV },
        );
        return e;
    };
}

fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

test "formatViolations empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines: [0][]const u8 = undefined;
    const out = try formatViolations(a, &lines);
    try std.testing.expectEqualStrings("", out);
}

test "formatViolations sorts and trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lines = [_][]const u8{ "zeta", "alpha", "mu" };
    const out = try formatViolations(a, &lines);
    try std.testing.expectEqualStrings("alpha\nmu\nzeta\n", out);
}
