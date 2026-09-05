//! `abi-layout` — an `extern`/`packed struct` is an ABI contract with something
//! outside the compiler (a C header, a file format, a wire protocol), and Zig
//! will silently give it a different size than the contract requires.
//!
//! The evidence is ziglang/zig#23564, "packed struct fields in extern structs
//! can unexpectedly change the size of the struct" (opened 2025-04-13).
//! Substituting a `packed struct(u128)` `EIdent` for the plain
//! `e_ident: [EI_NIDENT]u8` field in `lib/std/elf.zig` made
//! `@sizeOf(Elf32_Ehdr)` **64** instead of the ABI-required **52**: the packed
//! struct's backing integer carries the alignment of a `u128`, which pads the
//! containing extern struct. Maintainer alexrp: "Seems like an alignment
//! thing; works if you apply `align(1)` to `e_ident`." The issue was closed
//! **`not_planned`** — "This behavior matches the C ABI so I don't think
//! there's actually a bug here" — which is what makes this a PERMANENT hazard
//! rather than one awaiting a compiler fix. It will never be diagnosed for you.
//!
//! Critically, the only thing that caught it was a hand-written comptime
//! assertion: the failure surfaced as `error: reached unreachable code` at
//! `assert(@sizeOf(Elf32_Ehdr) == 52)`, with **zero** compiler diagnostic about
//! the struct itself. std treats generated size assertions as the standard
//! mitigation — `lib/std/elf.zig` carries a contiguous run of seven of them.
//! Without one, the wrong size is not an error anywhere; it is a struct that
//! reads and writes the wrong bytes at run time.
//!
//! Two halves, independently controlled:
//!
//!   (a) INVENTORY (advisory by default) — every `extern struct` / `packed
//!       struct` declaration should be pinned by a `@sizeOf(T) == N` or
//!       `@offsetOf(T, ...) == N` comparison **in the same file**. Advisory
//!       because a project's internal-only extern struct (an FFI shim it owns
//!       both ends of) has no ABI contract to pin; `[abi_layout]
//!       require_assertions = true` promotes it to a blocking gate, and
//!       `[[allow]] check = "abi-layout"` paths exempt files outright.
//!
//!   (b) ALIGNMENT HAZARD (blocking) — an `extern struct` field whose declared
//!       type resolves to a `packed struct` backed by **more than 64 bits** and
//!       carrying no explicit `align(...)`. This is #23564 itself, reduced to
//!       the shape that actually produces it. `[abi_layout] alignment_hazard =
//!       false` turns it off.
//!
//! Why (b) is 64 bits and not "wider than u8" — the obvious rule, measured and
//! rejected. Run over all of `lib/std` (161 files' worth of real ABI structs),
//! "wider than u8" produced **36** findings, and probing them showed the
//! overwhelming majority are correct code: a `packed struct(u32)` field among
//! u32 siblings is 12 bytes with or without `align(1)`, and wasi's `fdstat_t`
//! is 24 bytes *because* the C struct is — adding `align(1)` would have broken
//! it to 20. Two compiler facts explain why, and they collapse the rule:
//! Zig rejects any other backing outright ("only integers with 0, 8, 16, 32, 64
//! and 128 bits are extern compatible"), and of the widths it does accept,
//! 8/16/32/64 have exactly `uintN_t`'s alignment — a packed struct there stands
//! in for a C scalar and pads nothing the C field would not. That leaves 128,
//! which has no C scalar counterpart: the only extern-legal backing whose
//! alignment (16) can be a surprise, and precisely the `packed struct(u128)`
//! EIdent of #23564. On all of `lib/std` the narrowed rule reports **0**.
//! The residual false positive is a field genuinely modeling a C `__int128`,
//! whose 16-byte alignment is correct — spell that intent as `align(16)` and
//! the check steps aside, since any explicit alignment exonerates.
//!
//! Co-location, not a designated layout-test file, is what half (a) demands
//! (hence `scope = .per_file`). Three reasons: the assertion must ride the same
//! review diff as the struct — the failure mode IS an agent editing the struct
//! without touching its contract; a separate test file can be dropped from the
//! build, filtered out by `-Dtest-filter`, or simply never referenced, and Zig
//! only analyzes referenced code, so the guarantee evaporates with no signal;
//! and same-file identity is exact, where a cross-file lookup by type NAME is
//! ambiguous the moment two files declare a `Header`.
//!
//! Limitations, all deliberately fail-safe (a miss, never a false positive):
//!   * The satisfier for (a) is a `@sizeOf`/`@offsetOf` on either side of an
//!     `==`/`!=`. `assert(@sizeOf(T) == 52)`, a bare `comptime { ... }` block
//!     and `try expect(@sizeOf(T) == 52)` all count; the argument-position form
//!     `expectEqual(52, @sizeOf(T))` does NOT — rewrite it as the comparison.
//!   * (b) resolves a field type only when it is a plain identifier naming a
//!     packed struct declared in the SAME file. A dotted `mod.EIdent`, an
//!     array/pointer of one, or a type imported from another file is not
//!     resolved — matching (a)'s co-location premise rather than guessing.
//!   * (b) reads the backing width from `packed struct(uN)` when it is spelled,
//!     and otherwise infers it by summing field widths when every field is a
//!     primitive `uN`/`iN`/`bool`. Anything else is "unknown" and never flagged.
//!   * A packed struct standing in for a byte ARRAY at a C-scalar width (the
//!     #23564 mistake made with a `packed struct(u64)` instead of a u128) is
//!     indistinguishable in source from one standing in for a `uint64_t`, and
//!     is not flagged. Half (a)'s size assertion is what covers that case —
//!     which is the whole reason the two halves ship as one check.
//!   * A field carrying any explicit `align(...)` is left alone: an explicit
//!     alignment is a deliberate ABI decision, and only a missing one is the
//!     accident #23564 describes.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const decls = @import("../ast/decls.zig");
const config_mod = @import("../config.zig");
const lineOf = @import("../text.zig").lineOf;

