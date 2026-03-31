const std = @import("std");
const config = @import("config.zig");
const pipeline = @import("pipeline.zig");
const stage_mod = @import("stage.zig");
const git = @import("git.zig");
const feedback = @import("feedback.zig");

// Stages
const change = @import("stages/change.zig");
const spec_coverage = @import("stages/spec_coverage.zig");
const compilation = @import("stages/compilation.zig");
const format = @import("stages/format.zig");
const file_size = @import("stages/file_size.zig");
const dead_code = @import("stages/dead_code.zig");
const boundaries = @import("stages/boundaries.zig");
const tests = @import("stages/tests.zig");
const mutation = @import("stages/mutation.zig");

// All stages for standalone mode
const all_stages = [_]pipeline.StageEntry{
    .{ .name = "Change Classification", .run_fn = change.run },
    .{ .name = "Spec Coverage", .run_fn = spec_coverage.run },
    .{ .name = "Compilation", .run_fn = compilation.run },
    .{ .name = "Format", .run_fn = format.run },
    .{ .name = "File Size", .run_fn = file_size.run },
    .{ .name = "Dead Code", .run_fn = dead_code.run },
    .{ .name = "Boundaries", .run_fn = boundaries.run },
    .{ .name = "Tests", .run_fn = tests.run },
    .{ .name = "Mutation Testing", .run_fn = mutation.run },
};

// Stages when build.zig handles compile/test/fmt (--build-verified mode)
const analysis_stages = [_]pipeline.StageEntry{
    .{ .name = "Change Classification", .run_fn = change.run },
    .{ .name = "Spec Coverage", .run_fn = spec_coverage.run },
    .{ .name = "File Size", .run_fn = file_size.run },
    .{ .name = "Dead Code", .run_fn = dead_code.run },
    .{ .name = "Boundaries", .run_fn = boundaries.run },
    .{ .name = "Mutation Testing", .run_fn = mutation.run },
};

const print = std.debug.print;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2 or !std.mem.eql(u8, args[1], "check")) {
        print("Usage: guardian check --intent \"...\" [--build-verified] [target-dir]\n", .{});
        print("\nOptions:\n", .{});
        print("  --intent <msg>     Required. Description of changes.\n", .{});
        print("  --build-verified   Skip compile/test/fmt stages (handled by build.zig).\n", .{});
        print("  [target-dir]       Project directory (default: current dir).\n", .{});
        std.process.exit(1);
    }

    // Parse check args
    var intent: ?[]const u8 = null;
    var target_dir: []const u8 = ".";
    var build_verified = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--intent") and i + 1 < args.len) {
            i += 1;
            intent = args[i];
        } else if (std.mem.eql(u8, args[i], "--build-verified")) {
            build_verified = true;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            target_dir = args[i];
        }
    }

    if (intent == null) {
        print("Error: --intent is required\n", .{});
        print("Usage: guardian check --intent \"description\" [--build-verified] [target-dir]\n", .{});
        std.process.exit(1);
    }

    print("Guardian: checking {s}\n", .{target_dir});
    print("Intent: {s}\n", .{intent.?});
    if (build_verified) {
        print("Mode: build-verified (compile/test/fmt handled by build.zig)\n", .{});
    }
    print("\n", .{});

    // Load config
    const cfg = config.load(allocator, target_dir);

    // Get changed files
    const changed_files = getChangedFiles(allocator, target_dir);

    // Build and run pipeline
    var ctx = pipeline.Context{
        .allocator = allocator,
        .target_dir = target_dir,
        .config = cfg,
        .changed_files = changed_files,
    };

    // Choose stages based on mode
    const stages: []const pipeline.StageEntry = if (build_verified) &analysis_stages else &all_stages;

    // In build-verified mode, report the pre-verified stages
    if (build_verified) {
        print("  \xe2\x9c\x93 Compilation \xe2\x80\x94 verified by build.zig\n", .{});
        print("  \xe2\x9c\x93 Format \xe2\x80\x94 verified by build.zig\n", .{});
        print("  \xe2\x9c\x93 Tests \xe2\x80\x94 verified by build.zig\n", .{});
    }

    const result = pipeline.run(allocator, stages, &ctx);

    // Report results
    for (result.stages) |s| {
        switch (s) {
            .passed => |p| print("  \xe2\x9c\x93 {s} \xe2\x80\x94 {s}\n", .{ p.name, p.detail }),
            .failed => |f| {
                print("  \xe2\x9c\x97 {s}\n", .{f.name});
                for (f.issues) |issue| {
                    print("    {s}\n", .{issue});
                }
            },
        }
    }

    switch (result.status) {
        .accepted => {
            print("\n\xe2\x9c\x93 All stages passed\n", .{});

            // Auto-commit
            const receipt = buildReceipt(allocator, result, build_verified);
            const message = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ intent.?, receipt }) catch intent.?;

            git.addAll(allocator, target_dir) catch {
                print("\nWarning: Failed to stage files\n", .{});
                std.process.exit(0);
            };
            git.commit(allocator, target_dir, message) catch {
                print("\nWarning: Failed to commit\n", .{});
                std.process.exit(0);
            };
            const hash = git.headHash(allocator, target_dir) catch "unknown";
            const short_hash = if (hash.len >= 8) hash[0..8] else hash;
            print("Committed: {s}\n", .{short_hash});
            std.process.exit(0);
        },
        .rejected => {
            print("\n\xe2\x9c\x97 Pipeline failed at: {s}\n", .{result.failed_stage});
            feedback.writeFeedback(allocator, target_dir, result);
            print("Feedback written to GUARDIAN_FEEDBACK.md\n", .{});
            std.process.exit(1);
        },
    }
}

