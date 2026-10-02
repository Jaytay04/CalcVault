#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
experiment_dir="$(cd "$script_dir/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcrun >/dev/null 2>&1; then
  echo "Apple compilation NOT RUN: a macOS host with Xcode command-line tools is required."
  exit 77
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [[ -z "$sdk_path" ]]; then
  echo "Apple compilation NOT RUN: the macOS SDK is unavailable."
  exit 77
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tkp-profile-controls.XXXXXX")"
echo "Synthetic fixture executables will be retained in: $build_dir"

for mode in 0 1 2 3 4 5 6 7 8 9; do
  xcrun --sdk macosx clang \
    -isysroot "$sdk_path" \
    -fobjc-arc \
    -std=c11 \
    -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable \
    -DTKP_PROFILE_FIXTURE_MODE="$mode" \
    "$experiment_dir/Guest/TKPProfileControls.m" \
    "$experiment_dir/Tests/profile_controls_fixture.m" \
    -framework Foundation \
    -o "$build_dir/profile-controls-$mode"
  "$build_dir/profile-controls-$mode"
done
