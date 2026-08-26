//! Local, non-gating evidence for deciding whether each Guardian check earns
//! its development cost.
//!
//! This stream is deliberately separate from DORA. DORA describes delivery
//! runs and intentionally excludes cache hits and partial runs; ROI telemetry
//! needs those invocations to measure the developer loop honestly. Records are
//! append-only JSONL under `.guardian/cache/`, carry an explicit schema, and
//! contain stable finding identities but no source text or rendered messages.
//!
//! Time is supplied by callers. `dora.zig` owns Guardian's clock seam, so this
//! module remains deterministic and does not introduce a second wall-clock
//! consumer. Writing is best-effort through `recordRun` / `recordEvent`; the
//! fallible `appendRun` / `appendEvent` forms exist for tests and tooling.

const std = @import("std");
const fs = @import("fs.zig");
const wiring = @import("wiring.zig");
const reporter = @import("reporter.zig");
const violation_key = @import("violation_key.zig");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const schema_version: u8 = 1;
const default_sink_path = ".guardian/cache/check-roi.jsonl";
const default_max_bytes: u64 = 32 * 1024 * 1024;
const rotated_suffix = ".1";
const lock_attempts = 64;

const run_type = "check_run";
const run_id_domain = "guardian-check-run-v1";
const observation_id_domain = "guardian-observation-v1";

/// Which source view the invocation verified. A cache hit retains the view the
/// caller requested and sets `cached`; it is an invocation, not an execution.
pub const ScopeMode = enum { full, filtered, diff };

/// Overall result of one Guardian invocation.
pub const RunOutcome = enum { green, red, @"error" };
/// Effective enforcement policy for one check execution.
pub const Policy = enum { block, ratchet, report };
/// Result of one executed check; `reported` is a non-blocking policy finding.
pub const CheckOutcome = enum { passed, failed, reported, @"error", skipped };

/// One finding, identified without persisting its rendered diagnostic or any
/// source contents. `finding_key` follows baseline-v3 identity semantics.
pub const Observation = struct {
    observation_id: []const u8 = "",
    finding_key: []const u8 = "",
    file: ?[]const u8 = null,
    line: ?u32 = null,
};

/// One check's result. Durations overlap when Guardian runs checks in parallel;
/// readers must not sum them to derive run duration.
/// Finding, warning, and measurement-deferred totals for one check execution.
pub const CheckCounts = struct {
    findings: u32 = 0,
    warnings: u32 = 0,
    deferred: u32 = 0,
};

/// One check's execution facts.
pub const CheckRecord = struct {
    check: []const u8 = "",
    policy: Policy = .block,
    outcome: CheckOutcome = .passed,
    duration_ms: u64 = 0,
    counts: CheckCounts = .{},
    observations: []const Observation = &.{},
};

/// Source and tool identity for one invocation.
pub const RunIdentity = struct {
    /// Optional caller-provided unique ID. Rendering derives a content-stable
    /// ID when absent; callers that can issue duplicate same-ms runs may supply
    /// their own ID if strict invocation uniqueness matters.
    run_id: ?[]const u8 = null,
    timestamp_ms: u64 = 0,
    commit: ?[]const u8 = null,
    guardian_digest: ?[]const u8 = null,
};

/// User workflow and source scope that caused one invocation.
pub const RunContext = struct {
    origin: []const u8 = "all",
    phase: ?[]const u8 = null,
    scope_mode: ScopeMode = .full,
    scope_files: u32 = 0,
    cached: bool = false,
};

/// Non-additive wall timings for one invocation.
pub const RunTiming = struct {
    /// Elapsed gate work through verdict generation. The deferred best-effort
    /// serialization of this record necessarily happens after this sample.
    duration_ms: u64 = 0,
    /// Wall time spent in the check-execution phase. It can be lower than
    /// `duration_ms`, which also includes digest/cache/index preparation.
    check_phase_ms: u64 = 0,
};

/// The complete fact record for one user-visible Guardian invocation.
pub const RunRecord = struct {
    identity: RunIdentity = .{},
    context: RunContext = .{},
    outcome: RunOutcome = .green,
    timing: RunTiming = .{},
    checks: []const CheckRecord = &.{},
};

