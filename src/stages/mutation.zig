const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const shell = @import("../shell.zig");
const StageResult = stage.StageResult;
const Allocator = std.mem.Allocator;

pub const Mutator = struct {
    name: []const u8,
    original: []const u8,
    replacement: []const u8,
};

pub const Mutation = struct {
    file: []const u8,
    line_number: usize,
    mutator: Mutator,
    original_line: []const u8,
    mutated_line: []const u8,
};

const MutationOutcome = enum { killed, survived, compile_error };

const mutators = [_]Mutator{
    // Arithmetic
    .{ .name = "arithmetic: + to -", .original = " + ", .replacement = " - " },
    .{ .name = "arithmetic: - to +", .original = " - ", .replacement = " + " },
    .{ .name = "arithmetic: * to /", .original = " * ", .replacement = " / " },
    // Comparison
    .{ .name = "comparison: == to !=", .original = " == ", .replacement = " != " },
    .{ .name = "comparison: != to ==", .original = " != ", .replacement = " == " },
    .{ .name = "comparison: >= to >", .original = " >= ", .replacement = " > " },
    .{ .name = "comparison: <= to <", .original = " <= ", .replacement = " < " },
    .{ .name = "comparison: > to >=", .original = " > ", .replacement = " >= " },
    .{ .name = "comparison: < to <=", .original = " < ", .replacement = " <= " },
    // Boolean
    .{ .name = "boolean: true to false", .original = "true", .replacement = "false" },
    .{ .name = "boolean: false to true", .original = "false", .replacement = "true" },
    // Zig-specific
    .{ .name = "optional: orelse to unreachable", .original = " orelse ", .replacement = " orelse unreachable; // " },
    .{ .name = "error: catch to unreachable", .original = " catch ", .replacement = " catch unreachable; // " },
};

pub fn run(ctx: *pipeline.Context) StageResult {
    const src_path = std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.target_dir}) catch
        return stage.passed("Mutation Testing", "Could not construct path");

    // Find source files
    var source_files: std.ArrayListUnmanaged([]const u8) = .empty;
    collectZigFiles(ctx.allocator, src_path, &source_files) catch {};

    // Filter by changed files and exclusions
    var filtered: std.ArrayListUnmanaged([]const u8) = .empty;
    for (source_files.items) |file| {
        if (isExcluded(file, ctx.config.mutation_exclude)) continue;
        if (ctx.changed_files.len > 0 and !isChanged(file, ctx.changed_files)) continue;
        filtered.append(ctx.allocator, file) catch {};
    }

    if (filtered.items.len == 0) {
        return stage.passed("Mutation Testing", "No source files to mutate");
    }

    // Generate mutations
    var all_mutations: std.ArrayListUnmanaged(Mutation) = .empty;
    for (filtered.items) |file| {
        generateMutations(ctx.allocator, file, &all_mutations);
    }

    if (all_mutations.items.len == 0) {
        return stage.passed("Mutation Testing", "No applicable mutations found");
    }

    // Run mutations
    var killed: usize = 0;
    var survived_list: std.ArrayListUnmanaged(Mutation) = .empty;
    var compile_errors: usize = 0;

    for (all_mutations.items) |mutation_item| {
        const outcome = runSingleMutation(ctx.allocator, ctx.target_dir, mutation_item);
        switch (outcome) {
            .killed => killed += 1,
            .survived => survived_list.append(ctx.allocator, mutation_item) catch {},
            .compile_error => compile_errors += 1,
        }
    }

    // Final clean build to restore state
    _ = shell.run(ctx.allocator, &.{ "zig", "build" }, ctx.target_dir) catch {};

    const survived = survived_list.items.len;
    const testable = killed + survived;
    const score_val: u32 = if (testable == 0) 100 else @intCast(killed * 100 / testable);

    const detail = std.fmt.allocPrint(ctx.allocator, "{d} killed, {d} survived, {d} compile errors -- score: {d}%", .{
        killed, survived, compile_errors, score_val,
    }) catch "Mutation testing complete";

    if (score_val >= ctx.config.min_mutation_score) {
        return stage.passed("Mutation Testing", detail);
    }

    // Build failure issues
    var issues: std.ArrayListUnmanaged([]const u8) = .empty;
    const score_msg = std.fmt.allocPrint(ctx.allocator, "Mutation score {d}% is below minimum {d}%", .{
        score_val, ctx.config.min_mutation_score,
    }) catch "Score below minimum";
    issues.append(ctx.allocator, score_msg) catch {};

    for (survived_list.items) |m| {
        const msg = std.fmt.allocPrint(ctx.allocator, "{s}:{d} -- {s} survived", .{
            m.file, m.line_number, m.mutator.name,
        }) catch continue;
        issues.append(ctx.allocator, msg) catch {};
    }

    return stage.failed(
        "Mutation Testing",
        issues.toOwnedSlice(ctx.allocator) catch &.{},
        &.{"Add tests that would fail when these mutations are applied"},
    );
}

fn collectZigFiles(allocator: Allocator, dir_path: []const u8, files: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try collectZigFiles(allocator, full, files),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    try files.append(allocator, full);
                }
            },
            else => {},
        }
    }
}

