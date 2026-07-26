//! guardian.toml parser (types live in config.zig). Preserves defaults for
//! unset fields. Fails closed: a missing file is the zero-config default, but a
//! file that exists yet can't be read, or that names an unknown section header
//! or an unknown key inside a known section, is a hard error with a file:line
//! diagnostic — a gate whose own config silently misparses can't be trusted at
//! exactly the moment it's misconfigured. Present-but-malformed values and
//! semantically unsafe settings also fail closed rather than falling back to a
//! default the operator did not ask for.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const reporter = @import("reporter.zig");
const value = @import("config_value.zig");
const semantics = @import("config_semantics.zig");
const config_policy = @import("config_policy.zig");
const Config = config.Config;
const BoundaryRule = config.BoundaryRule;
const AllowRule = config.AllowRule;
const ExternalGate = config.ExternalGate;
const arrayTableName = value.arrayTableName;
const bestMatch = value.bestMatch;
const hasEmptyArrayItem = value.hasEmptyArrayItem;
const isValidString = value.isValidString;
const isValidStringArray = value.isValidStringArray;
const inList = value.inList;
const parseString = value.parseString;
const parseStringArray = value.parseStringArray;
const parseBool = value.parseBool;
const parseU32 = value.parseU32;
const startsMultilineArray = value.startsMultilineArray;
const stripInlineComment = value.stripInlineComment;
const tableName = value.tableName;
const toStrings = value.toStrings;

/// A parse failure's location and message (arena-owned), filled by `parseInto`
/// on an unknown section or key so `load` can render a `path:line: message`.
pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

/// Errors `parse`/`parseInto` may raise. Every non-OOM rejection populates a
/// located diagnostic.
pub const ParseError = Allocator.Error || error{
    UnknownSection,
    UnknownKey,
    MalformedLine,
    InvalidValue,
    IncompleteTable,
    InvalidConfig,
};

/// Errors `load` may raise on a present-but-broken config: the parse errors
/// plus a read failure (any I/O error other than a missing file).
pub const LoadError = ParseError || error{ConfigUnreadable};

/// The `exempt_names` key, shared by [doc_quality] and [test_coverage]; a named
/// const so the literal isn't repeated across the valid-key lists and appliers.
const exempt_names_key = "exempt_names";
const min_score_pct_key = "min_score_pct";
const min_mutants_key = "min_mutants";
const max_mutants_key = "max_mutants";
const fast_max_mutants_key = "fast_max_mutants";
const timeout_floor_secs_key = "timeout_floor_secs";
const timeout_multiplier_key = "timeout_multiplier";
const timeout_retry_multiplier_key = "timeout_retry_multiplier";
const timeout_secs_key = "timeout_secs";
const max_file_lines_key = "max_file_lines";
const hard_max_file_lines_key = "hard_max_file_lines";
const max_lines_key = "max_lines";
const hard_max_lines_key = "hard_max_lines";
const max_len_key = "max_len";
const hard_max_len_key = "hard_max_len";
const required_inputs_key = "required_inputs";
const on_build_key = "on_build";
const lock_enabled_key = config_policy.lock_enabled_key;
const lock_against_key = config_policy.lock_against_key;

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
        error.UnknownSection,
        error.UnknownKey,
        error.MalformedLine,
        error.InvalidValue,
        error.IncompleteTable,
        error.InvalidConfig,
        => {
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
    stdout_flush,
    module_doc_header,
    dead_pub,
    change_classification,
    mutation,
    benchmark,
    completeness,
    dora,
    fuzz_presence,
    int_from_float,
    policy,
    doctor,
    gate,
    unknown,
};

const KeyVal = struct {
    key: []const u8,
    val: []const u8,
};

const ApplyCtx = struct {
    allocator: Allocator,
    cfg: *Config,
};

const ArrayKind = enum { none, boundary, allow, external };

