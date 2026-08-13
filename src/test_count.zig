//! Ground truth for how many tests a project's suite actually ran.
//!
//! Every other answer about test reachability is a MODEL over import edges
//! (`ast/test_reach.zig`): it reasons about which files a test root references
//! and infers which `test` blocks the compiler therefore kept. This module
//! records the MEASUREMENT instead — Guardian's test runner prints
//! `guardian/test: N test(s) selected` before the first test, and the commit
//! gate already captures the output of the test command it runs — so a later
//! check can hold the model against the number the compiler actually produced.
//! A model that promises more tests than ran is wrong in the expensive
//! direction: it is the state in which dead tests, and the `// spec:` tags on
//! them, read as covered.
//!
//! The record lives under `.guardian/cache/` (gitignored, excluded from the
//! green-run digest) and is best-effort in both directions: an unwritable cache
//! records nothing, and a missing or unreadable record means "nothing measured"
//! rather than a finding. It also carries the tree's total `test` count at
//! record time, which is what lets a reader tell a current measurement from one
//! taken before the tests changed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const reporter = @import("reporter.zig");

/// Record format version.
pub const version: u32 = 1;

/// Project-relative path of the record, named here so `doctor` and the check
/// can point a reader at one spelling of it.
pub const leaf = ".guardian/cache/test-count.txt";

/// The line Guardian's test runner prints before the first test. Spelled here
/// rather than imported: `test_timing.zig` belongs to the test-runner module,
/// and a Zig file may only live in one module. `build_helper` has a test
/// asserting the runner still prints this, so the two cannot drift silently.
const selected_marker = " test(s) selected";

/// Prefix of that same line, which keeps a project's own test output from being
/// mistaken for the runner's report.
const runner_prefix = "guardian/test: ";

/// Present on the count line only when the build narrowed the run. A filtered
/// run compiles a subset by construction, so it is no measurement of the suite.
const filtered_marker = " by filter:";

/// One recorded measurement.
pub const Record = struct {
    /// Tests the recorded run actually selected, summed over every test binary
    /// whose runner reported a count.
    selected: u32,
    /// Every `test` block in the walked trees when the run was recorded. A
    /// current tree with a different count means the record predates today's
    /// tests and says nothing about them.
    tests_in_tree: u32,
};

/// The selected-test count in a captured test-run log, or null when the log
/// holds none — and null too when any count line names a filter, since a
/// filtered run measures a subset of the suite rather than the suite. Counts
/// from several binaries are summed: each one printed what it ran.
pub fn parseSelected(output: []const u8) ?u32 {
    var total: u32 = 0;
    var found = false;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, runner_prefix) orelse continue;
        const rest = line[start + runner_prefix.len ..];
        const marker = std.mem.indexOf(u8, rest, selected_marker) orelse continue;
        if (std.mem.indexOf(u8, rest, filtered_marker) != null) return null;
        const count = std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..marker], " "), 10) catch continue;
        total += count;
        found = true;
    }
    return if (found) total else null;
}

/// Records the count found in `output` against the tree's current `test` total.
/// Best-effort: a log with no count (a project not wired to Guardian's runner,
/// or a filtered run) records nothing, and an I/O failure is reported as a note
/// rather than failing the run that produced a green suite.
pub fn record(a: Allocator, project_dir: []const u8, output: []const u8, tests_in_tree: u32) void {
    const selected = parseSelected(output) orelse return;
    write(a, project_dir, .{ .selected = selected, .tests_in_tree = tests_in_tree }) catch |e|
        reporter.detail("  note: test-count record not written ({s})\n", .{@errorName(e)});
}

/// Testable core of `record`.
fn write(a: Allocator, project_dir: []const u8, rec: Record) (Allocator.Error || snapshot.WriteError)!void {
    const path = try pathFor(a, project_dir);
    var lines = [_][]const u8{
        try std.fmt.allocPrint(a, "selected {d}", .{rec.selected}),
        try std.fmt.allocPrint(a, "tree {d}", .{rec.tests_in_tree}),
    };
    try snapshot.write(path, version, &lines);
}

/// The last recorded measurement, or null when none was ever taken (or the
/// record is unreadable or malformed — in every case nothing is known, which is
/// not a finding).
pub fn read(a: Allocator, project_dir: []const u8) ?Record {
    const path = pathFor(a, project_dir) catch return null;
    const snap = snapshot.read(a, path, version) catch return null;
    return decode(snap.lines);
}

/// Parses the stored `selected N` / `tree N` lines. Null unless both are present
/// and numeric, so a half-written record is treated as no record at all.
fn decode(lines: []const []const u8) ?Record {
    var selected: ?u32 = null;
    var tree: ?u32 = null;
    for (lines) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const number = std.fmt.parseInt(u32, line[space + 1 ..], 10) catch continue;
        if (std.mem.eql(u8, line[0..space], "selected")) selected = number;
        if (std.mem.eql(u8, line[0..space], "tree")) tree = number;
    }
    return .{ .selected = selected orelse return null, .tests_in_tree = tree orelse return null };
}

fn pathFor(a: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ project_dir, leaf });
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const fs = @import("fs.zig");

// spec: Test Reachability - Parses the runner's selected-test count out of a captured test run

test "parseSelected sums the count every reporting binary printed" {
    const output =
        \\test
        \\+- run test w
        \\guardian/test: 950 test(s) selected
        \\guardian/test: test wall 0.56s; slowest over 50ms:
        \\guardian/test: 17 test(s) selected
    ;
    // A suite split across binaries prints one line each; each one ran what it
    // says, so the measurement is their sum.
    try testing.expectEqual(@as(?u32, 967), parseSelected(output));
    // Output with no count line at all is no measurement — a project not wired
    // to Guardian's runner records nothing rather than a zero.
    try testing.expectEqual(@as(?u32, null), parseSelected("All 12 tests passed.\n"));
}

// spec: Test Reachability - Discards a filtered test run rather than recording it as a measurement

test "parseSelected refuses a run the build narrowed with a filter" {
    const output =
        \\guardian/test: 3 test(s) selected by filter: "add_tracks"
    ;
    // A filtered build compiles a subset by construction, so its count is not a
    // measurement of the suite and must never be compared against one.
    try testing.expectEqual(@as(?u32, null), parseSelected(output));
}

// spec: Test Reachability - Reads back a recorded measurement and treats a missing or partial record as unmeasured

test "a written record round-trips and a missing one reads as nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/test-count-record";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};

    try testing.expectEqual(@as(?Record, null), read(a, dir));
    try write(a, dir, .{ .selected = 950, .tests_in_tree = 967 });
    const back = read(a, dir) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 950), back.selected);
    try testing.expectEqual(@as(u32, 967), back.tests_in_tree);
    // A record missing either number says nothing measurable; guessing the
    // absent half would invent a gap or hide one.
    try testing.expectEqual(@as(?Record, null), decode(&.{"selected 950"}));
    try testing.expectEqual(@as(?Record, null), decode(&.{"tree 967"}));
}
