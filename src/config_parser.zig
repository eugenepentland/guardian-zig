//! guardian.toml parser (types live in config.zig). Preserves defaults for
//! unset fields. Fails closed: a missing file is the zero-config default, but a
//! file that exists yet can't be read, or that names an unknown section header
//! or an unknown key inside a known section, is a hard error with a file:line
//! diagnostic — a gate whose own config silently misparses can't be trusted at
//! exactly the moment it's misconfigured. Present-but-malformed values and
//! semantically unsafe settings also fail closed rather than falling back to a
//! default the operator did not ask for.

const std = @import("std");
const fs = @import("fs.zig");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const reporter = @import("reporter.zig");
const value = @import("config_value.zig");
const semantics = @import("config_semantics.zig");
const config_policy = @import("config_policy.zig");
const hysteresis = @import("hysteresis.zig");
const Config = config.Config;
const BoundaryRule = config.BoundaryRule;
const AllowRule = config.AllowRule;
const BanRule = config.BanRule;
const ConceptRule = config.ConceptRule;
const IdiomRule = config.IdiomRule;
const ShadowRule = config.ShadowRule;
const LayeringRule = config.LayeringRule;
const LiteralsFrom = config.LiteralsFrom;
const TwinRule = config.TwinRule;
const DeadModelFieldRule = config.DeadModelFieldRule;
const ExternalGate = config.ExternalGate;
const arrayTableName = value.arrayTableName;
const bestMatch = value.bestMatch;
const hasEmptyArrayItem = value.hasEmptyArrayItem;
const isValidString = value.isValidString;
const isValidStringArray = value.isValidStringArray;
const inList = value.inList;
const parseString = value.parseString;
const parseStringAlloc = value.parseStringAlloc;
const parseStringArray = value.parseStringArray;
const parseInlineTable = value.parseInlineTable;
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
const recover_pct_key = "recover_pct";
const required_inputs_key = "required_inputs";
const literals_key = "literals";
const patterns_key = "patterns";
const owner_key = "owner";
const fragments_key = "fragments";
const from_key = "from";
const to_key = "to";
const require_in_key = "require_in";
const literals_from_key = "literals_from";
/// The two keys a `literals_from` inline table accepts. Named consts because
/// the validator, the applier and the diagnostic each spell them, and a fourth
/// copy is how they drift.
const literals_from_file_key = "file";
const literals_from_fragments_key = "fragments";
const surfaces_key = "surfaces";
const parity_test_key = "parity_test";
/// One surface is a capability, not a twin: there is nothing for a second
/// implementation to disagree with.
const min_surfaces = 2;
const on_build_key = "on_build";
const measurement_paths_key = "paths";
const ignore_names_key = "ignore_names";
const mode_key = "mode";
/// The two `[divergent_const] mode` spellings; `units` is the default, so only
/// the widening one needs a named const for the validator and the applier.
const units_mode = "units";
const all_mode = "all";
/// The two `[shadowed_const] mode` spellings. `declared` is the default, so
/// only `auto` — the whole-tree measurement sweep — needs naming twice.
const declared_mode = "declared";
const auto_mode = "auto";
const ignore_values_key = "ignore_values";
const min_float_digits_key = "min_float_digits";
const min_int_digits_key = "min_int_digits";
const min_statements_key = "min_statements";
const min_similarity_key = "min_similarity";
const report_identical_key = "report_identical";
/// Floor on `[twin_drift] min_statements`. A one-line body two files agree on
/// is not evidence of anything, so a floor below this would make the check's
/// own population meaningless rather than merely noisy.
const min_twin_statements = 2;
/// The `[[shadow]]` referent key. Spelled `const` in TOML (it names a Zig
/// const); the Config field is `const_ref`, since `const` is a Zig keyword.
const shadow_const_key = "const";
const benchmark_key = "benchmark";
const lock_enabled_key = config_policy.lock_enabled_key;
const lock_against_key = config_policy.lock_against_key;

/// Reads guardian.toml from `dir`. A missing file is the zero-config default; a
/// present file that can't be read or parsed is a hard failure with a printed
/// `guardian.toml:line: …` diagnostic, so a typo can't silently drop config.
pub fn load(allocator: Allocator, dir: []const u8) LoadError!Config {
    const path = try std.fmt.allocPrint(allocator, "{s}/guardian.toml", .{dir});
    const content = fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return .{}, // zero-config: absent is fine
        else => {
            // reporter.fail already prefixes "guardian: " — don't double it.
            reporter.fail("cannot read {s}: {s}", .{ path, @errorName(e) });
            return error.ConfigUnreadable;
        },
    };
    var diag: Diagnostic = .{};
    const cfg = parseInto(allocator, content, &diag) catch |e| switch (e) {
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
    noteRetiredSections(content);
    return cfg;
}

fn noteRetiredSections(content: []const u8) void {
    const names = [_][]const u8{ "stdout_flush", "escape_discipline", "magic_number" };
    for (names) |name| {
        var buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "[{s}]", .{name}) catch continue;
        if (std.mem.indexOf(u8, content, header) != null)
            reporter.ok("note: guardian.toml section [{s}] is retired and ignored", .{name});
    }
}

