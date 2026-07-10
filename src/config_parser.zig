//! guardian.toml parser (types live in config.zig). Preserves defaults for
//! unset fields. Fails closed: a missing file is the zero-config default, but a
//! file that exists yet can't be read, or that names an unknown section header
//! or an unknown key inside a known section, is a hard error with a file:line
//! diagnostic — a gate whose own config silently misparses can't be trusted at
//! exactly the moment it's misconfigured. Malformed scalar *values* (a
//! non-integer where a u32 is expected) still fall back to their default: that
//! is the parser's deliberate lenient scope, not an unknown-input violation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const reporter = @import("reporter.zig");
const Config = config.Config;
const BoundaryRule = config.BoundaryRule;
const AllowRule = config.AllowRule;

/// A parse failure's location and message (arena-owned), filled by `parseInto`
/// on an unknown section or key so `load` can render a `path:line: message`.
pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

/// Errors `parse`/`parseInto` may raise: OOM, or an unknown section/key.
pub const ParseError = Allocator.Error || error{ UnknownSection, UnknownKey };

/// Errors `load` may raise on a present-but-broken config: the parse errors
/// plus a read failure (any I/O error other than a missing file).
pub const LoadError = ParseError || error{ConfigUnreadable};

/// The `exempt_names` key, shared by [doc_quality] and [test_coverage]; a named
/// const so the literal isn't repeated across the valid-key lists and appliers.
const exempt_names_key = "exempt_names";

/// Reads guardian.toml from `dir`. A missing file is the zero-config default; a
/// present file that can't be read or parsed is a hard failure with a printed
/// `guardian.toml:line: …` diagnostic, so a typo can't silently drop config.
pub fn load(allocator: Allocator, dir: []const u8) LoadError!Config {
    const path = try std.fmt.allocPrint(allocator, "{s}/guardian.toml", .{dir});
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return .{}, // zero-config: absent is fine
        else => {
            // reporter.fail already prefixes "guardian: " — don't double it.
            reporter.fail("cannot read {s}: {s}", .{ path, @errorName(e) });
            return error.ConfigUnreadable;
        },
    };
    var diag: Diagnostic = .{};
    return parseInto(allocator, content, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownSection, error.UnknownKey => {
            reporter.fail("{s}:{d}: {s}", .{ path, diag.line, diag.message });
            return e;
        },
    };
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
    line_length,
    baseline,
    escape_discipline,
    oom_discipline,
    magic_number,
    dead_pub,
    change_classification,
    mutation,
    completeness,
    dora,
    unknown,
};

/// A trimmed `key = value` pair (value stripped of any inline comment).
const KeyVal = struct {
    key: []const u8,
    val: []const u8,
};

/// Everything the per-section appliers need: the arena and the config to fill.
const ApplyCtx = struct {
    allocator: Allocator,
    cfg: *Config,
};

/// Which `[[array]]` table (if any) the parser is currently inside.
const ArrayKind = enum { none, boundary, allow };

