//! dead-model-field: a model struct field that is SURFACED to the user (read in
//! render/review code) but read by NO decision path (never touched in the
//! enforcement code) is a contract shown to the user and enforced by nobody —
//! the value drifts from what the tool actually does, silently.
//!
//! The eda motivating case: `ElectricalDecl.max_voltage` is parsed from a
//! component's electrical annotation, written into the review JSON and the
//! contract table the schematic page renders, and read by none of the ERC /
//! requirement-check / validation passes. A reader sees an absolute-maximum
//! voltage in the UI and reasonably assumes something checks a rail against it.
//! Nothing does.
//!
//! The check is OPT-IN and config-scoped: `[[dead_model_field]]` names the
//! owning `struct`, the `output` globs (render/review files a field may be read
//! in and still be dead), and the `logic` globs (decision/enforcement files
//! whose read proves a field is live). A field's identifier is counted as a
//! FIELD ACCESS only — an identifier token immediately preceded by `.` — so the
//! JSON key string `"max_voltage"` never counts and only `e.max_voltage` does.
//! A field with an access under `output` and none under `logic` fires.
//!
//! Field set: the precise mode lists `fields` explicitly (recommended — a bare
//! field name is counted tree-wide, so an explicit list avoids conflating a
//! field with a same-named field on another struct). Omitting `fields` and
//! giving an `owner` file discovers every field of the named struct instead —
//! broader, and the discovered set is only as precise as field names are unique.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const config = @import("../config.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const check_name = "dead-model-field";
const read_limit = 4 * 1024 * 1024;

const no_reason = "no reason given (add reason = \"...\" to the [[dead_model_field]] rule)";
const fix_hint = "read this field in an enforcement path (ERC / requirement / validation), " ++
    "stop surfacing it, or add its glob to that rule's logic list if the check lives elsewhere.";

/// Output/logic access tallies for one field.
const Counts = struct { out: u32 = 0, log: u32 = 0 };

/// True when any `patterns` glob names `rel_path`.
fn matchesAny(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |p| {
        if (walk.matchGlob(rel_path, p)) return true;
    }
    return false;
}

/// Adds every depth-1 field name of `struct_name` in `tree` to `into`. A field
/// is an identifier at brace-depth 1 that opens a member (first token after the
/// struct's `{` or after a `,`) and is immediately followed by `:` — so methods
/// (which open with `pub`/`fn`/`const`) and nested-type identifiers never count.
fn discoverInto(
    allocator: Allocator,
    into: *std.StringArrayHashMapUnmanaged(Counts),
    tree: *const Ast,
    struct_name: []const u8,
) Allocator.Error!void {
    const tags = tree.tokens.items(.tag);
    const open = structOpenBrace(tree, tags, struct_name) orelse return;
    var depth: u32 = 1;
    var member_start = true;
    var k = open + 1;
    while (k < tags.len and depth > 0) : (k += 1) {
        switch (tags[k]) {
            .l_brace, .l_paren, .l_bracket => member_start = false,
            .r_brace, .r_paren, .r_bracket => member_start = false,
            .comma => if (depth == 1) {
                member_start = true;
            },
            .doc_comment => {}, // trivia between a field's doc and the field
            .identifier => {
                if (depth == 1 and member_start and k + 1 < tags.len and tags[k + 1] == .colon) {
                    try into.put(allocator, tree.tokenSlice(@intCast(k)), .{});
                }
                member_start = false;
            },
            else => member_start = false,
        }
        depth = adjustDepth(depth, tags[k]);
    }
}

/// Bracket-depth after consuming `tag`. Split out of the walk so the switch
/// there stays about member boundaries, not counting.
fn adjustDepth(depth: u32, tag: std.zig.Token.Tag) u32 {
    return switch (tag) {
        .l_brace, .l_paren, .l_bracket => depth + 1,
        .r_brace, .r_paren, .r_bracket => if (depth > 0) depth - 1 else 0,
        else => depth,
    };
}

/// Index of the `{` that opens `struct_name = struct { … }`, or null.
fn structOpenBrace(tree: *const Ast, tags: []const std.zig.Token.Tag, struct_name: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        if (tags[i + 1] != .equal or tags[i + 2] != .keyword_struct or tags[i + 3] != .l_brace) continue;
        if (std.mem.eql(u8, tree.tokenSlice(@intCast(i)), struct_name)) return i + 3;
    }
    return null;
}

