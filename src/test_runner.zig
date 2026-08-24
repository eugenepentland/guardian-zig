//! Guardian's test runner: the stock Zig test runner plus one line of honesty
//! about how many tests actually ran.
//!
//! Zig hands `--test-filter` to the *compiler*, not to the runner. Tests that
//! don't match are never analyzed, never linked, and never reach
//! `builtin.test_functions` — verified on Zig 0.15.1, where a filtered build
//! also stays green while a test it skipped fails to compile. The corollary is
//! the trap this file exists to close: a filter that matches *nothing* produces
//! a binary with zero tests, runs it, and exits 0, which at the shell is
//! indistinguishable from a green suite. Six consumer sessions reported trusting
//! such a run.
//!
//! So, before the first test runs, this runner prints
//! `guardian/test: N test(s) selected` (naming the filters when the build
//! forwards them with `--guardian-filter=`), and a run in which nothing the
//! caller asked for ran fails loudly instead of exiting 0.
//! `GUARDIAN_TEST_ALLOW_EMPTY=1` opts out for the one honest case: a project
//! that genuinely has no tests yet.
//!
//! "Nothing the caller asked for" is not the same as "no tests": an unnamed
//! `test { }` block has no name for a filter to match, so it compiles into
//! every filtered binary and would otherwise pad a zero-match run to a
//! comfortable-looking count (Guardian's own suite has three, and a nonsense
//! filter reports `3 test(s) selected` without them being noticed). When the
//! build forwards the filters, the runner therefore also counts how many
//! selected tests a filter actually names, and judges emptiness on that.
//!
//! It is deliberately self-contained — `std` and `builtin` only, no Guardian
//! imports — because it is compiled as the *root* of a consumer's test binary
//! from wherever the guardian package happens to sit on disk. Its own `test`
//! blocks would never run there — the compiler collects tests from the module
//! under test, not from the runner, and refuses to put this file in both
//! modules at once ("file exists in modules 'root' and 'root'"). Guardian
//! therefore compiles it a second time as its own test root; `zig build test`
//! depends on that binary too.
//!
//! It also reports what the run COST and guards that cost: a test that reaches
//! the slow floor is warned about on its own line the moment it finishes, and
//! the opt-in `GUARDIAN_TEST_MAX_TEST_SECS` / `GUARDIAN_TEST_MAX_WALL_SECS`
//! caps fail the run — after every test has run and reported. See
//! `test_timing.zig` for the reasoning, including why the caps are opt-in and
//! why none of them is a watchdog.
//!
//! And every exit path ends in one VERDICT line — `PASS — N passed` or
//! `FAIL — F failed of N` — printed last, in both modes, off the same
//! `timing.Verdict` the exit status is read from. Without it a `zig build test`
//! transcript never states its own answer: Zig's build runner writes a run
//! step's `failed command: …` banner before any verdict exists and erases it
//! only on the success path, so a piped green run ends on that banner and reads
//! as a failure (fifteen-plus consumer reports in two days, each costing a
//! re-run). Guardian cannot unprint another program's line; it can be the last
//! word. The one seam: in SERVER mode a failing test still exits this process
//! 0, because the build system already has that test's result over the protocol
//! and treats a nonzero runner exit as "the runner itself broke", discarding
//! every per-test result. The verdict line reports the run's true state there
//! while the build system reports the status.
//!
//! Protocol parity with the stock runner: it speaks `std.zig.Server` over stdio
//! when the build system passes `--listen=-`, and reports to the terminal when
//! run directly. Deviations: the exotic-backend paths (SPIR-V, the `mainSimple`
//! crippled-backend fallback) are not carried over, the terminal fallback prints
//! failures and the summary rather than echoing every passing test, and an
//! unrecognized argument is ignored rather than fatal — a future build-system
//! flag must not take out every consumer's suite.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const timing = @import("test_timing.zig");
const fuzz_abi = std.Build.abi.fuzz;

/// Root options. The stock runner fails a test that only *logged* an error;
/// keeping its `logFn` keeps that verdict identical.
pub const std_options: std.Options = .{ .logFn = log };

/// Prefix on every line this runner prints, so its output is greppable and
/// obviously not part of a test's own output. One spelling, owned by the
/// timing module, shared here.
const prefix = timing.prefix;

/// Set to a non-empty value other than "0" (the spelling every other GUARDIAN_*
/// flag uses) to permit a run that selected no tests at all.
const allow_empty_env = "GUARDIAN_TEST_ALLOW_EMPTY";
/// Same spelling: widens the closing slow-test report (lower floor, higher
/// cap) when set. The report itself always prints — see `reportTimings`.
const timings_env = "GUARDIAN_TEST_TIMINGS";

const listen_flag = "--listen=-";
const seed_flag = "--seed=";
const cache_dir_flag = "--cache-dir=";
/// Forwarded by `build_helper.announceFilters` so the runner can name the
/// filter that produced its count. Zig never tells a runner what the filter was.
const filter_flag = "--guardian-filter=";

/// Bytes reserved for argv only. Environment values use the entry point's
/// backing allocator so a normal-sized environment can never exhaust argv's
/// small fixed buffer and silently disable a test cap.
const args_arena_bytes = 8192;
/// Bytes reserved for each stdio buffer of the server protocol.
const io_buffer_bytes = 4096;
/// Bytes reserved for one rendered report.
const report_buffer_bytes = 1024;
/// Filters kept for name-matching. Beyond this the runner stops claiming to
/// know what matched (see `Args.complete`) rather than undercounting.
const max_stored_filters = 16;
/// Filters quoted individually before the report summarizes the rest.
const max_named_filters = 3;

