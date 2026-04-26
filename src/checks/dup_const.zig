const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

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
    var depth: i32 = 0;

    var prev_was_pub = false;
    var pending_const_at_depth0: bool = false;
    var pending_name: ?[]const u8 = null;
    var pending_after_eq: bool = false;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;

        switch (t.tag) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            .keyword_pub => {
                prev_was_pub = (depth == 0);
                continue;
            },
            .keyword_const => {
                pending_const_at_depth0 = (depth == 0);
                pending_name = null;
                pending_after_eq = false;
                prev_was_pub = false;
                continue;
            },
            .identifier => {
                if (pending_const_at_depth0 and pending_name == null) {
                    pending_name = z[t.loc.start..t.loc.end];
                }
            },
            .equal => {
                if (pending_const_at_depth0 and pending_name != null) {
                    pending_after_eq = true;
                }
            },
            .string_literal => {
                if (pending_after_eq) {
                    const raw = z[t.loc.start..t.loc.end];
                    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
                        const value = raw[1 .. raw.len - 1];
                        try out.append(allocator, .{
                            .file = file,
                            .name = pending_name.?,
                            .value = value,
                        });
                    }
                    pending_const_at_depth0 = false;
                    pending_name = null;
                    pending_after_eq = false;
                }
            },
            .semicolon => {
                pending_const_at_depth0 = false;
                pending_name = null;
                pending_after_eq = false;
            },
            else => {
                // Anything else after `= ` that isn't a string literal means
                // this const isn't a string-literal value — drop it.
                if (pending_after_eq) {
                    pending_const_at_depth0 = false;
                    pending_name = null;
                    pending_after_eq = false;
                }
            },
        }
    }
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
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit });

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

// spec: Duplicate Const - Rejects file-scope const string-literal declarations with the same name and value defined in two or more files
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
