const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const shell = @import("../shell.zig");
const StageResult = stage.StageResult;

pub fn run(ctx: *pipeline.Context) StageResult {
    const result = shell.run(ctx.allocator, &.{ "zig", "build" }, ctx.target_dir) catch {
        return stage.failed(
            "Compilation",
            &.{"Failed to run zig build"},
            &.{"Ensure zig is installed and in PATH"},
        );
    };

    if (result.exit_code == 0) {
        return stage.passed("Compilation", "zig build succeeded");
    }

    const output = if (result.stderr.len > 0) result.stderr else result.stdout;
    return stage.failedAlloc(
        ctx.allocator,
        "Compilation",
        output,
        "Fix the compilation errors shown above",
    );
}