/// Identity fields shared by explicit workflow events.
pub const EventIdentity = struct {
    timestamp_ms: u64 = 0,
    commit: ?[]const u8 = null,
    guardian_digest: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
};

/// Origin, phase, and result of an explicit workflow event.
pub const EventContext = struct {
    origin: []const u8 = "",
    phase: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
};

/// Overall and phase-specific wall timings for a workflow event.
pub const EventTiming = struct {
    duration_ms: ?u64 = null,
    gate_duration_ms: ?u64 = null,
    test_duration_ms: ?u64 = null,
};

/// An explicit compound-workflow event. `action` becomes the JSON `type`, so
/// v1 supports `accept` and `commit` without closing the stream to later kinds.
pub const EventRecord = struct {
    action: []const u8,
    identity: EventIdentity = .{},
    context: EventContext = .{},
    timing: EventTiming = .{},
    observation_ids: []const []const u8 = &.{},
};

/// Storage controls. `max_bytes = null` disables rotation. The default retains
/// one prior generation at `<sink_path>.1`; a single record larger than the cap
/// is rejected rather than silently breaking the bound.
const SinkOptions = struct {
    sink_path: []const u8 = default_sink_path,
    max_bytes: ?u64 = default_max_bytes,
};

/// Inputs shared while deriving observation IDs. Guardian's digest is included
/// so a changed check implementation begins a new observation cohort even when
/// its human-facing diagnostic and the consumer commit did not move.
pub const ObservationSeed = struct {
    commit: ?[]const u8 = null,
    guardian_digest: ?[]const u8 = null,
    check: []const u8,
};

/// Wire DTO. Field order is the emitted JSON order; defaults and the parser's
/// unknown-field tolerance keep an append-only stream readable across upgrades.
const CheckLine = struct {
    check: []const u8 = "",
    policy: Policy = .block,
    outcome: CheckOutcome = .passed,
    duration_ms: u64 = 0,
    findings: u32 = 0,
    warnings: u32 = 0,
    observations: []const Observation = &.{},
    deferred: u32 = 0,
};

const RunLine = struct {
    type: []const u8 = "",
    schema: u8 = 0,
    run_id: []const u8 = "",
    timestamp_ms: u64 = 0,
    commit: ?[]const u8 = null,
    guardian_digest: ?[]const u8 = null,
    origin: []const u8 = "all",
    phase: ?[]const u8 = null,
    scope_mode: ScopeMode = .full,
    scope_files: u32 = 0,
    cached: bool = false,
    outcome: []const u8 = "",
    duration_ms: u64 = 0,
    check_phase_ms: u64 = 0,
    checks: []const CheckLine = &.{},
};

const EventLine = struct {
    type: []const u8 = "",
    schema: u8 = 0,
    timestamp_ms: u64 = 0,
    commit: ?[]const u8 = null,
    guardian_digest: ?[]const u8 = null,
    origin: []const u8 = "",
    phase: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    gate_duration_ms: ?u64 = null,
    test_duration_ms: ?u64 = null,
    observation_ids: []const []const u8 = &.{},
};

/// Serializes a run as one JSON object without its trailing newline.
fn renderRun(arena: Allocator, rec: RunRecord) Allocator.Error![]u8 {
    const id = rec.identity.run_id orelse try makeRunId(arena, rec);
    const line: RunLine = .{
        .type = run_type,
        .schema = schema_version,
        .run_id = id,
        .timestamp_ms = rec.identity.timestamp_ms,
        .commit = rec.identity.commit,
        .guardian_digest = rec.identity.guardian_digest,
        .origin = rec.context.origin,
        .phase = rec.context.phase,
        .scope_mode = rec.context.scope_mode,
        .scope_files = rec.context.scope_files,
        .cached = rec.context.cached,
        .outcome = @tagName(rec.outcome),
        .duration_ms = rec.timing.duration_ms,
        .check_phase_ms = rec.timing.check_phase_ms,
        .checks = try toCheckLines(arena, rec.checks),
    };
    return std.json.Stringify.valueAlloc(arena, line, .{});
}