const missing_error_trace =
    "guardian/test: assertion location unavailable because this optimized test module disabled error-return tracing\n" ++
    "guardian/test: fix: call guardian.enableTestDiagnostics(test_mod), or use guardian.addTestCompileProbe with that module\n";

/// Verdict reason when the zero-match guard stops the run before any test.
const empty_selection_verdict = "nothing the filter named ran";
/// Verdict reason when the runner itself gave up (`fatal`).
const runner_aborted_verdict = "the runner aborted before the suite finished";

const ServerExit = enum { return_normally, cap_failure };

// Process-lifetime state. A test runner is an entry point: the log counter, the
// argv arena, the protocol buffers, and the fuzz flag are all singletons of the
// process, exactly as they are in the stock runner (see the ban-globals
// exemption in guardian.toml).
var log_err_count: usize = 0;
var fba_buffer: [args_arena_bytes]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
var stdin_buffer: [io_buffer_bytes]u8 = undefined;
var stdout_buffer: [io_buffer_bytes]u8 = undefined;
const runner_io: Io = Io.Threaded.global_single_threaded.io();
var stdin_reader = Io.File.stdin().readerStreaming(runner_io, &stdin_buffer);
var stdout_writer = Io.File.stdout().writerStreaming(runner_io, &stdout_buffer);
var runner_environ: std.process.Environ = .empty;
var runner_args: std.process.Args = undefined;
var runner_backing_allocator: std.mem.Allocator = undefined;
var is_fuzz_test: bool = undefined;
var filter_storage: [max_stored_filters][]const u8 = undefined;
// Timing state, accumulated per finished test (a per-test array is impossible:
// `builtin.test_functions.len` is not comptime-known under --test-runner).
// `slow_list[0..slow_len]` holds the most expensive tests, descending.
var slow_list: [timing.max_capacity]timing.Slow = undefined;
var slow_len: usize = 0;
var total_test_ns: u64 = 0;
/// Floor + cap for the closing slow-test report, set once in `main`.
var timing_limits: timing.Limits = .{};
/// The opt-in hard caps, read once in `main`; the default value is "no cap".
var timing_caps: timing.Caps = .{};
// Cap offenders, same fixed-capacity shape and for the same reason:
// `over_list[0..over.stored]` names the tests that broke the per-test cap, and
// `over.count` is how many there were — which can be larger than the list.
var over_list: [timing.max_offenders]timing.Slow = undefined;
var over: timing.Over = .{};
/// What this run produced, folded in test by test. Server mode has nowhere else
/// to keep it: each result goes straight out over the protocol and is gone, so
/// without this the closing verdict would have no counts to state.
var run_tally: timing.Tally = .{};

/// Command line as this runner reads it. `stored` counts the filters captured
/// into `filter_storage`; `filters` counts how many were passed.
const Args = struct {
    listen: bool = false,
    cache_dir: ?[]const u8 = null,
    filters: usize = 0,
    stored: usize = 0,

    /// Every captured filter — what test names are matched against.
    fn allFilters(self: Args) []const []const u8 {
        return filter_storage[0..self.stored];
    }

    /// The prefix of the filters the report quotes individually.
    fn namedFilters(self: Args) []const []const u8 {
        return filter_storage[0..@min(self.stored, max_named_filters)];
    }

    /// True when every passed filter was captured, so a match count over them
    /// is the whole truth.
    fn complete(self: Args) bool {
        return self.stored == self.filters;
    }
};

/// What the runner selected, as the report needs to describe it.
const Selection = struct {
    /// Tests in this binary — after the compiler applied any `--test-filter`.
    count: usize = 0,
    /// How many of those actually match a filter by name. Null when the runner
    /// cannot tell (no filters were forwarded, or there were too many to hold).
    /// The distinction matters: an unnamed `test { }` block has no name to
    /// match, so it survives *every* filter and would otherwise disguise a
    /// zero-match run as a non-empty one.
    matched: ?usize = null,
    /// Filters quoted individually in the report.
    named: []const []const u8 = &.{},
    /// Filters passed in total; `named.len` may be smaller.
    filters: usize = 0,
};

/// A rendered pre-run report plus the verdict on whether the run may proceed.
const Report = struct {
    text: []const u8,
    fatal: bool,
};

/// Entry point: report the selection, then run the tests the compiler left in
/// this binary.
pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    runner_environ = init.environ;
    runner_args = init.args;
    // The process entry point owns this process-lifetime allocator choice;
    // helpers consume the capability instead of selecting a global allocator.
    runner_backing_allocator = std.heap.page_allocator;

    const argv = init.args.toSlice(fba.allocator()) catch
        fatal("out of memory parsing command line arguments");
    var args: Args = .{};
    parseArgs(argv[1..], &args);
    announce(args);
    timing_limits = timing.Limits.forDetail(
        if (optOutActive(readEnv(timings_env))) .wide else .standard,
    );
    // Caps hold only integers, so they outlive the arena the values came from.
    timing_caps = timing.Caps.fromSeconds(
        timing.parseSeconds(readEnv(timing.max_test_env)),
        timing.parseSeconds(readEnv(timing.max_wall_env)),
    );
    fba.reset();

    if (builtin.fuzz) {
        const cache_dir = args.cache_dir orelse fatal("missing --cache-dir=[path] argument");
        fuzz_abi.fuzzer_init(.fromSlice(cache_dir));
    }

    if (args.listen) return mainServer() catch fatal("internal test runner failure");
    return mainTerminal();
}

fn initTestState(canary: u32) void {
    testing.allocator_instance = .init(runner_backing_allocator, .{
        .canary = canary,
        .check_write_after_free = true,
    });
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(runner_args),
        .environ = runner_environ,
    });
    testing.environ = runner_environ;
}

