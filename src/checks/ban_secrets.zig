const std = @import("std");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");

const Allocator = std.mem.Allocator;
const detail = reporter.detail;
const lineOf = @import("../text.zig").lineOf;

// Precision-first hardcoded-credential detection. Naive "high-entropy string"
// scanners are >93% false positives, fatal for a hard-block gate. So this fires
// only on two tightly-constrained signals: (1) known vendor token FORMATS
// (exact prefix + length + charset) — scanned everywhere, tests included, since
// a real key committed "for a test" is still a leak; and (2) entropy-gated
// ASSIGNMENTS to a secret-named const/var — skipped in test blocks and under
// testing/ or fixtures/ paths where random-looking strings are legitimate.
// Publishable/test vendor keys (`sk_test_`/`pk_test_`/`pk_live_`) are NOT
// flagged: they ship in client code by design, so blocking them is noise.
//
// Default allowed_paths is empty — secrets are never OK anywhere. A project
// grants exemptions via [[allow]] in guardian.toml like every other check.
const allowed_paths = [_][]const u8{};

const min_assignment_len: usize = 16;
const entropy_threshold: f64 = 3.5;
const jwt_min_len: usize = 100;
const token_body_min: usize = 20;
const google_body_len: usize = 35;
const slack_body_min: usize = 10;
const aws_body_len: usize = 16;
const slack_prefix_len: usize = 5;
const preview_chars: usize = 4;

/// True if `c` is a base62 character (A-Z, a-z, 0-9).
fn isBase62(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// True if `c` is a base64url character (base62 plus `-` and `_`).
fn isBase64Url(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

/// Length of the leading run of `s` for which `pred` holds.
fn runLen(s: []const u8, comptime pred: fn (u8) bool) usize {
    var n: usize = 0;
    while (n < s.len and pred(s[n])) n += 1;
    return n;
}

/// AWS access key: `AKIA`/`ASIA` + exactly 16 uppercase-or-digit chars.
fn matchAws(s: []const u8) bool {
    const prefixes = [_][]const u8{ "AKIA", "ASIA" };
    for (prefixes) |p| {
        if (!std.mem.startsWith(u8, s, p)) continue;
        const body = s[p.len..];
        if (body.len < aws_body_len) return false;
        for (body[0..aws_body_len]) |c| {
            if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
        }
        return true;
    }
    return false;
}

/// GitHub PAT/OAuth/server tokens: `gh?_`/`github_pat_` + 20+ base62 chars.
fn matchGithub(s: []const u8) bool {
    const prefixes = [_][]const u8{ "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_" };
    for (prefixes) |p| {
        if (!std.mem.startsWith(u8, s, p)) continue;
        // github_pat_ bodies contain underscores; the gh?_ ones are pure base62.
        if (runLen(s[p.len..], isBase64Url) >= token_body_min) return true;
    }
    return false;
}

/// Slack tokens: `xox[baprs]-` followed by 10+ chars.
fn matchSlack(s: []const u8) bool {
    if (s.len < slack_prefix_len) return false;
    if (!std.mem.startsWith(u8, s, "xox")) return false;
    if (!isSlackKind(s[3])) return false;
    if (s[4] != '-') return false;
    return s.len - slack_prefix_len >= slack_body_min;
}

/// True for the Slack token-kind byte (bot/app/personal/refresh/server).
fn isSlackKind(c: u8) bool {
    return switch (c) {
        'b', 'a', 'p', 'r', 's' => true,
        else => false,
    };
}

/// Google API key: `AIza` + exactly 35 base64url chars.
fn matchGoogle(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "AIza")) return false;
    const body = s[4..];
    if (body.len < google_body_len) return false;
    return runLen(body, isBase64Url) >= google_body_len;
}

/// OpenAI secret key: `sk-` + 20+ base62 that mixes letters and digits.
fn matchOpenAi(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "sk-")) return false;
    const body = s[3..];
    const n = runLen(body, isBase62);
    if (n < token_body_min) return false;
    var has_alpha = false;
    var has_digit = false;
    for (body[0..n]) |c| {
        if (std.ascii.isAlphabetic(c)) has_alpha = true;
        if (std.ascii.isDigit(c)) has_digit = true;
    }
    return has_alpha and has_digit;
}

