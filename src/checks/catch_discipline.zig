//! catch-discipline check: reject error-swallowing catches in production code —
//! `catch unreachable` (crash on error), an empty `catch {}` block (silent
//! swallow), and `catch undefined`. Tokenizer-based, so the pattern is flagged
//! only in real code, never in a comment or string.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
};

// Per-file destination for reported violations. `z` and `rel_path` are constant
// for the duration of one `visit`, so bundling them keeps `appendAt` to a small
// parameter list. Findings are buffered rather than rendered on sight: the
// conforming catch a file already uses may sit *below* the offending one (in the
// report that prompted this, two lines below), and the message names it.
const Sink = struct {
    ctx: *ScanCtx,
    z: []const u8,
    rel_path: []const u8,
    findings: std.ArrayList(Finding) = .empty,
    conforming: ?Conforming = null,
};

// One swallowing catch: where it is, and what is wrong with it.
const Finding = struct { pos: usize, what: []const u8 };

// The first error-handling catch this file already gets right. Naming the shape
// the surrounding code uses turns "handle the error" into a one-line edit the
// author can copy — the fix is almost always the neighbouring idiom.
const Conforming = struct { shape: []const u8, pos: usize };

// State machine for the tokenizer scan. Tracks the current parse state and the
// source offset of the most recent `catch` keyword so a violation can be
// reported at the right line.
const State = enum { none, after_catch, in_capture, expect_brace, after_lbrace };

const Scanner = struct {
    state: State = .none,
    catch_pos: usize = 0,

    // Advances the machine by one token. `in_test` exempts idiomatic test
    // assertions like `x catch unreachable`.
    fn step(self: *Scanner, sink: *Sink, t: std.zig.Token, in_test: bool) !void {
        switch (self.state) {
            .none => self.startFrom(t),
            .after_catch => try self.afterCatch(sink, t, in_test),
            .in_capture => if (t.tag == .pipe) {
                self.state = .expect_brace;
            },
            .expect_brace => self.expectBrace(sink, t, in_test),
            .after_lbrace => try self.afterLbrace(sink, t, in_test),
        }
    }

    // In `.none`, only a `catch` keyword is interesting; it opens the machine.
    fn startFrom(self: *Scanner, t: std.zig.Token) void {
        if (t.tag != .keyword_catch) return;
        self.state = .after_catch;
        self.catch_pos = t.loc.start;
    }

    fn afterCatch(self: *Scanner, sink: *Sink, t: std.zig.Token, in_test: bool) !void {
        switch (t.tag) {
            .keyword_unreachable => {
                const what = "catch unreachable in production code";
                if (!in_test) try appendAt(sink, self.catch_pos, what);
                self.state = .none;
            },
            .identifier => {
                try self.reportUndefined(sink, t.loc, in_test);
                self.state = .none;
            },
            .pipe => self.state = .in_capture,
            .l_brace => self.state = .after_lbrace,
            .keyword_catch => self.catch_pos = t.loc.start,
            else => {
                self.noteConforming(sink, t.tag, in_test, .bare);
                self.state = .none;
            },
        }
    }

    // Records the file's first conforming catch — the shape its own code already
    // uses to handle an error — so a violation's message can point at it.
    // Production code only: a `catch return` inside a test block is not
    // necessarily an idiom the surrounding src can copy.
    fn noteConforming(self: *Scanner, sink: *Sink, tag: std.zig.Token.Tag, in_test: bool, form: CatchForm) void {
        if (in_test or sink.conforming != null) return;
        const shape = shapeName(tag, form) orelse return;
        sink.conforming = .{ .shape = shape, .pos = self.catch_pos };
    }

    // `catch undefined` assigns undefined (UB) on error; other identifiers pass.
    fn reportUndefined(self: *Scanner, sink: *Sink, loc: std.zig.Token.Loc, in_test: bool) !void {
        if (in_test) return;
        if (!std.mem.eql(u8, sink.z[loc.start..loc.end], "undefined")) return;
        try appendAt(sink, self.catch_pos, "catch undefined assigns undefined on error");
    }

    // Skip the `|capture|`; the closing pipe leads to the body.
    fn expectBrace(self: *Scanner, sink: *Sink, t: std.zig.Token, in_test: bool) void {
        switch (t.tag) {
            .l_brace => self.state = .after_lbrace,
            .keyword_catch => {
                self.catch_pos = t.loc.start;
                self.state = .after_catch;
            },
            else => {
                self.noteConforming(sink, t.tag, in_test, .captured);
                self.state = .none;
            },
        }
    }

    fn afterLbrace(self: *Scanner, sink: *Sink, t: std.zig.Token, in_test: bool) !void {
        if (t.tag == .r_brace and !in_test) {
            try appendAt(sink, self.catch_pos, "catch block is empty (silently swallows the error)");
        }
        if (t.tag == .keyword_catch) {
            self.catch_pos = t.loc.start;
            self.state = .after_catch;
        } else {
            self.state = .none;
        }
    }
};

// Whether a conforming catch captured the error (`catch |e| return`) or not
// (`catch return`) — quoted back verbatim, so the hint matches the file's style.
const CatchForm = enum { bare, captured };

