const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BoundaryRule = struct {
    module_pattern: []const u8,
    forbidden_imports: []const []const u8,
};

pub const Config = struct {
    spec_file: []const u8 = "SPEC.md",
    min_spec_coverage: u32 = 100,
    min_test_coverage: u32 = 80,
    min_mutation_score: u32 = 90,
    max_file_lines: u32 = 500,
    mutation_exclude: []const []const u8 = &.{},
    file_size_exclude: []const []const u8 = &.{},
    boundary_rules: []const BoundaryRule = &.{},
};

pub fn load(allocator: Allocator, dir: []const u8) Config {
    const path = std.fmt.allocPrint(allocator, "{s}/guardian.toml", .{dir}) catch return .{};
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return .{};
    return parse(allocator, content);
}

pub fn parse(allocator: Allocator, content: []const u8) Config {
    var cfg = Config{};
    var boundaries: std.ArrayListUnmanaged(BoundaryRule) = .empty;

    var in_boundary = false;
    var cur_module: ?[]const u8 = null;
    var cur_forbidden: std.ArrayListUnmanaged([]const u8) = .empty;

    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    while (lines_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        // Array of tables header
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
            } else {
                if (std.mem.eql(u8, key, "spec_file")) {
                    if (parseString(val_raw)) |v| {
                        cfg.spec_file = v;
                    }
                } else if (std.mem.eql(u8, key, "min_spec_coverage")) {
                    cfg.min_spec_coverage = std.fmt.parseInt(u32, val_raw, 10) catch cfg.min_spec_coverage;
                } else if (std.mem.eql(u8, key, "min_test_coverage")) {
                    cfg.min_test_coverage = std.fmt.parseInt(u32, val_raw, 10) catch cfg.min_test_coverage;
                } else if (std.mem.eql(u8, key, "min_mutation_score")) {
                    cfg.min_mutation_score = std.fmt.parseInt(u32, val_raw, 10) catch cfg.min_mutation_score;
                } else if (std.mem.eql(u8, key, "max_file_lines")) {
                    cfg.max_file_lines = std.fmt.parseInt(u32, val_raw, 10) catch cfg.max_file_lines;
                } else if (std.mem.eql(u8, key, "mutation_exclude")) {
                    var list = parseStringArray(allocator, val_raw);
                    cfg.mutation_exclude = list.toOwnedSlice(allocator) catch &.{};
                } else if (std.mem.eql(u8, key, "file_size_exclude")) {
                    var list = parseStringArray(allocator, val_raw);
                    cfg.file_size_exclude = list.toOwnedSlice(allocator) catch &.{};
                }
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
    try std.testing.expectEqual(@as(u32, 100), cfg.min_spec_coverage);
    try std.testing.expectEqual(@as(u32, 500), cfg.max_file_lines);
}

// spec: Configuration - Loads guardian.toml from target directory
// spec: Configuration - Supports boundary rules via [[boundary]] sections
test "parse config with values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\spec_file = "SPEC.md"
        \\min_spec_coverage = 80
        \\max_file_lines = 300
        \\mutation_exclude = ["src/config.zig"]
        \\
        \\[[boundary]]
        \\module = "src/stages/*"
        \\forbidden = ["shell"]
    ;
    const cfg = parse(arena.allocator(), content);

    try std.testing.expectEqual(@as(u32, 80), cfg.min_spec_coverage);
    try std.testing.expectEqual(@as(u32, 300), cfg.max_file_lines);
    try std.testing.expectEqual(@as(usize, 1), cfg.mutation_exclude.len);
    try std.testing.expectEqualStrings("src/config.zig", cfg.mutation_exclude[0]);
    try std.testing.expectEqual(@as(usize, 1), cfg.boundary_rules.len);
    try std.testing.expectEqualStrings("src/stages/*", cfg.boundary_rules[0].module_pattern);
    try std.testing.expectEqual(@as(usize, 1), cfg.boundary_rules[0].forbidden_imports.len);
    try std.testing.expectEqualStrings("shell", cfg.boundary_rules[0].forbidden_imports[0]);
}
