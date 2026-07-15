//! Token-stream mutant generator for the `mutate` command. Each mutant is
//! one operator- or literal-level change to production code (test blocks
//! are never mutated — mutating a test proves nothing about its strength).
//! Working on the token stream keeps mutants format-stable (`zig fmt`
//! clean) and immune to matches inside strings and comments. The operator
//! set follows the sibling guardians' mutation stages: comparison flips,
//! binary +/- swaps, and/or swaps, and true/false flips.

const std = @import("std");
const text = @import("../text.zig");
const git = @import("../git.zig");

const Allocator = std.mem.Allocator;

const true_lit = "true";
const false_lit = "false";
const cohort_rotate_bits: u6 = 23;

/// Waiver marker: a source line containing this string is excluded from mutant
/// generation. For known *equivalent* mutants — e.g. `>` vs `>=` on a min/max
/// scan — that no test could ever kill, so gating on them is pure noise. An
/// optional reason may follow (`// mutate-ok: boundary equivalence`).
const waiver_marker = "// mutate-ok";

/// Stable source coordinates and original line text for one mutation site.
pub const Source = struct {
    line: u32 = 1,
    /// Zero-based token column. Unlike absolute byte/line offsets this remains
    /// stable when unrelated lines are inserted, while distinguishing two
    /// identical operators on the same source line.
    column: u32 = 0,
    text: []const u8 = "",
};

/// One candidate mutation: replace `content[start..end]` (which reads
/// `original`) with `replacement`. Its nested source coordinates support
/// reporting, diff filtering, and stable cohort identity.
pub const Mutant = struct {
    path: []const u8,
    start: usize,
    end: usize,
    original: []const u8,
    replacement: []const u8,
    source: Source = .{},
};

/// A file's generated mutants plus the 1-indexed lines whose mutation sites
/// were suppressed by a `// mutate-ok` waiver (one entry per suppressed site).
/// Waived sites never run and never score; the lines are surfaced so a
/// deliberately-waived equivalence is visible, and so the fast tier can scope
/// its waiver tally to the diff exactly as it scopes mutants (see waivedInSpans).
pub const GenResult = struct {
    mutants: []const Mutant,
    waived_lines: []const u32 = &.{},
};

/// Generates every mutant for one file's content. Deterministic: mutants
/// are emitted in token order, so identical input yields identical output.
/// Sites on a `// mutate-ok` line are recorded in `waived_lines` and skipped.
pub fn generate(allocator: Allocator, rel_path: []const u8, content: []const u8) Allocator.Error!GenResult {
    const z = try allocator.dupeZ(u8, content);
    var out: std.ArrayList(Mutant) = .empty;
    var waived: std.ArrayList(u32) = .empty;
    var tok = std.zig.Tokenizer.init(z);
    var scope = text.TestScope{};
    var line: u32 = 1;
    var cursor: usize = 0;
    var prev_tag: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        line = advanceLine(z, &cursor, t.loc.start, line);
        const in_test = scope.in_test;
        scope.update(t.tag);
        if (!in_test) {
            if (replacementFor(z, t, prev_tag)) |rep| {
                const source_line_start = lineStart(z, t.loc.start);
                const src = lineTextFrom(z, source_line_start);
                if (isWaived(src)) {
                    try waived.append(allocator, line);
                } else {
                    try out.append(allocator, .{
                        .path = rel_path,
                        .start = t.loc.start,
                        .end = t.loc.end,
                        .original = z[t.loc.start..t.loc.end],
                        .replacement = rep,
                        .source = .{
                            .line = line,
                            .column = @intCast(t.loc.start - source_line_start),
                            .text = src,
                        },
                    });
                }
            }
        }
        prev_tag = t.tag;
    }
    return .{ .mutants = try out.toOwnedSlice(allocator), .waived_lines = try waived.toOwnedSlice(allocator) };
}

/// Count of waived-site lines falling within `spans` — the fast tier's waiver
/// tally, scoped to the diff exactly like `filterToSpans` scopes mutants.
pub fn waivedInSpans(waived_lines: []const u32, spans: []const git.LineSpan) u32 {
    var n: u32 = 0;
    for (waived_lines) |ln| {
        if (anySpanContains(spans, ln)) n += 1;
    }
    return n;
}

/// True when `src_line` carries the `// mutate-ok` waiver marker.
fn isWaived(src_line: []const u8) bool {
    return std.mem.indexOf(u8, src_line, waiver_marker) != null;
}