/// Parses one v1 run line. Blank, malformed, foreign-type, future-schema and
/// unknown-outcome lines return null; unknown fields are ignored.
fn parseRun(arena: Allocator, line: []const u8) ?RunRecord {
    const text = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (text.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(RunLine, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (!std.mem.eql(u8, parsed.type, run_type) or parsed.schema != schema_version) return null;
    const outcome = std.meta.stringToEnum(RunOutcome, parsed.outcome) orelse return null;
    return .{
        .identity = .{
            .run_id = parsed.run_id,
            .timestamp_ms = parsed.timestamp_ms,
            .commit = parsed.commit,
            .guardian_digest = parsed.guardian_digest,
        },
        .context = .{
            .origin = parsed.origin,
            .phase = parsed.phase,
            .scope_mode = parsed.scope_mode,
            .scope_files = parsed.scope_files,
            .cached = parsed.cached,
        },
        .outcome = outcome,
        .timing = .{
            .duration_ms = parsed.duration_ms,
            .check_phase_ms = parsed.check_phase_ms,
        },
        .checks = fromCheckLines(arena, parsed.checks) catch return null,
    };
}

fn toCheckLines(arena: Allocator, records: []const CheckRecord) Allocator.Error![]const CheckLine {
    const lines = try arena.alloc(CheckLine, records.len);
    for (records, lines) |record, *line| line.* = .{
        .check = record.check,
        .policy = record.policy,
        .outcome = record.outcome,
        .duration_ms = record.duration_ms,
        .findings = record.counts.findings,
        .warnings = record.counts.warnings,
        .observations = record.observations,
        .deferred = record.counts.deferred,
    };
    return lines;
}

fn fromCheckLines(arena: Allocator, lines: []const CheckLine) Allocator.Error![]const CheckRecord {
    const records = try arena.alloc(CheckRecord, lines.len);
    for (lines, records) |line, *record| record.* = .{
        .check = line.check,
        .policy = line.policy,
        .outcome = line.outcome,
        .duration_ms = line.duration_ms,
        .counts = .{
            .findings = line.findings,
            .warnings = line.warnings,
            .deferred = line.deferred,
        },
        .observations = line.observations,
    };
    return records;
}

/// Serializes an explicit workflow event as one JSON object without a newline.
fn renderEvent(arena: Allocator, rec: EventRecord) Allocator.Error![]u8 {
    const line: EventLine = .{
        .type = rec.action,
        .schema = schema_version,
        .timestamp_ms = rec.identity.timestamp_ms,
        .commit = rec.identity.commit,
        .guardian_digest = rec.identity.guardian_digest,
        .origin = rec.context.origin,
        .phase = rec.context.phase,
        .operation_id = rec.identity.operation_id,
        .outcome = rec.context.outcome,
        .duration_ms = rec.timing.duration_ms,
        .gate_duration_ms = rec.timing.gate_duration_ms,
        .test_duration_ms = rec.timing.test_duration_ms,
        .observation_ids = rec.observation_ids,
    };
    return std.json.Stringify.valueAlloc(arena, line, .{});
}

/// Parses a v1 non-run event. Event types remain open strings; `check_run` is
/// reserved for `parseRun`.
fn parseEvent(arena: Allocator, line: []const u8) ?EventRecord {
    const text = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (text.len == 0) return null;
    const parsed = std.json.parseFromSliceLeaky(EventLine, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (parsed.schema != schema_version or parsed.type.len == 0 or
        std.mem.eql(u8, parsed.type, run_type)) return null;
    return .{
        .action = parsed.type,
        .identity = .{
            .timestamp_ms = parsed.timestamp_ms,
            .commit = parsed.commit,
            .guardian_digest = parsed.guardian_digest,
            .operation_id = parsed.operation_id,
        },
        .context = .{
            .origin = parsed.origin,
            .phase = parsed.phase,
            .outcome = parsed.outcome,
        },
        .timing = .{
            .duration_ms = parsed.duration_ms,
            .gate_duration_ms = parsed.gate_duration_ms,
            .test_duration_ms = parsed.test_duration_ms,
        },
        .observation_ids = parsed.observation_ids,
    };
}

/// A deterministic ID for a supplied baseline-v3 finding key.
fn observationId(arena: Allocator, seed: ObservationSeed, finding_key: []const u8) Allocator.Error![]u8 {
    var hasher = Sha256.init(.{});
    updateField(&hasher, observation_id_domain);
    updateOptionalField(&hasher, seed.commit);
    updateOptionalField(&hasher, seed.guardian_digest);
    updateField(&hasher, seed.check);
    updateField(&hasher, finding_key);
    return finishId(arena, "o1_", &hasher);
}

/// Builds an observation when a caller already has a canonical finding key.
fn observationFromKey(
    arena: Allocator,
    seed: ObservationSeed,
    finding_key: []const u8,
    file: ?[]const u8,
    line: ?u32,
) Allocator.Error!Observation {
    return .{
        .observation_id = try observationId(arena, seed, finding_key),
        .finding_key = finding_key,
        .file = if (file) |path| try arena.dupe(u8, path) else null,
        .line = line,
    };
}

/// Builds an observation from a structured violation using the same identity,
/// ratchet-key and message-skeleton tiers as baselines.
pub fn observationFromRecord(
    arena: Allocator,
    seed: ObservationSeed,
    violation: reporter.Violation,
) Allocator.Error!Observation {
    const key = try violation_key.fromRecord(arena, seed.check, violation);
    return observationFromKey(arena, seed, key, violation.file, violation.line);
}

/// Builds an observation from an unmigrated check's rendered violation line.
/// The identity excludes its line number; location metadata retains it when it
/// can be parsed without retaining the message.
fn observationFromLine(
    arena: Allocator,
    seed: ObservationSeed,
    line: []const u8,
) Allocator.Error!Observation {
    const key = try violation_key.fromLine(arena, seed.check, line);
    const file = violation_key.fileOf(line);
    const located_file: ?[]const u8 = if (std.mem.eql(u8, file, violation_key.no_file)) null else file;
    return observationFromKey(arena, seed, key, located_file, renderedLineNumber(line, located_file));
}

/// Content-stable fallback ID for a run whose caller did not supply one.
fn makeRunId(arena: Allocator, rec: RunRecord) Allocator.Error![]u8 {
    var hasher = Sha256.init(.{});
    updateField(&hasher, run_id_domain);
    updateInt(&hasher, rec.identity.timestamp_ms);
    updateOptionalField(&hasher, rec.identity.commit);
    updateOptionalField(&hasher, rec.identity.guardian_digest);
    updateField(&hasher, rec.context.origin);
    updateOptionalField(&hasher, rec.context.phase);
    updateField(&hasher, @tagName(rec.context.scope_mode));
    updateInt(&hasher, rec.context.scope_files);
    updateInt(&hasher, @intFromBool(rec.context.cached));
    updateField(&hasher, @tagName(rec.outcome));
    updateInt(&hasher, rec.timing.duration_ms);
    updateInt(&hasher, rec.timing.check_phase_ms);
    updateInt(&hasher, rec.checks.len);
    for (rec.checks) |check| {
        updateField(&hasher, check.check);
        updateField(&hasher, @tagName(check.policy));
        updateField(&hasher, @tagName(check.outcome));
        updateInt(&hasher, check.duration_ms);
        updateInt(&hasher, check.counts.findings);
        updateInt(&hasher, check.counts.warnings);
        updateInt(&hasher, check.counts.deferred);
        updateInt(&hasher, check.observations.len);
        for (check.observations) |obs| updateField(&hasher, obs.observation_id);
    }
    return finishId(arena, "r1_", &hasher);
}

/// Best-effort default-sink recording. Telemetry can warn but never gates.
pub fn recordRun(arena: Allocator, project_dir: []const u8, rec: RunRecord) void {
    appendRun(arena, project_dir, rec, .{}) catch |err|
        reporter.detail(reporter.prefix ++ "warning: check ROI write failed: {s}\n", .{@errorName(err)});
}

/// Best-effort event recording to the same mixed stream as run facts.
pub fn recordEvent(arena: Allocator, project_dir: []const u8, rec: EventRecord) void {
    appendEvent(arena, project_dir, rec, .{}) catch |err|
        reporter.detail(reporter.prefix ++ "warning: check ROI write failed: {s}\n", .{@errorName(err)});
}

/// Fallible run writer with configurable sink/rotation, useful to integration
/// tests and offline tools.
fn appendRun(arena: Allocator, project_dir: []const u8, rec: RunRecord, options: SinkOptions) !void {
    try appendRendered(arena, project_dir, try renderRun(arena, rec), options);
}

/// Fallible workflow-event writer with configurable sink/rotation.
fn appendEvent(arena: Allocator, project_dir: []const u8, rec: EventRecord, options: SinkOptions) !void {
    try appendRendered(arena, project_dir, try renderEvent(arena, rec), options);
}

/// Resolves the configured sink against a project. Absolute paths pass through.
fn resolvePath(arena: Allocator, project_dir: []const u8, sink_path: []const u8) Allocator.Error![]const u8 {
    if (sink_path.len > 0 and sink_path[0] == '/') return arena.dupe(u8, sink_path);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, sink_path });
}

fn appendRendered(arena: Allocator, project_dir: []const u8, line: []const u8, options: SinkOptions) !void {
    const path = try resolvePath(arena, project_dir, options.sink_path);
    const record = try std.fmt.allocPrint(arena, "{s}\n", .{line});
    if (options.max_bytes) |max| if (record.len > max) return error.RecordTooLarge;

    if (parentDir(path)) |parent| try fs.cwd().makePath(parent);
    const lock_path = try std.fmt.allocPrint(arena, "{s}.lock", .{path});
    const lock = try acquireSinkLock(lock_path);
    defer lock.close();

    const should_rotate = if (options.max_bytes) |max| try exceedsCap(path, record.len, max) else false;
    if (should_rotate) try rotate(arena, path);

    const sink = try fs.cwd().createFile(path, .{ .truncate = false, .read = false });
    defer sink.close();
    try sink.seekFromEnd(0);
    try sink.writeAll(record);
}

/// Tries a few nonblocking acquisitions so ordinary simultaneous completions
/// usually serialize, while a paused writer or long-running reader can never
/// strand the quality gate. Exhausted contention drops best-effort telemetry.
fn acquireSinkLock(path: []const u8) !fs.File {
    for (0..lock_attempts) |attempt| {
        return fs.cwd().createFile(path, .{
            .truncate = false,
            .read = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => {
                if (attempt + 1 == lock_attempts) return err;
                std.atomic.spinLoopHint();
                continue;
            },
            else => return err,
        };
    }
    return error.WouldBlock;
}

/// Opens (and therefore creates) the sink while the sidecar lock is held, then
/// checks whether appending the next complete JSON record would cross the cap.
fn exceedsCap(path: []const u8, record_len: usize, max: u64) !bool {
    const sink = try fs.cwd().createFile(path, .{ .truncate = false, .read = true });
    defer sink.close();
    const size = (try sink.stat()).size;
    if (size == 0) return false;
    const next = std.math.add(u64, size, @intCast(record_len)) catch return true;
    return next > max;
}

/// Keeps one prior generation. All writers take the stable `.lock` sidecar, so
/// renaming the active inode does not split their lock domain.
fn rotate(arena: Allocator, path: []const u8) !void {
    const previous = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, rotated_suffix });
    fs.cwd().deleteFile(previous) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(path, cwd, previous, wiring.io());
}