/// Stripe live secret/restricted keys: `sk_live_`/`rk_live_` + 20+ chars (publishable/test keys are skipped).
fn matchStripe(s: []const u8) bool {
    const prefixes = [_][]const u8{ "sk_live_", "rk_live_" };
    for (prefixes) |p| {
        if (!std.mem.startsWith(u8, s, p)) continue;
        return runLen(s[p.len..], isBase62) >= token_body_min;
    }
    return false;
}

/// JWT: `eyJ….eyJ….<sig>` over 100 chars — a real signed token, not a stub.
fn matchJwt(s: []const u8) bool {
    if (s.len <= jwt_min_len or !std.mem.startsWith(u8, s, "eyJ")) return false;
    const after_header = takeDotSegment(s, "eyJ") orelse return false;
    const after_payload = takeDotSegment(after_header, "eyJ") orelse return false;
    return runLen(after_payload, isBase64Url) > 0;
}

/// Remainder after a `<prefix><b64url>.` run, or null if `s` isn't one.
fn takeDotSegment(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    const n = runLen(s, isBase64Url);
    if (n >= s.len or s[n] != '.') return null;
    return s[n + 1 ..];
}

const FormatRule = struct {
    match: *const fn ([]const u8) bool,
    name: []const u8,
};

const format_rules = [_]FormatRule{
    .{ .match = matchAws, .name = "AWS access key" },
    .{ .match = matchGithub, .name = "GitHub token" },
    .{ .match = matchSlack, .name = "Slack token" },
    .{ .match = matchGoogle, .name = "Google API key" },
    .{ .match = matchOpenAi, .name = "OpenAI API key" },
    .{ .match = matchStripe, .name = "Stripe secret key" },
    .{ .match = matchJwt, .name = "JWT" },
};

/// Name of the first known-token format matching at any offset of `s`; null=none.
fn matchKnownFormat(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        for (format_rules) |r| {
            if (r.match(s[i..])) return r.name;
        }
    }
    return null;
}

const pem_headers = [_][]const u8{
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
    "-----BEGIN OPENSSH PRIVATE KEY-----",
    "-----BEGIN PGP PRIVATE KEY BLOCK-----",
    "-----BEGIN PRIVATE KEY-----",
};

/// True if `s` contains any recognized PEM private-key header line.
fn hasPemHeader(s: []const u8) bool {
    for (pem_headers) |h| {
        if (std.mem.indexOf(u8, s, h) != null) return true;
    }
    return false;
}

const secret_name_needles = [_][]const u8{
    "password", "passwd", "secret",      "token",
    "api_key",  "apikey", "private_key", "credential",
};

const placeholder_needles = [_][]const u8{
    "example", "placeholder", "dummy", "test", "fake", "xxx",
};

/// True if `s` is obviously a placeholder (placeholder word, template/angle marker, or whitespace).
fn looksLikePlaceholder(s: []const u8) bool {
    for (placeholder_needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(s, needle) != null) return true;
    }
    for (s) |c| {
        if (isPlaceholderMarker(c)) return true;
    }
    return std.mem.indexOf(u8, s, "${") != null;
}

/// True for a template/placeholder marker char (angle brackets, braces, space).
fn isPlaceholderMarker(c: u8) bool {
    return switch (c) {
        '<', '>', '{', '}', ' ' => true,
        else => false,
    };
}

/// True if `s` looks like an env-var NAME (all uppercase, digits, underscores).
fn looksLikeEnvVarName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

/// Shannon entropy of `s` in bits per character (0 for empty).
fn shannonEntropy(s: []const u8) f64 {
    if (s.len == 0) return 0;
    var counts = [_]u32{0} ** 256;
    for (s) |c| counts[c] += 1;
    const len_f: f64 = @floatFromInt(s.len);
    var bits: f64 = 0;
    for (counts) |c| {
        if (c == 0) continue;
        const p = @as(f64, @floatFromInt(c)) / len_f;
        bits -= p * std.math.log2(p);
    }
    return bits;
}

/// True if a secret-named literal is a real high-entropy secret (rejects short/placeholder/env-name/low-entropy).
fn isEntropySecret(value: []const u8) bool {
    if (value.len < min_assignment_len) return false;
    if (looksLikePlaceholder(value)) return false;
    if (looksLikeEnvVarName(value)) return false;
    return shannonEntropy(value) > entropy_threshold;
}

