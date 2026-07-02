const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const min_occurrences: u32 = 3;
// Length threshold tuned above 7 chars to skip common short identifiers
// ("init", "time", "enabled") that happen to recur as token literals in
// rule definitions or TOML keys without representing duplicated knowledge.
const min_length: usize = 8;

// ── In-file repeated literals ───────────────────────────────────────────

/// Pure-function entry: scans `content` for string literals that occur
/// `min_occurrences` or more times within a single file.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try a.dupeZ(u8, content);

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(a);

    try countLiterals(a, z, &counts);
    return collectViolations(allocator, rel_path, &counts);
}

/// Tokenizes `z` and tallies every non-test string literal at or above the
/// minimum length into `counts`.
fn countLiterals(
    a: Allocator,
    z: [:0]const u8,
    counts: *std.StringHashMapUnmanaged(u32),
) Allocator.Error!void {
    var tok = std.zig.Tokenizer.init(z);
    var scan: ScanState = .{};
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        const inner = scan.step(z, t) orelse continue;
        if (inner.len < min_length) continue;
        const gop = try counts.getOrPut(a, inner);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
}

/// Brace/test tracking used while walking tokens.
const ScanState = struct {
    depth: u32 = 0,
    in_test: bool = false,
    test_depth: u32 = 0,
    pending_test: bool = false,

    /// Updates state for `t` and returns the inner text of a countable
    /// string literal, or null when the token is not one to count.
    fn step(self: *ScanState, z: [:0]const u8, t: std.zig.Token) ?[]const u8 {
        switch (t.tag) {
            .keyword_test => self.pending_test = true,
            .l_brace => self.openBrace(),
            .r_brace => self.closeBrace(),
            .string_literal => return self.literalInner(z, t),
            else => {},
        }
        return null;
    }

    fn openBrace(self: *ScanState) void {
        self.depth += 1;
        if (!self.pending_test) return;
        self.in_test = true;
        self.test_depth = self.depth;
        self.pending_test = false;
    }

    fn closeBrace(self: *ScanState) void {
        if (self.depth > 0) self.depth -= 1;
        if (self.in_test and self.depth < self.test_depth) self.in_test = false;
    }

    fn literalInner(self: *ScanState, z: [:0]const u8, t: std.zig.Token) ?[]const u8 {
        if (self.in_test) return null;
        const raw = z[t.loc.start..t.loc.end];
        if (raw.len < min_length + 2) return null;
        return raw[1 .. raw.len - 1];
    }
};

/// Builds a violation message for every literal seen `min_occurrences`+ times.
fn collectViolations(
    allocator: Allocator,
    rel_path: []const u8,
    counts: *std.StringHashMapUnmanaged(u32),
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = counts.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.* < min_occurrences) continue;
        const msg = try std.fmt.allocPrint(
            allocator,
            "{s}: string literal {s} appears {d} times — extract a const",
            .{ rel_path, e.key_ptr.*, e.value_ptr.* },
        );
        try violations.append(allocator, msg);
    }
    return violations.toOwnedSlice(allocator);
}

// ── Cross-file duplicate string consts (folded in from dup-const) ────────

const Decl = struct {
    file: []const u8,
    name: []const u8,
    value: []const u8,
};

/// Mutable state carried across tokens while scanning for a top-level
/// `(pub) const NAME = "literal";` declaration.
const ConstScanState = struct {
    depth: i32 = 0,
    pending_const_at_depth0: bool = false,
    pending_name: ?[]const u8 = null,
    pending_after_eq: bool = false,

    fn reset(self: *ConstScanState) void {
        self.pending_const_at_depth0 = false;
        self.pending_name = null;
        self.pending_after_eq = false;
    }
};

/// Starts tracking a declaration when a `const` opens one at depth 0. A `const`
/// inside a type (`[]const u8`, `*const T`) arrives while we're already tracking
/// one — ignoring it keeps the real name instead of capturing the type.
fn beginConst(state: *ConstScanState) void {
    if (state.pending_const_at_depth0) return;
    state.pending_const_at_depth0 = (state.depth == 0);
    state.pending_name = null;
    state.pending_after_eq = false;
}

/// Captures the first identifier after `const` as the declaration's name.
fn recordName(state: *ConstScanState, name: []const u8) void {
    if (state.pending_const_at_depth0 and state.pending_name == null) {
        state.pending_name = name;
    }
}

/// Notes that `=` was seen for the tracked `const NAME`, arming value capture.
fn markAfterEq(state: *ConstScanState) void {
    if (state.pending_const_at_depth0 and state.pending_name != null) {
        state.pending_after_eq = true;
    }
}

/// Append destination for collected decls, bundling shared fields so per-token
/// helpers stay within the parameter limit.
const Sink = struct {
    allocator: Allocator,
    file: []const u8,
    out: *std.ArrayListUnmanaged(Decl),
};

/// Appends a completed `NAME = "value"` decl when `raw` is a quoted literal.
fn appendStringLiteral(sink: Sink, name: []const u8, raw: []const u8) !void {
    const quoted = raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"';
    if (!quoted) return;
    try sink.out.append(sink.allocator, .{
        .file = sink.file,
        .name = name,
        .value = raw[1 .. raw.len - 1],
    });
}

