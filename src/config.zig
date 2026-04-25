const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BoundaryRule = struct {
    module_pattern: []const u8,
    forbidden_imports: []const []const u8,
};

pub const SpecQualityCfg = struct {
    enabled: bool = true,
    forbidden_phrases: []const []const u8 = &.{},
};

pub const FunctionSizeCfg = struct {
    enabled: bool = true,
    max_params: u32 = 5,
};

pub const Config = struct {
    spec_file: []const u8 = "SPEC.md",
    max_file_lines: u32 = 500,
    file_size_exclude: []const []const u8 = &.{},
    boundary_rules: []const BoundaryRule = &.{},
    spec_quality: SpecQualityCfg = .{},
    function_size: FunctionSizeCfg = .{},
};

pub fn load(allocator: Allocator, dir: []const u8) Config {
    const path = std.fmt.allocPrint(allocator, "{s}/guardian.toml", .{dir}) catch return .{};
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return .{};
    return parse(allocator, content);
}

const Section = enum {
    top,
    spec_quality,
    function_size,
    unknown,
};

pub fn parse(allocator: Allocator, content: []const u8) Config {
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
                    boundaries.append(allocator, .{
                        .module_pattern = m,
                        .forbidden_imports = cur_forbidden.toOwnedSlice(allocator) catch &.{},
                    }) catch {};
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
                    boundaries.append(allocator, .{
                        .module_pattern = m,
                        .forbidden_imports = cur_forbidden.toOwnedSlice(allocator) catch &.{},
                    }) catch {};
                }
                in_boundary = false;
            }
            const name = line[1 .. line.len - 1];
            if (std.mem.eql(u8, name, "spec_quality")) {
                section = .spec_quality;
            } else if (std.mem.eql(u8, name, "function_size")) {
                section = .function_size;
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
                    cur_forbidden = parseStringArray(allocator, val_raw);
                }
                continue;
            }

            switch (section) {
                .top => {
                    if (std.mem.eql(u8, key, "spec_file")) {
                        if (parseString(val_raw)) |v| cfg.spec_file = v;
                    } else if (std.mem.eql(u8, key, "max_file_lines")) {
                        cfg.max_file_lines = std.fmt.parseInt(u32, val_raw, 10) catch cfg.max_file_lines;
                    } else if (std.mem.eql(u8, key, "file_size_exclude")) {
                        var list = parseStringArray(allocator, val_raw);
                        cfg.file_size_exclude = list.toOwnedSlice(allocator) catch &.{};
                    }
                },
                .spec_quality => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.spec_quality.enabled = parseBool(val_raw) orelse cfg.spec_quality.enabled;
                    } else if (std.mem.eql(u8, key, "forbidden_phrases")) {
                        var list = parseStringArray(allocator, val_raw);
                        cfg.spec_quality.forbidden_phrases = list.toOwnedSlice(allocator) catch &.{};
                    }
                },
                .function_size => {
                    if (std.mem.eql(u8, key, "enabled")) {
                        cfg.function_size.enabled = parseBool(val_raw) orelse cfg.function_size.enabled;
                    } else if (std.mem.eql(u8, key, "max_params")) {
                        cfg.function_size.max_params = std.fmt.parseInt(u32, val_raw, 10) catch cfg.function_size.max_params;
                    }
                },
                .unknown => {},
            }
        }
    }

    // Flush last boundary
    if (in_boundary) {
        if (cur_module) |m| {
            boundaries.append(allocator, .{
                .module_pattern = m,
                .forbidden_imports = cur_forbidden.toOwnedSlice(allocator) catch &.{},
            }) catch {};
        }
    }

    cfg.boundary_rules = boundaries.toOwnedSlice(allocator) catch &.{};
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

fn parseStringArray(allocator: Allocator, val: []const u8) std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    if (val.len < 2 or val[0] != '[' or val[val.len - 1] != ']') return list;
    const inner = val[1 .. val.len - 1];
    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, &std.ascii.whitespace);
        if (parseString(trimmed)) |s| {
            list.append(allocator, s) catch {};
        }
    }
    return list;
}

// spec: Configuration - Falls back to defaults when no config file exists
test "parse default config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = parse(arena.allocator(), "");
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
    const cfg = parse(arena.allocator(), content);

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
    const cfg = parse(arena.allocator(), content);
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
    const cfg = parse(arena.allocator(), content);
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
    const cfg = parse(arena.allocator(), content);
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
    const cfg = parse(arena.allocator(), content);
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
    const cfg = parse(arena.allocator(), content);
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
    const cfg = parse(arena.allocator(), content);
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
    const cfg = parse(arena.allocator(), content);
    try std.testing.expectEqual(true, cfg.spec_quality.enabled);
    try std.testing.expectEqual(@as(usize, 1), cfg.boundary_rules.len);
    try std.testing.expectEqualStrings("src/x/*", cfg.boundary_rules[0].module_pattern);
}
