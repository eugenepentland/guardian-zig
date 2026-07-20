//! Content-derived violation identity (baseline v3 keys).
//!
//! A baselined violation used to be keyed by its *rendered* text, so rewording a
//! diagnostic re-keyed every consumer's baseline and reddened their gate on
//! completely unchanged code (FEEDBACK 2026-07-20: a message batch took eda to
//! 3/67 red and zig_genetic_cascades to 1/67 red with zero source edits). That
//! trains agents to reflexively accept baselines — the exact habit Guardian
//! exists to prevent.
//!
//! A key here is `<check>|<file>|<discriminator>` — or `<check>|<discriminator>`
//! when the discriminator already stands alone — resolved in three tiers:
//!
//!   1. `Violation.identity` — the check names the thing it flagged (a symbol,
//!      a prong set, a literal, an alias). Fully rendering-independent: the
//!      message may be rewritten word for word and the key does not move.
//!   2. `Violation.ratchet_key` — the `file|symbol` identity the threshold
//!      checks already emit for `ratchet.zig`. Reused verbatim, so the ratchet
//!      (v2) and baseline (v3) paths agree on what a subject *is*.
//!   3. `skeleton(message)` — the fallback for the ~57 checks that still report
//!      prose. See `skeleton` for exactly what it absorbs and what it doesn't.
//!
//! Source line numbers are deliberately absent from every tier: a violation that
//! only shifted lines must stay `matched` (the property `positionKey` gave v1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const reporter = @import("reporter.zig");

/// Separates the `<check>|<file>|<discriminator>` fields of a key. Keys stay
/// human-readable on purpose: they are what `.guardian/baselines/*.txt` stores,
/// so a reviewer reading a baseline diff sees subjects, not hashes.
pub const separator = "|";

/// What `fileOf` reports for a violation line that names no file (the spec
/// check's unverified behaviors, cross-file findings), so the migration guard
/// can still count those violations as a group.
pub const no_file = "-";

/// Normalizes a message into a rendering-stable discriminator by collapsing
/// every standalone digit run to `#`.
///
/// This absorbs the churn that dominates diagnostic edits — counts ("appears in
/// 2 files"), caps ("(cap 200)"), measured metrics ("is 246 lines"), and
/// embedded line numbers — so retuning a threshold or enriching a count never
/// re-keys a baseline.
///
/// A digit run glued to the right of a letter or `_` is left alone, so type and
/// encoding names keep their identity: `u8`, `f32`, `utf8` and `sha256` are not
/// all flattened to the same skeleton.
///
/// **Tradeoff, deliberately documented:** this is still derived from the message
/// text, so rewriting the *prose* around the subject ("X is banned here" → "avoid
/// X") does re-key a tier-3 check. It is strictly weaker than tier 1, and the
/// remedy is to give the check a `Violation.identity` — which is a one-field
/// change — *before* rewording its message. Tier 3 exists so the ~57 prose
/// checks gain line-shift and number immunity for free, not as a substitute for
/// naming the subject.
pub fn skeleton(arena: Allocator, message: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < message.len) {
        if (!isDigit(message[i])) {
            try out.append(arena, message[i]);
            i += 1;
            continue;
        }
        // Decide once per run, at its first digit: a run that continues an
        // identifier is copied whole (so `f32` stays `f32`, not `f3#`).
        const glued = gluedToWord(message, i);
        const start = i;
        while (i < message.len and isDigit(message[i])) i += 1;
        if (glued) try out.appendSlice(arena, message[start..i]) else try out.append(arena, '#');
    }
    return out.toOwnedSlice(arena);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isWordByte(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// True when the digit at `i` continues an identifier (`u8`, `utf8`, `f32`)
/// rather than starting a standalone number. Only the byte immediately left of
/// the digit run matters, so `cap 200` (space) collapses while `sha256` does not.
fn gluedToWord(message: []const u8, i: usize) bool {
    return i > 0 and isWordByte(message[i - 1]);
}

/// The stable key for a structured violation record: `identity`, else
/// `ratchet_key`, else the skeletonized message under the record's file.
///
/// Tiers 1 and 2 are already whole identities (a check that sets `identity` for a
/// cross-file finding owns the entire discriminator), so they are used as the
/// discriminator directly rather than being re-qualified by file.
pub fn fromRecord(arena: Allocator, check: []const u8, v: reporter.Violation) Allocator.Error![]const u8 {
    if (v.identity) |id| return join(arena, check, null, id);
    if (v.ratchet_key) |rk| return join(arena, check, null, rk);
    return join(arena, check, v.file, try skeleton(arena, v.message));
}

/// The stable key for a scraped violation line (`<file>:<line>: <msg>`,
/// `<file>: <msg>`, or a bare message) produced by a check that reports prose
/// rather than records. Parses the location back off, then keys the remainder
/// exactly as `fromRecord`'s tier-3 fallback does, so a check that later migrates
/// to records without adding an `identity` keeps the same key.
pub fn fromLine(arena: Allocator, check: []const u8, line: []const u8) Allocator.Error![]const u8 {
    const split = splitLocation(line);
    return join(arena, check, split.file, try skeleton(arena, split.message));
}

/// The file a rendered violation line names, or `no_file` when it names none.
/// The v1→v3 baseline migration counts violations per file with this to prove a
/// migration adopts no violation the old baseline didn't already cover.
pub fn fileOf(line: []const u8) []const u8 {
    return splitLocation(line).file orelse no_file;
}

/// A violation line's optional file prefix and its remaining message.
const Located = struct { file: ?[]const u8, message: []const u8 };

/// Splits `<file>:<line>: <msg>` / `<file>: <msg>` off a rendered violation
/// line. The prefix is only taken as a file when it *looks* like one
/// (`looksLikePath`), so the spec check's `unverified: Auth - ...` keeps its
/// whole text as the message instead of gaining a bogus `unverified` file.
///
/// Only the **first** colon-delimited segment is ever considered. A rendered
/// violation puts its file at the very front or has none at all, so scanning
/// deeper can only find a path *inside the message* and mistake it for the
/// location — which is exactly what made `repeated-switch-on-enum` (whose
/// message lists `file:line` pairs) bucket ten unchanged violations into ten
/// bogus "files" and wrongly block eda's migration.
fn splitLocation(line: []const u8) Located {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .{ .file = null, .message = line };
    const candidate = line[0..colon];
    if (!looksLikePath(candidate)) return .{ .file = null, .message = line };
    return .{ .file = candidate, .message = afterLocation(line, colon) };
}

/// The message body following a file prefix that ends at `colon`, skipping an
/// optional `:<digits>` line group and one separating space.
fn afterLocation(line: []const u8, colon: usize) []const u8 {
    var j = colon + 1;
    while (j < line.len and isDigit(line[j])) j += 1;
    if (j > colon + 1 and j < line.len and line[j] == ':') j += 1;
    if (j < line.len and line[j] == ' ') j += 1;
    return line[j..];
}

/// True when `text` reads as a source path — it contains a `/` or ends in
/// `.zig`. Keeps `splitLocation` from mistaking a message's own colon-prefixed
/// label for a file.
fn looksLikePath(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.indexOfScalar(u8, text, '/') != null) return true;
    return std.mem.endsWith(u8, text, ".zig");
}