/// Parse state across lines: the current [section] and in-progress array table.
const ParseState = struct {
    section: Section = .top,
    array_kind: ArrayKind = .none,
    cur_module: ?[]const u8 = null,
    cur_forbidden: std.ArrayListUnmanaged([]const u8) = .empty,
    boundaries: std.ArrayListUnmanaged(BoundaryRule) = .empty,
    cur_check: ?[]const u8 = null,
    cur_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    allows: std.ArrayListUnmanaged(AllowRule) = .empty,

    /// Flushes the in-progress array-of-tables entry (if complete) into its list.
    fn flush(self: *ParseState, allocator: Allocator) Allocator.Error!void {
        switch (self.array_kind) {
            .boundary => {
                const m = self.cur_module orelse return;
                try self.boundaries.append(allocator, .{
                    .module_pattern = m,
                    .forbidden_imports = try self.cur_forbidden.toOwnedSlice(allocator),
                });
            },
            .allow => {
                const c = self.cur_check orelse return;
                try self.allows.append(allocator, .{
                    .check = c,
                    .paths = try self.cur_paths.toOwnedSlice(allocator),
                });
            },
            .none => {},
        }
    }

    /// Starts a `[[name]]` array-of-tables entry, flushing any prior one.
    fn beginArrayTable(self: *ParseState, allocator: Allocator, name: []const u8) Allocator.Error!void {
        try self.flush(allocator);
        self.array_kind = arrayKindFor(name);
        self.cur_module = null;
        self.cur_forbidden = .empty;
        self.cur_check = null;
        self.cur_paths = .empty;
        self.section = .top;
    }

    /// Starts a `[name]` table, flushing any prior array entry.
    fn beginTable(self: *ParseState, allocator: Allocator, name: []const u8) Allocator.Error!void {
        try self.flush(allocator);
        self.array_kind = .none;
        self.section = sectionFor(name);
    }

    /// Applies a key/value inside an open array-of-tables entry.
    fn setArrayKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        switch (self.array_kind) {
            .boundary => try self.setBoundaryKey(allocator, kv),
            .allow => try self.setAllowKey(allocator, kv),
            .none => {},
        }
    }

    fn setBoundaryKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "module")) {
            self.cur_module = parseString(kv.val);
        } else if (std.mem.eql(u8, kv.key, "forbidden")) {
            self.cur_forbidden = try parseStringArray(allocator, kv.val);
        }
    }

    fn setAllowKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "check")) {
            self.cur_check = parseString(kv.val);
        } else if (std.mem.eql(u8, kv.key, "paths")) {
            self.cur_paths = try parseStringArray(allocator, kv.val);
        }
    }
};

/// Maps a `[[name]]` header to the array kind it opens.
fn arrayKindFor(name: []const u8) ArrayKind {
    if (std.mem.eql(u8, name, "boundary")) return .boundary;
    if (std.mem.eql(u8, name, "allow")) return .allow;
    return .none;
}

/// Parses guardian.toml content into a Config. Discards the diagnostic; use
/// `parseInto` when the offending line/message is needed (see `load`).
pub fn parse(allocator: Allocator, content: []const u8) ParseError!Config {
    var diag: Diagnostic = .{};
    return parseInto(allocator, content, &diag);
}

/// Parses guardian.toml content, filling `diag` on an unknown section or key.
/// Unknown section headers and unknown keys inside a known section are hard
/// errors; malformed scalar values still fall back to their default.
pub fn parseInto(allocator: Allocator, content: []const u8, diag: *Diagnostic) ParseError!Config {
    var cfg = Config{};
    var st: ParseState = .{};
    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (lines_iter.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        try parseLine(allocator, &cfg, &st, line, line_no, diag);
    }
    try st.flush(allocator);
    cfg.boundary_rules = try st.boundaries.toOwnedSlice(allocator);
    cfg.allow_rules = try st.allows.toOwnedSlice(allocator);
    return cfg;
}

/// Records the offending `line_no` and a formatted message into `diag`.
fn setDiag(
    allocator: Allocator,
    diag: *Diagnostic,
    line_no: u32,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    diag.* = .{ .line = line_no, .message = try std.fmt.allocPrint(allocator, fmt, args) };
}

fn parseLine(
    allocator: Allocator,
    cfg: *Config,
    st: *ParseState,
    line: []const u8,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (arrayTableName(line)) |name| {
        if (arrayKindFor(name) == .none) return unknownName(allocator, diag, line_no, "section", name, &.{});
        return st.beginArrayTable(allocator, name);
    }
    if (tableName(line)) |name| {
        if (sectionFor(name) == .unknown) return unknownName(allocator, diag, line_no, "section", name, &.{});
        return st.beginTable(allocator, name);
    }
    try applyKeyValueLine(allocator, cfg, st, line, line_no, diag);
}

/// Fills `diag` for an unknown `kind` ("section"/"key") named `name`, appending
/// a cheap "did you mean 'x'?" when `candidates` holds a close prefix match, and
/// returns the matching error so the caller can `return` it.
fn unknownName(
    allocator: Allocator,
    diag: *Diagnostic,
    line_no: u32,
    comptime kind: []const u8,
    name: []const u8,
    candidates: []const []const u8,
) ParseError!void {
    if (bestMatch(name, candidates)) |sug| {
        try setDiag(allocator, diag, line_no, "unknown " ++ kind ++ " '{s}' (did you mean '{s}'?)", .{ name, sug });
    } else {
        try setDiag(allocator, diag, line_no, "unknown " ++ kind ++ " '{s}'", .{name});
    }
    return if (std.mem.eql(u8, kind, "section")) error.UnknownSection else error.UnknownKey;
}

