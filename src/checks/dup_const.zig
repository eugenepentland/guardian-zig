const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const Decl = struct {
    file: []const u8,
    name: []const u8,
    value: []const u8,
};

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    decls: *std.ArrayListUnmanaged(Decl),
};

/// Mutable state carried across tokens while scanning for a top-level
/// `(pub) const NAME = "literal";` declaration.
const ScanState = struct {
    depth: i32 = 0,
    pending_const_at_depth0: bool = false,
    pending_name: ?[]const u8 = null,
    pending_after_eq: bool = false,

    fn reset(self: *ScanState) void {
        self.pending_const_at_depth0 = false;
        self.pending_name = null;
        self.pending_after_eq = false;
    }
};

/// Starts tracking a declaration when a `const` opens one at depth 0. A `const`
/// inside a type (`[]const u8`, `*const T`) arrives while we're already tracking
/// one — ignoring it keeps the real name instead of capturing the type.
fn beginConst(state: *ScanState) void {
    if (state.pending_const_at_depth0) return;
    state.pending_const_at_depth0 = (state.depth == 0);
    state.pending_name = null;
    state.pending_after_eq = false;
}

/// Captures the first identifier after `const` as the declaration's name.
fn recordName(state: *ScanState, name: []const u8) void {
    if (state.pending_const_at_depth0 and state.pending_name == null) {
        state.pending_name = name;
    }
}

/// Notes that `=` was seen for the tracked `const NAME`, arming value capture.
fn markAfterEq(state: *ScanState) void {
    if (state.pending_const_at_depth0 and state.pending_name != null) {
        state.pending_after_eq = true;
    }
}

/// Append destination for collected decls, bundling the fields shared by every
/// `out.append` call so per-token helpers stay within the parameter limit.
const Sink = struct {
    allocator: std.mem.Allocator,
    file: []const u8,
    out: *std.ArrayListUnmanaged(Decl),
};

/// Appends a completed `NAME = "value"` decl when `raw` is a quoted literal.
/// Non-string values are dropped. The caller resets scan state afterward.
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
/// brace depth so consts inside function bodies are ignored. Returns owned
/// slices of name and unquoted value.
fn extractFileScopeStringConsts(
    allocator: std.mem.Allocator,
    file: []const u8,
    content: []const u8,
    out: *std.ArrayListUnmanaged(Decl),
) !void {
    const z = try allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var state: ScanState = .{};
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
            // Anything else after `= ` that isn't a string literal means this
            // const isn't a string-literal value — drop it.
            else => if (state.pending_after_eq) state.reset(),
        }
    }
}

/// Handles a `string_literal` token: when a value is expected, records the decl
/// (quoted literals only) and resets scan state. Ignored otherwise.
fn onStringLiteral(state: *ScanState, sink: Sink, raw: []const u8) !void {
    if (!state.pending_after_eq) return;
    try appendStringLiteral(sink, state.pending_name.?, raw);
    state.reset();
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try extractFileScopeStringConsts(ctx.allocator, entry.rel_path, entry.content, ctx.decls);
}

const Group = struct {
    name: []const u8,
    value: []const u8,
    files: []const []const u8,
};

fn findDuplicates(allocator: std.mem.Allocator, decls: []const Decl) ![]const Group {
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    var seen: std.ArrayListUnmanaged(usize) = .empty;
    defer seen.deinit(allocator);

    for (decls, 0..) |d, i| {
        var already = false;
        for (seen.items) |j| {
            if (j == i) {
                already = true;
                break;
            }
        }
        if (already) continue;

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

/// Entry point for the dup-const check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .decls = &decls };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    const groups = try findDuplicates(allocator, decls.items);

    if (groups.len == 0) {
        ok("no duplicate string-literal consts ({d} scanned)", .{decls.items.len});
        return;
    }

    fail("dup-const FAILED ({d} duplicate group(s))", .{groups.len});
    for (groups) |g| {
        print("  {s} = \"{s}\"\n", .{ g.name, g.value });
        for (g.files) |f| print("    in: {s}\n", .{f});
    }
    print("  fix: extract the constant into a shared module and import it.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Duplicate Const - Rejects duplicate file-scope string-literal consts (same name and value) across files

test "extractFileScopeStringConsts finds top-level pub and private consts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var decls: std.ArrayListUnmanaged(Decl) = .empty;

    const content =
        \\const A = "alpha";
        \\pub const B = "beta";
        \\pub const N = 42;
        \\fn x() void {
        \\    const inside = "ignore-me";
        \\}
    ;
    try extractFileScopeStringConsts(a, "src/x.zig", content, &decls);
    try testing.expectEqual(@as(usize, 2), decls.items.len);
    try testing.expectEqualStrings("A", decls.items[0].name);
    try testing.expectEqualStrings("alpha", decls.items[0].value);
    try testing.expectEqualStrings("B", decls.items[1].name);
    try testing.expectEqualStrings("beta", decls.items[1].value);
}

test "extractFileScopeStringConsts keeps the real name on type-annotated consts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var decls: std.ArrayListUnmanaged(Decl) = .empty;

    const content =
        \\pub const Greeting: []const u8 = "hi";
        \\const Ptr: *const [3:0]u8 = "abc";
    ;
    try extractFileScopeStringConsts(a, "src/x.zig", content, &decls);
    try testing.expectEqual(@as(usize, 2), decls.items.len);
    // Previously the `const` in `[]const u8` overwrote the name with `u8`.
    try testing.expectEqualStrings("Greeting", decls.items[0].name);
    try testing.expectEqualStrings("hi", decls.items[0].value);
    try testing.expectEqualStrings("Ptr", decls.items[1].name);
}
test "findDuplicates groups by (name, value)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = [_]Decl{
        .{ .file = "a.zig", .name = "X", .value = "shared" },
        .{ .file = "b.zig", .name = "X", .value = "shared" },
        .{ .file = "c.zig", .name = "X", .value = "different" },
        .{ .file = "d.zig", .name = "Y", .value = "shared" },
    };
    const groups = try findDuplicates(a, &decls);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("X", groups[0].name);
    try testing.expectEqualStrings("shared", groups[0].value);
    try testing.expectEqual(@as(usize, 2), groups[0].files.len);
}

test "findDuplicates ignores singletons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = [_]Decl{
        .{ .file = "a.zig", .name = "X", .value = "alpha" },
        .{ .file = "b.zig", .name = "Y", .value = "beta" },
    };
    const groups = try findDuplicates(a, &decls);
    try testing.expectEqual(@as(usize, 0), groups.len);
}
