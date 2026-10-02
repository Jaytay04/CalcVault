#!/bin/sh
set -eu
if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Foundation fixture requires macOS with Xcode tools." >&2
  exit 1
fi
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out_dir=$(mktemp -d "${TMPDIR:-/tmp}/tkplus-media.XXXXXX")
# Deliberately retain the bounded temporary executable for inspection.
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
  "$test_dir/media_selection_fixture.m" "$test_dir/../Guest/TKPMediaSelection.m" \
  -framework Foundation -o "$out_dir/media_selection_fixture"
"$out_dir/media_selection_fixture"
