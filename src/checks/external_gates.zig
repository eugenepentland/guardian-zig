//! Project-defined non-Zig gates. Commands execute directly as argv arrays in
//! the project directory (never through a shell), and their declared input
//! files participate in Guardian's green-run cache digest.

const std = @import("std");
const config = @import("../config.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const max_output_bytes: usize = 4 * 1024 * 1024;

/// Runs every configured `[[external]]` command and blocks on spawn/nonzero.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    if (ctx.cfg.external_gates.len == 0) {
        reporter.ok("external-gates: none configured", .{});
        return;
    }
    var failed: usize = 0;
    for (ctx.cfg.external_gates) |gate| {
        const result = std.process.Child.run(.{
            .allocator = ctx.allocator,
            .argv = gate.command,
            .cwd = ctx.project_dir,
            .max_output_bytes = max_output_bytes,
        }) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            failed += 1;
            reporter.fail("external gate '{s}' could not start: {s}", .{ gate.name, @errorName(e) });
            continue;
        };
        if (result.term == .Exited and result.term.Exited == 0) continue;
        failed += 1;
        reporter.fail("external gate '{s}' FAILED", .{gate.name});
        const stderr = std.mem.trim(u8, result.stderr, &std.ascii.whitespace);
        const stdout = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        if (stderr.len > 0) reporter.detail("  stderr: {s}\n", .{stderr});
        if (stdout.len > 0) reporter.detail("  stdout: {s}\n", .{stdout});
    }
    if (failed > 0) return error.CheckFailed;
    reporter.ok("external-gates: {d} command(s) passed", .{ctx.cfg.external_gates.len});
}

// spec: External Gates - Runs configured argv commands without a shell and blocks on nonzero exit

test "external gate failure propagates without a shell" {
    const cfg: config.Config = .{ .external_gates = &.{.{
        .name = "expected-failure",
        .command = &.{"false"},
    }} };
    var ctx: registry.RunCtx = .{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = false,
    };
    var cap: reporter.Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const prior = reporter.default.capture;
    defer reporter.default.capture = prior;
    reporter.default.capture = &cap;
    try std.testing.expectError(error.CheckFailed, run(&ctx));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "expected-failure") != null);
    try std.testing.expect(max_output_bytes <= 4 * 1024 * 1024);
}
