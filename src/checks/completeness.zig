//! `completeness` (opt-in, default off) — a spec-side checklist gate ported
//! from the Gleam and Rust guardians' identical 8-category list. When
//! `[completeness] enabled = true`, every `## ` feature section in SPEC.md must
//! ADDRESS each of the 8 scenario categories (a `- ` bullet whose prose matches
//! the category's keywords) or explicitly WAIVE it with a
//! `- completeness-waiver: <category> (<reason>)` bullet (reason required).
//! The production consumer's dominant shipped-bug classes are boundary /
//! geometry / numeric — exactly what the empty / large / overflow categories
//! force a bullet (and, via the 1:1 map, a test) for. Non-feature sections
//! (changelog-ish) are listed in `[completeness] exempt_sections`.

const std = @import("std");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const spec_parser = @import("../spec/parser.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

/// Bullet prefix that marks a category waiver instead of a real behavior. The
/// spec parser skips these too, so a waiver never demands a `// spec:` tag.
pub const waiver_prefix = "completeness-waiver:";

/// Cap on the SPEC.md read (matches the spec parser's own limit).
const max_spec_bytes = 1024 * 1024;

/// One required scenario category: its canonical name (shown in violations and
/// matched in a waiver) and the lowercase keyword set that counts as addressing
/// it in a bullet's prose.
const Category = struct {
    name: []const u8,
    keywords: []const []const u8,
};

/// The 8 categories, mirroring the Gleam/Rust guardians' set (adapted to
/// free-form Zig SPEC prose via a small synonym set per category).
const categories = [_]Category{
    .{
        .name = "empty inputs",
        .keywords = &.{ "empty", "no input", "zero-length", "zero length", "blank" },
    },
    .{
        .name = "large inputs",
        .keywords = &.{ "large input", "very large", "huge", "oversized", "bulk", "many items" },
    },
    .{
        .name = "unauthorized access",
        .keywords = &.{ "unauthorized", "unauthorised", "permission", "forbidden", "access control", "not allowed" },
    },
    .{
        .name = "i/o failure",
        .keywords = &.{ "i/o failure", "io failure", "i/o error", "read error", "write error", "read fails" },
    },
    .{
        .name = "concurrent access",
        .keywords = &.{ "concurrent", "parallel", "race", "thread-safe", "threadsafe", "simultaneous" },
    },
    .{
        .name = "malformed encoding",
        .keywords = &.{ "malformed", "invalid encoding", "invalid utf", "corrupt", "bad encoding", "garbage input" },
    },
    .{
        .name = "integer overflow",
        .keywords = &.{ "overflow", "underflow", "saturat", "wraparound", "wrap-around" },
    },
    .{
        .name = "panic-free",
        .keywords = &.{ "panic-free", "never panics", "no panic", "does not panic", "cannot panic" },
    },
};

/// One `## ` feature section: its heading name and every `- ` bullet under it
/// (waiver bullets included — the waiver logic needs to see them).
pub const FeatureSection = struct {
    name: []const u8,
    bullets: []const []const u8,
};

/// A parsed `completeness-waiver:` bullet: the category it names (trimmed) and
/// whether it supplied a non-empty `(reason)`.
const Waiver = struct {
    category: []const u8,
    has_reason: bool,
};

/// Whether a category is covered, missing, or waived without the required reason.
const CategoryStatus = enum { addressed, missing, waiver_no_reason };

/// Splits SPEC.md into `## ` feature sections with their `- ` bullets, skipping
/// fenced code blocks so an illustrative `## `/`- ` inside a fence is ignored.
pub fn parseFeatureSections(arena: Allocator, text: []const u8) Allocator.Error![]const FeatureSection {
    var sections: std.ArrayList(FeatureSection) = .empty;
    var cur_name: ?[]const u8 = null;
    var cur_bullets: std.ArrayList([]const u8) = .empty;
    var in_fence = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            try flushSection(arena, &sections, cur_name, &cur_bullets);
            cur_name = std.mem.trim(u8, line[3..], &std.ascii.whitespace);
            cur_bullets = .empty;
        } else if (std.mem.startsWith(u8, line, "- ") and cur_name != null) {
            try cur_bullets.append(arena, std.mem.trim(u8, line[2..], &std.ascii.whitespace));
        }
    }
    try flushSection(arena, &sections, cur_name, &cur_bullets);
    return sections.toOwnedSlice(arena);
}

fn flushSection(
    arena: Allocator,
    sections: *std.ArrayList(FeatureSection),
    name: ?[]const u8,
    bullets: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const n = name orelse return;
    try sections.append(arena, .{ .name = n, .bullets = try bullets.toOwnedSlice(arena) });
}

