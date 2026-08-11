//! Terminal output plus the `Violation` value type. `ok`/`fail`/`detail` print
//! the `guardian: ` status lines; `Violation` carries the structured
//! `ratchet_key`/`metric` hooks the per-item ratchets and the JSONL sink read
//! without re-parsing prose. Output is unbuffered debug.print to stderr.

const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub const green = "\x1b[32m";
const yellow = "\x1b[33m";
pub const red = "\x1b[31m";
pub const reset = "\x1b[0m";
pub const prefix = "guardian: ";

/// A single check failure with optional location and fix hint.
///
/// `check` names the producing check; `ratchet_key`/`metric` are the structured
/// hooks per-item ratchets and the JSONL sink read without re-parsing prose:
/// a stable per-subject identity (`"src/foo.zig|parse"` for a fn,
/// `"src/foo.zig|Config"` for a type, `"src/foo.zig"` for a file metric) and
/// the measured scalar behind the threshold. `message` is the human-facing tail
/// rendered after `file:line:` — see `flatLine`.
///
/// `identity` names *what was flagged*, independently of how the finding is
/// worded: the prong set, the repeated literal, the deprecated alias. It is the
/// top tier of the baseline v3 key (see `violation_key.zig`), so a check that
/// sets it may reword its message freely without re-keying any consumer's
/// baseline. Set it on any check whose message embeds churn-prone context
/// (counts, file lists, measured values); leave it null to fall back to the
/// message skeleton.
///
/// `alert` marks an advisory finding that must survive being summarized away.
/// Warnings collapse to a bare count under `--summary` and on a diff-scoped run
/// whose changed files they miss — correct for the bulk advisory tier, fatal for
/// the one finding that says a file is about to cross a BLOCKING limit (see
/// `near_cap.zig`). The run summary replays an alert whatever the collapse
/// decision was. It changes nothing else: an alert is still a warning, so no
/// baseline, ratchet or snapshot ever records it.
pub const Violation = struct {
    check: []const u8 = "",
    file: ?[]const u8 = null,
    line: ?u32 = null,
    message: []const u8,
    fix_hint: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    ratchet_key: ?[]const u8 = null,
    metric: ?u64 = null,
    alert: bool = false,
};

/// One finding routed to the non-blocking measurement channel: the check that
/// found it, the `[measurement]` path it was attributed to, and its rendered
/// violation line. A deferred finding is neither a blocking violation nor an
/// advisory warning — it is the same violation the commit-time gate will raise,
/// held open only for a local run (see measurement.zig).
pub const Measured = struct {
    check: []const u8 = "",
    path: []const u8 = "",
    message: []const u8,
};

/// Renders a Violation to its single-line human form without the leading
/// two-space indent or trailing newline: `"<file>:<line>: <message>"`,
/// `"<file>: <message>"`, or `"<message>"`. This is exactly the body `emit`
/// indents and prints, so a migrated check whose `run` emits Violations stays
/// byte-for-byte identical to the pre-migration hand-formatted `  {s}\n`, and
/// baseline capture can render structured records to the same stored lines.
pub fn flatLine(arena: Allocator, v: Violation) Allocator.Error![]const u8 {
    if (v.file) |f| {
        if (v.line) |l| return std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ f, l, v.message });
        return std.fmt.allocPrint(arena, "{s}: {s}", .{ f, v.message });
    }
    return arena.dupe(u8, v.message);
}

/// Renders each Violation to its `flatLine`, returning the arena-owned slice the
/// golden harness, single-check `analyzeContent` entry points, and baseline
/// capture use to keep working with plain violation-line text.
pub fn flatLines(arena: Allocator, records: []const Violation) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, records.len);
    for (records, 0..) |v, i| out[i] = try flatLine(arena, v);
    return out;
}

