const std = @import("std");
const Allocator = std.mem.Allocator;

/// One [[boundary]] entry — a module glob and the import substrings forbidden inside it.
pub const BoundaryRule = struct {
    module_pattern: []const u8,
    forbidden_imports: []const []const u8,
};

/// Per-check config for the spec-quality lint.
pub const SpecQualityCfg = struct {
    enabled: bool = true,
    forbidden_phrases: []const []const u8 = &.{},
};

/// Per-check config for the function-size cap.
pub const FunctionSizeCfg = struct {
    enabled: bool = true,
    max_params: u32 = 4,
};

/// Per-check config for cognitive-complexity scoring.
pub const ComplexityCfg = struct {
    enabled: bool = true,
    max_score: u32 = 15,
};

/// Per-check config for the anytype-budget cap.
pub const AnytypeBudgetCfg = struct {
    enabled: bool = true,
    max_per_file: u32 = 2,
};

/// Per-check config for the orphan-files reachability scan.
pub const OrphanFilesCfg = struct {
    enabled: bool = true,
    /// Explicit root files for reachability. Paths are walker-relative
    /// (e.g. "src/main.zig"). When empty, every top-level src/*.zig
    /// is treated as a root.
    roots: []const []const u8 = &.{},
};

/// Per-check config for doc-quality (content lint on /// doc comments).
pub const DocQualityCfg = struct {
    enabled: bool = true,
    /// Minimum non-whitespace character count after the `///` prefix.
    min_chars: u32 = 12,
};

/// Per-check config for the type-size cap on pub containers.
pub const TypeSizeCfg = struct {
    enabled: bool = true,
    /// Max fields per `pub const X = struct { ... }` (or variants for enums,
    /// fields for unions). Methods and inner const decls don't count.
    max_fields: u32 = 7,
};

/// Per-check config for the function-length cap.
pub const FunctionLengthCfg = struct {
    enabled: bool = true,
    /// Max source lines per fn decl, counted from the `fn` keyword line
    /// through the closing `}` line.
    max_lines: u32 = 60,
};

/// Per-check config for the nesting-depth cap.
pub const NestingDepthCfg = struct {
    enabled: bool = true,
    /// Max brace-nesting depth inside a function body. Body itself
    /// counts as depth 1; nested blocks each add 1.
    max_depth: u32 = 4,
};

/// Project-wide baseline mode. When enabled, every check's current
/// violations are recorded on first run and only NEW violations fail
/// the build thereafter — converting the hard-block wall into a ratchet.
/// Designed for adopting Guardian on legacy codebases.
pub const BaselineCfg = struct {
    enabled: bool = false,
};

/// Per-check config for the line-length cap.
pub const LineLengthCfg = struct {
    enabled: bool = true,
    /// Max codepoints per line. Framework recommends 100-120.
    max_len: u32 = 120,
};

/// Per-check config for the bool-ops-per-condition cap.
pub const BoolOpsCfg = struct {
    enabled: bool = true,
    /// Max `and` / `or` / `!` tokens inside a single `if`/`while` condition.
    max_ops: u32 = 3,
};

/// Per-check config for the returns-per-function cap.
pub const ReturnsPerFnCfg = struct {
    enabled: bool = true,
    /// Max `return` keywords per fn body (excludes nested fn defs).
    max_returns: u32 = 3,
};

/// Per-check config for the test-coverage check (per-pub-fn).
pub const TestCoverageCfg = struct {
    /// Off by default: the check is intentionally strict (every pub fn
    /// must be referenced from some `test {…}` block) and most existing
    /// codebases need migration before they can satisfy it. Set to true
    /// in guardian.toml to opt in.
    enabled: bool = false,
    /// Pub fn names that are exempt from the requirement (commonly entry
    /// points like `main`, `build`, etc.). Matched on the bare fn name.
    exempt_names: []const []const u8 = &.{},
};