// The quotable source shape for a conforming catch, or null for a token that
// isn't one of the handled forms.
fn shapeName(tag: std.zig.Token.Tag, form: CatchForm) ?[]const u8 {
    return switch (tag) {
        .keyword_return => switch (form) {
            .bare => "catch return",
            .captured => "catch |e| return",
        },
        .keyword_continue => switch (form) {
            .bare => "catch continue",
            .captured => "catch |e| continue",
        },
        .keyword_break => switch (form) {
            .bare => "catch break",
            .captured => "catch |e| break",
        },
        else => null,
    };
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));

    // Tokenizer-based scan for catch patterns that hide failures:
    //   `catch unreachable`  — crashes instead of handling the error
    //   `catch undefined`    — assigns undefined (UB) on error
    //   `catch {}`           — empty block silently swallows the error
    //   `catch |e| {}`       — captured but empty body, the same swallow
    // The Tokenizer skips //-comments and string literals so we only
    // match real code, not text inside doc-strings or comments.
    // entry.content is already null-terminated by the walker.
    const z = entry.content;
    var sink = Sink{ .ctx = ctx, .z = z, .rel_path = entry.rel_path };
    var tok = std.zig.Tokenizer.init(z);
    var scanner = Scanner{};
    // Inline `test { ... }` blocks are exempt: `x catch unreachable` is an
    // idiomatic (and correct) assertion in a test. Track test scope by brace
    // depth alongside the catch state machine.
    var scope = TestScope{};
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        scope.update(t.tag);
        try scanner.step(&sink, t, scope.in_test);
    }
    try renderFindings(&sink);
}

// Turns the file's buffered findings into violation lines. Deferred to here so
// every message can name the conforming catch the file already contains, even
// when that catch appears further down the file than the violation.
fn renderFindings(sink: *Sink) !void {
    const a = sink.ctx.allocator;
    for (sink.findings.items) |f| {
        const line = lineOf(sink.z, f.pos);
        const msg = if (sink.conforming) |c| try std.fmt.allocPrint(
            a,
            "{s}:{d}: {s} — this file already uses `{s}` at line {d}",
            .{ sink.rel_path, line, f.what, c.shape, lineOf(sink.z, c.pos) },
        ) else try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ sink.rel_path, line, f.what });
        try sink.ctx.violations.append(a, msg);
    }
}

const TestScope = @import("../text.zig").TestScope;

fn appendAt(sink: *Sink, pos: usize, what: []const u8) !void {
    try sink.findings.append(sink.ctx.allocator, .{ .pos = pos, .what = what });
}

const lineOf = @import("../text.zig").lineOf;

/// Entry point for the catch-discipline check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    // Scan src/ only — test files are exempt.
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no catch unreachable in production code", .{});
        return;
    }

    fail("catch discipline FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: handle the error explicitly with a switch or named return — when the finding " ++
        "names a shape the file already uses, copy that one.\n", .{});
    return error.CheckFailed;
}

// spec: Catch Discipline - Rejects catch unreachable in production code
// spec: Catch Discipline - Rejects catch with empty block (silent error swallow)
// spec: Catch Discipline - Rejects catch undefined assigning undefined on error

test "visit catches `catch unreachable`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    const f = std.fs.cwd().openFile("x", .{}) catch unreachable;
        \\    _ = f;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit ignores `catch unreachable` inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "const s = \"catch unreachable\";\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit exempts catch unreachable inside a test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\test "ok" {
        \\    const v = mightFail() catch unreachable;
        \\    _ = v;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
test "visit catches `catch {}`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    list.append(item) catch {};
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows `catch |err| ...`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() !void {
        \\    const f = std.fs.cwd().openFile("x", .{}) catch |err| return err;
        \\    _ = f;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches `catch undefined`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    const n = parse(s) catch undefined;
        \\    _ = n;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit catches `catch |e| {}` empty captured body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    list.append(item) catch |e| {};
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

// spec: Catch Discipline - Names a conforming catch the same file already uses

test "visit quotes the file's own catch shape in the violation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    // The reported case: "catch block is empty" two lines above a `catch return;`
    // the author could have copied. The conforming catch sits BELOW the
    // violation, so the message can only name it after the whole file is scanned.
    const content =
        \\fn x() void {
        \\    list.append(item) catch {};
        \\}
        \\fn y() void {
        \\    list.append(item) catch return;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expectEqualStrings(
        "src/x.zig:2: catch block is empty (silently swallows the error) — " ++
            "this file already uses `catch return` at line 5",
        violations.items[0],
    );

    // A file with no conforming catch to point at keeps the plain message.
    violations.clearRetainingCapacity();
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/y.zig", .content =
        \\fn x() void {
        \\    list.append(item) catch {};
        \\}
    });
    try std.testing.expectEqualStrings(
        "src/y.zig:2: catch block is empty (silently swallows the error)",
        violations.items[0],
    );
}

test "visit allows `catch |e| { handle(e); }` non-empty body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\fn x() void {
        \\    list.append(item) catch |e| { log(e); };
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
