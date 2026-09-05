//! deprecated-alias — token-level ban on pre-0.15 / soon-removed std spellings.
//!
//! Zig 0.15 renamed a batch of std containers and I/O idioms and left the old
//! names behind as `/// Deprecated` aliases (std.zig: `pub const
//! ArrayListUnmanaged = ArrayList;`). The alias compiles today and is a
//! no-op cost, but it is a guaranteed tree-wide breaking diff the day 0.16
//! drops it — and an AI agent trained on 0.13/0.14 corpora reaches for the old
//! spelling by reflex. This check freezes the modern spelling in place while
//! the rename is still `sed`-grade.
//!
//! Detection is purely lexical (a chain of identifier tokens via the shared
//! banned-symbol scanner), so string literals, comments, and doc-comments that
//! merely mention a banned name are never flagged. The table below documents
//! the 0.15/0.16 rationale for every entry.
//!
//! WHAT THIS IS WORTH, honestly: std churn is COMPILE-TIME detectable. The
//! compiler rejects a removed or renamed API, so this table is not a safety net
//! for the common case. Its value is narrow and worth stating plainly — it
//! catches a spelling that is deprecated but STILL PRESENT, in the window before
//! removal, and it stops an agent trained on 0.13/0.14 corpora from writing
//! old-std idioms that happen to still compile. The general lesson it argues for
//! is toolchain pinning plus a CI version matrix, not a bigger ban list.
//!
//! The churn is a PATTERN across releases, not one event: 0.12 renamed
//! `std.os` → `std.posix`, 0.13 reworked `std.Progress`, 0.14 changed
//! `std.mem.split`/`tokenize`, 0.15 shipped "Writergate" ("All existing std.io
//! readers and writers are deprecated in favor of the newly provided
//! `std.Io.Reader` and `std.Io.Writer`... These changes are extremely breaking.
//! I am sorry for that.") alongside "ArrayList: make unmanaged the default"
//! ("Warning: these will both eventually be removed entirely"), and 0.16
//! continues into the new `std.Io` interface (ghostty-org/ghostty#12228).
//!
//! EVERY ENTRY IS VERIFIED AGAINST THE PINNED TOOLCHAIN's std source
//! (0.17.0-dev.1683+5ceec001b), because a rename table is exactly the kind of
//! thing that rots: a spelling can be removed outright (so nothing can reference
//! it and the rule is dead weight), or renamed AGAIN, so that yesterday's
//! recommended replacement is today's deprecation. Both happened here — see the
//! per-entry comments. Candidates checked and DROPPED, with the reason:
//!   * `std.io.GenericReader` / `GenericWriter` / `SeekableStream` / `BitReader`
//!     / `BitWriter` — `std.io` does not exist in the pinned std at all (no
//!     `pub const io` in std.zig, no `io.zig`). Nothing can name them.
//!   * `std.fifo.LinearFifo` — `LinearFifo` appears nowhere in the pinned std.
//!   * `std.RingBuffer`, `std.BoundedArray` — no such decl, no backing file.
//!   * `std.os` → `std.posix` — `std.os` is NOT deprecated. It is the live home
//!     of `std.os.linux` / `.windows` / `.wasi`, so banning it would flag
//!     correct current code. The 0.12 rename it comes from is long complete.
//! A rule for a spelling the compiler already rejects buys nothing and has to be
//! maintained, so it is worse than no rule.

const std = @import("std");
const helper = @import("banned_symbol_helper.zig");
const registry = @import("../cli/types.zig");
const config = @import("../config.zig");