/// The candidate name in `candidates` sharing the longest prefix (>= 3 chars)
/// with `offender`, for a cheap did-you-mean, or null when none is close.
fn bestMatch(offender: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    for (candidates) |c| {
        const p = commonPrefixLen(offender, c);
        if (p > best_len) {
            best_len = p;
            best = c;
        }
    }
    return if (best_len >= 3) best else null;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
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

fn applyKeyValueLine(
    allocator: Allocator,
    cfg: *Config,
    st: *ParseState,
    line: []const u8,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return;
    const key = std.mem.trim(u8, line[0..eq_idx], &std.ascii.whitespace);
    const raw = std.mem.trim(u8, line[eq_idx + 1 ..], &std.ascii.whitespace);
    const kv: KeyVal = .{ .key = key, .val = stripInlineComment(raw) };
    // A key the current section doesn't recognize is a typo, not a value to
    // silently drop — name it (with a cheap suggestion) and fail.
    const valid = if (st.array_kind != .none) validArrayKeys(st.array_kind) else validSectionKeys(st.section);
    if (!inList(valid, key)) return unknownName(allocator, diag, line_no, "key", key, valid);
    if (st.array_kind != .none) return st.setArrayKey(allocator, kv);
    try applySectionKey(.{ .allocator = allocator, .cfg = cfg }, st.section, kv);
}

/// True when `name` appears in `list`.
fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The `enabled` toggle plus the extra keys `section` accepts (mirrors the
/// appliers in `applySectionKey`). A key outside this set is an unknown-key
/// error. Keep in sync when an applier gains a key.
fn validSectionKeys(section: Section) []const []const u8 {
    return switch (section) {
        .top => &.{
            "spec_file",         "max_file_lines", "cache_enabled", "parallel",
            "file_size_exclude", "exclude",        "disabled",
        },
        .spec_quality => &.{ "enabled", "forbidden_phrases" },
        .function_size => &.{ "enabled", "max_params" },
        .complexity => &.{ "enabled", "max_score" },
        .anytype_budget => &.{ "enabled", "max_per_file", "exclude" },
        .orphan_files => &.{ "enabled", "roots" },
        .doc_quality => &.{ "enabled", "min_chars", exempt_names_key },
        .type_size => &.{ "enabled", "max_fields", "exclude" },
        .function_length => &.{ "enabled", "max_lines" },
        .nesting_depth => &.{ "enabled", "max_depth" },
        .test_coverage => &.{ "enabled", exempt_names_key },
        .bool_ops => &.{ "enabled", "max_ops" },
        .line_length => &.{ "enabled", "max_len" },
        .baseline => &.{ "enabled", "deny_growth" },
        .escape_discipline, .oom_discipline, .magic_number => &.{"enabled"},
        .dead_pub => &.{"ignore_test_refs"},
        .change_classification => &.{ "enabled", "against", "gate_last_commit" },
        .mutation => &.{ "min_score_pct", "min_mutants", "max_mutants", "timeout_secs" },
        .completeness => &.{ "enabled", "exempt_sections" },
        .dora => &.{ "enabled", "sink_path" },
        .unknown => &.{},
    };
}

/// Keys accepted inside a `[[boundary]]` / `[[allow]]` array-of-tables entry.
fn validArrayKeys(kind: ArrayKind) []const []const u8 {
    return switch (kind) {
        .boundary => &.{ "module", "forbidden" },
        .allow => &.{ "check", "paths" },
        .none => &.{},
    };
}

fn applySectionKey(ctx: ApplyCtx, section: Section, kv: KeyVal) Allocator.Error!void {
    switch (section) {
        .top => try applyTopLevelKey(ctx, kv),
        .spec_quality => try applyArrayCfg("spec_quality", "forbidden_phrases", ctx, kv),
        .orphan_files => try applyArrayCfg("orphan_files", "roots", ctx, kv),
        .test_coverage => try applyArrayCfg("test_coverage", exempt_names_key, ctx, kv),
        .function_size => applyU32Cfg("function_size", "max_params", ctx, kv),
        .complexity => applyU32Cfg("complexity", "max_score", ctx, kv),
        .doc_quality => try applyDocQualityKey(ctx, kv),
        .function_length => applyU32Cfg("function_length", "max_lines", ctx, kv),
        .nesting_depth => applyU32Cfg("nesting_depth", "max_depth", ctx, kv),
        .bool_ops => applyU32Cfg("bool_ops", "max_ops", ctx, kv),
        .line_length => applyU32Cfg("line_length", "max_len", ctx, kv),
        .anytype_budget => try applyAnytypeBudgetKey(ctx, kv),
        .type_size => try applyTypeSizeKey(ctx, kv),
        .baseline => try applyBaselineKey(ctx, kv),
        .escape_discipline => applyEnabledCfg("escape_discipline", ctx, kv),
        .oom_discipline => applyEnabledCfg("oom_discipline", ctx, kv),
        .magic_number => applyEnabledCfg("magic_number", ctx, kv),
        .dead_pub => applyBoolCfg("dead_pub", "ignore_test_refs", ctx, kv),
        .change_classification => applyChangeClassificationKey(ctx, kv),
        .mutation => applyMutationKey(ctx, kv),
        .completeness => try applyCompletenessKey(ctx, kv),
        .dora => applyDoraKey(ctx, kv),
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
        .{ "line_length", Section.line_length },
        .{ "baseline", Section.baseline },
        .{ "escape_discipline", Section.escape_discipline },
        .{ "oom_discipline", Section.oom_discipline },
        .{ "magic_number", Section.magic_number },
        .{ "dead_pub", Section.dead_pub },
        .{ "change_classification", Section.change_classification },
        .{ "mutation", Section.mutation },
        .{ "completeness", Section.completeness },
        .{ "dora", Section.dora },
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

/// Applies `enabled` + a single u32 cap (`cap_key`) to `cfg.<group>`.
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
    } else if (std.mem.eql(u8, kv.key, "parallel")) {
        cfg.parallel = parseBool(kv.val) orelse cfg.parallel;
    } else if (std.mem.eql(u8, kv.key, "file_size_exclude")) {
        cfg.file_size_exclude = try toStrings(ctx.allocator, kv.val);
    } else if (std.mem.eql(u8, kv.key, "exclude")) {
        cfg.exclude = try toStrings(ctx.allocator, kv.val);
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

fn applyDocQualityKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.doc_quality;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, "min_chars")) {
        g.min_chars = parseU32(kv.val, g.min_chars);
    } else if (std.mem.eql(u8, kv.key, exempt_names_key)) {
        g.exempt_names = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyBaselineKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.baseline;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, "deny_growth")) {
        g.deny_growth = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyChangeClassificationKey(ctx: ApplyCtx, kv: KeyVal) void {
    const g = &ctx.cfg.change_classification;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, "against")) {
        if (parseString(kv.val)) |v| g.against = v;
    } else if (std.mem.eql(u8, kv.key, "gate_last_commit")) {
        g.gate_last_commit = parseBool(kv.val) orelse g.gate_last_commit;
    }
}