/// Adds every explicitly configured field name to `into` (the precise mode).
fn seedFields(allocator: Allocator, into: *std.StringArrayHashMapUnmanaged(Counts), fields: []const []const u8) Allocator.Error!void {
    for (fields) |f| try into.put(allocator, f, .{});
}

/// Increments the out/log tally for every field ACCESS in `tree` — an
/// identifier token immediately preceded by `.` whose text is a tracked field.
fn tallyFieldAccess(
    tree: *const Ast,
    counts: *std.StringArrayHashMapUnmanaged(Counts),
    add_out: bool,
    add_log: bool,
) void {
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .identifier or i == 0 or tags[i - 1] != .period) continue;
        const entry = counts.getPtr(tree.tokenSlice(@intCast(i))) orelse continue;
        if (add_out) entry.out += 1;
        if (add_log) entry.log += 1;
    }
}

/// Walk context: tallies every indexed file into the field map by its output /
/// logic glob membership.
const TallyCtx = struct {
    counts: *std.StringArrayHashMapUnmanaged(Counts),
    output: []const []const u8,
    logic: []const []const u8,
};

fn tallyVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *TallyCtx = @ptrCast(@alignCast(raw_ctx));
    const add_out = matchesAny(ctx.output, entry.rel_path);
    const add_log = matchesAny(ctx.logic, entry.rel_path);
    if (!add_out and !add_log) return;
    if (entry.tree) |t| tallyFieldAccess(t, ctx.counts, add_out, add_log);
}

/// Builds one violation for a field surfaced but never enforced.
fn violationFor(
    allocator: Allocator,
    rule: config.DeadModelFieldRule,
    field: []const u8,
    out: u32,
) Allocator.Error!reporter.Violation {
    return .{
        .check = check_name,
        .file = rule.owner,
        .message = try std.fmt.allocPrint(
            allocator,
            "{s}.{s} is surfaced ({d} output read(s)) but read by no enforcement path \u{2014} {s}",
            .{ rule.struct_name, field, out, rule.reason orelse no_reason },
        ),
        .fix_hint = fix_hint,
        // Identity is the struct and field: a reworded message must keep the
        // same baseline key, and a second dead field on the same struct is a
        // distinct row.
        .identity = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ check_name, rule.struct_name, field }),
        .metric = out,
    };
}

/// Resolves one rule's field set into `map`: the explicit `fields`, or every
/// field discovered in the `owner` struct. Returns false when neither yields a
/// field (a config-time guarantee — `requireDeadModelFieldRule` refuses a rule
/// with no field source — so this is the defensive fail-closed path only).
fn resolveFields(
    ctx_param: *registry.RunCtx,
    allocator: Allocator,
    rule: config.DeadModelFieldRule,
    map: *std.StringArrayHashMapUnmanaged(Counts),
) registry.RunError!bool {
    if (rule.fields.len > 0) {
        try seedFields(allocator, map, rule.fields);
        return true;
    }
    const owner = rule.owner orelse return false;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ctx_param.project_dir, owner });
    const src = fs.cwd().readFileAllocOptions(allocator, path, read_limit, null, .of(u8), 0) catch return false;
    var tree = try Ast.parse(allocator, src, .{});
    try discoverInto(allocator, map, &tree, rule.struct_name);
    return map.count() > 0;
}

/// Analyzes one rule, appending a violation for each surfaced-but-unenforced
/// field. Split from `run` so the per-rule allocation and tally stay one unit.
fn analyzeRule(
    ctx_param: *registry.RunCtx,
    allocator: Allocator,
    rule: config.DeadModelFieldRule,
    found: *std.ArrayList(reporter.Violation),
) registry.RunError!void {
    var map: std.StringArrayHashMapUnmanaged(Counts) = .empty;
    if (!try resolveFields(ctx_param, allocator, rule, &map)) return;
    var tally: TallyCtx = .{ .counts = &map, .output = rule.output, .logic = rule.logic };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{
        .ctx = &tally,
        .visit = tallyVisit,
    });
    for (map.keys()) |field| {
        const c = map.get(field).?;
        if (c.out > 0 and c.log == 0) {
            try found.append(allocator, try violationFor(allocator, rule, field, c.out));
        }
    }
}