/// The full source line (no trailing newline) containing byte `offset`, sliced
/// from `z`. Feeds both the survivor report (the exact line an agent must
/// strengthen a test against) and the `// mutate-ok` waiver scan.
fn lineStart(z: []const u8, offset: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, z[0..offset], '\n')) |i| i + 1 else 0;
}

fn lineTextFrom(z: []const u8, start: usize) []const u8 {
    const end = std.mem.indexOfScalarPos(u8, z, start, '\n') orelse z.len;
    return z[start..end];
}

/// The mutated text for one token, or null when the token isn't a mutation
/// site. `prev_tag` disambiguates binary minus from unary negation — Zig
/// has no unary `+`, so mutating `-x` to `+x` would only make unviable
/// (compile-error) mutants that waste a build each.
fn replacementFor(z: []const u8, t: std.zig.Token, prev_tag: std.zig.Token.Tag) ?[]const u8 {
    return switch (t.tag) {
        .equal_equal => "!=",
        .bang_equal => "==",
        .angle_bracket_left => "<=",
        .angle_bracket_left_equal => "<",
        .angle_bracket_right => ">=",
        .angle_bracket_right_equal => ">",
        .keyword_and => "or",
        .keyword_or => "and",
        .plus => "-",
        .plus_equal => "-=",
        .minus_equal => "+=",
        .minus => if (endsValue(prev_tag)) "+" else null,
        .identifier => boolFlip(z[t.loc.start..t.loc.end]),
        else => null,
    };
}

/// True when `tag` can end a value expression, making a following `-` a
/// binary operator rather than unary negation.
fn endsValue(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .identifier, .number_literal, .char_literal, .string_literal, .r_paren, .r_bracket => true,
        else => false,
    };
}

/// `true` ↔ `false` for the boolean literal identifiers; null otherwise.
fn boolFlip(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, true_lit)) return false_lit;
    if (std.mem.eql(u8, name, false_lit)) return true_lit;
    return null;
}

/// Advances a monotone byte cursor to `target`, counting newlines into the
/// running 1-indexed line number (tokens arrive in source order).
/// Asserts the cursor has not already passed `target`: the caller feeds tokens
/// in ascending start order, so a backward target would silently miscount lines.
fn advanceLine(z: []const u8, cursor: *usize, target: usize, line: u32) u32 {
    std.debug.assert(cursor.* <= target);
    var ln = line;
    while (cursor.* < target and cursor.* < z.len) : (cursor.* += 1) {
        if (z[cursor.*] == '\n') ln += 1;
    }
    return ln;
}

/// Keeps only mutants whose line falls inside one of `spans` — the fast
/// tier's scope: mutate what the diff touched, nothing else.
pub fn filterToSpans(
    allocator: Allocator,
    mutants: []const Mutant,
    spans: []const git.LineSpan,
) Allocator.Error![]const Mutant {
    var out: std.ArrayList(Mutant) = .empty;
    for (mutants) |m| {
        if (anySpanContains(spans, m.source.line)) try out.append(allocator, m);
    }
    return out.toOwnedSlice(allocator);
}

fn anySpanContains(spans: []const git.LineSpan, line: u32) bool {
    for (spans) |s| {
        if (s.contains(line)) return true;
    }
    return false;
}

/// A stable identity hash used for deterministic sampling and cohort manifests.
/// It deliberately excludes absolute byte/line offsets: inserting unrelated
/// source above a mutation site must not reshuffle the campaign. The source
/// line, stable within-line column, and operator swap uniquely identify sites.
pub fn identityHash(m: Mutant) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(m.path);
    h.update("\x00");
    h.update(m.source.text);
    h.update("\x00");
    const column_end = @min(@as(usize, m.source.column), m.source.text.len);
    h.update(m.source.text[0..column_end]);
    h.update("\x00");
    h.update(m.original);
    h.update("\x00");
    h.update(m.replacement);
    return h.final();
}

const Ranked = struct { hash: u64, mutant: Mutant };

fn rankedLess(_: void, lhs: Ranked, rhs: Ranked) bool {
    if (lhs.hash != rhs.hash) return lhs.hash < rhs.hash;
    const path_order = std.mem.order(u8, lhs.mutant.path, rhs.mutant.path);
    if (path_order != .eq) return path_order == .lt;
    return lhs.mutant.start < rhs.mutant.start;
}