// The versioned alias table. `require_call = true` matches only the
// `(`-application form (a generic instantiation / call); the default matches a
// bare or `std.`-qualified reference anywhere.
const rules = [_]helper.Rule{
    // `std.ArrayListUnmanaged` is a deprecated alias of `std.ArrayList` in 0.15
    // — std.zig literally reads `pub const ArrayListUnmanaged = ArrayList;`.
    // Identical type today; a whole-tree rename when 0.16 removes the alias.
    .{
        .chain = &.{"ArrayListUnmanaged"},
        .display = "std.ArrayListUnmanaged",
        .replacement = "std.ArrayList (unmanaged by default since 0.15)",
    },
    // `std.ArrayListAlignedUnmanaged` — same deprecation. The replacement is
    // NOT `std.ArrayListAligned`: verified against the pinned 0.17.0-dev.1683
    // std, that spelling is itself deprecated in favour of `array_list.Aligned`,
    // so the old advice moved a caller from one deprecated alias onto another.
    .{
        .chain = &.{"ArrayListAlignedUnmanaged"},
        .display = "std.ArrayListAlignedUnmanaged",
        .replacement = "std.array_list.Aligned",
    },
    // `std.ArrayListAligned` — the pinned std marks it `/// Deprecated; use
    // array_list.Aligned.`
    .{
        .chain = &.{"ArrayListAligned"},
        .display = "std.ArrayListAligned",
        .replacement = "std.array_list.Aligned",
    },
    // `std.array_list.Managed` is the deprecated *managed* ArrayList
    // (array_list.zig: `/// Deprecated. pub fn Managed`). Prefer the unmanaged
    // `std.ArrayList`, which stores no allocator.
    .{
        .chain = &.{ "std", "array_list", "Managed" },
        .display = "std.array_list.Managed",
        .replacement = "std.ArrayList with an allocator-per-call",
    },
    // `std.array_list.AlignedManaged` — the aligned sibling of the above, and
    // `/// Deprecated.` on the same terms.
    .{
        .chain = &.{ "std", "array_list", "AlignedManaged" },
        .display = "std.array_list.AlignedManaged",
        .replacement = "std.array_list.Aligned with an allocator-per-call",
    },
    // The array-hash-map aliases the pinned std marks `/// Deprecated`, each in
    // favour of its `array_hash_map` original.
    // These are the spellings the managed-map entries below USED to redirect
    // to, which is how a rename table goes stale: yesterday's replacement is
    // today's violation.
    .{
        .chain = &.{"StringArrayHashMapUnmanaged"},
        .display = "std.StringArrayHashMapUnmanaged",
        .replacement = "std.array_hash_map.String",
    },
    .{
        .chain = &.{"AutoArrayHashMapUnmanaged"},
        .display = "std.AutoArrayHashMapUnmanaged",
        .replacement = "std.array_hash_map.Auto",
    },
    .{
        .chain = &.{"ArrayHashMapUnmanaged"},
        .display = "std.ArrayHashMapUnmanaged",
        .replacement = "std.array_hash_map.Custom",
    },
    // `std.builtin` is `/// Deprecated; use lang.` with the only explicit
    // removal deadline in the file: "To be removed after Zig 0.17.0"
    // It is `pub const builtin = lang;`, so every member —
    // `TestFn`, `OptimizeMode`, `Type` — is reachable unchanged under
    // `std.lang`. The bare `builtin` from `@import("builtin")` is a DIFFERENT
    // module and is not deprecated; the `std.` prefix in the chain is what
    // keeps this rule off it.
    .{
        .chain = &.{ "std", "builtin" },
        .display = "std.builtin",
        .replacement = "std.lang (std.builtin is removed after 0.17.0)",
    },
    // Managed hashmap constructors. NOT deprecated in 0.15 — they still exist
    // and work — but discouraged: std has moved to the unmanaged maps, which
    // keep the allocator on the owning struct instead of inside every map. They
    // are included here (rather than left unenforced) because the generic
    // `[[allow]]` path machinery is a clean per-path escape hatch for a consumer
    // that keeps managed maps on purpose. Only the `(`-application form is a
    // type/construction, so `require_call`.
    .{
        .chain = &.{ "std", "StringHashMap" },
        .display = "std.StringHashMap (managed)",
        .require_call = true,
        .replacement = "std.StringHashMapUnmanaged with an allocator-per-call",
    },
    .{
        .chain = &.{ "std", "AutoHashMap" },
        .display = "std.AutoHashMap (managed)",
        .require_call = true,
        .replacement = "std.AutoHashMapUnmanaged with an allocator-per-call",
    },
    // The two managed ARRAY hash maps are a step further along than their
    // hash_map cousins above: verified against the pinned std, its root has no
    // `StringArrayHashMap` / `AutoArrayHashMap` decl at all — they are gone, not
    // deprecated. The entries stay because the diagnostic names the current
    // spelling where the compiler would only say "no member named", but the
    // replacement now points at `array_hash_map`, since the `*Unmanaged` names
    // they used to redirect to are themselves deprecated.
    .{
        .chain = &.{ "std", "StringArrayHashMap" },
        .display = "std.StringArrayHashMap",
        .require_call = true,
        .replacement = "std.array_hash_map.String with an allocator-per-call",
    },
    .{
        .chain = &.{ "std", "AutoArrayHashMap" },
        .display = "std.AutoArrayHashMap",
        .require_call = true,
        .replacement = "std.array_hash_map.Auto with an allocator-per-call",
    },
    // `usingnamespace` was removed from the language outright in 0.15 (the
    // tokenizer now lexes it as a bare identifier). Overlaps usingnamespace-ban
    // by design: that check argues symbol-hiding, this one argues "the keyword
    // no longer exists in the grammar."
    .{
        .chain = &.{"usingnamespace"},
        .display = "usingnamespace",
        .replacement = "explicit re-exports (`pub const x = mod.x;`)",
    },
    // Pre-0.15 stdout/stderr writer idioms. 0.15's "Writergate" replaced
    // `std.io.getStdOut().writer()` with `std.fs.File.stdout()` plus a buffered
    // `std.io.Writer` and an explicit `flush()`. `(`-application form.
    .{
        .chain = &.{"getStdOut"},
        .display = "getStdOut",
        .require_call = true,
        .replacement = "std.fs.File.stdout() + a buffered writer with an explicit flush()",
    },
    .{
        .chain = &.{"getStdErr"},
        .display = "getStdErr",
        .require_call = true,
        .replacement = "std.fs.File.stderr() + a buffered writer with an explicit flush()",
    },
};

