const std = @import("std");
const spec_parser = @import("../spec/parser.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const text_helpers = @import("../text.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const default_forbidden_phrases: []const []const u8 = &.{
    "works correctly",
    "properly",
    "appropriately",
    "as needed",
    "if possible",
    "should be able to",
    "etc.",
};

const min_behavior_chars: usize = 20;

/// Entry point for the spec-quality check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const cfg = ctx.cfg;

    if (!cfg.spec_quality.enabled) {
        ok("spec quality skipped (disabled in config)", .{});
        return;
    }

    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ctx.project_dir, cfg.spec_file });
    const sections = spec_parser.parseFile(allocator, spec_path) catch
        return reportMissingSpec(allocator, ctx.project_dir, cfg.spec_file);

    const phrases = if (cfg.spec_quality.forbidden_phrases.len > 0)
        cfg.spec_quality.forbidden_phrases
    else
        default_forbidden_phrases;

    var violations: std.ArrayList([]const u8) = .empty;
    for (sections) |sec| {
        try collectSectionViolations(allocator, sec, phrases, &violations);
    }

    return report(violations.items);
}

/// Reports a missing SPEC.md as a hard error rather than a silent skip
/// (guiding principle #8: missing SPEC.md = error). Names the resolved project
/// dir so a run launched from the wrong directory is obvious instead of quietly
/// passing this check.
fn reportMissingSpec(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    spec_file: []const u8,
) registry.RunError!void {
    const dir = spec_parser.resolveProjectDir(allocator, project_dir) catch project_dir;
    fail("{s} not found for project dir '{s}'", .{ spec_file, dir });
    print("  Missing SPEC.md is an error, not a skip. Run `zig build spec-init` to scaffold one.\n", .{});
    return error.CheckFailed;
}

/// Append quality violations for one section's behaviors to `violations`.
fn collectSectionViolations(
    allocator: std.mem.Allocator,
    sec: spec_parser.Section,
    phrases: []const []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    for (sec.behaviors) |b| {
        if (b.statement.len < min_behavior_chars) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s} - {s}: behavior shorter than {d} chars",
                .{ b.section, b.statement, min_behavior_chars },
            );
            try violations.append(allocator, msg);
            continue;
        }
        if (try firstVaguePhrase(allocator, b.statement, phrases)) |phrase| {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s} - {s}: contains vague phrase \"{s}\"",
                .{ b.section, b.statement, phrase },
            );
            try violations.append(allocator, msg);
        }
    }
}

/// Return the first forbidden phrase appearing as a word in `statement`, else null.
fn firstVaguePhrase(
    allocator: std.mem.Allocator,
    statement: []const u8,
    phrases: []const []const u8,
) !?[]const u8 {
    const lower = try toLowerOwned(allocator, statement);
    for (phrases) |phrase| {
        const lower_phrase = try toLowerOwned(allocator, phrase);
        if (text_helpers.containsWord(lower, lower_phrase)) return phrase;
    }
    return null;
}

/// Print the check result; fails if any violations were collected.
fn report(violations: []const []const u8) registry.RunError!void {
    if (violations.len == 0) {
        ok("spec quality passed", .{});
        return;
    }

    fail("spec quality FAILED ({d} issue(s))", .{violations.len});
    for (violations) |v| {
        print("  {s}\n", .{v});
    }
    print("  fix: rewrite each behavior as an observable outcome.\n", .{});
    return error.CheckFailed;
}

fn toLowerOwned(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

// spec: Spec Quality - Flags vague behavior phrases in SPEC.md
// spec: Spec Quality - Rejects behaviors shorter than the minimum length
// spec: Spec Quality - Fails when SPEC.md is missing instead of silently skipping

test "firstVaguePhrase matches a forbidden phrase only at its word boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const phrases: []const []const u8 = &.{ "properly", "works correctly" };
    try std.testing.expectEqualStrings(
        "properly",
        (try firstVaguePhrase(a, "handles things Properly here", phrases)).?,
    );
    try std.testing.expectEqualStrings(
        "works correctly",
        (try firstVaguePhrase(a, "works correctly with input", phrases)).?,
    );
    // `proper` is not `properly`, and a phrase glued inside a longer word is not
    // a match — the boundary rule lives in text.containsWord.
    try std.testing.expect((try firstVaguePhrase(a, "supports the proper interface", phrases)) == null);
}

test "reportMissingSpec fails loudly and names the resolved project dir" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An absolute dir passes through resolveProjectDir, so the message is
    // deterministic — and the check errors rather than reporting a green skip.
    try std.testing.expectError(
        error.CheckFailed,
        reportMissingSpec(arena.allocator(), "/abs/proj", "SPEC.md"),
    );
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "not found for project dir '/abs/proj'") != null);
}
