//! guardian.toml parser. Config types live in config.zig; this module reads a
//! guardian.toml file (or string) into a Config, preserving defaults for any
//! field not set and silently ignoring unknown sections / malformed values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const Config = config.Config;
const BoundaryRule = config.BoundaryRule;

/// Reads guardian.toml from `dir` and returns parsed config; defaults if the
/// file is missing, unreadable, or fails to parse.
pub fn load(allocator: Allocator, dir: []const u8) Config {
    return loadInner(allocator, dir) catch .{};
}

fn loadInner(allocator: Allocator, dir: []const u8) !Config {
    const path = try std.fmt.allocPrint(allocator, "{s}/guardian.toml", .{dir});
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return parse(allocator, content);
}

const Section = enum {
    top,
    spec_quality,
    function_size,
    complexity,
    anytype_budget,
    orphan_files,
    doc_quality,
    type_size,
    function_length,
    nesting_depth,
    test_coverage,
    bool_ops,
    returns_per_fn,
    line_length,
    baseline,
    unknown,
};

/// A trimmed `key = value` pair from a config line (value already stripped of
/// any trailing inline comment).
const KeyVal = struct {
    key: []const u8,
    val: []const u8,
};

/// Everything the per-section appliers need: the arena and the config to fill.
const ApplyCtx = struct {
    allocator: Allocator,
    cfg: *Config,
};

/// Mutable state carried across lines while parsing: the current [section] and
/// the in-progress [[boundary]] table.
const ParseState = struct {
    section: Section = .top,
    in_boundary: bool = false,
    cur_module: ?[]const u8 = null,
    cur_forbidden: std.ArrayListUnmanaged([]const u8) = .empty,
    boundaries: std.ArrayListUnmanaged(BoundaryRule) = .empty,

    /// Flushes the in-progress [[boundary]] (if any, and if it named a module)
    /// into the accumulated boundary rules.
    fn flush(self: *ParseState, allocator: Allocator) Allocator.Error!void {
        if (!self.in_boundary) return;
        const m = self.cur_module orelse return;
        try self.boundaries.append(allocator, .{
            .module_pattern = m,
            .forbidden_imports = try self.cur_forbidden.toOwnedSlice(allocator),
        });
    }

    /// Starts a `[[name]]` array-of-tables entry, flushing any prior boundary.
    fn beginArrayTable(self: *ParseState, allocator: Allocator, name: []const u8) Allocator.Error!void {
        try self.flush(allocator);
        self.in_boundary = std.mem.eql(u8, name, "boundary");
        self.cur_module = null;
        self.cur_forbidden = .empty;
        self.section = .top;
    }

    /// Starts a `[name]` table, flushing any prior boundary.
    fn beginTable(self: *ParseState, allocator: Allocator, name: []const u8) Allocator.Error!void {
        try self.flush(allocator);
        self.in_boundary = false;
        self.section = sectionFor(name);
    }

    /// Applies a key/value inside an open [[boundary]] table.
    fn setBoundaryKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "module")) {
            self.cur_module = parseString(kv.val);
        } else if (std.mem.eql(u8, kv.key, "forbidden")) {
            self.cur_forbidden = try parseStringArray(allocator, kv.val);
        }
    }
};

/// Parses guardian.toml content. Unknown sections and malformed values are
/// silently ignored; defaults are preserved for any field not set. Errors
/// only on allocator failure; `load` swallows those into defaults.
pub fn parse(allocator: Allocator, content: []const u8) Allocator.Error!Config {
    var cfg = Config{};
    var st: ParseState = .{};
    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        try parseLine(allocator, &cfg, &st, line);
    }
    try st.flush(allocator);
    cfg.boundary_rules = try st.boundaries.toOwnedSlice(allocator);
    return cfg;
}

fn parseLine(allocator: Allocator, cfg: *Config, st: *ParseState, line: []const u8) Allocator.Error!void {
    if (arrayTableName(line)) |name| return st.beginArrayTable(allocator, name);
    if (tableName(line)) |name| return st.beginTable(allocator, name);
    try applyKeyValueLine(allocator, cfg, st, line);
}

