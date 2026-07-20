const std = @import("std");
const spec_parser = @import("../spec/parser.zig");
const spec_matcher = @import("../spec/matcher.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// Bundles the near-miss tag lists collected while scanning directories.
const TagScan = struct {
    tags: []const spec_matcher.SpecTag,
    malformed: std.ArrayList(spec_matcher.MalformedTag),
    unattached: std.ArrayList(spec_matcher.MalformedTag),
};

/// Entry point for the spec coverage check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const cfg = ctx.cfg;
    const project_dir = ctx.project_dir;
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, cfg.spec_file });

    const sections = spec_parser.parseFile(allocator, spec_path) catch {
        printMissingSpec(allocator, project_dir, cfg.spec_file);
        return error.CheckFailed;
    };

    var scan = try collectTags(allocator, project_dir);
    const result = try spec_matcher.analyze(allocator, sections, scan.tags);

    if (result.total_behaviors == 0) {
        fail("spec coverage FAILED — {s} defines no behaviors", .{cfg.spec_file});
        print("  Add at least one `## Section` with `- behavior` bullets.\n", .{});
        return error.CheckFailed;
    }

    const has_failures = result.unverified_behaviors.len > 0 or
        result.unlinked_tags.len > 0 or
        result.duplicate_tags.len > 0 or
        result.duplicate_behaviors.len > 0 or
        scan.malformed.items.len > 0 or
        scan.unattached.items.len > 0;

    if (has_failures) {
        reportFailures(result, &scan);
        return error.CheckFailed;
    }

    ok("spec coverage {d}/{d} behaviors covered", .{ result.covered_behaviors, result.total_behaviors });
}

/// Prints the guidance shown when the SPEC.md file cannot be parsed/found,
/// naming the resolved project dir so a wrong-directory run reads as such.
fn printMissingSpec(allocator: std.mem.Allocator, project_dir: []const u8, spec_file: []const u8) void {
    const dir = spec_parser.resolveProjectDir(allocator, project_dir) catch project_dir;
    fail("ERROR — {s} not found for project dir '{s}'", .{ spec_file, dir });
    print("\n", .{});
    print("  Guardian requires a SPEC.md file with your project's specification.\n", .{});
    print("  Create {s} with this structure:\n", .{spec_file});
    print("\n", .{});
    print("    # Project Name\n", .{});
    print("    \n", .{});
    print("    ## Section Name\n", .{});
    print("    - Behavior description\n", .{});
    print("    - Another behavior\n", .{});
    print("\n", .{});
    print("  Then tag each test with a matching // spec: comment:\n", .{});
    print("    // spec: Section Name - Behavior description\n", .{});
    print("    test \"behavior\" {{ ... }}\n", .{});
}

/// Scans the project's test/ and src/ dirs for spec tags and near-misses.
fn collectTags(allocator: std.mem.Allocator, project_dir: []const u8) !TagScan {
    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});

    var all_tags: std.ArrayList(spec_matcher.SpecTag) = .empty;
    var malformed: std.ArrayList(spec_matcher.MalformedTag) = .empty;
    var unattached: std.ArrayList(spec_matcher.MalformedTag) = .empty;
    for ([_][]const u8{ test_dir, src_dir }) |dir| {
        const scan = try spec_matcher.scanDir(allocator, dir);
        for (scan.tags) |t| try all_tags.append(allocator, t);
        for (scan.malformed) |m| try malformed.append(allocator, m);
        for (scan.unattached) |u| try unattached.append(allocator, u);
    }
    return .{
        .tags = try all_tags.toOwnedSlice(allocator),
        .malformed = malformed,
        .unattached = unattached,
    };
}

/// Prints the failure header, per-item detail lines, and fix hints.
fn reportFailures(result: spec_matcher.CoverageResult, scan: *const TagScan) void {
    fail("spec coverage FAILED ({d}/{d} covered, {d} unverified, {d} unlinked, {d} dup-tag, " ++
        "{d} dup-behavior, {d} malformed, {d} unattached)", .{
        result.covered_behaviors,
        result.total_behaviors,
        result.unverified_behaviors.len,
        result.unlinked_tags.len,
        result.duplicate_tags.len,
        result.duplicate_behaviors.len,
        scan.malformed.items.len,
        scan.unattached.items.len,
    });
    for (result.unverified_behaviors) |b| {
        print("  unverified: {s} - {s}\n", .{ b.section, b.statement });
    }
    for (result.unlinked_tags) |t| {
        print("  unlinked tag: {s} in {s}\n", .{ t.tag, t.file });
    }
    for (result.duplicate_tags) |d| {
        print("  duplicate tag: {s}\n", .{d.key});
        for (d.files) |f| {
            print("    in: {s}\n", .{f});
        }
    }
    for (result.duplicate_behaviors) |d| {
        print("  duplicate behavior bullet ({d}x): {s}\n", .{ d.count, d.key });
    }
    for (scan.malformed.items) |m| {
        print("  malformed spec tag: {s}:{d}: {s}\n", .{ m.file, m.line, m.text });
    }
    for (scan.unattached.items) |u| {
        print("  tag not on a test: {s}:{d}: {s}\n", .{ u.file, u.line, u.text });
    }
    print("\n", .{});
    for (result.unverified_behaviors) |b| {
        print("  add: // spec: {s} - {s}\n", .{ b.section, b.statement });
    }
    if (scan.malformed.items.len > 0) {
        print("  A tag must be exactly `// spec: ...` or `// spec-case: ...` (check spacing/case).\n", .{});
    }
    if (result.duplicate_tags.len > 0 or result.duplicate_behaviors.len > 0) {
        print("  Each behavior needs one primary // spec: tag; additional tests use // spec-case:.\n", .{});
    }
}
