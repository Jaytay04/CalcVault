#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$root_dir/build/DerivedData-tests"
test_destination=${CALCVAULT_TEST_DESTINATION:-'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest'}

if [ "$(uname -s)" != "Darwin" ] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: authoritative iOS tests require macOS with Xcode." >&2
  exit 1
fi

sh "$root_dir/scripts/generate-project.sh"

xcodebuild \
  -project "$root_dir/CalcVault.xcodeproj" \
  -scheme CalcVault \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "$test_destination" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  test
