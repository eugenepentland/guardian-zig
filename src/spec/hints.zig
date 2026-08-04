//! Fix-shaped guidance for an unlinked `// spec:` tag, plus the reverse lookup
//! for tags that are frozen in a baseline.
//!
//! The `spec` check can say *that* a tag has no bullet; it could not say what to
//! do about it. Three consumer sessions each paid a gate cycle re-deriving the
//! same three answers by hand: the bullet text to paste, the section a
//! byte-identical bullet already lives under (a wrong-`## `-section mistake reads
//! as two unrelated findings — one `unlinked tag:` and one `unverified:`), and
//! whether a tag is unlinkable on purpose because it is already grandfathered in
//! `.guardian/baselines/spec.txt`.
//!
//! Everything here is pure over parsed SPEC.md sections and tag text, so the
//! wording of a hint is unit-testable and no caller needs the filesystem.
//!
//! **Rendering contract:** nothing here may be emitted as a violation *line*.
//! Spec violations are keyed for the baseline by their rendered text
//! (`violation_key.zig` tier 3), so appending a hint to `unlinked tag: …` would
//! re-key every consumer's committed baseline and red their gate with no source
//! change. Hints ride the advisory (`reporter.warn`) channel, which is excluded
//! from baselines and ratchets by construction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const violation_key = @import("../violation_key.zig");

/// Longest edit distance still treated as "you probably meant this bullet".
/// Calibrated at a typo/rewording scale: a bullet reworded past this reads as a
/// genuinely different behavior and gets the plain "add it" hint instead.
pub const near_miss_max_distance: usize = 12;

/// A near miss must also stay under this fraction of the shorter text, so the
/// absolute cap cannot make two SHORT unrelated bullets look like a typo of each
/// other ("lists designs" is 12 edits from "Renders a widget", and suggesting
/// one for the other would be worse than saying nothing).
const near_miss_denominator: usize = 4;

/// True when `distance` is small both absolutely and relative to the texts —
/// the pair of conditions that separates a reworded bullet from a different one.
fn withinNearMiss(distance: usize, a_len: usize, b_len: usize) bool {
    if (distance > near_miss_max_distance) return false;
    return distance * near_miss_denominator <= @min(a_len, b_len);
}

/// Cap on the strings the edit distance is computed over. Beyond it the
/// comparison is skipped (reported as no near miss) rather than paid for — the
/// matrix is O(n*m) and a bullet this long is prose, not a typo candidate.
const max_distance_input: usize = 200;

/// A tag's `<Section> - <Behavior>` split against the known section names.
pub const Parts = struct {
    section: []const u8,
    bullet: []const u8,
};

/// The existing bullet an unlinked tag most resembles, and how far apart the
/// two texts are in edits.
pub const NearMiss = struct {
    section: []const u8,
    statement: []const u8,
    distance: usize,
};

/// What to tell the author about one unlinked tag.
pub const Hint = union(enum) {
    /// A bullet with this exact statement exists, under a different `## `
    /// section. The single highest-value case: the two halves of the mistake
    /// otherwise surface as an `unlinked tag:` and an `unverified:` line that
    /// never say they are the same behavior.
    wrong_section: struct { section: []const u8, parts: Parts },
    /// The closest bullet is within `near_miss_max_distance` — a reword or typo
    /// on one side of the pair, not a missing behavior.
    near_miss: NearMiss,
    /// No bullet resembles the tag: the behavior is genuinely unspecified, so
    /// the hint is the exact bullet to paste.
    add: Parts,
};

/// The best hint for `tag` given the spec's current sections.
///
/// Ordered by how much the author saves: an exact statement under the wrong
/// section is a two-line fix they cannot otherwise see, a near miss is a
/// character-level diff, and only then does "write the bullet" apply.
pub fn hintFor(sections: []const parser.Section, tag: []const u8) Hint {
    const parts = splitTag(sections, tag);
    if (sectionHolding(sections, parts)) |name| return .{
        .wrong_section = .{ .section = name, .parts = parts },
    };
    if (nearestBehavior(sections, parts.bullet)) |near| return .{ .near_miss = near };
    return .{ .add = parts };
}

/// The section whose bullets contain `parts.bullet` verbatim (case-insensitive,
/// ignoring surrounding whitespace) but which is NOT the section the tag names.
fn sectionHolding(sections: []const parser.Section, parts: Parts) ?[]const u8 {
    for (sections) |section| {
        if (std.ascii.eqlIgnoreCase(section.name, parts.section)) continue;
        for (section.behaviors) |behavior| {
            if (std.ascii.eqlIgnoreCase(behavior.statement, parts.bullet)) return section.name;
        }
    }
    return null;
}

/// Closest bullet to `bullet` across every section, when within the near-miss
/// threshold. Null when nothing is close enough — or when the strings are long
/// enough that a distance would be prose comparison rather than typo detection.
fn nearestBehavior(sections: []const parser.Section, bullet: []const u8) ?NearMiss {
    var best: ?NearMiss = null;
    for (sections) |section| {
        for (section.behaviors) |behavior| {
            const d = editDistance(bullet, behavior.statement) orelse continue;
            if (!withinNearMiss(d, bullet.len, behavior.statement.len)) continue;
            if (best) |b| if (b.distance <= d) continue;
            best = .{ .section = section.name, .statement = behavior.statement, .distance = d };
        }
    }
    return best;
}