const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

/// Registry name (also the `[[allow]]` key).
pub const check_name = "abi-layout";

/// Widest backing integer that still has a C scalar counterpart. A packed
/// struct backed by 8/16/32/64 bits has exactly `uintN_t`'s alignment, so it
/// pads its host no differently than the C field it stands in for; only a
/// wider backing brings an alignment C has no name for. Measured, not assumed —
/// see the module header's std run.
const c_scalar_max_bits: u16 = 64;

/// Which half of the check produced a finding. The two travel together (one
/// walk, one type table) but report on different channels: `inventory` is
/// advisory by default, `alignment` blocks.
pub const Half = enum { inventory, alignment };

/// One finding, pre-rendered. `identity` is the baseline v3 key discriminator —
/// what was flagged, independent of wording, so the message may be reworded
/// without re-keying a consumer's baseline (see `violation_key.zig`).
pub const Finding = struct {
    half: Half,
    line: u32,
    message: []const u8,
    identity: []const u8,
};

/// The memory layout keyword on a container declaration.
const Layout = enum { extern_, packed_ };

/// One `extern`/`packed struct` declaration found in a file.
const LayoutDecl = struct {
    name: []const u8,
    layout: Layout,
    line: u32,
    /// The container node, so the field walk can revisit its members.
    node: Ast.Node.Index,
    /// Backing width in bits for a packed struct: the `(uN)` argument when
    /// spelled, else inferred from primitive field widths, else null (unknown).
    backing_bits: ?u16,
};

// ── Layout-decl collection ─────────────────────────────────────────────