fn parentDir(path: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (idx == 0) return null;
    return path[0..idx];
}

fn renderedLineNumber(line: []const u8, file: ?[]const u8) ?u32 {
    const f = file orelse return null;
    if (line.len <= f.len or line[f.len] != ':') return null;
    const start = f.len + 1;
    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    if (end == start or end >= line.len or line[end] != ':') return null;
    return std.fmt.parseInt(u32, line[start..end], 10) catch null;
}

fn updateField(hasher: *Sha256, bytes: []const u8) void {
    updateInt(hasher, bytes.len);
    hasher.update(bytes);
}

fn updateOptionalField(hasher: *Sha256, bytes: ?[]const u8) void {
    if (bytes) |value| {
        hasher.update(&.{1});
        updateField(hasher, value);
    } else {
        hasher.update(&.{0});
    }
}

fn updateInt(hasher: *Sha256, value: anytype) void {
    var framed: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &framed, @intCast(value), .little);
    hasher.update(&framed);
}

fn finishId(arena: Allocator, prefix: []const u8, hasher: *Sha256) Allocator.Error![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, &hex });
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Check ROI Telemetry - Records every invocation in a versioned local JSONL stream

test "run rendering emits schema v1 facts and round-trips unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const observations = [_]Observation{.{
        .observation_id = "o1_example",
        .finding_key = "file-size|src/large.zig|is # lines",
        .file = "src/large.zig",
        .line = 41,
    }};
    const checks = [_]CheckRecord{.{
        .check = "file-size",
        .policy = .ratchet,
        .outcome = .failed,
        .duration_ms = 12,
        .counts = .{ .findings = 1, .warnings = 2 },
        .observations = &observations,
    }};
    const rendered = try renderRun(a, .{
        .identity = .{
            .run_id = "r1_example",
            .timestamp_ms = 1_700_000_000_123,
            .commit = "abc123",
            .guardian_digest = "guardian-a",
        },
        .context = .{
            .origin = "build",
            .phase = "gate",
            .scope_mode = .diff,
            .scope_files = 3,
        },
        .outcome = .red,
        .timing = .{ .duration_ms = 20, .check_phase_ms = 12 },
        .checks = &checks,
    });
    try std.testing.expect(std.mem.startsWith(u8, rendered, "{\"type\":\"check_run\",\"schema\":1"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"scope_mode\":\"diff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"finding_key\":\"file-size|") != null);

    const extended = try std.fmt.allocPrint(a, "{s}", .{rendered[0 .. rendered.len - 1]});
    const with_unknown = try std.fmt.allocPrint(a, "{s},\"future\":true}}", .{extended});
    const back = parseRun(a, with_unknown).?;
    try std.testing.expectEqualStrings("r1_example", back.identity.run_id.?);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_123), back.identity.timestamp_ms);
    try std.testing.expect(back.context.scope_mode == .diff);
    try std.testing.expect(back.outcome == .red);
    try std.testing.expectEqual(@as(usize, 1), back.checks.len);
    try std.testing.expectEqualStrings("o1_example", back.checks[0].observations[0].observation_id);
}

