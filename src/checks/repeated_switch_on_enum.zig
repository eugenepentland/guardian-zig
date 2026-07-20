//! repeated-switch-on-enum check: flag the same enum dot-prong set (`.a`, `.b`,
//! …) switched on in 2+ files — a duplicated dispatch that drifts when one copy
//! gains a prong the other forgets. An architectural-fitness signal, not a
//! per-switch rule.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const text = @import("../text.zig");

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
    violations: *std.ArrayList([]const u8),
};

/// Pure-function entry: collects unique sets of leading enum prongs
/// (`.alpha`, `.beta`, …) across all switch expressions in `content` and
/// returns one line per discovered set, prefixed by `rel_path:`. The
/// real check across the whole project is performed by `run` which
/// keeps a project-wide hashmap.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sigs = try collectSwitchSignatures(a, content);
    for (sigs) |sl| {
        const owned = try allocator.dupe(u8, sl.sig);
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

/// One switch's prong signature paired with the source line of its `switch`
/// keyword, so the cross-file report can point at where each collision lives.
const SwitchSig = struct { sig: []const u8, line: u32 };

fn collectSwitchSignatures(arena: Allocator, z: [:0]const u8) Allocator.Error![]const SwitchSig {
    var out: std.ArrayList(SwitchSig) = .empty;
    var tok = std.zig.Tokenizer.init(z);
    var test_scope: text.TestScope = .{};
    while (true) {
        const t = nextScoped(&tok, &test_scope);
        if (t.tag == .eof) break;
        if (t.tag != .keyword_switch) continue;
        if (test_scope.in_test) continue;
        const line = text.lineOf(z, t.loc.start);
        if (try collectOneSwitch(arena, &tok, z, &test_scope)) |sig|
            try out.append(arena, .{ .sig = sig, .line = line });
    }
    return out.toOwnedSlice(arena);
}

fn collectOneSwitch(
    arena: Allocator,
    tok: *std.zig.Tokenizer,
    z: []const u8,
    test_scope: *text.TestScope,
) Allocator.Error!?[]const u8 {
    const prongs = (try collectProngs(arena, tok, z, test_scope)) orelse return null;
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
    test_scope: *text.TestScope,
) Allocator.Error!?[]const []const u8 {
    if (!skipParenGroup(tok, test_scope)) return null;
    if (nextScoped(tok, test_scope).tag != .l_brace) return null;
    return scanProngs(arena, tok, z, test_scope);
}

/// Skips the `(...)` subject of a switch, starting at the token after
/// `switch`. Returns false if the first token is not `(` or on EOF.
fn skipParenGroup(tok: *std.zig.Tokenizer, test_scope: *text.TestScope) bool {
    if (nextScoped(tok, test_scope).tag != .l_paren) return false;
    var paren_depth: u32 = 1;
    while (paren_depth > 0) {
        const ti = nextScoped(tok, test_scope);
        if (ti.tag == .eof) return false;
        if (ti.tag == .l_paren) paren_depth += 1;
        if (ti.tag == .r_paren) paren_depth -= 1;
    }
    return true;
}

const ProngScan = struct {
    prongs: std.ArrayList([]const u8) = .empty,
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
    test_scope: *text.TestScope,
) Allocator.Error!?[]const []const u8 {
    var scan: ProngScan = .{};
    while (scan.depth > 0) {
        const ti = nextScoped(tok, test_scope);
        if (ti.tag == .eof) return null;
        try scan.step(arena, ti, z);
    }
    return scan.prongs.items;
}

fn nextScoped(tok: *std.zig.Tokenizer, test_scope: *text.TestScope) std.zig.Token {
    const token = tok.next();
    test_scope.update(token.tag);
    return token;
}

fn joinSorted(arena: Allocator, items: []const []const u8) Allocator.Error![]const u8 {
    const copy = try arena.alloc([]const u8, items.len);
    @memcpy(copy, items);
    std.mem.sort([]const u8, copy, {}, lessThan);
    var buf: std.ArrayList(u8) = .empty;
    for (copy, 0..) |s, i| {
        if (i > 0) try buf.append(arena, ',');
        try buf.appendSlice(arena, s);
    }
    return buf.toOwnedSlice(arena);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A signature occurrence: the file it appeared in and the switch's line.
const FileLoc = struct { file: []const u8, line: u32 };

const ProjectCtx = struct {
    allocator: Allocator,
    sig_to_files: *std.StringHashMapUnmanaged(std.ArrayList(FileLoc)),
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
    for (sigs) |sl| {
        const owned_sig = try a.dupe(u8, sl.sig);
        const gop = try ctx.sig_to_files.getOrPut(a, owned_sig);
        if (gop.found_existing) a.free(owned_sig) else gop.value_ptr.* = .empty;
        try gop.value_ptr.*.append(a, .{ .file = try a.dupe(u8, entry.rel_path), .line = sl.line });
    }
}

/// Entry point for the repeated-switch-on-enum check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var sig_to_files: std.StringHashMapUnmanaged(std.ArrayList(FileLoc)) = .empty;
    var pctx: ProjectCtx = .{
        .allocator = allocator,
        .sig_to_files = &sig_to_files,
        .extra_allowed = ctx.cfg.extraAllowed("repeated-switch-on-enum"),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &pctx, .visit = projectVisit });

    var violations: std.ArrayList(reporter.Violation) = .empty;
    var iter = sig_to_files.iterator();
    while (iter.next()) |e| {
        const locs = e.value_ptr.*.items;
        const unique = try uniqueFileLocs(allocator, locs);
        if (unique.len < 2) continue;
        const loc_list = try std.mem.join(allocator, ", ", unique);
        const msg = try std.fmt.allocPrint(
            allocator,
            "switch on prongs ({s}) appears in {d} files: {s}",
            .{ e.key_ptr.*, unique.len, loc_list },
        );
        // The prong set is what was flagged; the file count and the location
        // list are context *about* it that legitimately churns as code moves.
        // Keying the baseline on the prong set (reporter.Violation.identity) is
        // what stopped this check re-keying every consumer baseline whenever its
        // message gained a detail — the 2026-07-20 "all 10 reported as new" case.
        try violations.append(allocator, .{
            .check = "repeated-switch-on-enum",
            .message = msg,
            .identity = e.key_ptr.*,
        });
    }

    if (violations.items.len == 0) {
        reporter.ok("repeated-switch-on-enum: no enum prong-set is switched in 2+ files", .{});
        return;
    }
    reporter.fail("repeated-switch-on-enum FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: move the dispatch onto the enum/tagged union itself (e.g., a method per prong).\n", .{});
    return error.CheckFailed;
}

