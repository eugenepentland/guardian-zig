//! Machine-readable survivor report for the `mutate` command. After a run,
//! guardian writes one JSON object per line to `.guardian/cache/last-mutate.jsonl`:
//! a `survivor` record for each mutant the suite let pass, then a `summary`
//! record with the tier, score, and outcome counts. It exists so an agent can
//! read exactly which expressions its tests failed to constrain — file, line,
//! the operator that changed, and the original source line — without scraping
//! terminal prose.
//!
//! The log lives under `cache/` (git-ignored, excluded from the skip-cache
//! digest), so rewriting it every run never churns git or the build cache.
//! std.json does the escaping — no hand-rolled JSON, and no timestamps
//! (std.time is banned).

const std = @import("std");
const runner = @import("runner.zig");
const gen = @import("gen.zig");
const Allocator = std.mem.Allocator;

/// Basename of the machine-readable survivor log.
const log_name = "last-mutate.jsonl";
const cohort_manifest_name = "mutation-cohort.jsonl";

/// One surviving mutant: the location, the operator swap, and the original
/// source line — the exact context an agent needs to write the killing test.
pub const Survivor = struct {
    file: []const u8,
    line: u32,
    original: []const u8,
    replacement: []const u8,
    src_line: []const u8,
};

/// Run-level totals written as the final `summary` record. `tier` is
/// "fast"/"full"; `score` is the kill percentage; `counts` holds the per-outcome
/// tallies; `waived` counts `// mutate-ok` sites excluded from generation;
/// `cached` counts outcomes reused from the result cache; `gated` is whether the
/// score was gated on the percentage (false below the `min_mutants` floor).
pub const Summary = struct {
    tier: []const u8,
    score: u32,
    counts: runner.Score,
    waived: u32,
    cached: u32,
    gated: bool,
};

/// Wire form of a survivor record. Private DTO: field order here is the emitted
/// JSON key order, and `type` discriminates it in the mixed stream.
const SurvivorLine = struct {
    type: []const u8 = "survivor",
    file: []const u8,
    line: u32,
    op: []const u8,
    original_line: []const u8,
};

/// Wire form of the run summary record. Private DTO (see `SurvivorLine`).
const SummaryLine = struct {
    type: []const u8 = "summary",
    tier: []const u8,
    score: u32,
    killed: u32,
    survived: u32,
    unviable: u32,
    inconclusive: u32,
    waived: u32,
    cached: u32,
    gated: bool,
};

/// Serializes one survivor to a single JSON line (no trailing newline). `op` is
/// rendered `<original> -> <replacement>`; std.json escapes all text.
pub fn survivorJson(arena: Allocator, s: Survivor) Allocator.Error![]u8 {
    const op = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ s.original, s.replacement });
    const rec: SurvivorLine = .{ .file = s.file, .line = s.line, .op = op, .original_line = s.src_line };
    return std.json.Stringify.valueAlloc(arena, rec, .{});
}

/// Serializes the run summary to a single JSON line (no trailing newline).
pub fn summaryJson(arena: Allocator, s: Summary) Allocator.Error![]u8 {
    const rec: SummaryLine = .{
        .tier = s.tier,
        .score = s.score,
        .killed = s.counts.killed,
        .survived = s.counts.survived,
        .unviable = s.counts.unviable,
        .inconclusive = s.counts.inconclusive,
        .waived = s.waived,
        .cached = s.cached,
        .gated = s.gated,
    };
    return std.json.Stringify.valueAlloc(arena, rec, .{});
}

/// Path to the survivor log: `<project_dir>/.guardian/cache/last-mutate.jsonl`.
pub fn pathFor(arena: Allocator, project_dir: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.guardian/cache/{s}", .{ project_dir, log_name });
}

/// Writes the survivor log: one `survivor` record per entry, then the `summary`
/// record. Written on every run (a clean run yields a summary-only log).
/// Best-effort — any I/O error is logged and swallowed so the report can never
/// fail the run.
pub fn write(arena: Allocator, project_dir: []const u8, survivors: []const Survivor, summary: Summary) void {
    writeInner(arena, project_dir, survivors, summary) catch |e|
        std.log.warn("guardian mutate report write failed: {s}", .{@errorName(e)});
}

/// Writes the exact sampled cohort manifest. Like the survivor report this is
/// diagnostic-only and cannot fail a mutation run.
pub fn writeCohort(
    arena: Allocator,
    project_dir: []const u8,
    tier: []const u8,
    candidate_count: usize,
    picked: []const gen.Mutant,
    cohort: u64,
) void {
    writeCohortInner(arena, project_dir, tier, candidate_count, picked, cohort) catch |e|
        std.log.warn("guardian mutate cohort write failed: {s}", .{@errorName(e)});
}

