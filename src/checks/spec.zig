//! `spec` — the 1:1 SPEC.md ↔ `// spec:` tag map, Guardian's flagship gate.
//!
//! Two output channels, and the split is load-bearing. Violation *lines* are
//! frozen text: a spec violation is baselined by its rendered form
//! (`violation_key.zig` tier 3), so every word of `unlinked tag: <tag> in
//! <file>` is part of a consumer's committed baseline key and may not change.
//! Everything this check learned that would *help* — the bullet to paste, the
//! section a byte-identical bullet already sits under, which of a file's tags
//! are grandfathered debt — therefore rides `reporter.warn`, the advisory
//! channel, which baselines and ratchets exclude by construction and which
//! survives baseline mode's capture-and-replace of the check's own output.

const std = @import("std");
const spec_parser = @import("../spec/parser.zig");
const spec_matcher = @import("../spec/matcher.zig");
const spec_hints = @import("../spec/hints.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const snapshot = @import("../snapshot.zig");
const baseline = @import("../baseline.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// Name this check is registered under; also the baseline file's stem.
const check_name = "spec";

/// The one thing the failure output cannot say for itself, and the thing three
/// consumer sessions each guessed wrong: the tag list is produced by walking
/// every `.zig` file under `test/` and `src/`, not by reading the compiled test
/// set. A `-Dtest-filter` build therefore sees exactly the same tags, so the
/// list below is complete and can be fixed in ONE pass — the belief that it was
/// partial is what turned a single edit into an edit-per-tag loop.
const scan_note = "the // spec: scan walks every .zig file under test/ and src/, NOT the compiled test set — " ++
    "a -Dtest-filter build sees this same list, so it is complete; fix them in one pass";

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
        // Guidance rides the advisory channel, never the violation lines: a spec
        // violation is baselined by its rendered text, so appending a hint to
        // `unlinked tag: …` would re-key every consumer's committed baseline.
        try reportGuidance(allocator, project_dir, sections, result);
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

/// Advisory, copy-pasteable guidance for the unlinked tags this run found.
///
/// Routed through `reporter.warn` rather than the violation lines for two
/// reasons. It is the only channel that survives baseline mode — a baselined
/// check's own output is captured and replaced by the outcome report, so a hint
/// printed as `detail` never reaches the consumer that needs it most. And
/// advisory findings are excluded from baselines and ratchets by construction,
/// so enriching them can never re-key committed debt.
fn reportGuidance(
    allocator: Allocator,
    project_dir: []const u8,
    sections: []const spec_parser.Section,
    result: spec_matcher.CoverageResult,
) registry.RunError!void {
    if (result.unlinked_tags.len == 0) return;
    const frozen = try frozenTags(allocator, project_dir);
    const fresh = try freshTags(allocator, frozen, result.unlinked_tags);
    if (fresh.len > 1) reporter.warn(.{
        .check = check_name,
        .message = try std.fmt.allocPrint(allocator, "{d} unlinked tag(s) need a bullet — {s}", .{ fresh.len, scan_note }),
    });
    for (fresh) |t| reporter.warn(.{
        .check = check_name,
        .file = t.file,
        .message = try hintMessage(allocator, sections, t.tag),
    });
    try reportFrozenDebt(allocator, frozen, fresh);
}

/// The `unlinked tag` records already grandfathered in this project's spec
/// baseline. Empty when baseline mode is off, the file is absent, or it is a
/// format this build cannot read — in every case the honest answer is "nothing
/// is known to be frozen", which only ever costs an extra (correct) hint.
fn frozenTags(
    allocator: Allocator,
    project_dir: []const u8,
) registry.RunError![]const spec_hints.FrozenTag {
    const path = try baseline.pathFor(allocator, project_dir, check_name);
    const snap = snapshot.read(allocator, path, baseline.version) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    return spec_hints.frozenUnlinked(allocator, snap.lines);
}

/// The unlinked tags that are NOT already frozen — the ones this change
/// introduced. Under baseline mode the check still reports every unlinked tag
/// (the baseline subtracts them afterwards), so hinting all of them would bury
/// one new tag under a consumer's whole grandfathered backlog.
fn freshTags(
    allocator: Allocator,
    frozen: []const spec_hints.FrozenTag,
    unlinked: []const spec_matcher.SpecTag,
) Allocator.Error![]const spec_matcher.SpecTag {
    var out: std.ArrayList(spec_matcher.SpecTag) = .empty;
    for (unlinked) |t| {
        const key = try spec_hints.frozenKeyFor(allocator, t.tag, t.file);
        if (spec_hints.isFrozen(frozen, key)) continue;
        try out.append(allocator, t);
    }
    return out.toOwnedSlice(allocator);
}

/// The fix for one unlinked tag, worded by which mistake it actually is.
fn hintMessage(
    allocator: Allocator,
    sections: []const spec_parser.Section,
    tag: []const u8,
) Allocator.Error![]const u8 {
    return switch (spec_hints.hintFor(sections, tag)) {
        .wrong_section => |w| std.fmt.allocPrint(
            allocator,
            "unlinked tag `{s}`: a bullet with this exact text already lives under `## {s}` — " ++
                "move it under `## {s}`, or retag the test `// spec: {s} - {s}`",
            .{ tag, w.section, w.parts.section, w.section, w.parts.bullet },
        ),
        .near_miss => |n| std.fmt.allocPrint(
            allocator,
            "unlinked tag `{s}`: closest bullet is `{s} - {s}` ({d} char(s) apart) — " ++
                "tag and bullet must match byte for byte",
            .{ tag, n.section, n.statement, n.distance },
        ),
        .add => |p| addHint(allocator, sections, tag, p),
    };
}

/// The "no bullet resembles this" hint: the exact line to paste, plus the
/// heading to create when the tag names a section SPEC.md does not have.
fn addHint(
    allocator: Allocator,
    sections: []const spec_parser.Section,
    tag: []const u8,
    parts: spec_hints.Parts,
) Allocator.Error![]const u8 {
    if (spec_hints.sectionMissing(sections, parts.section))
        return std.fmt.allocPrint(
            allocator,
            "unlinked tag `{s}`: SPEC.md has no `## {s}` heading — add the heading, then the bullet `- {s}`",
            .{ tag, parts.section, parts.bullet },
        );
    return std.fmt.allocPrint(
        allocator,
        "unlinked tag `{s}`: add under `## {s}` in SPEC.md the bullet `- {s}`",
        .{ tag, parts.section, parts.bullet },
    );
}

/// Names, per file being edited, how many of its `// spec:` tags are frozen as
/// permanent unlinked debt. Without it a file's grandfathered tags are visible
/// only by grepping `.guardian/baselines/spec.txt`, and an author reads the
/// existing unlinkable tags beside theirs as the house style to copy.
fn reportFrozenDebt(
    allocator: Allocator,
    frozen: []const spec_hints.FrozenTag,
    fresh: []const spec_matcher.SpecTag,
) Allocator.Error!void {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (fresh) |t| {
        const gop = try seen.getOrPut(allocator, t.file);
        if (gop.found_existing) continue;
        const count = try spec_hints.frozenCountFor(allocator, frozen, t.file);
        if (count == 0) continue;
        reporter.warn(.{
            .check = check_name,
            .file = t.file,
            .message = try std.fmt.allocPrint(
                allocator,
                "{d} other tag(s) here are baselined-unlinked (frozen in .guardian/baselines/{s}.txt) — " ++
                    "they are grandfathered debt, not a pattern to copy",
                .{ count, check_name },
            ),
        });
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Captures reporter output for the guidance tests and restores the prior sink.
const Sink = struct {
    capture: reporter.Capture,
    prior: ?*reporter.Capture,

    fn start(allocator: Allocator) Sink {
        return .{ .capture = .{ .allocator = allocator }, .prior = reporter.default.capture };
    }

    fn install(self: *Sink) void {
        reporter.default.capture = &self.capture;
    }

    fn stop(self: *Sink) void {
        reporter.default.capture = self.prior;
        self.capture.deinit();
    }

    fn text(self: *const Sink) []const u8 {
        return self.capture.buf.items;
    }
};

fn unlinkedResult(tags: []const spec_matcher.SpecTag) spec_matcher.CoverageResult {
    return .{
        .total_behaviors = 0,
        .covered_behaviors = 0,
        .unverified_behaviors = &.{},
        .unlinked_tags = tags,
        .duplicate_tags = &.{},
        .duplicate_behaviors = &.{},
    };
}

// spec: Spec Reporting - Guides every unlinked tag the run found rather than only the first

test "reportGuidance emits a fix for each unlinked tag, not just the first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sink = Sink.start(testing.allocator);
    defer sink.stop();
    sink.install();

    const sections = [_]spec_parser.Section{.{ .name = "Widgets", .behaviors = &.{} }};
    const tags = [_]spec_matcher.SpecTag{
        .{ .file = "src/a.zig", .tag = "Widgets - Alpha behavior", .key = "widgets - alpha behavior" },
        .{ .file = "src/a.zig", .tag = "Widgets - Bravo behavior", .key = "widgets - bravo behavior" },
        .{ .file = "src/b.zig", .tag = "Gadgets - Charlie behavior", .key = "gadgets - charlie behavior" },
    };
    // A directory with no baseline: nothing is frozen, so all three are fresh.
    try reportGuidance(arena.allocator(), "/nonexistent-guardian-fixture", &sections, unlinkedResult(&tags));

    // Every tag is named — the whole point: three tags cost one edit pass, not
    // three gate cycles of discovering them one at a time.
    for ([_][]const u8{ "Alpha behavior", "Bravo behavior", "Charlie behavior" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, sink.text(), needle) != null);
    }
    // A tag naming a section SPEC.md does not have says so, rather than
    // suggesting a bullet under a heading that will not be found.
    try testing.expect(std.mem.indexOf(u8, sink.text(), "no `## Gadgets` heading") != null);
    // One scan note plus one hint per tag; nothing here is a blocking record.
    try testing.expectEqual(@as(usize, 4), sink.capture.warnings.items.len);
    try testing.expectEqual(@as(usize, 0), sink.capture.records.items.len);
}

// spec: Spec Reporting - Names the tag scan as a file walk that a test filter cannot narrow

test "reportGuidance states the tag list is complete under a filtered build" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sink = Sink.start(testing.allocator);
    defer sink.stop();
    sink.install();

    const tags = [_]spec_matcher.SpecTag{
        .{ .file = "src/a.zig", .tag = "Widgets - Alpha behavior", .key = "widgets - alpha behavior" },
        .{ .file = "src/a.zig", .tag = "Widgets - Bravo behavior", .key = "widgets - bravo behavior" },
    };
    try reportGuidance(arena.allocator(), "/nonexistent-guardian-fixture", &.{}, unlinkedResult(&tags));
    // The false model this replaces — "the filtered run compiled fewer tests, so
    // more tags must be hiding" — is what turned one edit into a per-tag loop.
    try testing.expect(std.mem.indexOf(u8, sink.text(), "-Dtest-filter") != null);
    try testing.expect(std.mem.indexOf(u8, sink.text(), "NOT the compiled test set") != null);
}

// spec: Spec Reporting - Omits guidance for an unlinked tag already frozen in the spec baseline

test "freshTags keeps only the tags the baseline has not grandfathered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frozen = try spec_hints.frozenUnlinked(a, &[_][]const u8{
        "spec|unlinked tag: commands - lists designs in src/commands.zig",
        "spec|unlinked tag: commands - runs the build in src/commands.zig",
    });
    const unlinked = [_]spec_matcher.SpecTag{
        .{ .file = "src/commands.zig", .tag = "commands - lists designs", .key = "commands - lists designs" },
        .{ .file = "src/commands.zig", .tag = "commands - deletes designs", .key = "commands - deletes designs" },
    };
    const fresh = try freshTags(a, frozen, &unlinked);
    // Under baseline mode the check still reports every unlinked tag; hinting
    // all of them would bury the one new tag under the whole frozen backlog.
    try testing.expectEqual(@as(usize, 1), fresh.len);
    try testing.expectEqualStrings("commands - deletes designs", fresh[0].tag);
}

// spec: Spec Reporting - Names how many other tags in the edited file are baselined-unlinked

test "reportFrozenDebt names the file's grandfathered unlinked tags once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink = Sink.start(testing.allocator);
    defer sink.stop();
    sink.install();

    const frozen = try spec_hints.frozenUnlinked(a, &[_][]const u8{
        "spec|unlinked tag: commands - lists designs in src/commands.zig",
        "spec|unlinked tag: commands - runs the build in src/commands.zig",
    });
    const fresh = [_]spec_matcher.SpecTag{
        .{ .file = "src/commands.zig", .tag = "commands - deletes designs", .key = "commands - deletes designs" },
        .{ .file = "src/commands.zig", .tag = "commands - renames designs", .key = "commands - renames designs" },
    };
    try reportFrozenDebt(a, frozen, &fresh);
    // One line per FILE, not per tag, and it says the debt is grandfathered —
    // the tags sitting beside yours are not a pattern to copy.
    try testing.expectEqual(@as(usize, 1), sink.capture.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, sink.text(), "2 other tag(s) here are baselined-unlinked") != null);
}
