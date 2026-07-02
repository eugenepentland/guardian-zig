const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

// Vague public identifiers (folded in from vague-name-blacklist). Exact match
// only — `ConfigManager` / `tmpBuf` pass; these bare names name nothing concrete.
const vague_names = [_][]const u8{
    "tmp",     "data",      "info",    "obj",     "foo",
    "bar",     "baz",       "mgr",     "Helper",  "Util",
    "Manager", "Processor", "Handler", "Wrapper",
};

fn isVague(name: []const u8) bool {
    for (vague_names) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

fn checkVagueName(ctx: *ScanCtx, rel_path: []const u8, kind: []const u8, name: []const u8) anyerror!void {
    if (!isVague(name)) return;
    const msg = try std.fmt.allocPrint(ctx.allocator, "{s}: {s} '{s}' uses a vague name", .{ rel_path, kind, name });
    try ctx.violations.append(ctx.allocator, msg);
}

const CaseKind = enum { pascal, camel, snake, other };

fn lowerLeadCase(name: []const u8) CaseKind {
    // Precondition: name[0] is a lower-case ASCII letter. snake_case iff it
    // contains an underscore, otherwise camelCase.
    return if (std.mem.indexOfScalar(u8, name, '_') != null) .snake else .camel;
}

fn caseKind(name: []const u8) CaseKind {
    if (name.len == 0) return .other;
    const first = name[0];
    if (std.ascii.isUpper(first)) return .pascal;
    return if (std.ascii.isLower(first)) lowerLeadCase(name) else .other;
}

fn checkFn(ctx: *ScanCtx, rel_path: []const u8, f: ast.PubFn) anyerror!void {
    const a = ctx.allocator;
    const kind = caseKind(f.name);
    if (f.return_kind == .type_kw) {
        if (kind == .pascal) return;
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: pub fn {s} returns `type` but is not PascalCase",
            .{ rel_path, f.name },
        );
        try ctx.violations.append(a, msg);
        return;
    }
    if (kind == .pascal) {
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: pub fn {s} is PascalCase but does not return `type`",
            .{ rel_path, f.name },
        );
        try ctx.violations.append(a, msg);
    } else if (kind == .snake) {
        // Zig fns are camelCase; snake_case is a Rust/Python bleed.
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: pub fn {s} is snake_case (Zig fns are camelCase)",
            .{ rel_path, f.name },
        );
        try ctx.violations.append(a, msg);
    }
}

fn checkConst(ctx: *ScanCtx, rel_path: []const u8, c: ast.PubConst) anyerror!void {
    const a = ctx.allocator;
    switch (c.kind) {
        .struct_, .enum_, .union_, .opaque_ => {},
        else => return,
    }
    if (caseKind(c.name) == .pascal) return;
    const msg = try std.fmt.allocPrint(
        a,
        "{s}: pub const {s} is a {s} type but is not PascalCase",
        .{ rel_path, c.name, @tagName(c.kind) },
    );
    try ctx.violations.append(a, msg);
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        try checkFn(ctx, entry.rel_path, f);
        try checkVagueName(ctx, entry.rel_path, "pub fn", f.name);
    }

    const consts = if (entry.tree) |t| try ast.pubConstsFromTree(a, t) else try ast.pubConsts(a, entry.content);
    for (consts) |c| {
        try checkConst(ctx, entry.rel_path, c);
        try checkVagueName(ctx, entry.rel_path, "pub const", c.name);
    }
}

/// Entry point for the naming check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("naming conventions OK", .{});
        return;
    }

    fail("naming check FAILED ({d} violation(s))", .{violations.items.len});
    for (violations.items) |v| {
        print("  {s}\n", .{v});
    }
    print("  fix: PascalCase iff the fn returns `type`; types use PascalCase.\n", .{});
    return error.CheckFailed;
}

// spec: Naming - PascalCase pub fn must return type
// spec: Naming - camelCase pub fn must not return type
// spec: Naming - snake_case pub fn is rejected
// spec: Naming - pub const struct/enum/union with fields must be PascalCase
// spec: Tier 2 Anti-patterns - Rejects vague identifier names on public declarations

test "visit flags a vague public name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    // PascalCase (naming OK) but a blacklisted vague name → flagged once.
    const content = "pub const Manager = struct { x: i32 };\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "caseKind classifies common cases" {
    try std.testing.expectEqual(@as(@TypeOf(caseKind("Foo")), .pascal), caseKind("Foo"));
    try std.testing.expectEqual(@as(@TypeOf(caseKind("foo")), .camel), caseKind("foo"));
    try std.testing.expectEqual(@as(@TypeOf(caseKind("foo_bar")), .snake), caseKind("foo_bar"));
    try std.testing.expectEqual(@as(@TypeOf(caseKind("fooBar")), .camel), caseKind("fooBar"));
}

test "visit catches pascal fn that does not return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn DoThing() void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit catches snake_case pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn do_the_thing() void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit accepts pascal fn returning type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn List(comptime T: type) type { return T; }\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches snake_case struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub const my_struct = struct { x: i32 };\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}