test "run parser rejects malformed foreign and future-schema records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(parseRun(a, "") == null);
    try std.testing.expect(parseRun(a, "{not json") == null);
    try std.testing.expect(parseRun(a, "{\"schema\":1,\"outcome\":\"green\"}") == null);
    try std.testing.expect(parseRun(a, "{\"type\":\"check_run\",\"outcome\":\"green\"}") == null);
    try std.testing.expect(parseRun(a, "{\"type\":\"accept\",\"schema\":1}") == null);
    try std.testing.expect(parseRun(a, "{\"type\":\"check_run\",\"schema\":2,\"outcome\":\"green\"}") == null);
    try std.testing.expect(parseRun(a, "{\"type\":\"check_run\",\"schema\":1,\"outcome\":\"amber\"}") == null);
}

// spec: Check ROI Telemetry - Uses content-stable finding identities across line and numeric drift

test "observation identity follows violation key tiers and Guardian cohorts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const seed: ObservationSeed = .{
        .commit = "consumer-commit",
        .guardian_digest = "guardian-a",
        .check = "file-size",
    };
    const first = try observationFromRecord(a, seed, .{
        .file = "src/main.zig",
        .line = 12,
        .message = "file is 246 lines (cap 200)",
    });
    const moved = try observationFromRecord(a, seed, .{
        .file = "src/main.zig",
        .line = 90,
        .message = "file is 310 lines (cap 250)",
    });
    try std.testing.expectEqualStrings(first.finding_key, moved.finding_key);
    try std.testing.expectEqualStrings(first.observation_id, moved.observation_id);
    try std.testing.expect(first.line.? != moved.line.?);

    const next_guardian = try observationFromKey(a, .{
        .commit = seed.commit,
        .guardian_digest = "guardian-b",
        .check = seed.check,
    }, first.finding_key, first.file, first.line);
    try std.testing.expect(!std.mem.eql(u8, first.observation_id, next_guardian.observation_id));

    const named = try observationFromRecord(a, .{ .check = "concept" }, .{
        .message = "rendering may change entirely",
        .identity = "palette|layer-name",
    });
    try std.testing.expectEqualStrings("concept|palette|layer-name", named.finding_key);
}

