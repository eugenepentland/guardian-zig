//! Two-tier function-length guidance: ordinary overages are advisory, while
//! exceptionally long functions still fail the quality gate.

const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast = @import("../ast/parser.zig");
const ast_index = @import("../ast/index.zig");
const config_mod = @import("../config.zig");
const near_cap = @import("../near_cap.zig");
const hysteresis = @import("../hysteresis.zig");

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// This check's registry name, used for its own violation records and to ask
/// whether hysteresis binds it.
const check_name = "function-length";

/// What the alert line tells a function to do about its remaining runway.
const extract_remedy = "extract a focused helper now";

const ScanCtx = struct {
    allocator: std.mem.Allocator,
    warnings: *std.ArrayList(reporter.Violation),
    violations: *std.ArrayList(reporter.Violation),
    cfg: config_mod.FunctionLengthCfg,
    /// What the pre-trip alert says a crossing would cost; `.unacceptable`
    /// when `[hysteresis]` binds this check (see near_cap.Crossing).
    crossing: near_cap.Crossing = .blocks,
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    const a = ctx.allocator;

    const fns = if (entry.tree) |t| try ast.fnDeclInfosFromTree(a, t) else try ast.fnDeclInfos(a, entry.content);
    for (fns) |f| {
        try noteNearHardCap(ctx, entry.rel_path, f);
        if (f.line_count <= ctx.cfg.max_lines) continue;
        const is_hard = f.line_count > ctx.cfg.hard_max_lines;
        const destination = if (is_hard) ctx.violations else ctx.warnings;
        const message = if (is_hard)
            try std.fmt.allocPrint(
                a,
                "fn {s} is {d} lines (hard limit {d})",
                .{ f.name, f.line_count, ctx.cfg.hard_max_lines },
            )
        else
            try std.fmt.allocPrint(
                a,
                "fn {s} is {d} lines (recommended {d}; hard limit {d})",
                .{ f.name, f.line_count, ctx.cfg.max_lines, ctx.cfg.hard_max_lines },
            );
        try destination.append(a, .{
            .check = check_name,
            .file = entry.rel_path,
            .line = f.start_line,
            .message = message,
            .fix_hint = if (is_hard) null else "consider extracting a focused helper when the function next changes",
            .ratchet_key = try std.fmt.allocPrint(a, "{s}|{s}", .{ entry.rel_path, f.name }),
            .metric = f.line_count,
        });
    }
}

/// Appends the pre-trip alert for a function that has reached 95% of the hard
/// line limit. A SECOND advisory finding beside the ordinary recommended-limit
/// warning, carrying no ratchet key — that warning owns this function's
/// advisory entry, and an alert must never add or preserve one.
fn noteNearHardCap(ctx: *ScanCtx, rel_path: []const u8, f: ast.FnDeclInfo) std.mem.Allocator.Error!void {
    if (!near_cap.isNearHardCap(f.line_count, ctx.cfg.hard_max_lines)) return;
    try ctx.warnings.append(ctx.allocator, .{
        .check = check_name,
        .file = rel_path,
        .line = f.start_line,
        .alert = true,
        .message = try near_cap.alertMessage(ctx.allocator, .{
            .value = f.line_count,
            .hard_cap = ctx.cfg.hard_max_lines,
            .unit = "lines",
            .remedy = extract_remedy,
            .crossing = ctx.crossing,
            .subject = try std.fmt.allocPrint(ctx.allocator, "fn {s}", .{f.name}),
        }),
    });
}

/// Pure-function entry: scans `content` and returns violation lines
/// (allocator-owned). Empty slice = pass.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: []const u8,
    cfg: config_mod.FunctionLengthCfg,
) std.mem.Allocator.Error![]const []const u8 {
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .warnings = &warnings,
        .violations = &violations,
        .cfg = cfg,
    };
    try visit(@ptrCast(&ctx), .{ .rel_path = rel_path, .content = content });
    return reporter.flatLines(allocator, violations.items);
}

/// Entry point for the function-length check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const project_dir = ctx_param.project_dir;
    const cfg = ctx_param.cfg.function_length;

    if (!cfg.enabled) {
        ok("function-length disabled by config", .{});
        return;
    }

    var violations: std.ArrayList(reporter.Violation) = .empty;
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .warnings = &warnings,
        .violations = &violations,
        .cfg = cfg,
        .crossing = hysteresis.crossingFor(ctx_param.cfg, check_name),
    };

    try ast_index.runSrc(ctx_param.source_index, allocator, project_dir, .{ .ctx = &ctx, .visit = visit });

    for (warnings.items) |warning| reporter.warn(warning);
    if (violations.items.len == 0 and warnings.items.len == 0) {
        ok("all functions within {d} recommended lines", .{cfg.max_lines});
        return;
    }
    if (violations.items.len == 0) return;

    fail("function length FAILED ({d} fn(s) over {d} hard line limit)", .{
        violations.items.len,
        cfg.hard_max_lines,
    });
    for (violations.items) |v| reporter.emit(v);
    print("  fix: extract helpers to break the function into focused units, " ++
        "or raise [function_length] max_lines.\n", .{});
    return error.CheckFailed;
}

// spec: Function Length - Warns on long functions and fails only above a configurable hard line limit
// spec: Function Length - Warns prominently when a function has reached 95% of the hard line limit

test "a fn at 95% of the hard limit draws one un-collapsible alert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .warnings = &warnings,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 2, .hard_max_lines = 5 },
    };
    // 5 of 5 lines: green, with zero room left — the state the ordinary warning
    // buries among every other function over the recommended limit.
    const content =
        \\pub fn long() void {
        \\    var x: i32 = 0;
        \\    x += 1;
        \\    _ = x;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
    const alert = warnings.items[0];
    try std.testing.expect(alert.alert);
    try std.testing.expectEqual(@as(u32, 1), alert.line.?);
    try std.testing.expectEqualStrings(
        "NEAR HARD CAP  fn long  5 of 5 lines (100%) — crossing blocks the gate; " ++ extract_remedy,
        alert.message,
    );
    try std.testing.expect(alert.ratchet_key == null);
}

test "visit flags fn over the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .warnings = &warnings,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 3, .hard_max_lines = 4 },
    };
    const content =
        \\pub fn long() void {
        \\    var x: i32 = 0;
        \\    x += 1;
        \\    _ = x;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

test "visit warns between recommended and hard limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .warnings = &warnings,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 3, .hard_max_lines = 6 },
    };
    const content =
        \\pub fn long() void {
        \\    var x: i32 = 0;
        \\    x += 1;
        \\    _ = x;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit allows fn at the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .warnings = &warnings,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 3, .hard_max_lines = 6 },
    };
    const content =
        \\pub fn short() void {
        \\    return;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "visit reports correct start_line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList(reporter.Violation) = .empty;
    var violations: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = a,
        .warnings = &warnings,
        .violations = &violations,
        .cfg = .{ .enabled = true, .max_lines = 1, .hard_max_lines = 2 },
    };
    const content =
        \\const x = 1;
        \\
        \\pub fn long() void {
        \\    return;
        \\}
    ;
    try visit(@ptrCast(&ctx), .{ .rel_path = "src/x.zig", .content = content });
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    // The violation should reference line 3 (where `pub fn` sits) as structured data.
    try std.testing.expectEqual(@as(u32, 3), violations.items[0].line.?);
    try std.testing.expectEqualStrings("src/x.zig|long", violations.items[0].ratchet_key.?);
}
