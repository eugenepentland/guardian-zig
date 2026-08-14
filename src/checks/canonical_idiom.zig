//! The project-configurable canonical-idiom check: enforces the `[[idiom]]`
//! rules a project declares in its own guardian.toml — "this EXPRESSION SHAPE
//! has one canonical implementation; hand-rolling it anywhere else is drift".
//!
//! Guardian's two existing ownership checks each own a NAME. `[[ban]]` owns a
//! symbol chain (`optimizer.placeFromPoses` may only be called through the
//! sanctioned wrapper). `[[concept]]` owns a literal spelling (`"F.Cu"` comes
//! from the layer table). Between them sits the case neither can express: a
//! shape assembled out of perfectly ordinary std calls, which is exactly what an
//! agent re-derives from scratch every time it needs the behaviour, because the
//! shape has no name to search for.
//!
//! Measured in the eda repository on 2026-08-14, all four with a canonical
//! implementation already in the tree:
//!
//!   * **51** sites splitting a sub-block leaf by hand with
//!     `lastIndexOfScalar(u8, <x>, '/')`, under **8** different function names —
//!     so no reader could tell they were one operation, and no `[[ban]]` could
//!     name them (the ban would have to forbid `lastIndexOfScalar` itself, which
//!     is a legitimate std call everywhere else in the tree).
//!   * **6** byte-identical `urlDecodeAlloc` wrappers around
//!     `std.Uri.percentDecodeInPlace`.
//!   * **8** private tmp-file + rename atomic-write implementations.
//!   * **~24** private JSON escaper loops in **7** mutually incompatible tiers,
//!     despite `json_writer.zig` existing and being correct.
//!
//! No named-symbol gate reaches any of them, which is the gap this check
//! closes: **`fragments` is a CONJUNCTION**, so the rule narrows a common std
//! call back down to the one expression that means the idiom.
//! `fragments = ["lastIndexOfScalar", "'/'"]` fires on the leaf split and stays
//! silent on every other use of the same function. That conjunction is the whole
//! design — a single fragment is almost always either too broad to enable or so
//! specific it is really a `[[concept]]` literal.
//!
//! **Matching is single-line and plain-text.** No regex (a rule a reader cannot
//! evaluate in their head is a rule they cannot trust), and no multi-line shapes
//! (deliberately out of scope: an idiom spread over four lines has no stable
//! textual form, and matching one would need the per-language parser the
//! relational checks refuse to be). One violation per (rule, file), because the
//! subject is "this file hand-rolls that idiom" — the count of matching lines
//! rides along as the metric.
//!
//! The comment/test blanking and the every-extension file walk come from
//! `lexical_scan.zig`, shared with `concept`, so a comment describing an idiom
//! can never be reported as one and the two relational checks can never disagree
//! about what a lexical scan may judge.
//!
//! Zero `[[idiom]]` entries is the zero-config default: the check passes without
//! reading a single file.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const lexical = @import("lexical_scan.zig");
const baseline = @import("../baseline.zig");
const config = @import("../config.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const check_name = "canonical-idiom";

/// Stands in for an empty `allow` list. An idiom with no canonical home is
/// banned outright, which is legal — "nobody should write this shape again" —
/// but is far more often a rule whose author forgot to name the helper's file.
const no_home = "nowhere (add allow = [\"...\"] to the [[idiom]] rule)";

const fix_hint = "call the canonical implementation the rule's reason names, " ++
    "or add this path to that [[idiom]] rule's allow list.";

// ── Per-file analysis ───────────────────────────────────────────────────

/// What one rule found in one file: how many LINES carried every fragment, and
/// where the first of them is. The column is carried because a fragment
/// conjunction can fire anywhere on a long line, and "line 412" of a formatting
/// helper is not a location a reader can act on by itself.
const Match = struct {
    count: u64,
    line: u32,
    col: u32,
};

/// The 1-based column of the leftmost fragment occurrence on `line`, or null
/// when the line does not carry ALL of them. Leftmost rather than first-declared
/// so the reported column does not depend on the order the rule happens to list
/// its fragments in.
fn fragmentCol(line: []const u8, fragments: []const []const u8) ?u32 {
    if (fragments.len == 0) return null;
    var leftmost: usize = line.len;
    for (fragments) |fragment| {
        const at = std.mem.indexOf(u8, line, fragment) orelse return null;
        leftmost = @min(leftmost, at);
    }
    return @intCast(leftmost + 1);
}

/// Every line of `text` carrying all of `fragments`, or null when none does.
/// Splitting on `\n` is what makes the scan single-line by construction: no
/// fragment can be satisfied by bytes on a neighbouring line, so the rule means
/// exactly what it reads like.
fn matchIn(text: []const u8, fragments: []const []const u8) ?Match {
    var found: ?Match = null;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const col = fragmentCol(line, fragments) orelse continue;
        if (found) |*hit| {
            hit.count += 1;
        } else {
            found = .{ .count = 1, .line = line_no, .col = col };
        }
    }
    return found;
}

