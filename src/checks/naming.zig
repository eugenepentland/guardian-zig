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
    violations: *std.ArrayList([]const u8),
    /// [[allow]] check = "naming" path globs (the C-ABI-mirror escape hatch): a
    /// file matching any of these is skipped wholesale. Empty in tests.
    allowed_paths: []const []const u8 = &.{},
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

/// True for a SCREAMING_SNAKE identifier: length >= 2, every character is an
/// uppercase ASCII letter, a digit, or an underscore, and at least one is a
/// letter. Zig std reserves this casing for C/OS-ABI mirrors (a plain const is
/// snake_case, e.g. `std.fs.max_path_bytes`); everywhere else it reads as a
/// C/Rust convention bleed. Distinct from caseKind, which folds SCREAMING into
/// .pascal because both lead with an uppercase letter.
fn isScreamingSnake(name: []const u8) bool {
    if (name.len < 2) return false;
    var has_letter = false;
    for (name) |c| {
        if (std.ascii.isUpper(c)) {
            has_letter = true;
        } else if (std.ascii.isDigit(c) or c == '_') {
            // permitted inside a SCREAMING_SNAKE identifier
        } else {
            return false; // a lowercase letter (or other char) rules it out
        }
    }
    return has_letter;
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

/// Flags a container-scope const whose name is SCREAMING_SNAKE. snake_case value
/// consts and PascalCase type-valued consts both pass; only the all-caps form is
/// rejected. Applies to pub and private consts alike (both are the project's own
/// vocabulary). The escape hatch for a deliberate C-ABI mirror is a `[[allow]]
/// check = "naming"` path entry, handled in `visit`.
fn checkConstCasing(ctx: *ScanCtx, rel_path: []const u8, name: []const u8) anyerror!void {
    if (!isScreamingSnake(name)) return;
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}: const {s} is SCREAMING_SNAKE (Zig consts are snake_case, or PascalCase for a type)",
        .{ rel_path, name },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    // [[allow]] check = "naming" exempts a whole file (e.g. a C/OS-ABI mirror
    // whose SCREAMING casing intentionally matches the foreign API).
    for (ctx.allowed_paths) |pat| {
        if (walk.matchGlob(entry.rel_path, pat)) return;
    }

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

    // Container-scope const casing (pub and private): SCREAMING_SNAKE is banned.
    const const_names = if (entry.tree) |t|
        try ast.allConstNamesFromTree(a, t)
    else
        try ast.allConstNames(a, entry.content);
    for (const_names) |name| try checkConstCasing(ctx, entry.rel_path, name);
}

/// Entry point for the naming check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .allowed_paths = ctx_param.cfg.extraAllowed("naming"),
    };

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
    print("       consts are snake_case; SCREAMING_SNAKE is banned ([[allow]] exempts a C-ABI mirror).\n", .{});
    return error.CheckFailed;
}

// spec: Naming - PascalCase pub fn must return type
// spec: Naming - camelCase pub fn must not return type
// spec: Naming - snake_case pub fn is rejected
// spec: Naming - pub const struct/enum/union with fields must be PascalCase
// spec: Naming - SCREAMING_SNAKE container-scope const is rejected
// spec: Tier 2 Anti-patterns - Rejects vague identifier names on public declarations

test "visit flags a vague public name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
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
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn DoThing() void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit catches snake_case pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn do_the_thing() void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit accepts pascal fn returning type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn List(comptime T: type) type { return T; }\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches snake_case struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub const my_struct = struct { x: i32 };\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit flags a SCREAMING_SNAKE const but allows snake_case and PascalCase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\const MAX_BYTES = 1024;
        \\const max_bytes = 1024;
        \\const Widget = struct { x: i32 };
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    // Only MAX_BYTES trips: the snake_case value const and the PascalCase type pass.
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(isScreamingSnake("MAX_BYTES"));
    try std.testing.expect(!isScreamingSnake("max_bytes"));
    try std.testing.expect(!isScreamingSnake("Widget"));
}

test "visit skips a file matching a naming allow glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayList([]const u8) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .violations = &violations,
        .allowed_paths = &.{"src/abi/*"},
    };
    // A C-ABI mirror kept SCREAMING on purpose: [[allow]] exempts the whole file.
    const content = "const IOCTL_MAGIC = 0x42;\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/abi/linux.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