test "scraped observations retain location without keying on line number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const seed: ObservationSeed = .{ .check = "naming" };
    const first = try observationFromLine(a, seed, "src/main.zig:17: name is 2 bytes");
    const moved = try observationFromLine(a, seed, "src/main.zig:91: name is 8 bytes");
    try std.testing.expectEqualStrings(first.finding_key, moved.finding_key);
    try std.testing.expectEqualStrings(first.observation_id, moved.observation_id);
    try std.testing.expectEqualStrings("src/main.zig", first.file.?);
    try std.testing.expectEqual(@as(u32, 17), first.line.?);
    try std.testing.expectEqual(@as(u32, 91), moved.line.?);
}

test "observations own borrowed locations until deferred serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var borrowed = [_]u8{ 's', 'r', 'c', '/', 'x', '.', 'z', 'i', 'g' };
    const observation = try observationFromRecord(arena.allocator(), .{ .check = "naming" }, .{
        .file = &borrowed,
        .message = "name is too short",
    });
    borrowed[0] = 'X';
    try std.testing.expectEqualStrings("src/x.zig", observation.file.?);
}

test "derived run IDs are stable over content and move when facts move" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: RunRecord = .{
        .identity = .{ .timestamp_ms = 42, .commit = "abc" },
        .timing = .{ .duration_ms = 9 },
    };
    const first = try makeRunId(a, base);
    const again = try makeRunId(a, base);
    var changed = base;
    changed.identity.timestamp_ms = 43;
    const second = try makeRunId(a, changed);
    try std.testing.expectEqual(@as(usize, 3 + 2 * Sha256.digest_length), first.len);
    try std.testing.expectEqualStrings(first, again);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

