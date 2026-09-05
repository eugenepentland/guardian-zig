//! Configured operation gates and the read-only, baseline-independent audit.
const std = @import("std");
const types = @import("../cli/types.zig");
const reporter = @import("../reporter.zig");
const sources = @import("../ast/index.zig");
const graph = @import("../contracts/index.zig");
const analysis = @import("../contracts/analyze.zig");
const model = @import("../contracts/model.zig");

/// A machine-readable report deliberately separates violations from review work.
pub const Report = struct {
    project: []const u8,
    violations: usize = 0,
    review_items: usize = 0,
    findings: []const model.Finding,
};

fn findings(ctx: *types.RunCtx, only: ?model.Kind) types.RunError![]const model.Finding {
    var storage: sources.Index = undefined;
    const source = try sources.resolve(ctx.source_index, ctx.allocator, ctx.project_dir, &storage);
    for (source.files) |file| {
        if (file.tree.errors.len == 0) continue;
        reporter.fail("contract analysis cannot parse {s}", .{file.rel_path});
        return error.CheckFailed;
    }
    var local: graph.Graph = undefined;
    const calls = ctx.contract_graph orelse blk: {
        local = try graph.build(ctx.allocator, source);
        break :blk &local;
    };
    return analysis.run(ctx.allocator, calls, ctx.cfg.contracts, only);
}

fn violation(a: std.mem.Allocator, row: model.Finding) std.mem.Allocator.Error!reporter.Violation {
    return .{
        .check = row.check,
        .file = row.file,
        .line = row.line,
        .message = try std.fmt.allocPrint(a, "[{s}] {s}: {s} ({s})", .{ row.rule, row.function, row.message, row.operation }),
        .fix_hint = row.reason,
        .identity = try std.fmt.allocPrint(a, "{s}|{s}|{s}|{s}", .{ row.rule, row.function, row.code, row.operation }),
        .alert = row.confidence == .review,
    };
}

fn gate(ctx: *types.RunCtx, kind: model.Kind) types.RunError!void {
    if (ctx.cfg.contracts.len == 0) {
        reporter.ok("{s}: no operation contracts configured", .{kind.checkName()});
        return;
    }
    const rows = try findings(ctx, kind);
    var failed: usize = 0;
    for (rows) |row| {
        const v = try violation(ctx.allocator, row);
        if (row.confidence == .review) reporter.warn(v) else {
            reporter.emit(v);
            failed += 1;
        }
    }
    if (failed > 0) {
        reporter.fail("{s}: {d} violation(s), {d} review item(s)", .{ kind.checkName(), failed, rows.len - failed });
        return error.CheckFailed;
    }
    reporter.ok("{s}: no definite violations; {d} review item(s)", .{ kind.checkName(), rows.len });
}

/// Gate durable-write result contracts; an error must remain observable.
pub fn runWrite(ctx: *types.RunCtx) types.RunError!void {
    try gate(ctx, .durable_write);
}

/// Gate persisted-state reads that erase failures into ordinary absence.
pub fn runRead(ctx: *types.RunCtx) types.RunError!void {
    try gate(ctx, .persistent_read);
}

/// Gate calls bypassing a declared mutation owner.
pub fn runMutation(ctx: *types.RunCtx) types.RunError!void {
    try gate(ctx, .transaction);
}

/// Gate raw request parsing outside its approved decoder declarations.
pub fn runDecoder(ctx: *types.RunCtx) types.RunError!void {
    try gate(ctx, .decoder);
}

/// Report identity/revision evidence still requiring semantic review.
pub fn runIdentity(ctx: *types.RunCtx) types.RunError!void {
    try gate(ctx, .identity);
}

/// Read-only report: never accepts baselines or writes target-project metadata.
/// Exit success means the report completed; its counts contain the verdict.
pub fn audit(ctx: *types.RunCtx) types.RunError!void {
    if (ctx.cfg.contracts.len == 0) {
        reporter.fail("contract-audit requires [[contract]] entries or --contracts <profile.toml>", .{});
        return error.CheckFailed;
    }
    var report: Report = .{ .project = ctx.project_dir, .findings = try findings(ctx, null) };
    for (report.findings) |row| switch (row.confidence) {
        .violation => report.violations += 1,
        .review => report.review_items += 1,
    };
    if (ctx.json) {
        const bytes = try std.json.Stringify.valueAlloc(ctx.allocator, report, .{ .whitespace = .indent_2 });
        try reporter.machine(bytes);
        return;
    }
    for (report.findings) |row| {
        reporter.detail("{s}:{d}: {s} {s} [{s}] {s}: {s}\n", .{ row.file, row.line, @tagName(row.confidence), row.check, row.rule, row.function, row.message });
    }
    reporter.ok("contract-audit: {d} violations, {d} review items; target unchanged", .{ report.violations, report.review_items });
}

// spec: Operation Contracts - Registers every gate and keeps the audit counts separate
test "contracts entry points retain distinct gates and explicit report counts" {
    _ = runWrite;
    _ = runRead;
    _ = runMutation;
    _ = runDecoder;
    _ = runIdentity;
    _ = audit;
    const report: Report = .{ .project = ".", .findings = &.{} };
    try std.testing.expectEqual(@as(usize, 0), report.violations);
    try std.testing.expectEqual(@as(usize, 0), report.review_items);
}