fn applyMutationKey(ctx: ApplyCtx, kv: KeyVal) void {
    const g = &ctx.cfg.mutation;
    if (std.mem.eql(u8, kv.key, "min_score_pct")) {
        g.min_score_pct = parseU32(kv.val, g.min_score_pct);
    } else if (std.mem.eql(u8, kv.key, "min_mutants")) {
        g.min_mutants = parseU32(kv.val, g.min_mutants);
    } else if (std.mem.eql(u8, kv.key, "max_mutants")) {
        g.max_mutants = parseU32(kv.val, g.max_mutants);
    } else if (std.mem.eql(u8, kv.key, "timeout_secs")) {
        g.timeout_secs = parseU32(kv.val, g.timeout_secs);
    }
}

fn applyCompletenessKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.completeness;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, "exempt_sections")) {
        g.exempt_sections = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyDoraKey(ctx: ApplyCtx, kv: KeyVal) void {
    const g = &ctx.cfg.dora;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, "sink_path")) {
        if (parseString(kv.val)) |v| g.sink_path = v;
    }
}

/// Applies an `enabled` toggle to an enabled-only cfg group.
fn applyEnabledCfg(comptime group: []const u8, ctx: ApplyCtx, kv: KeyVal) void {
    const g = &@field(ctx.cfg, group);
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    }
}