/// Returns the inner name of a `[[name]]` array-of-tables header, or null.
fn arrayTableName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "[[") or !std.mem.endsWith(u8, line, "]]")) return null;
    return line[2 .. line.len - 2];
}

/// Returns the inner name of a `[name]` table header, or null.
fn tableName(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return null;
    return line[1 .. line.len - 1];
}

fn applyKeyValueLine(allocator: Allocator, cfg: *Config, st: *ParseState, line: []const u8) Allocator.Error!void {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq_idx], &std.ascii.whitespace);
    const raw = std.mem.trim(u8, line[eq_idx + 1 ..], &std.ascii.whitespace);
    const kv: KeyVal = .{ .key = key, .val = stripInlineComment(raw) };
    if (st.in_boundary) return st.setBoundaryKey(allocator, kv);
    try applySectionKey(.{ .allocator = allocator, .cfg = cfg }, st.section, kv);
}

fn applySectionKey(ctx: ApplyCtx, section: Section, kv: KeyVal) Allocator.Error!void {
    switch (section) {
        .top => try applyTopLevelKey(ctx, kv),
        .spec_quality => try applyArrayCfg("spec_quality", "forbidden_phrases", ctx, kv),
        .orphan_files => try applyArrayCfg("orphan_files", "roots", ctx, kv),
        .test_coverage => try applyArrayCfg("test_coverage", "exempt_names", ctx, kv),
        .function_size => applyU32Cfg("function_size", "max_params", ctx, kv),
        .complexity => applyU32Cfg("complexity", "max_score", ctx, kv),
        .doc_quality => applyU32Cfg("doc_quality", "min_chars", ctx, kv),
        .function_length => applyU32Cfg("function_length", "max_lines", ctx, kv),
        .nesting_depth => applyU32Cfg("nesting_depth", "max_depth", ctx, kv),
        .bool_ops => applyU32Cfg("bool_ops", "max_ops", ctx, kv),
        .returns_per_fn => applyU32Cfg("returns_per_fn", "max_returns", ctx, kv),
        .line_length => applyU32Cfg("line_length", "max_len", ctx, kv),
        .anytype_budget => try applyAnytypeBudgetKey(ctx, kv),
        .type_size => try applyTypeSizeKey(ctx, kv),
        .baseline => applyBaselineKey(ctx, kv),
        .unknown => {},
    }
}

/// Maps a `[name]` table header to its Section (unknown when unrecognized).
fn sectionFor(name: []const u8) Section {
    const map = .{
        .{ "spec_quality", Section.spec_quality },
        .{ "function_size", Section.function_size },
        .{ "complexity", Section.complexity },
        .{ "anytype_budget", Section.anytype_budget },
        .{ "orphan_files", Section.orphan_files },
        .{ "doc_quality", Section.doc_quality },
        .{ "type_size", Section.type_size },
        .{ "function_length", Section.function_length },
        .{ "nesting_depth", Section.nesting_depth },
        .{ "test_coverage", Section.test_coverage },
        .{ "bool_ops", Section.bool_ops },
        .{ "returns_per_fn", Section.returns_per_fn },
        .{ "line_length", Section.line_length },
        .{ "baseline", Section.baseline },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return .unknown;
}

/// Parses a base-10 u32, falling back to `default` on malformed input.
fn parseU32(val: []const u8, default: u32) u32 {
    return std.fmt.parseInt(u32, val, 10) catch default;
}

/// Parses a `["a", "b"]` array into an owned slice of strings.
fn toStrings(allocator: Allocator, val: []const u8) Allocator.Error![]const []const u8 {
    var list = try parseStringArray(allocator, val);
    return list.toOwnedSlice(allocator);
}

/// Applies `enabled` + a single u32 cap (`cap_key`) to `cfg.<group>` — the
/// shape shared by every numeric-limit section.
fn applyU32Cfg(comptime group: []const u8, comptime cap_key: []const u8, ctx: ApplyCtx, kv: KeyVal) void {
    const g = &@field(ctx.cfg, group);
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, cap_key)) {
        @field(g, cap_key) = parseU32(kv.val, @field(g, cap_key));
    }
}