const ParseState = struct {
    section: Section = .top,
    array_kind: ArrayKind = .none,
    cur_module: ?[]const u8 = null,
    cur_forbidden: std.ArrayList([]const u8) = .empty,
    boundaries: std.ArrayList(BoundaryRule) = .empty,
    cur_check: ?[]const u8 = null,
    cur_paths: std.ArrayList([]const u8) = .empty,
    allows: std.ArrayList(AllowRule) = .empty,
    cur_name: ?[]const u8 = null,
    cur_command: std.ArrayList([]const u8) = .empty,
    cur_inputs: std.ArrayList([]const u8) = .empty,
    external_gates: std.ArrayList(ExternalGate) = .empty,
    array_line: u32 = 0,
    mutation_lines: MutationLines = .{},
    threshold_lines: ThresholdLines = .{},
    boundary_forbidden_set: bool = false,
    allow_paths_set: bool = false,
    external_command_set: bool = false,

    fn flush(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        switch (self.array_kind) {
            .boundary => {
                const m = self.cur_module orelse {
                    try setDiag(
                        allocator,
                        diag,
                        self.array_line,
                        "incomplete [[boundary]]: missing required key 'module'",
                        .{},
                    );
                    return error.IncompleteTable;
                };
                if (!self.boundary_forbidden_set) {
                    try setDiag(
                        allocator,
                        diag,
                        self.array_line,
                        "incomplete [[boundary]]: missing required key 'forbidden'",
                        .{},
                    );
                    return error.IncompleteTable;
                }
                try self.boundaries.append(allocator, .{
                    .module_pattern = m,
                    .forbidden_imports = try self.cur_forbidden.toOwnedSlice(allocator),
                });
            },
            .allow => {
                const c = self.cur_check orelse {
                    try setDiag(
                        allocator,
                        diag,
                        self.array_line,
                        "incomplete [[allow]]: missing required key 'check'",
                        .{},
                    );
                    return error.IncompleteTable;
                };
                if (!self.allow_paths_set) {
                    try setDiag(
                        allocator,
                        diag,
                        self.array_line,
                        "incomplete [[allow]]: missing required key 'paths'",
                        .{},
                    );
                    return error.IncompleteTable;
                }
                try self.allows.append(allocator, .{
                    .check = c,
                    .paths = try self.cur_paths.toOwnedSlice(allocator),
                });
            },
            .external => {
                const name = self.cur_name orelse {
                    try setDiag(
                        allocator,
                        diag,
                        self.array_line,
                        "incomplete [[external]]: missing required key 'name'",
                        .{},
                    );
                    return error.IncompleteTable;
                };
                if (!self.external_command_set or self.cur_command.items.len == 0) {
                    try setDiag(
                        allocator,
                        diag,
                        self.array_line,
                        "incomplete [[external]]: 'command' must be a non-empty string array",
                        .{},
                    );
                    return error.IncompleteTable;
                }
                try self.external_gates.append(allocator, .{
                    .name = name,
                    .command = try self.cur_command.toOwnedSlice(allocator),
                    .inputs = try self.cur_inputs.toOwnedSlice(allocator),
                });
            },
            .none => {},
        }
    }

    fn beginArrayTable(
        self: *ParseState,
        allocator: Allocator,
        name: []const u8,
        line_no: u32,
        diag: *Diagnostic,
    ) ParseError!void {
        try self.flush(allocator, diag);
        self.array_kind = arrayKindFor(name);
        self.cur_module = null;
        self.cur_forbidden = .empty;
        self.cur_check = null;
        self.cur_paths = .empty;
        self.cur_name = null;
        self.cur_command = .empty;
        self.cur_inputs = .empty;
        self.boundary_forbidden_set = false;
        self.allow_paths_set = false;
        self.external_command_set = false;
        self.array_line = line_no;
        self.section = .top;
    }

    fn beginTable(self: *ParseState, allocator: Allocator, name: []const u8, diag: *Diagnostic) ParseError!void {
        try self.flush(allocator, diag);
        self.array_kind = .none;
        self.section = sectionFor(name);
    }

    fn setArrayKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        switch (self.array_kind) {
            .boundary => try self.setBoundaryKey(allocator, kv),
            .allow => try self.setAllowKey(allocator, kv),
            .external => try self.setExternalKey(allocator, kv),
            .none => {},
        }
    }

    fn setBoundaryKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "module")) {
            self.cur_module = parseString(kv.val);
        } else if (std.mem.eql(u8, kv.key, "forbidden")) {
            self.cur_forbidden = try parseStringArray(allocator, kv.val);
            self.boundary_forbidden_set = true;
        }
    }

    fn setAllowKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "check")) {
            self.cur_check = parseString(kv.val);
        } else if (std.mem.eql(u8, kv.key, "paths")) {
            self.cur_paths = try parseStringArray(allocator, kv.val);
            self.allow_paths_set = true;
        }
    }

    fn setExternalKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "name")) {
            self.cur_name = parseString(kv.val);
        } else if (std.mem.eql(u8, kv.key, "command")) {
            self.cur_command = try parseStringArray(allocator, kv.val);
            self.external_command_set = true;
        } else if (std.mem.eql(u8, kv.key, "inputs")) {
            self.cur_inputs = try parseStringArray(allocator, kv.val);
        }
    }
};

const MutationLines = struct {
    min_score_pct: u32 = 0,
    min_mutants: u32 = 0,
    max_mutants: u32 = 0,
    fast_max_mutants: u32 = 0,
    timeout_floor_secs: u32 = 0,
    timeout_multiplier: u32 = 0,
    timeout_retry_multiplier: u32 = 0,
    timeout_secs: u32 = 0,
    retained_cache_suites: u32 = 0,
};

const ThresholdLines = struct {
    max_file_lines: u32 = 0,
    hard_max_file_lines: u32 = 0,
    function_max_lines: u32 = 0,
    function_hard_max_lines: u32 = 0,
    line_max_len: u32 = 0,
    line_hard_max_len: u32 = 0,
};

fn arrayKindFor(name: []const u8) ArrayKind {
    if (std.mem.eql(u8, name, "boundary")) return .boundary;
    if (std.mem.eql(u8, name, "allow")) return .allow;
    if (std.mem.eql(u8, name, "external")) return .external;
    return .none;
}

/// Parses guardian.toml content into a Config. Discards the diagnostic; use
/// `parseInto` when the offending line/message is needed (see `load`).
pub fn parse(allocator: Allocator, content: []const u8) ParseError!Config {
    var diag: Diagnostic = .{};
    return parseInto(allocator, content, &diag);
}