fn deinitTestState() usize {
    testing.io_instance.deinit();
    return testing.allocator_instance.deinit();
}

/// Reads the command line, ignoring anything unrecognized.
fn parseArgs(argv: []const [:0]const u8, out: *Args) void {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, listen_flag)) {
            out.listen = true;
        } else if (std.mem.startsWith(u8, arg, seed_flag)) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg[seed_flag.len..], 0) catch 0;
        } else if (std.mem.startsWith(u8, arg, cache_dir_flag)) {
            out.cache_dir = arg[cache_dir_flag.len..];
        } else if (std.mem.startsWith(u8, arg, filter_flag)) {
            recordFilter(out, arg[filter_flag.len..]);
        }
    }
}

/// Counts one forwarded filter, keeping the text when there is room for it.
fn recordFilter(out: *Args, text: []const u8) void {
    if (out.stored < filter_storage.len) {
        filter_storage[out.stored] = text;
        out.stored += 1;
    }
    out.filters += 1;
}

/// Prints the pre-run report and aborts the run when it is fatal. This is the
/// whole point of the runner: the count is printed before any test executes, so
/// it is visible even if the suite later hangs or crashes.
fn announce(args: Args) void {
    var buf: [report_buffer_bytes]u8 = undefined;
    const rendered = report(&buf, .{
        .count = builtin.test_functions.len,
        .matched = matchedCount(args),
        .named = args.namedFilters(),
        .filters = args.filters,
    }, optOutActive(readEnv(allow_empty_env)));
    writeErr(rendered.text);
    if (!rendered.fatal) return;
    announceVerdict(.{ .aborted = empty_selection_verdict });
    std.process.exit(1);
}

/// Prints the run's ONE closing verdict line. Every exit path routes through
/// here, and the caller decides its status from the same `timing.Verdict`, so a
/// PASS line can never sit above a nonzero exit (or the reverse).
fn announceVerdict(verdict: timing.Verdict) void {
    @disableInstrumentation();
    var buf: [report_buffer_bytes]u8 = undefined;
    writeErr(timing.renderVerdict(&buf, verdict));
}

/// How many tests in this binary a forwarded filter actually names. Null when
/// no filter was forwarded, or when more arrived than could be held — an
/// undercount would fail an honest run, so the runner says "unknown" instead.
fn matchedCount(args: Args) ?usize {
    if (args.filters == 0 or !args.complete()) return null;
    var matched: usize = 0;
    for (builtin.test_functions) |test_fn| {
        if (nameMatches(test_fn.name, args.allFilters())) matched += 1;
    }
    return matched;
}

/// True when `name` contains any of `filters` — the same substring rule the
/// compiler applies to a fully qualified test name for `--test-filter`
/// (verified on Zig 0.15.1: `-Dtest-filter=lpha` selects `test "alpha one"`).
fn nameMatches(name: []const u8, filters: []const []const u8) bool {
    for (filters) |filter| {
        if (std.mem.indexOf(u8, name, filter) != null) return true;
    }
    return false;
}

/// Renders the bytes printed before the first test runs, and decides whether
/// the run may continue. A run that selected nothing the caller asked for is
/// fatal unless the opt-out is set: exiting 0 on it is exactly the false green
/// this runner exists to prevent.
fn report(buf: []u8, sel: Selection, opt_out: bool) Report {
    var w = std.Io.Writer.fixed(buf);
    writeSelection(&w, sel) catch return .{ .text = w.buffered(), .fatal = false };
    if (!isEmpty(sel)) return .{ .text = w.buffered(), .fatal = false };
    const tail = if (opt_out) empty_permitted else empty_refused;
    w.writeAll(tail) catch return .{ .text = w.buffered(), .fatal = !opt_out };
    return .{ .text = w.buffered(), .fatal = !opt_out };
}

/// True when nothing the caller asked for ran: no test at all, or — when the
/// runner knows the filters — no test whose name the filter names. The second
/// case is the one that hides: unnamed `test { }` blocks have no name to match,
/// so they survive every filter and keep the raw count above zero.
fn isEmpty(sel: Selection) bool {
    if (sel.matched) |matched| return matched == 0;
    return sel.count == 0;
}

/// Writes the one-line count, naming the filters when the build forwarded them
/// and separating the tests a filter actually named from the unnamed blocks
/// that ran regardless.
fn writeSelection(w: *std.Io.Writer, sel: Selection) std.Io.Writer.Error!void {
    try w.print("{s}{d} test(s) selected", .{ prefix, sel.count });
    if (sel.filters == 0) return w.writeByte('\n');
    try w.writeAll(" by filter: ");
    for (sel.named, 0..) |text, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{text});
    }
    const rest = sel.filters - sel.named.len;
    if (rest > 0) try w.print(" (+{d} more)", .{rest});
    try writeUnfilterable(w, sel);
    try w.writeByte('\n');
}

/// Adds the "only N of them are yours" clause when unnamed blocks padded the
/// count.
fn writeUnfilterable(w: *std.Io.Writer, sel: Selection) std.Io.Writer.Error!void {
    const matched = sel.matched orelse return;
    if (matched >= sel.count) return;
    try w.print(" — {d} match by name, {d} unnamed test block(s) run regardless", .{
        matched,
        sel.count - matched,
    });
}