/// Assembles `<check>|<file>|<discriminator>`, or `<check>|<discriminator>`
/// when there is no file to qualify by — which is the tier-1/tier-2 case, where
/// the identity is already a whole discriminator (and typically embeds its own
/// file). Omitting an empty field keeps committed baselines readable, since
/// these keys are exactly what a reviewer sees in a `.guardian/` diff.
fn join(arena: Allocator, check: []const u8, file: ?[]const u8, discriminator: []const u8) Allocator.Error![]const u8 {
    const f = file orelse
        return std.fmt.allocPrint(arena, "{s}" ++ separator ++ "{s}", .{ check, discriminator });
    return std.fmt.allocPrint(arena, "{s}" ++ separator ++ "{s}" ++ separator ++ "{s}", .{
        check,
        f,
        discriminator,
    });
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Violation Identity - Collapses standalone digit runs while keeping digits glued to identifiers

test "skeleton absorbs counts and caps but preserves type names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Counts, caps and measured metrics all collapse, so retuning a threshold or
    // enriching a count never re-keys a baselined violation.
    try testing.expectEqualStrings(
        "fn foo is # lines (cap #)",
        try skeleton(a, "fn foo is 246 lines (cap 200)"),
    );
    // Digits glued to a word continue an identifier and survive intact, so u8 /
    // f32 / utf8 stay distinguishable from each other.
    try testing.expectEqualStrings(
        "@intFromFloat on f32 needs a u8 range check",
        try skeleton(a, "@intFromFloat on f32 needs a u8 range check"),
    );
    // A digit-free message is returned unchanged.
    try testing.expectEqualStrings("std.fs.cwd reference", try skeleton(a, "std.fs.cwd reference"));
}

// spec: Violation Identity - Keys a record by its explicit identity then ratchet key then message skeleton

