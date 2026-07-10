const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;

/// One token chain to ban. e.g. `&.{"std","time","timestamp"}` for
/// `std.time.timestamp`. The `display` field is the human-readable
/// form printed in violation messages.
pub const Rule = struct {
    chain: []const []const u8,
    display: []const u8,
    /// When true, only flag the chain if it's followed by `(` (a call
    /// expression). When false, flag any reference (incl. aliases) —
    /// the safer default for hidden-dependency bans, since aliasing
    /// would otherwise launder a forbidden symbol.
    require_call: bool = false,
};

/// Scanner options. Each ban check builds these once and hands them to
/// `scan` / `analyzeContent`.
pub const ScanOpts = struct {
    rules: []const Rule,
    /// Glob patterns where these symbols are allowed regardless. Matched
    /// against the file's display path, e.g. `"src/infra/clock*"`.
    allowed_paths: []const []const u8 = &.{},
    /// Allow inside `test {...}` blocks.
    allow_in_tests: bool = true,
    /// Allow inside `pub fn main`.
    allow_in_main: bool = true,
    /// Fix hint shown after the violation list.
    fix_hint: []const u8 = "inject this dependency through a wiring-layer port instead of using it directly.",
};

/// Per-rule state for the chain-match state machine.
const Match = struct {
    matched: u32 = 0,
    awaiting_dot: bool = false,
    start_byte: usize = 0,

    fn reset(self: *Match) void {
        self.* = .{};
    }

    /// Try to advance the match on a new identifier `text` at `byte`.
    /// Returns true iff this advance just completed the chain.
    fn onIdent(self: *Match, rule: Rule, text: []const u8, byte: usize) bool {
        if (self.awaiting_dot) self.reset();
        if (self.matched < rule.chain.len and std.mem.eql(u8, text, rule.chain[self.matched])) {
            if (self.matched == 0) self.start_byte = byte;
            self.matched += 1;
            self.awaiting_dot = true;
            return self.matched == rule.chain.len;
        }
        self.reset();
        if (rule.chain.len > 0 and std.mem.eql(u8, text, rule.chain[0])) {
            self.start_byte = byte;
            self.matched = 1;
            self.awaiting_dot = true;
            return self.matched == rule.chain.len;
        }
        return false;
    }

    /// Advance over a period token. Returns true if the period kept the
    /// match alive; false means the chain is broken and state was reset.
    fn onDot(self: *Match, rule: Rule) bool {
        if (self.awaiting_dot and self.matched < rule.chain.len) {
            self.awaiting_dot = false;
            return true;
        }
        self.reset();
        return false;
    }
};

/// Per-file scan running state — bundled so step functions stay under
/// the function-size cap.
const ScanState = struct {
    z: []const u8,
    states: []Match,
    depth: u32 = 0,
    permissive: std.ArrayList(u32) = .empty,
    pending_permissive: bool = false,
    saw_fn: bool = false,
};

const Ctx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayList([]const u8),
    opts: ScanOpts,
};

/// Public entry point for the in-process pure-function scan. Returns
/// the violation lines (allocator-owned). Used by tests and `scan`.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
    opts: ScanOpts,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    for (opts.allowed_paths) |pat| {
        if (walk.matchGlob(rel_path, pat)) return violations.toOwnedSlice(allocator);
    }
    var ctx: Ctx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
        .opts = opts,
    };
    var tree = try std.zig.Ast.parse(allocator, content, .zig);
    try scanTree(&ctx, &tree);
    return violations.toOwnedSlice(allocator);
}

/// Scans a file's pre-parsed token stream. Iterating the shared tree's tokens
/// avoids the per-check `dupeZ` + full re-tokenize; only identifiers need their
/// end offset (to read text), so `tokenSlice` is called only for those.
fn scanTree(ctx: *Ctx, tree: *const std.zig.Ast) Allocator.Error!void {
    const a = ctx.allocator;
    const states = try a.alloc(Match, ctx.opts.rules.len);
    defer a.free(states);
    for (states) |*s| s.reset();

    var state: ScanState = .{ .z = tree.source, .states = states };
    defer state.permissive.deinit(a);

    const tags = tree.tokens.items(.tag);
    const starts = tree.tokens.items(.start);
    for (tags, 0..) |tag, i| {
        if (tag == .eof) break;
        const start: usize = starts[i];
        const end = if (tag == .identifier) start + tree.tokenSlice(@intCast(i)).len else start;
        try stepToken(ctx, &state, .{ .tag = tag, .loc = .{ .start = start, .end = end } });
    }
}

fn stepToken(ctx: *Ctx, st: *ScanState, t: std.zig.Token) Allocator.Error!void {
    const a = ctx.allocator;
    switch (t.tag) {
        .keyword_test => {
            if (ctx.opts.allow_in_tests) st.pending_permissive = true;
            st.saw_fn = false;
            resetAll(st.states);
        },
        .keyword_fn => {
            st.saw_fn = true;
            resetAll(st.states);
        },
        .l_brace => {
            st.depth += 1;
            if (st.pending_permissive) {
                try st.permissive.append(a, st.depth);
                st.pending_permissive = false;
            }
            resetAll(st.states);
        },
        .r_brace => {
            const p = st.permissive.items;
            if (p.len > 0 and p[p.len - 1] == st.depth) _ = st.permissive.pop();
            if (st.depth > 0) st.depth -= 1;
            resetAll(st.states);
        },
        .identifier => try handleIdent(ctx, st, t),
        .period => for (ctx.opts.rules, 0..) |rule, i| {
            _ = st.states[i].onDot(rule);
        },
        .l_paren => try handleLParen(ctx, st),
        else => {
            resetAll(st.states);
            st.saw_fn = false;
        },
    }
}