const empty_refused =
    \\  NOTHING YOU ASKED FOR RAN. A zero-match filter proves nothing: Zig applies
    \\  --test-filter in the compiler, so the tests it skipped were never analyzed,
    \\  never linked, and never reached this runner. Exiting 0 here would be
    \\  indistinguishable from a green suite, so this run fails instead.
    \\  fix: correct the filter text (`guardian-check test-filter . --args` derives
    \\  one from your diff), or drop the filter and run the whole suite.
    \\  opt out (a project that genuinely has no tests yet): GUARDIAN_TEST_ALLOW_EMPTY=1
    \\
;

const empty_permitted =
    \\  Nothing you asked for ran. GUARDIAN_TEST_ALLOW_EMPTY is set, so the empty run
    \\  is permitted and reports success — it is evidence of nothing.
    \\
;

/// True when the opt-out variable carries a meaningful value: present,
/// non-empty, and not "0".
fn optOutActive(value: ?[]const u8) bool {
    const text = value orelse return false;
    if (text.len == 0) return false;
    return !std.mem.eql(u8, text, "0");
}

/// Reads one GUARDIAN_* variable from the environment through a dedicated
/// allocation path. Returning null means absent, never "the shared argv arena
/// happened to be full" — test caps are enforcement switches, so an allocation
/// failure must not look like an unset variable.
fn readEnv(name: []const u8) ?[]const u8 {
    return std.process.Environ.getAlloc(runner_environ, runner_backing_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => fatal("out of memory reading Guardian test-runner environment"),
        error.InvalidWtf8 => fatal("invalid environment encoding in Guardian test runner"),
    };
}

/// Writes to stderr, dropping the message if the handle is unusable — a failed
/// diagnostic must never replace the test result it was describing.
fn writeErr(bytes: []const u8) void {
    Io.File.stderr().writeStreamingAll(runner_io, bytes) catch return;
}

/// Prints `message`, closes with a FAIL verdict so no exit path is silent about
/// its own outcome, and exits nonzero. This file is the process entry point, so
/// the raw exit is the sanctioned one (see the fatal-exit check).
fn fatal(message: []const u8) noreturn {
    writeErr(prefix);
    writeErr(message);
    writeErr("\n");
    announceVerdict(.{ .aborted = runner_aborted_verdict });
    std.process.exit(1);
}

/// Serves the build system's test protocol over stdio — the mode every
/// `zig build test` uses.
fn mainServer() !void {
    @disableInstrumentation();
    var server: std.zig.Server = .{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                reportTimings();
                // The build system has already collected every test's result;
                // a broken cap fails the run here, after all of them reported.
                const verdict: timing.Verdict = .{
                    .tally = run_tally,
                    .caps_broken = capsFailed(),
                };
                announceVerdict(verdict);
                // Only the caps decide THIS process's status. A failing test is
                // already on the wire, and Zig's Run step discards every
                // per-test result when the runner exits nonzero ("the test
                // runner itself broke"), so exiting on `verdict.failed()` here
                // would trade all failure attribution for a redundant code.
                // Return normally on success: forcing `_exit(0)` from inside the
                // protocol loop made Zig's Maker retain a stale `failed command`
                // diagnostic even after a PASS on piped focused runs.
                switch (serverExit(verdict)) {
                    .return_normally => return,
                    .cap_failure => std.process.exit(1),
                }
            },
            .query_test_metadata => try serveMetadata(&server),
            .run_test => try serveOneTest(&server, try server.receiveBody_u32()),
            .start_fuzzing => try startFuzzing(&server),
            else => fatal("unsupported test protocol message"),
        }
    }
}

fn serverExit(verdict: timing.Verdict) ServerExit {
    return if (verdict.caps_broken) .cap_failure else .return_normally;
}

// spec: Test Runner Verdict - Returns normally from a passing build-server run after printing its result

test "server exit is normal after a green result and nonzero only for a broken cap" {
    try testing.expectEqual(ServerExit.return_normally, serverExit(.{ .tally = .{ .ok = 3 } }));
    try testing.expectEqual(ServerExit.return_normally, serverExit(.{ .tally = .{ .fail = 1 } }));
    try testing.expectEqual(ServerExit.cap_failure, serverExit(.{ .caps_broken = true }));
}

/// Answers the build system's metadata query with every test in this binary.
fn serveMetadata(server: *std.zig.Server) !void {
    @disableInstrumentation();
    initTestState(0xc3a701ba);
    defer if (deinitTestState() != 0) fatal("internal test runner memory leak");

    var string_bytes: std.ArrayList(u8) = .empty;
    defer string_bytes.deinit(testing.allocator);
    try string_bytes.append(testing.allocator, 0); // Reserve 0 for null.

    const test_fns = builtin.test_functions;
    const names = try testing.allocator.alloc(u32, test_fns.len);
    defer testing.allocator.free(names);
    const expected_panic_msgs = try testing.allocator.alloc(u32, test_fns.len);
    defer testing.allocator.free(expected_panic_msgs);

    for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
        name.* = @intCast(string_bytes.items.len);
        try string_bytes.ensureUnusedCapacity(testing.allocator, test_fn.name.len + 1);
        string_bytes.appendSliceAssumeCapacity(test_fn.name);
        string_bytes.appendAssumeCapacity(0);
        expected_panic_msg.* = 0;
    }

    try server.serveTestMetadata(.{
        .names = names,
        .expected_panic_msgs = expected_panic_msgs,
        .string_bytes = string_bytes.items,
    });
}

