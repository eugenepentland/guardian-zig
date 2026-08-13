//! Small text/token-scan helpers shared by the checks, so the byte→line
//! computation and inline-test-scope tracking live in one place instead of
//! being copy-pasted into every tokenizer-based check.
const std = @import("std");

/// 1-indexed source line containing `byte_offset` (counts preceding newlines).
pub fn lineOf(source: []const u8, byte_offset: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < byte_offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

/// Forward-only line counter for a scan that visits ascending byte offsets.
/// `lineOf` restarts at byte 0 every call, so a check asking for the line of
/// each of a file's declarations is quadratic in file size; this walks the
/// source once. Offsets must not go backwards — `at` asserts it.
pub const LineCursor = struct {
    offset: usize = 0,
    line: u32 = 1,

    /// The 1-indexed line containing `byte_offset`, advancing the cursor to it.
    ///
    /// Asserts `byte_offset` is at or after the previous query: this counts
    /// newlines forward only, so a backwards offset would report a line number
    /// that is silently too high.
    pub fn at(self: *LineCursor, source: []const u8, byte_offset: usize) u32 {
        std.debug.assert(byte_offset >= self.offset);
        const end = @min(byte_offset, source.len);
        while (self.offset < end) : (self.offset += 1) {
            if (source[self.offset] == '\n') self.line += 1;
        }
        return self.line;
    }
};

/// Brace-depth tracker for inline `test { ... }` scope. Feed every token tag
/// to `update`; `in_test` is true while the tokenizer is inside a test body.
/// Discipline checks use this to exempt idiomatic test assertions like
/// `x catch unreachable`.
pub const TestScope = struct {
    depth: u32 = 0,
    test_depth: u32 = 0,
    in_test: bool = false,
    pending: bool = false,

    /// Advances the tracker for one token tag.
    pub fn update(self: *TestScope, tag: std.zig.Token.Tag) void {
        switch (tag) {
            .keyword_test => self.pending = true,
            .l_brace => {
                self.depth += 1;
                if (self.pending) {
                    self.in_test = true;
                    self.test_depth = self.depth;
                    self.pending = false;
                }
            },
            .r_brace => {
                if (self.in_test and self.depth == self.test_depth) self.in_test = false;
                if (self.depth > 0) self.depth -= 1;
            },
            else => {},
        }
        // While inside a test body the opening brace's depth is never below the
        // current depth: the closing brace clears in_test at depth == test_depth
        // before decrementing, so depth never falls under test_depth while in_test.
        std.debug.assert(!self.in_test or self.test_depth <= self.depth);
    }
};

test "lineOf counts newlines up to the offset" {
    const s = "a\nbb\nccc";
    try std.testing.expectEqual(@as(u32, 1), lineOf(s, 0));
    try std.testing.expectEqual(@as(u32, 2), lineOf(s, 2));
    try std.testing.expectEqual(@as(u32, 3), lineOf(s, 5));
    // Past the end clamps to the last line rather than overrunning.
    try std.testing.expectEqual(@as(u32, 3), lineOf(s, 999));
}

// spec: Text Helpers - Counts lines forward across ascending offsets in one pass

test "LineCursor reports the same lines as lineOf while walking forward" {
    const s = "a\nbb\nccc\ndddd";
    var cursor: LineCursor = .{};
    try std.testing.expectEqual(lineOf(s, 0), cursor.at(s, 0));
    try std.testing.expectEqual(lineOf(s, 2), cursor.at(s, 2));
    // Repeating an offset is allowed and does not advance the count.
    try std.testing.expectEqual(lineOf(s, 2), cursor.at(s, 2));
    try std.testing.expectEqual(lineOf(s, 5), cursor.at(s, 5));
    try std.testing.expectEqual(lineOf(s, 9), cursor.at(s, 9));
    // Past the end clamps to the last line, exactly as lineOf does.
    try std.testing.expectEqual(lineOf(s, 999), cursor.at(s, 999));
}

test "TestScope is in_test only inside a test body" {
    var scope = TestScope{};
    scope.update(.keyword_test);
    try std.testing.expect(!scope.in_test);
    scope.update(.l_brace); // enter test body
    try std.testing.expect(scope.in_test);
    scope.update(.l_brace); // nested block
    try std.testing.expect(scope.in_test);
    scope.update(.r_brace); // leave nested block
    try std.testing.expect(scope.in_test);
    scope.update(.r_brace); // leave test body
    try std.testing.expect(!scope.in_test);
}

// Brace/test-keyword shapes (balanced, nested, and deliberately unbalanced) so
// the default `zig build test` smoke run walks the tracker through real token
// streams before `zig build test --fuzz` explores further.
const test_scope_fuzz_corpus = [_][]const u8{
    "test { }",
    "test { test { } }",
    "}}}{{{",
    "test {",
    "fn f() void { if (x) {} }",
};
const fuzz_input_bytes = 64 * 1024;

/// One fuzz iteration for the inline-test scope tracker: feeding the token tags
/// of arbitrary source through `update` must never crash — the closing-brace
/// path is guarded against underflow — and must uphold the same invariant
/// `update` asserts, `test_depth <= depth` while `in_test`. The internal assert
/// traps in Debug; re-checking it here turns a fuzz counterexample into a named
/// test failure rather than a bare panic.
fn fuzzTestScope(allocator: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [fuzz_input_bytes]u8 = undefined;
    const input = input_buffer[0..smith.slice(&input_buffer)];
    const z = try allocator.dupeSentinel(u8, input, 0);
    defer allocator.free(z);
    var tok = std.zig.Tokenizer.init(z);
    var scope = TestScope{};
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        scope.update(t.tag);
        try std.testing.expect(!scope.in_test or scope.test_depth <= scope.depth);
    }
}

// spec: Fuzzing - Fuzzing the inline-test scope tracker never crashes and holds its depth invariant
test "fuzz: TestScope tracker tolerates arbitrary source tokens" {
    // The allocator rides in as the fuzz context, so the global only appears in
    // this (exempt) test block, not the helper body.
    try std.testing.fuzz(std.testing.allocator, fuzzTestScope, .{ .corpus = &test_scope_fuzz_corpus });
}
