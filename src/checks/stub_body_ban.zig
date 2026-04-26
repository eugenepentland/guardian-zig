const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Stub Body Ban - Rejects single-statement function bodies that are stub forms (return undefined, panic with placeholder phrase, or unreachable in non-noreturn fns)

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
};

const placeholder_phrases = [_][]const u8{
    "TODO",
    "FIXME",
    "todo",
    "fixme",
    "not implemented",
    "Not implemented",
    "unimplemented",
    "Unimplemented",
    "stub",
    "Stub",
};

/// Returns the trimmed body content, with the surrounding `{` and `}` stripped.
/// Returns null if the slice doesn't start with `{` and end with `}`.
fn stripBraces(body_text: []const u8) ?[]const u8 {
    if (body_text.len < 2) return null;
    if (body_text[0] != '{' or body_text[body_text.len - 1] != '}') return null;
    return std.mem.trim(u8, body_text[1 .. body_text.len - 1], &std.ascii.whitespace);
}

const StubKind = enum {
    none,
    return_undefined,
    placeholder_panic,
    unreachable_in_value_fn,
};

fn classify(body_text: []const u8, return_type_text: ?[]const u8) StubKind {
    const inner = stripBraces(body_text) orelse return .none;

    if (std.mem.eql(u8, inner, "return undefined;")) return .return_undefined;

    if (std.mem.startsWith(u8, inner, "@panic(") and std.mem.endsWith(u8, inner, ");")) {
        // Pull the argument out: between the parens, looking only at the
        // outer call (no nested parens expected for a literal stub).
        const arg = inner["@panic(".len .. inner.len - ");".len];
        for (placeholder_phrases) |phr| {
            if (std.mem.indexOf(u8, arg, phr) != null) return .placeholder_panic;
        }
    }

    if (std.mem.eql(u8, inner, "unreachable;")) {
        // unreachable; is idiomatic in fn x() noreturn — only flag elsewhere.
        const rt = return_type_text orelse return .unreachable_in_value_fn;
        if (std.mem.eql(u8, std.mem.trim(u8, rt, &std.ascii.whitespace), "noreturn")) {
            return .none;
        }
        return .unreachable_in_value_fn;
    }

    return .none;
}

fn kindLabel(kind: StubKind) []const u8 {
    return switch (kind) {
        .none => "",
        .return_undefined => "stub body `return undefined;`",
        .placeholder_panic => "stub body `@panic(...)` with placeholder phrase (TODO/FIXME/unimplemented/stub)",
        .unreachable_in_value_fn => "stub body `unreachable;` in non-noreturn function",
    };
}

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = try ast.fnDeclInfos(a, entry.content);
    for (fns) |fi| {
        const kind = classify(fi.body_text, fi.return_type_text);
        if (kind == .none) continue;
        const msg = try std.fmt.allocPrint(
            a,
            "{s}: fn {s}: {s}",
            .{ entry.rel_path, fi.name, kindLabel(kind) },
        );
        try ctx.violations.append(a, msg);
    }
}

/// Entry point for the stub-body-ban check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    try walk.walkZigFiles(allocator, src_path, "src", .{}, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("no stub function bodies", .{});
        return;
    }

    fail("stub body ban FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: implement the function, OR mark it noreturn if `unreachable;` is intentional.\n", .{});
    return error.CheckFailed;
}

test "classify flags return undefined" {
    try std.testing.expectEqual(StubKind.return_undefined, classify("{ return undefined; }", "i32"));
    try std.testing.expectEqual(StubKind.return_undefined, classify("{return undefined;}", "void"));
}

test "classify flags placeholder panics" {
    try std.testing.expectEqual(StubKind.placeholder_panic, classify("{ @panic(\"TODO\"); }", "void"));
    try std.testing.expectEqual(StubKind.placeholder_panic, classify("{ @panic(\"not implemented\"); }", null));
    try std.testing.expectEqual(StubKind.placeholder_panic, classify("{ @panic(\"unimplemented yet\"); }", "i32"));
    try std.testing.expectEqual(StubKind.none, classify("{ @panic(\"out of memory\"); }", "void"));
}

test "classify flags unreachable in non-noreturn fns" {
    try std.testing.expectEqual(StubKind.unreachable_in_value_fn, classify("{ unreachable; }", "void"));
    try std.testing.expectEqual(StubKind.unreachable_in_value_fn, classify("{ unreachable; }", "i32"));
    try std.testing.expectEqual(StubKind.unreachable_in_value_fn, classify("{ unreachable; }", null));
}

test "classify allows unreachable in noreturn fns" {
    try std.testing.expectEqual(StubKind.none, classify("{ unreachable; }", "noreturn"));
    try std.testing.expectEqual(StubKind.none, classify("{ unreachable; }", " noreturn "));
}

test "classify ignores multi-statement bodies" {
    try std.testing.expectEqual(StubKind.none, classify("{ doSomething(); return; }", "void"));
    try std.testing.expectEqual(StubKind.none, classify("{ const x = 1; _ = x; return undefined; }", "i32"));
}

test "classify ignores legitimate single-statement bodies" {
    try std.testing.expectEqual(StubKind.none, classify("{ return 42; }", "i32"));
    try std.testing.expectEqual(StubKind.none, classify("{ return; }", "void"));
}

test "visit flags fn with stub body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn todoLater() void {
        \\    @panic("TODO: wire this up");
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows real function bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