/// Runs one test by index and reports its result over the protocol.
fn serveOneTest(server: *std.zig.Server, index: u32) !void {
    @disableInstrumentation();
    initTestState(0xc3a701ba);
    log_err_count = 0;
    is_fuzz_test = false;
    try server.serveStringMessage(.test_started, &.{});

    var fail = false;
    var skip = false;
    const started = Io.Clock.awake.now(runner_io);
    builtin.test_functions[index].func() catch |err| switch (err) {
        error.SkipZigTest => skip = true,
        else => {
            fail = true;
            dumpFailureTrace();
        },
    };
    const leak_count = deinitTestState();
    recordDuration(builtin.test_functions[index].name, elapsedSince(started));
    // `log_err_count` was zeroed above, so it holds THIS test's errors.
    recordResult(if (fail) .fail else if (skip) .skip else .pass, leak_count, log_err_count);

    try server.serveTestResults(.{
        .index = index,
        .flags = .{
            .status = if (fail) .fail else if (skip) .skip else .pass,
            .fuzz = is_fuzz_test,
            .log_err_count = std.math.lossyCast(
                @FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"),
                log_err_count,
            ),
            .leak_count = std.math.lossyCast(
                @FieldType(std.zig.Server.Message.TestResults.Flags, "leak_count"),
                leak_count,
            ),
        },
    });
}

/// Hands the selected fuzz tests to Zig's current multi-test fuzzing ABI.
fn startFuzzing(server: *std.zig.Server) !void {
    @disableInstrumentation();
    if (!builtin.fuzz) return;

    var allocator_instance: std.heap.SafeAllocator = .init(runner_backing_allocator, .{});
    defer if (allocator_instance.deinit() != 0) fatal("internal fuzz runner memory leak");
    const allocator = allocator_instance.allocator();
    var io_instance: Io.Threaded = .init(allocator, .{
        .argv0 = .init(runner_args),
        .environ = runner_environ,
    });
    defer io_instance.deinit();
    const io = io_instance.io();

    const mode: fuzz_abi.LimitKind = @fromBackingInt(@intCast(try server.receiveBody_u8()));
    const amount_or_instance = try server.receiveBody_u64();
    const main_instance = mode == .iterations or amount_or_instance == 0;
    if (main_instance) {
        const coverage = fuzz_abi.fuzzer_coverage();
        try server.serveCoverageIdMessage(coverage.id, coverage.runs, coverage.unique, coverage.seen);
    }

    const test_count = try server.receiveBody_u32();
    const indexes = try allocator.alloc(u32, test_count);
    defer allocator.free(indexes);
    fuzz_runner = .{
        .indexes = indexes,
        .server = server,
        .allocator = allocator,
        .io = io,
        .input_poller = null,
    };

    var large_name: std.ArrayList(u8) = .empty;
    defer large_name.deinit(allocator);
    for (indexes) |*index| {
        const name_len = try server.receiveBody_u32();
        const name = if (name_len <= server.in.buffer.len)
            try server.in.take(name_len)
        else name: {
            try large_name.resize(allocator, name_len);
            try server.in.readSliceAll(large_name.items);
            break :name large_name.items;
        };
        index.* = fuzzTestIndex(name) orelse fatal("requested fuzz test no longer exists");

        if (main_instance) {
            const relocated = @intFromPtr(builtin.test_functions[index.*].func);
            try server.serveU64Message(.fuzz_start_addr, fuzz_abi.fuzzer_unslide_address(relocated));
        }
    }

    fuzz_abi.fuzzer_main(test_count, testing.random_seed, mode, amount_or_instance);
    std.debug.assert(mode != .forever);
    std.process.exit(0);
}

/// Resolves the build server's selected fuzz-test name to the ABI index.
fn fuzzTestIndex(name: []const u8) ?u32 {
    for (builtin.test_functions, 0..) |test_fn, candidate| {
        if (std.mem.eql(u8, name, test_fn.name)) return @intCast(candidate);
    }
    return null;
}

/// Folds one finished test into the run tally — the single place either mode
/// counts, so the closing verdict cannot disagree with what ran. `leak_count`
/// is that test's leaked allocations (any is one leaking test) and `log_errs`
/// its logged errors.
fn recordResult(status: timing.Status, leak_count: usize, log_errs: usize) void {
    @disableInstrumentation();
    run_tally.record(status);
    if (leak_count != 0) run_tally.leak +|= 1;
    run_tally.log_err +|= log_errs;
}

/// Runs every test and reports to the terminal — the path taken when the binary
/// is executed directly instead of through the build system.
fn mainTerminal() void {
    @disableInstrumentation();
    const tests = builtin.test_functions;
    const root_node = if (builtin.fuzz) std.Progress.Node.none else std.Progress.start(runner_io, .{
        .root_name = "Test",
        .estimated_total_items = tests.len,
    });

    for (tests, 0..) |test_fn, i| {
        initTestState(0xc3a701ba);
        testing.log_level = .warn;
        is_fuzz_test = false;
        const node = root_node.start(test_fn.name, 0);
        const started = Io.Clock.awake.now(runner_io);
        const status = runOneTest(test_fn, i);
        // Terminal mode never zeroes `log_err_count`, so it is summed once
        // below rather than per test.
        recordResult(status, deinitTestState(), 0);
        recordDuration(test_fn.name, elapsedSince(started));
        node.end();
    }
    root_node.end();
    run_tally.log_err = log_err_count;
    writeSummary(run_tally, tests.len);
    reportTimings();
    const verdict: timing.Verdict = .{ .tally = run_tally, .caps_broken = capsFailed() };
    announceVerdict(verdict);
    if (verdict.failed()) std.process.exit(1);
}

/// Runs one test, printing a line for anything that is not a plain pass, and
/// reports what it was.
fn runOneTest(test_fn: std.builtin.TestFn, index: usize) timing.Status {
    @disableInstrumentation();
    var buf: [report_buffer_bytes]u8 = undefined;
    test_fn.func() catch |err| {
        if (err == error.SkipZigTest) {
            writeErr(std.fmt.bufPrint(&buf, "{d} {s}...SKIP\n", .{ index + 1, test_fn.name }) catch "");
            return .skip;
        }
        writeErr(std.fmt.bufPrint(&buf, "{d} {s}...FAIL ({s})\n", .{
            index + 1,
            test_fn.name,
            @errorName(err),
        }) catch "");
        dumpFailureTrace();
        return .fail;
    };
    return .pass;
}