/// Applies `enabled` + a single string-array field (`arr_key`) to `cfg.<group>`.
fn applyArrayCfg(
    comptime group: []const u8,
    comptime arr_key: []const u8,
    ctx: ApplyCtx,
    kv: KeyVal,
) Allocator.Error!void {
    const g = &@field(ctx.cfg, group);
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, arr_key)) {
        @field(g, arr_key) = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyTopLevelKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const cfg = ctx.cfg;
    if (std.mem.eql(u8, kv.key, "spec_file")) {
        if (parseString(kv.val)) |v| cfg.spec_file = v;
    } else if (std.mem.eql(u8, kv.key, "max_file_lines")) {
        cfg.max_file_lines = parseU32(kv.val, cfg.max_file_lines);
    } else if (std.mem.eql(u8, kv.key, "cache_enabled")) {
        cfg.cache_enabled = parseBool(kv.val) orelse cfg.cache_enabled;
    } else if (std.mem.eql(u8, kv.key, "file_size_exclude")) {
        cfg.file_size_exclude = try toStrings(ctx.allocator, kv.val);
    } else if (std.mem.eql(u8, kv.key, "disabled")) {
        cfg.disabled = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyAnytypeBudgetKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.anytype_budget;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, "max_per_file")) {
        g.max_per_file = parseU32(kv.val, g.max_per_file);
    } else if (std.mem.eql(u8, kv.key, "exclude")) {
        g.exclude = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyTypeSizeKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.type_size;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, "max_fields")) {
        g.max_fields = parseU32(kv.val, g.max_fields);
    } else if (std.mem.eql(u8, kv.key, "exclude")) {
        g.exclude = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyBaselineKey(ctx: ApplyCtx, kv: KeyVal) void {
    if (std.mem.eql(u8, kv.key, "enabled")) {
        ctx.cfg.baseline.enabled = parseBool(kv.val) orelse ctx.cfg.baseline.enabled;
    }
}

fn parseBool(val: []const u8) ?bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return null;
}

fn parseString(val: []const u8) ?[]const u8 {
    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
        return val[1 .. val.len - 1];
    }
    return null;
}

fn parseStringArray(allocator: Allocator, val: []const u8) Allocator.Error!std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (val.len < 2 or val[0] != '[' or val[val.len - 1] != ']') return list;
    const inner = val[1 .. val.len - 1];
    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, &std.ascii.whitespace);
        if (parseString(trimmed)) |s| {
            try list.append(allocator, s);
        }
    }
    return list;
}

/// Removes a trailing `# comment` from a TOML value, ignoring `#` inside a
/// double-quoted string. Returns the value with trailing whitespace trimmed.
fn stripInlineComment(val: []const u8) []const u8 {
    var in_str = false;
    var i: usize = 0;
    while (i < val.len) : (i += 1) {
        switch (val[i]) {
            '"' => in_str = !in_str,
            '#' => if (!in_str) return std.mem.trimRight(u8, val[0..i], &std.ascii.whitespace),
            else => {},
        }
    }
    return val;
}

// spec: Configuration - Falls back to defaults when no config file exists
// spec: Configuration - Loads guardian.toml from target directory
// spec: Configuration - Supports boundary rules via [[boundary]] sections
// spec: Configuration - Parses a top-level disabled list of check names

test "parse default config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), "");
    try std.testing.expectEqualStrings("SPEC.md", cfg.spec_file);
    try std.testing.expectEqual(@as(u32, 500), cfg.max_file_lines);
}

test "parse config with values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\spec_file = "SPEC.md"
        \\max_file_lines = 300
        \\
        \\[[boundary]]
        \\module = "src/stages/*"
        \\forbidden = ["shell"]
    ;
    const cfg = try parse(arena.allocator(), content);

    try std.testing.expectEqual(@as(u32, 300), cfg.max_file_lines);
    try std.testing.expectEqual(@as(usize, 1), cfg.boundary_rules.len);
    try std.testing.expectEqualStrings("src/stages/*", cfg.boundary_rules[0].module_pattern);
    try std.testing.expectEqual(@as(usize, 1), cfg.boundary_rules[0].forbidden_imports.len);
    try std.testing.expectEqualStrings("shell", cfg.boundary_rules[0].forbidden_imports[0]);
}