/// The unique files sharing a signature, each rendered `file:line` (earliest
/// line when one file switches the same prong-set more than once), sorted for
/// deterministic output. Deduplicating by *file* — not by line — keeps the
/// "2+ files" threshold about distinct files, so one file switching the same
/// set twice is never miscounted as a cross-file collision.
fn uniqueFileLocs(allocator: Allocator, locs: []const FileLoc) Allocator.Error![]const []const u8 {
    var first_line: std.StringHashMapUnmanaged(u32) = .empty;
    defer first_line.deinit(allocator);
    for (locs) |l| {
        // Propagate OOM: an undercount here could turn a real collision into a
        // false pass — surface the allocation error instead.
        const gop = try first_line.getOrPut(allocator, l.file);
        if (!gop.found_existing or l.line < gop.value_ptr.*) gop.value_ptr.* = l.line;
    }
    var out = try allocator.alloc([]const u8, first_line.count());
    var it = first_line.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1)
        out[i] = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ kv.key_ptr.*, kv.value_ptr.* });
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

// spec: Tier 3 Architectural Fitness - Flags the same enum dot-prong set switched in 2+ files
// spec: Tier 3 Architectural Fitness - Ignores repeated enum switches that occur only inside test blocks
// spec: Tier 3 Architectural Fitness - Names every file sharing a repeated enum prong set
// spec: Tier 3 Architectural Fitness - Renders each colliding switch location as file and line

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

test "analyzeContent ignores test switches and resumes after the test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "helper" {
        \\    _ = switch (value) { .alpha => 1, .beta => 2, else => 0 };
        \\}
        \\fn production(value: Mode) u32 {
        \\    return switch (value) { .gamma => 3, .delta => 4, else => 0 };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "delta,gamma") != null);
}

test "uniqueFileLocs dedups by file, keeps the earliest line, and sorts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const locs = [_]FileLoc{
        .{ .file = "src/z.zig", .line = 30 },
        .{ .file = "src/a.zig", .line = 12 },
        .{ .file = "src/z.zig", .line = 8 },
    };
    const out = try uniqueFileLocs(arena.allocator(), &locs);
    // Two distinct files (z seen twice), each rendered file:line at its earliest.
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("src/a.zig:12", out[0]);
    try std.testing.expectEqualStrings("src/z.zig:8", out[1]);
}