/// Prints the assertion's error-return trace, or an actionable explanation for
/// optimized consumer test modules that compiled tracing out. The latter used
/// to leave only `FAIL (TestUnexpectedResult)`, with no source location and no
/// indication that the build configuration had discarded it.
fn dumpFailureTrace() void {
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpErrorReturnTrace(trace);
        return;
    }
    writeErr(missing_error_trace);
}

/// Prints the closing counts, matching the stock runner's wording. Terminal
/// mode only: the server protocol reports each result as it happens, so this
/// path is never reached under `zig build test`.
fn writeSummary(tally: timing.Tally, total: usize) void {
    var buf: [report_buffer_bytes]u8 = undefined;
    if (tally.ok == total) {
        writeErr(std.fmt.bufPrint(&buf, "All {d} tests passed.\n", .{tally.ok}) catch "");
    } else {
        writeErr(std.fmt.bufPrint(&buf, "{d} passed; {d} skipped; {d} failed.\n", .{
            tally.ok,
            tally.skip,
            tally.fail,
        }) catch "");
    }
    if (tally.log_err != 0) {
        writeErr(std.fmt.bufPrint(&buf, "{d} errors were logged.\n", .{tally.log_err}) catch "");
    }
    if (tally.leak != 0) {
        writeErr(std.fmt.bufPrint(&buf, "{d} tests leaked memory.\n", .{tally.leak}) catch "");
    }
}

/// Folds one finished test into the timing tally: its time joins the total, it
/// is warned about if it is slow, it is held as an offender if it broke the
/// opt-in per-test cap, and it joins the slow list when it clears the reporting
/// floor. `name` points at `builtin.test_functions`, which outlives the run.
fn elapsedSince(started: Io.Timestamp) u64 {
    return @intCast(started.untilNow(runner_io, .awake).toNanoseconds());
}

fn recordDuration(name: []const u8, ns: u64) void {
    @disableInstrumentation();
    total_test_ns +|= ns;
    const entry: timing.Slow = .{ .ns = ns, .name = name };
    warnIfSlow(entry);
    if (timing_caps.overPerTest(ns)) timing.recordOffender(&over_list, &over, entry);
    if (ns < timing_limits.floor_ns) return;
    timing.insertSlow(&slow_list, &slow_len, timing_limits.max_lines, entry);
}

/// Streams the always-on slow warning the moment a test finishes, rather than
/// only in the closing table — a creeping hog is then named on every run,
/// including one whose output nobody reads to the end.
fn warnIfSlow(entry: timing.Slow) void {
    @disableInstrumentation();
    if (!timing.isSlow(entry.ns)) return;
    var buf: [report_buffer_bytes]u8 = undefined;
    writeErr(timing.renderSlowWarning(&buf, entry));
}

/// Prints the run's total test wall and its slowest tests, most expensive
/// first — the data that names a suite's run-time hogs (see test_timing.zig
/// for why). Runs after the last test in both modes; a run that dies early
/// skips it, because a diagnostic must never displace the failure itself.
fn reportTimings() void {
    @disableInstrumentation();
    var buf: [report_buffer_bytes]u8 = undefined;
    writeErr(timing.renderWall(&buf, total_test_ns, slow_len, timing_limits.floor_ns));
    for (slow_list[0..slow_len]) |entry| {
        writeErr(timing.renderSlowLine(&buf, entry));
    }
    reportCaps();
}

/// Prints the opt-in caps' verdict, after every test has run and everything
/// else has been reported. Breaking a cap never cuts the run short: a suite
/// that stops at the first slow test hides the others, and the point is to see
/// the whole cost. The exit code is `capsFailed`.
///
/// A cap is not a watchdog — it is read off a test that FINISHED, so a hung
/// test still hangs and nothing here fires. These catch cost regressions.
fn reportCaps() void {
    @disableInstrumentation();
    var buf: [report_buffer_bytes]u8 = undefined;
    if (over.count != 0) {
        writeErr(timing.renderTestCapFailure(&buf, over, timing_caps.per_test_ns));
        for (over_list[0..over.stored]) |entry| writeErr(timing.renderSlowLine(&buf, entry));
    }
    if (timing_caps.overWall(total_test_ns)) {
        writeErr(timing.renderWallCapFailure(&buf, total_test_ns, timing_caps.wall_ns));
    }
}

/// True when either opt-in cap was broken, in which case the run fails even
/// though every test passed. Both caps are unset by default, so this is false
/// for every run that did not ask for them.
fn capsFailed() bool {
    @disableInstrumentation();
    return over.count != 0 or timing_caps.overWall(total_test_ns);
}

/// Counts logged errors so a test that only logs one still fails, and echoes
/// messages at or above the testing log level. Private: `std_options` is the
/// only thing that needs it, and std reads it through there.
fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) log_err_count +|= 1;
    if (@backingInt(message_level) > @backingInt(testing.log_level)) return;
    var buf: [report_buffer_bytes]u8 = undefined;
    const line = "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n";
    writeErr(std.fmt.bufPrint(&buf, line, args) catch "");
}