// spec: Check ROI Telemetry - Distinguishes accept and commit phases without inferring usefulness

test "events carry explicit workflow phases and phase durations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rendered = try renderEvent(a, .{
        .action = "commit",
        .identity = .{ .timestamp_ms = 99, .commit = "abc", .operation_id = "commit-1" },
        .context = .{ .origin = "guardian-check commit", .phase = "complete", .outcome = "red" },
        .timing = .{ .duration_ms = 30, .gate_duration_ms = 10, .test_duration_ms = 20 },
        .observation_ids = &.{"o1_example"},
    });
    _ = &recordEvent;
    const parsed = parseEvent(a, rendered).?;
    try std.testing.expectEqualStrings("commit", parsed.action);
    try std.testing.expectEqualStrings("complete", parsed.context.phase.?);
    try std.testing.expectEqual(@as(u64, 10), parsed.timing.gate_duration_ms.?);
    try std.testing.expectEqual(@as(u64, 20), parsed.timing.test_duration_ms.?);
    try std.testing.expect(parseRun(a, rendered) == null);
}

// spec: Check ROI Telemetry - Appends atomically under concurrent writers and bounds the raw log

test "fallible writers append runs and events to one JSONL stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/check-roi-append";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};

    const options: SinkOptions = .{ .max_bytes = null };
    try appendRun(a, dir, .{ .identity = .{ .run_id = "run-1" }, .outcome = .green }, options);
    try appendEvent(a, dir, .{ .action = "accept", .identity = .{ .operation_id = "accept-1" } }, options);

    const raw = try fs.cwd().readFileAlloc(a, dir ++ "/" ++ default_sink_path, 4096);
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    try std.testing.expect(parseRun(a, lines.next().?) != null);
    try std.testing.expect(parseEvent(a, lines.next().?) != null);
    try std.testing.expect(lines.next() == null);
}

