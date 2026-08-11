//! Shared engine for the "banned symbol" checks (ban-time/rng/fs/net/env/sleep,
//! debug-print-ban, deprecated-alias): each wrapper supplies a rule table of
//! dotted symbol chains plus an allowed-path set, and this walks the token
//! stream flagging any use outside the exempt paths. Reuses the shared AST tree
//! when present, else parses the file once.
//!
//! The `ban` check (src/checks/ban.zig) drives the same engine from the
//! project's own `[[ban]]` guardian.toml entries instead of a compiled table, so
//! matching semantics — identifier-chain matching, the test/main permissive
//! scopes, no alias resolution — are shared rather than reinvented.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const measurement = @import("../measurement.zig");

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
    /// The modern spelling to reach for instead, appended to the violation as
    /// `<display> → use <replacement>`. Null for the hidden-dependency bans,
    /// whose fix is "inject a port", not a one-to-one rename.
    replacement: ?[]const u8 = null,
    /// Free-form rationale appended as `<display> is banned here — <note>`, used
    /// when the alternative is a sentence rather than a symbol name. This is how
    /// the config-driven `ban` check carries a `[[ban]]` rule's `reason`; the
    /// compiled bans leave it null and keep their own wording. Ignored when
    /// `replacement` is set.
    note: ?[]const u8 = null,
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
    violations: *std.ArrayList(reporter.Violation),
    opts: ScanOpts,
    /// Tags emitted records for the JSONL sink. Empty under `analyzeContent`,
    /// which renders to text and never reaches the sink.
    check_name: []const u8 = "",
};

/// Public entry point for the in-process pure-function scan. Returns
/// the violation lines (allocator-owned). Used by tests and `scan`.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
    opts: ScanOpts,
) Allocator.Error![]const []const u8 {
    return reporter.flatLines(allocator, try analyzeRecords(allocator, rel_path, content, opts));
}

/// The structured form of `analyzeContent`: each hit as a `reporter.Violation`
/// carrying an `identity` of `<file>|<banned symbol>`. That identity is what the
/// baseline keys on, so this family's messages — which name the replacement
/// inline and have been reworded before (the 2026-07-20 `deprecated-alias`
/// consumer red) — can change without re-keying anyone's baseline.
pub fn analyzeRecords(
    allocator: Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
    opts: ScanOpts,
) Allocator.Error![]const reporter.Violation {
    var tree = try std.zig.Ast.parse(allocator, content, .zig);
    return analyzeTree(allocator, rel_path, &tree, opts);
}

/// The pre-parsed form of `analyzeRecords`: scans a tree the caller already
/// holds (the shared AST index's), so a check driving this engine across the
/// whole tree doesn't pay a second parse per file. `analyzeRecords` is this plus
/// the parse.
pub fn analyzeTree(
    allocator: Allocator,
    rel_path: []const u8,
    tree: *const std.zig.Ast,
    opts: ScanOpts,
) Allocator.Error![]const reporter.Violation {
    var violations: std.ArrayList(reporter.Violation) = .empty;
    for (opts.allowed_paths) |pat| {
        if (walk.matchGlob(rel_path, pat)) return violations.toOwnedSlice(allocator);
    }
    var ctx: Ctx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
        .opts = opts,
    };
    try scanTree(&ctx, tree);
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
    // Name the replacement inline when the rule supplies one (deprecated-alias),
    // so the reader sees what to reach for without opening the fix hint. The
    // file/line move into the record's own fields; `flatLine` re-renders the
    // identical `<file>:<line>: <message>` text this used to format by hand.
    const msg = try renderMessage(a, rule);
    // The walker's rel_path is only valid for this visit, so copy it: the record
    // outlives the walk.
    const file = try a.dupe(u8, ctx.rel_path);
    try ctx.violations.append(a, .{
        .check = ctx.check_name,
        .file = file,
        .line = line,
        .message = msg,
        // The remedy rides on the record, not only on the trailing `fix:` line
        // this family prints once per run: the JSONL sink reads records, so a
        // hint printed after the list never reached an agent's fix loop.
        .fix_hint = try renderFixHint(a, rule, ctx.opts.fix_hint),
        // What was flagged: this banned symbol in this file. Repeated hits in one
        // file share the identity, and the baseline's multiset diff keeps their
        // count, so removing one of three still registers as an improvement.
        .identity = try std.fmt.allocPrint(a, "{s}|{s}", .{ file, rule.display }),
    });
}

/// Per-hit remedy. A rule that names a modern spelling gets the mechanical
/// rename; everything else gets the check's own architectural hint (inject a
/// port, route through the logger, use the alternative the `[[ban]]` reason
/// names), which is the same text the run prints once beneath the list.
fn renderFixHint(a: Allocator, rule: Rule, check_hint: []const u8) Allocator.Error![]const u8 {
    if (rule.replacement) |repl| return std.fmt.allocPrint(a, "rename to {s}", .{repl});
    return check_hint;
}