/// Tokenizer-based scan for top-level `(pub) const NAME = "literal";`. Tracks
/// brace depth so consts inside function bodies are ignored.
fn extractFileScopeStringConsts(
    allocator: Allocator,
    file: []const u8,
    content: []const u8,
    out: *std.ArrayListUnmanaged(Decl),
) !void {
    const z = try allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var state: ConstScanState = .{};
    const sink: Sink = .{ .allocator = allocator, .file = file, .out = out };

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        switch (t.tag) {
            .l_brace => state.depth += 1,
            .r_brace => state.depth -= 1,
            .keyword_const => beginConst(&state),
            .identifier => recordName(&state, z[t.loc.start..t.loc.end]),
            .equal => markAfterEq(&state),
            .string_literal => try onStringLiteral(&state, sink, z[t.loc.start..t.loc.end]),
            .semicolon => state.reset(),
            else => if (state.pending_after_eq) state.reset(),
        }
    }
}

/// Handles a `string_literal` token: when a value is expected, records the decl
/// (quoted literals only) and resets scan state. Ignored otherwise.
fn onStringLiteral(state: *ConstScanState, sink: Sink, raw: []const u8) !void {
    if (!state.pending_after_eq) return;
    try appendStringLiteral(sink, state.pending_name.?, raw);
    state.reset();
}

const Group = struct {
    name: []const u8,
    value: []const u8,
    files: []const []const u8,
};

fn findDuplicates(allocator: Allocator, decls: []const Decl) ![]const Group {
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    var seen: std.ArrayListUnmanaged(usize) = .empty;
    defer seen.deinit(allocator);

    for (decls, 0..) |d, i| {
        if (indexSeen(seen.items, i)) continue;
        var matches: std.ArrayListUnmanaged([]const u8) = .empty;
        try matches.append(allocator, d.file);
        try seen.append(allocator, i);
        for (decls[i + 1 ..], i + 1..) |d2, j| {
            if (std.mem.eql(u8, d.name, d2.name) and std.mem.eql(u8, d.value, d2.value)) {
                try matches.append(allocator, d2.file);
                try seen.append(allocator, j);
            }
        }
        if (matches.items.len > 1) {
            try groups.append(allocator, .{
                .name = d.name,
                .value = d.value,
                .files = try matches.toOwnedSlice(allocator),
            });
        }
    }
    return groups.toOwnedSlice(allocator);
}

fn indexSeen(seen: []const usize, i: usize) bool {
    for (seen) |j| if (j == i) return true;
    return false;
}

// ── Run: one walk, both analyses ────────────────────────────────────────

const MergedCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    decls: *std.ArrayListUnmanaged(Decl),
};

fn mergedVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *MergedCtx = @ptrCast(@alignCast(raw_ctx));
    const out = try analyzeContent(ctx.allocator, entry.rel_path, entry.content);
    for (out) |line| try ctx.violations.append(ctx.allocator, line);
    try extractFileScopeStringConsts(ctx.allocator, entry.rel_path, entry.content, ctx.decls);
}

/// Entry point for the repeated-string-literal check (in-file repeats +
/// cross-file duplicate named consts).
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    var mctx: MergedCtx = .{ .allocator = allocator, .violations = &violations, .decls = &decls };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &mctx, .visit = mergedVisit });

    const groups = try findDuplicates(allocator, decls.items);
    for (groups) |g| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "duplicate const {s} = \"{s}\" across {d} files",
            .{ g.name, g.value, g.files.len },
        );
        try violations.append(allocator, msg);
    }

    if (violations.items.len == 0) {
        reporter.ok("repeated-string-literal: no repeated literals or duplicate consts", .{});
        return;
    }
    reporter.fail("repeated-string-literal FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: extract the literal/const into a shared file-scope const and import it.\n", .{});
    return error.CheckFailed;
}

// spec: Tier 2 Anti-patterns - Rejects identical string literals appearing 3 or more times in a single file
// spec: Duplicate Const - Rejects duplicate file-scope string-literal consts (same name and value) across files

test "analyzeContent flags 3 copies of the same literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn a() []const u8 { return "/etc/something"; }
        \\fn b() []const u8 { return "/etc/something"; }
        \\fn c() []const u8 { return "/etc/something"; }
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows 2 copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn a() []const u8 { return "abcd"; }
        \\fn b() []const u8 { return "abcd"; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "extractFileScopeStringConsts finds top-level consts and keeps real names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    const content =
        \\const A = "alpha";
        \\pub const Greeting: []const u8 = "hi";
        \\pub const N = 42;
        \\fn x() void { const inside = "ignore-me"; }
    ;
    try extractFileScopeStringConsts(a, "src/x.zig", content, &decls);
    try std.testing.expectEqual(@as(usize, 2), decls.items.len);
    try std.testing.expectEqualStrings("A", decls.items[0].name);
    try std.testing.expectEqualStrings("alpha", decls.items[0].value);
    // The `const` inside `[]const u8` must not overwrite the real name.
    try std.testing.expectEqualStrings("Greeting", decls.items[1].name);
    try std.testing.expectEqualStrings("hi", decls.items[1].value);
}

test "findDuplicates groups by (name, value) and ignores singletons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = [_]Decl{
        .{ .file = "a.zig", .name = "X", .value = "shared" },
        .{ .file = "b.zig", .name = "X", .value = "shared" },
        .{ .file = "c.zig", .name = "X", .value = "different" },
        .{ .file = "d.zig", .name = "Y", .value = "solo" },
    };
    const groups = try findDuplicates(a, &decls);
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqualStrings("X", groups[0].name);
    try std.testing.expectEqualStrings("shared", groups[0].value);
    try std.testing.expectEqual(@as(usize, 2), groups[0].files.len);
}
