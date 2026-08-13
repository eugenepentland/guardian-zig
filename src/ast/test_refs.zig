//! Which `@import`ed files a source file REFERENCES — the relation that decides
//! whether their `test` blocks are compiled at all.
//!
//! Zig does not compile every imported file's tests. It compiles the tests of a
//! file whose namespace is *referenced from an analyzed unit*, and an import
//! nobody touches is never such a reference. Measured on the pinned toolchain
//! (`0.17.0-dev.1683+5ceec001b`) with a four-file fixture:
//!
//! ```
//! const f = @import("f.zig");   // used: `f.foo()` in a test -> f's tests RUN
//! const g = @import("g.zig");   // never mentioned again     -> g's tests do NOT run
//! ```
//!
//! So a plain textual `@import` scan (what `import_graph.Node.edges` records,
//! and what the reachability check used to walk) over-states reachability: it
//! keeps a file alive through an import that references nothing. This module
//! records the tighter relation instead:
//!
//! * `_ = @import("p.zig")` — the aggregator idiom; the namespace itself is the
//!   referenced value.
//! * `@import("p.zig").member` — a decl of the file is referenced on the spot.
//! * `const alias = @import("p.zig");` — an edge only when `alias` is USED
//!   somewhere else in the file. An unused alias references nothing.
//! * `refAllDecls(...)` anywhere — every alias the file binds becomes an edge,
//!   since the call's whole purpose is to reference them.
//!
//! What it deliberately does NOT model: *where* the use sits. Zig only analyzes
//! a decl that something reachable calls, so a reference from a function no test
//! ever reaches compiles no tests either. Tracking that needs a cross-file
//! decl-level call graph; approximating it with "the file mentions the alias"
//! keeps this check free of false "dead" verdicts (the expensive kind — a real
//! test wrongly reported as never compiled) and leaves the residual gap to the
//! ground-truth counter in `checks/test_reachability.zig`.
//!
//! Validated against ground truth: over Guardian's own tree this model puts
//! exactly 950 tests in `src/check.zig`'s closure and 17 in
//! `src/test_runner.zig`'s, which is what the two test binaries report running.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tag = std.zig.Token.Tag;

/// One `const NAME = @import("PATH");` binding, pending the question of whether
/// the file ever uses `NAME`.
const Alias = struct { name: []const u8, path: []const u8 };

/// An `@import` whose classification depends on the token that follows it: a
/// `.` makes it an immediate member reference, anything else leaves it as the
/// binding (or the bare reference) it looked like.
const Pending = struct { path: []const u8, alias: ?[]const u8 };

/// One entry of the three-token lookbehind used to spot `const NAME =` in front
/// of an `@import`.
const Seen = struct { tag: Tag = .invalid, text: []const u8 = "" };

/// Zig's two `refAllDecls` spellings. Either one references every declaration of
/// the container it is handed, so every alias the file binds counts as used.
const ref_all_names = [_][]const u8{ "refAllDecls", "refAllDeclsRecursive" };

/// The `@import` paths this file references, deduplicated, in first-seen order.
/// Paths are the literal argument text (`"std"`, `"../a.zig"`); resolving them
/// against the walk set is the import graph's job.
///
/// Best-effort like `ast.imports`: an allocation failure propagates, but a
/// malformed `@import(` is skipped rather than aborting the scan, because this
/// runs over whatever bytes a repository holds.
pub fn referenced(arena: Allocator, source: []const u8) Allocator.Error![]const []const u8 {
    const z = try arena.dupeSentinel(u8, source, 0);
    var scan: Scan = .{ .arena = arena, .z = z };
    try scan.collect();
    return scan.finish();
}

