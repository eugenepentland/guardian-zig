// Fixture MIRROR for the concept check's `require_in` direction: a hand-written
// gate table that has fallen behind the owner's enum. It knows two of the three
// wire strings; `hole_size` is the one a rename/addition left behind, and a
// table like this fails PERMISSIVELY — an unrecognised kind simply stops
// blocking, which is why silence here is not acceptable.
const DRC_BLOCK = {
  clearance: true,
  track_track: true,
};

// A comment naming hole_size does NOT satisfy the requirement: a comment cannot
// carry the value at runtime, and the same blanking the ownership scan applies
// is applied here.
export function blocks(kind) {
  return DRC_BLOCK[kind] === true;
}