/// Every `const Name = extern|packed struct { ... }` reachable from the root,
/// including ones nested inside other containers (`collectDecls` recurses, so
/// wrapping a struct in a namespace cannot dodge the check).
fn collectLayoutDecls(a: Allocator, tree: *const Ast) Allocator.Error![]const LayoutDecl {
    var out: std.ArrayList(LayoutDecl) = .empty;
    var t = tree.*;
    for (try decls.collectDecls(a, &t)) |decl| {
        const var_decl = t.fullVarDecl(decl) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        var buf: [2]Ast.Node.Index = undefined;
        const cdecl = t.fullContainerDecl(&buf, init_node) orelse continue;
        const layout_tok = cdecl.layout_token orelse continue;
        const layout: Layout = switch (t.tokenTag(layout_tok)) {
            .keyword_extern => .extern_,
            .keyword_packed => .packed_,
            else => continue,
        };
        // `extern union` / `packed union` are containers too, but neither is
        // the shape #23564 describes and neither has a stable field-offset
        // contract to pin, so only structs are inventoried.
        if (t.tokenTag(cdecl.ast.main_token) != .keyword_struct) continue;

        const name_tok = var_decl.ast.mut_token + 1;
        try out.append(a, .{
            .name = t.tokenSlice(name_tok),
            .layout = layout,
            .line = lineOf(t.source, t.tokenStart(layout_tok)),
            .node = init_node,
            .backing_bits = if (layout == .packed_) backingBits(&t, cdecl) else null,
        });
    }
    return out.toOwnedSlice(a);
}

/// Backing width of a packed struct in bits: the explicit `packed struct(uN)`
/// argument when present, else the sum of the field widths when EVERY field is
/// a primitive `uN`/`iN`/`bool`. Null means "cannot be determined" — the
/// alignment half then leaves the type alone rather than guessing.
fn backingBits(tree: *const Ast, cdecl: Ast.full.ContainerDecl) ?u16 {
    if (cdecl.ast.arg.unwrap()) |arg| return intBits(std.mem.trim(u8, tree.getNodeSource(arg), " \t"));

    var total: u16 = 0;
    for (cdecl.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        const type_node = field.ast.type_expr.unwrap() orelse return null;
        const text = std.mem.trim(u8, tree.getNodeSource(type_node), " \t");
        if (std.mem.eql(u8, text, "bool")) {
            total += 1;
        } else {
            total += intBits(text) orelse return null;
        }
    }
    return total;
}

/// Bit width of a primitive integer type spelling (`u128`, `i7`), or null when
/// `text` is not one. Deliberately strict: `usize` has no fixed width in source
/// and is not an ABI-pinnable spelling, so it reads as unknown.
fn intBits(text: []const u8) ?u16 {
    if (text.len < 2) return null;
    if (text[0] != 'u' and text[0] != 'i') return null;
    return std.fmt.parseInt(u16, text[1..], 10) catch null;
}

// ── (a) Assertion inventory ────────────────────────────────────────────

/// True when `content` compares `@sizeOf(<name>)` or `@offsetOf(<name>, ...)`
/// against something — the hand-written layout assertion std uses as the
/// standard mitigation. The comparison requirement is what keeps an ordinary
/// `alloc(@sizeOf(T))` from reading as a contract.
fn hasLayoutAssertion(content: [:0]const u8, name: []const u8) bool {
    var tok = std.zig.Tokenizer.init(content);
    // A comparison on EITHER side counts: `assert(N == @sizeOf(T))` pins the
    // layout exactly as well as `assert(@sizeOf(T) == N)`.
    var prev_tag: std.zig.Token.Tag = .invalid;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return false;
        if (t.tag == .builtin and isLayoutBuiltin(content[t.loc.start..t.loc.end])) {
            if (firstArgNames(content, t.loc.end, name)) |after| {
                if (isEquality(prev_tag)) return true;
                // Resume just past the call so its argument tokens are never
                // re-read as surrounding context.
                tok.index = after;
                const following = tok.next();
                if (isEquality(following.tag)) return true;
                if (following.tag == .eof) return false;
                prev_tag = following.tag;
                continue;
            }
        }
        prev_tag = t.tag;
    }
}