/// True when `rel_path` is one of the places `rule` says the idiom is legal —
/// its canonical implementation's own file, plus whatever else the project
/// blesses. Allow paths use Guardian's ordinary path-glob syntax
/// (`walk.matchGlob`), so a bare path is a substring match and `src/json/*`
/// covers a subtree.
fn allowed(rule: config.IdiomRule, rel_path: []const u8) bool {
    for (rule.allow) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// True when one of `rule`'s own `files` globs names `rel_path`. A rule's
/// `files` scopes THAT rule — it is the rule's domain, not "also scan these" —
/// which is the same per-rule reading `[[concept]]` settled on.
fn namesPath(rule: config.IdiomRule, rel_path: []const u8) bool {
    for (rule.files) |pattern| {
        if (walk.matchGlob(rel_path, pattern)) return true;
    }
    return false;
}

/// Renders a rule's allow list as `"a, b"`, or the `no_home` placeholder.
fn formatHome(allocator: Allocator, rule: config.IdiomRule) Allocator.Error![]const u8 {
    if (rule.allow.len == 0) return no_home;
    return std.mem.join(allocator, ", ", rule.allow);
}

/// Builds the single violation for one (rule, file) pair.
fn violationFor(
    allocator: Allocator,
    rel_path: []const u8,
    rule: config.IdiomRule,
    hit: Match,
) Allocator.Error!reporter.Violation {
    const message = try std.fmt.allocPrint(
        allocator,
        "idiom '{s}' hand-rolled on {d} line(s) (first at col {d}) — canonical home: {s} — {s}",
        .{ rule.name, hit.count, hit.col, try formatHome(allocator, rule), rule.reason },
    );
    // Identity is the RULE and the file, in that order, and never the line or
    // the count: a second hand-rolled site in an already-frozen file must keep
    // the same baseline key, and moving the existing one down the file must not
    // churn it. Rule first (where `[[concept]]` puts the file first) because an
    // idiom's ledger is read the other way round — the question is "which files
    // still hand-roll THIS shape", 51 of them at a time, so sorting the baseline
    // groups a rule's whole cleanup campaign together.
    const identity = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ rule.name, rel_path });
    return .{
        .check = check_name,
        .file = rel_path,
        .line = hit.line,
        .message = message,
        .fix_hint = fix_hint,
        .identity = identity,
        .metric = hit.count,
    };
}

