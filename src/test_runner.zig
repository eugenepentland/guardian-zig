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
//! Protocol parity with the stock runner: it speaks `std.zig.Server` over stdio
//! when the build system passes `--listen=-`, and reports to the terminal when
//! run directly. Deviations: the exotic-backend paths (SPIR-V, the `mainSimple`
//! crippled-backend fallback) are not carried over, the terminal fallback prints
//! failures and the summary rather than echoing every passing test, and an
//! unrecognized argument is ignored rather than fatal — a future build-system
//! flag must not take out every consumer's suite.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const timing = @import("test_timing.zig");

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

/// Bytes reserved for argv and the env read done before any test runs.
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

// Process-lifetime state. A test runner is an entry point: the log counter, the
// argv arena, the protocol buffers, and the fuzz flag are all singletons of the
// process, exactly as they are in the stock runner (see the ban-globals
// exemption in guardian.toml).
var log_err_count: usize = 0;
var fba_buffer: [args_arena_bytes]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
var stdin_buffer: [io_buffer_bytes]u8 = undefined;
var stdout_buffer: [io_buffer_bytes]u8 = undefined;
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
pub fn main() void {
    @disableInstrumentation();

    const argv = std.process.argsAlloc(fba.allocator()) catch
        fatal("out of memory parsing command line arguments");
    var args: Args = .{};
    parseArgs(argv[1..], &args);
    announce(args);
    timing_limits = timing.Limits.forDetail(
        if (optOutActive(readEnv(timings_env))) .wide else .standard,
    );
    fba.reset();

    if (builtin.fuzz) {
        const cache_dir = args.cache_dir orelse fatal("missing --cache-dir=[path] argument");
        fuzzer_init(FuzzerSlice.fromSlice(cache_dir));
    }

    if (args.listen) return mainServer() catch fatal("internal test runner failure");
    return mainTerminal();
}

/// Reads the command line, ignoring anything unrecognized.
fn parseArgs(argv: []const [:0]u8, out: *Args) void {
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
    if (rendered.fatal) std.process.exit(1);
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

/// Reads one GUARDIAN_* variable from the environment. Runs before
/// `fba.reset()`, so the returned text lives in the argv arena.
fn readEnv(name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(fba.allocator(), name) catch null;
}

/// Writes to stderr, dropping the message if the handle is unusable — a failed
/// diagnostic must never replace the test result it was describing.
fn writeErr(bytes: []const u8) void {
    std.fs.File.stderr().writeAll(bytes) catch return;
}

/// Prints `message` and exits nonzero. This file is the process entry point, so
/// the raw exit is the sanctioned one (see the fatal-exit check).
fn fatal(message: []const u8) noreturn {
    writeErr(prefix);
    writeErr(message);
    writeErr("\n");
    std.process.exit(1);
}

/// Serves the build system's test protocol over stdio — the mode every
/// `zig build test` uses.
fn mainServer() !void {
    @disableInstrumentation();
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });

    if (builtin.fuzz) try server.serveU64Message(.coverage_id, fuzzer_coverage_id());

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                reportTimings();
                return std.process.exit(0);
            },
            .query_test_metadata => try serveMetadata(&server),
            .run_test => try serveOneTest(&server, try server.receiveBody_u32()),
            .start_fuzzing => try startFuzzing(&server, try server.receiveBody_u32()),
            else => fatal("unsupported test protocol message"),
        }
    }
}

/// Answers the build system's metadata query with every test in this binary.
fn serveMetadata(server: *std.zig.Server) !void {
    @disableInstrumentation();
    testing.allocator_instance = .{};
    defer if (testing.allocator_instance.deinit() == .leak) fatal("internal test runner memory leak");

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
    testing.allocator_instance = .{};
    log_err_count = 0;
    is_fuzz_test = false;

    var fail = false;
    var skip = false;
    var timer: ?std.time.Timer = std.time.Timer.start() catch null;
    builtin.test_functions[index].func() catch |err| switch (err) {
        error.SkipZigTest => skip = true,
        else => {
            fail = true;
            dumpFailureTrace();
        },
    };
    const leak = testing.allocator_instance.deinit() == .leak;
    if (timer) |*t| recordDuration(builtin.test_functions[index].name, t.read());

    try server.serveTestResults(.{
        .index = index,
        .flags = .{
            .fail = fail,
            .skip = skip,
            .leak = leak,
            .fuzz = is_fuzz_test,
            .log_err_count = std.math.lossyCast(
                @FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"),
                log_err_count,
            ),
        },
    });
}

/// Hands one fuzz test to the fuzzer, as the stock runner does.
fn startFuzzing(server: *std.zig.Server, index: u32) !void {
    @disableInstrumentation();
    if (!builtin.fuzz) return;
    const test_fn = builtin.test_functions[index];
    try server.serveU64Message(.fuzz_start_addr, @intFromPtr(test_fn.func));
    defer if (testing.allocator_instance.deinit() == .leak) std.process.exit(1);
    is_fuzz_test = false;
    fuzzer_set_name(test_fn.name.ptr, test_fn.name.len);
    test_fn.func() catch |err| switch (err) {
        error.SkipZigTest => return,
        else => {
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
            fatal(@errorName(err));
        },
    };
    if (!is_fuzz_test) fatal("missed call to std.testing.fuzz");
    if (log_err_count != 0) fatal("error logs detected");
}

/// Tally of one terminal-mode run.
const Tally = struct {
    ok: usize = 0,
    skip: usize = 0,
    fail: usize = 0,
    leak: usize = 0,

    fn failed(self: Tally) bool {
        return self.fail != 0 or self.leak != 0 or log_err_count != 0;
    }
};