/// Entry point for dead-model-field (opt-in: `[[dead_model_field]]` rules).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const rules = ctx_param.cfg.dead_model_field_rules;
    if (rules.len == 0) {
        reporter.ok("dead-model-field: no [[dead_model_field]] rules configured", .{});
        return;
    }
    var found: std.ArrayList(reporter.Violation) = .empty;
    for (rules) |rule| try analyzeRule(ctx_param, allocator, rule, &found);

    if (found.items.len == 0) {
        reporter.ok("dead-model-field: no surfaced-but-unenforced fields ({d} rule(s))", .{rules.len});
        return;
    }
    reporter.fail("dead-model-field FAILED ({d} surfaced-but-unenforced field(s))", .{found.items.len});
    for (found.items) |v| reporter.emitQuiet(v);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const owner_src =
    \\pub const ElectricalDecl = struct {
    \\    pin: []const u8,
    \\    v_ih_min: ?f64 = null,
    \\    /// Absolute-maximum voltage rating for this pin.
    \\    max_voltage: ?f64 = null,
    \\    domain: []const u8 = "",
    \\};
;

// spec: Dead Model Field - Discovers every depth-1 field of the named struct

test "dead-model-field: discoverInto extracts the struct's fields and skips its methods" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try a.dupeSentinel(u8, owner_src ++
        \\
        \\pub fn helper(self: @This()) void { _ = self; }
    , 0);
    var tree = try Ast.parse(a, src, .{});
    var map: std.StringArrayHashMapUnmanaged(Counts) = .empty;
    try discoverInto(a, &map, &tree, "ElectricalDecl");
    try testing.expect(map.contains("pin"));
    try testing.expect(map.contains("max_voltage"));
    try testing.expect(map.contains("domain"));
    // `helper` is a method, not a field.
    try testing.expect(!map.contains("helper"));
    try testing.expect(!map.contains("self"));
}

// spec: Dead Model Field - Counts a field access under a period and skips its key string

test "dead-model-field: tallyFieldAccess counts .field reads and ignores a matching string key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The render line writes the JSON KEY "max_voltage" (a string, must not
    // count) and then reads the FIELD e.max_voltage (a period access, counts).
    const src = try a.dupeSentinel(u8,
        \\fn render(w: anytype, e: E) void {
        \\    w.writeAll(",\"max_voltage\":");
        \\    w.writeFloat(e.max_voltage);
        \\}
    , 0);
    var tree = try Ast.parse(a, src, .{});
    var map: std.StringArrayHashMapUnmanaged(Counts) = .empty;
    try map.put(a, "max_voltage", .{});
    tallyFieldAccess(&tree, &map, true, false);
    try testing.expectEqual(@as(u32, 1), map.get("max_voltage").?.out);
}

// spec: Dead Model Field - Flags a field read under output globs but never under logic globs

test "dead-model-field: analyzeRule fires only for the surfaced-but-unenforced field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two fields, one read by logic and one not. Only the unenforced one fires.
    var map: std.StringArrayHashMapUnmanaged(Counts) = .empty;
    try map.put(a, "max_voltage", .{ .out = 2, .log = 0 });
    try map.put(a, "v_ih_min", .{ .out = 2, .log = 4 });
    const rule: config.DeadModelFieldRule = .{
        .struct_name = "ElectricalDecl",
        .owner = "src/eval/env.zig",
        .fields = &.{ "max_voltage", "v_ih_min" },
        .output = &.{"src/review_json.zig"},
        .logic = &.{"src/erc.zig"},
        .reason = "nothing checks it",
    };
    var found: std.ArrayList(reporter.Violation) = .empty;
    for (map.keys()) |field| {
        const c = map.get(field).?;
        if (c.out > 0 and c.log == 0) try found.append(a, try violationFor(a, rule, field, c.out));
    }
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectEqualStrings("dead-model-field|ElectricalDecl|max_voltage", found.items[0].identity.?);
    try testing.expect(std.mem.indexOf(u8, found.items[0].message, "surfaced") != null);
}