fn writeCohortInner(
    arena: Allocator,
    project_dir: []const u8,
    tier: []const u8,
    candidate_count: usize,
    picked: []const gen.Mutant,
    cohort: u64,
) !void {
    const Header = struct {
        type: []const u8 = "summary",
        tier: []const u8,
        candidates: usize,
        sampled: usize,
        cohort: u64,
    };
    const Item = struct {
        type: []const u8 = "mutant",
        hash: u64,
        file: []const u8,
        line: u32,
        column: u32,
        original: []const u8,
        replacement: []const u8,
    };
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, Header{
        .tier = tier,
        .candidates = candidate_count,
        .sampled = picked.len,
        .cohort = cohort,
    }, .{}));
    try buf.append(arena, '\n');
    for (picked) |m| {
        try buf.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, Item{
            .hash = gen.identityHash(m),
            .file = m.path,
            .line = m.source.line,
            .column = m.source.column,
            .original = m.original,
            .replacement = m.replacement,
        }, .{}));
        try buf.append(arena, '\n');
    }
    const p = try std.fmt.allocPrint(arena, "{s}/.guardian/cache/{s}", .{
        project_dir,
        cohort_manifest_name,
    });
    if (std.fs.path.dirname(p)) |dir| try std.fs.cwd().makePath(dir);
    const f = try std.fs.cwd().createFile(p, .{});
    defer f.close();
    try f.writeAll(buf.items);
}

fn writeInner(arena: Allocator, project_dir: []const u8, survivors: []const Survivor, summary: Summary) !void {
    var buf: std.ArrayList(u8) = .empty;
    for (survivors) |s| {
        try buf.appendSlice(arena, try survivorJson(arena, s));
        try buf.append(arena, '\n');
    }
    try buf.appendSlice(arena, try summaryJson(arena, summary));
    try buf.append(arena, '\n');

    const p = try pathFor(arena, project_dir);
    if (std.fs.path.dirname(p)) |dir| try std.fs.cwd().makePath(dir);
    const f = try std.fs.cwd().createFile(p, .{});
    defer f.close();
    try f.writeAll(buf.items);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Mutation Testing - Records each surviving mutant with its operator and original source line

test "survivorJson emits location, operator, and original line, escaping text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A src_line containing a quote proves std.json escaping (not hand-rolled).
    const s: Survivor = .{
        .file = "src/x.zig",
        .line = 42,
        .original = "<",
        .replacement = "<=",
        .src_line = "return name == \"a\";",
    };
    try testing.expectEqualStrings(
        "{\"type\":\"survivor\",\"file\":\"src/x.zig\",\"line\":42,\"op\":\"< -> <=\"," ++
            "\"original_line\":\"return name == \\\"a\\\";\"}",
        try survivorJson(a, s),
    );
}

// spec: Mutation Testing - Records a mutation summary with the tier, score, and outcome counts

test "summaryJson emits the tier, score, and counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"type\":\"summary\",\"tier\":\"fast\",\"score\":75,\"killed\":3,\"survived\":1," ++
            "\"unviable\":2,\"inconclusive\":0,\"waived\":1,\"cached\":2,\"gated\":true}",
        try summaryJson(a, .{
            .tier = "fast",
            .score = 75,
            .counts = .{ .killed = 3, .survived = 1, .unviable = 2, .inconclusive = 0 },
            .waived = 1,
            .cached = 2,
            .gated = true,
        }),
    );
}

// spec: Mutation Testing - Writes the survivor report under the git-ignored mutate cache dir

test "write emits survivor lines then a summary under the cache dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/mutate-report-proj";
    try std.fs.cwd().makePath(dir);
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("mutate report cleanup: {s}", .{@errorName(e)});

    const survivors = [_]Survivor{
        .{ .file = "src/x.zig", .line = 1, .original = "<", .replacement = "<=", .src_line = "a < b" },
    };
    write(a, dir, &survivors, .{
        .tier = "full",
        .score = 50,
        .counts = .{ .killed = 1, .survived = 1, .unviable = 0, .inconclusive = 0 },
        .waived = 0,
        .cached = 0,
        .gated = true,
    });
    const raw = try std.fs.cwd().readFileAlloc(a, try pathFor(a, dir), 4096);
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "\"type\":\"survivor\"") != null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "\"type\":\"summary\"") != null);
    try testing.expect(lines.next() == null);
}

// spec: Mutation Testing - Persists the exact sampled mutation cohort

test "writeCohort emits a summary and each selected identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/mutate-cohort-proj";
    try std.fs.cwd().makePath(dir);
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("cohort cleanup: {s}", .{@errorName(e)});
    const mutants = [_]gen.Mutant{.{
        .path = "src/x.zig",
        .start = 2,
        .end = 3,
        .original = "<",
        .replacement = "<=",
        .source = .{ .line = 4, .text = "a < b" },
    }};
    writeCohort(a, dir, "full", 9, &mutants, gen.cohortHash(&mutants));
    const p = try std.fmt.allocPrint(a, "{s}/.guardian/cache/{s}", .{ dir, cohort_manifest_name });
    const raw = try std.fs.cwd().readFileAlloc(a, p, 4096);
    try testing.expect(std.mem.indexOf(u8, raw, "\"candidates\":9") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"file\":\"src/x.zig\"") != null);
}
