#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcrun >/dev/null 2>&1 || [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Apple sanitizer execution NOT RUN: macOS and Xcode are required."
  exit 77
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
experiment_dir="$(cd "$script_dir/.." && pwd)"

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
test -d "$sdk_path"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tkp-sanitizers.XXXXXX")"
echo "Generated sanitizer fixtures retained in: $build_dir"

for fixture in transfer stream_reader; do
  sources=("$experiment_dir/Core/TKPTransfer.c")
  if [[ "$fixture" == "stream_reader" ]]; then
    sources+=("$experiment_dir/Core/TKPStreamReader.c")
  fi
  xcrun --sdk macosx clang \
    -isysroot "$sdk_path" -std=c11 -Wall -Wextra -Wpedantic -Werror \
    -DNDEBUG -O1 -g -fsanitize=address,undefined \
    -fno-sanitize-recover=all -fno-omit-frame-pointer \
    "${sources[@]}" "$script_dir/${fixture}_tests.c" \
    -o "$build_dir/$fixture"
  "$build_dir/$fixture"
done

echo "PASS: portable fixtures under AddressSanitizer and UndefinedBehaviorSanitizer."
