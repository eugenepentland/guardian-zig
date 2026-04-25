const std = @import("std");
const spec_parser = @import("../spec/parser.zig");
const spec_matcher = @import("../spec/matcher.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
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
        std.process.exit(1);
    };

    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test", .{project_dir});
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});

    var all_tags: std.ArrayListUnmanaged(spec_matcher.SpecTag) = .empty;
    for (try spec_matcher.scanDir(allocator, test_dir)) |t| try all_tags.append(allocator, t);
    for (try spec_matcher.scanDir(allocator, src_dir)) |t| try all_tags.append(allocator, t);
    const tags = try all_tags.toOwnedSlice(allocator);

    const result = try spec_matcher.analyze(allocator, sections, tags);

    const has_failures = result.unverified_behaviors.len > 0 or
        result.unlinked_tags.len > 0 or
        result.duplicate_tags.len > 0;

    if (!has_failures) {
        ok("spec coverage {d}/{d} behaviors covered", .{ result.covered_behaviors, result.total_behaviors });
        return;
    }

    fail("spec coverage FAILED ({d}/{d} covered, {d} unverified, {d} unlinked, {d} duplicate)", .{
        result.covered_behaviors,
        result.total_behaviors,
        result.unverified_behaviors.len,
        result.unlinked_tags.len,
        result.duplicate_tags.len,
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
    print("\n", .{});
    for (result.unverified_behaviors) |b| {
        print("  add: // spec: {s} - {s}\n", .{ b.section, b.statement });
    }
    if (result.duplicate_tags.len > 0) {
        print("  Each spec behavior must have exactly one // spec: tag (1:1 mapping).\n", .{});
    }
    std.process.exit(1);
}