/// True for the two builtins that state a layout contract.
fn isLayoutBuiltin(text: []const u8) bool {
    return std.mem.eql(u8, text, "@sizeOf") or std.mem.eql(u8, text, "@offsetOf");
}

/// True for the comparison operators that turn a `@sizeOf` into an assertion.
fn isEquality(tag: std.zig.Token.Tag) bool {
    return tag == .equal_equal or tag == .bang_equal;
}

/// Scans the argument list starting at `open` (the byte just past the builtin
/// name, expected to be `(`). Returns the byte offset just past the closing
/// `)` when the FIRST argument is exactly the identifier `name`, else null.
/// Only a bare identifier matches: `mod.Header` names another file's type, and
/// resolving it here by its last segment would collide with a local `Header`.
fn firstArgNames(content: [:0]const u8, open: usize, name: []const u8) ?usize {
    var tok = std.zig.Tokenizer.init(content);
    tok.index = open;
    if (tok.next().tag != .l_paren) return null;

    const first = tok.next();
    if (first.tag != .identifier) return null;
    if (!std.mem.eql(u8, content[first.loc.start..first.loc.end], name)) return null;

    // Consume to the matching `)`, tolerating a second argument (`@offsetOf`'s
    // field name) and any nesting inside it.
    var depth: usize = 1;
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) return null;
        switch (t.tag) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return t.loc.end;
            },
            // A dotted or indexed first argument is not the bare identifier
            // form this resolves, so stop rather than accept a near-match.
            .period, .l_bracket => if (depth == 1) return null,
            else => {},
        }
    }
}

// ── (b) Alignment hazard ───────────────────────────────────────────────

/// The packed struct a field's declared type names, or null when the type is
/// not a plain same-file identifier resolving to one.
fn resolvePacked(table: []const LayoutDecl, type_text: []const u8) ?LayoutDecl {
    if (!isBareIdentifier(type_text)) return null;
    for (table) |d| {
        if (d.layout == .packed_ and std.mem.eql(u8, d.name, type_text)) return d;
    }
    return null;
}

/// True when `text` is a single identifier — no dots, brackets, pointers or
/// whitespace. Anything else is a type this per-file check does not resolve.
fn isBareIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.isDigit(text[0])) return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

// ── Analysis ───────────────────────────────────────────────────────────

/// Pure-function entry: every finding for one file's `content`, allocator-owned
/// and tagged with the half that produced it. Empty slice = clean. The
/// filesystem never appears here, so the inline tests exercise the real
/// analysis rather than a walker.
pub fn analyzeContent(
    allocator: Allocator,
    content: [:0]const u8,
) Allocator.Error![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    var tree = try Ast.parse(allocator, content, .{});
    // A file that does not parse has no declarations to judge; the formatting
    // and compile gates own syntax errors.
    if (tree.errors.len > 0) return out.toOwnedSlice(allocator);

    const table = try collectLayoutDecls(allocator, &tree);
    try inventory(allocator, &out, content, table);
    try alignmentHazards(allocator, &out, &tree, table);
    return out.toOwnedSlice(allocator);
}

/// Half (a): every layout decl with no co-located `@sizeOf`/`@offsetOf` pin.
fn inventory(
    a: Allocator,
    out: *std.ArrayList(Finding),
    content: [:0]const u8,
    table: []const LayoutDecl,
) Allocator.Error!void {
    for (table) |d| {
        if (hasLayoutAssertion(content, d.name)) continue;
        try out.append(a, .{
            .half = .inventory,
            .line = d.line,
            .message = try std.fmt.allocPrint(
                a,
                "{s} struct {s} has no @sizeOf/@offsetOf assertion in this file",
                .{ if (d.layout == .extern_) "extern" else "packed", d.name },
            ),
            .identity = try std.fmt.allocPrint(a, "inventory:{s}", .{d.name}),
        });
    }
}

