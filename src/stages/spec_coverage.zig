const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const parser = @import("../spec/parser.zig");
const matcher = @import("../spec/matcher.zig");
const StageResult = stage.StageResult;

pub fn run(ctx: *pipeline.Context) StageResult {
    const spec_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.target_dir, ctx.config.spec_file }) catch
        return stage.failed("Spec Coverage", &.{"Failed to construct spec path"}, &.{});

    const sections = parser.parseFile(ctx.allocator, spec_path) catch {
        return stage.failedAlloc(
            ctx.allocator,
            "Spec Coverage",
            std.fmt.allocPrint(ctx.allocator, "Could not read spec file: {s}", .{spec_path}) catch "Could not read spec file",
            "Create a SPEC.md file with ## Section and - Behavior entries",
        );
    };

    // Scan both test/ and src/ for spec tags (Zig tests can be co-located)
    const test_dir = std.fmt.allocPrint(ctx.allocator, "{s}/test", .{ctx.target_dir}) catch "";
    const src_dir = std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.target_dir}) catch "";

    var all_tags: std.ArrayListUnmanaged(matcher.SpecTag) = .empty;
    for (matcher.scanDir(ctx.allocator, test_dir)) |t| all_tags.append(ctx.allocator, t) catch {};
    for (matcher.scanDir(ctx.allocator, src_dir)) |t| all_tags.append(ctx.allocator, t) catch {};
    const tags = all_tags.toOwnedSlice(ctx.allocator) catch &.{};

    const result = matcher.analyze(ctx.allocator, sections, tags);

    // Build issues
    var issues: std.ArrayListUnmanaged([]const u8) = .empty;
    for (result.unverified_behaviors) |b| {
        const msg = std.fmt.allocPrint(ctx.allocator, "Unverified: {s} - {s}", .{ b.section, b.statement }) catch continue;
        issues.append(ctx.allocator, msg) catch {};
    }
    for (result.unlinked_tags) |t| {
        const msg = std.fmt.allocPrint(ctx.allocator, "Unlinked tag: {s} in {s}", .{ t.tag, t.file }) catch continue;
        issues.append(ctx.allocator, msg) catch {};
    }

    if (issues.items.len == 0) {
        const detail = std.fmt.allocPrint(ctx.allocator, "{d}/{d} behaviors covered", .{ result.covered_behaviors, result.total_behaviors }) catch "All behaviors covered";
        return stage.passed("Spec Coverage", detail);
    }

    // Build remediation
    var remediation: std.ArrayListUnmanaged([]const u8) = .empty;
    for (result.unverified_behaviors) |b| {
        const msg = std.fmt.allocPrint(ctx.allocator, "Add test with tag: // spec: {s} - {s}", .{ b.section, b.statement }) catch continue;
        remediation.append(ctx.allocator, msg) catch {};
    }
    for (result.unlinked_tags) |t| {
        const msg = std.fmt.allocPrint(ctx.allocator, "Fix tag '{s}' to match a SPEC.md behavior, or add the behavior to SPEC.md", .{t.tag}) catch continue;
        remediation.append(ctx.allocator, msg) catch {};
    }

    return stage.failed(
        "Spec Coverage",
        issues.toOwnedSlice(ctx.allocator) catch &.{},
        remediation.toOwnedSlice(ctx.allocator) catch &.{},
    );
}