fn generateMutations(allocator: Allocator, file: []const u8, mutations: *std.ArrayListUnmanaged(Mutation)) void {
    const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch return;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 1;

    while (lines.next()) |line| {
        defer line_number += 1;

        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Skip lines that shouldn't be mutated
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (std.mem.startsWith(u8, trimmed, "const std")) continue;
        if (std.mem.startsWith(u8, trimmed, "pub const") and std.mem.indexOf(u8, trimmed, "@import") != null) continue;
        if (std.mem.startsWith(u8, trimmed, "test ")) continue;
        // Skip error-handling boilerplate — catch/orelse on fire-and-forget lines
        if (shouldSkipErrorHandling(trimmed)) continue;

        for (&mutators) |m| {
            if (std.mem.indexOf(u8, line, m.original) != null) {
                if (appearsOutsideString(line, m.original)) {
                    const mutated = replaceFirst(allocator, line, m.original, m.replacement) catch continue;
                    mutations.append(allocator, .{
                        .file = file,
                        .line_number = line_number,
                        .mutator = m,
                        .original_line = line,
                        .mutated_line = mutated,
                    }) catch {};
                }
            }
        }
    }
}

fn shouldSkipErrorHandling(trimmed: []const u8) bool {
    // Skip lines that are pure error-handling boilerplate:
    // - "} catch {}" / "catch {}" / "catch continue" / "catch return"
    // - "orelse return" / "orelse continue" / "orelse &.{}"
    // - lines ending with "catch {};" or "catch {},"
    // These generate noise mutations (catch→unreachable) that aren't meaningful.
    const skip_suffixes = [_][]const u8{
        "catch {}",
        "catch {};",
        "catch {},",
        "catch continue;",
        "catch continue,",
        "catch return;",
        "catch return,",
        "catch return",
        "orelse return;",
        "orelse return,",
        "orelse return",
        "orelse continue;",
        "orelse continue,",
        "orelse &.{};",
        "orelse &.{},",
        "orelse &.{}",
        "catch |_| {};",
        "catch |_| {},",
    };
    for (&skip_suffixes) |suffix| {
        if (std.mem.endsWith(u8, trimmed, suffix)) return true;
    }
    // Skip lines that are just "} catch {" (multiline catch block opener)
    if (std.mem.eql(u8, trimmed, "} catch {")) return true;
    return false;
}

fn appearsOutsideString(line: []const u8, pattern: []const u8) bool {
    const idx = std.mem.indexOf(u8, line, pattern) orelse return false;
    var quote_count: usize = 0;
    for (line[0..idx]) |c| {
        if (c == '"') quote_count += 1;
    }
    return quote_count % 2 == 0;
}

fn replaceFirst(allocator: Allocator, text: []const u8, pattern: []const u8, replacement: []const u8) ![]const u8 {
    const idx = std.mem.indexOf(u8, text, pattern) orelse return text;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    try result.appendSlice(allocator, text[0..idx]);
    try result.appendSlice(allocator, replacement);
    try result.appendSlice(allocator, text[idx + pattern.len ..]);
    return result.toOwnedSlice(allocator);
}

fn runSingleMutation(allocator: Allocator, target_dir: []const u8, mutation_item: Mutation) MutationOutcome {
    // Read original file
    const original_content = std.fs.cwd().readFileAlloc(allocator, mutation_item.file, 10 * 1024 * 1024) catch return .compile_error;

    // Apply mutation
    const mutated_content = applyMutation(allocator, original_content, mutation_item) catch return .compile_error;

    // Write mutated file
    const cwd = std.fs.cwd();
    const file = cwd.createFile(mutation_item.file, .{}) catch return .compile_error;
    file.writeAll(mutated_content) catch {
        file.close();
        return .compile_error;
    };
    file.close();

    // Try build
    const build_result = shell.run(allocator, &.{ "zig", "build" }, target_dir) catch {
        restoreFile(mutation_item.file, original_content);
        return .compile_error;
    };

    var outcome: MutationOutcome = undefined;
    if (build_result.exit_code != 0) {
        outcome = .compile_error;
    } else {
        // Build succeeded — run tests
        const test_result = shell.run(allocator, &.{ "zig", "build", "test" }, target_dir) catch {
            restoreFile(mutation_item.file, original_content);
            return .killed;
        };
        outcome = if (test_result.exit_code == 0) .survived else .killed;
    }

    restoreFile(mutation_item.file, original_content);
    return outcome;
}

fn restoreFile(path: []const u8, content: []const u8) void {
    const cwd = std.fs.cwd();
    const file = cwd.createFile(path, .{}) catch return;
    defer file.close();
    file.writeAll(content) catch {};
}

fn applyMutation(allocator: Allocator, content: []const u8, mutation_item: Mutation) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 1;
    var first = true;

    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        first = false;

        if (line_number == mutation_item.line_number) {
            try result.appendSlice(allocator, mutation_item.mutated_line);
        } else {
            try result.appendSlice(allocator, line);
        }
        line_number += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn isExcluded(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |pattern| {
        if (std.mem.indexOf(u8, path, pattern) != null) return true;
    }
    return false;
}

fn isChanged(path: []const u8, changed_files: []const []const u8) bool {
    for (changed_files) |cf| {
        if (std.mem.endsWith(u8, path, cf)) return true;
    }
    return false;
}