/// Captures formatted output instead of printing it. Used by baseline
/// mode to intercept a check's violation lines for diffing, and by the
/// `all` runner to collect each check's structured Violations for the JSONL
/// sink — `buf` is the raw text (still scraped for unmigrated checks),
/// `records` the structured Violations emitted through `Reporter.emit`.
pub const Capture = struct {
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,
    records: std.ArrayList(Violation) = .empty,
    /// Advisory findings are separate from blocking violation records so
    /// baselines and ratchets never turn a warning into acceptance work.
    warnings: std.ArrayList(Violation) = .empty,
    /// Findings deferred by a live `[measurement]` exemption. Kept out of
    /// `records` so no baseline, ratchet, or snapshot can be written from an
    /// exempted view; the `all` runner reads them only to print the run-level
    /// standing reminder.
    measured: std.ArrayList(Measured) = .empty,

    /// Frees the captured buffer and structured records.
    pub fn deinit(self: *Capture) void {
        self.buf.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
        self.measured.deinit(self.allocator);
    }

    /// Appends `fmt`/`args` to the capture buffer; logs a warning on OOM.
    pub fn write(self: *Capture, comptime fmt: []const u8, args: anytype) void {
        self.buf.writer(self.allocator).print(fmt, args) catch |e|
            std.log.warn("guardian capture write failed: {s}", .{@errorName(e)});
    }

    /// Records a structured Violation emitted through `Reporter.emit`, so
    /// baseline mode and the JSONL sink read key/metric without re-parsing
    /// prose. Best-effort: an OOM is logged and dropped (the text form is
    /// still captured by `write`).
    fn record(self: *Capture, v: Violation) void {
        self.records.append(self.allocator, v) catch |e|
            std.log.warn("guardian capture record failed: {s}", .{@errorName(e)});
    }

    fn recordWarning(self: *Capture, v: Violation) void {
        self.warnings.append(self.allocator, v) catch |e|
            std.log.warn("guardian capture warning failed: {s}", .{@errorName(e)});
    }

    fn recordMeasured(self: *Capture, m: Measured) void {
        self.measured.append(self.allocator, m) catch |e|
            std.log.warn("guardian capture measured failed: {s}", .{@errorName(e)});
    }
};

/// The status verb a blocking check prints, and the one a policy-demoted
/// (report-only) check prints instead. A demoted check's finding never fails
/// the run, so printing FAILED made a green build read as broken to both an
/// eyeball and the `grep FAILED` an agent naturally writes.
const blocking_verb = "FAILED";
const report_verb = "REPORT";

/// Comptime rewrite of a status format string from the blocking verb to the
/// report-only one, so every check keeps its single hand-written message and
/// the demotion is applied at the one printing choke point. Only the verb
/// changes: counts, names, and wording are untouched.
fn demotedFmt(comptime fmt: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, fmt, blocking_verb) orelse return fmt;
    return fmt[0..idx] ++ report_verb ++ demotedFmt(fmt[idx + blocking_verb.len ..]);
}