fn getChangedFiles(allocator: std.mem.Allocator, dir: []const u8) []const []const u8 {
    const cached = git.diffCachedNames(allocator, dir) catch &.{};
    if (cached.len > 0) return cached;
    return git.diffNames(allocator, dir) catch &.{};
}

// spec: Pipeline - Auto-commits with receipt on success
fn buildReceipt(allocator: std.mem.Allocator, result: pipeline.PipelineResult, build_verified: bool) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(allocator, "Guardian verification:\n") catch {};
    if (build_verified) {
        buf.appendSlice(allocator, "  \xe2\x9c\x93 Compilation (build.zig)\n") catch {};
        buf.appendSlice(allocator, "  \xe2\x9c\x93 Format (build.zig)\n") catch {};
        buf.appendSlice(allocator, "  \xe2\x9c\x93 Tests (build.zig)\n") catch {};
    }
    for (result.stages) |s| {
        const line = switch (s) {
            .passed => |p| std.fmt.allocPrint(allocator, "  \xe2\x9c\x93 {s}\n", .{p.name}) catch continue,
            .failed => |f| std.fmt.allocPrint(allocator, "  \xe2\x9c\x97 {s}\n", .{f.name}) catch continue,
        };
        buf.appendSlice(allocator, line) catch {};
    }
    return buf.toOwnedSlice(allocator) catch "";
}

// Import all modules for test compilation
test {
    _ = @import("config.zig");
    _ = @import("stage.zig");
    _ = @import("pipeline.zig");
    _ = @import("shell.zig");
    _ = @import("git.zig");
    _ = @import("feedback.zig");
    _ = @import("spec/parser.zig");
    _ = @import("spec/matcher.zig");
    _ = @import("stages/change.zig");
    _ = @import("stages/spec_coverage.zig");
    _ = @import("stages/compilation.zig");
    _ = @import("stages/format.zig");
    _ = @import("stages/file_size.zig");
    _ = @import("stages/dead_code.zig");
    _ = @import("stages/boundaries.zig");
    _ = @import("stages/tests.zig");
    _ = @import("stages/mutation.zig");
}