test "raw stream rotation retains one complete prior generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/check-roi-rotate";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};

    const first: RunRecord = .{ .identity = .{ .run_id = "first" }, .context = .{ .origin = "first" } };
    const second: RunRecord = .{ .identity = .{ .run_id = "second" }, .context = .{ .origin = "second" } };
    const first_line = try renderRun(a, first);
    const second_line = try renderRun(a, second);
    const cap: u64 = @intCast(@max(first_line.len, second_line.len) + 1);
    const options: SinkOptions = .{ .max_bytes = cap };
    try appendRun(a, dir, first, options);
    try appendRun(a, dir, second, options);

    const active_path = dir ++ "/" ++ default_sink_path;
    const active = try fs.cwd().readFileAlloc(a, active_path, 4096);
    const prior = try fs.cwd().readFileAlloc(a, active_path ++ rotated_suffix, 4096);
    try std.testing.expect(std.mem.indexOf(u8, active, "\"run_id\":\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prior, "\"run_id\":\"first\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, active, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, prior, "\n"));
}

test "a record larger than the configured raw cap is rejected before writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/check-roi-oversize";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};

    try std.testing.expectError(error.RecordTooLarge, appendRun(
        a,
        dir,
        .{ .identity = .{ .run_id = "larger-than-one-byte" } },
        .{ .max_bytes = 1 },
    ));
    try std.testing.expectError(
        error.FileNotFound,
        fs.cwd().access(dir ++ "/" ++ default_sink_path, .{}),
    );
}

test "a contended ROI sink lock drops promptly instead of blocking the gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = "zig-cache/check-roi-contended";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    const cache_dir = dir ++ "/.guardian/cache";
    try fs.cwd().makePath(cache_dir);
    const lock = try fs.cwd().createFile(cache_dir ++ "/check-roi.jsonl.lock", .{
        .truncate = false,
        .read = false,
        .lock = .exclusive,
    });
    defer lock.close();

    try std.testing.expectError(
        error.WouldBlock,
        appendRun(a, dir, .{ .identity = .{ .run_id = "contended" } }, .{}),
    );
}

const ConcurrentCtx = struct {
    path: []const u8,
    run_id: []const u8,
    failed: *std.atomic.Value(bool),
};

fn appendMany(ctx: ConcurrentCtx) void {
    // allocator-ok: each writer thread owns this short-lived test arena
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var appended: usize = 0;
    while (appended < 50) {
        appendRun(
            arena.allocator(),
            ctx.path,
            .{ .identity = .{ .run_id = ctx.run_id } },
            .{ .max_bytes = null },
        ) catch |err| switch (err) {
            error.WouldBlock => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => {
                ctx.failed.store(true, .release);
                return;
            },
        };
        appended += 1;
    }
}

test "concurrent writers preserve every complete ROI record" {
    const dir = "zig-cache/check-roi-concurrent";
    fs.cwd().deleteTree(dir) catch {};
    defer fs.cwd().deleteTree(dir) catch {};
    var failed: std.atomic.Value(bool) = .init(false);
    const first = try std.Thread.spawn(.{}, appendMany, .{ConcurrentCtx{
        .path = dir,
        .run_id = "writer-a",
        .failed = &failed,
    }});
    const second = try std.Thread.spawn(.{}, appendMany, .{ConcurrentCtx{
        .path = dir,
        .run_id = "writer-b",
        .failed = &failed,
    }});
    first.join();
    second.join();
    try std.testing.expect(!failed.load(.acquire));

    const raw = try fs.cwd().readFileAlloc(
        std.testing.allocator,
        dir ++ "/" ++ default_sink_path,
        128 * 1024,
    );
    defer std.testing.allocator.free(raw);
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const parsed = parseRun(parse_arena.allocator(), line) orelse return error.InvalidRecord;
        try std.testing.expect(std.mem.eql(u8, parsed.identity.run_id.?, "writer-a") or
            std.mem.eql(u8, parsed.identity.run_id.?, "writer-b"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), count);
}
