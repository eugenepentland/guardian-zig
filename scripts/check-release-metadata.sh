#!/usr/bin/env bash
set -euo pipefail

package_version=$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)",/\1/p' build.zig.zon)
source_version=$(sed -n 's/^pub const string: \[\]const u8 = "\([^"]*\)";/\1/p' src/version.zig)

if [[ -z "$package_version" || -z "$source_version" ]]; then
  echo "unable to read Guardian version metadata" >&2
  exit 1
fi
if [[ "$package_version" != "$source_version" ]]; then
  echo "version mismatch: build.zig.zon=$package_version src/version.zig=$source_version" >&2
  exit 1
fi

echo "Guardian version metadata agrees: $package_version"
