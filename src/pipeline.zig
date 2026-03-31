const std = @import("std");
const Allocator = std.mem.Allocator;
const stage = @import("stage.zig");
const StageResult = stage.StageResult;

pub const Status = enum {
    accepted,
    rejected,
};

pub const PipelineResult = struct {
    status: Status,
    stages: []const StageResult,
    failed_stage: []const u8,
};

pub const StageFn = *const fn (*Context) StageResult;

pub const StageEntry = struct {
    name: []const u8,
    run_fn: StageFn,
};

pub const Context = struct {
    allocator: Allocator,
    target_dir: []const u8,
    config: @import("config.zig").Config,
    changed_files: []const []const u8,
};

pub fn run(allocator: Allocator, stages: []const StageEntry, ctx: *Context) PipelineResult {
    var results: std.ArrayListUnmanaged(StageResult) = .empty;
    var failed_stage: []const u8 = "";

    for (stages) |s| {
        const result = s.run_fn(ctx);
        results.append(allocator, result) catch {};

        switch (result) {
            .failed => {
                failed_stage = s.name;
                return .{
                    .status = .rejected,
                    .stages = results.toOwnedSlice(allocator) catch &.{},
                    .failed_stage = failed_stage,
                };
            },
            .passed => {},
        }
    }

    return .{
        .status = .accepted,
        .stages = results.toOwnedSlice(allocator) catch &.{},
        .failed_stage = "",
    };
}
