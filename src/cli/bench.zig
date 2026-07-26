//! `bench` command — the CLI over the benchmark ledger (`.guardian/benchmarks.txt`).
//!
//!   guardian-check bench set <name> <value> --unit s --dir min --note "…" .
//!   guardian-check bench list .
//!   guardian-check bench rm <name> .
//!
//! Guardian never measures anything: an agent runs the expensive experiment and
//! records the scalar here, so the next agent reads "close_open_nets_wall_s =
//! 531 s (min, @a3c81cd 2026-07-25: …)" off every gate run instead of spending
//! nine minutes rediscovering it. A `--dir info` record with a note is the
//! negative-result case — "relaxing X cost a net" — kept next to the code it
//! explains.
//!
//! Recording is REPORT-ONLY by default: nothing here can fail a gate. Naming a
//! metric in `[benchmark] gate = […]` opts it into a mutation-ratchet-style
//! ceiling: `set` then refuses a regression unless `--force` arrives with a
//! non-empty `--note` explaining what was accepted.
//!
//! Dispatched specially by check.zig (never a gate), like doctor/spec-sync.
//! The wall-clock read for the record date is this module's one impure act —
//! guardian.toml grants it the `ban-time` allow, as it does the DORA sink.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const config_mod = @import("../config.zig");
const reporter = @import("../reporter.zig");
const benchmark = @import("../benchmark.zig");
const snapshot_helper = @import("../snapshot_helper.zig");
const git = @import("../git.zig");

pub const command_name = "bench";

/// Why a `bench set` invocation was rejected before anything was written.
const Invalid = enum {
    name,
    value,
    unit,
    direction,
    note,
    forced_without_note,
};

/// Entry point for the bench command: routes `set` / `list` / `rm`, and prints
/// the usage summary for anything else (including a bare `bench`).
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    const sub = ctx.bench.sub;
    if (std.mem.eql(u8, sub, benchmark.sub_set)) return setMetric(ctx);
    if (std.mem.eql(u8, sub, benchmark.sub_list)) return listMetrics(ctx);
    if (std.mem.eql(u8, sub, benchmark.sub_rm)) return removeMetric(ctx);
    reporter.fail("bench: expected a subcommand, got '{s}'", .{sub});
    printUsage();
    return error.CheckFailed;
}

/// Prints every recorded metric as one compact line. Called at the start of
/// every `all` run so the numbers an agent already paid for are visible on
/// every gate run; a missing ledger prints nothing and a corrupt one is
/// reported without ever failing the run (the ledger is report-only).
pub fn report(ctx: *types.RunCtx) Allocator.Error!void {
    const path = try ledgerPath(ctx);
    const records = benchmark.read(ctx.allocator, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            reporter.detail(reporter.prefix ++ "bench: ledger {s} is unreadable ({s})\n", .{ path, @errorName(e) });
            return;
        },
    };
    for (records) |rec| {
        reporter.detail(reporter.prefix ++ "{s}\n", .{try benchmark.summaryLine(ctx.allocator, rec)});
    }
}

/// Records (or replaces) one metric, after validating every field and honoring
/// the opt-in per-metric ratchet.
fn setMetric(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    const args = ctx.bench;
    if (validate(args)) |reason| {
        reporter.fail("bench set: {s}", .{reasonText(reason)});
        printUsage();
        return error.CheckFailed;
    }
    const path = try ledgerPath(ctx);
    const records = try readLedger(ctx, path, benchmark.sub_set);
    const value = benchmark.parseValue(args.value).?;
    const rec: benchmark.Record = .{
        .name = args.name,
        .value = value,
        .unit = args.unit,
        .direction = requestedDirection(args),
        .commit = git.headHash(a, ctx.project_dir) orelse benchmark.empty_field,
        .date = try today(a),
        .note = args.note,
    };
    if (try refuseRegression(ctx, records, rec)) return error.CheckFailed;
    try benchmark.write(a, path, try benchmark.upsert(a, records, rec));
    reporter.ok("{s}", .{try benchmark.summaryLine(a, rec)});
    reporter.detail("  recorded in {s}\n", .{path});
}

/// Prints the whole ledger.
fn listMetrics(ctx: *types.RunCtx) types.RunError!void {
    const path = try ledgerPath(ctx);
    const records = try readLedger(ctx, path, benchmark.sub_list);
    if (records.len == 0) {
        reporter.ok("bench: no metrics recorded in {s}", .{path});
        return;
    }
    reporter.ok("bench: {d} metric(s) in {s}", .{ records.len, path });
    for (records) |rec| {
        reporter.detail("  {s}\n", .{try benchmark.summaryLine(ctx.allocator, rec)});
    }
}

