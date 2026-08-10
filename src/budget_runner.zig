//! Supervised command execution for opt-in external performance gates. The
//! child gets its own process group so a timeout stops descendants as well as
//! the direct process, while wait4-backed resource statistics retain peak RSS.

const std = @import("std");
const reporter = @import("reporter.zig");

const Allocator = std.mem.Allocator;
const watchdog_tick_ns: u64 = 100 * std.time.ns_per_ms;

/// Exit status and measured resources from one supervised child invocation.
pub const Result = struct {
    term: std.process.Child.Term,
    elapsed_ns: u64,
    timed_out: bool,
    max_rss_bytes: ?usize,
};

/// Errors raised while starting the clock, spawning/waiting for the child, or
/// creating its deadline watchdog thread.
pub const RunError = std.time.Timer.Error || std.process.Child.WaitError || std.Thread.SpawnError;

/// Runs `argv` directly in `cwd`, with inherited output. A non-zero
/// `timeout_ns` kills the whole process group at the deadline. Errors are
/// intentionally caught at the external-gate boundary, which can name the
/// configured gate while preserving OOM as a hard process error.
pub fn run(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ns: u64,
) RunError!Result {
    var timer = try std.time.Timer.start();
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.pgid = 0;
    child.request_resource_usage_statistics = true;
    try child.spawn();

    var watchdog: Watchdog = .{ .pgid = child.id, .timeout_ns = timeout_ns };
    var thread: ?std.Thread = null;
    errdefer {
        watchdog.finished.set();
        _ = child.kill() catch |e| reporter.detail("  external gate cleanup failed: {s}\n", .{@errorName(e)});
        if (thread) |t| t.join();
    }
    if (timeout_ns > 0) thread = try std.Thread.spawn(.{}, Watchdog.watch, .{&watchdog});

    const term = try child.wait();
    watchdog.finished.set();
    if (thread) |t| t.join();
    return .{
        .term = term,
        .elapsed_ns = timer.read(),
        .timed_out = watchdog.fired.load(.monotonic),
        .max_rss_bytes = child.resource_usage_statistics.getMaxRss(),
    };
}

const Watchdog = struct {
    pgid: std.process.Child.Id,
    timeout_ns: u64,
    finished: std.Thread.ResetEvent = .{},
    fired: std.atomic.Value(bool) = .init(false),

    fn watch(self: *Watchdog) void {
        var waited: u64 = 0;
        while (waited < self.timeout_ns) {
            const tick = @min(watchdog_tick_ns, self.timeout_ns - waited);
            self.finished.timedWait(tick) catch {
                waited += tick;
                continue;
            };
            return;
        }
        self.fired.store(true, .monotonic);
        std.posix.kill(-self.pgid, std.posix.SIG.KILL) catch |e|
            reporter.detail("  external gate process-group kill failed: {s}\n", .{@errorName(e)});
    }
};

test "supervised external command is killed at its wall-time ceiling" {
    const result = try run(std.testing.allocator, &.{ "sleep", "1" }, ".", 10 * std.time.ns_per_ms);
    try std.testing.expect(result.timed_out);
}