/// Half (b): every `extern struct` field whose type is a same-file packed
/// struct backed by more than a byte and carrying no explicit alignment.
fn alignmentHazards(
    a: Allocator,
    out: *std.ArrayList(Finding),
    tree: *const Ast,
    table: []const LayoutDecl,
) Allocator.Error!void {
    var buf: [2]Ast.Node.Index = undefined;
    for (table) |host| {
        if (host.layout != .extern_) continue;
        const cdecl = tree.fullContainerDecl(&buf, host.node) orelse continue;
        for (cdecl.ast.members) |member| {
            const field = tree.fullContainerField(member) orelse continue;
            if (field.ast.align_expr != .none) continue;
            const type_node = field.ast.type_expr.unwrap() orelse continue;
            const type_text = std.mem.trim(u8, tree.getNodeSource(type_node), " \t");
            const inner = resolvePacked(table, type_text) orelse continue;
            const bits = inner.backing_bits orelse continue;
            if (bits <= c_scalar_max_bits) continue;

            const field_name = tree.tokenSlice(field.ast.main_token);
            try out.append(a, .{
                .half = .alignment,
                .line = lineOf(tree.source, tree.tokenStart(field.ast.main_token)),
                .message = try std.fmt.allocPrint(
                    a,
                    "extern struct {s} field {s}: {s} is a packed struct backed by {d} bits, " ++
                        "wider than any C scalar — its alignment silently grows {s}; add align(1)",
                    .{ host.name, field_name, type_text, bits, host.name },
                ),
                .identity = try std.fmt.allocPrint(a, "alignment:{s}.{s}", .{ host.name, field_name }),
            });
        }
    }
}

// ── Run ────────────────────────────────────────────────────────────────

const ScanCtx = struct {
    allocator: Allocator,
    blocking: *std.ArrayList(reporter.Violation),
    advisory: *std.ArrayList(reporter.Violation),
    cfg: config_mod.AbiLayoutCfg,
    /// `[[allow]]` path globs: a matching file is skipped whole (both halves —
    /// the per-half switches are the independent control).
    allowed_paths: []const []const u8 = &.{},
};

fn visit(raw_ctx: *anyopaque, entry: walk.FileEntry) !void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    for (ctx.allowed_paths) |pat| {
        if (walk.matchGlob(entry.rel_path, pat)) return;
    }
    const a = ctx.allocator;
    for (try analyzeContent(a, entry.content)) |f| {
        // The alignment half is one narrow shape: switching it off silences it
        // outright rather than demoting it to advice nobody asked for. The
        // inventory half only ever changes CHANNEL, never visibility.
        if (f.half == .alignment and !ctx.cfg.alignment_hazard) continue;
        const blocks = f.half == .alignment or ctx.cfg.require_assertions;
        const v: reporter.Violation = .{
            .check = check_name,
            .file = entry.rel_path,
            .line = f.line,
            .message = f.message,
            .identity = f.identity,
        };
        try (if (blocks) ctx.blocking else ctx.advisory).append(a, v);
    }
}

/// Entry point for the abi-layout check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const cfg = ctx_param.cfg.abi_layout;
    var blocking: std.ArrayList(reporter.Violation) = .empty;
    var advisory: std.ArrayList(reporter.Violation) = .empty;
    var ctx: ScanCtx = .{
        .allocator = allocator,
        .blocking = &blocking,
        .advisory = &advisory,
        .cfg = cfg,
        .allowed_paths = ctx_param.cfg.extraAllowed(check_name),
    };
    try ast_index.runSrc(ctx_param.source_index, allocator, ctx_param.project_dir, .{ .ctx = &ctx, .visit = visit });

    for (advisory.items) |v| reporter.warn(v);

    if (blocking.items.len == 0) {
        if (advisory.items.len == 0) {
            ok("abi-layout: every extern/packed struct is pinned and no packed field pads its host", .{});
        } else {
            ok(
                "abi-layout: no blocking alignment hazard ({d} unpinned layout struct(s) reported)",
                .{advisory.items.len},
            );
        }
        return;
    }
    fail("abi-layout FAILED ({d} finding(s))", .{blocking.items.len});
    for (blocking.items) |v| reporter.emit(v);
    print("  fix: give the field align(1) (ziglang/zig#23564, closed not_planned — " ++
        "the C ABI does this on purpose), and pin the struct with a comptime " ++
        "assert(@sizeOf(T) == N) beside it.\n", .{});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Findings of one half, for the assertions below.