/// Pure core: one violation per rule whose idiom appears in this file outside
/// its allow list. Takes plain bytes, so the same function judges a `.zig` file
/// (whose parse `tree` exempts its test blocks) and any other extension a
/// `files` glob names (`tree` = null).
pub fn analyzeFile(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
    tree: ?*const Ast,
    rules: []const config.IdiomRule,
) Allocator.Error![]const reporter.Violation {
    if (lexical.selfExempt(rel_path) or rules.len == 0) return &.{};
    const text = try lexical.scrubbed(allocator, rel_path, content, tree);
    var violations: std.ArrayList(reporter.Violation) = .empty;
    for (rules) |rule| {
        if (allowed(rule, rel_path) or !namesPath(rule, rel_path)) continue;
        const hit = matchIn(text, rule.fragments) orelse continue;
        try violations.append(allocator, try violationFor(allocator, rel_path, rule, hit));
    }
    return violations.toOwnedSlice(allocator);
}

// ── Run: one glob walk, because every rule has a files set ──────────────

/// Shared across the walk: where findings land, and the paths this check never
/// judges.
const ScanCtx = struct {
    allocator: Allocator,
    rules: []const config.IdiomRule,
    /// Path globs no rule is applied to: a `[[allow]] check = "canonical-idiom"`
    /// entry, plus the top-level `exclude` list. `exclude` is folded in here
    /// because its contract is "no check ever sees a file whose path matches",
    /// and this scan reads from disk rather than through the shared source index
    /// that applies it — so honoring it is this check's own job.
    skip: []const []const u8,
    violations: *std.ArrayList(reporter.Violation),
};

/// The rules whose own `files` globs name `rel_path` — computed BEFORE the read,
/// so a tree full of binaries and vendored assets is never opened for a rule
/// that does not name it.
fn rulesNaming(
    allocator: Allocator,
    rules: []const config.IdiomRule,
    rel_path: []const u8,
) Allocator.Error![]const config.IdiomRule {
    var out: std.ArrayList(config.IdiomRule) = .empty;
    for (rules) |rule| {
        if (namesPath(rule, rel_path)) try out.append(allocator, rule);
    }
    return out.toOwnedSlice(allocator);
}

/// Reads and scans one file against the rules that named it. A `.zig` file
/// parses its own tree so its `test` blocks are exempt — unlike `concept`, this
/// check never reads the shared parsed index, because EVERY rule here carries a
/// `files` set (the default `src/*.zig` when none was declared) and one scan
/// path cannot disagree with itself about how much it read.
fn scanFile(ctx: *ScanCtx, dir: fs.Dir, name: []const u8, rel_path: []const u8) walk.WalkError!void {
    if (lexical.skipPath(ctx.skip, rel_path)) return;
    const rules = try rulesNaming(ctx.allocator, ctx.rules, rel_path);
    if (rules.len == 0) return;
    const content = try dir.readFileAlloc(ctx.allocator, name, lexical.read_limit);
    if (std.mem.endsWith(u8, rel_path, ".zig")) {
        const source = try ctx.allocator.dupeSentinel(u8, content, 0);
        var tree = try Ast.parse(ctx.allocator, source, .{});
        const found = try analyzeFile(ctx.allocator, rel_path, source, &tree, rules);
        return ctx.violations.appendSlice(ctx.allocator, found);
    }
    const found = try analyzeFile(ctx.allocator, rel_path, content, null, rules);
    try ctx.violations.appendSlice(ctx.allocator, found);
}

fn fileVisit(raw_ctx: *anyopaque, dir: fs.Dir, name: []const u8, rel_path: []const u8) walk.WalkError!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try scanFile(ctx, dir, name, rel_path);
}