/// Case-insensitive: true if `name` contains a secret-bearing substring.
fn isSecretName(name: []const u8) bool {
    for (secret_name_needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(name, needle) != null) return true;
    }
    return false;
}

/// Redacts a secret to its first few chars + ellipsis (the message never echoes it).
fn redact(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const head = if (s.len >= preview_chars) s[0..preview_chars] else s;
    return std.fmt.allocPrint(allocator, "{s}\u{2026}", .{head});
}

/// Per-file scan state: brace/test tracking plus flags gating the entropy heuristic to `secret_name = "literal"`.
const ScanState = struct {
    depth: u32 = 0,
    in_test: bool = false,
    test_depth: u32 = 0,
    pending_test: bool = false,
    /// True from `const`/`var` until the next identifier (the decl name); gates
    /// arming so a secret-named symbol in an expression never arms the heuristic.
    expect_name: bool = false,
    /// On a `const`/`var` whose name is a secret name, awaiting its `=`.
    secret_name_seen: bool = false,
    /// True only right after the `=` so entropy fires only on a direct literal
    /// initializer, not `const secret_mod = @import("...")`.
    at_value: bool = false,
};

const Ctx = struct {
    allocator: Allocator,
    rel_path: []const u8,
    violations: *std.ArrayListUnmanaged([]const u8),
    /// True for paths under testing/ or fixtures/ — entropy heuristic disabled,
    /// known-format + PEM still enforced.
    fixture_path: bool,
};

/// Pure-function entry: scans `content`, returns violation lines (empty = pass). Used by tests / single-check runs.
pub fn analyzeContent(
    allocator: Allocator,
    rel_path: []const u8,
    content: []const u8,
) Allocator.Error![]const []const u8 {
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    for (allowed_paths) |pat| {
        if (walk.matchGlob(rel_path, pat)) return violations.toOwnedSlice(allocator);
    }
    var ctx: Ctx = .{
        .allocator = allocator,
        .rel_path = rel_path,
        .violations = &violations,
        .fixture_path = isFixturePath(rel_path),
    };
    const z = try allocator.dupeZ(u8, content);
    var tree = try std.zig.Ast.parse(allocator, z, .zig);
    try scanTree(&ctx, &tree);
    return violations.toOwnedSlice(allocator);
}

/// True under a testing/ or fixtures/ path, where random strings are legitimate (entropy heuristic disabled).
fn isFixturePath(rel_path: []const u8) bool {
    return std.mem.indexOf(u8, rel_path, "testing/") != null or
        std.mem.indexOf(u8, rel_path, "fixtures/") != null;
}

/// Scans a file's pre-parsed token stream; `tokenSlice` is read only for tags whose text this check needs.
fn scanTree(ctx: *Ctx, tree: *const std.zig.Ast) Allocator.Error!void {
    var st: ScanState = .{};
    const tags = tree.tokens.items(.tag);
    const starts = tree.tokens.items(.start);
    for (tags, 0..) |tag, i| {
        if (tag == .eof) break;
        const start: usize = starts[i];
        const end = if (needsText(tag)) start + tree.tokenSlice(@intCast(i)).len else start;
        try stepToken(ctx, &st, tree.source, .{ .tag = tag, .loc = .{ .start = start, .end = end } });
    }
}

/// True for token tags whose source text this check reads.
fn needsText(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .identifier, .string_literal, .multiline_string_literal_line => true,
        else => false,
    };
}

fn stepToken(ctx: *Ctx, st: *ScanState, z: []const u8, t: std.zig.Token) Allocator.Error!void {
    switch (t.tag) {
        .keyword_test => st.pending_test = true,
        .l_brace => openBrace(st),
        .r_brace => closeBrace(st),
        .keyword_const, .keyword_var => {
            st.expect_name = true;
            st.secret_name_seen = false;
            st.at_value = false;
        },
        .identifier => armSecretName(st, z[t.loc.start..t.loc.end]),
        .equal => st.at_value = st.secret_name_seen,
        .string_literal => try onStringLiteral(ctx, st, z, t),
        .multiline_string_literal_line => try onMultilineLine(ctx, z, t),
        .semicolon => resetStatement(st),
        else => st.at_value = false,
    }
}