const FuzzRunner = if (builtin.fuzz) struct {
    indexes: []u32,
    server: *std.zig.Server,
    allocator: std.mem.Allocator,
    io: Io,
    input_poller: ?Io.Future(Io.Cancelable!void),

    fn state() *@This() {
        return &fuzz_runner.?;
    }

    export fn runner_test_run(i: u32) void {
        @disableInstrumentation();
        const runner = state();
        runner.server.serveU32Message(.fuzz_test_change, i) catch
            fatal("failed to report fuzz-test change");

        testing.allocator_instance = .init(runner_backing_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        defer if (testing.allocator_instance.deinit() != 0) std.process.exit(1);
        is_fuzz_test = false;

        builtin.test_functions[runner.indexes[i]].func() catch |err| switch (err) {
            error.SkipZigTest => return,
            else => {
                dumpFailureTrace();
                fatal(@errorName(err));
            },
        };
        if (!is_fuzz_test) fatal("missed call to std.testing.fuzz");
        if (log_err_count != 0) fatal("error logs detected");
    }

    export fn runner_test_name(i: u32) fuzz_abi.Slice {
        @disableInstrumentation();
        return .fromSlice(builtin.test_functions[state().indexes[i]].name);
    }

    export fn runner_broadcast_input(test_i: u32, bytes_slice: fuzz_abi.Slice) void {
        @disableInstrumentation();
        state().server.serveBroadcastFuzzInputMessage(test_i, bytes_slice.toSlice()) catch
            fatal("failed to broadcast fuzz input");
    }

    export fn runner_start_input_poller() void {
        @disableInstrumentation();
        const runner = state();
        runner.input_poller = runner.io.concurrent(inputPoller, .{}) catch
            fatal("failed to spawn fuzz input poller");
    }

    export fn runner_stop_input_poller() void {
        @disableInstrumentation();
        const runner = state();
        std.debug.assert(runner.input_poller.?.cancel(runner.io) == error.Canceled);
    }

    export fn runner_futex_wait(ptr: *const u32, expected: u32) bool {
        @disableInstrumentation();
        return state().io.futexWait(u32, ptr, expected) == error.Canceled;
    }

    export fn runner_futex_wake(ptr: *const u32, waiters: u32) void {
        @disableInstrumentation();
        state().io.futexWake(u32, ptr, waiters);
    }

    fn inputPoller() Io.Cancelable!void {
        @disableInstrumentation();
        switch (inputPollerInner()) {
            error.Canceled => |err| return err,
            error.ReadFailed => {
                if (stdin_reader.err.? == error.Canceled) return error.Canceled;
                fatal("failed to read fuzz input from build server");
            },
            error.EndOfStream => fatal("unexpected end of fuzz input stream"),
        }
    }

    fn inputPollerInner() (Io.Cancelable || Io.Reader.Error) {
        @disableInstrumentation();
        var large_bytes: std.ArrayList(u8) = .empty;
        const runner = state();
        defer large_bytes.deinit(runner.allocator);
        while (true) {
            const header = try runner.server.receiveMessage();
            if (header.tag != .new_fuzz_input) fatal("unexpected fuzz protocol message");
            const test_i = try runner.server.receiveBody_u32();
            const input_len = header.bytes_len - 4;
            const bytes = if (input_len <= runner.server.in.buffer.len)
                try runner.server.in.take(input_len)
            else bytes: {
                large_bytes.resize(runner.allocator, @intCast(input_len)) catch
                    fatal("out of memory receiving fuzz input");
                try runner.server.in.readSliceAll(large_bytes.items);
                break :bytes large_bytes.items;
            };
            if (fuzz_abi.fuzzer_receive_input(test_i, .fromSlice(bytes))) return error.Canceled;
        }
    }
} else struct {};
var fuzz_runner: ?FuzzRunner = null;

/// `std.testing.fuzz` dispatches to the root module, so every runner must
/// provide this. Same contract as the stock runner: with `--fuzz` it hands
/// `testOne` to the fuzzer, otherwise it runs the corpus plus one empty input.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    // Keep this function's own coverage out of the fuzzer's view.
    @disableInstrumentation();

    // Smoke test: a test that compiles itself out of being a fuzz test in fuzz
    // mode would otherwise report a meaningless pass.
    is_fuzz_test = true;
    if (log_err_count != 0) fatal("error logs detected before fuzzing");

    const global = struct {
        var ctx: @TypeOf(context) = undefined;

        fn fuzzer_one() callconv(.c) bool {
            @disableInstrumentation();
            testing.allocator_instance = .init(runner_backing_allocator, .{
                .canary = 0xcacce5e0,
                .check_write_after_free = true,
            });
            defer if (testing.allocator_instance.deinit() != 0) std.process.exit(1);
            log_err_count = 0;
            var smith: testing.Smith = .{ .in = null };
            testOne(ctx, &smith) catch |err| switch (err) {
                error.SkipZigTest => return true,
                else => {
                    if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                    fatal(@errorName(err));
                },
            };
            if (log_err_count != 0) fatal("error logs detected");
            return false;
        }
    };

    if (builtin.fuzz) {
        const prev_allocator_state = testing.allocator_instance;
        defer testing.allocator_instance = prev_allocator_state;

        global.ctx = context;
        fuzz_abi.fuzzer_set_test(&global.fuzzer_one);
        for (options.corpus) |elem| fuzz_abi.fuzzer_new_input(.fromSlice(elem));
        fuzz_abi.fuzzer_start_test();
        return;
    }

    // Outside fuzz mode a fuzz test is a corpus replay, plus the empty input as
    // a smoke test.
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

// ── Tests ──────────────────────────────────────────────────────────────
//
// A custom runner's test decls are never collected into the binary it runs (the
// compiler takes tests from the module under test), and the same file cannot
// belong to both modules. So these run from their own compilation, on the stock
// runner, wired into `zig build test` by build.zig.

// Collect the timing module's tests into that same compilation.
test {
    _ = timing;
}

// spec: Test Runner - Prints the number of selected tests before any test runs

test "the pre-run report states how many tests were selected" {
    var buf: [report_buffer_bytes]u8 = undefined;
    const rendered = report(&buf, .{ .count = 412 }, false);
    try testing.expectEqualStrings("guardian/test: 412 test(s) selected\n", rendered.text);
    try testing.expect(!rendered.fatal);
}

// spec: Test Runner - Explains how to restore assertion locations when an optimized test module disables error tracing
test "missing error trace diagnostic names the build-helper fix" {
    try testing.expect(std.mem.indexOf(u8, missing_error_trace, "assertion location unavailable") != null);
    try testing.expect(std.mem.indexOf(u8, missing_error_trace, "enableTestDiagnostics") != null);
}

// spec: Test Runner - Names the filters that selected the tests and summarizes any beyond the first few

test "the pre-run report quotes the forwarded filters" {
    var buf: [report_buffer_bytes]u8 = undefined;
    const two = report(&buf, .{
        .count = 3,
        .matched = 3,
        .named = &.{ "alpha", "beta" },
        .filters = 2,
    }, false);
    try testing.expectEqualStrings(
        "guardian/test: 3 test(s) selected by filter: \"alpha\", \"beta\"\n",
        two.text,
    );

    // More filters than the report names individually: the rest are counted,
    // never silently dropped.
    var wide: [report_buffer_bytes]u8 = undefined;
    const many = report(&wide, .{
        .count = 9,
        .matched = 9,
        .named = &.{ "a", "b", "c" },
        .filters = 5,
    }, false);
    try testing.expectEqualStrings(
        "guardian/test: 9 test(s) selected by filter: \"a\", \"b\", \"c\" (+2 more)\n",
        many.text,
    );
}

// spec: Test Runner - Fails a run in which no selected test matches the filter

test "a zero-match filter is reported as fatal even when unnamed blocks ran" {
    var buf: [report_buffer_bytes]u8 = undefined;
    // The trap this guards: two unnamed `test { }` blocks compiled in, so the
    // raw count is 2 and the run would look like it did something.
    const rendered = report(&buf, .{
        .count = 2,
        .matched = 0,
        .named = &.{"nope"},
        .filters = 1,
    }, false);
    try testing.expect(rendered.fatal);
    // The count line still leads, so the filter that matched nothing is named.
    try testing.expect(std.mem.startsWith(
        u8,
        rendered.text,
        "guardian/test: 2 test(s) selected by filter: \"nope\" — 0 match by name",
    ));
    // And the run is told why that is not a pass, plus how to get out of it.
    try testing.expect(std.mem.indexOf(u8, rendered.text, "NOTHING YOU ASKED FOR RAN") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.text, "--test-filter") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.text, allow_empty_env) != null);
}