/// Parses guardian.toml content, filling `diag` for every rejected input.
/// Unknown names, malformed values/lines, incomplete array tables, and unsafe
/// semantic combinations all fail closed.
pub fn parseInto(allocator: Allocator, content: []const u8, diag: *Diagnostic) ParseError!Config {
    var cfg = Config{};
    var st: ParseState = .{};
    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    var pending: std.ArrayList(u8) = .empty;
    var pending_line: u32 = 0;
    while (lines_iter.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (pending.items.len != 0) {
            try pending.append(allocator, '\n');
            try pending.appendSlice(allocator, line);
            if (startsMultilineArray(pending.items)) continue;
            try parseLine(allocator, &cfg, &st, pending.items, pending_line, diag);
            pending.clearRetainingCapacity();
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;
        if (startsMultilineArray(line)) {
            pending_line = line_no;
            try pending.appendSlice(allocator, line);
            continue;
        }
        try parseLine(allocator, &cfg, &st, line, line_no, diag);
    }
    if (pending.items.len != 0) {
        try setDiag(allocator, diag, pending_line, "malformed string array: missing closing ']'", .{});
        return error.InvalidValue;
    }
    try st.flush(allocator, diag);
    try validateConfig(allocator, &cfg, &st, diag);
    cfg.boundary_rules = try st.boundaries.toOwnedSlice(allocator);
    cfg.allow_rules = try st.allows.toOwnedSlice(allocator);
    cfg.external_gates = try st.external_gates.toOwnedSlice(allocator);
    return cfg;
}

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
        return st.beginArrayTable(allocator, name, line_no, diag);
    }
    if (tableName(line)) |name| {
        if (sectionFor(name) == .unknown) return unknownName(allocator, diag, line_no, "section", name, &.{});
        return st.beginTable(allocator, name, diag);
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

/// A value beginning with `[` but not closing on this physical line is
/// accumulated until its matching bracket, enabling readable multiline lists.
fn applyKeyValueLine(
    allocator: Allocator,
    cfg: *Config,
    st: *ParseState,
    line: []const u8,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse {
        try setDiag(allocator, diag, line_no, "expected 'key = value'", .{});
        return error.MalformedLine;
    };
    const key = std.mem.trim(u8, line[0..eq_idx], &std.ascii.whitespace);
    if (key.len == 0) {
        try setDiag(allocator, diag, line_no, "missing key before '='", .{});
        return error.MalformedLine;
    }
    const raw = std.mem.trim(u8, line[eq_idx + 1 ..], &std.ascii.whitespace);
    const val = if (raw.len != 0 and raw[0] == '[') raw else stripInlineComment(raw);
    const kv: KeyVal = .{ .key = key, .val = val };
    // A key the current section doesn't recognize is a typo, not a value to
    // silently drop — name it (with a cheap suggestion) and fail.
    const valid = if (st.array_kind != .none) validArrayKeys(st.array_kind) else validSectionKeys(st.section);
    if (!inList(valid, key)) return unknownName(allocator, diag, line_no, "key", key, valid);
    try validateValue(allocator, st, kv, line_no, diag);
    if (st.array_kind == .none and st.section == .mutation) noteMutationLine(&st.mutation_lines, key, line_no);
    noteThresholdLine(&st.threshold_lines, st.section, key, line_no);
    if (st.array_kind != .none) return st.setArrayKey(allocator, kv);
    try applySectionKey(.{ .allocator = allocator, .cfg = cfg }, st.section, kv);
}

const ValueKind = enum { boolean, unsigned, string, string_array };

/// Returns the value shape from the already-validated section/key position.
/// The first-character branches are unambiguous within each section and avoid
/// maintaining a third duplicate list of every supported key.
fn valueKind(st: *const ParseState, key: []const u8) ValueKind {
    if (st.array_kind != .none) return switch (st.array_kind) {
        .boundary => if (key[0] == 'm') .string else .string_array,
        .allow => if (key[0] == 'c') .string else .string_array,
        .external => if (key[0] == 'n') .string else .string_array,
        .none => .string_array,
    };
    return switch (st.section) {
        .top => switch (key[0]) {
            's' => .string,
            'h', 'm' => .unsigned,
            'c', 'p' => .boolean,
            else => .string_array,
        },
        .spec_quality, .orphan_files, .test_coverage, .completeness => if (key[1] == 'n') .boolean else .string_array,
        .function_size,
        .complexity,
        .function_length,
        .nesting_depth,
        .bool_ops,
        .line_length,
        => {
            return if (key[0] == 'e') .boolean else .unsigned;
        },
        .anytype_budget, .doc_quality, .type_size => switch (key[0]) {
            'e' => if (key[1] == 'n') .boolean else .string_array,
            'm' => .unsigned,
            else => .string_array,
        },
        .baseline => if (key[1] == 'n') .boolean else .string_array,
        .escape_discipline, .oom_discipline, .magic_number, .stdout_flush, .dead_pub => .boolean,
        .module_doc_header => .unsigned,
        .change_classification => if (key[0] == 'a') .string else .boolean,
        .mutation => if (key[0] == 's') .string else .unsigned,
        .benchmark => .string_array,
        .dora => if (key[0] == 'e') .boolean else .string,
        .fuzz_presence, .int_from_float => .string_array,
        .policy => if (std.mem.eql(u8, key, "profile") or std.mem.eql(u8, key, lock_against_key))
            .string
        else if (std.mem.eql(u8, key, lock_enabled_key))
            .boolean
        else
            .string_array,
        .doctor => .unsigned,
        // on_build / test_command are strings; install_hook is a bool.
        .gate => if (key[0] == 'i') .boolean else .string,
        .unknown => .string_array,
    };
}

fn validateValue(
    allocator: Allocator,
    st: *const ParseState,
    kv: KeyVal,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    const kind = valueKind(st, kv.key);
    const ok = switch (kind) {
        .boolean => parseBool(kv.val) != null,
        .unsigned => std.fmt.parseInt(u32, kv.val, 10) catch null != null,
        .string => isValidString(kv.val),
        .string_array => isValidStringArray(kv.val),
    };
    if (!ok) {
        try setDiag(allocator, diag, line_no, "invalid value for '{s}'", .{kv.key});
        return error.InvalidValue;
    }
    if (st.array_kind == .none and st.section == .policy and std.mem.eql(u8, kv.key, "profile")) {
        const profile = parseString(kv.val).?;
        if (!config_policy.validProfile(profile)) {
            try setDiag(allocator, diag, line_no, "invalid policy profile '{s}'", .{profile});
            return error.InvalidValue;
        }
    }
    if (st.array_kind == .none and st.section == .gate and std.mem.eql(u8, kv.key, on_build_key)) {
        const mode = parseString(kv.val).?;
        if (!std.mem.eql(u8, mode, "report") and !std.mem.eql(u8, mode, "block")) {
            try setDiag(allocator, diag, line_no, "invalid gate on_build '{s}' (want report or block)", .{mode});
            return error.InvalidValue;
        }
    }

    // Values used as filesystem/config identifiers must not be empty. Array
    // tables additionally need non-empty identities even when both keys exist.
    if (kind == .string) {
        const s = parseString(kv.val).?;
        if (std.mem.trim(u8, s, &std.ascii.whitespace).len == 0) {
            try setDiag(allocator, diag, line_no, "'{s}' must not be empty", .{kv.key});
            return error.InvalidValue;
        }
    }
    if (kind == .string_array and hasEmptyArrayItem(kv.val)) {
        try setDiag(allocator, diag, line_no, "'{s}' must not contain empty strings", .{kv.key});
        return error.InvalidValue;
    }
}

fn noteMutationLine(lines: *MutationLines, key: []const u8, line_no: u32) void {
    inline for (std.meta.fields(MutationLines)) |field| {
        if (std.mem.eql(u8, key, field.name)) @field(lines, field.name) = line_no;
    }
}

fn noteThresholdLine(lines: *ThresholdLines, section: Section, key: []const u8, line_no: u32) void {
    if (section == .top and std.mem.eql(u8, key, max_file_lines_key)) lines.max_file_lines = line_no;
    if (section == .top and std.mem.eql(u8, key, hard_max_file_lines_key)) lines.hard_max_file_lines = line_no;
    if (section == .function_length and std.mem.eql(u8, key, max_lines_key)) lines.function_max_lines = line_no;
    if (section == .function_length and std.mem.eql(u8, key, hard_max_lines_key)) {
        lines.function_hard_max_lines = line_no;
    }
    if (section == .line_length and std.mem.eql(u8, key, max_len_key)) lines.line_max_len = line_no;
    if (section == .line_length and std.mem.eql(u8, key, hard_max_len_key)) lines.line_hard_max_len = line_no;
}

fn semanticLine(st: *const ParseState, field: semantics.Field) u32 {
    const n = switch (field) {
        .hard_max_file_lines => firstLine(st.threshold_lines.hard_max_file_lines, st.threshold_lines.max_file_lines),
        .function_hard_max_lines => firstLine(
            st.threshold_lines.function_hard_max_lines,
            st.threshold_lines.function_max_lines,
        ),
        .line_hard_max_len => firstLine(st.threshold_lines.line_hard_max_len, st.threshold_lines.line_max_len),
        .min_score_pct => st.mutation_lines.min_score_pct,
        .min_mutants => st.mutation_lines.min_mutants,
        .max_mutants => st.mutation_lines.max_mutants,
        .fast_max_mutants => st.mutation_lines.fast_max_mutants,
        .timeout_floor_secs => st.mutation_lines.timeout_floor_secs,
        .timeout_multiplier => st.mutation_lines.timeout_multiplier,
        .timeout_retry_multiplier => st.mutation_lines.timeout_retry_multiplier,
        .timeout_secs => st.mutation_lines.timeout_secs,
    };
    return if (n == 0) 1 else n;
}

fn firstLine(preferred: u32, fallback: u32) u32 {
    return if (preferred != 0) preferred else fallback;
}

fn validateConfig(allocator: Allocator, cfg: *const Config, st: *const ParseState, diag: *Diagnostic) ParseError!void {
    const issue = try semantics.validate(allocator, cfg) orelse return;
    diag.* = .{ .line = semanticLine(st, issue.field), .message = issue.message };
    return error.InvalidConfig;
}

/// The `enabled` toggle plus the extra keys `section` accepts (mirrors the
/// appliers in `applySectionKey`). A key outside this set is an unknown-key
/// error. Keep in sync when an applier gains a key.
fn validSectionKeys(section: Section) []const []const u8 {
    return switch (section) {
        .top => &.{
            "spec_file",     max_file_lines_key, hard_max_file_lines_key,
            "cache_enabled", "parallel",         "file_size_exclude",
            "exclude",       "disabled",         required_inputs_key,
        },
        .spec_quality => &.{ "enabled", "forbidden_phrases" },
        .function_size => &.{ "enabled", "max_params" },
        .complexity => &.{ "enabled", "max_score" },
        .anytype_budget => &.{ "enabled", "max_per_file", "exclude" },
        .orphan_files => &.{ "enabled", "roots" },
        .doc_quality => &.{ "enabled", "min_chars", exempt_names_key },
        .type_size => &.{ "enabled", "max_fields", "exclude" },
        .function_length => &.{ "enabled", max_lines_key, hard_max_lines_key },
        .nesting_depth => &.{ "enabled", "max_depth" },
        .test_coverage => &.{ "enabled", exempt_names_key },
        .bool_ops => &.{ "enabled", "max_ops" },
        .line_length => &.{ "enabled", max_len_key, hard_max_len_key },
        .baseline => &.{ "enabled", "deny_growth" },
        .escape_discipline, .oom_discipline, .magic_number, .stdout_flush => &.{"enabled"},
        .module_doc_header => &.{"min_lines"},
        .dead_pub => &.{"ignore_test_refs"},
        .change_classification => &.{ "enabled", "against", "gate_last_commit" },
        .mutation => &.{
            min_score_pct_key,
            min_mutants_key,
            max_mutants_key,
            fast_max_mutants_key,
            "smoke_step",
            timeout_floor_secs_key,
            timeout_multiplier_key,
            timeout_retry_multiplier_key,
            timeout_secs_key,
            "retained_cache_suites",
        },
        .benchmark => &.{"gate"},
        .completeness => &.{ "enabled", "exempt_sections" },
        .dora => &.{ "enabled", "sink_path" },
        .fuzz_presence => &.{"modules"},
        .int_from_float => &.{ "guard_fns", "require_guard" },
        .policy => &.{ "profile", "block", "ratchet", "report", lock_enabled_key, lock_against_key, "protected_paths" },
        .doctor => &.{ "zig_cache_warn_mib", "guardian_cache_warn_mib" },
        .gate => &.{ on_build_key, "test_command", "install_hook" },
        .unknown => &.{},
    };
}

/// Keys accepted inside a `[[boundary]]` / `[[allow]]` array-of-tables entry.
fn validArrayKeys(kind: ArrayKind) []const []const u8 {
    return switch (kind) {
        .boundary => &.{ "module", "forbidden" },
        .allow => &.{ "check", "paths" },
        .external => &.{ "name", "command", "inputs" },
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
        .function_length => applyDualLimitCfg("function_length", max_lines_key, hard_max_lines_key, ctx, kv),
        .nesting_depth => applyU32Cfg("nesting_depth", "max_depth", ctx, kv),
        .bool_ops => applyU32Cfg("bool_ops", "max_ops", ctx, kv),
        .line_length => applyDualLimitCfg("line_length", max_len_key, hard_max_len_key, ctx, kv),
        .anytype_budget => try applyAnytypeBudgetKey(ctx, kv),
        .type_size => try applyTypeSizeKey(ctx, kv),
        .baseline => try applyBaselineKey(ctx, kv),
        .escape_discipline => applyEnabledCfg("escape_discipline", ctx, kv),
        .oom_discipline => applyEnabledCfg("oom_discipline", ctx, kv),
        .magic_number => applyEnabledCfg("magic_number", ctx, kv),
        .stdout_flush => applyEnabledCfg("stdout_flush", ctx, kv),
        .module_doc_header => applyModuleDocHeaderKey(ctx, kv),
        .dead_pub => applyBoolCfg("dead_pub", "ignore_test_refs", ctx, kv),
        .change_classification => applyChangeClassificationKey(ctx, kv),
        .mutation => applyMutationKey(ctx, kv),
        .benchmark => try applyBenchmarkKey(ctx, kv),
        .completeness => try applyCompletenessKey(ctx, kv),
        .dora => applyDoraKey(ctx, kv),
        .fuzz_presence => try applyFuzzPresenceKey(ctx, kv),
        .int_from_float => try applyIntFromFloatKey(ctx, kv),
        .policy => try config_policy.applyPolicy(ctx.allocator, ctx.cfg, kv.key, kv.val),
        .doctor => config_policy.applyDoctor(ctx.cfg, kv.key, kv.val),
        .gate => applyGateKey(ctx, kv),
        .unknown => {},
    }
}

/// Applies one `[gate]` key: `on_build` (report/block — already value-checked),
/// `test_command` (the commit-time suite), and `install_hook` (auto pre-commit
/// hook on `commit`).
fn applyGateKey(ctx: ApplyCtx, kv: KeyVal) void {
    const g = &ctx.cfg.gate;
    if (std.mem.eql(u8, kv.key, on_build_key)) {
        if (parseString(kv.val)) |v| g.on_build = if (std.mem.eql(u8, v, "block")) .block else .report;
    } else if (std.mem.eql(u8, kv.key, "test_command")) {
        if (parseString(kv.val)) |v| g.test_command = v;
    } else if (std.mem.eql(u8, kv.key, "install_hook")) {
        g.install_hook = parseBool(kv.val) orelse g.install_hook;
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
        .{ "stdout_flush", Section.stdout_flush },
        .{ "module_doc_header", Section.module_doc_header },
        .{ "dead_pub", Section.dead_pub },
        .{ "change_classification", Section.change_classification },
        .{ "mutation", Section.mutation },
        .{ "benchmark", Section.benchmark },
        .{ "completeness", Section.completeness },
        .{ "dora", Section.dora },
        .{ "fuzz_presence", Section.fuzz_presence },
        .{ "int_from_float", Section.int_from_float },
        .{ "policy", Section.policy },
        .{ "doctor", Section.doctor },
        .{ "gate", Section.gate },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return .unknown;
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

/// Applies an enabled toggle plus warning and hard u32 limits.
fn applyDualLimitCfg(
    comptime group: []const u8,
    comptime warn_key: []const u8,
    comptime hard_key: []const u8,
    ctx: ApplyCtx,
    kv: KeyVal,
) void {
    const g = &@field(ctx.cfg, group);
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, warn_key)) {
        @field(g, warn_key) = parseU32(kv.val, @field(g, warn_key));
    } else if (std.mem.eql(u8, kv.key, hard_key)) {
        @field(g, hard_key) = parseU32(kv.val, @field(g, hard_key));
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
    } else if (std.mem.eql(u8, kv.key, max_file_lines_key)) {
        cfg.max_file_lines = parseU32(kv.val, cfg.max_file_lines);
    } else if (std.mem.eql(u8, kv.key, hard_max_file_lines_key)) {
        cfg.hard_max_file_lines = parseU32(kv.val, cfg.hard_max_file_lines);
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
    } else if (std.mem.eql(u8, kv.key, required_inputs_key)) {
        cfg.required_inputs = try toStrings(ctx.allocator, kv.val);
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
    if (std.mem.eql(u8, kv.key, min_score_pct_key)) {
        g.min_score_pct = parseU32(kv.val, g.min_score_pct);
    } else if (std.mem.eql(u8, kv.key, min_mutants_key)) {
        g.min_mutants = parseU32(kv.val, g.min_mutants);
    } else if (std.mem.eql(u8, kv.key, max_mutants_key)) {
        g.max_mutants = parseU32(kv.val, g.max_mutants);
    } else if (std.mem.eql(u8, kv.key, fast_max_mutants_key)) {
        g.fast_max_mutants = parseU32(kv.val, g.fast_max_mutants);
    } else if (std.mem.eql(u8, kv.key, "smoke_step")) {
        g.smoke_step = parseString(kv.val);
    } else if (std.mem.eql(u8, kv.key, timeout_floor_secs_key)) {
        g.timeout_floor_secs = parseU32(kv.val, g.timeout_floor_secs);
    } else if (std.mem.eql(u8, kv.key, timeout_multiplier_key)) {
        g.timeout_multiplier = parseU32(kv.val, g.timeout_multiplier);
    } else if (std.mem.eql(u8, kv.key, timeout_retry_multiplier_key)) {
        g.timeout_retry_multiplier = parseU32(kv.val, g.timeout_retry_multiplier);
    } else if (std.mem.eql(u8, kv.key, timeout_secs_key)) {
        g.timeout_secs = parseU32(kv.val, g.timeout_secs);
    } else if (std.mem.eql(u8, kv.key, "retained_cache_suites")) {
        g.retained_cache_suites = parseU32(kv.val, g.retained_cache_suites);
    }
}

/// Applies the `[benchmark] gate` list — the metric names opted into the
/// ledger's per-metric ratchet (see config.BenchmarkCfg).
fn applyBenchmarkKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    if (std.mem.eql(u8, kv.key, "gate")) {
        ctx.cfg.benchmark.gate = try toStrings(ctx.allocator, kv.val);
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

fn applyFuzzPresenceKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    if (std.mem.eql(u8, kv.key, "modules")) {
        ctx.cfg.fuzz_presence.modules = try toStrings(ctx.allocator, kv.val);
    }
}

fn applyIntFromFloatKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.int_from_float;
    if (std.mem.eql(u8, kv.key, "guard_fns")) {
        g.guard_fns = try toStrings(ctx.allocator, kv.val);
    } else if (std.mem.eql(u8, kv.key, "require_guard")) {
        g.require_guard = try toStrings(ctx.allocator, kv.val);
    }
}

/// Applies the `min_lines` threshold to `cfg.module_doc_header` (no `enabled`
/// key — the check is always on; the knob only moves its line threshold).
fn applyModuleDocHeaderKey(ctx: ApplyCtx, kv: KeyVal) void {
    const g = &ctx.cfg.module_doc_header;
    if (std.mem.eql(u8, kv.key, "min_lines")) {
        g.min_lines = parseU32(kv.val, g.min_lines);
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
    try std.testing.expectEqual(@as(u32, 10_000), cfg.hard_max_file_lines);
    try std.testing.expectEqual(@as(u32, 400), cfg.function_length.hard_max_lines);
    try std.testing.expectEqual(@as(u32, 240), cfg.line_length.hard_max_len);
}

// spec: Configuration - Parses warning and hard limits for file size, function length, and line length

test "parse dual warning and hard thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\max_file_lines = 800
        \\hard_max_file_lines = 8000
        \\[function_length]
        \\max_lines = 100
        \\hard_max_lines = 350
        \\[line_length]
        \\max_len = 110
        \\hard_max_len = 220
    );
    try std.testing.expectEqual(@as(u32, 800), cfg.max_file_lines);
    try std.testing.expectEqual(@as(u32, 8000), cfg.hard_max_file_lines);
    try std.testing.expectEqual(@as(u32, 100), cfg.function_length.max_lines);
    try std.testing.expectEqual(@as(u32, 350), cfg.function_length.hard_max_lines);
    try std.testing.expectEqual(@as(u32, 110), cfg.line_length.max_len);
    try std.testing.expectEqual(@as(u32, 220), cfg.line_length.hard_max_len);
}