fn openBrace(st: *ScanState) void {
    st.depth += 1;
    if (!st.pending_test) return;
    st.in_test = true;
    st.test_depth = st.depth;
    st.pending_test = false;
}

fn closeBrace(st: *ScanState) void {
    if (st.depth > 0) st.depth -= 1;
    if (st.in_test and st.depth < st.test_depth) st.in_test = false;
}

/// Only the first identifier after `const`/`var` can arm the heuristic (not a symbol used in an expression).
fn armSecretName(st: *ScanState, name: []const u8) void {
    st.at_value = false;
    if (!st.expect_name) return;
    st.expect_name = false;
    st.secret_name_seen = isSecretName(name);
}

fn resetStatement(st: *ScanState) void {
    st.expect_name = false;
    st.secret_name_seen = false;
    st.at_value = false;
}

/// Handles a `.string_literal`: known formats always; entropy only for a `secret_name = "value"` initializer.
fn onStringLiteral(ctx: *Ctx, st: *ScanState, z: []const u8, t: std.zig.Token) Allocator.Error!void {
    const raw = z[t.loc.start..t.loc.end];
    const inner = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;

    if (matchKnownFormat(inner)) |name| {
        try record(ctx, z, t.loc.start, name, inner);
    } else if (shouldEntropyCheck(ctx, st) and isEntropySecret(inner)) {
        try record(ctx, z, t.loc.start, "secret assignment", inner);
    }
    resetStatement(st);
}

/// Entropy heuristic applies only to a direct secret-named initializer outside tests and fixture paths.
fn shouldEntropyCheck(ctx: *const Ctx, st: *const ScanState) bool {
    if (!st.at_value) return false;
    if (st.in_test) return false;
    return !ctx.fixture_path;
}

/// Handles one `\\` multiline line: PEM headers and embedded known-format tokens (a heredoc key is still a leak).
fn onMultilineLine(ctx: *Ctx, z: []const u8, t: std.zig.Token) Allocator.Error!void {
    const raw = z[t.loc.start..t.loc.end];
    const inner = if (std.mem.startsWith(u8, raw, "\\\\")) raw[2..] else raw;
    if (hasPemHeader(inner)) {
        try record(ctx, z, t.loc.start, "private key (PEM)", inner);
    } else if (matchKnownFormat(inner)) |name| {
        try record(ctx, z, t.loc.start, name, inner);
    }
}

fn record(ctx: *Ctx, z: []const u8, byte: usize, rule: []const u8, secret: []const u8) Allocator.Error!void {
    const line = lineOf(z, byte);
    const preview = try redact(ctx.allocator, secret);
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}:{d}: hardcoded {s} (starts {s})",
        .{ ctx.rel_path, line, rule, preview },
    );
    try ctx.violations.append(ctx.allocator, msg);
}

const FileScanCtx = struct {
    allocator: Allocator,
    violations: *std.ArrayListUnmanaged([]const u8),
    extra_allowed: []const []const u8 = &.{},
};

/// True if `rel_path` matches a compiled default (none) or a configured [[allow]] path for this check.
fn isAllowed(rel_path: []const u8, extra: []const []const u8) bool {
    for (allowed_paths) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    for (extra) |pat| if (walk.matchGlob(rel_path, pat)) return true;
    return false;
}

fn fileVisit(raw_ctx: *anyopaque, entry: walk.FileEntry) anyerror!void {
    const ctx: *FileScanCtx = @ptrCast(@alignCast(raw_ctx));
    if (isAllowed(entry.rel_path, ctx.extra_allowed)) return;
    var local: Ctx = .{
        .allocator = ctx.allocator,
        .rel_path = entry.rel_path,
        .violations = ctx.violations,
        .fixture_path = isFixturePath(entry.rel_path),
    };
    // Reuse the shared parse when the index provides it; parse standalone only
    // for a single-check run with no shared index.
    if (entry.tree) |t| {
        try scanTree(&local, t);
    } else {
        var tree = try std.zig.Ast.parse(ctx.allocator, entry.content, .zig);
        try scanTree(&local, &tree);
    }
}