// spec: Test Runner - Counts only the selected tests a filter names, since unnamed blocks always run

test "unnamed blocks are counted apart from the tests the filter named" {
    // Zig matches a filter as a substring of the fully qualified test name.
    try testing.expect(nameMatches("check.test.alpha one", &.{"lpha"}));
    try testing.expect(nameMatches("check.test.beta", &.{ "zzz", "beta" }));
    // An unnamed block's generated name carries none of the filter text, which
    // is why it can never be *selected* by one — only survive it.
    try testing.expect(!nameMatches("check.test_0", &.{"lpha"}));
    try testing.expect(!nameMatches("check.test.alpha", &.{}));

    var buf: [report_buffer_bytes]u8 = undefined;
    const rendered = report(&buf, .{ .count = 5, .matched = 3, .named = &.{"lpha"}, .filters = 1 }, false);
    // Three are the caller's; the other two would have run under any filter.
    try testing.expect(!rendered.fatal);
    try testing.expect(std.mem.indexOf(u8, rendered.text, "3 match by name") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.text, "2 unnamed test block(s)") != null);
}

// spec: Test Runner - Permits an empty run only when the empty-suite opt-out is set

test "the opt-out downgrades a zero-test run to a warning" {
    var buf: [report_buffer_bytes]u8 = undefined;
    // No filters at all (matched is unknown): a suite with no tests yet.
    const rendered = report(&buf, .{ .count = 0 }, true);
    try testing.expect(!rendered.fatal);
    try testing.expect(std.mem.indexOf(u8, rendered.text, "evidence of nothing") != null);
}

// spec: Test Runner - Treats an empty or zero-valued opt-out variable as unset

test "optOutActive follows the GUARDIAN_ flag spelling" {
    try testing.expect(optOutActive("1"));
    try testing.expect(optOutActive("yes"));
    try testing.expect(!optOutActive("0"));
    try testing.expect(!optOutActive(""));
    try testing.expect(!optOutActive(null));
}

// spec: Test Runner - Counts a logged error so a test that only logs one still fails

test "the installed log hook counts errors" {
    const before = log_err_count;
    defer log_err_count = before;
    // Called through std_options, which is the wiring std itself uses: if that
    // hook is ever dropped, a test that only logs an error would start passing.
    std_options.logFn(.err, .guardian_test_runner, "expected: exercising the error counter", .{});
    try testing.expectEqual(before + 1, log_err_count);
}

test "fuzz protocol resolves the selected test name to its ABI index" {
    try testing.expect(builtin.test_functions.len > 0);
    try testing.expectEqual(@as(?u32, 0), fuzzTestIndex(builtin.test_functions[0].name));
    try testing.expectEqual(@as(?u32, null), fuzzTestIndex("guardian.missing-fuzz-test"));
}