/// Entry point for the canonical-idiom check (opt-in: declare `[[idiom]]`
/// entries).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const rules = ctx_param.cfg.idiom_rules;
    if (rules.len == 0) {
        reporter.ok("canonical-idiom: no [[idiom]] rules configured", .{});
        return;
    }

    var found: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .rules = rules,
        .skip = try std.mem.concat(allocator, []const u8, &.{
            ctx_param.cfg.extraAllowed(check_name),
            ctx_param.cfg.exclude,
        }),
        .violations = &found,
    };
    var root = try fs.cwd().openDir(ctx_param.project_dir, .{ .iterate = true });
    defer root.close();
    try lexical.walkFiles(allocator, root, "", .{ .ctx = &ctx, .visit = fileVisit });

    if (found.items.len == 0) {
        reporter.ok("canonical-idiom: no hand-rolled idioms ({d} rule(s))", .{rules.len});
        return;
    }
    reporter.fail("canonical-idiom FAILED ({d} file(s) outside a canonical home)", .{found.items.len});
    // emitQuiet, not emit: one shared `fix:` line closes the list below, and
    // repeating a near-identical remedy under every finding is console noise.
    // The hint still rides each record into last-run.jsonl, which has no
    // "beneath the list".
    for (found.items) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The motivating rule, transcribed from the eda measurement in the header: 51
/// sites hand-rolling a sub-block leaf split under 8 different names.
const leaf_rule = config.IdiomRule{
    .name = "subblock-leaf-split",
    .fragments = &.{ "lastIndexOfScalar", "'/'" },
    .files = &.{"src/*.zig"},
    .allow = &.{"src/subblock.zig"},
    .reason = "call subblock.leafOf() — 51 sites hand-rolled this under 8 names",
};

const test_rules = [_]config.IdiomRule{leaf_rule};

// spec: Canonical Idiom - Flags a line carrying every fragment outside the allow list

test "analyzeFile flags a hand-rolled idiom outside its canonical home" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, "src/serve/routes.zig",
        \\fn leaf(ref: []const u8) []const u8 {
        \\    const cut = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return ref;
        \\    return ref[cut + 1 ..];
        \\}
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(check_name, out[0].check);
    try testing.expectEqual(@as(u32, 2), out[0].line.?);
    try testing.expectEqual(@as(u64, 1), out[0].metric.?);
    // Identity is `<rule>|<file>` — a tier-1 key, used whole and never
    // re-qualified (violation_key.fromRecord).
    try testing.expectEqualStrings("subblock-leaf-split|src/serve/routes.zig", out[0].identity.?);
}

// spec: Canonical Idiom - Requires every fragment on one line before reporting

test "analyzeFile ignores a line carrying only some of the fragments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The conjunction is the whole design: `lastIndexOfScalar` alone is an
    // ordinary std call that a rule must not fire on, and a `'/'` alone is a
    // path separator anywhere. Neither line below is the idiom.
    const out = try analyzeFile(a, "src/serve/routes.zig",
        \\const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse 0;
        \\const sep = '/';
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 0), out.len);
    // Nor do two fragments satisfied on ADJACENT lines: matching is single-line
    // by construction, because the scan splits on `\n` before looking.
    const split = try analyzeFile(a, "src/serve/routes.zig",
        \\const cut = std.mem.lastIndexOfScalar(
        \\    u8, ref, '/') orelse return ref;
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 0), split.len);
}

// spec: Canonical Idiom - Ignores the idiom inside a file the rule's allow list names

test "analyzeFile ignores the canonical implementation's own file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), "src/subblock.zig",
        \\pub fn leafOf(ref: []const u8) []const u8 {
        \\    const cut = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return ref;
        \\    return ref[cut + 1 ..];
        \\}
    , null, &test_rules);
    // Somebody has to write the shape once; the allow list is where.
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Canonical Idiom - Ignores a path no files glob of the rule names

test "analyzeFile ignores a file outside the rule's files globs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), "tools/scratch.zig",
        \\const cut = std.mem.lastIndexOfScalar(u8, ref, '/') orelse 0;
    , null, &test_rules);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Canonical Idiom - Skips a line-leading comment and a Zig test block when counting lines