const opts: helper.ScanOpts = .{
    .rules = &rules,
    // A deprecated spelling breaks on 0.16 regardless of where it sits, so —
    // unlike the hidden-dependency bans — this check does NOT wave through
    // `test {…}` blocks or `pub fn main`. The only escape hatch is a `[[allow]]`
    // path glob, merged in from guardian.toml by helper.scan.
    .allow_in_tests = false,
    .allow_in_main = false,
    // Each rule also carries its own per-hit `replacement`, which is what the
    // JSONL sink and the reader actually act on; this line is the one shared
    // summary printed under the list.
    .fix_hint = "std.ArrayListUnmanaged -> std.ArrayList and std.ArrayListAligned* -> std.array_list.Aligned; " ++
        "std.*ArrayHashMapUnmanaged -> std.array_hash_map.{String,Auto,Custom}; managed std.*HashMap(...) -> " ++
        "the *Unmanaged map with an allocator-per-call; std.builtin -> std.lang; drop usingnamespace for " ++
        "explicit re-exports; getStdOut/getStdErr -> std.fs.File.stdout()/stderr().",
};

/// Pure-function entry: scans `content` for deprecated std spellings and returns
/// the violation lines (allocator-owned). Empty slice = pass. Used by the unit
/// tests; the production walker goes through `run` into the shared helper.
pub fn analyzeContent(
    allocator: std.mem.Allocator,
    rel_path: []const u8,
    content: [:0]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    return helper.analyzeContent(allocator, rel_path, content, opts);
}

/// Concatenates the compiled std table with the project's own `[[deprecated]]`
/// entries. Returns `rules` unchanged when there are none, so the common
/// (no-config) path allocates nothing.
///
/// Project rules come SECOND so a consumer can never silently shadow a compiled
/// std rule: both fire, and the reader sees both spellings named.
fn mergeRules(
    allocator: std.mem.Allocator,
    extra: []const config.DeprecatedRule,
) std.mem.Allocator.Error![]const helper.Rule {
    if (extra.len == 0) return &rules;
    var list: std.ArrayList(helper.Rule) = .empty;
    try list.appendSlice(allocator, &rules);
    for (extra) |r| {
        try list.append(allocator, .{
            .chain = r.chain,
            // The dotted spelling the project wrote is what it wants to read
            // back in the violation, so `display` is its own chain rejoined.
            .display = try std.mem.join(allocator, ".", r.chain),
            .replacement = r.replacement,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Entry point for the deprecated-alias check.
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    var merged = opts;
    merged.rules = try mergeRules(ctx_param.allocator, ctx_param.cfg.deprecated_rules);
    return helper.scan(ctx_param, "deprecated-alias", merged);
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Deprecated Alias - Flags the std.ArrayListUnmanaged deprecated 0.15 alias

test "analyzeContent flags std.ArrayListUnmanaged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f() void {
        \\    var xs: std.ArrayListUnmanaged(u8) = .empty;
        \\    _ = &xs;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Deprecated Alias - Flags a managed hashmap construction such as std.StringHashMap

test "analyzeContent flags managed std.StringHashMap construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f(alloc: std.mem.Allocator) void {
        \\    var m = std.StringHashMap(u32).init(alloc);
        \\    _ = &m;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Deprecated Alias - Flags the usingnamespace keyword removed in 0.15

test "analyzeContent flags usingnamespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const foo = @import("foo.zig");
        \\pub usingnamespace foo;
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Deprecated Alias - Flags the pre-0.15 getStdOut and getStdErr writer idioms

test "analyzeContent flags getStdOut and getStdErr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn out() void {
        \\    const o = std.io.getStdOut();
        \\    const e = std.io.getStdErr();
        \\    _ = o;
        \\    _ = e;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 2), out.len);
}

// spec: Deprecated Alias - Names the modern replacement for each flagged alias

test "analyzeContent names the replacement for a flagged alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f() void {
        \\    var xs: std.ArrayListUnmanaged(u8) = .empty;
        \\    _ = &xs;
        \\}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    // The message points at the modern spelling, not just the banned one.
    try std.testing.expect(std.mem.indexOf(u8, out[0], "→ use std.ArrayList") != null);
}