const Section = enum {
    top,
    spec_quality,
    function_size,
    complexity,
    anytype_budget,
    orphan_files,
    test_reachability,
    doc_quality,
    type_size,
    function_length,
    nesting_depth,
    test_coverage,
    bool_ops,
    line_length,
    baseline,
    hysteresis,
    retired_check,
    oom_discipline,
    module_doc_header,
    dead_pub,
    change_classification,
    mutation,
    benchmark,
    completeness,
    dora,
    fuzz_presence,
    concurrency_presence,
    script_string_safety,
    int_from_float,
    divergent_const,
    shadowed_const,
    twin_referent,
    twin_drift,
    measurement,
    policy,
    doctor,
    gate,
    test_filter,
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

const ArrayKind = enum { none, boundary, allow, ban, concept, idiom, shadow, layering, twin, dead_model_field, external };

const ParseState = struct {
    section: Section = .top,
    array_kind: ArrayKind = .none,
    cur_module: ?[]const u8 = null,
    cur_forbidden: std.ArrayList([]const u8) = .empty,
    boundaries: std.ArrayList(BoundaryRule) = .empty,
    cur_check: ?[]const u8 = null,
    cur_paths: std.ArrayList([]const u8) = .empty,
    allows: std.ArrayList(AllowRule) = .empty,
    cur_chain: std.ArrayList([]const u8) = .empty,
    cur_ban_paths: std.ArrayList([]const u8) = .empty,
    cur_ban_allow: std.ArrayList([]const u8) = .empty,
    cur_reason: ?[]const u8 = null,
    bans: std.ArrayList(BanRule) = .empty,
    cur_concept_name: ?[]const u8 = null,
    cur_literals: std.ArrayList([]const u8) = .empty,
    cur_patterns: std.ArrayList([]const u8) = .empty,
    cur_owner: std.ArrayList([]const u8) = .empty,
    cur_concept_files: std.ArrayList([]const u8) = .empty,
    cur_require_in: std.ArrayList([]const u8) = .empty,
    cur_literals_from: ?LiteralsFrom = null,
    concepts: std.ArrayList(ConceptRule) = .empty,
    cur_idiom_name: ?[]const u8 = null,
    cur_fragments: std.ArrayList([]const u8) = .empty,
    cur_idiom_files: std.ArrayList([]const u8) = .empty,
    cur_idiom_allow: std.ArrayList([]const u8) = .empty,
    idioms: std.ArrayList(IdiomRule) = .empty,
    cur_shadow_const: ?[]const u8 = null,
    cur_shadow_files: std.ArrayList([]const u8) = .empty,
    cur_shadow_ignore: std.ArrayList([]const u8) = .empty,
    shadows: std.ArrayList(ShadowRule) = .empty,
    cur_layering_name: ?[]const u8 = null,
    cur_from: std.ArrayList([]const u8) = .empty,
    cur_to: std.ArrayList([]const u8) = .empty,
    cur_layering_allow: std.ArrayList([]const u8) = .empty,
    layerings: std.ArrayList(LayeringRule) = .empty,
    cur_twin_name: ?[]const u8 = null,
    cur_surfaces: std.ArrayList([]const u8) = .empty,
    cur_parity_test: ?[]const u8 = null,
    twins: std.ArrayList(TwinRule) = .empty,
    cur_dmf_struct: ?[]const u8 = null,
    cur_dmf_owner: ?[]const u8 = null,
    cur_dmf_fields: std.ArrayList([]const u8) = .empty,
    cur_dmf_output: std.ArrayList([]const u8) = .empty,
    cur_dmf_logic: std.ArrayList([]const u8) = .empty,
    dead_model_fields: std.ArrayList(DeadModelFieldRule) = .empty,
    cur_name: ?[]const u8 = null,
    cur_command: std.ArrayList([]const u8) = .empty,
    cur_inputs: std.ArrayList([]const u8) = .empty,
    cur_external_paths: std.ArrayList([]const u8) = .empty,
    cur_benchmark: ?[]const u8 = null,
    cur_max_regression_pct: u32 = 25,
    cur_external_timeout_secs: u32 = 0,
    cur_max_rss_mib: u32 = 0,
    external_gates: std.ArrayList(ExternalGate) = .empty,
    array_line: u32 = 0,
    mutation_lines: MutationLines = .{},
    threshold_lines: ThresholdLines = .{},
    boundary_forbidden_set: bool = false,
    allow_paths_set: bool = false,
    idiom_files_set: bool = false,
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
            .ban => try self.flushBan(allocator, diag),
            .concept => try self.flushConcept(allocator, diag),
            .idiom => try self.flushIdiom(allocator, diag),
            .shadow => try self.flushShadow(allocator, diag),
            .layering => try self.flushLayering(allocator, diag),
            .twin => try self.flushTwin(allocator, diag),
            .dead_model_field => try self.flushDeadModelField(allocator, diag),
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
                    .paths = try self.cur_external_paths.toOwnedSlice(allocator),
                    .benchmark = self.cur_benchmark,
                    .max_regression_pct = self.cur_max_regression_pct,
                    .timeout_secs = self.cur_external_timeout_secs,
                    .max_rss_mib = self.cur_max_rss_mib,
                });
            },
            .none => {},
        }
    }

    /// Closes a `[[ban]]` entry. An absent or empty `chain` is refused rather
    /// than stored: a rule with nothing to match would sit in the config looking
    /// like a guarantee while banning nothing at all.
    fn flushBan(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        if (self.cur_chain.items.len == 0) {
            try setDiag(
                allocator,
                diag,
                self.array_line,
                "incomplete [[ban]]: 'chain' must be a non-empty string array",
                .{},
            );
            return error.IncompleteTable;
        }
        try self.bans.append(allocator, .{
            .chain = try self.cur_chain.toOwnedSlice(allocator),
            .paths = try self.cur_ban_paths.toOwnedSlice(allocator),
            .allow = try self.cur_ban_allow.toOwnedSlice(allocator),
            .reason = self.cur_reason,
        });
    }

    /// Closes a `[[concept]]` entry. Three ways to be inert are refused rather
    /// than stored, because each one reads in the config like an enforced
    /// ownership rule while enforcing nothing: no `name` (the violation and its
    /// baseline key are named after it), nothing to look for at all, and a
    /// `name` a previous entry already used (identity is `<file>|<name>`, so a
    /// second rule under one name would share — and silently freeze with — the
    /// first one's baseline keys).
    ///
    /// "Nothing to look for" has three cures, not two: `literals`, `patterns`,
    /// or a `literals_from` that will READ the literals out of the owner. The
    /// third one's family is empty here and filled at run time, which is why the
    /// check has its own fail-closed rule for an extraction that yields nothing
    /// (see `checks/concept.zig`) — the config layer cannot see that far.
    fn flushConcept(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        const name = self.cur_concept_name orelse {
            try setDiag(allocator, diag, self.array_line, "incomplete [[concept]]: missing required key 'name'", .{});
            return error.IncompleteTable;
        };
        if (self.cur_literals.items.len == 0 and self.cur_patterns.items.len == 0 and self.cur_literals_from == null) {
            try setDiag(
                allocator,
                diag,
                self.array_line,
                "incomplete [[concept]] '{s}': needs a non-empty 'literals' or 'patterns' array, " ++
                    "or a 'literals_from' table",
                .{name},
            );
            return error.IncompleteTable;
        }
        for (self.concepts.items) |existing| {
            if (!std.mem.eql(u8, existing.name, name)) continue;
            try setDiag(allocator, diag, self.array_line, "duplicate [[concept]] name '{s}'", .{name});
            return error.InvalidConfig;
        }
        try self.concepts.append(allocator, .{
            .name = name,
            .literals = try self.cur_literals.toOwnedSlice(allocator),
            .patterns = try self.cur_patterns.toOwnedSlice(allocator),
            .owner = try self.cur_owner.toOwnedSlice(allocator),
            .files = try self.cur_concept_files.toOwnedSlice(allocator),
            .require_in = try self.cur_require_in.toOwnedSlice(allocator),
            .literals_from = self.cur_literals_from,
            .reason = self.cur_reason,
        });
    }

    /// Closes an `[[idiom]]` entry. Every way to be inert is refused rather than
    /// stored, because each reads in the config like an enforced rule while
    /// enforcing nothing: no `name` (the violation and its baseline key are
    /// named after it), no `fragments` (nothing to look for), no `reason` (an
    /// idiom finding is unactionable without the canonical helper's name — which
    /// is why it is required here and merely recommended for `[[ban]]` /
    /// `[[concept]]`), an explicitly EMPTY `files` (a scan set naming no file),
    /// and a `name` a previous entry already used (identity is `<name>|<file>`,
    /// so a second rule under one name would share — and silently freeze with —
    /// the first one's baseline keys).
    fn flushIdiom(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        const name = self.cur_idiom_name orelse {
            try setDiag(allocator, diag, self.array_line, "incomplete [[idiom]]: missing required key 'name'", .{});
            return error.IncompleteTable;
        };
        const reason = try self.idiomReason(allocator, name, diag);
        for (self.idioms.items) |existing| {
            if (!std.mem.eql(u8, existing.name, name)) continue;
            try setDiag(allocator, diag, self.array_line, "duplicate [[idiom]] name '{s}'", .{name});
            return error.InvalidConfig;
        }
        try self.idioms.append(allocator, .{
            .name = name,
            .fragments = try self.cur_fragments.toOwnedSlice(allocator),
            .files = if (self.idiom_files_set)
                try self.cur_idiom_files.toOwnedSlice(allocator)
            else
                &IdiomRule.default_files,
            .allow = try self.cur_idiom_allow.toOwnedSlice(allocator),
            .reason = reason,
        });
    }

    /// The three `[[idiom]]` completeness rules that need a name to report
    /// against, split out so `flushIdiom` stays one straight-line append.
    /// Returns the validated `reason` so the required key is proven present by
    /// the value that flows into the rule, not by an `unreachable` after a
    /// separate check.
    fn idiomReason(
        self: *ParseState,
        allocator: Allocator,
        name: []const u8,
        diag: *Diagnostic,
    ) ParseError![]const u8 {
        if (self.cur_fragments.items.len == 0) {
            try setDiag(
                allocator,
                diag,
                self.array_line,
                "incomplete [[idiom]] '{s}': needs a non-empty 'fragments' array",
                .{name},
            );
            return error.IncompleteTable;
        }
        if (self.idiom_files_set and self.cur_idiom_files.items.len == 0) {
            try setDiag(
                allocator,
                diag,
                self.array_line,
                "incomplete [[idiom]] '{s}': 'files' must not be empty (omit the key for the default src/*.zig)",
                .{name},
            );
            return error.IncompleteTable;
        }
        return self.cur_reason orelse {
            try setDiag(
                allocator,
                diag,
                self.array_line,
                "incomplete [[idiom]] '{s}': missing required key 'reason' (name the canonical helper)",
                .{name},
            );
            return error.IncompleteTable;
        };
    }

    /// Closes a `[[layering]]` entry. Four ways to be inert are refused rather
    /// than stored, because each reads in the config like a declared
    /// architecture while declaring nothing: no `name` (the violation and the
    /// `<rule>|<from>|<to>` baseline key are built from it), no `from` and no
    /// `to` (the rule matches no edge in either direction), no `reason` (the
    /// violation would name a forbidden import with no statement of which way
    /// the layer points), and a `name` a previous entry already used (two rules
    /// under one name would share — and silently freeze with — each other's
    /// baseline keys).
    fn flushLayering(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        const name = self.cur_layering_name orelse {
            try setDiag(allocator, diag, self.array_line, "incomplete [[layering]]: missing required key 'name'", .{});
            return error.IncompleteTable;
        };
        try self.requireLayeringRule(allocator, name, diag);
        for (self.layerings.items) |existing| {
            if (!std.mem.eql(u8, existing.name, name)) continue;
            try setDiag(allocator, diag, self.array_line, "duplicate [[layering]] name '{s}'", .{name});
            return error.InvalidConfig;
        }
        try self.layerings.append(allocator, .{
            .name = name,
            .from = try self.cur_from.toOwnedSlice(allocator),
            .to = try self.cur_to.toOwnedSlice(allocator),
            .allow = try self.cur_layering_allow.toOwnedSlice(allocator),
            .reason = self.cur_reason.?,
        });
    }

    /// Names the first missing required key of the `[[layering]]` entry being
    /// closed, or returns cleanly when `from`, `to` and `reason` are all there.
    fn requireLayeringRule(
        self: *const ParseState,
        allocator: Allocator,
        name: []const u8,
        diag: *Diagnostic,
    ) ParseError!void {
        const missing: ?[]const u8 = if (self.cur_from.items.len == 0)
            "'from' must be a non-empty string array"
        else if (self.cur_to.items.len == 0)
            "'to' must be a non-empty string array"
        else if (self.cur_reason == null)
            "missing required key 'reason'"
        else
            null;
        const detail = missing orelse return;
        try setDiag(allocator, diag, self.array_line, "incomplete [[layering]] '{s}': {s}", .{ name, detail });
        return error.IncompleteTable;
    }

    /// Closes a `[[twin]]` entry, refusing the same three ways to be inert the
    /// concept table refuses — plus the one specific to this table: fewer than
    /// two `surfaces`. A single-surface entry is a capability, not a twin;
    /// there is no second implementation for a parity test to compare against,
    /// so storing it would put a row in the coverage ratchet that no test could
    /// ever legitimately close.
    fn flushTwin(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        const name = self.cur_twin_name orelse {
            try setDiag(allocator, diag, self.array_line, "incomplete [[twin]]: missing required key 'name'", .{});
            return error.IncompleteTable;
        };
        if (self.cur_surfaces.items.len < min_surfaces) {
            try setDiag(
                allocator,
                diag,
                self.array_line,
                "incomplete [[twin]] '{s}': 'surfaces' needs at least {d} entries " ++
                    "(one surface is a capability, not a twin)",
                .{ name, min_surfaces },
            );
            return error.IncompleteTable;
        }
        for (self.twins.items) |existing| {
            if (!std.mem.eql(u8, existing.name, name)) continue;
            try setDiag(allocator, diag, self.array_line, "duplicate [[twin]] name '{s}'", .{name});
            return error.InvalidConfig;
        }
        try self.twins.append(allocator, .{
            .name = name,
            .surfaces = try self.cur_surfaces.toOwnedSlice(allocator),
            .parity_test = self.cur_parity_test,
        });
    }

    /// Closes a `[[dead_model_field]]` entry. Every way to be inert is refused,
    /// because each reads in the config like an enforced contract while checking
    /// nothing: no `struct` (the finding and its `<struct>|<field>` baseline key
    /// are built from it), no `output` (nothing surfaces a field, so nothing can
    /// be "surfaced but unenforced"), neither `fields` nor `owner` (no field set
    /// to check and no file to discover one from), and a `struct` a previous
    /// entry already named (two rules under one struct would share, and silently
    /// freeze with, each other's baseline keys). An empty `logic` is allowed: a
    /// project may legitimately assert that NONE of a struct's surfaced fields
    /// are enforced yet.
    fn flushDeadModelField(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        const name = self.cur_dmf_struct orelse {
            try setDiag(allocator, diag, self.array_line, "incomplete [[dead_model_field]]: missing required key 'struct'", .{});
            return error.IncompleteTable;
        };
        try self.requireDeadModelFieldRule(allocator, name, diag);
        for (self.dead_model_fields.items) |existing| {
            if (!std.mem.eql(u8, existing.struct_name, name)) continue;
            try setDiag(allocator, diag, self.array_line, "duplicate [[dead_model_field]] struct '{s}'", .{name});
            return error.InvalidConfig;
        }
        try self.dead_model_fields.append(allocator, .{
            .struct_name = name,
            .owner = self.cur_dmf_owner,
            .fields = try self.cur_dmf_fields.toOwnedSlice(allocator),
            .output = try self.cur_dmf_output.toOwnedSlice(allocator),
            .logic = try self.cur_dmf_logic.toOwnedSlice(allocator),
            .reason = self.cur_reason,
        });
    }

    /// Names the first missing required half of the `[[dead_model_field]]` entry
    /// being closed: a non-empty `output`, and a field set — either an explicit
    /// `fields` list or an `owner` to discover one from.
    fn requireDeadModelFieldRule(
        self: *const ParseState,
        allocator: Allocator,
        name: []const u8,
        diag: *Diagnostic,
    ) ParseError!void {
        const missing: ?[]const u8 = if (self.cur_dmf_output.items.len == 0)
            "'output' must be a non-empty string array (the render/review globs)"
        else if (self.cur_dmf_fields.items.len == 0 and self.cur_dmf_owner == null)
            "needs an explicit 'fields' array or an 'owner' file to discover fields from"
        else
            null;
        const detail = missing orelse return;
        try setDiag(allocator, diag, self.array_line, "incomplete [[dead_model_field]] '{s}': {s}", .{ name, detail });
        return error.IncompleteTable;
    }

    fn setDeadModelFieldKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "struct")) {
            self.cur_dmf_struct = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "owner")) {
            self.cur_dmf_owner = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "fields")) {
            self.cur_dmf_fields = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "output")) {
            self.cur_dmf_output = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "logic")) {
            self.cur_dmf_logic = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "reason")) {
            self.cur_reason = try parseStringAlloc(allocator, kv.val);
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
        self.cur_chain = .empty;
        self.cur_ban_paths = .empty;
        self.cur_ban_allow = .empty;
        self.cur_reason = null;
        self.cur_concept_name = null;
        self.cur_literals = .empty;
        self.cur_patterns = .empty;
        self.cur_owner = .empty;
        self.cur_concept_files = .empty;
        self.cur_idiom_name = null;
        self.cur_fragments = .empty;
        self.cur_idiom_files = .empty;
        self.cur_idiom_allow = .empty;
        self.cur_shadow_const = null;
        self.cur_shadow_files = .empty;
        self.cur_shadow_ignore = .empty;
        self.cur_layering_name = null;
        self.cur_from = .empty;
        self.cur_to = .empty;
        self.cur_layering_allow = .empty;
        self.cur_require_in = .empty;
        self.cur_literals_from = null;
        self.cur_twin_name = null;
        self.cur_surfaces = .empty;
        self.cur_parity_test = null;
        self.cur_dmf_struct = null;
        self.cur_dmf_owner = null;
        self.cur_dmf_fields = .empty;
        self.cur_dmf_output = .empty;
        self.cur_dmf_logic = .empty;
        self.cur_name = null;
        self.cur_command = .empty;
        self.cur_inputs = .empty;
        self.cur_external_paths = .empty;
        self.cur_benchmark = null;
        self.cur_max_regression_pct = 25;
        self.cur_external_timeout_secs = 0;
        self.cur_max_rss_mib = 0;
        self.boundary_forbidden_set = false;
        self.allow_paths_set = false;
        self.idiom_files_set = false;
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
            .ban => try self.setBanKey(allocator, kv),
            .concept => try self.setConceptKey(allocator, kv),
            .idiom => try self.setIdiomKey(allocator, kv),
            .shadow => try self.setShadowKey(allocator, kv),
            .layering => try self.setLayeringKey(allocator, kv),
            .twin => try self.setTwinKey(allocator, kv),
            .dead_model_field => try self.setDeadModelFieldKey(allocator, kv),
            .external => try self.setExternalKey(allocator, kv),
            .none => {},
        }
    }

    fn setBoundaryKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "module")) {
            self.cur_module = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "forbidden")) {
            self.cur_forbidden = try parseStringArray(allocator, kv.val);
            self.boundary_forbidden_set = true;
        }
    }

    fn setAllowKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "check")) {
            self.cur_check = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "paths")) {
            self.cur_paths = try parseStringArray(allocator, kv.val);
            self.allow_paths_set = true;
        }
    }

    fn setBanKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "chain")) {
            self.cur_chain = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "paths")) {
            self.cur_ban_paths = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "allow")) {
            self.cur_ban_allow = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "reason")) {
            self.cur_reason = try parseStringAlloc(allocator, kv.val);
        }
    }

    fn setConceptKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "name")) {
            self.cur_concept_name = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, literals_key)) {
            self.cur_literals = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, patterns_key)) {
            self.cur_patterns = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, owner_key)) {
            self.cur_owner = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "files")) {
            self.cur_concept_files = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, require_in_key)) {
            self.cur_require_in = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, literals_from_key)) {
            self.cur_literals_from = try parseLiteralsFrom(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "reason")) {
            self.cur_reason = try parseStringAlloc(allocator, kv.val);
        }
    }

    fn setIdiomKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "name")) {
            self.cur_idiom_name = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, fragments_key)) {
            self.cur_fragments = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "files")) {
            self.cur_idiom_files = try parseStringArray(allocator, kv.val);
            self.idiom_files_set = true;
        } else if (std.mem.eql(u8, kv.key, "allow")) {
            self.cur_idiom_allow = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "reason")) {
            self.cur_reason = try parseStringAlloc(allocator, kv.val);
        }
    }

    /// Closes a `[[shadow]]` entry. A missing `const` is refused: the rule's
    /// whole subject is the constant it names, and it is also the baseline key
    /// every finding is frozen under, so an entry without one would sit in the
    /// config looking like a guarantee about nothing. A SECOND rule naming the
    /// same constant is refused for the identity reason `[[concept]]` refuses a
    /// duplicate name: findings are keyed `<const>|<file>`, so two rules under
    /// one referent would share — and silently freeze with — one set of keys.
    fn flushShadow(self: *ParseState, allocator: Allocator, diag: *Diagnostic) ParseError!void {
        const referent = self.cur_shadow_const orelse {
            try setDiag(allocator, diag, self.array_line, "incomplete [[shadow]]: missing required key 'const'", .{});
            return error.IncompleteTable;
        };
        for (self.shadows.items) |existing| {
            if (!std.mem.eql(u8, existing.const_ref, referent)) continue;
            try setDiag(allocator, diag, self.array_line, "duplicate [[shadow]] const '{s}'", .{referent});
            return error.InvalidConfig;
        }
        try self.shadows.append(allocator, .{
            .const_ref = referent,
            .files = try self.cur_shadow_files.toOwnedSlice(allocator),
            .ignore = try self.cur_shadow_ignore.toOwnedSlice(allocator),
            .reason = self.cur_reason,
        });
    }

    fn setShadowKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, shadow_const_key)) {
            self.cur_shadow_const = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "files")) {
            self.cur_shadow_files = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "ignore")) {
            self.cur_shadow_ignore = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "reason")) {
            self.cur_reason = try parseStringAlloc(allocator, kv.val);
        }
    }

    fn setLayeringKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "name")) {
            self.cur_layering_name = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, from_key)) {
            self.cur_from = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, to_key)) {
            self.cur_to = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "allow")) {
            self.cur_layering_allow = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "reason")) {
            self.cur_reason = try parseStringAlloc(allocator, kv.val);
        }
    }

    fn setTwinKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "name")) {
            self.cur_twin_name = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, surfaces_key)) {
            self.cur_surfaces = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, parity_test_key)) {
            self.cur_parity_test = try parseStringAlloc(allocator, kv.val);
        }
    }

    fn setExternalKey(self: *ParseState, allocator: Allocator, kv: KeyVal) Allocator.Error!void {
        if (std.mem.eql(u8, kv.key, "name")) {
            self.cur_name = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "command")) {
            self.cur_command = try parseStringArray(allocator, kv.val);
            self.external_command_set = true;
        } else if (std.mem.eql(u8, kv.key, "inputs")) {
            self.cur_inputs = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "paths")) {
            self.cur_external_paths = try parseStringArray(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, benchmark_key)) {
            self.cur_benchmark = try parseStringAlloc(allocator, kv.val);
        } else if (std.mem.eql(u8, kv.key, "max_regression_pct")) {
            self.cur_max_regression_pct = parseU32(kv.val, self.cur_max_regression_pct);
        } else if (std.mem.eql(u8, kv.key, timeout_secs_key)) {
            self.cur_external_timeout_secs = parseU32(kv.val, self.cur_external_timeout_secs);
        } else if (std.mem.eql(u8, kv.key, "max_rss_mib")) {
            self.cur_max_rss_mib = parseU32(kv.val, self.cur_max_rss_mib);
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
    if (std.mem.eql(u8, name, "ban")) return .ban;
    if (std.mem.eql(u8, name, "concept")) return .concept;
    if (std.mem.eql(u8, name, "idiom")) return .idiom;
    if (std.mem.eql(u8, name, "shadow")) return .shadow;
    if (std.mem.eql(u8, name, "layering")) return .layering;
    if (std.mem.eql(u8, name, "twin")) return .twin;
    if (std.mem.eql(u8, name, "dead_model_field")) return .dead_model_field;
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
            // Parsed strings are borrowed slices of the buffer they came from,
            // and this one is REUSED for the next multiline value — so hand the
            // parser a stable copy. Without it, a config with two multiline
            // arrays silently reads the second one's bytes through the first
            // one's slices (caught by the [[ban]] chain/paths regression test).
            const stable = try allocator.dupe(u8, pending.items);
            try parseLine(allocator, &cfg, &st, stable, pending_line, diag);
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
    cfg.ban_rules = try st.bans.toOwnedSlice(allocator);
    cfg.concept_rules = try st.concepts.toOwnedSlice(allocator);
    cfg.idiom_rules = try st.idioms.toOwnedSlice(allocator);
    cfg.shadow_rules = try st.shadows.toOwnedSlice(allocator);
    cfg.layering_rules = try st.layerings.toOwnedSlice(allocator);
    cfg.twin_rules = try st.twins.toOwnedSlice(allocator);
    cfg.dead_model_field_rules = try st.dead_model_fields.toOwnedSlice(allocator);
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

const ValueKind = enum { boolean, unsigned, float, string, string_array, inline_table };

/// The value shape of one `[[array-table]]` key. Split out of `valueKind` so
/// the two halves — array tables and `[section]`s — each stay inside the
/// complexity cap as entries are added to either.
fn arrayValueKind(kind: ArrayKind, key: []const u8) ValueKind {
    return switch (kind) {
        .boundary => if (key[0] == 'm') .string else .string_array,
        .allow => if (key[0] == 'c') .string else .string_array,
        // chain / paths / allow are arrays; only `reason` is prose.
        .ban => if (key[0] == 'r') .string else .string_array,
        // Spelled out rather than branched on a first character: `require_in`
        // and `reason` share an `r`, and `literals` / `literals_from` share
        // four — the shape that made the shorthand readable is gone.
        .concept => if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "reason"))
            .string
        else if (std.mem.eql(u8, key, literals_from_key))
            .inline_table
        else
            .string_array,
        // fragments / files / allow are arrays; name and reason are prose.
        .idiom => if (key[0] == 'n' or key[0] == 'r') .string else .string_array,
        // files / ignore are arrays; const (the referent) and reason are prose.
        .shadow => if (key[0] == 'c' or key[0] == 'r') .string else .string_array,
        // from / to / allow are arrays; name and reason are prose.
        .layering => if (key[0] == 'n' or key[0] == 'r') .string else .string_array,
        // name / parity_test are prose; surfaces is an array.
        .twin => if (std.mem.eql(u8, key, surfaces_key)) .string_array else .string,
        // struct / owner / reason are prose; fields / output / logic are arrays.
        .dead_model_field => if (std.mem.eql(u8, key, "struct") or
            std.mem.eql(u8, key, "owner") or std.mem.eql(u8, key, "reason"))
            .string
        else
            .string_array,
        .external => externalValueKind(key),
        .none => .string_array,
    };
}

