const std = @import("std");
const spec_parser = @import("../spec/parser.zig");
const spec_matcher = @import("../spec/matcher.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// Entry point for the spec coverage check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const cfg = ctx.cfg;
    const project_dir = ctx.project_dir;
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, cfg.spec_file });

    // spec: Spec Coverage - Fails with clear error when SPEC.md is missing
    const sections = spec_parser.parseFile(allocator, spec_path) catch {
        fail("ERROR — {s} not found", .{cfg.spec_file});
        print("\n", .{});
        print("  Guardian requires a SPEC.md file with your project's specification.\n", .{});
        print("  Create {s} with this structure:\n", .{cfg.spec_file});
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
        return error.CheckFailed;
    };

    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});

    var all_tags: std.ArrayListUnmanaged(spec_matcher.SpecTag) = .empty;
    var malformed: std.ArrayListUnmanaged(spec_matcher.MalformedTag) = .empty;
    for ([_][]const u8{ test_dir, src_dir }) |dir| {
        const scan = try spec_matcher.scanDir(allocator, dir);
        for (scan.tags) |t| try all_tags.append(allocator, t);
        for (scan.malformed) |m| try malformed.append(allocator, m);
    }
    const tags = try all_tags.toOwnedSlice(allocator);

    const result = try spec_matcher.analyze(allocator, sections, tags);

    // spec: Spec Coverage - Fails when SPEC.md defines no behaviors
    if (result.total_behaviors == 0) {
        fail("spec coverage FAILED — {s} defines no behaviors", .{cfg.spec_file});
        print("  Add at least one `## Section` with `- behavior` bullets.\n", .{});
        return error.CheckFailed;
    }

    const has_failures = result.unverified_behaviors.len > 0 or
        result.unlinked_tags.len > 0 or
        result.duplicate_tags.len > 0 or
        result.duplicate_behaviors.len > 0 or
        malformed.items.len > 0;

    if (!has_failures) {
        ok("spec coverage {d}/{d} behaviors covered", .{ result.covered_behaviors, result.total_behaviors });
        return;
    }

    fail("spec coverage FAILED ({d}/{d} covered, {d} unverified, {d} unlinked, {d} dup-tag, {d} dup-behavior, {d} malformed)", .{
        result.covered_behaviors,
        result.total_behaviors,
        result.unverified_behaviors.len,
        result.unlinked_tags.len,
        result.duplicate_tags.len,
        result.duplicate_behaviors.len,
        malformed.items.len,
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
    for (malformed.items) |m| {
        print("  malformed spec tag: {s}:{d}: {s}\n", .{ m.file, m.line, m.text });
    }
    print("\n", .{});
    for (result.unverified_behaviors) |b| {
        print("  add: // spec: {s} - {s}\n", .{ b.section, b.statement });
    }
    if (malformed.items.len > 0) {
        print("  A tag must be exactly `// spec: Section - Behavior` (check spacing/case).\n", .{});
    }
    if (result.duplicate_tags.len > 0 or result.duplicate_behaviors.len > 0) {
        print("  Each spec behavior must have exactly one // spec: tag (1:1 mapping).\n", .{});
    }
    return error.CheckFailed;
}