test "fromRecord resolves identity, ratchet key, and skeleton tiers in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Tier 1: an explicit identity owns the whole discriminator, so the message
    // is not consulted at all — this is what makes rewording free.
    const tier1: reporter.Violation = .{
        .check = "repeated-switch-on-enum",
        .message = "switch on prongs (float,integer) appears in 2 files: src/a.zig:1, src/b.zig:9",
        .identity = "float,integer",
    };
    try testing.expectEqualStrings(
        "repeated-switch-on-enum|float,integer",
        try fromRecord(a, "repeated-switch-on-enum", tier1),
    );

    // Tier 2: the threshold checks' existing file|symbol ratchet key is reused
    // verbatim, so baseline v3 and ratchet v2 agree on subject identity.
    const tier2: reporter.Violation = .{
        .check = "function-length",
        .file = "src/x.zig",
        .line = 5,
        .message = "fn foo is 246 lines (cap 200)",
        .ratchet_key = "src/x.zig|foo",
    };
    try testing.expectEqualStrings(
        "function-length|src/x.zig|foo",
        try fromRecord(a, "function-length", tier2),
    );

    // Tier 3: no identity and no ratchet key falls back to file + skeleton.
    const tier3: reporter.Violation = .{
        .check = "ban-fs",
        .file = "src/y.zig",
        .line = 8,
        .message = "std.fs.cwd reference outside allowed paths",
    };
    try testing.expectEqualStrings(
        "ban-fs|src/y.zig|std.fs.cwd reference outside allowed paths",
        try fromRecord(a, "ban-fs", tier3),
    );
}

// spec: Violation Identity - Ignores a path inside a message when locating the violation's file

test "splitLocation only treats a leading segment as the file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // repeated-switch-on-enum's real shape: no file prefix, but the message
    // lists `file:line` pairs. Scanning past the first colon used to latch onto
    // `src/review.zig` and invent a per-violation "file", which bucketed ten
    // unchanged violations as ten newly-gained files and blocked eda's
    // migration. The location is a prefix or nothing.
    const cross_file =
        "switch on prongs (@\"error\",info,warning) appears in 2 files: " ++
        "src/review.zig:368, src/serve/schematic_page.zig:236";
    try testing.expectEqualStrings(no_file, fileOf(cross_file));

    // The pre-rewording v1 rendering of that same violation (no `:line`
    // suffixes) must land in the same bucket, which is what makes the migration
    // guard see "nothing gained" instead of ten new files.
    const cross_file_v1 =
        "switch on prongs (@\"error\",info,warning) appears in 2 files: " ++
        "src/review.zig, src/serve/schematic_page.zig";
    try testing.expectEqualStrings(fileOf(cross_file_v1), fileOf(cross_file));

    // A genuine location prefix is still recognized.
    try testing.expectEqualStrings("src/x.zig", fileOf("src/x.zig:5: fn foo is long"));
    // And the cross-file key keeps the whole line as its discriminator, with the
    // file *count* skeletonized — so the same prong set spreading to a third
    // file would not re-key either.
    try testing.expectEqualStrings(
        "repeated-switch-on-enum|switch on prongs (@\"error\",info,warning) appears in # files: " ++
            "src/review.zig, src/serve/schematic_page.zig",
        try fromLine(a, "repeated-switch-on-enum", cross_file_v1),
    );
}

// spec: Violation Identity - Reports the file a rendered violation line names

test "fileOf extracts the path a violation line points at" {
    // With and without a line group, the file is the same — this is what the
    // v1 baseline migration counts violations per file with.
    try testing.expectEqualStrings("src/x.zig", fileOf("src/x.zig:5: fn foo is 246 lines (cap 200)"));
    try testing.expectEqualStrings("src/x.zig", fileOf("src/x.zig: 1234 code lines (limit: 1000)"));
    // A line naming no path reports the no_file placeholder rather than
    // inventing a file out of a message label.
    try testing.expectEqualStrings(no_file, fileOf("unverified: Auth - Validates tokens"));
}

// spec: Violation Identity - Derives the same fallback key from a scraped line as from a record

test "fromLine parses locations off and agrees with the record fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `<file>:<line>: <msg>` — the line number is dropped, so a pure line shift
    // keeps the key identical (the property v1's positionKey provided).
    const at_8 = try fromLine(a, "ban-fs", "src/y.zig:8: std.fs.cwd reference outside allowed paths");
    const at_99 = try fromLine(a, "ban-fs", "src/y.zig:99: std.fs.cwd reference outside allowed paths");
    try testing.expectEqualStrings(at_8, at_99);
    // ...and it matches what the same violation would key as if the check were
    // migrated to a structured record with no explicit identity.
    const as_record: reporter.Violation = .{
        .check = "ban-fs",
        .file = "src/y.zig",
        .line = 8,
        .message = "std.fs.cwd reference outside allowed paths",
    };
    try testing.expectEqualStrings(at_8, try fromRecord(a, "ban-fs", as_record));

    // `<file>: <msg>` with no line group.
    try testing.expectEqualStrings(
        "file-size|src/x.zig|# code lines (limit: #)",
        try fromLine(a, "file-size", "src/x.zig: 1234 code lines (limit: 1000)"),
    );

    // A bare message whose prefix is a label, not a path, keeps its whole text:
    // `unverified` must not be mistaken for a file.
    try testing.expectEqualStrings(
        "spec|unverified: Auth - Validates tokens",
        try fromLine(a, "spec", "unverified: Auth - Validates tokens"),
    );
}