fn only(found: []const Finding, half: Half) usize {
    var n: usize = 0;
    for (found) |f| {
        if (f.half == half) n += 1;
    }
    return n;
}

// spec: ABI Layout - Reports an extern or packed struct with no co-located size or offset assertion

test "analyzeContent reports an unpinned extern struct and an unpinned packed struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(),
        \\const Header = extern struct { a: u32, b: u32 };
        \\const Flags = packed struct(u16) { x: u1, rest: u15 };
        \\const Plain = struct { a: u32 };
    );
    // The plain struct is not a layout contract and is never inventoried.
    try testing.expectEqual(@as(usize, 2), only(found, .inventory));
    try testing.expect(std.mem.indexOf(u8, found[0].message, "extern struct Header") != null);
}

// spec: ABI Layout - Accepts a layout struct pinned by a sizeOf or offsetOf comparison

test "analyzeContent accepts a struct pinned by sizeOf, offsetOf, or a reversed comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(),
        \\const A = extern struct { a: u32 };
        \\const B = extern struct { b: u32 };
        \\const C = extern struct { c: u32 };
        \\comptime {
        \\    assert(@sizeOf(A) == 4);
        \\    assert(@offsetOf(B, "b") == 0);
        \\    assert(8 == @sizeOf(C));
        \\}
    );
    try testing.expectEqual(@as(usize, 0), only(found, .inventory));
}

// spec: ABI Layout - Ignores a sizeOf that is not part of a comparison

test "analyzeContent does not count a bare sizeOf use as a layout assertion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(),
        \\const A = extern struct { a: u32 };
        \\fn make(alloc: anytype) void {
        \\    _ = alloc.alloc(u8, @sizeOf(A));
        \\}
    );
    // An allocation sized by the struct states no contract about that size.
    try testing.expectEqual(@as(usize, 1), only(found, .inventory));
}

// spec: ABI Layout - Flags an extern struct field whose packed type is backed wider than any C scalar and lacks align(1)

test "analyzeContent flags a wide packed field with no align and names the fix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The reduced ziglang/zig#23564 shape: a packed struct(u128) substituted for
    // a byte array silently pushes @sizeOf(Ehdr) from 52 to 64.
    const found = try analyzeContent(arena.allocator(),
        \\const EIdent = packed struct(u128) { magic: u32, rest: u96 };
        \\const Ehdr = extern struct {
        \\    e_ident: EIdent,
        \\    e_type: u16,
        \\};
    );
    try testing.expectEqual(@as(usize, 1), only(found, .alignment));
    for (found) |f| {
        if (f.half != .alignment) continue;
        try testing.expect(std.mem.indexOf(u8, f.message, "e_ident") != null);
        try testing.expect(std.mem.indexOf(u8, f.message, "align(1)") != null);
        try testing.expectEqualStrings("alignment:Ehdr.e_ident", f.identity);
    }
}

// spec: ABI Layout - Accepts a wide packed field carrying an explicit alignment

test "analyzeContent accepts a wide packed field with align(1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(),
        \\const EIdent = packed struct(u128) { magic: u32, rest: u96 };
        \\const Ehdr = extern struct {
        \\    e_ident: EIdent align(1),
        \\    e_type: u16,
        \\};
    );
    try testing.expectEqual(@as(usize, 0), only(found, .alignment));
}