fn handleIdent(ctx: *Ctx, st: *ScanState, t: std.zig.Token) Allocator.Error!void {
    const text = st.z[t.loc.start..t.loc.end];
    if (st.saw_fn) {
        if (ctx.opts.allow_in_main and std.mem.eql(u8, text, "main")) st.pending_permissive = true;
        st.saw_fn = false;
    }
    for (ctx.opts.rules, 0..) |rule, i| {
        const completed = st.states[i].onIdent(rule, text, t.loc.start);
        if (completed and !rule.require_call) {
            if (st.permissive.items.len == 0) {
                try recordViolation(ctx, st.z, st.states[i].start_byte, rule);
            }
            st.states[i].reset();
        }
    }
}

fn handleLParen(ctx: *Ctx, st: *ScanState) Allocator.Error!void {
    for (ctx.opts.rules, 0..) |rule, i| {
        if (rule.require_call and st.states[i].matched == rule.chain.len) {
            if (st.permissive.items.len == 0) {
                try recordViolation(ctx, st.z, st.states[i].start_byte, rule);
            }
        }
        st.states[i].reset();
    }
}

fn resetAll(states: []Match) void {
    for (states) |*s| s.reset();
}

fn recordViolation(ctx: *Ctx, z: []const u8, start_byte: usize, rule: Rule) Allocator.Error!void {
    const a = ctx.allocator;
    const line = lineOf(z, start_byte);
    const msg = try std.fmt.allocPrint(
        a,
        "{s}:{d}: {s} reference outside allowed paths",
        .{ ctx.rel_path, line, rule.display },
    );
    try ctx.violations.append(a, msg);
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList([]const u8),
    opts: ScanOpts,
};

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    for (ctx.opts.allowed_paths) |pat| {
        if (walk.matchGlob(entry.rel_path, pat)) return;
    }
    var local: Ctx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
        .opts = ctx.opts,
    };
    // Reuse the shared parse when the index provides it; parse standalone only
    // for a single-check run with no shared index.
    if (entry.tree) |t| {
        try scanTree(&local, t);
    } else {
        var tree = try std.zig.Ast.parse(ctx.allocator, entry.content, .zig);
        try scanTree(&local, &tree);
    }
}

/// Concatenates a check's compiled allowed paths with any configured via
/// [[allow]] in guardian.toml. Returns `base` unchanged when there are no
/// extras, so the common (no-config) path allocates nothing.
fn mergeAllowed(
    allocator: Allocator,
    base: []const []const u8,
    extra: []const []const u8,
) Allocator.Error![]const []const u8 {
    if (extra.len == 0) return base;
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(allocator, base);
    try list.appendSlice(allocator, extra);
    return list.toOwnedSlice(allocator);
}

/// Run the banned-symbol scan against the project's `src/` tree and
/// emit a Guardian-style ok/fail report.
pub fn scan(
    ctx_param: *registry.RunCtx,
    check_name: []const u8,
    opts: ScanOpts,
) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;

    // Merge the check's compiled architectural defaults with any [[allow]]
    // entries from guardian.toml, so self-hosting exemptions live in config
    // rather than punching holes into every downstream repo.
    var merged = opts;
    merged.allowed_paths = try mergeAllowed(allocator, opts.allowed_paths, ctx_param.cfg.extraAllowed(check_name));

    var violations: std.ArrayList([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .opts = merged,
    };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("{s}: no forbidden references", .{check_name});
        return;
    }
    reporter.fail("{s} FAILED ({d} occurrence(s))", .{ check_name, violations.items.len });
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: {s}\n", .{opts.fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "analyzeContent flags simple chain reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "time", "timestamp" },
        .display = "std.time.timestamp",
    }};
    const content =
        \\fn now() i64 {
        \\    return std.time.timestamp();
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows reference inside test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "time", "timestamp" },
        .display = "std.time.timestamp",
    }};
    const content =
        \\test "now" {
        \\    _ = std.time.timestamp();
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent allows reference inside pub fn main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "time", "timestamp" },
        .display = "std.time.timestamp",
    }};
    const content =
        \\pub fn main() !void {
        \\    _ = std.time.timestamp();
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent skips files matching allowed_paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "time", "timestamp" },
        .display = "std.time.timestamp",
    }};
    const content =
        \\fn now() i64 { return std.time.timestamp(); }
    ;
    const out = try analyzeContent(a, "src/infra/clock.zig", content, .{
        .rules = &rules,
        .allowed_paths = &.{"src/infra/clock*"},
    });
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags alias declaration when require_call=false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "time", "timestamp" },
        .display = "std.time.timestamp",
    }};
    const content =
        \\const ts = std.time.timestamp;
    ;
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent allows alias declaration when require_call=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "debug", "print" },
        .display = "std.debug.print",
        .require_call = true,
    }};
    const content =
        \\const print = std.debug.print;
        \\fn use() void { print("hi", .{}); }
    ;
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags call when require_call=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "debug", "print" },
        .display = "std.debug.print",
        .require_call = true,
    }};
    const content =
        \\fn use() void { std.debug.print("hi", .{}); }
    ;
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent ignores chain inside string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "time", "timestamp" },
        .display = "std.time.timestamp",
    }};
    const content = "const s = \"std.time.timestamp\";\n";
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags shorter prefix chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{
        .chain = &.{ "std", "fs" },
        .display = "std.fs.*",
    }};
    const content =
        \\fn open() !void {
        \\    _ = try std.fs.cwd().openFile("a", .{});
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 1), out.len);
}