/// Applies a single named bool key to `cfg.<group>`.
fn applyBoolCfg(comptime group: []const u8, comptime key: []const u8, ctx: ApplyCtx, kv: KeyVal) void {
    const g = &@field(ctx.cfg, group);
    if (std.mem.eql(u8, kv.key, key)) @field(g, key) = parseBool(kv.val) orelse @field(g, key);
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

/// Removes a trailing `# comment` (ignoring `#` inside a quoted string).
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
    try std.testing.expectEqual(@as(u32, 1000), cfg.max_file_lines);
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
    try std.testing.expectEqual(@as(u32, 1000), cfg.max_file_lines);
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

// spec: Configuration - Parses the mutation section score and budget settings

test "parse reads [mutation] score minimum and run budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[mutation]
        \\min_score_pct = 90
        \\min_mutants = 6
        \\max_mutants = 25
        \\timeout_secs = 60
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(u32, 90), cfg.mutation.min_score_pct);
    try std.testing.expectEqual(@as(u32, 6), cfg.mutation.min_mutants);
    try std.testing.expectEqual(@as(u32, 25), cfg.mutation.max_mutants);
    try std.testing.expectEqual(@as(u32, 60), cfg.mutation.timeout_secs);
}

// spec: Configuration - Parses the change classification toggle and against ref

test "parse reads [change_classification] enabled and against" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[change_classification]
        \\enabled = false
        \\against = "origin/main"
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expect(!cfg.change_classification.enabled);
    try std.testing.expectEqualStrings("origin/main", cfg.change_classification.against);
    // Defaults: enabled, diffing against HEAD.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expect(defaults.change_classification.enabled);
    try std.testing.expectEqualStrings("HEAD", defaults.change_classification.against);
}

// spec: Configuration - Defaults completeness off and parses its enabled and exempt_sections settings

test "parse [completeness] defaults off and reads enabled + exempt_sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: opt-in, so off, with no exemptions.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expect(!defaults.completeness.enabled);
    try std.testing.expectEqual(@as(usize, 0), defaults.completeness.exempt_sections.len);
    // Opt in and exempt a non-feature section.
    const cfg = try parse(arena.allocator(),
        \\[completeness]
        \\enabled = true
        \\exempt_sections = ["Overview", "Changelog"]
    );
    try std.testing.expect(cfg.completeness.enabled);
    try std.testing.expectEqual(@as(usize, 2), cfg.completeness.exempt_sections.len);
    try std.testing.expectEqualStrings("Overview", cfg.completeness.exempt_sections[0]);
}

// spec: Configuration - Parses the dora sink path and enabled toggle

test "parse [dora] defaults on and reads enabled + sink_path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: enabled, sink under the git-ignored cache dir.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expect(defaults.dora.enabled);
    try std.testing.expectEqualStrings(".guardian/cache/dora.jsonl", defaults.dora.sink_path);
    // Override both.
    const cfg = try parse(arena.allocator(),
        \\[dora]
        \\enabled = false
        \\sink_path = "metrics/runs.jsonl"
    );
    try std.testing.expect(!cfg.dora.enabled);
    try std.testing.expectEqualStrings("metrics/runs.jsonl", cfg.dora.sink_path);
}

// spec: Configuration - Parses the change classification last-commit gate toggle

test "parse reads [change_classification] gate_last_commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[change_classification]
        \\gate_last_commit = false
    );
    try std.testing.expect(!cfg.change_classification.gate_last_commit);
    // Default: the last-commit fallback is on.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expect(defaults.change_classification.gate_last_commit);
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

