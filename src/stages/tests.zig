const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const shell = @import("../shell.zig");
const StageResult = stage.StageResult;

pub fn run(ctx: *pipeline.Context) StageResult {
    const result = shell.run(ctx.allocator, &.{ "zig", "build", "test" }, ctx.target_dir) catch {
        return stage.failed(
            "Tests",
            &.{"Failed to run zig build test"},
            &.{"Ensure zig is installed and in PATH"},
        );
    };

    if (result.exit_code == 0) {
        return stage.passed("Tests", "All tests passed");
    }

    const output = if (result.stderr.len > 0) result.stderr else result.stdout;
    return stage.failedAlloc(
        ctx.allocator,
        "Tests",
        output,
        "Fix the failing tests shown above",
    );
}
