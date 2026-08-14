//! Fixture OWNER for the concept check's `literals_from` extraction: an enum
//! whose emitting switch is the only place the wire strings are spelled. Lives
//! outside `src/` on purpose — the AST index walks `src/` alone, so this file
//! reaches a check only through a `[[concept]]` rule that names it.

pub const Kind = enum {
    clearance,
    track_track,
    hole_size,

    /// Every wire string of the family, on lines carrying `=> "` — the fragment
    /// a `literals_from` rule matches on. The next line is prose ABOUT the
    /// switch and must enrol nothing, because comment lines are blanked first:
    ///     .retired => "not_a_kind",
    pub fn wire(self: Kind) []const u8 {
        return switch (self) {
            .clearance => "clearance",
            .track_track => "track_track",
            .hole_size => "hole_size",
        };
    }
};