/// Output controller — owns color, quiet, and (optional) capture state.
pub const Reporter = struct {
    use_color: bool = false,
    quiet: bool = false,
    /// When non-null, all output is appended here and not printed.
    capture: ?*Capture = null,
    /// True while a policy-demoted (report-only) check is running: its status
    /// lines print `REPORT` instead of `FAILED`. Set by the runner around each
    /// check, so no check has to know its own policy mode.
    report_only: bool = false,

    /// Reports a passing check (green when colored, suppressed in quiet mode).
    pub fn ok(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(prefix ++ fmt ++ "\n", args);
            return;
        }
        if (self.quiet) return;
        if (self.use_color)
            print(green ++ prefix ++ reset ++ fmt ++ "\n", args)
        else
            print(prefix ++ fmt ++ "\n", args);
    }

    /// Reports a failing check (red when colored); always shown, even in quiet.
    /// Under a policy-demoted check the blocking verb is swapped for the
    /// report-only one, so a green run's output contains no FAILED at all.
    pub fn fail(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.report_only) return self.status(comptime demotedFmt(fmt), args);
        self.status(fmt, args);
    }

    /// Writes one `guardian: ` status line through the capture or straight to
    /// the terminal. The single rendering path both `fail` spellings share.
    fn status(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(prefix ++ fmt ++ "\n", args);
            return;
        }
        if (self.use_color)
            print(red ++ prefix ++ reset ++ fmt ++ "\n", args)
        else
            print(prefix ++ fmt ++ "\n", args);
    }

    /// Reports an advisory finding. Warnings are always visible, including in
    /// quiet mode, but are captured separately from blocking violations.
    fn warn(self: Reporter, v: Violation) void {
        if (self.capture) |c| {
            c.recordWarning(v);
            warnTo(c, v);
            return;
        }
        warnDirect(self.use_color, v);
    }

    /// Prints an indented detail line under a check (violation specifics,
    /// fix hints). Routed to the capture buffer in baseline mode.
    pub fn detail(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(fmt, args);
            return;
        }
        print(fmt, args);
    }

    /// Emits a structured Violation (file:line, message, optional fix hint).
    /// Under capture, the structured record is stored *and* the text is
    /// written — the text stays byte-identical to `  {s}\n` of `flatLine`.
    pub fn emit(self: Reporter, v: Violation) void {
        if (self.capture) |c| {
            c.record(v);
            emitTo(c, v);
            return;
        }
        emitDirect(v);
    }

    /// Records a Violation for the machine-readable sink WITHOUT printing it.
    /// See the module-level `sink`.
    pub fn sinkOnly(self: Reporter, v: Violation) void {
        if (self.capture) |c| c.record(v);
    }

    /// Emits a Violation whose `fix_hint` is for the sink alone: the printed
    /// line is the finding by itself. For a check that prints ONE shared `fix:`
    /// line beneath its whole list — repeating a near-identical remedy under
    /// every finding is console noise, but the sink has no "beneath the list"
    /// and needs the remedy on the row.
    pub fn emitQuiet(self: Reporter, v: Violation) void {
        var text_only = v;
        text_only.fix_hint = null;
        if (self.capture) |c| {
            c.record(v);
            emitTo(c, text_only);
            return;
        }
        emitDirect(text_only);
    }

    /// Emits a finding deferred by a live `[measurement]` exemption. It is
    /// listed under the check's MEASURE header and recorded separately from
    /// blocking violations, so nothing downstream can mistake it for one.
    fn measure(self: Reporter, m: Measured) void {
        if (self.capture) |c| {
            c.recordMeasured(m);
            c.write("  {s}\n", .{m.message});
            return;
        }
        print("  {s}\n", .{m.message});
    }
};

fn emitTo(c: *Capture, v: Violation) void {
    if (v.file) |f| {
        if (v.line) |l|
            c.write("  {s}:{d}: {s}\n", .{ f, l, v.message })
        else
            c.write("  {s}: {s}\n", .{ f, v.message });
    } else {
        c.write("  {s}\n", .{v.message});
    }
    if (v.fix_hint) |h| c.write("    fix: {s}\n", .{h});
}

fn emitDirect(v: Violation) void {
    if (v.file) |f| {
        if (v.line) |l|
            print("  {s}:{d}: {s}\n", .{ f, l, v.message })
        else
            print("  {s}: {s}\n", .{ f, v.message });
    } else {
        print("  {s}\n", .{v.message});
    }
    if (v.fix_hint) |h| print("    fix: {s}\n", .{h});
}

fn warnTo(c: *Capture, v: Violation) void {
    if (v.file) |f| {
        if (v.line) |l|
            c.write(prefix ++ "warning: {s}:{d}: {s}\n", .{ f, l, v.message })
        else
            c.write(prefix ++ "warning: {s}: {s}\n", .{ f, v.message });
    } else {
        c.write(prefix ++ "warning: {s}\n", .{v.message});
    }
    if (v.fix_hint) |h| c.write("  fix: {s}\n", .{h});
}