/// Deterministically samples the identities with the lowest stable hashes.
/// Adding an unrelated candidate therefore displaces at most one selected
/// mutant instead of shifting nearly the entire every-kth cohort.
pub fn sample(allocator: Allocator, mutants: []const Mutant, max: u32) Allocator.Error![]const Mutant {
    if (max == 0 or mutants.len <= max) return mutants;
    const ranked = try allocator.alloc(Ranked, mutants.len);
    for (mutants, ranked) |m, *r| r.* = .{ .hash = identityHash(m), .mutant = m };
    std.mem.sort(Ranked, ranked, {}, rankedLess);
    const out = try allocator.alloc(Mutant, max);
    for (out, ranked[0..max]) |*m, r| m.* = r.mutant;
    return out;
}

/// Digest of the exact selected identities, independent of their execution
/// order. Ratchets only compare scores when this digest matches.
pub fn cohortHash(mutants: []const Mutant) u64 {
    var xor: u64 = 0;
    var sum: u64 = 0;
    for (mutants) |m| {
        const h = identityHash(m);
        xor ^= h;
        sum +%= h *% 0x9e3779b97f4a7c15;
    }
    return xor ^ std.math.rotl(u64, sum, cohort_rotate_bits) ^ @as(u64, @intCast(mutants.len));
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn countReplacement(mutants: []const Mutant, replacement: []const u8) usize {
    var n: usize = 0;
    for (mutants) |m| {
        if (std.mem.eql(u8, m.replacement, replacement)) n += 1;
    }
    return n;
}

// spec: Mutation Testing - Generates mutants by flipping comparison operators outside test blocks

test "generate flips comparison operators in production code only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = (try generate(arena.allocator(), "src/x.zig",
        \\pub fn lt(a: u32, b: u32) bool { return a < b; }
        \\pub fn ge(a: u32, b: u32) bool { return a >= b; }
        \\test "cmp" { try expect(1 == 1); }
    )).mutants;
    // `<` -> `<=`, `>=` -> `>`; the `==` inside the test block is skipped.
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "<="));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, ">"));
    try testing.expectEqual(@as(usize, 0), countReplacement(out, "!="));
    try testing.expectEqual(@as(u32, 1), out[0].source.line);
}

// spec: Mutation Testing - Generates mutants by swapping binary plus and minus operators

test "generate swaps binary plus and minus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = (try generate(arena.allocator(), "src/x.zig",
        \\pub fn calc(a: u32, b: u32) u32 { return a + b - 1; }
    )).mutants;
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "-"));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "+"));
}

// spec: Mutation Testing - Skips unary minus when generating arithmetic mutants

test "generate skips unary minus (no unary plus exists in Zig)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = (try generate(arena.allocator(), "src/x.zig",
        \\pub fn neg(a: i32) i32 { return -a; }
        \\pub fn expr(a: i32) i32 { return (a) - -a; }
    )).mutants;
    // Only the binary minus after `)` mutates; both unary sites are skipped.
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "+"));
}

// spec: Mutation Testing - Generates mutants by swapping boolean and/or keywords

test "generate swaps and/or keywords" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = (try generate(arena.allocator(), "src/x.zig",
        \\pub fn both(a: bool, b: bool, c: bool) bool { return a and (b or c); }
    )).mutants;
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "or"));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "and"));
}

// spec: Mutation Testing - Generates mutants by flipping true and false literals

test "generate flips boolean literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = (try generate(arena.allocator(), "src/x.zig",
        \\pub const ON = true;
        \\pub fn off() bool { return false; }
    )).mutants;
    try testing.expectEqual(@as(usize, 1), countReplacement(out, false_lit));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, true_lit));
}

// spec: Mutation Testing - Excludes a mutate-ok waived line from generation and counts the waiver

test "generate skips a mutate-ok line and counts it as waived" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try generate(arena.allocator(), "src/x.zig",
        \\pub fn hi(a: u32, b: u32) bool { return a > b; } // mutate-ok: boundary equivalence
        \\pub fn lo(a: u32, b: u32) bool { return a < b; }
    );
    // The `>` site on the waived line (1) is suppressed and recorded; the `<` on
    // line 2 still mutates, so the waiver never touches non-waived lines.
    try testing.expectEqual(@as(usize, 1), res.waived_lines.len);
    try testing.expectEqual(@as(u32, 1), res.waived_lines[0]);
    try testing.expectEqual(@as(usize, 1), res.mutants.len);
    try testing.expectEqualStrings("<=", res.mutants[0].replacement);
    try testing.expectEqual(@as(u32, 2), res.mutants[0].source.line);
    // The fast tier scopes the waiver tally to the diff: a span covering only
    // line 2 sees no waiver; one covering line 1 counts it.
    try testing.expectEqual(@as(u32, 0), waivedInSpans(res.waived_lines, &.{.{ .start = 2, .len = 1 }}));
    try testing.expectEqual(@as(u32, 1), waivedInSpans(res.waived_lines, &.{.{ .start = 1, .len = 1 }}));
}