/// Collector for one file's referenced imports.
const Scan = struct {
    arena: Allocator,
    z: [:0]const u8,
    /// Imports referenced on the spot: `_ = @import(...)`, `@import(...).x`, and
    /// any `@import` not bound to a plain `const` alias.
    direct: std.ArrayList([]const u8) = .empty,
    /// Imports bound to a `const` alias, resolved by the second pass.
    aliases: std.ArrayList(Alias) = .empty,
    /// Set when the file calls `refAllDecls`, which references every alias.
    ref_all: bool = false,

    fn text(self: *const Scan, token: std.zig.Token) []const u8 {
        return self.z[token.loc.start..token.loc.end];
    }

    /// Single token pass: records every `@import`, its alias binding when it has
    /// one, and whether the file calls `refAllDecls`.
    fn collect(self: *Scan) Allocator.Error!void {
        var tokenizer = std.zig.Tokenizer.init(self.z);
        var history: [3]Seen = @splat(.{});
        var pending: ?Pending = null;
        while (true) {
            const token = tokenizer.next();
            if (pending) |p| {
                try self.settle(p, token.tag == .period);
                pending = null;
            }
            if (token.tag == .eof) break;
            if (self.startsImport(token)) {
                pending = .{
                    .path = self.importPath(&tokenizer) orelse continue,
                    .alias = bindingName(history),
                };
                history = @splat(.{});
                continue;
            }
            if (token.tag == .identifier and isRefAll(self.text(token))) self.ref_all = true;
            // Shifted oldest-first and element by element: `history = .{ new,
            // history[0], history[1] }` builds the literal IN PLACE, so the
            // reads see the value just written and every slot ends up holding
            // the newest token.
            history[2] = history[1];
            history[1] = history[0];
            history[0] = .{ .tag = token.tag, .text = self.text(token) };
        }
    }

    /// True when `token` opens an `@import(...)` builtin call.
    fn startsImport(self: *const Scan, token: std.zig.Token) bool {
        return token.tag == .builtin and std.mem.eql(u8, self.text(token), "@import");
    }

    /// Consumes `("path")` and returns the path, or null when the call is not
    /// the plain single-string-literal form.
    fn importPath(self: *const Scan, tokenizer: *std.zig.Tokenizer) ?[]const u8 {
        if (tokenizer.next().tag != .l_paren) return null;
        const literal = tokenizer.next();
        if (literal.tag != .string_literal) return null;
        if (tokenizer.next().tag != .r_paren) return null;
        const raw = self.text(literal);
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
        return raw[1 .. raw.len - 1];
    }

    /// Files a settled `@import`: a member access right after the call, or an
    /// import that binds no alias, references the file immediately; anything
    /// else waits for the second pass to say whether its alias is used.
    fn settle(self: *Scan, p: Pending, member_access: bool) Allocator.Error!void {
        const name = p.alias orelse return self.direct.append(self.arena, p.path);
        if (member_access) return self.direct.append(self.arena, p.path);
        try self.aliases.append(self.arena, .{ .name = name, .path = p.path });
    }

    /// The referenced set: every direct reference, plus each alias the file
    /// actually mentions (all of them under `refAllDecls`).
    fn finish(self: *Scan) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.direct.items) |path| try appendUnique(self.arena, &out, path);
        if (self.aliases.items.len == 0) return out.toOwnedSlice(self.arena);
        const uses = try self.aliasUses();
        for (self.aliases.items, uses) |alias, count| {
            // The binding itself is one occurrence of the name, so a second one
            // is the first real use.
            if (self.ref_all or count > 1) try appendUnique(self.arena, &out, alias.path);
        }
        return out.toOwnedSlice(self.arena);
    }

    /// How many times each alias name occurs as a plain identifier (a field
    /// access `x.name` is the field's name, not this alias). Second token pass,
    /// so an alias declared below its use still counts — container declarations
    /// are order-independent in Zig.
    fn aliasUses(self: *const Scan) Allocator.Error![]const u32 {
        const counts = try self.arena.alloc(u32, self.aliases.items.len);
        @memset(counts, 0);
        var tokenizer = std.zig.Tokenizer.init(self.z);
        var previous: Tag = .invalid;
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag == .identifier and previous != .period) {
                const name = self.text(token);
                for (self.aliases.items, counts) |alias, *count| {
                    if (std.mem.eql(u8, alias.name, name)) count.* += 1;
                }
            }
            previous = token.tag;
        }
        return counts;
    }
};

/// The alias name in front of an `@import`, given the three tokens preceding it
/// (most recent first): `const NAME =` binds, anything else does not.
fn bindingName(history: [3]Seen) ?[]const u8 {
    if (history[0].tag != .equal) return null;
    if (history[1].tag != .identifier) return null;
    if (history[2].tag != .keyword_const) return null;
    return history[1].text;
}

/// True when `name` is one of Zig's `refAllDecls` spellings.
fn isRefAll(name: []const u8) bool {
    for (ref_all_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Appends `path` unless the list already holds it, keeping first-seen order so
/// the graph's edges stay deterministic.
fn appendUnique(
    arena: Allocator,
    list: *std.ArrayList([]const u8),
    path: []const u8,
) Allocator.Error!void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try list.append(arena, path);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// True when `paths` holds `needle` (test-local, so assertions stay loop-free).
fn holds(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, needle)) return true;
    }
    return false;
}

// spec: Test Reachability - Reads an import bound to an alias the file never mentions as no test edge

test "referenced drops an import whose alias is never used" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try referenced(arena.allocator(),
        \\const used = @import("used.zig");
        \\const unused = @import("unused.zig");
        \\pub fn go() u32 { return used.value; }
    );
    // Measured Zig behavior: an import nobody mentions references nothing, so
    // the imported file's tests are never compiled.
    try testing.expect(holds(refs, "used.zig"));
    try testing.expect(!holds(refs, "unused.zig"));
}

// spec: Test Reachability - Reads a discarded or member-accessed import as a test edge

test "referenced keeps a discarded import and an import accessed in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try referenced(arena.allocator(),
        \\const lineOf = @import("text.zig").lineOf;
        \\test {
        \\    _ = @import("aggregated.zig");
        \\}
    );
    // The aggregator idiom and a member access are both references on the spot,
    // regardless of whether anything binds them to a name.
    try testing.expect(holds(refs, "aggregated.zig"));
    try testing.expect(holds(refs, "text.zig"));
}

// spec: Test Reachability - Reads a discarded alias as a test edge to that import

test "referenced keeps an alias discarded by a later statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try referenced(arena.allocator(),
        \\const helper = @import("helper.zig");
        \\comptime {
        \\    _ = helper;
        \\}
    );
    // `_ = alias;` is the same reference as `_ = @import(...)`, only spelled
    // through the binding — and the binding may sit above or below it.
    try testing.expect(holds(refs, "helper.zig"));
}

// spec: Test Reachability - Reads refAllDecls as a test edge to every import the file binds

test "referenced keeps every alias when the file calls refAllDecls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try referenced(arena.allocator(),
        \\const std = @import("std");
        \\const quiet = @import("quiet.zig");
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
    );
    // refAllDecls exists to reference declarations, so an otherwise unmentioned
    // alias is referenced after all.
    try testing.expect(holds(refs, "quiet.zig"));
    try testing.expect(holds(refs, "std"));
}

// spec: Test Reachability - Ignores an import spelled inside a comment or a string

test "referenced counts each import once and ignores comments and strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const refs = try referenced(arena.allocator(),
        \\// _ = @import("commented.zig");
        \\const s = "_ = @import(\"quoted.zig\")";
        \\test {
        \\    _ = @import("real.zig");
        \\    _ = @import("real.zig");
        \\}
    );
    // Token-based, so only the real call counts — and repeats collapse, since an
    // edge is a relation rather than a tally.
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("real.zig", refs[0]);
}
