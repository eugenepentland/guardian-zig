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

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    // Resolve one level of `const X = anyerror;` aliasing: the decl is itself a
    // violation, and its name is collected so a signature using it counts as
    // anyerror (else the alias would launder `anyerror` past this check).
    const aliases = try collectAnyerrorAliases(ctx, entry.rel_path, entry.content);

    const fns = if (entry.tree) |t| try ast.pubFnsFromTree(a, t) else try ast.pubFns(a, entry.content);
    for (fns) |f| {
        // `main` is conventionally exempt; its inferred error set is idiomatic.
        if (std.mem.eql(u8, f.name, "main")) continue;
        // A generic `fn (w: anytype) !T` CANNOT name a concrete error set — it
        // inherits the caller's (e.g. the writer's), so the inferred-set rule
        // is unimplementable here. Skip fns whose prototype takes an anytype.
        if (std.mem.indexOf(u8, f.proto_span, "anytype") != null) continue;
        switch (f.return_kind) {
            .err_union_inferred => {
                const msg = try std.fmt.allocPrint(
                    a,
                    "{s}: pub fn {s} uses inferred error set `!T` (use `MyErr!T`)",
                    .{ entry.rel_path, f.name },
                );
                try ctx.violations.append(a, msg);
            },
            .anyerror_union => {
                const msg = try std.fmt.allocPrint(
                    a,
                    "{s}: pub fn {s} uses anyerror (declare a specific error set)",
                    .{ entry.rel_path, f.name },
                );
                try ctx.violations.append(a, msg);
            },
            .err_union_explicit => {
                // An explicit error set whose name is an in-file anyerror alias
                // is anyerror in disguise.
                const set_name = returnErrorSetName(f.proto_span) orelse continue;
                if (!isAliasName(aliases.items, set_name)) continue;
                const msg = try std.fmt.allocPrint(
                    a,
                    "{s}: pub fn {s} returns `{s}`, an alias of anyerror (declare a specific error set)",
                    .{ entry.rel_path, f.name, set_name },
                );
                try ctx.violations.append(a, msg);
            },
            else => {},
        }
    }
}

/// True when `name` is one of the collected in-file anyerror-alias names.
fn isAliasName(aliases: []const []const u8, name: []const u8) bool {
    for (aliases) |alias| if (std.mem.eql(u8, alias, name)) return true;
    return false;
}

/// Scans `content` for file-scope `const X = anyerror;` aliases: each is flagged
/// as its own violation (there is no honest reason to alias anyerror) and its
/// name is returned so `visit` can flag any signature that uses it. Matches only
/// an exact `= anyerror;` right-hand side, not `anyerror!T` or `anyerror || …`.
fn collectAnyerrorAliases(
    ctx: *ScanCtx,
    rel_path: []const u8,
    content: [:0]const u8,
) std.mem.Allocator.Error!std.ArrayListUnmanaged([]const u8) {
    const a = ctx.allocator;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var tok = std.zig.Tokenizer.init(content);
    // State over the `const IDENT = anyerror ;` window; `pub` before `const`
    // never reaches .const_seen, so pub and private aliases are both caught.
    var state: AliasScan = .start;
    var name: []const u8 = "";
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        const slice = content[t.loc.start..t.loc.end];
        switch (state) {
            .start => state = if (t.tag == .keyword_const) .const_seen else .start,
            .const_seen => state = if (t.tag == .identifier) blk: {
                name = slice;
                break :blk .name_seen;
            } else afterMiss(t.tag),
            .name_seen => state = if (t.tag == .equal) .eq_seen else afterMiss(t.tag),
            .eq_seen => state = if (t.tag == .identifier and std.mem.eql(u8, slice, "anyerror"))
                .anyerror_seen
            else
                afterMiss(t.tag),
            .anyerror_seen => {
                if (t.tag == .semicolon) {
                    try names.append(a, name);
                    try ctx.violations.append(a, try std.fmt.allocPrint(
                        a,
                        "{s}: `const {s} = anyerror` aliases anyerror (declare a specific error set)",
                        .{ rel_path, name },
                    ));
                }
                state = afterMiss(t.tag);
            },
        }
    }
    return names;
}

