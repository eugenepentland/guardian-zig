const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

// Architectural defaults: config values and paths live in config/ or main.
// This check's own file (whose pattern strings inevitably look like what it
// flags) is exempted via [[allow]] in Guardian's guardian.toml.
const allowed_paths = [_][]const u8{
    "src/config*",
    "config/*",
    "src/main*",
};

const ScanCtx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayList([]const u8),
};

/// Pure-function entry: scans `content` for hardcoded absolute paths or URLs.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    for (allowed_paths) |pat| {
        if (walk.matchGlob(rel_path, pat)) return violations.toOwnedSlice(allocator);
    }
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
    };
    try scan(&ctx, content);
    return violations.toOwnedSlice(allocator);
}

fn scan(ctx: *ScanCtx, content: []const u8) Allocator.Error!void {
    const z = try ctx.allocator.dupeZ(u8, content);
    var tok = std.zig.Tokenizer.init(z);
    var in_test = false;
    var depth: u32 = 0;
    var test_depth: u32 = 0;

    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;

        switch (t.tag) {
            .keyword_test => {
                in_test = true;
                test_depth = depth + 1;
            },
            .l_brace => depth += 1,
            .r_brace => {
                if (depth > 0) depth -= 1;
                if (in_test and depth < test_depth) in_test = false;
            },
            .string_literal => {
                if (in_test) continue;
                const raw = z[t.loc.start..t.loc.end];
                if (raw.len < 4) continue;
                const inner = raw[1 .. raw.len - 1];
                if (suspicious(inner)) |kind| try report(ctx, z, t.loc.start, kind);
            },
            else => {},
        }
    }
}

const PrefixKind = struct { prefix: []const u8, kind: []const u8 };

const suspicious_prefixes = [_]PrefixKind{
    .{ .prefix = "/etc/", .kind = "absolute /etc path" },
    .{ .prefix = "/usr/", .kind = "absolute /usr path" },
    .{ .prefix = "/var/", .kind = "absolute /var path" },
    .{ .prefix = "/opt/", .kind = "absolute /opt path" },
    .{ .prefix = "/home/", .kind = "absolute /home path" },
    .{ .prefix = "/tmp/", .kind = "absolute /tmp path" },
    .{ .prefix = "http://", .kind = "hardcoded http URL" },
    .{ .prefix = "https://", .kind = "hardcoded https URL" },
};

fn suspicious(s: []const u8) ?[]const u8 {
    for (suspicious_prefixes) |entry| {
        if (std.mem.startsWith(u8, s, entry.prefix)) return entry.kind;
    }
    if (looksLikeWindowsAbsolute(s)) return "absolute Windows path";
    return null;
}

fn looksLikeWindowsAbsolute(s: []const u8) bool {
    if (s.len < 3) return false;
    const drive_letter = std.ascii.isAlphabetic(s[0]);
    const has_colon = s[1] == ':';
    const has_sep = s[2] == '\\' or s[2] == '/';
    return drive_letter and has_colon and has_sep;
}

fn report(ctx: *ScanCtx, z: []const u8, byte: usize, kind: []const u8) Allocator.Error!void {
    const line = lineOf(z, byte);
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: hardcoded literal ({s})",
        .{ ctx.rel_path, line, kind },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
    extra_allowed: []const []const u8 = &.{},
};

/// True if `rel_path` matches a compiled architectural default or a configured
/// [[allow]] path for this check.
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (allowed_paths) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.extra_allowed)) return;
    var local: ScanCtx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
    };
    try scan(&local, entry.content);
}

/// Entry point for the ban-hardcoded-paths check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .extra_allowed = ctx.cfg.extraAllowed("ban-hardcoded-paths"),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("ban-hardcoded-paths: no hardcoded paths or URLs", .{});
        return;
    }
    reporter.fail("ban-hardcoded-paths FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: read the value from config or pass as a parameter; keep config under config/.\n", .{});
    return error.CheckFailed;
}

// spec: Hidden Dependency Bans - Rejects hardcoded absolute paths and URLs in string literals

test "analyzeContent flags absolute /etc path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const p = "/etc/passwd";
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags https URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const u = "https://example.com/api";
    );
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows relative path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\const p = "config/local.toml";
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows hardcoded paths inside config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/config.zig",
        \\const p = "/etc/passwd";
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows paths in test blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try analyzeContent(arena.allocator(), "src/x.zig",
        \\test "ok" { const p = "/etc/passwd"; _ = p; }
    );
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
