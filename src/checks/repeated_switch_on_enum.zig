const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

const min_prong_count: u32 = 2;

// Default: nothing exempt. Guardian dispatches several internal enums
// (Outcome, ReadError, PubConstKind, std.zig.Token.Tag) across many token-walk
// files; those directories are exempted via [[allow]] in Guardian's
// guardian.toml — an honest, visible record of that refactor debt rather than
// a compiled-in carve-out that would silence the check in any repo with a
// src/checks/ directory.
const allowed_paths = [_][]const u8{};

const FileScanCtx = struct {
    allocator: Allocator,
    seen: *std.StringHashMapUnmanaged([]const u8),
    violations: *std.ArrayListUnmanaged([]const u8),
};

/// Pure-function entry: collects unique sets of leading enum prongs
/// (`.alpha`, `.beta`, …) across all switch expressions in `content` and
/// returns one line per discovered set, prefixed by `rel_path:`. The
/// real check across the whole project is performed by `run` which
/// keeps a project-wide hashmap.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sigs = try collectSwitchSignatures(a, content);
    for (sigs) |sig| {
        const owned = try allocator.dupe(u8, sig);
        const gop = try seen.getOrPut(allocator, owned);
        if (gop.found_existing) {
            allocator.free(owned);
            continue;
        }
        const msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ rel_path, owned });
        try lines.append(allocator, msg);
    }
    return lines.toOwnedSlice(allocator);
}

fn collectSwitchSignatures(arena: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const z = try arena.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        if (t.tag != .keyword_switch) continue;
        if (try collectOneSwitch(arena, &tok, z)) |sig| try out.append(arena, sig);
    }
    return out.toOwnedSlice(arena);
}

fn collectOneSwitch(arena: Allocator, tok: *std.zig.Tokenizer, z: []const u8) Allocator.Error!?[]const u8 {
    const prongs = (try collectProngs(arena, tok, z)) orelse return null;
    if (prongs.len < min_prong_count) return null;
    return try joinSorted(arena, prongs);
}

/// Advances `tok` through one switch's subject and body, returning the
/// ordered enum dot-prong names. Returns null if the header (`(...)` then
/// `{`) is malformed or EOF is hit before the body closes.
fn collectProngs(
    arena: Allocator,
    tok: *std.zig.Tokenizer,
    z: []const u8,
) Allocator.Error!?[]const []const u8 {
    if (!skipParenGroup(tok)) return null;
    if (tok.next().tag != .l_brace) return null;
    return scanProngs(arena, tok, z);
}

/// Skips the `(...)` subject of a switch, starting at the token after
/// `switch`. Returns false if the first token is not `(` or on EOF.
fn skipParenGroup(tok: *std.zig.Tokenizer) bool {
    if (tok.next().tag != .l_paren) return false;
    var paren_depth: u32 = 1;
    while (paren_depth > 0) {
        const ti = tok.next();
        if (ti.tag == .eof) return false;
        if (ti.tag == .l_paren) paren_depth += 1;
        if (ti.tag == .r_paren) paren_depth -= 1;
    }
    return true;
}

const ProngScan = struct {
    prongs: std.ArrayListUnmanaged([]const u8) = .empty,
    depth: u32 = 1,
    case_start: bool = true,
    expecting_ident: bool = false,

    fn step(self: *ProngScan, arena: Allocator, ti: std.zig.Token, z: []const u8) Allocator.Error!void {
        switch (ti.tag) {
            .l_brace, .l_paren, .l_bracket => self.depth += 1,
            .r_brace, .r_paren, .r_bracket => self.depth -= 1,
            .comma => if (self.depth == 1) {
                self.case_start = true;
                self.expecting_ident = false;
            },
            .equal_angle_bracket_right => {
                self.case_start = false;
                self.expecting_ident = false;
            },
            .period => if (self.case_start and self.depth == 1) {
                self.expecting_ident = true;
            },
            .identifier => try self.takeIdent(arena, ti, z),
            else => {},
        }
    }

    fn takeIdent(self: *ProngScan, arena: Allocator, ti: std.zig.Token, z: []const u8) Allocator.Error!void {
        if (!self.expecting_ident) return;
        try self.prongs.append(arena, z[ti.loc.start..ti.loc.end]);
        self.expecting_ident = false;
    }
};

