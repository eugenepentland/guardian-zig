# Releasing Guardian

Guardian is a build gate, so consumers should use an immutable package rather
than a live sibling checkout. A release is complete only when its tag, mutation
ratchet, and downstream package hashes agree.

1. Update `CHANGELOG.md`, `build.zig.zon`, and `src/version.zig`.
2. Run `./scripts/check-release-metadata.sh`, `zig build test`, and
   `zig build mutate-full`. Commit any intended `.guardian/` ratchet change.
3. Commit the release, create an annotated `v<version>` tag, and push the commit
   and tag. The release workflow verifies the tag and creates the GitHub release.
4. Run:

   ```sh
   zig fetch https://github.com/eugenepentland/guardian-zig/archive/refs/tags/v<version>.tar.gz
   ```

   Record the printed package hash with the release notes.
5. Update every package in one dependency graph to the same Guardian URL and
   hash. In particular, `ward` and `eda` must move together: pinning only EDA
   leaves Ward's path dependency as a second Guardian module and Zig rejects the
   duplicate package.

Never publish a tag whose full mutation run is red or whose mutation snapshot
was created from a different cohort than the one recorded by the release.