test "parse rejects a hard threshold below its warning threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        parseInto(
            arena.allocator(),
            "[line_length]\nmax_len = 120\nhard_max_len = 100\n",
            &diag,
        ),
    );
    try std.testing.expectEqual(@as(u32, 3), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "must exceed") != null);
}

// spec-case: Configuration - Parses policy profiles, policy locks, doctor thresholds, and external argv gates

test "parse policy doctor and external gate settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[policy]
        \\profile = "agent"
        \\report = ["optional-density"]
        \\ratchet = ["file-size"]
        \\lock_enabled = true
        \\lock_against = "origin/main"
        \\protected_paths = ["guardian.toml", ".guardian/"]
        \\[doctor]
        \\zig_cache_warn_mib = 8192
        \\guardian_cache_warn_mib = 512
        \\[[external]]
        \\name = "javascript-syntax"
        \\command = ["node", "--check", "src/app.js"]
        \\inputs = ["src/app.js"]
    );
    try std.testing.expect(cfg.policy.profile == .agent);
    try std.testing.expect(cfg.policy.lock_enabled);
    try std.testing.expectEqualStrings("origin/main", cfg.policy.lock_against);
    try std.testing.expectEqual(@as(u32, 8192), cfg.doctor.zig_cache_warn_mib);
    try std.testing.expectEqual(@as(usize, 1), cfg.external_gates.len);
    try std.testing.expectEqualStrings("node", cfg.external_gates[0].command[0]);
    try std.testing.expectEqualStrings("src/app.js", cfg.external_gates[0].inputs[0]);
}

