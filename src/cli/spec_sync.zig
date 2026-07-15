//! Read-only assistant that turns currently-unlinked `// spec:` tags into
//! exact SPEC.md bullet suggestions. It never edits the specification.

const std = @import("std");
const types = @import("types.zig");
const parser = @import("../spec/parser.zig");
const matcher = @import("../spec/matcher.zig");
const reporter = @import("../reporter.zig");

const Suggestion = struct {
    section: []const u8,
    bullet: []const u8,
    tag: []const u8,
    file: []const u8,
};

const JsonReport = struct {
    dry_run: bool = true,
    suggestion_count: usize,
    suggestions: []const Suggestion,
};

/// Prints exact, grouped SPEC.md additions for tags which have no behavior.
/// The report is a dry run in both text and JSON modes.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const spec_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, ctx.cfg.spec_file });
    const sections = parser.parseFile(ctx.allocator, spec_path) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        reporter.fail("spec-sync: cannot read {s}; no files changed", .{spec_path});
        return error.CheckFailed;
    };
    const tags = try collectTags(ctx.allocator, ctx.project_dir);
    const result = try matcher.analyze(ctx.allocator, sections, tags);
    const suggestions = try makeSuggestions(ctx.allocator, sections, result.unlinked_tags);

    if (ctx.json) {
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, JsonReport{
            .suggestion_count = suggestions.len,
            .suggestions = suggestions,
        }, .{});
        reporter.detail("{s}\n", .{json});
        return;
    }
    if (suggestions.len == 0) {
        reporter.ok("spec-sync: no missing SPEC.md bullets (dry run; no files changed)", .{});
        return;
    }
    reporter.ok("spec-sync dry run: {d} missing bullet(s); no files changed", .{suggestions.len});
    var previous: ?[]const u8 = null;
    for (suggestions) |suggestion| {
        if (previous == null or !std.mem.eql(u8, previous.?, suggestion.section)) {
            reporter.detail("\n[{s}]\n", .{suggestion.section});
            previous = suggestion.section;
        }
        reporter.detail("- {s}\n", .{suggestion.bullet});
        reporter.detail("  source: {s}\n", .{suggestion.file});
    }
}

fn collectTags(allocator: std.mem.Allocator, project_dir: []const u8) types.RunError![]const matcher.SpecTag {
    var out: std.ArrayList(matcher.SpecTag) = .empty;
    for ([_][]const u8{ "test", "src" }) |leaf| {
        const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, leaf });
        const scan = try matcher.scanDir(allocator, dir);
        try out.appendSlice(allocator, scan.tags);
    }
    return out.toOwnedSlice(allocator);
}

fn makeSuggestions(
    allocator: std.mem.Allocator,
    sections: []const parser.Section,
    tags: []const matcher.SpecTag,
) ![]Suggestion {
    var out: std.ArrayList(Suggestion) = .empty;
    for (tags) |tag| {
        const parts = splitTag(sections, tag.tag);
        try out.append(allocator, .{
            .section = parts.section,
            .bullet = parts.bullet,
            .tag = tag.tag,
            .file = tag.file,
        });
    }
    const owned = try out.toOwnedSlice(allocator);
    std.mem.sort(Suggestion, owned, {}, suggestionLessThan);
    return owned;
}

const Parts = struct { section: []const u8, bullet: []const u8 };

/// Chooses the longest existing section prefix, preserving nested section
/// names. With no match it falls back to the first ` - ` separator.
fn splitTag(sections: []const parser.Section, tag: []const u8) Parts {
    var best: ?[]const u8 = null;
    for (sections) |section| {
        if (tag.len <= section.name.len + 3) continue;
        if (!std.mem.startsWith(u8, tag, section.name)) continue;
        if (!std.mem.eql(u8, tag[section.name.len .. section.name.len + 3], " - ")) continue;
        if (best == null or section.name.len > best.?.len) best = section.name;
    }
    if (best) |section| return .{ .section = section, .bullet = tag[section.len + 3 ..] };
    const sep = std.mem.indexOf(u8, tag, " - ") orelse return .{ .section = "Ungrouped", .bullet = tag };
    return .{ .section = tag[0..sep], .bullet = tag[sep + 3 ..] };
}

fn suggestionLessThan(_: void, a: Suggestion, b: Suggestion) bool {
    const section_order = std.mem.order(u8, a.section, b.section);
    if (section_order != .eq) return section_order == .lt;
    return std.mem.order(u8, a.bullet, b.bullet) == .lt;
}

// spec: Maintenance - Spec sync suggests missing bullets without editing SPEC.md

test "splitTag prefers the longest existing section" {
    const sections = &[_]parser.Section{
        .{ .name = "API", .behaviors = &.{} },
        .{ .name = "API - Parsing", .behaviors = &.{} },
    };
    const got = splitTag(sections, "API - Parsing - rejects blanks");
    try std.testing.expectEqualStrings("API - Parsing", got.section);
    try std.testing.expectEqualStrings("rejects blanks", got.bullet);
}
