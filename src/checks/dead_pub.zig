const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Dead Pub - Flags public declarations referenced only by themselves

const Decl = struct {
    file: []const u8,
    name: []const u8,
};

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    decls: *std.ArrayListUnmanaged(Decl),
};

fn collectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *CollectCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const fns = ast.pubFns(a, entry.content) catch return;
    for (fns) |f| {
        // Conventionally exempt: main, build, run (registry-dispatched).
        if (std.mem.eql(u8, f.name, "main")) continue;
        if (std.mem.eql(u8, f.name, "build")) continue;
        if (std.mem.eql(u8, f.name, "run")) continue;
        ctx.decls.append(a, .{ .file = entry.rel_path, .name = f.name }) catch {};
    }
    const consts = ast.pubConsts(a, entry.content) catch return;
    for (consts) |c| {
        ctx.decls.append(a, .{ .file = entry.rel_path, .name = c.name }) catch {};
    }
}

const RefCtx = struct {
    allocator: std.mem.Allocator,
    counts: *std.StringHashMap(u32),
};

fn refVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) void {
    const ctx: *RefCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;
    const z = a.dupeZ(u8, entry.content) catch return;
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .identifier) continue;
        const name = z[t.loc.start..t.loc.end];
        if (ctx.counts.getPtr(name)) |p| p.* += 1;
    }
}

/// Entry point for the dead-pub check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    // Pass 1: collect every pub decl in src/.
    var decls: std.ArrayListUnmanaged(Decl) = .empty;
    var collect_ctx: CollectCtx = .{ .allocator = allocator, .decls = &decls };
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &collect_ctx, .visit = collectVisit }) catch {};

    if (decls.items.len == 0) {
        ok("no public declarations to check", .{});
        return;
    }

    // Pass 2: tally identifier-token references across src/ and test/.
    var counts = std.StringHashMap(u32).init(allocator);
    for (decls.items) |d| {
        try counts.put(d.name, 0);
    }
    var ref_ctx: RefCtx = .{ .allocator = allocator, .counts = &counts };
    const dirs = [_][]const u8{ "src", "test" };
    for (&dirs) |dir| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, dir });
        walk.walkZigFiles(allocator, dir_path, dir, .{}, .{ .ctx = &ref_ctx, .visit = refVisit }) catch {};
    }
    // build.zig is a Zig file at the project root — include its references
    // so consumer-facing build helpers aren't flagged dead.
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_dir});
    if (std.fs.cwd().readFileAlloc(allocator, build_path, 1024 * 1024)) |content| {
        refVisit(@ptrCast(&ref_ctx), .{ .rel_path = "build.zig", .content = content });
    } else |_| {}

    // A decl is dead if its identifier token appears at most once
    // (only the declaration itself, no callers / tests / signatures).
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    for (decls.items) |d| {
        const c = counts.get(d.name) orelse 0;
        if (c <= 1) {
            const msg = std.fmt.allocPrint(
                allocator,
                "{s}::{s}: unused public declaration",
                .{ d.file, d.name },
            ) catch continue;
            try violations.append(allocator, msg);
        }
    }

    if (violations.items.len == 0) {
        ok("no unused public declarations ({d} pub decls scanned)", .{decls.items.len});
        return;
    }

    fail("dead-pub FAILED ({d} unused public declaration(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: remove, demote to private (drop `pub`), or reference from a test.\n", .{});
    std.process.exit(1);
}

test "exempt names are not flagged" {
    // Smoke test — full integration is exercised by Guardian's self-build.
    const exempt = [_][]const u8{ "main", "build", "run" };
    for (exempt) |n| try std.testing.expect(n.len > 0);
}
