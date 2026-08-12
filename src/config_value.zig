//! Strict scalar and string-array parsing helpers for guardian.toml.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Parses a strict lowercase TOML boolean.
pub fn parseBool(val: []const u8) ?bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return null;
}

/// Parses a base-ten u32, returning the supplied default on failure.
pub fn parseU32(val: []const u8, default: u32) u32 {
    return std.fmt.parseInt(u32, val, 10) catch default;
}

/// Parses one strict quoted string without allocating.
pub fn parseString(val: []const u8) ?[]const u8 {
    if (isValidString(val)) return val[1 .. val.len - 1];
    return null;
}

/// Parses a validated string array into borrowed string slices.
pub fn parseStringArray(allocator: Allocator, val: []const u8) Allocator.Error!std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    if (!isValidStringArray(val)) return list;
    var i: usize = 1;
    while (true) {
        skipArrayTrivia(val, &i);
        if (val[i] == ']') break;
        i += 1;
        const start = i;
        while (val[i] != '"') {
            if (val[i] == '\\') i += 1;
            i += 1;
        }
        try list.append(allocator, val[start..i]);
        i += 1;
        skipArrayTrivia(val, &i);
        if (val[i] == ',') i += 1;
    }
    return list;
}

/// Parses a string array and returns its owned slice of borrowed strings.
pub fn toStrings(allocator: Allocator, val: []const u8) Allocator.Error![]const []const u8 {
    var list = try parseStringArray(allocator, val);
    return list.toOwnedSlice(allocator);
}

/// Returns whether a scalar is one complete quoted string.
pub fn isValidString(val: []const u8) bool {
    if (val.len < 2 or val[0] != '"' or val[val.len - 1] != '"') return false;
    var i: usize = 1;
    while (i < val.len - 1) : (i += 1) {
        if (val[i] == '\n' or val[i] == '\r' or val[i] == '"') return false;
        if (val[i] == '\\') {
            i += 1;
            if (i >= val.len - 1) return false;
        }
    }
    return true;
}

/// Returns whether a value is a complete strict string array.
pub fn isValidStringArray(val: []const u8) bool {
    if (val.len < 2 or val[0] != '[') return false;
    var i: usize = 1;
    while (true) {
        skipArrayTrivia(val, &i);
        if (i >= val.len) return false;
        if (val[i] == ']') {
            i += 1;
            skipArrayTrivia(val, &i);
            return i == val.len;
        }
        if (val[i] != '"') return false;
        i += 1;
        var closed = false;
        while (i < val.len) : (i += 1) {
            if (val[i] == '\n' or val[i] == '\r') return false;
            if (val[i] == '\\') {
                i += 1;
                if (i >= val.len) return false;
            } else if (val[i] == '"') {
                i += 1;
                closed = true;
                break;
            }
        }
        if (!closed) return false;
        skipArrayTrivia(val, &i);
        if (i >= val.len) return false;
        if (val[i] == ']') continue;
        if (val[i] != ',') return false;
        i += 1;
    }
}

/// Returns whether a validated array contains a blank item.
pub fn hasEmptyArrayItem(val: []const u8) bool {
    var i: usize = 1;
    while (true) {
        skipArrayTrivia(val, &i);
        if (val[i] == ']') return false;
        i += 1;
        const start = i;
        while (val[i] != '"') {
            if (val[i] == '\\') i += 1;
            i += 1;
        }
        if (std.mem.trim(u8, val[start..i], &std.ascii.whitespace).len == 0) return true;
        i += 1;
        skipArrayTrivia(val, &i);
        if (val[i] == ',') i += 1;
    }
}

fn skipArrayTrivia(val: []const u8, index: *usize) void {
    while (index.* < val.len) {
        if (std.ascii.isWhitespace(val[index.*])) {
            index.* += 1;
        } else if (val[index.*] == '#') {
            while (index.* < val.len and val[index.*] != '\n') index.* += 1;
        } else return;
    }
}

/// Removes a trailing comment while leaving hashes inside strings intact.
pub fn stripInlineComment(val: []const u8) []const u8 {
    var in_str = false;
    var escaped = false;
    for (val, 0..) |c, i| {
        switch (c) {
            '\\' => if (in_str) {
                escaped = !escaped;
            },
            '"' => if (!escaped) {
                in_str = !in_str;
                escaped = false;
            },
            '#' => if (!in_str) return std.mem.trimEnd(u8, val[0..i], &std.ascii.whitespace),
            else => escaped = false,
        }
    }
    return val;
}

/// Returns whether a key starts a string array that continues on later lines.
pub fn startsMultilineArray(line: []const u8) bool {
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const raw = std.mem.trim(u8, line[eq_idx + 1 ..], &std.ascii.whitespace);
    const val = stripInlineComment(raw);
    return val.len != 0 and val[0] == '[' and !stringArrayClosed(line);
}

/// Finds the candidate sharing a useful three-character-or-longer prefix.
pub fn bestMatch(offender: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    for (candidates) |candidate| {
        const n = @min(offender.len, candidate.len);
        var prefix_len: usize = 0;
        while (prefix_len < n and offender[prefix_len] == candidate[prefix_len]) prefix_len += 1;
        if (prefix_len > best_len) {
            best_len = prefix_len;
            best = candidate;
        }
    }
    return if (best_len >= 3) best else null;
}

/// Returns the name inside a complete array-table header.
pub fn arrayTableName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "[[") or !std.mem.endsWith(u8, line, "]]")) return null;
    return line[2 .. line.len - 2];
}

/// Returns the name inside a complete ordinary table header.
pub fn tableName(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return null;
    return line[1 .. line.len - 1];
}

/// Returns whether a byte string exactly matches one list entry.
pub fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn stringArrayClosed(text: []const u8) bool {
    const eq_idx = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    var in_string = false;
    var escaped = false;
    var in_comment = false;
    for (text[eq_idx + 1 ..]) |c| {
        if (in_comment) {
            if (c == '\n') in_comment = false;
        } else if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
        } else if (c == '#') {
            in_comment = true;
        } else if (c == '"') {
            in_string = true;
        } else if (c == ']') return true;
    }
    return false;
}

test "strict config values cover scalar array comment and multiline helpers" {
    const a = std.testing.allocator;
    try std.testing.expect(parseBool("true").?);
    try std.testing.expectEqual(@as(u32, 7), parseU32("bad", 7));
    try std.testing.expectEqualStrings("x", parseString("\"x\"").?);
    try std.testing.expect(isValidString("\"x\""));
    try std.testing.expect(isValidStringArray("[\"x\"]"));
    try std.testing.expect(hasEmptyArrayItem("[\"\"]"));
    try std.testing.expectEqualStrings("true", stripInlineComment("true # note"));
    try std.testing.expect(startsMultilineArray("exclude = ["));
    try std.testing.expectEqualStrings("enabled", bestMatch("enabld", &.{"enabled"}).?);
    try std.testing.expectEqualStrings("allow", arrayTableName("[[allow]]").?);
    try std.testing.expectEqualStrings("mutation", tableName("[mutation]").?);
    try std.testing.expect(inList(&.{"enabled"}, "enabled"));
    var parsed = try parseStringArray(a, "[\"x\"]");
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("x", parsed.items[0]);
    const strings = try toStrings(a, "[\"x\"]");
    defer a.free(strings);
    try std.testing.expectEqualStrings("x", strings[0]);
}