/// The value shape of one `[[external]]` key: two prose keys, three arrays, and
/// counts for the rest.
fn externalValueKind(key: []const u8) ValueKind {
    if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, benchmark_key)) return .string;
    if (std.mem.eql(u8, key, "command") or std.mem.eql(u8, key, "inputs")) return .string_array;
    if (std.mem.eql(u8, key, "paths")) return .string_array;
    return .unsigned;
}

/// The value shape of one `[shadowed_const]` key: `mode` is prose, the two
/// digit floors are counts, `ignore_values` is an array — so `mode` is matched
/// whole before the shared `m` prefix could claim it.
fn shadowedConstValueKind(key: []const u8) ValueKind {
    if (std.mem.eql(u8, key, mode_key)) return .string;
    return if (key[0] == 'm') .unsigned else .string_array;
}

/// The value shape of one `[twin_drift]` key. `min_similarity` is the only
/// fractional setting in the whole config, and it shares its `m` prefix with
/// two counts, so it is matched whole before the prefix branch can claim it.
fn twinDriftValueKind(key: []const u8) ValueKind {
    if (std.mem.eql(u8, key, min_similarity_key)) return .float;
    return switch (key[0]) {
        'm' => .unsigned,
        'r' => .boolean,
        else => .string_array,
    };
}