// spec: Deprecated Alias - Allows the unmanaged and 0.15 replacement spellings

test "analyzeContent allows the modern replacement spellings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\const A = std.ArrayList(u8);
        \\const M = std.StringHashMapUnmanaged(u32);
        \\const N = std.AutoHashMapUnmanaged(u32, u32);
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Deprecated Alias - Flags the array-list and array-hash-map aliases the pinned std marks deprecated

test "analyzeContent flags the aliases the pinned std still carries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each of these is `/// Deprecated` in 0.17.0-dev.1683's std source, which
    // is the only reason it is in the table: a removed spelling is a compile
    // error and needs no gate.
    const content =
        \\const A = std.ArrayListAligned(u8, null);
        \\const B = std.array_list.AlignedManaged(u8, null);
        \\const C = std.StringArrayHashMapUnmanaged(u32);
        \\const D = std.AutoArrayHashMapUnmanaged(u32, u32);
        \\const E = std.ArrayHashMapUnmanaged(u32, u32, Ctx, true);
        \\const F = std.builtin.OptimizeMode;
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 6), out.len);
    // The replacement is the CURRENT spelling, not the one that was current when
    // the entry was written: `std.ArrayListAligned` is itself deprecated now.
    try std.testing.expect(std.mem.indexOf(u8, out[0], "→ use std.array_list.Aligned") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[5], "std.lang") != null);
}

// spec: Deprecated Alias - Ignores the bare builtin module that @import provides

test "analyzeContent leaves the imported builtin module alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `std.builtin` is deprecated; `@import("builtin")` is a different module
    // entirely and is not. The `std.` prefix in the chain is what separates them.
    const content =
        \\const builtin = @import("builtin");
        \\const mode = builtin.mode;
    ;
    try std.testing.expectEqual(@as(usize, 0), (try analyzeContent(a, "src/x.zig", content)).len);
}

// spec: Deprecated Alias - Merges project-declared deprecated spellings with the compiled table

test "mergeRules appends the project's own spellings after the compiled ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No config entries: the compiled table is handed back untouched, so the
    // zero-config path allocates nothing.
    try std.testing.expectEqual(rules.len, (try mergeRules(a, &.{})).len);

    const extra = [_]config.DeprecatedRule{.{
        .chain = &.{ "legacy", "Widget" },
        .replacement = "widget.Widget",
    }};
    var scoped = opts;
    scoped.rules = try mergeRules(a, &extra);
    try std.testing.expectEqual(rules.len + 1, scoped.rules.len);
    const content =
        \\const w = legacy.Widget;
    ;
    const out = try helper.analyzeContent(a, "src/x.zig", content, scoped);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    // The display is the project's own dotted spelling, rejoined from its chain.
    try std.testing.expect(std.mem.indexOf(u8, out[0], "legacy.Widget → use widget.Widget") != null);
}

test "analyzeContent ignores a banned spelling inside a string or comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\// std.ArrayListUnmanaged is deprecated
        \\const s = "std.ArrayListUnmanaged";
        \\fn f() void {}
    ;
    const out = try analyzeContent(a, "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "helper honors an allowed-path glob for deprecated-alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\fn f() void {
        \\    var xs: std.ArrayListUnmanaged(u8) = .empty;
        \\    _ = &xs;
        \\}
    ;
    // A file matching an [[allow]] glob is skipped wholesale — the same
    // mechanism helper.scan feeds from guardian.toml's per-check allow rules.
    var exempt = opts;
    exempt.allowed_paths = &.{"src/vendor/*"};
    const flagged = try helper.analyzeContent(a, "src/x.zig", content, exempt);
    const skipped = try helper.analyzeContent(a, "src/vendor/lib.zig", content, exempt);
    try std.testing.expectEqual(@as(usize, 1), flagged.len);
    try std.testing.expectEqual(@as(usize, 0), skipped.len);
}