/// Produces one violation line per category gap across every non-exempt
/// section. Pure over parsed sections so the checklist logic is unit-tested
/// without touching disk.
pub fn analyze(
    arena: Allocator,
    sections: []const FeatureSection,
    exempt: []const []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (sections) |sec| {
        if (inList(exempt, sec.name)) continue;
        try checkSection(arena, sec, &out);
    }
    return out.toOwnedSlice(arena);
}

fn checkSection(
    arena: Allocator,
    sec: FeatureSection,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const waivers = try collectWaivers(arena, sec);
    for (categories) |cat| {
        switch (categoryStatus(sec, waivers, cat)) {
            .addressed => {},
            .missing => try out.append(arena, try std.fmt.allocPrint(
                arena,
                "{s}: missing completeness category '{s}'",
                .{ sec.name, cat.name },
            )),
            .waiver_no_reason => try out.append(arena, try std.fmt.allocPrint(
                arena,
                "{s}: completeness-waiver for '{s}' needs a reason in parentheses",
                .{ sec.name, cat.name },
            )),
        }
    }
}

fn categoryStatus(sec: FeatureSection, waivers: []const Waiver, cat: Category) CategoryStatus {
    if (waiverFor(waivers, cat.name)) |w| return if (w.has_reason) .addressed else .waiver_no_reason;
    if (mentionsCategory(sec.bullets, cat)) return .addressed;
    return .missing;
}

/// Collects the parsed waivers among a section's bullets.
fn collectWaivers(arena: Allocator, sec: FeatureSection) Allocator.Error![]const Waiver {
    var list: std.ArrayList(Waiver) = .empty;
    for (sec.bullets) |b| {
        if (parseWaiver(b)) |w| try list.append(arena, w);
    }
    return list.toOwnedSlice(arena);
}

/// Parses a `completeness-waiver: <category> (<reason>)` bullet, or null when
/// the bullet is not a waiver. A missing/empty `(reason)` yields `has_reason
/// = false` (the check then fails it).
fn parseWaiver(statement: []const u8) ?Waiver {
    if (!isWaiver(statement)) return null;
    const rest = std.mem.trim(u8, statement[waiver_prefix.len..], &std.ascii.whitespace);
    const open = std.mem.indexOfScalar(u8, rest, '(') orelse
        return .{ .category = rest, .has_reason = false };
    const category = std.mem.trim(u8, rest[0..open], &std.ascii.whitespace);
    const close = std.mem.indexOfScalarPos(u8, rest, open + 1, ')') orelse rest.len;
    const reason = std.mem.trim(u8, rest[open + 1 .. close], &std.ascii.whitespace);
    return .{ .category = category, .has_reason = reason.len > 0 };
}

/// True when a bullet is a completeness-waiver line (case-insensitive prefix).
fn isWaiver(statement: []const u8) bool {
    return statement.len >= waiver_prefix.len and
        std.ascii.eqlIgnoreCase(statement[0..waiver_prefix.len], waiver_prefix);
}

/// The waiver naming `cat_name` (case-insensitive), or null when none.
fn waiverFor(waivers: []const Waiver, cat_name: []const u8) ?Waiver {
    for (waivers) |w| if (std.ascii.eqlIgnoreCase(w.category, cat_name)) return w;
    return null;
}

/// True when a non-waiver bullet's prose contains any of the category's
/// keywords (case-insensitive).
fn mentionsCategory(bullets: []const []const u8, cat: Category) bool {
    for (bullets) |b| {
        if (isWaiver(b)) continue;
        for (cat.keywords) |kw| {
            if (std.ascii.indexOfIgnoreCase(b, kw) != null) return true;
        }
    }
    return false;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Entry point for the completeness check. Opt-in: a no-op ok report unless
/// `[completeness] enabled = true`.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const cfg = ctx.cfg.completeness;
    if (!cfg.enabled) {
        reporter.ok("completeness disabled by config (opt-in via [completeness] enabled = true)", .{});
        return;
    }
    const allocator = ctx.allocator;
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ctx.project_dir, ctx.cfg.spec_file });
    const content = std.fs.cwd().readFileAlloc(allocator, spec_path, max_spec_bytes) catch
        return reportMissingSpec(allocator, ctx.project_dir, ctx.cfg.spec_file);
    const sections = try parseFeatureSections(allocator, content);
    const violations = try analyze(allocator, sections, cfg.exempt_sections);

    if (violations.len == 0) {
        reporter.ok("completeness: every feature section covers all {d} categories", .{categories.len});
        return;
    }
    reporter.fail("completeness FAILED ({d} category gap(s))", .{violations.len});
    for (violations) |v| detail("  {s}\n", .{v});
    detail("  fix: address the category with a `- ` bullet, or waive it with\n", .{});
    detail("       `- completeness-waiver: <category> (<reason>)` (reason required).\n", .{});
    return error.CheckFailed;
}