/// Drops one metric from the ledger; an unknown name is an error, so a typo
/// never looks like a successful removal.
fn removeMetric(ctx: *types.RunCtx) types.RunError!void {
    const a = ctx.allocator;
    const path = try ledgerPath(ctx);
    const records = try readLedger(ctx, path, benchmark.sub_rm);
    const remaining = (try benchmark.without(a, records, ctx.bench.name)) orelse {
        reporter.fail("bench rm: no metric named '{s}' in {s}", .{ ctx.bench.name, path });
        return error.CheckFailed;
    };
    try benchmark.write(a, path, remaining);
    reporter.ok("bench: removed {s} ({d} metric(s) left)", .{ ctx.bench.name, remaining.len });
}

/// Reads the ledger for subcommand `action`, turning a corrupt or unreadable
/// file into a reported command failure rather than a raw error trace — and
/// never into a silent rewrite. Allocation failure still propagates.
fn readLedger(ctx: *types.RunCtx, path: []const u8, action: []const u8) types.RunError![]const benchmark.Record {
    return benchmark.read(ctx.allocator, path) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            reporter.fail("bench {s}: ledger {s} is unreadable ({s}); fix or remove it", .{
                action, path, @errorName(e),
            });
            return error.CheckFailed;
        },
    };
}

/// Enforces the opt-in `[benchmark] gate` ratchet: true (after reporting) when
/// the new value worsens a gated metric and `--force` was not given. A forced
/// acceptance is announced, so the regression is visible in the run log rather
/// than silent.
fn refuseRegression(
    ctx: *types.RunCtx,
    records: []const benchmark.Record,
    rec: benchmark.Record,
) Allocator.Error!bool {
    if (!benchmark.gated(ctx.cfg.benchmark.gate, rec.name)) return false;
    const prior = benchmark.find(records, rec.name) orelse return false;
    if (!benchmark.regresses(prior.direction, prior.value, rec.value)) return false;
    if (!ctx.bench.force) {
        reporter.fail("bench set REFUSED: {s} regresses the gated ratchet", .{rec.name});
        reporter.detail("  recorded: {s}\n", .{try benchmark.summaryLine(ctx.allocator, prior)});
        reporter.detail("  proposed: {s}\n", .{try benchmark.summaryLine(ctx.allocator, rec)});
        reporter.detail(
            "  fix: improve the number, or accept it deliberately with --force --note \"<why>\".\n",
            .{},
        );
        return true;
    }
    reporter.ok("bench: accepting a forced regression of gated metric {s}", .{rec.name});
    return false;
}

/// First rejected field of a `bench set` invocation, or null when every input
/// is storable. Pure, so the whole validation surface is unit-tested.
fn validate(args: benchmark.Args) ?Invalid {
    if (!benchmark.validToken(args.name)) return .name;
    if (benchmark.parseValue(args.value) == null) return .value;
    if (args.unit.len != 0 and !benchmark.validToken(args.unit)) return .unit;
    if (args.direction.len != 0 and benchmark.parseDirection(args.direction) == null) return .direction;
    if (!benchmark.validNote(args.note)) return .note;
    if (args.force and args.note.len == 0) return .forced_without_note;
    return null;
}

/// The direction a `set` requested; `info` (no direction) when `--dir` is
/// omitted, which is what a pure documentation record wants.
fn requestedDirection(args: benchmark.Args) benchmark.Direction {
    if (args.direction.len == 0) return .info;
    return benchmark.parseDirection(args.direction) orelse .info;
}

/// Human-facing explanation for each rejection.
fn reasonText(reason: Invalid) []const u8 {
    return switch (reason) {
        .name => "metric name must be one printable word (no spaces)",
        .value => "value must be a finite number",
        .unit => "unit must be one printable word (no spaces)",
        .direction => "--dir must be min, max, or info",
        .note => "--note must be a single printable line",
        .forced_without_note => "--force requires a non-empty --note explaining the accepted regression",
    };
}

fn printUsage() void {
    reporter.detail(
        \\  usage: guardian-check bench set <name> <value> [--unit <u>] [--dir min|max|info]
        \\                                   [--note "<one line>"] [--force] [project-dir]
        \\         guardian-check bench list [project-dir]
        \\         guardian-check bench rm <name> [project-dir]
        \\
    , .{});
}

/// Path of this project's ledger file.
fn ledgerPath(ctx: *types.RunCtx) Allocator.Error![]const u8 {
    return snapshot_helper.snapshotPath(ctx.allocator, ctx.project_dir, benchmark.leaf);
}