/// Returns the value shape from the already-validated section/key position.
/// The first-character branches are unambiguous within each section and avoid
/// maintaining a third duplicate list of every supported key.
fn valueKind(st: *const ParseState, key: []const u8) ValueKind {
    if (st.array_kind != .none) return arrayValueKind(st.array_kind, key);
    return switch (st.section) {
        .top => switch (key[0]) {
            's' => .string,
            'h', 'm' => .unsigned,
            'c', 'p' => .boolean,
            else => .string_array,
        },
        .spec_quality,
        .orphan_files,
        .test_reachability,
        .test_coverage,
        .completeness,
        => if (key[1] == 'n') .boolean else .string_array,
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
        // enabled / recover_pct / checks.
        .hysteresis => switch (key[0]) {
            'e' => .boolean,
            'r' => .unsigned,
            else => .string_array,
        },
        .retired_check, .oom_discipline, .dead_pub => .boolean,
        .module_doc_header => .unsigned,
        .change_classification => if (key[0] == 'a') .string else .boolean,
        .mutation => if (key[0] == 's') .string else .unsigned,
        .benchmark => .string_array,
        .dora => if (key[0] == 'e') .boolean else .string,
        .fuzz_presence, .concurrency_presence, .script_string_safety => .string_array,
        .int_from_float, .measurement, .twin_referent => .string_array,
        // `mode` is prose; `ignore_names` is an array.
        .divergent_const => if (key[0] == 'm') .string else .string_array,
        .shadowed_const => shadowedConstValueKind(key),
        .twin_drift => twinDriftValueKind(key),
        .policy => if (std.mem.eql(u8, key, "profile") or std.mem.eql(u8, key, lock_against_key))
            .string
        else if (std.mem.eql(u8, key, lock_enabled_key))
            .boolean
        else
            .string_array,
        .doctor => .unsigned,
        // on_build / test_command are strings; install_hook is a bool.
        .gate => if (key[0] == 'i') .boolean else .string,
        .test_filter => .string,
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
        .float => std.fmt.parseFloat(f64, kv.val) catch null != null,
        .string => isValidString(kv.val),
        .string_array => isValidStringArray(kv.val),
        // Shape only here (is it a `{ … }` at all); the per-key rules are
        // `validateLiteralsFrom`'s, which needs to name the offending key.
        .inline_table => (try parseInlineTable(allocator, kv.val)) != null,
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

    if (st.array_kind == .none and st.section == .divergent_const and std.mem.eql(u8, kv.key, mode_key)) {
        const mode = parseString(kv.val).?;
        if (!std.mem.eql(u8, mode, units_mode) and !std.mem.eql(u8, mode, all_mode)) {
            try setDiag(allocator, diag, line_no, "invalid divergent_const mode '{s}' (want units or all)", .{mode});
            return error.InvalidValue;
        }
    }
    if (st.array_kind == .none and st.section == .shadowed_const and std.mem.eql(u8, kv.key, mode_key)) {
        const mode = parseString(kv.val).?;
        if (!std.mem.eql(u8, mode, declared_mode) and !std.mem.eql(u8, mode, auto_mode)) {
            try setDiag(allocator, diag, line_no, "invalid shadowed_const mode '{s}' (want declared or auto)", .{mode});
            return error.InvalidValue;
        }
    }
    if (st.array_kind == .none and st.section == .measurement) {
        try validateMeasurementPaths(allocator, kv, line_no, diag);
    }
    if (st.array_kind == .none and st.section == .hysteresis) {
        try validateHysteresis(allocator, kv, line_no, diag);
    }
    if (st.array_kind == .none and st.section == .twin_drift) {
        try validateTwinDrift(allocator, kv, line_no, diag);
    }
    if (st.array_kind == .ban) try validateBanChain(allocator, kv, line_no, diag);
    if (st.array_kind == .concept) {
        try validateRuleName(allocator, "concept", kv, line_no, diag);
        try validateLiteralsFrom(allocator, kv, line_no, diag);
    }
    if (st.array_kind == .idiom) try validateRuleName(allocator, "idiom", kv, line_no, diag);
    if (st.array_kind == .layering) try validateRuleName(allocator, "layering", kv, line_no, diag);
    if (st.array_kind == .twin) try validateRuleName(allocator, "twin", kv, line_no, diag);

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

/// Rejects a `[measurement] paths` entry that is not a plain project-relative
/// file or directory: a wildcard (the bridge matches by exact path or directory
/// prefix, never by glob or substring — see measurement.pathCovers), an
/// absolute path, or a `..` escape. Failing closed here matters more than
/// usual: a silently-inert entry would leave the operator believing
/// instrumentation is bridged when every finding still blocks.
fn validateMeasurementPaths(
    allocator: Allocator,
    kv: KeyVal,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (!std.mem.eql(u8, kv.key, measurement_paths_key)) return;
    for (try toStrings(allocator, kv.val)) |path| {
        if (isPlainRelativePath(path)) continue;
        try setDiag(
            allocator,
            diag,
            line_no,
            "invalid measurement path '{s}' (want a project-relative file or directory; no wildcards)",
            .{path},
        );
        return error.InvalidValue;
    }
}

/// Rejects a `[hysteresis]` setting the gate could not honor: a `recover_pct`
/// outside 1..90 (0 or 100+ would make the dead-band meaningless in one
/// direction or unreachable in the other), or a `checks` entry that is not one
/// of the two-tier hard-cap checks. Both fail closed at parse time with the
/// offending line, because the alternative is a setting that reads like a
/// policy and enforces nothing — the same reason an unknown `disabled` name
/// hard-fails.
fn validateHysteresis(
    allocator: Allocator,
    kv: KeyVal,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (std.mem.eql(u8, kv.key, recover_pct_key)) {
        const pct = std.fmt.parseInt(u32, kv.val, 10) catch {
            try setDiag(
                allocator,
                diag,
                line_no,
                "hysteresis recover_pct must be an integer in {d}..{d} (got '{s}')",
                .{ hysteresis.min_recover_pct, hysteresis.max_recover_pct, kv.val },
            );
            return error.InvalidValue;
        };
        if (pct >= hysteresis.min_recover_pct and pct <= hysteresis.max_recover_pct) return;
        try setDiag(
            allocator,
            diag,
            line_no,
            "hysteresis recover_pct {d} is outside {d}..{d}",
            .{ pct, hysteresis.min_recover_pct, hysteresis.max_recover_pct },
        );
        return error.InvalidValue;
    }
    if (!std.mem.eql(u8, kv.key, "checks")) return;
    for (try toStrings(allocator, kv.val)) |name| {
        if (hysteresis.isSupported(name)) continue;
        try setDiag(
            allocator,
            diag,
            line_no,
            "unknown hysteresis check '{s}' (only the two-tier hard-cap checks: {s})",
            .{ name, supported_hysteresis_checks },
        );
        return error.InvalidValue;
    }
}

/// Rejects a `[twin_drift]` setting the check could not honor: a
/// `min_similarity` outside the open interval (0, 1) — 0 pairs every function
/// with every same-named one and 1.0 asks for identical bodies, which is
/// `report_identical`'s job — or a `min_statements` under 2, which would pair
/// one-line bodies where agreement means nothing. Both fail closed at parse
/// time, because a threshold that silently means something else is worse than
/// no threshold.
fn validateTwinDrift(
    allocator: Allocator,
    kv: KeyVal,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (std.mem.eql(u8, kv.key, min_similarity_key)) {
        const share = std.fmt.parseFloat(f64, kv.val) catch return;
        if (share > 0 and share < 1) return;
        try setDiag(
            allocator,
            diag,
            line_no,
            "twin_drift min_similarity must be between 0 and 1 exclusive (got '{s}')",
            .{kv.val},
        );
        return error.InvalidValue;
    }
    if (!std.mem.eql(u8, kv.key, min_statements_key)) return;
    const floor = std.fmt.parseInt(u32, kv.val, 10) catch return;
    if (floor >= min_twin_statements) return;
    try setDiag(
        allocator,
        diag,
        line_no,
        "twin_drift min_statements must be at least {d} (got {d})",
        .{ min_twin_statements, floor },
    );
    return error.InvalidValue;
}

/// `hysteresis.supported` as one comma-joined string for the diagnostic above,
/// built at comptime from the list itself so it can never drift from it.
const supported_hysteresis_checks = blk: {
    var out: []const u8 = "";
    for (hysteresis.supported, 0..) |name, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ name;
    }
    break :blk out;
};

/// Rejects a `[[ban]] chain` segment that is not a bare identifier. The scanner
/// matches one identifier token per segment, so `chain = ["a.b"]` — the spelling
/// everyone reaches for first — would match nothing and sit in the config
/// looking like an enforced ban. Failing closed here is the difference between a
/// typo and a silently absent gate.
fn validateBanChain(
    allocator: Allocator,
    kv: KeyVal,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (!std.mem.eql(u8, kv.key, "chain")) return;
    for (try toStrings(allocator, kv.val)) |segment| {
        if (isIdentifier(segment)) continue;
        try setDiag(
            allocator,
            diag,
            line_no,
            "invalid ban chain segment '{s}' (one identifier per segment: chain = [\"a\", \"b\"] bans a.b)",
            .{segment},
        );
        return error.InvalidValue;
    }
}

/// Rejects a `[[concept]]` / `[[idiom]]` / `[[layering]]` `name` that is not
/// kebab-case. The name is what every violation says out loud and — as half of
/// the rule's baseline key (`<file>|<name>` for a concept, `<rule>|<file>` for
/// an idiom, `<name>|<from>|<to>` for a layering edge) — what a `.guardian/`
/// diff is read by, so it is an identifier a reader has to live with, not
/// free-form prose. `reason` is where prose belongs. `kind` names the array
/// table in the diagnostic, so the callers share one rule without sharing one
/// misleading message.
fn validateRuleName(
    allocator: Allocator,
    kind: []const u8,
    kv: KeyVal,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (!std.mem.eql(u8, kv.key, "name")) return;
    const name = parseString(kv.val) orelse return;
    if (isKebabCase(name)) return;
    try setDiag(
        allocator,
        diag,
        line_no,
        "invalid {s} name '{s}' (kebab-case: lowercase letters, digits and single inner '-')",
        .{ kind, name },
    );
    return error.InvalidValue;
}

/// Rejects a `[[concept]] literals_from` table the extraction could not use:
/// an unknown key, a missing or empty `file`, or a missing/empty `fragments`
/// list.
///
/// `fragments` is required, not defaulted to "match every line", because that
/// default would quietly enrol EVERY quoted string in the owner file — a
/// family so wide that every mirror fails and the rule gets disabled rather
/// than fixed. Failing here instead is the same fail-closed rule the rest of
/// this parser applies to a setting that would enforce the wrong thing.
fn validateLiteralsFrom(
    allocator: Allocator,
    kv: KeyVal,
    line_no: u32,
    diag: *Diagnostic,
) ParseError!void {
    if (!std.mem.eql(u8, kv.key, literals_from_key)) return;
    const pairs = (try parseInlineTable(allocator, kv.val)).?;
    var seen_file = false;
    var seen_fragments = false;
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, literals_from_file_key)) {
            seen_file = isValidString(pair.val) and
                std.mem.trim(u8, parseString(pair.val).?, &std.ascii.whitespace).len > 0;
            if (!seen_file) return literalsFromError(allocator, line_no, diag, "'file' must be a non-empty string");
        } else if (std.mem.eql(u8, pair.key, literals_from_fragments_key)) {
            seen_fragments = isValidStringArray(pair.val) and
                !hasEmptyArrayItem(pair.val) and
                (try toStrings(allocator, pair.val)).len > 0;
            if (!seen_fragments) {
                return literalsFromError(allocator, line_no, diag, "'fragments' must be a non-empty string array");
            }
        } else {
            try setDiag(
                allocator,
                diag,
                line_no,
                "unknown literals_from key '{s}' (want '{s}' and '{s}')",
                .{ pair.key, literals_from_file_key, literals_from_fragments_key },
            );
            return error.UnknownKey;
        }
    }
    if (!seen_file) return literalsFromError(allocator, line_no, diag, "missing required key 'file'");
    if (!seen_fragments) return literalsFromError(allocator, line_no, diag, "missing required key 'fragments'");
}

/// Fills the diagnostic for one malformed `literals_from` table and returns the
/// rejection, so each branch above stays a single line.
fn literalsFromError(
    allocator: Allocator,
    line_no: u32,
    diag: *Diagnostic,
    detail: []const u8,
) ParseError!void {
    try setDiag(allocator, diag, line_no, "invalid literals_from table: {s}", .{detail});
    return error.InvalidValue;
}

/// Reads a validated `literals_from` inline table into its config value. Null
/// only for a table `validateLiteralsFrom` already rejected — every caller runs
/// after validation, so this is the total-function guarantee, not a path.
fn parseLiteralsFrom(allocator: Allocator, val: []const u8) Allocator.Error!?LiteralsFrom {
    const pairs = (try parseInlineTable(allocator, val)) orelse return null;
    var file: ?[]const u8 = null;
    var fragments: []const []const u8 = &.{};
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, literals_from_file_key)) {
            file = try parseStringAlloc(allocator, pair.val);
        } else if (std.mem.eql(u8, pair.key, literals_from_fragments_key)) {
            fragments = try toStrings(allocator, pair.val);
        }
    }
    return .{ .file = file orelse return null, .fragments = fragments };
}

/// True when `text` is kebab-case: lowercase letters and digits separated by
/// single `-`, never leading, trailing, or doubled.
fn isKebabCase(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '-' or text[text.len - 1] == '-') return false;
    if (std.mem.indexOf(u8, text, "--") != null) return false;
    for (text) |c| {
        if (c == '-') continue;
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// True when `text` is a bare Zig identifier (leading letter or `_`, then
/// letters, digits, or `_`).
fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphabetic(text[0]) and text[0] != '_') return false;
    for (text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// True when `path` is a plain project-relative file or directory reference —
/// no wildcard, not absolute, no parent-directory escape.
fn isPlainRelativePath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '*') != null) return false;
    if (std.mem.startsWith(u8, path, "/")) return false;
    return std.mem.indexOf(u8, path, "..") == null;
}

fn noteMutationLine(lines: *MutationLines, key: []const u8, line_no: u32) void {
    inline for (@typeInfo(MutationLines).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, key, field_name)) @field(lines, field_name) = line_no;
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
        .orphan_files, .test_reachability => &.{ "enabled", "roots" },
        .doc_quality => &.{ "enabled", "min_chars", exempt_names_key },
        .type_size => &.{ "enabled", "max_fields", "exclude" },
        .function_length => &.{ "enabled", max_lines_key, hard_max_lines_key },
        .nesting_depth => &.{ "enabled", "max_depth" },
        .test_coverage => &.{ "enabled", exempt_names_key },
        .bool_ops => &.{ "enabled", "max_ops" },
        .line_length => &.{ "enabled", max_len_key, hard_max_len_key },
        .baseline => &.{ "enabled", "deny_growth" },
        .hysteresis => &.{ "enabled", recover_pct_key, "checks" },
        .retired_check, .oom_discipline => &.{"enabled"},
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
        .concurrency_presence => &.{"modules"},
        .script_string_safety => &.{"blob_files"},
        .int_from_float => &.{ "guard_fns", "require_guard" },
        .divergent_const => &.{ ignore_names_key, mode_key },
        .shadowed_const => &.{ mode_key, ignore_values_key, min_float_digits_key, min_int_digits_key },
        .twin_referent => &.{"ignore"},
        .twin_drift => &.{
            min_statements_key, min_similarity_key, report_identical_key,
            "ignore",           max_lines_key,
        },
        .measurement => &.{"paths"},
        .policy => &.{ "profile", "block", "ratchet", "report", lock_enabled_key, lock_against_key, "protected_paths" },
        .doctor => &.{ "zig_cache_warn_mib", "guardian_cache_warn_mib" },
        .gate => &.{ on_build_key, "test_command", "install_hook" },
        .test_filter => &.{"flag"},
        .unknown => &.{},
    };
}

/// Keys accepted inside a `[[boundary]]` / `[[allow]]` / `[[ban]]` /
/// `[[concept]]` / `[[layering]]` / `[[external]]` array-of-tables entry.
/// `[[concept]]` / `[[twin]]` / `[[external]]` array-of-tables entry.
fn validArrayKeys(kind: ArrayKind) []const []const u8 {
    return switch (kind) {
        .boundary => &.{ "module", "forbidden" },
        .allow => &.{ "check", "paths" },
        .ban => &.{ "chain", "paths", "allow", "reason" },
        .idiom => &.{ "name", fragments_key, "files", "allow", "reason" },
        .shadow => &.{ shadow_const_key, "files", "ignore", "reason" },
        .layering => &.{ "name", from_key, to_key, "allow", "reason" },
        .concept => &.{
            "name",  literals_key,   patterns_key,      owner_key,
            "files", require_in_key, literals_from_key, "reason",
        },
        .twin => &.{ "name", surfaces_key, parity_test_key },
        .dead_model_field => &.{ "struct", "owner", "fields", "output", "logic", "reason" },
        .external => &.{ "name", "command", "inputs", "paths", benchmark_key, "max_regression_pct", timeout_secs_key, "max_rss_mib" },
        .none => &.{},
    };
}