/// Entry point for the ban-secrets check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var violations: std.ArrayListUnmanaged([]const u8) = .empty;
    var fs_ctx: FileScanCtx = .{
        .allocator = allocator,
        .violations = &violations,
        .extra_allowed = ctx.cfg.extraAllowed("ban-secrets"),
    };
    try ast_index.runSrc(ctx.source_index, allocator, ctx.project_dir, .{ .ctx = &fs_ctx, .visit = fileVisit });

    if (violations.items.len == 0) {
        reporter.ok("ban-secrets: no hardcoded credentials", .{});
        return;
    }
    reporter.fail("ban-secrets FAILED ({d} occurrence(s))", .{violations.items.len});
    for (violations.items) |v| detail("  {s}\n", .{v});
    detail("  fix: remove the credential; load it from an injected secret/env at runtime.\n", .{});
    return error.CheckFailed;
}

//
// Known-format fixtures are built by `++` concatenation so the full pattern
// never appears as one contiguous literal in THIS file (the self-hosted run
// would otherwise flag ban-secrets' own source); at runtime `content`
// reconstitutes the secret for the parser under test.

// spec: Ban Secrets - Flags known-format vendor tokens like AWS and GitHub keys
// spec: Ban Secrets - Flags PEM private-key headers even inside test and fixture paths
// spec: Ban Secrets - Flags high-entropy secret-named assignments outside tests
// spec: Ban Secrets - Ignores placeholder and env-var-name secret assignments
// spec: Ban Secrets - Ignores publishable and test vendor keys
// spec: Ban Secrets - Skips the entropy heuristic in test blocks and fixture paths
// spec: Ban Secrets - Redacts the matched secret in the violation message

test "analyzeContent flags AWS access key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "const k = \"AKIA" ++ "IOSFODNN7EXAMPLE\";\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags GitHub token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "const k = \"ghp_" ++ "0123456789abcdefABCDEFxyz\";\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags PEM private key inside a test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // PEM headers are enforced even in tests: a real key is a leak anywhere.
    const content =
        "test \"x\" {\n" ++
        "    const k =\n" ++
        "        \\\\-----BEGIN RSA PRIVATE" ++ " KEY-----\n" ++
        "    ;\n" ++
        "}\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent flags high-entropy secret assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "const password = \"" ++ "a9Xf2Kq7Lp4Rz1Nm8Ws\";\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent ignores placeholder secret assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "const api_key = \"your-api-key-example-here\";\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores env-var-name secret assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "const token = \"MY_SERVICE_AUTH_TOKEN\";\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores secret name assigned via import call not literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The literal is an @import argument, not the direct initializer — the
    // entropy heuristic must not fire on it (regression guard for registry.zig).
    const content = "const secret_mod = @import(\"" ++ "aX9f2Kq7Lp4Rz1Nm8Ws.zig\");\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent ignores Stripe test and publishable keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        "const a = \"sk_test_" ++ "0123456789abcdefghij\";\n" ++
        "const b = \"pk_live_" ++ "0123456789abcdefghij\";\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent flags Stripe live secret key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "const a = \"sk_live_" ++ "0123456789abcdefghij\";\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "analyzeContent skips entropy heuristic in test block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        "test \"x\" {\n" ++
        "    const password = \"" ++ "a9Xf2Kq7Lp4Rz1Nm8Ws\";\n" ++
        "    _ = password;\n" ++
        "}\n";
    const out = try analyzeContent(arena.allocator(), "src/x.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "analyzeContent skips entropy heuristic under fixtures path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content = "const password = \"" ++ "a9Xf2Kq7Lp4Rz1Nm8Ws\";\n";
    const out = try analyzeContent(arena.allocator(), "src/fixtures/seed.zig", content);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "redact keeps only the first four characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try redact(arena.allocator(), "supersecretvalue");
    try std.testing.expectEqualStrings("supe\u{2026}", out);
}

test "shannonEntropy is higher for random than for repeated" {
    const low = shannonEntropy("aaaaaaaaaaaaaaaa");
    const high = shannonEntropy("a9Xf2Kq7Lp4Rz1Nm8Ws");
    try std.testing.expect(high > low);
    try std.testing.expect(low < 1.0);
}