test "analyzeFile counts neither a comment line nor a test block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A comment DESCRIBING the idiom — which a rule's own documentation and
    // every migration note is full of — cannot hand-roll it at runtime. And a
    // test's golden is the independent witness of the canonical helper, not a
    // second implementation. Counting either froze whole files into the ledger,
    // where the file's REAL drift then hides behind `<rule>|<file>` forever.
    const src = try a.dupeSentinel(u8,
        \\// replaced: std.mem.lastIndexOfScalar(u8, ref, '/') — call leafOf now
        \\/// See lastIndexOfScalar(u8, ref, '/') for the shape this replaced.
        \\const x = 1;
        \\test "leafOf matches the hand-rolled shape" {
        \\    const cut = std.mem.lastIndexOfScalar(u8, ref, '/');
        \\    _ = cut;
        \\}
    , 0);
    var tree = try Ast.parse(a, src, .{});
    try testing.expectEqual(@as(usize, 0), (try analyzeFile(a, "src/serve/routes.zig", src, &tree, &test_rules)).len);
    // Without a parse tree the test block is not exempt — the exemption needs a
    // parse, exactly as in `concept`.
    try testing.expectEqual(@as(usize, 1), (try analyzeFile(a, "src/serve/routes.zig", src, null, &test_rules)).len);
}

// spec: Canonical Idiom - Reports one violation per rule and file with the matching-line count and first position

test "analyzeFile reports one violation naming the count, position, home and reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeFile(a, "src/serve/routes.zig",
        \\const x = 1;
        \\  const a = std.mem.lastIndexOfScalar(u8, one, '/');
        \\const b = std.mem.lastIndexOfScalar(u8, two, '/');
    , null, &test_rules);
    // Two matching lines, one violation: the subject is the (rule, file) pair,
    // not each site. The reported position is the FIRST — line 2, and column 21
    // where `lastIndexOfScalar` begins, past the two-space indent.
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(
        "src/serve/routes.zig:2: idiom 'subblock-leaf-split' hand-rolled on 2 line(s) (first at col 21) " ++
            "— canonical home: src/subblock.zig — " ++
            "call subblock.leafOf() — 51 sites hand-rolled this under 8 names",
        try reporter.flatLine(a, out[0]),
    );
}

// spec: Canonical Idiom - Reports the leftmost fragment's column regardless of the declared order

test "fragmentCol reports the leftmost fragment and requires all of them" {
    const fragments = [_][]const u8{ "lastIndexOfScalar", "'/'" };
    // `'/'` is declared second but sits first on this line; the column must not
    // depend on the order a rule happens to list its fragments in.
    try testing.expectEqual(@as(?u32, 11), fragmentCol("const s = '/'; lastIndexOfScalar(x);", &fragments));
    try testing.expectEqual(@as(?u32, 1), fragmentCol("lastIndexOfScalar(u8, r, '/')", &fragments));
    // One fragment missing is no match at all.
    try testing.expectEqual(@as(?u32, null), fragmentCol("lastIndexOfScalar(u8, r, '.')", &fragments));
    // An empty fragment list matches nothing rather than everything — the parser
    // refuses one, so this is the total-function guarantee, not a live case.
    try testing.expectEqual(@as(?u32, null), fragmentCol("anything", &.{}));
}

// spec: Canonical Idiom - Passes trivially when no idiom rules are configured

test "analyzeFile finds nothing when no rules are configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try analyzeFile(arena.allocator(), "src/serve/routes.zig",
        \\const cut = std.mem.lastIndexOfScalar(u8, ref, '/') orelse 0;
    , null, &.{});
    try testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Canonical Idiom - Names the missing canonical home when a rule declares no allow list

test "analyzeFile names an absent allow list in the message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const homeless = [_]config.IdiomRule{.{
        .name = "private-json-escape",
        .fragments = &.{ "switch (c)", "escape" },
        .reason = "use json_writer.escape — 24 private escapers in 7 tiers",
    }};
    const out = try analyzeFile(a, "src/serve/api.zig",
        \\fn escape(c: u8) void { switch (c) { else => {} } }
    , null, &homeless);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(std.mem.indexOf(u8, out[0].message, no_home) != null);
    // And the default `files` set — no key declared — still reaches src/*.zig,
    // which is the whole src subtree under Guardian's `*` (it spans `/`), which
    // is how "src/serve/api.zig" was judged at all.
    try testing.expectEqual(@as(usize, 1), homeless[0].files.len);
    try testing.expectEqualStrings("src/*.zig", homeless[0].files[0]);
}