fn applySectionKey(ctx: ApplyCtx, section: Section, kv: KeyVal) Allocator.Error!void {
    switch (section) {
        .top => try applyTopLevelKey(ctx, kv),
        .spec_quality => try applyArrayCfg("spec_quality", "forbidden_phrases", ctx, kv),
        .orphan_files => try applyArrayCfg("orphan_files", "roots", ctx, kv),
        .test_reachability => try applyArrayCfg("test_reachability", "roots", ctx, kv),
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
        .hysteresis => try applyHysteresisKey(ctx, kv),
        .retired_check => {},
        .oom_discipline => applyEnabledCfg("oom_discipline", ctx, kv),
        .module_doc_header => applyModuleDocHeaderKey(ctx, kv),
        .dead_pub => applyBoolCfg("dead_pub", "ignore_test_refs", ctx, kv),
        .change_classification => applyChangeClassificationKey(ctx, kv),
        .mutation => applyMutationKey(ctx, kv),
        .benchmark => try applyBenchmarkKey(ctx, kv),
        .completeness => try applyCompletenessKey(ctx, kv),
        .dora => applyDoraKey(ctx, kv),
        .fuzz_presence => try applyFuzzPresenceKey(ctx, kv),
        .concurrency_presence => try applyConcurrencyPresenceKey(ctx, kv),
        .script_string_safety => try applyScriptStringSafetyKey(ctx, kv),
        .int_from_float => try applyIntFromFloatKey(ctx, kv),
        .divergent_const => try applyDivergentConstKey(ctx, kv),
        .shadowed_const => try applyShadowedConstKey(ctx, kv),
        .twin_referent => try applyTwinReferentKey(ctx, kv),
        .twin_drift => try applyTwinDriftKey(ctx, kv),
        .measurement => try applyMeasurementKey(ctx, kv),
        .policy => try config_policy.applyPolicy(ctx.allocator, ctx.cfg, kv.key, kv.val),
        .doctor => config_policy.applyDoctor(ctx.cfg, kv.key, kv.val),
        .gate => applyGateKey(ctx, kv),
        .test_filter => applyTestFilterKey(ctx, kv),
        .unknown => {},
    }
}

/// Applies the one `[test_filter]` key, `flag`: the compiler flag prefix the
/// read-only `test-filter` report emits before each derived test name.
fn applyTestFilterKey(ctx: ApplyCtx, kv: KeyVal) void {
    if (parseString(kv.val)) |v| ctx.cfg.test_filter.flag = v;
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
        .{ "test_reachability", Section.test_reachability },
        .{ "doc_quality", Section.doc_quality },
        .{ "type_size", Section.type_size },
        .{ "function_length", Section.function_length },
        .{ "nesting_depth", Section.nesting_depth },
        .{ "test_coverage", Section.test_coverage },
        .{ "bool_ops", Section.bool_ops },
        .{ "line_length", Section.line_length },
        .{ "baseline", Section.baseline },
        .{ "hysteresis", Section.hysteresis },
        .{ "stdout_flush", Section.retired_check },
        .{ "escape_discipline", Section.retired_check },
        .{ "magic_number", Section.retired_check },
        .{ "oom_discipline", Section.oom_discipline },
        .{ "module_doc_header", Section.module_doc_header },
        .{ "dead_pub", Section.dead_pub },
        .{ "change_classification", Section.change_classification },
        .{ "mutation", Section.mutation },
        .{ benchmark_key, Section.benchmark },
        .{ "completeness", Section.completeness },
        .{ "dora", Section.dora },
        .{ "fuzz_presence", Section.fuzz_presence },
        .{ "concurrency_presence", Section.concurrency_presence },
        .{ "script_string_safety", Section.script_string_safety },
        .{ "int_from_float", Section.int_from_float },
        .{ "divergent_const", Section.divergent_const },
        .{ "shadowed_const", Section.shadowed_const },
        .{ "twin_drift", Section.twin_drift },
        .{ "twin_referent", Section.twin_referent },
        .{ "measurement", Section.measurement },
        .{ "policy", Section.policy },
        .{ "doctor", Section.doctor },
        .{ "gate", Section.gate },
        .{ "test_filter", Section.test_filter },
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

/// Applies one `[hysteresis]` key. Both values are already range- and
/// name-checked by `validateHysteresis`, so nothing here can store a band the
/// gate would then have to defend against.
fn applyHysteresisKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.hysteresis;
    if (std.mem.eql(u8, kv.key, "enabled")) {
        g.enabled = parseBool(kv.val) orelse g.enabled;
    } else if (std.mem.eql(u8, kv.key, recover_pct_key)) {
        g.recover_pct = parseU32(kv.val, g.recover_pct);
    } else if (std.mem.eql(u8, kv.key, "checks")) {
        g.checks = try toStrings(ctx.allocator, kv.val);
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

/// Applies the `[concurrency_presence] modules` list — the files whose shared
/// mutable state must keep a test that spawns a second unit of execution.
fn applyConcurrencyPresenceKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    if (std.mem.eql(u8, kv.key, "modules")) {
        ctx.cfg.concurrency_presence.modules = try toStrings(ctx.allocator, kv.val);
    }
}

/// Applies the `[script_string_safety] blob_files` allowlist — the JSON/string
/// serializers whose output is embedded verbatim in an HTML `<script>` element.
fn applyScriptStringSafetyKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    if (std.mem.eql(u8, kv.key, "blob_files")) {
        ctx.cfg.script_string_safety.blob_files = try toStrings(ctx.allocator, kv.val);
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

/// Applies one `[divergent_const]` key: `ignore_names` (generic const names the
/// same-name-different-value rule skips) and `mode` (already value-checked
/// against the two spellings, so an unrecognized one cannot reach here).
fn applyDivergentConstKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.divergent_const;
    if (std.mem.eql(u8, kv.key, ignore_names_key)) {
        g.ignore_names = try toStrings(ctx.allocator, kv.val);
    } else if (std.mem.eql(u8, kv.key, mode_key)) {
        if (parseString(kv.val)) |v| g.mode = if (std.mem.eql(u8, v, all_mode)) .all else .units;
    }
}

/// Applies one `[shadowed_const]` key: `mode` (already value-checked against
/// the two spellings), the folded-compare `ignore_values` deny list, and the
/// two `auto`-mode significance floors.
fn applyShadowedConstKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.shadowed_const;
    if (std.mem.eql(u8, kv.key, mode_key)) {
        if (parseString(kv.val)) |v| g.mode = if (std.mem.eql(u8, v, auto_mode)) .auto else .declared;
    } else if (std.mem.eql(u8, kv.key, ignore_values_key)) {
        g.ignore_values = try toStrings(ctx.allocator, kv.val);
    } else if (std.mem.eql(u8, kv.key, min_float_digits_key)) {
        g.min_float_digits = parseU32(kv.val, g.min_float_digits);
    } else if (std.mem.eql(u8, kv.key, min_int_digits_key)) {
        g.min_int_digits = parseU32(kv.val, g.min_int_digits);
    }
}

/// Applies the `[twin_referent] ignore` globs — the per-claim silencer for the
/// "mirrors X / same as Y" comment scan.
fn applyTwinReferentKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    if (std.mem.eql(u8, kv.key, "ignore")) {
        ctx.cfg.twin_referent.ignore = try toStrings(ctx.allocator, kv.val);
    }
}

/// Applies one `[twin_drift]` key. Both thresholds are already range-checked by
/// `validateTwinDrift`, so a parse failure here is impossible rather than
/// tolerated.
fn applyTwinDriftKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    const g = &ctx.cfg.twin_drift;
    if (std.mem.eql(u8, kv.key, "ignore")) {
        g.ignore = try toStrings(ctx.allocator, kv.val);
    } else if (std.mem.eql(u8, kv.key, min_statements_key)) {
        g.min_statements = std.fmt.parseInt(u32, kv.val, 10) catch g.min_statements;
    } else if (std.mem.eql(u8, kv.key, min_similarity_key)) {
        g.min_similarity = std.fmt.parseFloat(f64, kv.val) catch g.min_similarity;
    } else if (std.mem.eql(u8, kv.key, max_lines_key)) {
        g.max_lines = std.fmt.parseInt(u32, kv.val, 10) catch g.max_lines;
    } else if (std.mem.eql(u8, kv.key, report_identical_key)) {
        g.report_identical = parseBool(kv.val) orelse g.report_identical;
    }
}

/// Applies the `[measurement] paths` allowlist — the instrumentation bridge's
/// file/directory list (see measurement.zig).
fn applyMeasurementKey(ctx: ApplyCtx, kv: KeyVal) Allocator.Error!void {
    if (std.mem.eql(u8, kv.key, measurement_paths_key)) {
        ctx.cfg.measurement.paths = try toStrings(ctx.allocator, kv.val);
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
        \\report = ["line-length"]
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
        \\paths = ["web/*.js"]
        \\benchmark = "javascript_syntax_wall_s"
        \\max_regression_pct = 30
        \\timeout_secs = 20
        \\max_rss_mib = 256
    );
    try std.testing.expect(cfg.policy.profile == .agent);
    try std.testing.expect(cfg.policy.lock_enabled);
    try std.testing.expectEqualStrings("origin/main", cfg.policy.lock_against);
    try std.testing.expectEqual(@as(u32, 8192), cfg.doctor.zig_cache_warn_mib);
    try std.testing.expectEqual(@as(usize, 1), cfg.external_gates.len);
    try std.testing.expectEqualStrings("node", cfg.external_gates[0].command[0]);
    try std.testing.expectEqualStrings("src/app.js", cfg.external_gates[0].inputs[0]);
    try std.testing.expectEqualStrings("web/*.js", cfg.external_gates[0].paths[0]);
    try std.testing.expectEqualStrings("javascript_syntax_wall_s", cfg.external_gates[0].benchmark.?);
    try std.testing.expectEqual(@as(u32, 30), cfg.external_gates[0].max_regression_pct);
    try std.testing.expectEqual(@as(u32, 20), cfg.external_gates[0].timeout_secs);
    try std.testing.expectEqual(@as(u32, 256), cfg.external_gates[0].max_rss_mib);
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

// spec: Configuration - Parses the test_filter flag spelling

test "parse test_filter flag defaults to the zig spelling and is overridable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqualStrings("-Dtest-filter=", defaults.test_filter.flag);

    const cfg = try parse(arena.allocator(),
        \\[test_filter]
        \\flag = "--filter="
    );
    try std.testing.expectEqualStrings("--filter=", cfg.test_filter.flag);
    // The flag lives in its own section and never touches the gate's suite.
    try std.testing.expectEqualStrings("zig build test", cfg.gate.test_command);
    // A typo in the section is a hard failure, not a silently ignored setting.
    try std.testing.expectError(error.UnknownKey, parse(arena.allocator(), "[test_filter]\nflags = \"-x\"\n"));
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

// spec: Ban - Parses ban entries with chain, paths, allow, and reason keys

test "parse ban array tables with every key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[[ban]]
        \\chain = ["optimizer", "placeFromPoses"]
        \\paths = ["src/serve/*"]
        \\allow = ["src/serve/route_seed.zig"]
        \\reason = "call through RouteSeed instead"
        \\
        \\[[ban]]
        \\chain = ["gethostbyname"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.ban_rules.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.ban_rules[0].chain.len);
    try std.testing.expectEqualStrings("placeFromPoses", cfg.ban_rules[0].chain[1]);
    try std.testing.expectEqualStrings("src/serve/*", cfg.ban_rules[0].paths[0]);
    try std.testing.expectEqualStrings("src/serve/route_seed.zig", cfg.ban_rules[0].allow[0]);
    try std.testing.expectEqualStrings("call through RouteSeed instead", cfg.ban_rules[0].reason.?);
    // The optional keys default to "everywhere, no exemptions, no reason".
    try std.testing.expectEqual(@as(usize, 0), cfg.ban_rules[1].paths.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.ban_rules[1].allow.len);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.ban_rules[1].reason);
}

// spec: Ban - Parses a multiline ban chain array with comments and trailing commas