// spec: Mutation Testing - Samples mutants by stable identity hash

test "stable hash sampling is not reshuffled by an unrelated insertion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = (try generate(a, "src/x.zig",
        \\pub fn a(x: bool) bool { return true and x; }
        \\pub fn b(x: bool) bool { return false or x; }
        \\pub fn c(x: u32) bool { return x > 2; }
    )).mutants;
    const shifted = (try generate(a, "src/x.zig",
        \\pub const unrelated = 1;
        \\pub fn a(x: bool) bool { return true and x; }
        \\pub fn b(x: bool) bool { return false or x; }
        \\pub fn c(x: u32) bool { return x > 2; }
    )).mutants;
    const first = try sample(a, base, 3);
    const second = try sample(a, shifted, 3);
    try testing.expectEqual(cohortHash(first), cohortHash(second));
    for (first, second) |lhs, rhs| try testing.expectEqual(identityHash(lhs), identityHash(rhs));
}

// spec: Mutation Testing - Distinguishes repeated mutation sites on one line in the cohort identity

test "stable identity distinguishes repeated operators on one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mutants = (try generate(
        arena.allocator(),
        "src/x.zig",
        "pub fn all(a: bool, b: bool, c: bool) bool { return a and b and c; }",
    )).mutants;
    try testing.expectEqual(@as(usize, 2), mutants.len);
    try testing.expect(mutants[0].source.column != mutants[1].source.column);
    try testing.expect(identityHash(mutants[0]) != identityHash(mutants[1]));
}

// spec: Mutation Testing - Records the original source line on each generated mutant

test "generate carries the original source line for the survivor report" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try generate(arena.allocator(), "src/x.zig",
        \\pub fn lt(a: u32, b: u32) bool { return a < b; }
    );
    try testing.expectEqual(@as(usize, 1), res.mutants.len);
    // src_line is the whole line's text — the exact context an agent needs.
    try testing.expectEqualStrings(
        "pub fn lt(a: u32, b: u32) bool { return a < b; }",
        res.mutants[0].source.text,
    );
}

// spec: Mutation Testing - Restricts fast-tier mutants to added line spans

test "filterToSpans keeps only mutants on added lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = (try generate(a, "src/x.zig",
        \\pub fn one(x: u32) bool { return x == 1; }
        \\pub fn two(x: u32) bool { return x == 2; }
    )).mutants;
    try testing.expectEqual(@as(usize, 2), out.len);
    const kept = try filterToSpans(a, out, &.{.{ .start = 2, .len = 1 }});
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqual(@as(u32, 2), kept[0].source.line);
}

// spec: Mutation Testing - Samples mutants deterministically down to the configured cap

test "sample takes a deterministic identity-hash subset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: [10]Mutant = undefined;
    for (&all, 0..) |*m, i| {
        m.* = .{
            .path = "p",
            .start = i,
            .end = i,
            .original = "",
            .replacement = "",
            .source = .{ .line = @intCast(i + 1) },
        };
    }
    const picked = try sample(a, &all, 3);
    try testing.expectEqual(@as(usize, 3), picked.len);
    const again = try sample(a, &all, 3);
    try testing.expectEqual(@as(u32, 1), picked[0].source.line);
    try testing.expectEqual(@as(u32, 2), picked[1].source.line);
    try testing.expectEqual(@as(u32, 3), picked[2].source.line);
    try testing.expectEqualSlices(Mutant, picked, again);
    // Under the cap, the input is returned unchanged.
    const untouched = try sample(a, picked, 8);
    try testing.expectEqual(@as(usize, 3), untouched.len);
}

// spec: Assertion Discipline - Deterministic mutant sampling never selects an out-of-range candidate
test "sample stays in bounds when the candidate list dwarfs the cap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: [100]Mutant = undefined;
    for (&all, 0..) |*m, i| {
        m.* = .{
            .path = "p",
            .start = i,
            .end = i,
            .original = "",
            .replacement = "",
            .source = .{ .line = @intCast(i + 1) },
        };
    }
    // Equal hashes exercise deterministic tie-breaking across the whole list.
    const picked = try sample(a, &all, 7);
    try testing.expectEqual(@as(usize, 7), picked.len);
    try testing.expectEqual(@as(u32, 1), picked[0].source.line);
    try testing.expectEqual(@as(u32, 7), picked[6].source.line);
}