/// Levenshtein distance between `a` and `b`, or null when either exceeds
/// `max_distance_input`. Two rolling rows rather than a full matrix, so the
/// whole-spec scan stays linear in memory.
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (a.len > max_distance_input or b.len > max_distance_input) return null;
    var prev: [max_distance_input + 1]usize = undefined;
    var cur: [max_distance_input + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const substitution = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), substitution);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Splits a tag into the section it names and the bullet text under it.
///
/// Chooses the longest existing section prefix so a nested section name
/// (`API - Parsing`) is preserved rather than cut at its first ` - `. With no
/// match it falls back to the first ` - ` separator, and a tag with no separator
/// at all is reported under `Ungrouped`.
pub fn splitTag(sections: []const parser.Section, tag: []const u8) Parts {
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

/// True when no `## ` section in the spec carries `name` — the state behind
/// permanently-unlinkable tags (a consumer had four `commands - …` tags with no
/// `## commands` heading anywhere, discoverable only by grepping the baseline).
pub fn sectionMissing(sections: []const parser.Section, name: []const u8) bool {
    for (sections) |section| {
        if (std.ascii.eqlIgnoreCase(section.name, name)) return false;
    }
    return true;
}

/// One `unlinked tag` record already grandfathered in the spec baseline: the
/// file it names, and the identity key it is stored under.
pub const FrozenTag = struct {
    file: []const u8,
    key: []const u8,
};

/// The marker a frozen `unlinked tag` baseline key carries. Baseline keys are
/// derived from the check's own rendered lines (`violation_key.zig` tier 3), so
/// this is the same text the check prints.
const unlinked_marker = "unlinked tag: ";

/// The ` in ` that separates a rendered `unlinked tag:` line's tag from its file.
const file_separator = " in ";

/// The `unlinked tag` records among a spec baseline's stored keys. Lines that
/// record something else (other spec violations, a snapshot header) are ignored,
/// so a malformed or future baseline degrades to "nothing frozen" rather than a
/// wrong count.
pub fn frozenUnlinked(arena: Allocator, lines: []const []const u8) Allocator.Error![]const FrozenTag {
    var out: std.ArrayList(FrozenTag) = .empty;
    for (lines) |line| {
        const marker = std.mem.indexOf(u8, line, unlinked_marker) orelse continue;
        const record = line[marker..];
        const file = fileOfFrozenTag(record) orelse continue;
        try out.append(arena, .{ .file = file, .key = record });
    }
    return out.toOwnedSlice(arena);
}

/// The file named by an `unlinked tag: <tag> in <file>` record, or null when the
/// record carries no file. The tag text may itself contain ` in `, so the file
/// is taken after the LAST separator.
fn fileOfFrozenTag(record: []const u8) ?[]const u8 {
    const rest = record[unlinked_marker.len..];
    const sep = std.mem.lastIndexOf(u8, rest, file_separator) orelse return null;
    const file = std.mem.trim(u8, rest[sep + file_separator.len ..], &std.ascii.whitespace);
    return if (file.len == 0) null else file;
}

/// The stored-key form of an unlinked tag: exactly the line the check renders,
/// with standalone digit runs collapsed the way `violation_key.skeleton` does
/// when the baseline records it. Comparing in this form is what lets a frozen
/// tag be told apart from a newly-written one.
pub fn frozenKeyFor(arena: Allocator, tag: []const u8, file: []const u8) Allocator.Error![]const u8 {
    const line = try std.fmt.allocPrint(arena, unlinked_marker ++ "{s}" ++ file_separator ++ "{s}", .{ tag, file });
    return violation_key.skeleton(arena, line);
}

/// True when `key` is already grandfathered. A miss only costs an extra
/// (correct) hint, never a missed violation — the hints are advisory.
pub fn isFrozen(frozen: []const FrozenTag, key: []const u8) bool {
    for (frozen) |f| if (std.mem.eql(u8, f.key, key)) return true;
    return false;
}

/// How many frozen unlinked tags `file` holds (0 when it has no frozen debt).
/// The query is skeletonized before comparison because the stored records
/// already are — a path carrying a standalone digit run would otherwise never
/// match itself.
pub fn frozenCountFor(
    arena: Allocator,
    frozen: []const FrozenTag,
    file: []const u8,
) Allocator.Error!usize {
    const key = try violation_key.skeleton(arena, file);
    var n: usize = 0;
    for (frozen) |f| {
        if (std.mem.eql(u8, f.file, key)) n += 1;
    }
    return n;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn sectionsFixture() []const parser.Section {
    const web = &[_]parser.Behavior{
        .{ .section = "Web Server", .statement = "Reports pad clearances", .key = "web server - reports pad clearances" },
    };
    const drc = &[_]parser.Behavior{
        .{ .section = "placement/drc", .statement = "Rejects overlapping courtyards", .key = "placement/drc - rejects overlapping courtyards" },
    };
    return &[_]parser.Section{
        .{ .name = "Web Server", .behaviors = web },
        .{ .name = "placement/drc", .behaviors = drc },
    };
}

// spec: Spec Reporting - Names the section a byte-identical bullet already lives under

test "hintFor pairs a tag with the wrong-section bullet that already exists" {
    // The eda case: the bullet landed under `## Web Server` while its test was
    // tagged `placement/drc - …`, and the two halves surfaced as unrelated
    // `unlinked tag:` / `unverified:` lines that never said "same behavior".
    const hint = hintFor(sectionsFixture(), "placement/drc - Reports pad clearances");
    try testing.expectEqualStrings("Web Server", hint.wrong_section.section);
    try testing.expectEqualStrings("placement/drc", hint.wrong_section.parts.section);
    try testing.expectEqualStrings("Reports pad clearances", hint.wrong_section.parts.bullet);
}

// spec: Spec Reporting - Suggests the closest existing bullet when a tag nearly matches one

test "hintFor reports a near miss with its distance and falls back to add" {
    // One word reworded on the tag side: a character-level fix, not a new bullet.
    const near = hintFor(sectionsFixture(), "Web Server - Reports pad clearance");
    try testing.expectEqualStrings("Web Server", near.near_miss.section);
    try testing.expectEqualStrings("Reports pad clearances", near.near_miss.statement);
    try testing.expectEqual(@as(usize, 1), near.near_miss.distance);

    // Nothing resembles it: the hint becomes the exact bullet to paste.
    const add = hintFor(sectionsFixture(), "Web Server - Streams gerber archives to the browser");
    try testing.expectEqualStrings("Web Server", add.add.section);
    try testing.expectEqualStrings("Streams gerber archives to the browser", add.add.bullet);

    // Two SHORT unrelated bullets can sit inside the absolute cap while sharing
    // nothing; the relative floor is what stops "lists designs" from being
    // offered as a typo of "Reports pad clearances".
    try testing.expect(!withinNearMiss(12, "lists designs".len, "Reports pad clearances".len));
    try testing.expect(withinNearMiss(1, 22, 23));
}

// spec: Spec Reporting - Splits a tag against the longest matching section name

test "splitTag prefers the longest section and falls back to the first separator" {
    const sections = &[_]parser.Section{
        .{ .name = "API", .behaviors = &.{} },
        .{ .name = "API - Parsing", .behaviors = &.{} },
    };
    const nested = splitTag(sections, "API - Parsing - rejects blanks");
    try testing.expectEqualStrings("API - Parsing", nested.section);
    try testing.expectEqualStrings("rejects blanks", nested.bullet);

    // No known section: the first ` - ` splits it, and a tag with no separator
    // at all lands under Ungrouped rather than losing its text.
    const unknown = splitTag(sections, "Widgets - renders");
    try testing.expectEqualStrings("Widgets", unknown.section);
    const bare = splitTag(sections, "PCB-RF-001");
    try testing.expectEqualStrings("Ungrouped", bare.section);
    try testing.expectEqualStrings("PCB-RF-001", bare.bullet);
}

// spec: Spec Reporting - Reports a tag whose named section has no SPEC.md heading

test "sectionMissing distinguishes an absent heading from a present one" {
    try testing.expect(sectionMissing(sectionsFixture(), "commands"));
    try testing.expect(!sectionMissing(sectionsFixture(), "Web Server"));
    // Case-insensitive: a heading differing only in case is still the section.
    try testing.expect(!sectionMissing(sectionsFixture(), "web server"));
}

// spec: Spec Reporting - Counts the unlinked tags a file already has frozen in the spec baseline

test "frozenUnlinked parses baseline records and counts them per file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = [_][]const u8{
        "spec|unlinked tag: commands - runs the build in a subprocess in src/commands.zig",
        "spec|unlinked tag: commands - lists designs in src/commands.zig",
        "spec|unlinked tag: erc - warns on floating input in src/erc.zig",
        "spec|unverified: Web Server - streams gerbers",
    };
    const frozen = try frozenUnlinked(a, &lines);
    try testing.expectEqual(@as(usize, 3), frozen.len);
    try testing.expectEqual(@as(usize, 2), try frozenCountFor(a, frozen, "src/commands.zig"));
    // A file with no frozen entry reports zero rather than a missing lookup.
    try testing.expectEqual(@as(usize, 0), try frozenCountFor(a, frozen, "src/new.zig"));

    // A tag already recorded is recognized as frozen; a newly written one in the
    // same file is not — which is what keeps the hint block to the NEW work.
    const old = try frozenKeyFor(a, "commands - lists designs", "src/commands.zig");
    try testing.expect(isFrozen(frozen, old));
    const new = try frozenKeyFor(a, "commands - deletes designs", "src/commands.zig");
    try testing.expect(!isFrozen(frozen, new));
}