test "parse ignores comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\# This is a comment
        \\
        \\max_file_lines = 200
        \\# Another comment
        \\spec_file = "MY_SPEC.md"
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(u32, 200), cfg.max_file_lines);
    try std.testing.expectEqualStrings("MY_SPEC.md", cfg.spec_file);
}

test "parse malformed values fall back to defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\max_file_lines = not_a_number
        \\spec_file = unquoted
    ;
    const cfg = try parse(arena.allocator(), content);
    // All should fall back to defaults
    try std.testing.expectEqual(@as(u32, 500), cfg.max_file_lines);
    try std.testing.expectEqualStrings("SPEC.md", cfg.spec_file);
}

test "parse multiple boundary rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[[boundary]]
        \\module = "src/a/*"
        \\forbidden = ["x", "y"]
        \\
        \\[[boundary]]
        \\module = "src/b/*"
        \\forbidden = ["z"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(usize, 2), cfg.boundary_rules.len);
    try std.testing.expectEqualStrings("src/a/*", cfg.boundary_rules[0].module_pattern);
    try std.testing.expectEqual(@as(usize, 2), cfg.boundary_rules[0].forbidden_imports.len);
    try std.testing.expectEqualStrings("src/b/*", cfg.boundary_rules[1].module_pattern);
    try std.testing.expectEqual(@as(usize, 1), cfg.boundary_rules[1].forbidden_imports.len);
}

test "parse empty array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\file_size_exclude = []
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(usize, 0), cfg.file_size_exclude.len);
}

test "parse strips inline comments from values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\max_file_lines = 300 # keep files small
        \\spec_file = "docs/SPEC.md"  # not the root
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(u32, 300), cfg.max_file_lines);
    try std.testing.expectEqualStrings("docs/SPEC.md", cfg.spec_file);
}

test "parse disabled check list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\disabled = ["spec-drift", "magic-number"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(usize, 2), cfg.disabled.len);
    try std.testing.expectEqualStrings("spec-drift", cfg.disabled[0]);
    try std.testing.expectEqualStrings("magic-number", cfg.disabled[1]);
}

test "parse per-check exclude arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[type_size]
        \\exclude = ["config.zig"]
        \\
        \\[anytype_budget]
        \\exclude = ["reporter.zig", "testing/golden_runner.zig"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(usize, 1), cfg.type_size.exclude.len);
    try std.testing.expectEqualStrings("config.zig", cfg.type_size.exclude[0]);
    try std.testing.expectEqual(@as(usize, 2), cfg.anytype_budget.exclude.len);
    try std.testing.expectEqualStrings("testing/golden_runner.zig", cfg.anytype_budget.exclude[1]);
}

test "parse named section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[spec_quality]
        \\enabled = false
        \\forbidden_phrases = ["properly", "handle"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(false, cfg.spec_quality.enabled);
    try std.testing.expectEqual(@as(usize, 2), cfg.spec_quality.forbidden_phrases.len);
    try std.testing.expectEqualStrings("properly", cfg.spec_quality.forbidden_phrases[0]);
}

test "parse unknown section silently ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\spec_file = "S.md"
        \\
        \\[future_check]
        \\some_key = "future_value"
        \\
        \\max_file_lines = 100
    ;
    const cfg = try parse(arena.allocator(), content);
    // top-level keys before the unknown section still apply
    try std.testing.expectEqualStrings("S.md", cfg.spec_file);
    // max_file_lines comes after [future_check]; section stays .unknown so it
    // does not apply — accept the default.
    try std.testing.expectEqual(@as(u32, 500), cfg.max_file_lines);
}

test "parse named section then boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[spec_quality]
        \\enabled = true
        \\
        \\[[boundary]]
        \\module = "src/x/*"
        \\forbidden = ["y"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(true, cfg.spec_quality.enabled);
    try std.testing.expectEqual(@as(usize, 1), cfg.boundary_rules.len);
    try std.testing.expectEqualStrings("src/x/*", cfg.boundary_rules[0].module_pattern);
}

test "load falls back to defaults when guardian.toml is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = load(arena.allocator(), "definitely/not/a/real/dir");
    try std.testing.expectEqualStrings("SPEC.md", cfg.spec_file);
    try std.testing.expectEqual(@as(u32, 500), cfg.max_file_lines);
}
