const std = @import("std");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const read_limit = 4 * 1024 * 1024;

/// One configured module paired with the source Guardian read for it. `content`
/// is null when the file was missing or unreadable — a fail-closed hard error,
/// not a silent skip, so a stale entry can't quietly pass the gate.
const ModuleSource = struct {
    path: []const u8,
    content: ?[]const u8,
};

/// Pure core: one violation line per configured module that is either missing/
/// unreadable (null content) or carries no `std.testing.fuzz` call. An empty
/// `modules` slice yields no violations (the check is opt-in by listing paths).
fn analyzeModules(allocator: Allocator, modules: []const ModuleSource) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    for (modules) |m| {
        const content = m.content orelse {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}: listed module is missing or unreadable",
                .{m.path},
            ));
            continue;
        };
        const z = try allocator.dupeZ(u8, content);
        if (!hasFuzzCall(z)) {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}: no std.testing.fuzz call found",
                .{m.path},
            ));
        }
    }
    return violations.toOwnedSlice(allocator);
}

/// True when the source contains a `testing.fuzz` reference as real code — the
/// token sequence identifier `testing`, `.`, identifier `fuzz`. Token-based, so
/// a `"testing.fuzz"` string literal or a `// testing.fuzz` comment never counts
/// (the tokenizer yields those as a single string/no token, not the identifiers).
fn hasFuzzCall(z: [:0]const u8) bool {
    var tok = std.zig.Tokenizer.init(z);
    var prev1: std.zig.Token.Tag = .invalid;
    var prev2: std.zig.Token.Tag = .invalid;
    var prev_ident: []const u8 = "";
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        const name = z[t.loc.start..t.loc.end];
        if (t.tag == .identifier and isFuzzTail(name, prev1, prev2, prev_ident)) return true;
        prev2 = prev1;
        prev1 = t.tag;
        if (t.tag == .identifier) prev_ident = name;
    }
    return false;
}

/// True when the current identifier `name` closes a `testing.fuzz` sequence: the
/// two prior tokens were `.` then an identifier, that identifier was `testing`,
/// and `name` is `fuzz`. Split out of `hasFuzzCall` so neither condition trips
/// the bool-ops-per-condition cap.
fn isFuzzTail(name: []const u8, prev1: std.zig.Token.Tag, prev2: std.zig.Token.Tag, prev_ident: []const u8) bool {
    if (prev1 != .period or prev2 != .identifier) return false;
    return std.mem.eql(u8, name, "fuzz") and std.mem.eql(u8, prev_ident, "testing");
}

/// Reads a configured module's source under `project_dir`, or null when the
/// file is missing/unreadable (the caller turns null into a hard violation).
fn readModule(allocator: Allocator, project_dir: []const u8, module: []const u8) Allocator.Error!?[]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, module });
    return std.fs.cwd().readFileAlloc(allocator, path, read_limit) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// Entry point for the fuzz-presence check (opt-in via `[fuzz_presence] modules`).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const modules = ctx_param.cfg.fuzz_presence.modules;
    if (modules.len == 0) {
        ok("fuzz-presence: no modules configured (opt-in via [fuzz_presence] modules)", .{});
        return;
    }

    var sources = try allocator.alloc(ModuleSource, modules.len);
    for (modules, 0..) |m, i| {
        sources[i] = .{ .path = m, .content = try readModule(allocator, ctx_param.project_dir, m) };
    }
    const violations = try analyzeModules(allocator, sources);

    if (violations.len == 0) {
        ok("fuzz-presence: all {d} listed module(s) carry a std.testing.fuzz call", .{modules.len});
        return;
    }
    fail("fuzz-presence FAILED ({d} module(s) without a fuzz harness)", .{violations.len});
    for (violations) |v| print("  {s}\n", .{v});
    print("  fix: add a `test {{ try std.testing.fuzz(ctx, testOne, .{{}}); }}` harness to the module,\n", .{});
    print("       or drop the path from [fuzz_presence] modules if it no longer needs one.\n", .{});
    return error.CheckFailed;
}

// spec: Fuzz Presence - Passes each configured module that contains a std.testing.fuzz call

test "analyzeModules passes a module carrying a fuzz call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = [_]ModuleSource{
        .{ .path = "src/a.zig", .content = "test { try std.testing.fuzz({}, oneA, .{}); }" },
        .{ .path = "src/b.zig", .content = "fn f() void {}\ntest { try testing.fuzz(ctx, oneB, .{}); }" },
    };
    const out = try analyzeModules(a, &mods);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Fuzz Presence - Flags a configured module whose source has no fuzz call

test "analyzeModules flags a module without a fuzz call and ignores string mentions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A string literal / comment mentioning testing.fuzz must NOT count.
    const mods = [_]ModuleSource{
        .{ .path = "src/c.zig", .content = "const s = \"testing.fuzz\"; // testing.fuzz here too" },
    };
    const out = try analyzeModules(a, &mods);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "no std.testing.fuzz") != null);
}

// spec: Fuzz Presence - Hard-fails a configured module that is missing or unreadable

test "analyzeModules hard-fails a missing or unreadable module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = [_]ModuleSource{
        .{ .path = "src/gone.zig", .content = null },
    };
    const out = try analyzeModules(a, &mods);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "missing or unreadable") != null);
}