test "parse a ban chain spread over several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A multiline array that silently parsed EMPTY would be the worst failure
    // this check can have: a rule that reads as an enforced ban while matching
    // nothing. Pin the multiline path for [[ban]] specifically.
    const cfg = try parse(arena.allocator(),
        \\[[ban]]
        \\chain = [
        \\  "optimizer", # the module
        \\  "placeFromPoses",
        \\]
        \\paths = [
        \\  "src/serve/*",
        \\  "src/api/*",
        \\]
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.ban_rules.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.ban_rules[0].chain.len);
    try std.testing.expectEqualStrings("optimizer", cfg.ban_rules[0].chain[0]);
    try std.testing.expectEqualStrings("placeFromPoses", cfg.ban_rules[0].chain[1]);
    try std.testing.expectEqual(@as(usize, 2), cfg.ban_rules[0].paths.len);
    try std.testing.expectEqualStrings("src/api/*", cfg.ban_rules[0].paths[1]);
}

// spec: Ban - Hard-fails a ban entry whose chain is missing or empty

test "parse rejects a ban entry with nothing to match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[[ban]]\npaths = [\"src/*\"]",
        "[[ban]]\nchain = []\nreason = \"nothing here\"",
    };
    for (cases) |content| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.IncompleteTable, parseInto(arena.allocator(), content, &diag));
        try std.testing.expectEqual(@as(u32, 1), diag.line);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, "chain") != null);
    }
}

// spec: Ban - Hard-fails a ban chain segment that is not a bare identifier

test "parse rejects a dotted ban chain segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // The spelling everyone tries first. It would match no token sequence at
    // all, so it fails closed and says how to split it.
    const content =
        \\[[ban]]
        \\chain = ["optimizer.placeFromPoses"]
    ;
    try std.testing.expectError(error.InvalidValue, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "one identifier per segment") != null);
}

// spec: Concept Ownership - Parses concept entries with name, literals, patterns, owner, files and reason keys

test "parse concept array tables with every key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[[concept]]
        \\name = "layer-names"
        \\literals = ["F.Cu", "B.Cu"]
        \\patterns = ["In*.Cu"]
        \\owner = ["src/board_layers.zig"]
        \\files = [
        \\  "src/*.zig", # the Zig side
        \\  "assets/*.css",
        \\]
        \\reason = "layer names come from board_layers.LayerTable"
        \\
        \\[[concept]]
        \\name = "gerber-suffixes"
        \\literals = ["-F_Cu.gbr"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.concept_rules.len);
    try std.testing.expectEqualStrings("layer-names", cfg.concept_rules[0].name);
    try std.testing.expectEqualStrings("B.Cu", cfg.concept_rules[0].literals[1]);
    try std.testing.expectEqualStrings("In*.Cu", cfg.concept_rules[0].patterns[0]);
    try std.testing.expectEqualStrings("src/board_layers.zig", cfg.concept_rules[0].owner[0]);
    try std.testing.expectEqual(@as(usize, 2), cfg.concept_rules[0].files.len);
    try std.testing.expectEqualStrings("assets/*.css", cfg.concept_rules[0].files[1]);
    try std.testing.expectEqualStrings(
        "layer names come from board_layers.LayerTable",
        cfg.concept_rules[0].reason.?,
    );
    // The optional keys default to "no patterns, no owner, the default source
    // scan, no reason" — literals alone is a complete rule.
    try std.testing.expectEqual(@as(usize, 0), cfg.concept_rules[1].patterns.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.concept_rules[1].owner.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.concept_rules[1].files.len);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.concept_rules[1].reason);
}

// spec: Concept Ownership - Hard-fails a concept entry that declares no name

test "parse rejects a concept entry with no name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content =
        \\[[concept]]
        \\literals = ["F.Cu"]
    ;
    try std.testing.expectError(error.IncompleteTable, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "'name'") != null);
}

// spec: Concept Ownership - Hard-fails a concept entry with neither literals nor patterns

test "parse rejects a concept entry with nothing to look for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // A rule with no spellings would sit in the config reading like an enforced
    // ownership guarantee while matching nothing at all.
    const content =
        \\[[concept]]
        \\name = "layer-names"
        \\owner = ["src/board_layers.zig"]
    ;
    try std.testing.expectError(error.IncompleteTable, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "layer-names") != null);
}

// spec: Concept Ownership - Hard-fails a second concept entry reusing an existing name

test "parse rejects a duplicate concept name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // Identity is `<file>|<name>`, so two rules under one name would share — and
    // silently freeze under — each other's baseline keys.
    const content =
        \\[[concept]]
        \\name = "layer-names"
        \\literals = ["F.Cu"]
        \\
        \\[[concept]]
        \\name = "layer-names"
        \\literals = ["B.Cu"]
    ;
    try std.testing.expectError(error.InvalidConfig, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 5), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "duplicate") != null);
}

// spec: Concept Ownership - Hard-fails a concept name that is not kebab-case

test "parse rejects a concept name that is not kebab-case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "[[concept]]\nname = \"Layer Names\"\nliterals = [\"F.Cu\"]",
        "[[concept]]\nname = \"layer_names\"\nliterals = [\"F.Cu\"]",
        "[[concept]]\nname = \"-layer\"\nliterals = [\"F.Cu\"]",
        "[[concept]]\nname = \"layer--names\"\nliterals = [\"F.Cu\"]",
    };
    for (cases) |content| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.InvalidValue, parseInto(arena.allocator(), content, &diag));
        try std.testing.expectEqual(@as(u32, 2), diag.line);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, "kebab-case") != null);
    }
    // Digits and single inner dashes are the accepted shape.
    const ok = try parse(arena.allocator(), "[[concept]]\nname = \"layer-2-names\"\nliterals = [\"F.Cu\"]");
    try std.testing.expectEqualStrings("layer-2-names", ok.concept_rules[0].name);
}

// spec: Canonical Idiom - Parses idiom entries with name, fragments, files, allow and reason keys

test "parse idiom array tables with every key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[[idiom]]
        \\name = "subblock-leaf-split"
        \\fragments = ["lastIndexOfScalar", "'/'"]
        \\files = ["src/*.zig", "tools/*.zig"]
        \\allow = ["src/subblock.zig"]
        \\reason = "call subblock.leafOf()"
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.idiom_rules.len);
    const rule = cfg.idiom_rules[0];
    try std.testing.expectEqualStrings("subblock-leaf-split", rule.name);
    try std.testing.expectEqual(@as(usize, 2), rule.fragments.len);
    try std.testing.expectEqualStrings("lastIndexOfScalar", rule.fragments[0]);
    try std.testing.expectEqualStrings("'/'", rule.fragments[1]);
    try std.testing.expectEqual(@as(usize, 2), rule.files.len);
    try std.testing.expectEqualStrings("tools/*.zig", rule.files[1]);
    try std.testing.expectEqualStrings("src/subblock.zig", rule.allow[0]);
    try std.testing.expectEqualStrings("call subblock.leafOf()", rule.reason);
}

// spec: Canonical Idiom - Defaults an idiom's scan set to the source tree when no files key is given

test "parse gives an idiom with no files key the default source scan set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[[idiom]]
        \\name = "atomic-write"
        \\fragments = ["makeTmp", "rename"]
        \\reason = "use atomic.writeFile"
    );
    // Guardian's `*` spans `/`, so this one pattern already means every .zig
    // file in the whole src subtree — a `**` spelling would not.
    try std.testing.expectEqual(@as(usize, 1), cfg.idiom_rules[0].files.len);
    try std.testing.expectEqualStrings("src/*.zig", cfg.idiom_rules[0].files[0]);
    try std.testing.expectEqual(@as(usize, 0), cfg.idiom_rules[0].allow.len);
}

// spec: Canonical Idiom - Hard-fails an idiom entry missing its name, fragments, reason, or naming an empty files set

test "parse rejects every inert shape of an idiom entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each of these reads in the config like an enforced rule and enforces
    // nothing, so each is a config error rather than a stored no-op.
    const cases = [_]struct { content: []const u8, want: []const u8 }{
        .{ .content = "[[idiom]]\nfragments = [\"a\"]\nreason = \"r\"", .want = "missing required key 'name'" },
        .{ .content = "[[idiom]]\nname = \"leaf\"\nreason = \"r\"", .want = "non-empty 'fragments' array" },
        .{ .content = "[[idiom]]\nname = \"leaf\"\nfragments = [\"a\"]", .want = "missing required key 'reason'" },
        .{
            .content = "[[idiom]]\nname = \"leaf\"\nfragments = [\"a\"]\nfiles = []\nreason = \"r\"",
            .want = "'files' must not be empty",
        },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.IncompleteTable, parseInto(a, case.content, &diag));
        try std.testing.expect(std.mem.indexOf(u8, diag.message, case.want) != null);
    }
    // An empty reason STRING is caught by the shared non-empty-string rule, so a
    // blank sign-off cannot stand in for the missing one either.
    var blank: Diagnostic = .{};
    const empty_reason = "[[idiom]]\nname = \"leaf\"\nfragments = [\"a\"]\nreason = \"\"";
    try std.testing.expectError(error.InvalidValue, parseInto(a, empty_reason, &blank));
}

// spec: Concept Ownership - Parses a concept entry's require_in globs and literals_from table

test "parse concept require_in and literals_from keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[[concept]]
        \\name = "drc-kinds"
        \\literals_from = { file = "src/drc/kind.zig", fragments = ["=> \"", "return \""] }
        \\owner = ["src/drc/kind.zig"]
        \\require_in = ["assets/viewer.js", "assets/*.css"]
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.concept_rules.len);
    // `literals_from` alone is a complete rule: the family is READ, so there is
    // nothing for `literals` to declare.
    try std.testing.expectEqual(@as(usize, 0), cfg.concept_rules[0].literals.len);
    try std.testing.expectEqualStrings("src/drc/kind.zig", cfg.concept_rules[0].literals_from.?.file);
    try std.testing.expectEqual(@as(usize, 2), cfg.concept_rules[0].literals_from.?.fragments.len);
    // The escape resolves, so a fragment can name the quote that OPENS the
    // literal — the whole point of anchoring on `=> "`.
    try std.testing.expectEqualStrings("=> \"", cfg.concept_rules[0].literals_from.?.fragments[0]);
    try std.testing.expectEqual(@as(usize, 2), cfg.concept_rules[0].require_in.len);
    try std.testing.expectEqualStrings("assets/viewer.js", cfg.concept_rules[0].require_in[0]);
    // Absent on a rule that declares neither.
    const bare = try parse(arena.allocator(), "[[concept]]\nname = \"x\"\nliterals = [\"F.Cu\"]");
    try std.testing.expectEqual(@as(usize, 0), bare.concept_rules[0].require_in.len);
    try std.testing.expect(bare.concept_rules[0].literals_from == null);
}

// spec: Concept Ownership - Hard-fails a malformed literals_from table

test "parse rejects a literals_from table the extraction could not use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const head = "[[concept]]\nname = \"drc-kinds\"\nliterals_from = ";
    const cases = [_]struct { text: []const u8, err: ParseError, needle: []const u8 }{
        // Not an inline table at all.
        .{ .text = "\"src/kind.zig\"", .err = error.InvalidValue, .needle = "literals_from" },
        // A key nobody reads is a setting the operator wrote and the gate
        // silently ignored.
        .{ .text = "{ path = \"src/kind.zig\", fragments = [\"x\"] }", .err = error.UnknownKey, .needle = "path" },
        .{ .text = "{ fragments = [\"x\"] }", .err = error.InvalidValue, .needle = "'file'" },
        // `fragments` is required rather than defaulted to "every line": that
        // default enrols every quoted string in the owner, which fails every
        // mirror and gets the rule deleted instead of fixed.
        .{ .text = "{ file = \"src/kind.zig\" }", .err = error.InvalidValue, .needle = "'fragments'" },
        .{ .text = "{ file = \"src/kind.zig\", fragments = [] }", .err = error.InvalidValue, .needle = "'fragments'" },
        .{ .text = "{ file = \"\", fragments = [\"x\"] }", .err = error.InvalidValue, .needle = "'file'" },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        const content = try std.mem.concat(arena.allocator(), u8, &.{ head, case.text });
        try std.testing.expectError(case.err, parseInto(arena.allocator(), content, &diag));
        try std.testing.expectEqual(@as(u32, 3), diag.line);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, case.needle) != null);
    }
}

// spec: Twin Parity - Parses twin entries with name, surfaces and parity_test keys