// spec: Benchmark Ledger - Parses the opt-in list of gated benchmark metrics

test "parse benchmark gate list defaults to empty and reads named metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Nothing is gated without a [benchmark] section: the ledger only records.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), defaults.benchmark.gate.len);

    const cfg = try parse(arena.allocator(),
        \\[benchmark]
        \\gate = ["kill_score", "close_open_nets_wall_s"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.benchmark.gate.len);
    try std.testing.expectEqualStrings("kill_score", cfg.benchmark.gate[0]);
    try std.testing.expectEqualStrings("close_open_nets_wall_s", cfg.benchmark.gate[1]);

    // A typo'd key inside the known section fails closed like every other one.
    try std.testing.expectError(error.UnknownKey, parse(arena.allocator(), "[benchmark]\ngates = [\"x\"]\n"));
}

// spec: Configuration - Parses the gate mode, test command, and hook install settings

test "parse gate section on_build test_command and install_hook" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default (no [gate]) is report mode with the default test command and hook on.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expect(defaults.gate.on_build == .report);
    try std.testing.expectEqualStrings("zig build test", defaults.gate.test_command);
    try std.testing.expect(defaults.gate.install_hook);

    const cfg = try parse(arena.allocator(),
        \\[gate]
        \\on_build = "block"
        \\test_command = "zig build test-fast"
        \\install_hook = false
    );
    try std.testing.expect(cfg.gate.on_build == .block);
    try std.testing.expectEqualStrings("zig build test-fast", cfg.gate.test_command);
    try std.testing.expect(!cfg.gate.install_hook);

    // An unknown on_build value fails closed with a located diagnostic.
    try std.testing.expectError(error.InvalidValue, parse(arena.allocator(), "[gate]\non_build = \"warn\"\n"));
}