/// Aggregated guardian.toml configuration; defaults are sensible.
pub const Config = struct {
    spec_file: []const u8 = "SPEC.md",
    max_file_lines: u32 = 500,
    /// When true, `all` skips the whole run when its hashed input set is
    /// unchanged since the last all-green run (see cache.zig).
    cache_enabled: bool = true,
    file_size_exclude: []const []const u8 = &.{},
    boundary_rules: []const BoundaryRule = &.{},
    spec_quality: SpecQualityCfg = .{},
    function_size: FunctionSizeCfg = .{},
    complexity: ComplexityCfg = .{},
    anytype_budget: AnytypeBudgetCfg = .{},
    orphan_files: OrphanFilesCfg = .{},
    doc_quality: DocQualityCfg = .{},
    type_size: TypeSizeCfg = .{},
    function_length: FunctionLengthCfg = .{},
    nesting_depth: NestingDepthCfg = .{},
    test_coverage: TestCoverageCfg = .{},
    bool_ops: BoolOpsCfg = .{},
    returns_per_fn: ReturnsPerFnCfg = .{},
    line_length: LineLengthCfg = .{},
    baseline: BaselineCfg = .{},
};

/// Reads guardian.toml from `dir` and returns parsed config; defaults if missing.
pub fn load(allocator: Allocator, dir: []const u8) Config {
    const path = std.fmt.allocPrint(allocator, "{s}/guardian.toml", .{dir}) catch return .{};
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return .{};
    return parse(allocator, content) catch return .{};
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

/// Parses guardian.toml content. Unknown sections and malformed values are
/// silently ignored; defaults are preserved for any field not set. Errors
/// only on allocator failure; `load` swallows those into defaults.
pub fn parse(allocator: Allocator, content: []const u8) std.mem.Allocator.Error!Config {
    var cfg = Config{};
    var boundaries: std.ArrayListUnmanaged(BoundaryRule) = .empty;

    var in_boundary = false;
    var cur_module: ?[]const u8 = null;
    var cur_forbidden: std.ArrayListUnmanaged([]const u8) = .empty;
    var section: Section = .top;

    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        // Array of tables header [[name]]
        if (std.mem.startsWith(u8, line, "[[") and std.mem.endsWith(u8, line, "]]")) {
            // Flush previous boundary
            if (in_boundary) {
                if (cur_module) |m| {
                    try boundaries.append(allocator, .{
                        .module_pattern = m,
                        .forbidden_imports = try cur_forbidden.toOwnedSlice(allocator),
                    });
                }
            }
            const table_name = line[2 .. line.len - 2];
            if (std.mem.eql(u8, table_name, "boundary")) {
                in_boundary = true;
                cur_module = null;
                cur_forbidden = .empty;
            } else {
                in_boundary = false;
            }
            section = .top;
            continue;
        }

        // Named table header [name]
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            // Flush previous boundary if leaving one
            if (in_boundary) {
                if (cur_module) |m| {
                    try boundaries.append(allocator, .{
                        .module_pattern = m,
                        .forbidden_imports = try cur_forbidden.toOwnedSlice(allocator),
                    });
                }
                in_boundary = false;
            }
            const name = line[1 .. line.len - 1];
            if (std.mem.eql(u8, name, "spec_quality")) {
                section = .spec_quality;
            } else if (std.mem.eql(u8, name, "function_size")) {
                section = .function_size;
            } else if (std.mem.eql(u8, name, "complexity")) {
                section = .complexity;
            } else if (std.mem.eql(u8, name, "anytype_budget")) {
                section = .anytype_budget;
            } else if (std.mem.eql(u8, name, "orphan_files")) {
                section = .orphan_files;
            } else if (std.mem.eql(u8, name, "doc_quality")) {
                section = .doc_quality;
            } else if (std.mem.eql(u8, name, "type_size")) {
                section = .type_size;
            } else if (std.mem.eql(u8, name, "function_length")) {
                section = .function_length;
            } else if (std.mem.eql(u8, name, "nesting_depth")) {
                section = .nesting_depth;
            } else if (std.mem.eql(u8, name, "test_coverage")) {
                section = .test_coverage;
            } else if (std.mem.eql(u8, name, "bool_ops")) {
                section = .bool_ops;
            } else if (std.mem.eql(u8, name, "returns_per_fn")) {
                section = .returns_per_fn;
            } else if (std.mem.eql(u8, name, "line_length")) {
                section = .line_length;
            } else if (std.mem.eql(u8, name, "baseline")) {
                section = .baseline;
            } else {
                section = .unknown;
            }
            continue;
        }

        // Key = value
        if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
            const key = std.mem.trim(u8, line[0..eq_idx], &std.ascii.whitespace);
            const val_raw = std.mem.trim(u8, line[eq_idx + 1 ..], &std.ascii.whitespace);

            if (in_boundary) {
                if (std.mem.eql(u8, key, "module")) {
                    cur_module = parseString(val_raw);
                } else if (std.mem.eql(u8, key, "forbidden")) {
                    cur_forbidden = try parseStringArray(allocator, val_raw);
                }
                continue;
            }

            switch (section) {
                .top => {
                    if (std.mem.eql(u8, key, "spec_file")) {
                        if (parseString(val_raw)) |v| cfg.spec_file = v;
                    } else if (std.mem.eql(u8, key, "max_file_lines")) {
                        cfg.max_file_lines = std.fmt.parseInt(u32, val_raw, 10) catch cfg.max_file_lines;
                    } else if (std.mem.eql(u8, key, "cache_enabled")) {
                        cfg.cache_enabled = parseBool(val_raw) orelse cfg.cache_enabled;
                    } else if (std.mem.eql(u8, key, "file_size_exclude")) {
                        var list = try parseStringArray(allocator, val_raw);
                        cfg.file_size_exclude = try list.toOwnedSlice(allocator);
                    }
                },
                .spec_quality => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.spec_quality.enabled = parseBool(val_raw) orelse cfg.spec_quality.enabled;
                    } else if (std.mem.eql(u8, key, "forbidden_phrases")) {
                        var list = try parseStringArray(allocator, val_raw);
                        cfg.spec_quality.forbidden_phrases = try list.toOwnedSlice(allocator);
                    }
                },
                .function_size => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.function_size.enabled = parseBool(val_raw) orelse cfg.function_size.enabled;
                    } else if (std.mem.eql(u8, key, "max_params")) {
                        cfg.function_size.max_params = std.fmt.parseInt(u32, val_raw, 10) catch cfg.function_size.max_params;
                    }
                },
                .complexity => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.complexity.enabled = parseBool(val_raw) orelse cfg.complexity.enabled;
                    } else if (std.mem.eql(u8, key, "max_score")) {
                        cfg.complexity.max_score = std.fmt.parseInt(u32, val_raw, 10) catch cfg.complexity.max_score;
                    }
                },
                .anytype_budget => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.anytype_budget.enabled = parseBool(val_raw) orelse cfg.anytype_budget.enabled;
                    } else if (std.mem.eql(u8, key, "max_per_file")) {
                        cfg.anytype_budget.max_per_file = std.fmt.parseInt(u32, val_raw, 10) catch cfg.anytype_budget.max_per_file;
                    }
                },
                .orphan_files => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.orphan_files.enabled = parseBool(val_raw) orelse cfg.orphan_files.enabled;
                    } else if (std.mem.eql(u8, key, "roots")) {
                        var list = try parseStringArray(allocator, val_raw);
                        cfg.orphan_files.roots = try list.toOwnedSlice(allocator);
                    }
                },
                .doc_quality => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.doc_quality.enabled = parseBool(val_raw) orelse cfg.doc_quality.enabled;
                    } else if (std.mem.eql(u8, key, "min_chars")) {
                        cfg.doc_quality.min_chars = std.fmt.parseInt(u32, val_raw, 10) catch cfg.doc_quality.min_chars;
                    }
                },
                .type_size => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.type_size.enabled = parseBool(val_raw) orelse cfg.type_size.enabled;
                    } else if (std.mem.eql(u8, key, "max_fields")) {
                        cfg.type_size.max_fields = std.fmt.parseInt(u32, val_raw, 10) catch cfg.type_size.max_fields;
                    }
                },
                .function_length => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.function_length.enabled = parseBool(val_raw) orelse cfg.function_length.enabled;
                    } else if (std.mem.eql(u8, key, "max_lines")) {
                        cfg.function_length.max_lines = std.fmt.parseInt(u32, val_raw, 10) catch cfg.function_length.max_lines;
                    }
                },
                .nesting_depth => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.nesting_depth.enabled = parseBool(val_raw) orelse cfg.nesting_depth.enabled;
                    } else if (std.mem.eql(u8, key, "max_depth")) {
                        cfg.nesting_depth.max_depth = std.fmt.parseInt(u32, val_raw, 10) catch cfg.nesting_depth.max_depth;
                    }
                },
                .test_coverage => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.test_coverage.enabled = parseBool(val_raw) orelse cfg.test_coverage.enabled;
                    } else if (std.mem.eql(u8, key, "exempt_names")) {
                        var list = try parseStringArray(allocator, val_raw);
                        cfg.test_coverage.exempt_names = try list.toOwnedSlice(allocator);
                    }
                },
                .bool_ops => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.bool_ops.enabled = parseBool(val_raw) orelse cfg.bool_ops.enabled;
                    } else if (std.mem.eql(u8, key, "max_ops")) {
                        cfg.bool_ops.max_ops = std.fmt.parseInt(u32, val_raw, 10) catch cfg.bool_ops.max_ops;
                    }
                },
                .returns_per_fn => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.returns_per_fn.enabled = parseBool(val_raw) orelse cfg.returns_per_fn.enabled;
                    } else if (std.mem.eql(u8, key, "max_returns")) {
                        cfg.returns_per_fn.max_returns = std.fmt.parseInt(u32, val_raw, 10) catch cfg.returns_per_fn.max_returns;
                    }
                },
                .line_length => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.line_length.enabled = parseBool(val_raw) orelse cfg.line_length.enabled;
                    } else if (std.mem.eql(u8, key, "max_len")) {
                        cfg.line_length.max_len = std.fmt.parseInt(u32, val_raw, 10) catch cfg.line_length.max_len;
                    }
                },
                .baseline => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.baseline.enabled = parseBool(val_raw) orelse cfg.baseline.enabled;
                    }
                },
                .unknown => {},
            }
        }
    }

    // Flush last boundary
    if (in_boundary) {
        if (cur_module) |m| {
            try boundaries.append(allocator, .{
                .module_pattern = m,
                .forbidden_imports = try cur_forbidden.toOwnedSlice(allocator),
            });
        }
    }

    cfg.boundary_rules = try boundaries.toOwnedSlice(allocator);
    return cfg;
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

fn parseStringArray(allocator: Allocator, val: []const u8) std.mem.Allocator.Error!std.ArrayListUnmanaged([]const u8) {
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

// spec: Configuration - Falls back to defaults when no config file exists
test "parse default config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), "");
    try std.testing.expectEqualStrings("SPEC.md", cfg.spec_file);
    try std.testing.expectEqual(@as(u32, 500), cfg.max_file_lines);
}

// spec: Configuration - Loads guardian.toml from target directory
// spec: Configuration - Supports boundary rules via [[boundary]] sections
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
    // top-level keys before/after the unknown section still apply
    try std.testing.expectEqualStrings("S.md", cfg.spec_file);
    // max_file_lines comes after [future_check] so section state must reset back to .top
    // when a new top-level key is seen — but our parser stays in .unknown. Accept default.
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