// spec: Configuration - Parses the baseline deny_growth check list

test "parse [baseline] enabled and deny_growth list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[baseline]
        \\enabled = true
        \\deny_growth = ["spec", "doc-comments"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expect(cfg.baseline.enabled);
    try std.testing.expectEqual(@as(usize, 2), cfg.baseline.deny_growth.len);
    try std.testing.expectEqualStrings("spec", cfg.baseline.deny_growth[0]);
    try std.testing.expectEqualStrings("doc-comments", cfg.baseline.deny_growth[1]);
    // Default: empty list.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), defaults.baseline.deny_growth.len);
}

// spec: Configuration - Parses a top-level exclude list of path globs dropped from the scan
test "parse top-level exclude list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\exclude = ["src/serve/templates", "*/generated/*"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(usize, 2), cfg.exclude.len);
    try std.testing.expectEqualStrings("src/serve/templates", cfg.exclude[0]);
    try std.testing.expectEqualStrings("*/generated/*", cfg.exclude[1]);
}

// spec: Configuration - Parses per-check allowed-path overrides via [[allow]] sections
test "parse [[allow]] per-check path overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[[allow]]
        \\check = "ban-fs"
        \\paths = ["src/walk*", "src/cache*"]
        \\
        \\[[allow]]
        \\check = "debug-print-ban"
        \\paths = ["src/reporter.zig"]
    ;
    const cfg = try parse(arena.allocator(), content);
    const fs = cfg.extraAllowed("ban-fs");
    try std.testing.expectEqual(@as(usize, 2), fs.len);
    try std.testing.expectEqualStrings("src/walk*", fs[0]);
    try std.testing.expectEqualStrings("src/reporter.zig", cfg.extraAllowed("debug-print-ban")[0]);
    try std.testing.expectEqual(@as(usize, 0), cfg.extraAllowed("nonexistent").len);
}

// spec: Configuration - Defaults magic-number off and enables it via [magic_number] enabled
test "magic-number defaults off and opts in via config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: off.
    const default_cfg = try parse(arena.allocator(), "");
    try std.testing.expectEqual(false, default_cfg.magic_number.enabled);
    // Opt in via section.
    const opted = try parse(arena.allocator(),
        \\[magic_number]
        \\enabled = true
    );
    try std.testing.expectEqual(true, opted.magic_number.enabled);
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

// spec: Configuration - Hard-fails on an unknown section header naming the offender
test "parse rejects an unknown section header with a located diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content =
        \\spec_file = "S.md"
        \\
        \\[future_check]
        \\some_key = "future_value"
    ;
    // A typo'd section is a loud failure, not a silent drop of its keys.
    try std.testing.expectError(error.UnknownSection, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 3), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "future_check") != null);
}

// spec: Configuration - Hard-fails on an unknown key within a known section
test "parse rejects an unknown key in a known section and names it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content =
        \\[mutation]
        \\min_mutant = 6
    ;
    try std.testing.expectError(error.UnknownKey, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    // The offender is named and a cheap prefix match is suggested.
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "min_mutant") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "did you mean") != null);
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
    const cfg = try load(arena.allocator(), "definitely/not/a/real/dir");
    try std.testing.expectEqualStrings("SPEC.md", cfg.spec_file);
    try std.testing.expectEqual(@as(u32, 1000), cfg.max_file_lines);
}

// spec: Configuration - Hard-fails when the config file exists but cannot be read
test "load hard-fails when guardian.toml exists but cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/config-unreadable-proj";
    std.fs.cwd().deleteTree(dir) catch {};
    // A *directory* named guardian.toml exists but can't be read as a file.
    try std.fs.cwd().makePath(dir ++ "/guardian.toml");
    defer std.fs.cwd().deleteTree(dir) catch |e| std.log.warn("cfg cleanup: {s}", .{@errorName(e)});
    // load prints a diagnostic; capture it so the test log stays clean.
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    try std.testing.expectError(error.ConfigUnreadable, load(a, dir));
    // The diagnostic carries exactly one "guardian: " prefix (reporter adds it).
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "guardian: guardian:") == null);
}