/// Runs every test and reports to the terminal — the path taken when the binary
/// is executed directly instead of through the build system.
fn mainTerminal() void {
    @disableInstrumentation();
    const tests = builtin.test_functions;
    const root_node = if (builtin.fuzz) std.Progress.Node.none else std.Progress.start(.{
        .root_name = "Test",
        .estimated_total_items = tests.len,
    });

    var tally: Tally = .{};
    for (tests, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.log_level = .warn;
        is_fuzz_test = false;
        const node = root_node.start(test_fn.name, 0);
        var timer: ?std.time.Timer = std.time.Timer.start() catch null;
        runOneTest(test_fn, i, &tally);
        if (testing.allocator_instance.deinit() == .leak) tally.leak += 1;
        if (timer) |*t| recordDuration(test_fn.name, t.read());
        node.end();
    }
    root_node.end();
    writeSummary(tally, tests.len);
    reportTimings();
    if (tally.failed()) std.process.exit(1);
}

/// Runs one test, printing a line for anything that is not a plain pass.
fn runOneTest(test_fn: std.builtin.TestFn, index: usize, tally: *Tally) void {
    @disableInstrumentation();
    var buf: [report_buffer_bytes]u8 = undefined;
    test_fn.func() catch |err| {
        if (err == error.SkipZigTest) {
            tally.skip += 1;
            writeErr(std.fmt.bufPrint(&buf, "{d} {s}...SKIP\n", .{ index + 1, test_fn.name }) catch "");
            return;
        }
        tally.fail += 1;
        writeErr(std.fmt.bufPrint(&buf, "{d} {s}...FAIL ({s})\n", .{
            index + 1,
            test_fn.name,
            @errorName(err),
        }) catch "");
        dumpFailureTrace();
        return;
    };
    tally.ok += 1;
}

/// Prints the assertion's error-return trace, or an actionable explanation for
/// optimized consumer test modules that compiled tracing out. The latter used
/// to leave only `FAIL (TestUnexpectedResult)`, with no source location and no
/// indication that the build configuration had discarded it.
fn dumpFailureTrace() void {
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace.*);
        return;
    }
    writeErr(missing_error_trace);
}

/// Prints the closing counts, matching the stock runner's wording.
fn writeSummary(tally: Tally, total: usize) void {
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
    if (log_err_count != 0) {
        writeErr(std.fmt.bufPrint(&buf, "{d} errors were logged.\n", .{log_err_count}) catch "");
    }
    if (tally.leak != 0) {
        writeErr(std.fmt.bufPrint(&buf, "{d} tests leaked memory.\n", .{tally.leak}) catch "");
    }
}

/// Folds one finished test into the timing tally: its time joins the total,
/// and it joins the slow list when it clears the reporting floor.
fn recordDuration(name: []const u8, ns: u64) void {
    @disableInstrumentation();
    total_test_ns +|= ns;
    if (ns < timing_limits.floor_ns) return;
    timing.insertSlow(&slow_list, &slow_len, timing_limits.max_lines, .{ .ns = ns, .name = name });
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
}

/// Counts logged errors so a test that only logs one still fails, and echoes
/// messages at or above the testing log level. Private: `std_options` is the
/// only thing that needs it, and std reads it through there.
fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(message_level) > @intFromEnum(testing.log_level)) return;
    var buf: [report_buffer_bytes]u8 = undefined;
    const line = "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n";
    writeErr(std.fmt.bufPrint(&buf, line, args) catch "");
}

const FuzzerSlice = extern struct {
    ptr: [*]const u8,
    len: usize,

    /// Inline to avoid fuzzer instrumentation.
    inline fn fromSlice(s: []const u8) FuzzerSlice {
        return .{ .ptr = s.ptr, .len = s.len };
    }
};

extern fn fuzzer_set_name(name_ptr: [*]const u8, name_len: usize) void;
extern fn fuzzer_init(cache_dir: FuzzerSlice) void;
extern fn fuzzer_init_corpus_elem(input_ptr: [*]const u8, input_len: usize) void;
extern fn fuzzer_start(testOne: *const fn ([*]const u8, usize) callconv(.c) void) void;
extern fn fuzzer_coverage_id() u64;

/// `std.testing.fuzz` dispatches to the root module, so every runner must
/// provide this. Same contract as the stock runner: with `--fuzz` it hands
/// `testOne` to the fuzzer, otherwise it runs the corpus plus one empty input.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), []const u8) anyerror!void,
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

        fn fuzzer_one(input_ptr: [*]const u8, input_len: usize) callconv(.c) void {
            @disableInstrumentation();
            testing.allocator_instance = .{};
            defer if (testing.allocator_instance.deinit() == .leak) std.process.exit(1);
            log_err_count = 0;
            testOne(ctx, input_ptr[0..input_len]) catch |err| switch (err) {
                error.SkipZigTest => return,
                else => {
                    if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
                    fatal(@errorName(err));
                },
            };
            if (log_err_count != 0) fatal("error logs detected");
        }
    };

    if (builtin.fuzz) {
        const prev_allocator_state = testing.allocator_instance;
        testing.allocator_instance = .{};
        defer testing.allocator_instance = prev_allocator_state;

        for (options.corpus) |elem| fuzzer_init_corpus_elem(elem.ptr, elem.len);
        global.ctx = context;
        fuzzer_start(&global.fuzzer_one);
        return;
    }

    // Outside fuzz mode a fuzz test is a corpus replay, plus the empty input as
    // a smoke test.
    for (options.corpus) |input| try testOne(context, input);
    try testOne(context, "");
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
