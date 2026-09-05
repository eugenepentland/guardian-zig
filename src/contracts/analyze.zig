//! Five declaration-scoped policies over one shared call graph. Definite
//! violations and unverified contracts remain separate in every output format.
const std = @import("std");
const config = @import("../config.zig");
const model = @import("model.zig");
const index = @import("index.zig");
const flow = @import("error_flow.zig");
const A = std.mem.Allocator;

const Diagnostic = struct { confidence: model.Confidence, code: []const u8, message: []const u8 };

const Scan = struct {
    allocator: A,
    findings: std.ArrayList(model.Finding) = .empty,

    fn add(self: *Scan, rule: config.ContractRule, f: index.Function, call: ?index.Call, diagnostic: Diagnostic) A.Error!void {
        const confidence = diagnostic.confidence;
        const code = diagnostic.code;
        const message = diagnostic.message;
        const operation = if (call) |c| c.name else f.qualified;
        // One row per declaration, operation and failure class. Moving lines or
        // repeating the same raw call does not inflate the backlog.
        for (self.findings.items) |old| {
            if (std.mem.eql(u8, old.rule, rule.name) and std.mem.eql(u8, old.function, f.qualified) and std.mem.eql(u8, old.operation, operation) and std.mem.eql(u8, old.code, code)) return;
        }
        const kind = std.meta.stringToEnum(model.Kind, rule.kind).?;
        try self.findings.append(self.allocator, .{ .check = kind.checkName(), .rule = rule.name, .file = f.file, .function = f.qualified, .line = if (call) |c| c.line else f.line, .confidence = confidence, .code = code, .operation = operation, .message = message, .reason = rule.reason });
    }

    fn errors(self: *Scan, rule: config.ContractRule, f: index.Function, marked: []const bool, kind: model.Kind) A.Error!void {
        var reaches = false;
        for (f.calls.items) |call| {
            if (!model.matches(rule.operations, call.name) and !(if (call.target) |t| marked[t] else false)) continue;
            reaches = true;
            const handler = call.handler orelse continue;
            const result = try flow.analyze(self.allocator, handler.source, handler.capture, kind == .persistent_read);
            switch (result) {
                .erased => try self.add(rule, f, call, .{ .confidence = .violation, .code = "failure-erased", .message = "operation failure becomes a normal return or default" }),
                .unknown => try self.add(rule, f, call, .{ .confidence = .review, .code = "handler-unverified", .message = "handler is too complex to prove failure propagation; inspect every exit" }),
                .propagated => {},
            }
        }
        if (kind == .durable_write and reaches and std.mem.eql(u8, f.return_type, "void"))
            try self.add(rule, f, null, .{ .confidence = .violation, .code = "no-write-result", .message = "durable-write wrapper returns void; callers cannot observe persistence failure" });
    }

    fn boundary(self: *Scan, rule: config.ContractRule, f: index.Function, kind: model.Kind) A.Error!void {
        for (f.calls.items) |call| {
            if (!model.matches(rule.operations, call.name)) continue;
            const message = if (kind == .transaction)
                "raw mutation bypasses the declared transaction owner"
            else
                "raw request parsing bypasses the declared decoder owner";
            try self.add(rule, f, call, .{ .confidence = .violation, .code = "boundary-bypass", .message = message });
        }
    }

    fn identity(self: *Scan, rule: config.ContractRule, f: index.Function) A.Error!void {
        var first: ?index.Call = null;
        for (f.calls.items) |call| {
            if (!model.matches(rule.operations, call.name)) continue;
            if (first == null or call.offset < first.?.offset) first = call;
        }
        const effect = first orelse return;
        for (f.calls.items) |call| {
            if (!model.matches(rule.validators, call.name) or call.offset >= effect.offset) continue;
            const has_id = try flow.hasIdentifier(self.allocator, call.arguments, rule.identity);
            const has_rev = try flow.hasIdentifier(self.allocator, call.arguments, rule.revision);
            if (has_id and has_rev) {
                // Presence does not prove dominance, result use, or that a
                // validator is correct. Do not turn this lexical evidence green.
                try self.add(rule, f, call, .{ .confidence = .review, .code = "validator-unverified", .message = "identity/revision validator is present; verify dominance and use of its validated target" });
                return;
            }
        }
        try self.add(rule, f, effect, .{ .confidence = .review, .code = "identity-unverified", .message = "no preceding declared validator receives both identity and revision before target selection or mutation" });
    }
};

/// Inspect all selected declarations. Unmatched selectors are review findings,
/// so renaming a boundary never silently disables a configured contract.
pub fn run(a: A, graph: *const index.Graph, rules: []const config.ContractRule, only: ?model.Kind) A.Error![]const model.Finding {
    var scan: Scan = .{ .allocator = a };
    for (rules) |rule| {
        const kind = std.meta.stringToEnum(model.Kind, rule.kind).?;
        if (only != null and only.? != kind) continue;
        const marked = try graph.effects(a, rule.operations);
        var selected: ?index.Function = null;
        var reaches = false;
        for (rule.functions) |selector| {
            var matched = false;
            for (graph.functions, 0..) |f, i| {
                if (!model.matches(&.{selector}, f.qualified)) continue;
                matched = true;
                selected = f;
                reaches = reaches or marked[i];
                if (model.matches(rule.allow, f.qualified)) continue;
                switch (kind) {
                    .durable_write, .persistent_read => try scan.errors(rule, f, marked, kind),
                    .transaction, .decoder => try scan.boundary(rule, f, kind),
                    .identity => try scan.identity(rule, f),
                }
            }
            if (!matched) try scan.findings.append(a, .{ .check = kind.checkName(), .rule = rule.name, .file = selector, .function = selector, .line = 0, .confidence = .review, .code = "unmatched-selector", .operation = selector, .message = "configured function selector matches no declaration", .reason = rule.reason });
        }
        if (!reaches) {
            if (selected) |f| try scan.add(rule, f, null, .{ .confidence = .review, .code = "unmatched-operation", .message = "selected declarations reach no configured operation; verify renamed calls and analysis coverage" });
        }
    }
    return scan.findings.toOwnedSlice(a);
}