/// Today's date as `YYYY-MM-DD`. The wall-clock read is this module's only
/// impure act (see the header note on the `ban-time` allow); the conversion
/// itself is the pure, unit-tested `benchmark.isoDate`.
fn today(arena: Allocator) Allocator.Error![]const u8 {
    var buf: [benchmark.iso_date_buf_len]u8 = undefined;
    const secs = std.math.cast(u64, std.time.timestamp()) orelse 0;
    return arena.dupe(u8, benchmark.isoDate(&buf, secs));
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Benchmark Ledger - Rejects an unstorable set invocation naming the offending input

test "validate names the first rejected field and passes a complete record" {
    const good: benchmark.Args = .{
        .sub = benchmark.sub_set,
        .name = "close_open_nets_wall_s",
        .value = "531",
        .unit = "s",
        .direction = "min",
        .note = "fixture B",
    };
    try testing.expect(validate(good) == null);
    try testing.expect(validate(.{ .name = "two words", .value = "1" }).? == .name);
    try testing.expect(validate(.{ .name = "m", .value = "inf" }).? == .value);
    try testing.expect(validate(.{ .name = "m", .value = "1", .unit = "per second" }).? == .unit);
    try testing.expect(validate(.{ .name = "m", .value = "1", .direction = "lower" }).? == .direction);
    try testing.expect(validate(.{ .name = "m", .value = "1", .note = "two\nlines" }).? == .note);
    // Every rejection has a distinct sentence, so the CLI never prints a blank.
    try testing.expect(reasonText(.name).len != 0);
    try testing.expect(reasonText(.value).len != 0);
    try testing.expect(reasonText(.unit).len != 0);
    try testing.expect(reasonText(.direction).len != 0);
    try testing.expect(reasonText(.note).len != 0);
}

// spec: Benchmark Ledger - Requires an explanatory note when forcing a recording

test "validate refuses --force without a note and accepts it with one" {
    const forced: benchmark.Args = .{ .name = "kill_score", .value = "70", .direction = "max", .force = true };
    try testing.expect(validate(forced).? == .forced_without_note);
    try testing.expect(reasonText(.forced_without_note).len != 0);
    var explained = forced;
    explained.note = "cohort turnover; new sample is not comparable";
    try testing.expect(validate(explained) == null);
}

// spec: Benchmark Ledger - Defaults an omitted direction to the undirected info metric

test "requestedDirection maps the flag and defaults to info" {
    try testing.expect(requestedDirection(.{ .direction = "min" }) == .min);
    try testing.expect(requestedDirection(.{ .direction = "max" }) == .max);
    try testing.expect(requestedDirection(.{}) == .info);
}

// spec: Benchmark Ledger - Refuses a gated metric's regression unless the recording is forced

test "refuseRegression blocks a worsening gated metric and yields to an explained force" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior_reporter = reporter.default;
    defer reporter.default = prior_reporter;
    reporter.default = .{ .capture = &cap };

    const cfg: config_mod.Config = .{ .benchmark = .{ .gate = &.{"kill_score"} } };
    var ctx: types.RunCtx = .{
        .allocator = a,
        .project_dir = ".",
        .cfg = &cfg,
        .quiet = true,
        .bench = .{ .sub = benchmark.sub_set, .name = "kill_score" },
    };
    const recorded = [_]benchmark.Record{
        .{ .name = "kill_score", .value = 81, .unit = "%", .direction = .max },
        .{ .name = "wall_s", .value = 531, .unit = "s", .direction = .min },
    };
    const worse: benchmark.Record = .{ .name = "kill_score", .value = 70, .unit = "%", .direction = .max };
    try testing.expect(try refuseRegression(&ctx, &recorded, worse));
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "REFUSED") != null);

    // The same regression lands once it is deliberately forced (the CLI has
    // already required a note by then).
    ctx.bench.force = true;
    try testing.expect(!try refuseRegression(&ctx, &recorded, worse));
    // An improvement, and an ungated metric's regression, are never refused.
    ctx.bench.force = false;
    const better: benchmark.Record = .{ .name = "kill_score", .value = 90, .direction = .max };
    const ungated: benchmark.Record = .{ .name = "wall_s", .value = 900, .direction = .min };
    try testing.expect(!try refuseRegression(&ctx, &recorded, better));
    try testing.expect(!try refuseRegression(&ctx, &recorded, ungated));
}

// spec: Benchmark Ledger - Surfaces every recorded metric on each gate run without blocking it

test "report prints one line per recorded metric and tolerates a missing ledger" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const project = "zig-cache/bench-report-test";
    defer std.fs.cwd().deleteTree(project) catch |e|
        std.log.warn("test cleanup {s}: {s}", .{ project, @errorName(e) });
    var cap: reporter.Capture = .{ .allocator = a };
    defer cap.deinit();
    const prior_reporter = reporter.default;
    defer reporter.default = prior_reporter;
    reporter.default = .{ .capture = &cap };

    const cfg: config_mod.Config = .{};
    var ctx: types.RunCtx = .{ .allocator = a, .project_dir = project, .cfg = &cfg, .quiet = true };
    // No ledger yet: a gate run prints nothing at all about benchmarks.
    try report(&ctx);
    try testing.expectEqualStrings("", cap.buf.items);

    const records = [_]benchmark.Record{
        .{ .name = "close_open_nets_wall_s", .value = 531, .unit = "s", .direction = .min, .note = "fixture B" },
    };
    try benchmark.write(a, try ledgerPath(&ctx), &records);
    try report(&ctx);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "bench close_open_nets_wall_s = 531 s (min,") != null);
    try testing.expect(std.mem.indexOf(u8, cap.buf.items, "fixture B") != null);
}