/// Scans the switch body (starting after `{`) accumulating leading enum
/// dot-prong identifiers. Returns null on EOF before the body closes.
fn scanProngs(
    arena: Allocator,
    tok: *std.zig.Tokenizer,
    z: []const u8,
) Allocator.Error!?[]const []const u8 {
    var scan: ProngScan = .{};
    while (scan.depth > 0) {
        const ti = tok.next();
        if (ti.tag == .eof) return null;
        try scan.step(arena, ti, z);
    }
    return scan.prongs.items;
}

fn joinSorted(arena: Allocator, items: []const []const u8) Allocator.Error![]const u8 {
    const copy = try arena.alloc([]const u8, items.len);
    @memcpy(copy, items);
    std.mem.sort([]const u8, copy, {}, lessThan);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (copy, 0..) |s, i| {
        if (i > 0) try buf.append(arena, ',');
        try buf.appendSlice(arena, s);
    }
    return buf.toOwnedSlice(arena);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const ProjectCtx = struct {
    allocator: Allocator,
    sig_to_files: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    extra_allowed: []const []const u8 = &.{},
};

/// True if `rel_path` matches a compiled architectural default or a configured
/// [[allow]] path for this check.
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (allowed_paths) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn projectVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ProjectCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.extra_allowed)) return;
    const a = ctx.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sigs = try collectSwitchSignatures(arena.allocator(), entry.content);
    for (sigs) |sig| {
        const owned_sig = try a.dupe(u8, sig);
        const gop = try ctx.sig_to_files.getOrPut(a, owned_sig);
        if (gop.found_existing) a.free(owned_sig) else gop.value_ptr.* = .empty;
        try gop.value_ptr.*.append(a, try a.dupe(u8, entry.rel_path));
    }
}

/// Entry point for the repeated-switch-on-enum check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var sig_to_files: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    var pctx: ProjectCtx = .{
        .allocator = allocator,
        .sig_to_files = &sig_to_files,
        .extra_allowed = ctx.cfg.extraAllowed("repeated-switch-on-enum"),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &pctx, .visit = projectVisit });

    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = sig_to_files.iterator();
    while (iter.next()) |e| {
        const files = e.value_ptr.*.items;
        const unique = try uniqueFileCount(allocator, files);
        if (unique < 2) continue;
        const msg = try std.fmt.allocPrint(
            allocator,
            "switch on prongs ({s}) appears in {d} files",
            .{ e.key_ptr.*, unique },
        );
        try violations.append(allocator, msg);
    }

    if (violations.items.len == 0) {
        reporter.ok("repeated-switch-on-enum: no enum prong-set is switched in 2+ files", .{});
        return;
    }
    reporter.fail("repeated-switch-on-enum FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: move the dispatch onto the enum/tagged union itself (e.g., a method per prong).\n", .{});
    return error.CheckFailed;
}

fn uniqueFileCount(allocator: Allocator, files: []const []const u8) Allocator.Error!usize {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (files) |f| {
        // Propagate OOM: returning files.len over-counts, which could turn a
        // non-violation into a false failure — surface the allocation error.
        try seen.put(allocator, f, {});
    }
    return seen.count();
}

// spec: Tier 3 Architectural Fitness - Flags the same enum dot-prong set switched in 2+ files

test "analyzeContent collects single switch signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn r(m: Mode) u32 {
        \\    return switch (m) {
        \\        .alpha => 1,
        \\        .beta => 2,
        \\        else => 0,
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent ignores switches with too few prongs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\fn r(m: bool) u32 {
        \\    return switch (m) {
        \\        true => 1,
        \\        false => 0,
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