// spec: Canonical Idiom - Applies a rule to only its own idiom when several are declared

test "analyzeFile keeps two idioms' findings apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.IdiomRule{
        leaf_rule,
        .{
            .name = "atomic-write",
            .fragments = &.{ "makeTmp", "rename" },
            .allow = &.{"src/atomic.zig"},
            .reason = "use atomic.writeFile — 8 private tmp+rename copies",
        },
    };
    // The leaf split's home may still hand-roll the atomic write, so exactly one
    // of the two rules fires there.
    const out = try analyzeFile(a, "src/subblock.zig",
        \\const cut = std.mem.lastIndexOfScalar(u8, ref, '/') orelse 0;
        \\fn save() void { const t = makeTmp(); rename(t, dst); }
    , null, &rules);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("atomic-write|src/subblock.zig", out[0].identity.?);
}

// spec: Canonical Idiom - Exempts guardian.toml and the .guardian directory from every rule

test "analyzeFile never flags the declaration or Guardian's own metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The rule that declares `fragments = ["lastIndexOfScalar", "'/'"]` writes
    // both fragments on one line of guardian.toml, and the baseline records the
    // finding verbatim — flagging either would flag the act of declaring or
    // recording the rule.
    const declaration =
        \\[[idiom]]
        \\fragments = ["lastIndexOfScalar", "'/'"]
    ;
    const toml_rule = [_]config.IdiomRule{.{
        .name = "subblock-leaf-split",
        .fragments = &.{ "lastIndexOfScalar", "'/'" },
        .files = &.{"*.toml"},
        .reason = "call subblock.leafOf()",
    }};
    try testing.expectEqual(@as(usize, 0), (try analyzeFile(a, "guardian.toml", declaration, null, &toml_rule)).len);
    const baselined = "canonical-idiom|subblock-leaf-split|src/x.zig lastIndexOfScalar '/'";
    try testing.expectEqual(
        @as(usize, 0),
        (try analyzeFile(a, ".guardian/baselines/canonical-idiom.txt", baselined, null, &toml_rule)).len,
    );
}

// spec: Canonical Idiom - Scans a globbed non-Zig file and ignores paths no glob names

test "scanFile reads a globbed asset outside the Zig source set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The fixture stylesheet carries `color: #C83434;` on one line. Nothing but
    // a `files` glob reaches a .css file at all, and the rest of the fixture
    // project — which the glob does not name — is never read.
    const rules = [_]config.IdiomRule{.{
        .name = "raw-hex-color",
        .fragments = &.{ "color:", "#C83434" },
        .files = &.{"assets/*.css"},
        .allow = &.{"src/palette.zig"},
        .reason = "reference the palette token instead of respelling the hex",
    }};
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .rules = &rules, .skip = &.{}, .violations = &violations };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try lexical.walkFiles(a, root, "", .{ .ctx = &ctx, .visit = fileVisit });
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqualStrings("raw-hex-color|assets/theme.css", violations.items[0].identity.?);
}

// spec: Canonical Idiom - Skips a path an allow entry or a top-level exclude glob names

test "scanFile drops a file the run's skip list names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = [_]config.IdiomRule{.{
        .name = "raw-hex-color",
        .fragments = &.{ "color:", "#C83434" },
        .files = &.{"assets/*.css"},
        .reason = "reference the palette token instead of respelling the hex",
    }};
    var violations: std.ArrayList(reporter.Violation) = .empty;
    // `[[allow]] check = "canonical-idiom"` and the top-level `exclude` arrive
    // here as one concatenated list; a path either names is never even read.
    const skip = [_][]const u8{"assets/*"};
    var ctx: ScanCtx = .{ .allocator = a, .rules = &rules, .skip = &skip, .violations = &violations };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try lexical.walkFiles(a, root, "", .{ .ctx = &ctx, .visit = fileVisit });
    try testing.expectEqual(@as(usize, 0), violations.items.len);
}

