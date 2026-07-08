const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub const GREEN = "\x1b[32m";
pub const RED = "\x1b[31m";
pub const RESET = "\x1b[0m";
pub const PREFIX = "guardian: ";

/// A single check failure with optional location and fix hint.
///
/// `check` names the producing check; `ratchet_key`/`metric` are the structured
/// hooks per-item ratchets and the JSONL sink read without re-parsing prose:
/// a stable per-subject identity (`"src/foo.zig|parse"` for a fn,
/// `"src/foo.zig|Config"` for a type, `"src/foo.zig"` for a file metric) and
/// the measured scalar behind the threshold. `message` is the human-facing tail
/// rendered after `file:line:` — see `flatLine`.
pub const Violation = struct {
    check: []const u8 = "",
    file: ?[]const u8 = null,
    line: ?u32 = null,
    message: []const u8,
    fix_hint: ?[]const u8 = null,
    ratchet_key: ?[]const u8 = null,
    metric: ?u64 = null,
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
    buf: std.ArrayListUnmanaged(u8) = .empty,
    records: std.ArrayListUnmanaged(Violation) = .empty,

    /// Frees the captured buffer and structured records.
    pub fn deinit(self: *Capture) void {
        self.buf.deinit(self.allocator);
        self.records.deinit(self.allocator);
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
};

/// Output controller — owns color, quiet, and (optional) capture state.
pub const Reporter = struct {
    use_color: bool = false,
    quiet: bool = false,
    /// When non-null, all output is appended here and not printed.
    capture: ?*Capture = null,

    /// Reports a passing check (green when colored, suppressed in quiet mode).
    pub fn ok(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(PREFIX ++ fmt ++ "\n", args);
            return;
        }
        if (self.quiet) return;
        if (self.use_color)
            print(GREEN ++ PREFIX ++ RESET ++ fmt ++ "\n", args)
        else
            print(PREFIX ++ fmt ++ "\n", args);
    }

    /// Reports a failing check (red when colored); always shown, even in quiet.
    pub fn fail(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(PREFIX ++ fmt ++ "\n", args);
            return;
        }
        if (self.use_color)
            print(RED ++ PREFIX ++ RESET ++ fmt ++ "\n", args)
        else
            print(PREFIX ++ fmt ++ "\n", args);
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

/// Format and print a Violation record.
pub fn emit(v: Violation) void {
    default.emit(v);
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