test "parse twin array tables with every key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[[twin]]
        \\name = "export-pdf"
        \\surfaces = [
        \\  "cli:export-pdf", # the CLI subcommand
        \\  "http:/api/schematic-pdf",
        \\  "mcp:export_pdf",
        \\]
        \\parity_test = "pdf export matches"
        \\
        \\[[twin]]
        \\name = "fab-package"
        \\surfaces = ["http:/api/pcb-gerbers", "cli:export-gerbers"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.twin_rules.len);
    try std.testing.expectEqualStrings("export-pdf", cfg.twin_rules[0].name);
    try std.testing.expectEqual(@as(usize, 3), cfg.twin_rules[0].surfaces.len);
    try std.testing.expectEqualStrings("http:/api/schematic-pdf", cfg.twin_rules[0].surfaces[1]);
    try std.testing.expectEqualStrings("pdf export matches", cfg.twin_rules[0].parity_test.?);
    // `parity_test` is optional: the row exists to be an uncovered one until a
    // test is written, which is what makes coverage a ratchet.
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.twin_rules[1].parity_test);
}

// spec: Twin Parity - Hard-fails a twin entry with no name or fewer than two surfaces

test "parse rejects a twin entry that is not a twin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { text: []const u8, err: ParseError, line: u32, needle: []const u8 }{
        .{ .text = "[[twin]]\nsurfaces = [\"a\", \"b\"]", .err = error.IncompleteTable, .line = 1, .needle = "'name'" },
        // One surface is a capability, not a twin: nothing can disagree with it,
        // so its coverage row could never be legitimately closed.
        .{
            .text = "[[twin]]\nname = \"export-pdf\"\nsurfaces = [\"cli:export-pdf\"]",
            .err = error.IncompleteTable,
            .line = 1,
            .needle = "at least 2",
        },
        .{ .text = "[[twin]]\nname = \"export-pdf\"", .err = error.IncompleteTable, .line = 1, .needle = "at least 2" },
        // An empty or non-kebab name is refused by the shared name rule, which
        // names the table it is in rather than saying "concept" from a [[twin]].
        .{
            .text = "[[twin]]\nname = \"\"\nsurfaces = [\"a\", \"b\"]",
            .err = error.InvalidValue,
            .line = 2,
            .needle = "invalid twin name",
        },
        .{
            .text = "[[twin]]\nname = \"Export PDF\"\nsurfaces = [\"a\", \"b\"]",
            .err = error.InvalidValue,
            .line = 2,
            .needle = "invalid twin name",
        },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(case.err, parseInto(arena.allocator(), case.text, &diag));
        try std.testing.expectEqual(case.line, diag.line);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, case.needle) != null);
    }
}

// spec: Canonical Idiom - Hard-fails a second idiom entry reusing an existing name

test "parse rejects a duplicate idiom name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // Identity is `<name>|<file>`, so two rules under one name would share — and
    // silently freeze with — the first one's baseline keys.
    const content =
        \\[[idiom]]
        \\name = "leaf-split"
        \\fragments = ["a"]
        \\reason = "first"
        \\
        \\[[idiom]]
        \\name = "leaf-split"
        \\fragments = ["b"]
        \\reason = "second"
    ;
    try std.testing.expectError(error.InvalidConfig, parseInto(arena.allocator(), content, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "duplicate [[idiom]] name") != null);
}

// spec: Canonical Idiom - Hard-fails an idiom name that is not kebab-case

test "parse rejects an idiom name that is not kebab-case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content = "[[idiom]]\nname = \"Leaf_Split\"\nfragments = [\"a\"]\nreason = \"r\"";
    try std.testing.expectError(error.InvalidValue, parseInto(arena.allocator(), content, &diag));
    // The shared kebab rule names the table it rejected, so the two callers
    // cannot hand a reader the wrong one.
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "invalid idiom name") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "kebab-case") != null);
}

// spec: Canonical Idiom - Names an unknown key inside an idiom entry

test "parse rejects an unknown key inside an idiom entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // `owner` is [[concept]]'s spelling of the same idea; naming it here is the
    // typo an adopting project actually makes, and a silently dropped key would
    // leave the rule enforcing something else than it reads like.
    const content = "[[idiom]]\nname = \"leaf\"\nfragments = [\"a\"]\nowner = [\"src/x.zig\"]\nreason = \"r\"";
    try std.testing.expectError(error.UnknownKey, parseInto(arena.allocator(), content, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "owner") != null);
}

/// One complete `[[layering]]` entry, reused by the tests below so the shape a
/// project actually writes is spelled once.
const layering_toml =
    \\[[layering]]
    \\name = "core-no-serve"
    \\from = ["src/kicad_pcb/*", "src/placement/*"]
    \\to = ["src/serve/*"]
    \\allow = ["src/kicad_pcb/serve_adapter.zig"]
    \\reason = "the format layer must not reach up into the web layer"
;

// spec: Import Layering - Parses layering entries with name, from, to, allow, and reason keys

test "parse layering array tables with every key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), layering_toml ++
        \\
        \\
        \\[[layering]]
        \\name = "leaf-no-cli"
        \\from = [
        \\  "src/ast/*", # the parse layer
        \\  "src/spec/*",
        \\]
        \\to = ["src/cli/"]
        \\reason = "leaves stay reusable"
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.layering_rules.len);
    const first = cfg.layering_rules[0];
    try std.testing.expectEqualStrings("core-no-serve", first.name);
    try std.testing.expectEqual(@as(usize, 2), first.from.len);
    try std.testing.expectEqualStrings("src/placement/*", first.from[1]);
    try std.testing.expectEqualStrings("src/serve/*", first.to[0]);
    try std.testing.expectEqualStrings("src/kicad_pcb/serve_adapter.zig", first.allow[0]);
    try std.testing.expectEqualStrings(
        "the format layer must not reach up into the web layer",
        first.reason,
    );
    // `allow` is the one optional key, and a multiline `from` (the shape a real
    // rule grows into) must not silently parse EMPTY — that would be a rule
    // reading as an enforced architecture while constraining nothing.
    const second = cfg.layering_rules[1];
    try std.testing.expectEqual(@as(usize, 0), second.allow.len);
    try std.testing.expectEqual(@as(usize, 2), second.from.len);
    try std.testing.expectEqualStrings("src/spec/*", second.from[1]);
}

// spec: Import Layering - Hard-fails a layering entry missing its name, from, to, or reason

test "parse rejects a layering entry that would enforce nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Each way of being incomplete reads in the config like a declared
    // architecture while declaring nothing, so all four fail closed and name
    // the key that is missing.
    const cases = [_]struct { toml: []const u8, names: []const u8 }{
        .{ .toml = "[[layering]]\nfrom = [\"src/a/*\"]\nto = [\"src/b/*\"]\nreason = \"r\"", .names = "name" },
        .{ .toml = "[[layering]]\nname = \"a-b\"\nto = [\"src/b/*\"]\nreason = \"r\"", .names = "'from'" },
        .{ .toml = "[[layering]]\nname = \"a-b\"\nfrom = [\"src/a/*\"]\nto = []\nreason = \"r\"", .names = "'to'" },
        .{ .toml = "[[layering]]\nname = \"a-b\"\nfrom = [\"src/a/*\"]\nto = [\"src/b/*\"]", .names = "'reason'" },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try std.testing.expectError(error.IncompleteTable, parseInto(arena.allocator(), case.toml, &diag));
        try std.testing.expectEqual(@as(u32, 1), diag.line);
        try std.testing.expect(std.mem.indexOf(u8, diag.message, case.names) != null);
    }
}

// spec: Import Layering - Hard-fails a second layering entry reusing an existing name

test "parse rejects a duplicate layering name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // Identity is `<name>|<from>|<to>`, so two rules under one name would share
    // — and silently freeze under — each other's baseline keys.
    const content = layering_toml ++ "\n\n" ++ layering_toml;
    try std.testing.expectError(error.InvalidConfig, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 8), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "duplicate") != null);
}

// spec: Import Layering - Hard-fails a layering name that is not kebab-case

test "parse rejects a layering name that is not kebab-case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // The name leads the baseline key and is what every violation says out
    // loud, so it is an identifier a `.guardian/` diff has to live with.
    const content = "[[layering]]\nname = \"Core No Serve\"\nfrom = [\"src/a/*\"]\nto = [\"src/b/*\"]\nreason = \"r\"";
    try std.testing.expectError(error.InvalidValue, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "invalid layering name") != null);
}

// spec: Twin Parity - Hard-fails a second twin entry reusing an existing name

test "parse rejects a duplicate twin name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    // The baseline key is built from the name, so two rows under one name would
    // share — and silently freeze under — each other's coverage record.
    const content =
        \\[[twin]]
        \\name = "export-pdf"
        \\surfaces = ["a", "b"]
        \\
        \\[[twin]]
        \\name = "export-pdf"
        \\surfaces = ["c", "d"]
    ;
    try std.testing.expectError(error.InvalidConfig, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 5), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "duplicate") != null);
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

// spec: Configuration - Parses the concurrency_presence modules list

test "parse [concurrency_presence] defaults empty and reads the modules list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: no modules configured, so the check is a no-op.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), defaults.concurrency_presence.modules.len);
    const cfg = try parse(arena.allocator(),
        \\[fuzz_presence]
        \\modules = ["src/walk.zig"]
        \\[concurrency_presence]
        \\modules = ["src/check_roi.zig", "src/store.zig"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.concurrency_presence.modules.len);
    try std.testing.expectEqualStrings("src/check_roi.zig", cfg.concurrency_presence.modules[0]);
    try std.testing.expectEqualStrings("src/store.zig", cfg.concurrency_presence.modules[1]);
    // Two same-shaped string-array sections in one file must not share storage:
    // the fuzz_presence/int_from_float pair once did, and one section silently
    // read the other's paths.
    try std.testing.expectEqual(@as(usize, 1), cfg.fuzz_presence.modules.len);
    try std.testing.expectEqualStrings("src/walk.zig", cfg.fuzz_presence.modules[0]);
}

// spec: Configuration - Parses the script_string_safety blob_files list

test "parse [script_string_safety] defaults empty and reads the blob_files list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), defaults.script_string_safety.blob_files.len);
    const cfg = try parse(arena.allocator(),
        \\[script_string_safety]
        \\blob_files = ["src/serve/pcb_part_json.zig", "src/power_integrity_json.zig"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.script_string_safety.blob_files.len);
    try std.testing.expectEqualStrings("src/serve/pcb_part_json.zig", cfg.script_string_safety.blob_files[0]);
}

// spec: Configuration - Parses the dead_model_field struct rule and rejects an incomplete one

test "parse [[dead_model_field]] reads a rule and refuses one with no field source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults = try parse(a, "");
    try std.testing.expectEqual(@as(usize, 0), defaults.dead_model_field_rules.len);
    const cfg = try parse(a,
        \\[[dead_model_field]]
        \\struct = "ElectricalDecl"
        \\owner = "src/eval/env.zig"
        \\fields = ["max_voltage"]
        \\output = ["src/review_json.zig", "src/render_html.zig"]
        \\logic = ["src/erc.zig", "src/checks.zig"]
        \\reason = "nothing checks it"
    );
    try std.testing.expectEqual(@as(usize, 1), cfg.dead_model_field_rules.len);
    const rule = cfg.dead_model_field_rules[0];
    try std.testing.expectEqualStrings("ElectricalDecl", rule.struct_name);
    try std.testing.expectEqualStrings("src/eval/env.zig", rule.owner.?);
    try std.testing.expectEqual(@as(usize, 1), rule.fields.len);
    try std.testing.expectEqual(@as(usize, 2), rule.output.len);
    // A rule with an output but no field source (neither fields nor owner) is
    // inert, so it is refused rather than silently checking nothing.
    try std.testing.expectError(error.IncompleteTable, parse(a,
        \\[[dead_model_field]]
        \\struct = "Foo"
        \\output = ["src/render.zig"]
    ));
    // A rule with a field source but no output can never surface anything.
    try std.testing.expectError(error.IncompleteTable, parse(a,
        \\[[dead_model_field]]
        \\struct = "Foo"
        \\fields = ["bar"]
    ));
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

// spec: Measurement Mode - Parses the measurement paths list and rejects a wildcard entry

test "parse [measurement] reads paths and refuses a glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Default: absent section = empty list = exactly today's behavior.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), defaults.measurement.paths.len);
    const cfg = try parse(arena.allocator(),
        \\[measurement]
        \\paths = ["src/placement/router.zig", "src/bench"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.measurement.paths.len);
    try std.testing.expectEqualStrings("src/placement/router.zig", cfg.measurement.paths[0]);
    try std.testing.expectEqualStrings("src/bench", cfg.measurement.paths[1]);
    // A wildcard would silently match nothing, so it is a hard config error
    // rather than an inert entry the operator believes is bridging something.
    try std.testing.expectError(error.InvalidValue, parse(arena.allocator(),
        \\[measurement]
        \\paths = ["src/*"]
    ));
    // Absolute paths and parent escapes are refused for the same reason.
    try std.testing.expectError(error.InvalidValue, parse(arena.allocator(),
        \\[measurement]
        \\paths = ["../other/src"]
    ));
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

test "retired per-check sections remain parse-compatible and are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(arena.allocator(),
        \\[stdout_flush]
        \\enabled = true
        \\[escape_discipline]
        \\enabled = false
        \\[magic_number]
        \\enabled = true
    );
}