// spec: ABI Layout - Leaves a packed field whose backing width matches a C scalar alone

test "analyzeContent leaves C-scalar-backed packed fields and unresolved types alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(),
        \\const Bits = packed struct(u8) { a: u4, b: u4 };
        \\const Flags = packed struct(u32) { a: bool, rest: u31 };
        \\const Rights = packed struct(u64) { a: bool, rest: u63 };
        \\const Elsewhere = extern struct {
        \\    bits: Bits,
        \\    flags: Flags,
        \\    rights: Rights,
        \\    other: mod.Wide,
        \\};
    );
    // 8/16/32/64 have exactly uintN_t's alignment, so the packed struct pads
    // nothing the C field it stands in for would not — measured across lib/std,
    // where the "wider than u8" rule produced 36 findings and this one produces
    // none. `mod.Wide` is not a same-file identifier and is not resolved.
    try testing.expectEqual(@as(usize, 0), only(found, .alignment));
}

// spec: ABI Layout - Infers a packed struct backing width from primitive field widths

test "backingBits reads the explicit argument and otherwise sums primitive fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No `(uN)` argument: two u64 fields make 128 bits, past every C scalar.
    const found = try analyzeContent(a,
        \\const Wide = packed struct { a: u64, b: u64 };
        \\const Host = extern struct { w: Wide };
    );
    try testing.expectEqual(@as(usize, 1), only(found, .alignment));
    // A field whose type is not a primitive width leaves the backing unknown,
    // and an unknown backing is never flagged.
    const unknown = try analyzeContent(a,
        \\const Opaque = packed struct { a: SomeOther };
        \\const Host2 = extern struct { w: Opaque };
    );
    try testing.expectEqual(@as(usize, 0), only(unknown, .alignment));
}

test "intBits parses primitive integer spellings only" {
    try testing.expectEqual(@as(?u16, 128), intBits("u128"));
    try testing.expectEqual(@as(?u16, 7), intBits("i7"));
    try testing.expectEqual(@as(?u16, null), intBits("usize"));
    try testing.expectEqual(@as(?u16, null), intBits("bool"));
    try testing.expectEqual(@as(?u16, null), intBits("u"));
}

test "isBareIdentifier rejects anything a per-file lookup cannot resolve" {
    try testing.expect(isBareIdentifier("EIdent"));
    try testing.expect(isBareIdentifier("_e2"));
    try testing.expect(!isBareIdentifier("mod.EIdent"));
    try testing.expect(!isBareIdentifier("[16]u8"));
    try testing.expect(!isBareIdentifier("*EIdent"));
    try testing.expect(!isBareIdentifier(""));
}

test "analyzeContent finds a layout struct nested inside a namespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Wrapping the declaration in a namespace must not dodge the inventory.
    const found = try analyzeContent(arena.allocator(),
        \\const ns = struct {
        \\    const Inner = extern struct { a: u32 };
        \\};
    );
    try testing.expectEqual(@as(usize, 1), only(found, .inventory));
}

test "analyzeContent ignores extern and packed unions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(),
        \\const U = extern union { a: u32, b: f32 };
    );
    try testing.expectEqual(@as(usize, 0), found.len);
}

test "analyzeContent returns nothing for a file that does not parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(), "const A = extern struct {");
    try testing.expectEqual(@as(usize, 0), found.len);
}

test "hasLayoutAssertion does not credit a different type's assertion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try analyzeContent(arena.allocator(),
        \\const A = extern struct { a: u32 };
        \\const B = extern struct { b: u32 };
        \\comptime { assert(@sizeOf(A) == 4); }
    );
    // A is pinned, B is not — one finding, and it names B.
    try testing.expectEqual(@as(usize, 1), only(found, .inventory));
    try testing.expect(std.mem.indexOf(u8, found[0].message, "struct B") != null);
}