fn warnDirect(use_color: bool, v: Violation) void {
    if (use_color) print(yellow, .{});
    if (v.file) |f| {
        if (v.line) |l|
            print(prefix ++ "warning: {s}:{d}: {s}\n", .{ f, l, v.message })
        else
            print(prefix ++ "warning: {s}: {s}\n", .{ f, v.message });
    } else {
        print(prefix ++ "warning: {s}\n", .{v.message});
    }
    if (use_color) print(reset, .{});
    if (v.fix_hint) |h| print("  fix: {s}\n", .{h});
}

// Thread-local so the parallel `all` runner can give each worker thread its own
// capture buffer without a shared-state race: every check's ok/fail/detail call
// resolves to the running thread's Reporter. The main thread's instance drives
// live (non-captured) output and the final summary.
pub threadlocal var default: Reporter = .{};

/// Initializes the module-level default Reporter (TTY-detected color).
pub fn init(quiet: bool) void {
    default = .{
        .use_color = std.fs.File.stderr().isTty(),
        .quiet = quiet,
    };
}

/// Print a green-prefixed success line (suppressed when quiet).
pub fn ok(comptime fmt: []const u8, args: anytype) void {
    default.ok(fmt, args);
}

/// Print a red-prefixed failure line (always printed, even when quiet).
pub fn fail(comptime fmt: []const u8, args: anytype) void {
    default.fail(fmt, args);
}

/// Print a follow-on detail line beneath an ok/fail message.
pub fn detail(comptime fmt: []const u8, args: anytype) void {
    default.detail(fmt, args);
}

/// Buffer size for one machine-payload write. The payload is written in a
/// single `print`, so this bounds the syscall, never the payload length.
const machine_buf_len = 4096;

/// Writes a machine-readable payload to STDOUT — the one output in this module
/// that does not go to stderr. The split is by ROLE, not verbosity: a `--json`
/// report on stderr is invisible to `… | jq` (which is what `debt --json`
/// shipped as, silently producing nothing), and human prose on stdout would
/// corrupt the payload. So prose stays on stderr and the machine payload gets
/// stdout to itself.
pub fn machine(text: []const u8) std.Io.Writer.Error!void {
    var buf: [machine_buf_len]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    return writeMachine(&out.interface, text);
}

/// The stream-agnostic half of `machine`: exactly `text` plus one newline,
/// flushed. Split out so the framing is provable without a real stdout.
fn writeMachine(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.print("{s}\n", .{text});
    try w.flush();
}

/// Format and print a Violation record.
pub fn emit(v: Violation) void {
    default.emit(v);
}

/// Print a Violation record, keeping its fix hint for the sink alone.
/// See `Reporter.emitQuiet`.
pub fn emitQuiet(v: Violation) void {
    default.emitQuiet(v);
}

/// Format and print a non-blocking warning record.
pub fn warn(v: Violation) void {
    default.warn(v);
}

/// Records a structured Violation for the machine-readable sink WITHOUT
/// printing it. The seam exists for a layer that renders its own human output
/// but must not lose the check's detail on the way to `last-run.jsonl`: the
/// baseline/ratchet reporter consumes a check's records under its own nested
/// capture and prints a summary instead, which previously left the sink to
/// scrape that summary's prose (no file, no line, no metric, no fix hint). A
/// no-op when nothing is capturing — a live run has no sink to feed.
pub fn sink(v: Violation) void {
    default.sinkOnly(v);
}

/// Format and print a finding deferred by a live `[measurement]` exemption.
pub fn measure(m: Measured) void {
    default.measure(m);
}

