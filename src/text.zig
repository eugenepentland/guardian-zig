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