// spec: Hysteresis - Parses the hysteresis section and defaults it on for the two volume caps

test "parse [hysteresis] and its defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\[hysteresis]
        \\enabled = false
        \\recover_pct = 35
        \\checks = ["file-size", "line-length"]
    ;
    const cfg = try parse(arena.allocator(), content);
    try std.testing.expect(!cfg.hysteresis.enabled);
    try std.testing.expectEqual(@as(u32, 35), cfg.hysteresis.recover_pct);
    try std.testing.expectEqual(@as(usize, 2), cfg.hysteresis.checks.len);
    try std.testing.expectEqualStrings("line-length", cfg.hysteresis.checks[1]);
    // Zero-config: on, a 20% band, and bound to the two volume caps that showed
    // the surfing. line-length is supported but opt-in.
    const defaults = try parse(arena.allocator(), "");
    try std.testing.expect(defaults.hysteresis.enabled);
    try std.testing.expectEqual(@as(u32, 20), defaults.hysteresis.recover_pct);
    try std.testing.expectEqual(@as(usize, 2), defaults.hysteresis.checks.len);
    try std.testing.expectEqualStrings("file-size", defaults.hysteresis.checks[0]);
    try std.testing.expectEqualStrings("function-length", defaults.hysteresis.checks[1]);
}

// spec: Hysteresis - Hard-fails a recover percentage out of range or a check that is not two-tier

test "parse rejects an out-of-range recover_pct and a non-two-tier check name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};

    // 0 would erase the dead-band (recover == cap, i.e. today's prune) and 100
    // would demand deleting the file, so both ends fail closed with the line.
    try std.testing.expectError(
        error.InvalidValue,
        parseInto(a, "[hysteresis]\nrecover_pct = 0\n", &diag),
    );
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "outside 1..90") != null);
    try std.testing.expectError(error.InvalidValue, parse(a, "[hysteresis]\nrecover_pct = 91\n"));
    try std.testing.expectError(error.InvalidValue, parse(a, "[hysteresis]\nrecover_pct = nope\n"));
    // The edges themselves are accepted.
    _ = try parse(a, "[hysteresis]\nrecover_pct = 1\n");
    _ = try parse(a, "[hysteresis]\nrecover_pct = 90\n");

    // A single-tier check gates AT its cap: there is no band for a trip to
    // live in, so listing one is a typo, not a policy — and a setting that
    // reads like a policy while enforcing nothing is the failure mode here.
    try std.testing.expectError(
        error.InvalidValue,
        parseInto(a, "[hysteresis]\nchecks = [\"type-size\"]\n", &diag),
    );
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "unknown hysteresis check 'type-size'") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "file-size, function-length, line-length") != null);
    try std.testing.expectError(error.InvalidValue, parse(a, "[hysteresis]\nchecks = [\"file-sizes\"]\n"));
    // An unknown key in the section is still an unknown key.
    try std.testing.expectError(error.UnknownKey, parse(a, "[hysteresis]\nrecover = 20\n"));
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
    const fs_allowed = cfg.extraAllowed("ban-fs");
    try std.testing.expectEqual(@as(usize, 2), fs_allowed.len);
    try std.testing.expectEqualStrings("src/walk*", fs_allowed[0]);
    try std.testing.expectEqualStrings("src/reporter.zig", cfg.extraAllowed("debug-print-ban")[0]);
    try std.testing.expectEqual(@as(usize, 0), cfg.extraAllowed("nonexistent").len);
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
    fs.cwd().deleteTree(dir) catch {};
    // A *directory* named guardian.toml exists but can't be read as a file.
    try fs.cwd().makePath(dir ++ "/guardian.toml");
    defer fs.cwd().deleteTree(dir) catch |e| std.log.warn("cfg cleanup: {s}", .{@errorName(e)});
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

// spec: Shadowed Const - Parses shadow entries with const, files, ignore and reason keys

test "parse shadow array tables with every key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\[[shadow]]
        \\const = "src/export_fab.zig.auto_outline_margin_mm"
        \\files = [
        \\  "src/placement/*.zig", # the pour side
        \\  "src/export_*.zig",
        \\]
        \\ignore = ["src/placement/vendor*"]
        \\reason = "the pour raster must follow the same Edge.Cuts outline"
        \\
        \\[[shadow]]
        \\const = "src/limits.zig.max_sidecar_bytes"
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.shadow_rules.len);
    try std.testing.expectEqualStrings(
        "src/export_fab.zig.auto_outline_margin_mm",
        cfg.shadow_rules[0].const_ref,
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.shadow_rules[0].files.len);
    try std.testing.expectEqualStrings("src/export_*.zig", cfg.shadow_rules[0].files[1]);
    try std.testing.expectEqualStrings("src/placement/vendor*", cfg.shadow_rules[0].ignore[0]);
    try std.testing.expectEqualStrings(
        "the pour raster must follow the same Edge.Cuts outline",
        cfg.shadow_rules[0].reason.?,
    );
    // Every optional key defaults to "scan every file, exempt none, no reason" —
    // the referent alone is a complete rule.
    try std.testing.expectEqual(@as(usize, 0), cfg.shadow_rules[1].files.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.shadow_rules[1].ignore.len);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.shadow_rules[1].reason);
}

// spec: Shadowed Const - Hard-fails a shadow entry that names no constant

test "parse rejects a shadow entry with no const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content =
        \\[[shadow]]
        \\files = ["src/*.zig"]
    ;
    try std.testing.expectError(error.IncompleteTable, parseInto(arena.allocator(), content, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "missing required key 'const'") != null);
}

// spec: Shadowed Const - Hard-fails a second shadow entry reusing an existing constant

test "parse rejects a duplicate shadow const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content =
        \\[[shadow]]
        \\const = "src/limits.zig.gap_mm"
        \\
        \\[[shadow]]
        \\const = "src/limits.zig.gap_mm"
    ;
    // Findings are keyed `<referent>|<file>`, so two rules under one referent
    // would share — and silently freeze with — one set of baseline keys.
    try std.testing.expectError(error.InvalidConfig, parseInto(arena.allocator(), content, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "duplicate [[shadow]] const") != null);
}

// spec: Shadowed Const - Parses the sweep mode, ignore values and digit floors

test "parse shadowed_const keys and default the mode to declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const default_cfg = try parse(a, "");
    try std.testing.expectEqual(config.ShadowedConstMode.declared, default_cfg.shadowed_const.mode);
    try std.testing.expectEqual(@as(u32, 2), default_cfg.shadowed_const.min_float_digits);
    try std.testing.expectEqual(@as(u32, 3), default_cfg.shadowed_const.min_int_digits);
    try std.testing.expectEqual(@as(usize, 8), default_cfg.shadowed_const.ignore_values.len);
    const cfg = try parse(a,
        \\[shadowed_const]
        \\mode = "auto"
        \\ignore_values = ["0", "1"]
        \\min_float_digits = 3
        \\min_int_digits = 4
    );
    try std.testing.expectEqual(config.ShadowedConstMode.auto, cfg.shadowed_const.mode);
    try std.testing.expectEqual(@as(usize, 2), cfg.shadowed_const.ignore_values.len);
    try std.testing.expectEqualStrings("1", cfg.shadowed_const.ignore_values[1]);
    try std.testing.expectEqual(@as(u32, 3), cfg.shadowed_const.min_float_digits);
    try std.testing.expectEqual(@as(u32, 4), cfg.shadowed_const.min_int_digits);
    // An explicitly empty list ignores nothing, rather than falling back to the
    // eight built-in spellings.
    const bare = try parse(a, "[shadowed_const]\nignore_values = []");
    try std.testing.expectEqual(@as(usize, 0), bare.shadowed_const.ignore_values.len);
}

// spec: Shadowed Const - Hard-fails a sweep mode that is neither declared nor auto

test "parse rejects an unknown shadowed_const mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content =
        \\[shadowed_const]
        \\mode = "everything"
    ;
    try std.testing.expectError(error.InvalidValue, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "want declared or auto") != null);
}

// spec: Divergent Const - Parses the ignore-names list and the grouping mode

test "parse divergent_const keys and default the mode to units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const default_cfg = try parse(a, "");
    try std.testing.expectEqual(config.DivergentConstMode.units, default_cfg.divergent_const.mode);
    try std.testing.expectEqual(@as(usize, 0), default_cfg.divergent_const.ignore_names.len);
    const cfg = try parse(a,
        \\[divergent_const]
        \\mode = "all"
        \\ignore_names = ["eps", "margin"]
    );
    try std.testing.expectEqual(config.DivergentConstMode.all, cfg.divergent_const.mode);
    try std.testing.expectEqual(@as(usize, 2), cfg.divergent_const.ignore_names.len);
    try std.testing.expectEqualStrings("margin", cfg.divergent_const.ignore_names[1]);
}

// spec: Twin Drift - Parses the twin-drift thresholds and defaults them

test "parse twin_drift keys and default the thresholds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const default_cfg = try parse(a, "");
    try std.testing.expectEqual(@as(u32, 8), default_cfg.twin_drift.min_statements);
    try std.testing.expectEqual(@as(f64, 0.6), default_cfg.twin_drift.min_similarity);
    try std.testing.expectEqual(@as(u32, 400), default_cfg.twin_drift.max_lines);
    try std.testing.expect(!default_cfg.twin_drift.report_identical);
    const cfg = try parse(a,
        \\[twin_drift]
        \\min_statements = 12
        \\min_similarity = 0.75
        \\report_identical = true
        \\max_lines = 250
        \\ignore = ["run", "deinit"]
    );
    try std.testing.expectEqual(@as(u32, 12), cfg.twin_drift.min_statements);
    try std.testing.expectEqual(@as(f64, 0.75), cfg.twin_drift.min_similarity);
    try std.testing.expectEqual(@as(u32, 250), cfg.twin_drift.max_lines);
    try std.testing.expect(cfg.twin_drift.report_identical);
    try std.testing.expectEqualStrings("deinit", cfg.twin_drift.ignore[1]);
}

// spec: Twin Drift - Hard-fails a similarity outside zero to one and an unknown key

test "parse rejects an out-of-range twin_drift threshold and an unknown key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidValue,
        parseInto(a, "[twin_drift]\nmin_similarity = 1.0\n", &diag),
    );
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "between 0 and 1 exclusive") != null);
    // 1.0 is `report_identical`'s subject and 0 pairs everything, so both ends
    // are closed; the interior and the statement floor are open.
    try std.testing.expectError(error.InvalidValue, parse(a, "[twin_drift]\nmin_similarity = 0\n"));
    try std.testing.expectError(error.InvalidValue, parse(a, "[twin_drift]\nmin_statements = 1\n"));
    try std.testing.expectError(error.UnknownKey, parse(a, "[twin_drift]\nmin_overlap = 0.5\n"));
    _ = try parse(a, "[twin_drift]\nmin_similarity = 0.99\nmin_statements = 2\n");
}

// spec: Divergent Const - Hard-fails a grouping mode that is neither units nor all

test "parse rejects an unknown divergent_const mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const content =
        \\[divergent_const]
        \\mode = "everything"
    ;
    try std.testing.expectError(error.InvalidValue, parseInto(arena.allocator(), content, &diag));
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "want units or all") != null);
}

// spec: Twin Referent - Parses the ignore globs

test "parse twin_referent ignore globs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, "")).twin_referent.ignore.len);
    const cfg = try parse(a,
        \\[twin_referent]
        \\ignore = ["src/vendor/*", "legacy.zig"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.twin_referent.ignore.len);
    try std.testing.expectEqualStrings("src/vendor/*", cfg.twin_referent.ignore[0]);
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
const fuzz_input_bytes = 64 * 1024;

/// One fuzz iteration for the guardian.toml parser: arbitrary input bytes must
/// never panic or overflow. A `ParseError` is a valid outcome — the invariant
/// under test is that rejecting input never fails open: whenever the parser
/// returns UnknownSection/UnknownKey it has also populated the diagnostic (a
/// non-zero line and a non-empty message), so a misconfigured gate always
/// reports where. OOM from a giant fuzzer input is not a parser bug.
fn fuzzParseInto(allocator: Allocator, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [fuzz_input_bytes]u8 = undefined;
    const input = input_buffer[0..smith.slice(&input_buffer)];
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