/// Renders a hit's message: the replacement rename when the rule names one, the
/// project's rationale when a `[[ban]]` rule supplied one, else the plain
/// hidden-dependency wording. The identity is derived from file + display, not
/// from this text, so all three shapes key identically.
fn renderMessage(a: Allocator, rule: Rule) Allocator.Error![]const u8 {
    if (rule.replacement) |repl| return std.fmt.allocPrint(a, "{s} → use {s}", .{ rule.display, repl });
    if (rule.note) |n| return std.fmt.allocPrint(a, "{s} is banned here — {s}", .{ rule.display, n });
    return std.fmt.allocPrint(a, "{s} reference outside allowed paths", .{rule.display});
}

const lineOf = @import("../text.zig").lineOf;

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayList(reporter.Violation),
    opts: ScanOpts,
    check_name: []const u8,
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
        .check_name = ctx.check_name,
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

    var found: std.ArrayList(reporter.Violation) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &found,
        .opts = merged,
        .check_name = check_name,
    };
    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    // Split off anything a live `[measurement]` path bridges for this check
    // (ban-time's phase timers, debug-print-ban's read-out prints): those are
    // reported under the non-blocking MEASURE verb and never counted here. The
    // partition is a no-op unless the bridge is live (see measurement.zig).
    const violations = try partitionMeasured(ctx_param, allocator, check_name, found.items);

    if (violations.items.len == 0) {
        reporter.ok("{s}: no forbidden references", .{check_name});
        return;
    }
    reporter.fail("{s} FAILED ({d} occurrence(s))", .{ check_name, violations.items.len });
    for (violations.items) |v| reporter.emit(v);
    detail("  fix: {s}\n", .{opts.fix_hint});
    return error.CheckFailed;
}

/// Routes every finding inside a live measurement path to the MEASURE channel,
/// returning the blocking remainder. With no live bridge the exemption is inert
/// and every finding passes straight through.
fn partitionMeasured(
    ctx_param: *registry.RunCtx,
    allocator: Allocator,
    check_name: []const u8,
    found: []const reporter.Violation,
) registry.RunError!std.ArrayList(reporter.Violation) {
    var exempt = measurement.forCheck(allocator, ctx_param, check_name);
    var blocking: std.ArrayList(reporter.Violation) = .empty;
    for (found) |v| {
        const file = v.file orelse "";
        if (exempt.covers(file)) {
            try exempt.record(file, try reporter.flatLine(allocator, v));
            continue;
        }
        try blocking.append(allocator, v);
    }
    try exempt.report();
    return blocking;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Violation Identity - Identifies a banned symbol hit by its file and symbol rather than its wording

test "analyzeRecords keys a hit by file and symbol while rendering the same text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A rule with a replacement — the shape whose message gained "→ use ..." and
    // re-keyed a consumer's deprecated-alias baseline on 2026-07-20.
    const rules = [_]Rule{.{
        .chain = &.{"ArrayListUnmanaged"},
        .display = "std.ArrayListUnmanaged",
        .replacement = "std.ArrayList",
    }};
    const content =
        \\fn f() void {
        \\    var x: std.ArrayListUnmanaged(u8) = .empty;
        \\    _ = x;
        \\}
    ;
    const recs = try analyzeRecords(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    // The identity names the file and the banned symbol — no prose, no line
    // number, no replacement text — so rewording the message cannot move it.
    try std.testing.expectEqualStrings("src/x.zig|std.ArrayListUnmanaged", recs[0].identity.?);
    // File and line ride in the record's own fields rather than the message.
    try std.testing.expectEqualStrings("src/x.zig", recs[0].file.?);
    try std.testing.expectEqual(@as(u32, 2), recs[0].line.?);

    // The rendered text is unchanged from the hand-formatted line this replaced,
    // so existing output and the text-scraping fallback both still hold.
    const lines = try analyzeContent(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqualStrings(
        "src/x.zig:2: std.ArrayListUnmanaged → use std.ArrayList",
        lines[0],
    );
}

test "analyzeTree scans a pre-parsed tree identically to analyzeRecords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]Rule{.{ .chain = &.{ "std", "time", "timestamp" }, .display = "std.time.timestamp" }};
    const content =
        \\fn now() i64 { return std.time.timestamp(); }
    ;
    // The whole point of the entry point: the caller already parsed this file
    // (the shared AST index did), so the scan must not need a second parse.
    var tree = try std.zig.Ast.parse(a, content, .zig);
    const from_tree = try analyzeTree(a, "src/x.zig", &tree, .{ .rules = &rules });
    const from_source = try analyzeRecords(a, "src/x.zig", content, .{ .rules = &rules });
    try std.testing.expectEqual(from_source.len, from_tree.len);
    try std.testing.expectEqualStrings(from_source[0].message, from_tree[0].message);
    try std.testing.expectEqualStrings(from_source[0].identity.?, from_tree[0].identity.?);
}

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