test "parse rejects an unknown policy profile and empty external command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, parse(arena.allocator(), "[policy]\nprofile = \"casual\"\n"));
    try std.testing.expectError(
        error.IncompleteTable,
        parse(arena.allocator(), "[[external]]\nname = \"empty\"\ncommand = []\n"),
    );
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

// spec: Configuration - Parses a top-level required input glob list

test "parse required input patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(
        arena.allocator(),
        "required_inputs = [\"src/generated/*.zig\", \"assets/schema.json\"]",
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.required_inputs.len);
    try std.testing.expectEqualStrings("src/generated/*.zig", cfg.required_inputs[0]);
    try std.testing.expectEqualStrings("assets/schema.json", cfg.required_inputs[1]);
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

// spec: Configuration - Hard-fails on malformed values and bare non-key lines with a located diagnostic

test "parse malformed values fail closed with a located diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "max_file_lines = not_a_number",
        "parallel = maybe",
        "spec_file = unquoted",
        "spec_file = \"\"",
        "disabled = [\"valid\", nope]",
        "exclude = [\"src/*\", \"\"]",
        "this is not a key",
    };
    for (cases) |content| {
        var diag: Diagnostic = .{};
        _ = parseInto(arena.allocator(), content, &diag) catch |e| {
            try std.testing.expect(e == error.InvalidValue or e == error.MalformedLine);
            try std.testing.expectEqual(@as(u32, 1), diag.line);
            try std.testing.expect(diag.message.len != 0);
            continue;
        };
        return error.TestUnexpectedResult;
    }
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

