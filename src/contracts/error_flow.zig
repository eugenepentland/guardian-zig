//! Conservative local error exits. This proves simple propagation, identifies
//! explicit benign returns, and labels complex handlers unknown rather than
//! claiming a conditional error return covers every path.
const std = @import("std");
const A = std.mem.Allocator;
const Tag = std.zig.Token.Tag;

/// Whether the catch handler preserves the operation's failure for its caller.
pub const Outcome = enum { propagated, erased, unknown };

const Token = struct { tag: Tag, value: []const u8 };

fn tokens(a: A, source: []const u8) A.Error![]const Token {
    var lexer = std.zig.Tokenizer.init(try a.dupeSentinel(u8, source, 0));
    var out: std.ArrayList(Token) = .empty;
    while (true) {
        const t = lexer.next();
        if (t.tag == .eof) break;
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) continue;
        try out.append(a, .{ .tag = t.tag, .value = source[t.loc.start..t.loc.end] });
    }
    return out.toOwnedSlice(a);
}

fn equal(token: Token, value: []const u8) bool {
    return std.mem.eql(u8, token.value, value);
}

fn join(lhs: Outcome, rhs: Outcome) Outcome {
    if (lhs == .erased or rhs == .erased) return .erased;
    if (lhs == .unknown or rhs == .unknown) return .unknown;
    return .propagated;
}

fn returned(ts: []const Token, capture: []const u8) Outcome {
    if (ts.len == 0) return .erased;
    if (ts[0].tag == .keyword_error) return .propagated;
    if (ts[0].tag == .keyword_try) return .unknown;
    for (ts) |t| {
        if (t.tag == .semicolon or t.tag == .r_brace) break;
        if (t.tag == .l_paren) return .unknown;
    }
    if (capture.len > 0 and equal(ts[0], capture)) {
        if (ts.len == 1 or ts[1].tag == .semicolon or ts[1].tag == .r_brace) return .propagated;
    }
    if (ts[0].tag != .identifier) return .erased;
    for ([_][]const u8{ "null", "true", "false" }) |literal| {
        if (equal(ts[0], literal)) return .erased;
    }
    return .unknown;
}

fn nesting(tag: Tag) i32 {
    return switch (tag) {
        .l_brace, .l_paren, .l_bracket => 1,
        .r_brace, .r_paren, .r_bracket => -1,
        else => 0,
    };
}

fn missingOnly(ts: []const Token) bool {
    return ts.len == 3 and ts[0].tag == .keyword_error and ts[1].tag == .period and equal(ts[2], "FileNotFound");
}

fn switched(ts: []const Token, capture: []const u8, allow_missing: bool, depth: usize) Outcome {
    var start: usize = 0;
    while (start < ts.len and ts[start].tag != .l_brace) : (start += 1) {}
    if (start == ts.len) return .unknown;
    start += 1;
    var arm = start;
    var arrow: ?usize = null;
    var level: i32 = 0;
    var result: Outcome = .propagated;
    var has_else = false;
    for (ts[start..], start..) |t, i| {
        if (level == 0 and t.tag == .equal_angle_bracket_right) arrow = i;
        if (level == 0 and (t.tag == .comma or t.tag == .r_brace) and arrow != null) {
            const cut = arrow.?;
            const labels = ts[arm..cut];
            if (labels.len == 1 and labels[0].tag == .keyword_else) has_else = true;
            if (!(allow_missing and missingOnly(labels))) result = join(result, classify(ts[cut + 1 .. i], capture, allow_missing, depth + 1));
            arm = i + 1;
            arrow = null;
        }
        if (level == 0 and t.tag == .r_brace) break;
        level += nesting(t.tag);
    }
    return if (has_else) result else join(result, .unknown);
}

fn classify(ts: []const Token, capture: []const u8, allow_missing: bool, depth: usize) Outcome {
    if (depth > 32) return .unknown;
    if (ts.len == 0) return .erased;
    if (ts[0].tag == .keyword_switch) return switched(ts, capture, allow_missing, depth);
    if (ts[0].tag == .keyword_return) return returned(ts[1..], capture);
    if (ts[0].tag != .l_brace) return switch (ts[0].tag) {
        .number_literal, .string_literal, .period, .ampersand => .erased,
        .identifier => if (equal(ts[0], "null") or equal(ts[0], "true") or equal(ts[0], "false")) .erased else .unknown,
        else => .unknown,
    };
    var conditional = false;
    var saw_return = false;
    var uncertain_return = false;
    for (ts, 0..) |t, i| {
        switch (t.tag) {
            .keyword_if, .keyword_while, .keyword_for, .keyword_switch => conditional = true,
            .keyword_return => {
                saw_return = true;
                const outcome = returned(ts[i + 1 ..], capture);
                if (outcome == .erased) return .erased;
                uncertain_return = uncertain_return or outcome == .unknown;
            },
            .keyword_break, .keyword_continue => return .unknown,
            else => {},
        }
    }
    const unconditional = saw_return and !conditional;
    if (unconditional and !uncertain_return) return .propagated;
    if (ts.len == 2) return .erased;
    return .unknown;
}

/// Analyze a catch RHS. A missing file may mean absence only for read contracts.
pub fn analyze(a: A, source: []const u8, capture: []const u8, allow_missing: bool) A.Error!Outcome {
    return classify(try tokens(a, source), capture, allow_missing, 0);
}

/// Identifier evidence excludes prose, quoted strings and comments.
pub fn hasIdentifier(a: A, source: []const u8, names: []const []const u8) A.Error!bool {
    for (try tokens(a, source)) |t| {
        if (t.tag != .identifier) continue;
        for (names) |name| if (equal(t, name)) return true;
    }
    return false;
}

// spec: Operation Contracts - Distinguishes propagated errors from defaults and conditional handlers
test "contracts classify error propagation and logged benign exits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Outcome.erased, try analyze(a, "return;", "", false));
    try std.testing.expectEqual(Outcome.unknown, try analyze(a, "{ log.warn(\"bad\"); return doc; }", "err", true));
    try std.testing.expectEqual(Outcome.propagated, try analyze(a, "return error.CannotWrite;", "", false));
    try std.testing.expectEqual(Outcome.propagated, try analyze(a, "{ log.warn(\"bad\"); return err; }", "err", false));
    try std.testing.expectEqual(Outcome.unknown, try analyze(a, "{ if (x) return err; }", "err", false));
    try std.testing.expectEqual(Outcome.unknown, try analyze(a, "return mapError(err);", "err", false));
    try std.testing.expectEqual(Outcome.unknown, try analyze(a, "{ const mapped = err; return mapped; }", "err", false));
    try std.testing.expect(!try hasIdentifier(a, "// rev\nlog(\"rev\");", &.{"rev"}));
}

// spec: Operation Contracts - Allows only explicit missing-file recovery in persistent readers
test "contracts keep absence separate from read failure across switch arms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = "switch (err) { error.FileNotFound => return .missing, else => return err, }";
    try std.testing.expectEqual(Outcome.propagated, try analyze(a, good, "err", true));
    try std.testing.expectEqual(Outcome.erased, try analyze(a, good, "err", false));
    const bad = "switch (err) { error.FileNotFound, error.AccessDenied => return .missing, else => return err, }";
    try std.testing.expectEqual(Outcome.erased, try analyze(a, bad, "err", true));
}