/// The alias-scan state; `pub`/`const`/ident/`=`/`anyerror`/`;` in sequence.
const AliasScan = enum { start, const_seen, name_seen, eq_seen, anyerror_seen };

/// Reset target after a token that breaks the alias window: a fresh `const`
/// restarts the match, anything else returns to the neutral start.
fn afterMiss(tag: std.zig.Token.Tag) AliasScan {
    return if (tag == .keyword_const) .const_seen else .start;
}

/// The error-set identifier a fn prototype names before `!` in its return type,
/// or null when the return type is inferred (`!T`), non-erroring, or an inline
/// `error{…}` set. `proto_span` is `fn name(params) rettype` with whitespace
/// collapsed; the balanced parameter parens are skipped first so a `!` or paren
/// inside a parameter type can't be misread as the return type.
fn returnErrorSetName(proto_span: []const u8) ?[]const u8 {
    const ret = returnTypeText(proto_span) orelse return null;
    const bang = std.mem.indexOfScalar(u8, ret, '!') orelse return null;
    const lhs = std.mem.trim(u8, ret[0..bang], &std.ascii.whitespace);
    if (lhs.len == 0) return null; // inferred `!T`
    // A bare identifier can name an alias; an inline `error{…}` set cannot.
    if (std.mem.indexOfScalar(u8, lhs, '{') != null) return null;
    return lhs;
}

/// The return-type text of `proto_span`: everything after the parameter list's
/// matching close paren. Null when the parens are unbalanced.
fn returnTypeText(proto_span: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, proto_span, '(') orelse return null;
    var depth: u32 = 0;
    var i = open;
    while (i < proto_span.len) : (i += 1) {
        switch (proto_span[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return std.mem.trim(u8, proto_span[i + 1 ..], &std.ascii.whitespace);
            },
            else => {},
        }
    }
    return null;
}

/// Entry point for the error-discipline check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = allocator, .violations = &violations };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    if (violations.items.len == 0) {
        ok("error discipline OK", .{});
        return;
    }

    fail("error discipline FAILED ({d} violation(s))", .{violations.items.len});
    for (violations.items) |v| print("  {s}\n", .{v});
    print("  fix: declare an explicit error set, e.g.\n", .{});
    print("    pub const MyError = error{{ Foo, Bar }};\n", .{});
    print("    pub fn run(...) MyError!void {{ ... }}\n", .{});
    return error.CheckFailed;
}

// spec: Error Discipline - Rejects inferred error sets on pub fn
// spec: Error Discipline - Rejects anyerror on pub fn

test "visit catches inferred error set on pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub fn bad() !void {}
        \\pub const MyErr = error{ X };
        \\pub fn good() MyErr!void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit allows main with inferred error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn main() !void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/main.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit catches anyerror on pub fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content = "pub fn dynamic() anyerror!void {}\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit skips anytype-param fns (writer pattern)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    // Inferred `!void` but the writer's error set can't be named — exempt.
    const content = "pub fn writeXml(w: anytype, s: []const u8) !void { _ = s; _ = w; }\n";
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

// spec: Error Discipline - Rejects a const that aliases anyerror and any pub fn returning that alias
test "visit flags an anyerror alias decl and any signature using it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .violations = &violations };
    const content =
        \\pub const Bad = anyerror;
        \\pub fn f() Bad!void {}
        \\pub const Ok = error{ X };
        \\pub fn g() Ok!void {}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    // The alias decl (Bad) and the signature returning it (f) both fire; the
    // real error-set const (Ok) and its user (g) do not — exactly two.
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "const Bad = anyerror") != null);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[1], "pub fn f returns `Bad`") != null);
}
