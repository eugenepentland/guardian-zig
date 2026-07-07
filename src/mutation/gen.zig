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

const TRUE_LIT = "true";
const FALSE_LIT = "false";

/// One candidate mutation: replace `content[start..end]` (which reads
/// `original`) with `replacement`. `line` is 1-indexed for reporting and
/// for fast-tier span filtering.
pub const Mutant = struct {
    path: []const u8,
    start: usize,
    end: usize,
    original: []const u8,
    replacement: []const u8,
    line: u32,
};

/// Generates every mutant for one file's content. Deterministic: mutants
/// are emitted in token order, so identical input yields identical output.
pub fn generate(allocator: Allocator, rel_path: []const u8, content: []const u8) Allocator.Error![]const Mutant {
    const z = try allocator.dupeZ(u8, content);
    var out: std.ArrayListUnmanaged(Mutant) = .empty;
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
                try out.append(allocator, .{
                    .path = rel_path,
                    .start = t.loc.start,
                    .end = t.loc.end,
                    .original = z[t.loc.start..t.loc.end],
                    .replacement = rep,
                    .line = line,
                });
            }
        }
        prev_tag = t.tag;
    }
    return out.toOwnedSlice(allocator);
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
    if (std.mem.eql(u8, name, TRUE_LIT)) return FALSE_LIT;
    if (std.mem.eql(u8, name, FALSE_LIT)) return TRUE_LIT;
    return null;
}

/// Advances a monotone byte cursor to `target`, counting newlines into the
/// running 1-indexed line number (tokens arrive in source order).
fn advanceLine(z: []const u8, cursor: *usize, target: usize, line: u32) u32 {
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
    var out: std.ArrayListUnmanaged(Mutant) = .empty;
    for (mutants) |m| {
        if (anySpanContains(spans, m.line)) try out.append(allocator, m);
    }
    return out.toOwnedSlice(allocator);
}

fn anySpanContains(spans: []const git.LineSpan, line: u32) bool {
    for (spans) |s| {
        if (s.contains(line)) return true;
    }
    return false;
}

/// Deterministically samples down to `max` mutants by taking every k-th
/// one, spreading coverage across the whole candidate list without RNG
/// (guardian bans ambient randomness — same input, same sample).
pub fn sample(allocator: Allocator, mutants: []const Mutant, max: u32) Allocator.Error![]const Mutant {
    if (max == 0 or mutants.len <= max) return mutants;
    const step = mutants.len / max;
    const out = try allocator.alloc(Mutant, max);
    for (out, 0..) |*m, i| m.* = mutants[i * step];
    return out;
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
    const out = try generate(arena.allocator(), "src/x.zig",
        \\pub fn lt(a: u32, b: u32) bool { return a < b; }
        \\pub fn ge(a: u32, b: u32) bool { return a >= b; }
        \\test "cmp" { try expect(1 == 1); }
    );
    // `<` -> `<=`, `>=` -> `>`; the `==` inside the test block is skipped.
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "<="));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, ">"));
    try testing.expectEqual(@as(usize, 0), countReplacement(out, "!="));
    try testing.expectEqual(@as(u32, 1), out[0].line);
}

// spec: Mutation Testing - Generates mutants by swapping binary plus and minus operators

test "generate swaps binary plus and minus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try generate(arena.allocator(), "src/x.zig",
        \\pub fn calc(a: u32, b: u32) u32 { return a + b - 1; }
    );
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "-"));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "+"));
}

// spec: Mutation Testing - Skips unary minus when generating arithmetic mutants

test "generate skips unary minus (no unary plus exists in Zig)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try generate(arena.allocator(), "src/x.zig",
        \\pub fn neg(a: i32) i32 { return -a; }
        \\pub fn expr(a: i32) i32 { return (a) - -a; }
    );
    // Only the binary minus after `)` mutates; both unary sites are skipped.
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "+"));
}

// spec: Mutation Testing - Generates mutants by swapping boolean and/or keywords

test "generate swaps and/or keywords" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try generate(arena.allocator(), "src/x.zig",
        \\pub fn both(a: bool, b: bool, c: bool) bool { return a and (b or c); }
    );
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "or"));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, "and"));
}

// spec: Mutation Testing - Generates mutants by flipping true and false literals

test "generate flips boolean literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try generate(arena.allocator(), "src/x.zig",
        \\pub const ON = true;
        \\pub fn off() bool { return false; }
    );
    try testing.expectEqual(@as(usize, 1), countReplacement(out, FALSE_LIT));
    try testing.expectEqual(@as(usize, 1), countReplacement(out, TRUE_LIT));
}

// spec: Mutation Testing - Restricts fast-tier mutants to added line spans

test "filterToSpans keeps only mutants on added lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try generate(a, "src/x.zig",
        \\pub fn one(x: u32) bool { return x == 1; }
        \\pub fn two(x: u32) bool { return x == 2; }
    );
    try testing.expectEqual(@as(usize, 2), out.len);
    const kept = try filterToSpans(a, out, &.{.{ .start = 2, .len = 1 }});
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqual(@as(u32, 2), kept[0].line);
}

// spec: Mutation Testing - Samples mutants deterministically down to the configured cap

test "sample takes a deterministic evenly-strided subset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: [10]Mutant = undefined;
    for (&all, 0..) |*m, i| {
        m.* = .{ .path = "p", .start = i, .end = i, .original = "", .replacement = "", .line = @intCast(i + 1) };
    }
    const picked = try sample(a, &all, 3);
    try testing.expectEqual(@as(usize, 3), picked.len);
    // Stride 10/3 = 3: indices 0, 3, 6 — stable across runs.
    try testing.expectEqual(@as(u32, 1), picked[0].line);
    try testing.expectEqual(@as(u32, 4), picked[1].line);
    try testing.expectEqual(@as(u32, 7), picked[2].line);
    // Under the cap, the input is returned unchanged.
    const untouched = try sample(a, picked, 8);
    try testing.expectEqual(@as(usize, 3), untouched.len);
}