/// Prints a red guardian-prefixed failure line, then terminates the process
/// with exit code 1. The single fatal path for an unrecoverable CLI error — bad
/// argv, a guardian.toml that won't parse, a spec-init write failure — that
/// centralizes the `fail(...) + std.process.exit(1)` pattern hand-rolled across
/// the CLI. `std.process.fatal` is the std reference but routes a bare message
/// through `std.log`, dropping both the "guardian: " prefix and the reporter's
/// coloring, so this keeps them instead. main's `error.CheckFailed -> exit(1)`
/// mapping is intentionally left alone: a failed check has already printed its
/// own diagnostic, so it exits without a second line. The `fatal-exit` check
/// enforces that no other file hand-rolls a nonzero `std.process.exit`.
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    fail(fmt, args);
    std.process.exit(1);
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Reporter - Renders a Violation to the same indented line the emitter prints

test "flatLine matches the text emit writes for every render branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // file+line, file-only, and message-only cover every render branch — the
    // exact shapes the migrated threshold checks emit.
    const cases = [_]Violation{
        .{ .check = "function-length", .file = "src/x.zig", .line = 5, .message = "fn foo is 10 lines (cap 3)" },
        .{ .check = "file-size", .file = "src/x.zig", .message = "1234 code lines (limit: 1000)" },
        .{ .check = "spec", .message = "unverified: Auth - Validates tokens" },
    };
    const want = [_][]const u8{
        "src/x.zig:5: fn foo is 10 lines (cap 3)",
        "src/x.zig: 1234 code lines (limit: 1000)",
        "unverified: Auth - Validates tokens",
    };
    for (cases, want) |v, flat| {
        // flatLine reproduces the pre-migration hand-formatted line body.
        try std.testing.expectEqualStrings(flat, try flatLine(a, v));
        // emit under capture indents that same body and adds a newline, and
        // retains the structured record alongside the text.
        var cap: Capture = .{ .allocator = a };
        const r: Reporter = .{ .capture = &cap };
        r.emit(v);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "  {s}\n", .{flat}), cap.buf.items);
        try std.testing.expectEqual(@as(usize, 1), cap.records.items.len);
    }
    // flatLines renders a whole batch to the same lines (used by analyzeContent
    // and baseline capture rendering).
    const batch = try flatLines(a, &cases);
    try std.testing.expectEqualStrings(want[0], batch[0]);
    try std.testing.expectEqual(cases.len, batch.len);
}

// spec: Reporter - Prints a report-only verb instead of FAILED for a policy-demoted check

test "a demoted check's status line says REPORT and never FAILED" {
    var cap: Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    // A blocking check keeps the historical wording.
    const blocking: Reporter = .{ .capture = &cap };
    blocking.fail("line-length FAILED ({d} occurrence(s))", .{3});
    try std.testing.expectEqualStrings("guardian: line-length FAILED (3 occurrence(s))\n", cap.buf.items);

    // The same message under a policy demotion swaps only the verb, so a naive
    // `grep FAILED` on a green run matches nothing.
    cap.buf.clearRetainingCapacity();
    const demoted: Reporter = .{ .capture = &cap, .report_only = true };
    demoted.fail("line-length FAILED ({d} occurrence(s))", .{3});
    try std.testing.expectEqualStrings("guardian: line-length REPORT (3 occurrence(s))\n", cap.buf.items);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, blocking_verb) == null);

    // A message with no verb in it is passed through untouched.
    try std.testing.expectEqualStrings("no verb here", comptime demotedFmt("no verb here"));
}

// spec: Reporter - Writes a machine payload and one trailing newline to the stream a caller pipes

test "writeMachine emits the payload verbatim with a single trailing newline" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeMachine(&w, "{\"rows\":[]}");
    // Verbatim, one newline, and nothing else: a caller pipes this straight
    // into a JSON parser, so a stray prefix or a second line would break it.
    try std.testing.expectEqualStrings("{\"rows\":[]}\n", w.buffered());
}

// spec: Reporter - Records a violation for the sink without printing it

