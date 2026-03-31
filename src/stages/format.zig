const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const shell = @import("../shell.zig");
const StageResult = stage.StageResult;

pub fn run(ctx: *pipeline.Context) StageResult {
    const src_path = std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.target_dir}) catch
        return stage.failed("Format", &.{"Failed to construct path"}, &.{});

    const result = shell.run(ctx.allocator, &.{ "zig", "fmt", "--check", src_path }, null) catch {
        return stage.failed(
            "Format",
            &.{"Failed to run zig fmt"},
            &.{"Ensure zig is installed and in PATH"},
        );
    };

    if (result.exit_code == 0) {
        return stage.passed("Format", "All files formatted correctly");
    }

    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    const msg = std.fmt.allocPrint(ctx.allocator, "Files are not formatted:\n{s}", .{output}) catch "Files are not formatted";
    return stage.failedAlloc(
        ctx.allocator,
        "Format",
        msg,
        "Run `zig fmt src/` to fix formatting",
    );
}