/// Reports a missing SPEC.md as a hard error rather than a silent skip
/// (guiding principle #8: missing SPEC.md = error). Only reachable once the
/// check is enabled, so an enabled completeness gate never quietly passes when
/// its spec is absent (e.g. a run launched from the wrong directory).
fn reportMissingSpec(
    allocator: Allocator,
    project_dir: []const u8,
    spec_file: []const u8,
) registry.RunError!void {
    const dir = spec_parser.resolveProjectDir(allocator, project_dir) catch project_dir;
    reporter.fail("{s} not found for project dir '{s}'", .{ spec_file, dir });
    detail("  completeness is enabled but SPEC.md is missing (missing SPEC.md = error, not a skip).\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Completeness Checklist - Fails when SPEC.md is missing while enabled instead of skipping

test "reportMissingSpec fails loudly and names the resolved project dir" {
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An absolute dir passes through resolveProjectDir → deterministic message,
    // and an enabled check errors instead of quietly reporting "nothing to check".
    try std.testing.expectError(
        error.CheckFailed,
        reportMissingSpec(arena.allocator(), "/abs/proj", "SPEC.md"),
    );
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "not found for project dir '/abs/proj'") != null);
}

// spec: Completeness Checklist - Fails a feature section that omits a required completeness category

test "analyze flags every uncovered category in a bare section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sections = try parseFeatureSections(a, "## Widget\n- renders the widget\n");
    const out = try analyze(a, sections, &.{});
    // No bullet matches any keyword → all 8 categories reported missing.
    try std.testing.expectEqual(categories.len, out.len);
}

// spec: Completeness Checklist - Passes a section whose bullets address every completeness category

test "analyze passes a section that addresses all categories via keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec =
        \\## Parser
        \\- handles empty inputs gracefully
        \\- streams very large inputs
        \\- rejects unauthorized access
        \\- surfaces i/o failure to the caller
        \\- guards concurrent access
        \\- rejects malformed encoding
        \\- checks for integer overflow
        \\- stays panic-free on bad data
    ;
    const sections = try parseFeatureSections(a, spec);
    const out = try analyze(a, sections, &.{});
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Completeness Checklist - Accepts a completeness-waiver bullet that gives a reason

test "analyze accepts reasoned waivers alongside keyword bullets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec =
        \\## Daemon
        \\- handles empty inputs
        \\- streams very large inputs
        \\- rejects malformed encoding
        \\- guards integer overflow
        \\- completeness-waiver: unauthorized access (single-user CLI, no auth surface)
        \\- completeness-waiver: i/o failure (pure in-memory transform)
        \\- completeness-waiver: concurrent access (single-threaded)
        \\- completeness-waiver: panic-free (best-effort telemetry only)
    ;
    const sections = try parseFeatureSections(a, spec);
    const out = try analyze(a, sections, &.{});
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Completeness Checklist - Rejects a completeness-waiver bullet that omits its reason

test "analyze rejects a waiver with no reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec =
        \\## Thing
        \\- handles empty inputs
        \\- streams very large inputs
        \\- rejects unauthorized access
        \\- surfaces i/o failure
        \\- guards concurrent access
        \\- rejects malformed encoding
        \\- checks integer overflow
        \\- completeness-waiver: panic-free
    ;
    const sections = try parseFeatureSections(a, spec);
    const out = try analyze(a, sections, &.{});
    // Seven categories covered; the reasonless panic-free waiver fails.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "needs a reason") != null);
}

// spec: Completeness Checklist - Skips sections listed in the exempt_sections config

test "analyze skips an exempt section entirely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sections = try parseFeatureSections(a, "## Changelog\n- released v1\n");
    const out = try analyze(a, sections, &.{"Changelog"});
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseFeatureSections ignores fenced code and groups bullets under headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec =
        \\## Real
        \\- addresses empty inputs
        \\```
        \\## Fenced
        \\- not a bullet
        \\```
    ;
    const sections = try parseFeatureSections(a, spec);
    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expectEqualStrings("Real", sections[0].name);
    try std.testing.expectEqual(@as(usize, 1), sections[0].bullets.len);
}