// spec: Canonical Idiom - Parses a globbed Zig file so its test blocks are exempt there too

test "scanFile exempts test blocks in a Zig file a files glob names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "hello world" occurs in the fixture only inside `test "join"`; the
    // debug-print spelling occurs in `pub fn main`. A rule must exempt the first
    // and flag the second — the walk parses its own tree, since this check never
    // reads the shared source index. The second rule doubles as proof the file
    // was read at all, so the zero cannot be the glob silently matching nothing.
    const rules = [_]config.IdiomRule{
        .{
            .name = "greeting-literal",
            .fragments = &.{ "hello", "world" },
            .files = &.{"src/main.zig"},
            .reason = "call greeting.text()",
        },
        .{
            .name = "raw-debug-print",
            .fragments = &.{ "std.debug.print", "{d}" },
            .files = &.{"src/main.zig"},
            .reason = "log through the reporter",
        },
    };
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{ .allocator = a, .rules = &rules, .skip = &.{}, .violations = &violations };
    var root = try fs.cwd().openDir("test-project", .{ .iterate = true });
    defer root.close();
    try lexical.walkFiles(a, root, "", .{ .ctx = &ctx, .visit = fileVisit });
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqualStrings("raw-debug-print|src/main.zig", violations.items[0].identity.?);
}

// spec: Canonical Idiom - Freezes a baselined file by rule and keeps a new file failing

test "a frozen baseline row suppresses its own file while a new file still fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const site =
        \\const cut = std.mem.lastIndexOfScalar(u8, ref, '/') orelse 0;
    ;
    const frozen = try analyzeFile(a, "src/serve/routes.zig", site, null, &test_rules);
    const fresh = try analyzeFile(a, "src/serve/api.zig", site, null, &test_rules);
    // keyedViolations is the production keying path the gate itself runs, so a
    // green result here cannot come from a test-only spelling of the key.
    const current = try baseline.keyedViolations(a, check_name, "", try std.mem.concat(
        a,
        reporter.Violation,
        &.{ frozen, fresh },
    ));
    const stored = [_][]const u8{"canonical-idiom|subblock-leaf-split|src/serve/routes.zig"};
    const split = try baseline.splitAgainst(a, &stored, current);
    // The recorded file is grandfathered debt; the unrecorded one fails.
    try testing.expectEqual(@as(usize, 1), split.live.len);
    try testing.expectEqual(@as(usize, 0), split.removed.len);
    try testing.expectEqual(@as(usize, 1), split.added.len);
    try testing.expectEqualStrings("canonical-idiom|subblock-leaf-split|src/serve/api.zig", split.added[0].key);

    // And the frozen row survives its site MOVING down the file: the key
    // carries neither the line nor the count, which is why an unrelated edit
    // above a hand-rolled idiom never churns a consumer's ledger.
    const moved = try analyzeFile(a, "src/serve/routes.zig",
        \\const unrelated = 1;
        \\const also_unrelated = 2;
        \\const cut = std.mem.lastIndexOfScalar(u8, ref, '/') orelse 0;
        \\const twin = std.mem.lastIndexOfScalar(u8, other, '/') orelse 0;
    , null, &test_rules);
    const rekeyed = try baseline.keyedViolations(a, check_name, "", moved);
    try testing.expectEqual(@as(u32, 3), moved[0].line.?);
    try testing.expectEqual(@as(u64, 2), moved[0].metric.?);
    try testing.expectEqualStrings(stored[0], rekeyed[0].key);
}