// spec: Configuration - Supports multiline string arrays with comments and trailing commas

test "parse multiline string arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\disabled = [
        \\  "spec", # tracked migration debt
        \\  "line-length",
        \\]
        \\[[allow]]
        \\check = "ban-fs"
        \\paths = [
        \\  "src/infra/*",
        \\  "src/testing/*"
        \\]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.disabled.len);
    try std.testing.expectEqualStrings("line-length", cfg.disabled[1]);
    try std.testing.expectEqual(@as(usize, 2), cfg.allow_rules[0].paths.len);
    try std.testing.expectEqualStrings("src/testing/*", cfg.allow_rules[0].paths[1]);
}

// spec: Configuration - Hard-fails on incomplete boundary and allow array tables

test "parse rejects incomplete array tables at their header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[[boundary]]\nforbidden = [\"shell\"]",
        "[[boundary]]\nmodule = \"src/*\"",
        "[[allow]]\npaths = [\"src/*\"]",
        "[[allow]]\ncheck = \"ban-fs\"",
    };
    for (cases) |content| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.IncompleteTable, parseInto(arena.allocator(), content, &diag));
        try std.testing.expectEqual(@as(u32, 1), diag.line);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, "incomplete") != null);
    }
}

test "parse rejects unsafe mutation invariants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[mutation]\nmin_score_pct = 101",
        "[mutation]\ntimeout_floor_secs = 0",
        "[mutation]\ntimeout_multiplier = 0",
        "[mutation]\ntimeout_retry_multiplier = 0",
        "[mutation]\ntimeout_secs = 0",
        "[mutation]\nmin_mutants = 20\nmax_mutants = 10\nfast_max_mutants = 8",
        "[mutation]\nmax_mutants = 7\nfast_max_mutants = 8",
        "[mutation]\nmin_mutants = 9\nfast_max_mutants = 8",
        "[mutation]\nfast_max_mutants = 0",
    };
    for (cases) |content| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parseInto(arena.allocator(), content, &diag));
        try std.testing.expect(diag.line >= 2);
        try std.testing.expect(diag.message.len != 0);
    }
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
        \\fast_max_mutants = 10
        \\smoke_step = "test-fast"
        \\timeout_secs = 60
        \\timeout_retry_multiplier = 3
        \\retained_cache_suites = 5
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(u32, 90), cfg.mutation.min_score_pct);
    try std.testing.expectEqual(@as(u32, 6), cfg.mutation.min_mutants);
    try std.testing.expectEqual(@as(u32, 25), cfg.mutation.max_mutants);
    try std.testing.expectEqual(@as(u32, 10), cfg.mutation.fast_max_mutants);
    try std.testing.expectEqualStrings("test-fast", cfg.mutation.smoke_step.?);
    try std.testing.expectEqual(@as(u32, 60), cfg.mutation.timeout_secs);
    try std.testing.expectEqual(@as(u32, 3), cfg.mutation.timeout_retry_multiplier);
    try std.testing.expectEqual(@as(u32, 5), cfg.mutation.retained_cache_suites);
}

