const std = @import("std");
const stage = @import("../stage.zig");
const pipeline = @import("../pipeline.zig");
const StageResult = stage.StageResult;

const FileClass = enum { spec, @"test", impl, config, other };

const ChangeType = enum {
    spec_only,
    test_only,
    impl_only,
    spec_and_impl,
    config_only,
    mixed,

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .spec_only => "spec-only",
            .test_only => "test-only",
            .impl_only => "impl-only",
            .spec_and_impl => "spec+impl",
            .config_only => "config-only",
            .mixed => "mixed",
        };
    }
};

fn classifyFile(path: []const u8) FileClass {
    if (std.mem.eql(u8, path, "SPEC.md")) return .spec;
    if (std.mem.eql(u8, path, "build.zig") or
        std.mem.eql(u8, path, "build.zig.zon") or
        std.mem.eql(u8, path, "guardian.toml")) return .config;
    if (std.mem.startsWith(u8, path, "test/")) return .@"test";
    if (std.mem.startsWith(u8, path, "src/")) return .impl;
    return .other;
}

fn classifyFiles(files: []const []const u8) ChangeType {
    var has_spec = false;
    var has_test = false;
    var has_impl = false;
    var has_config = false;

    for (files) |f| {
        switch (classifyFile(f)) {
            .spec => has_spec = true,
            .@"test" => has_test = true,
            .impl => has_impl = true,
            .config => has_config = true,
            .other => {},
        }
    }

    if (has_spec and has_impl) return .spec_and_impl;
    if (has_spec and !has_impl and !has_test and !has_config) return .spec_only;
    if (has_test and !has_spec and !has_impl and !has_config) return .test_only;
    if (has_impl and !has_spec and !has_test and !has_config) return .impl_only;
    if (has_config and !has_spec and !has_impl and !has_test) return .config_only;
    return .mixed;
}

pub fn run(ctx: *pipeline.Context) StageResult {
    const files = ctx.changed_files;
    const change_type = classifyFiles(files);

    if (change_type == .spec_and_impl) {
        var has_tests = false;
        for (files) |f| {
            if (std.mem.startsWith(u8, f, "test/")) {
                has_tests = true;
                break;
            }
        }
        if (!has_tests) {
            return stage.failed(
                "Change Classification",
                &.{"Spec and implementation changes detected without corresponding test changes"},
                &.{"Add or update tests to cover the new spec behaviors and implementation"},
            );
        }
    }

    const detail = std.fmt.allocPrint(ctx.allocator, "Change type: {s}", .{change_type.toString()}) catch "Change type: unknown";
    return stage.passed("Change Classification", detail);
}
