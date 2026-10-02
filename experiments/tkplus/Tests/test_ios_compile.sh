#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcrun >/dev/null 2>&1 || [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS source compilation NOT RUN: macOS and Xcode are required."
  exit 77
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
experiment_dir="$(cd "$script_dir/.." && pwd)"

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
test -d "$sdk_path"
echo "iPhoneOS SDK version: $(xcrun --sdk iphoneos --show-sdk-version)"
echo "Compile target: arm64-apple-ios18.0; object files only, no app or IPA."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tkp-ios-source.XXXXXX")"
echo "Generated object files retained in: $build_dir"

for unit in TKPTransfer TKPStreamReader; do
  xcrun --sdk iphoneos clang \
    -target arm64-apple-ios18.0 -isysroot "$sdk_path" \
    -std=c11 -Wall -Wextra -Wpedantic -Werror -DNDEBUG \
    -c "$experiment_dir/Core/$unit.c" -o "$build_dir/$unit.o"
done

for unit in TKPMediaSelection TKPProfileControls; do
  xcrun --sdk iphoneos clang \
    -target arm64-apple-ios18.0 -isysroot "$sdk_path" \
    -fobjc-arc -std=c11 -Wall -Wextra -Werror \
    -c "$experiment_dir/Guest/$unit.m" -o "$build_dir/$unit.o"
done

for unit in TKPTransfer TKPStreamReader TKPMediaSelection TKPProfileControls; do
  xcrun lipo "$build_dir/$unit.o" -verify_arch arm64
  build_info="$(xcrun vtool -show-build "$build_dir/$unit.o")"
  printf '%s\n' "$build_info"
  printf '%s\n' "$build_info" | grep -Eq '^[[:space:]]*platform IOS$'
  printf '%s\n' "$build_info" | grep -Eq '^[[:space:]]*minos 18\.0$'
done

echo "PASS: four independent source units compile for arm64 iPhoneOS. No linking or execution."