// spec: Configuration - Parses the mutation section timeout floor and multiplier

test "parse reads [mutation] timeout floor and multiplier with defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Absent keys keep the cargo-mutants-style defaults (floor 30s, ×5).
    const defaults = try parse(arena.allocator(), "[mutation]\nmin_score_pct = 80");
    try std.testing.expectEqual(@as(u32, 30), defaults.mutation.timeout_floor_secs);
    try std.testing.expectEqual(@as(u32, 5), defaults.mutation.timeout_multiplier);
    try std.testing.expectEqual(@as(u32, 8), defaults.mutation.fast_max_mutants);
    try std.testing.expectEqual(@as(?[]const u8, null), defaults.mutation.smoke_step);
    try std.testing.expectEqual(@as(u32, 2), defaults.mutation.timeout_retry_multiplier);
    try std.testing.expectEqual(@as(u32, 3), defaults.mutation.retained_cache_suites);
    // Explicit values override them.
    const content =
        \\[mutation]
        \\timeout_floor_secs = 45
        \\timeout_multiplier = 8
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expectEqual(@as(u32, 45), cfg.mutation.timeout_floor_secs);
    try std.testing.expectEqual(@as(u32, 8), cfg.mutation.timeout_multiplier);
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

// spec: Configuration - Parses the fuzz_presence modules list

test "parse [fuzz_presence] defaults empty and reads the modules list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: no modules configured, so the check is a no-op.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), defaults.fuzz_presence.modules.len);
    const cfg = try parse(arena.allocator(),
        \\[fuzz_presence]
        \\modules = ["src/config_parser.zig", "src/walk.zig"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.fuzz_presence.modules.len);
    try std.testing.expectEqualStrings("src/config_parser.zig", cfg.fuzz_presence.modules[0]);
    try std.testing.expectEqualStrings("src/walk.zig", cfg.fuzz_presence.modules[1]);
}

// spec: Configuration - Parses the int_from_float guard_fns and require_guard lists

test "parse [int_from_float] defaults empty and reads guard_fns + require_guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: no guards, no strict paths — the plain count-everything budget.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), defaults.int_from_float.guard_fns.len);
    try std.testing.expectEqual(@as(usize, 0), defaults.int_from_float.require_guard.len);
    const cfg = try parse(arena.allocator(),
        \\[int_from_float]
        \\guard_fns = ["checkedInt"]
        \\require_guard = ["src/render/*"]
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.int_from_float.guard_fns.len);
    try std.testing.expectEqualStrings("checkedInt", cfg.int_from_float.guard_fns[0]);
    try std.testing.expectEqual(@as(usize, 1), cfg.int_from_float.require_guard.len);
    try std.testing.expectEqualStrings("src/render/*", cfg.int_from_float.require_guard[0]);
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

// spec: Configuration - Defaults stdout_flush off and promotes it to a hard block via [stdout_flush] enabled
test "stdout_flush defaults off and opts into gating via config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: off, so the check stays report-only.
    const default_cfg = try parse(arena.allocator(), "");
    try std.testing.expectEqual(false, default_cfg.stdout_flush.enabled);
    // Opt in to promote the check to a gating hard-block.
    const opted = try parse(arena.allocator(),
        \\[stdout_flush]
        \\enabled = true
    );
    try std.testing.expectEqual(true, opted.stdout_flush.enabled);
}

// spec: Configuration - Parses the module_doc_header min_lines threshold
test "module_doc_header defaults to 200 lines and reads a custom min_lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: the 200-line threshold, unchanged from before the knob existed.
    const default_cfg = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(u32, 200), default_cfg.module_doc_header.min_lines);
    // Override to a lower threshold.
    const cfg = try parse(arena.allocator(),
        \\[module_doc_header]
        \\min_lines = 50
    );
    try std.testing.expectEqual(@as(u32, 50), cfg.module_doc_header.min_lines);
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

// Hand-picked malformed inputs so the default `zig build test` smoke run — which
// calls the harness on every corpus entry plus the empty string — actually
// exercises the reject paths, not just a trivial parse. `zig build test --fuzz`
// explores past these.
const config_fuzz_corpus = [_][]const u8{
    "[[",
    "[unknown_section]",
    "[mutation]\nbogus = 1",
    "spec_file = \"x",
    "[[allow]]\ncheck =",
};

/// One fuzz iteration for the guardian.toml parser: arbitrary input bytes must
/// never panic or overflow. A `ParseError` is a valid outcome — the invariant
/// under test is that rejecting input never fails open: whenever the parser
/// returns UnknownSection/UnknownKey it has also populated the diagnostic (a
/// non-zero line and a non-empty message), so a misconfigured gate always
/// reports where. OOM from a giant fuzzer input is not a parser bug.
fn fuzzParseInto(allocator: Allocator, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    _ = parseInto(arena.allocator(), input, &diag) catch |e| switch (e) {
        error.OutOfMemory => return,
        error.UnknownSection,
        error.UnknownKey,
        error.MalformedLine,
        error.InvalidValue,
        error.IncompleteTable,
        error.InvalidConfig,
        => {
            try std.testing.expect(diag.line != 0 and diag.message.len != 0);
            return;
        },
    };
}

// spec: Fuzzing - Fuzzing the guardian.toml parser never panics and every reject populates its diagnostic
test "fuzz: guardian.toml parser tolerates arbitrary bytes" {
    // The allocator rides in as the fuzz context, so the global only appears in
    // this (exempt) test block, not the helper body.
    try std.testing.fuzz(std.testing.allocator, fuzzParseInto, .{ .corpus = &config_fuzz_corpus });
}
