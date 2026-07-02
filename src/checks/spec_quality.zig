const std = @import("std");
const spec_parser = @import("../spec/parser.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

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
    const project_dir = ctx.project_dir;

    if (!cfg.spec_quality.enabled) {
        ok("spec quality skipped (disabled in config)", .{});
        return;
    }

    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, cfg.spec_file });
    const sections = spec_parser.parseFile(allocator, spec_path) catch {
        // SPEC.md is enforced by the `spec` check; here we silently skip if missing.
        ok("spec quality skipped (no SPEC.md)", .{});
        return;
    };

    const phrases = if (cfg.spec_quality.forbidden_phrases.len > 0)
        cfg.spec_quality.forbidden_phrases
    else
        default_forbidden_phrases;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    for (sections) |sec| {
        for (sec.behaviors) |b| {
            if (b.statement.len < min_behavior_chars) {
                const msg = try std.fmt.allocPrint(allocator, "{s} - {s}: behavior shorter than {d} chars", .{ b.section, b.statement, min_behavior_chars });
                try violations.append(allocator, msg);
                continue;
            }
            const lower = try toLowerOwned(allocator, b.statement);
            for (phrases) |phrase| {
                const lower_phrase = try toLowerOwned(allocator, phrase);
                if (containsWord(lower, lower_phrase)) {
                    const msg = try std.fmt.allocPrint(allocator, "{s} - {s}: contains vague phrase \"{s}\"", .{ b.section, b.statement, phrase });
                    try violations.append(allocator, msg);
                    break;
                }
            }
        }
    }

    if (violations.items.len == 0) {
        ok("spec quality passed", .{});
        return;
    }

    fail("spec quality FAILED ({d} issue(s))", .{violations.items.len});
    for (violations.items) |v| {
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

/// True if `phrase` appears in `text` with word boundaries on both sides
/// (or at start/end of text). Both inputs assumed already lowercased.
fn containsWord(text: []const u8, phrase: []const u8) bool {
    if (phrase.len == 0 or phrase.len > text.len) return false;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, phrase)) |idx| {
        const left_ok = idx == 0 or !std.ascii.isAlphanumeric(text[idx - 1]);
        const end = idx + phrase.len;
        const right_ok = end == text.len or !std.ascii.isAlphanumeric(text[end]);
        if (left_ok and right_ok) return true;
        search_start = idx + 1;
    }
    return false;
}

// spec: Spec Quality - Flags vague behavior phrases in SPEC.md
// spec: Spec Quality - Rejects behaviors shorter than the minimum length

test "containsWord respects word boundaries" {
    try std.testing.expect(containsWord("handles things properly here", "properly"));
    try std.testing.expect(!containsWord("supports the proper interface", "properly"));
    try std.testing.expect(containsWord("works correctly with input", "works correctly"));
    try std.testing.expect(!containsWord("nonpropery", "propery"));
}