test "sinkOnly stores a record and writes no text" {
    var cap: Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const r: Reporter = .{ .capture = &cap };
    r.sinkOnly(.{ .check = "file-size", .file = "src/x.zig", .message = "10 code lines (hard limit: 5)", .metric = 10 });
    // The record reaches the sink with its detail intact...
    try std.testing.expectEqual(@as(usize, 1), cap.records.items.len);
    try std.testing.expectEqualStrings("src/x.zig", cap.records.items[0].file.?);
    try std.testing.expectEqual(@as(?u64, 10), cap.records.items[0].metric);
    // ...and nothing is printed: the caller (the baseline reporter) already
    // rendered its own human line for this finding.
    try std.testing.expectEqual(@as(usize, 0), cap.buf.items.len);

    // The module-level spelling routes through the running thread's reporter,
    // which is how the baseline layer reaches the `all` runner's capture.
    const prior = default;
    defer default = prior;
    default = .{ .capture = &cap };
    sink(.{ .check = "file-size", .message = "second" });
    try std.testing.expectEqual(@as(usize, 2), cap.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

// spec: Reporter - Prints a finding without the fix hint it keeps for the sink

test "emitQuiet prints the finding alone and records the hint" {
    var cap: Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const v: Violation = .{
        .check = "ban-time",
        .file = "src/x.zig",
        .line = 26,
        .message = "std.time.timestamp reference outside allowed paths",
        .fix_hint = "inject a Clock port",
    };
    const r: Reporter = .{ .capture = &cap };
    r.emitQuiet(v);
    // The printed line is the finding only: the check prints one shared `fix:`
    // line under its whole list, and a copy per finding is noise.
    try std.testing.expectEqualStrings(
        "  src/x.zig:26: std.time.timestamp reference outside allowed paths\n",
        cap.buf.items,
    );
    // The sink still gets the remedy, because it has no "under the list".
    try std.testing.expectEqualStrings("inject a Clock port", cap.records.items[0].fix_hint.?);

    // `emit` is the opposite spelling: it prints the hint under the finding.
    cap.buf.clearRetainingCapacity();
    r.emit(v);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "    fix: inject a Clock port\n") != null);

    // The module-level spelling routes through the running thread's reporter.
    cap.buf.clearRetainingCapacity();
    const prior = default;
    defer default = prior;
    default = .{ .capture = &cap };
    emitQuiet(v);
    try std.testing.expectEqual(@as(usize, 3), cap.records.items.len);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "fix:") == null);
}

// spec: Reporter - Keeps advisory warnings separate from blocking violation records

test "warning capture is visible but excluded from violation records" {
    var cap: Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const r: Reporter = .{ .capture = &cap };
    r.warn(.{ .check = "line-length", .file = "src/x.zig", .line = 3, .message = "130 chars" });
    try std.testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), cap.records.items.len);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "guardian: warning: src/x.zig:3") != null);
}

// spec: Reporter - Marks an advisory finding that must survive a collapsed run summary

test "an alert warning is captured as a warning and carries its flag" {
    var cap: Capture = .{ .allocator = std.testing.allocator };
    defer cap.deinit();
    const r: Reporter = .{ .capture = &cap };
    r.warn(.{
        .check = "file-size",
        .file = "src/big.zig",
        .message = "NEAR HARD CAP  9612 of 10000 code lines (96%)",
        .alert = true,
    });
    // Still a warning in every respect that matters to metadata: it is captured
    // apart from the blocking records, so no baseline or ratchet can see it.
    try std.testing.expectEqual(@as(usize, 0), cap.records.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap.warnings.items.len);
    // The flag rides the record, which is what lets the run summary replay this
    // one finding after collapsing the rest of the check's output to a count.
    try std.testing.expect(cap.warnings.items[0].alert);
    // An ordinary warning is not an alert, so nothing is promoted by accident.
    r.warn(.{ .check = "file-size", .file = "src/mid.zig", .message = "1200 code lines" });
    try std.testing.expect(!cap.warnings.items[1].alert);
}
