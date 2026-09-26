#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$root_dir/build/DerivedData-device"
artifact_dir="$root_dir/build/artifacts"

if [ "$(uname -s)" != "Darwin" ] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: an iphoneos IPA requires macOS with Xcode." >&2
  exit 1
fi

sh "$root_dir/scripts/generate-project.sh"
mkdir -p "$artifact_dir"

xcodebuild \
  -project "$root_dir/CalcVault.xcodeproj" \
  -scheme CalcVault \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

app_path="$derived_data/Build/Products/Release-iphoneos/CalcVault.app"
if [ ! -d "$app_path" ]; then
  echo "error: expected device product was not found: $app_path" >&2
  exit 1
fi

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/calcvault-ipa.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT INT TERM
mkdir -p "$staging_dir/Payload"
ditto "$app_path" "$staging_dir/Payload/CalcVault.app"

ipa_path="$artifact_dir/CalcVault-unsigned.ipa"
(
  cd "$staging_dir"
  ditto -c -k --sequesterRsrc --keepParent Payload "$ipa_path"
)

sh "$root_dir/scripts/verify-artifact.sh" "$ipa_path"
shasum -a 256 "$ipa_path" | tee "$ipa_path.sha256"
echo "IPA=$ipa_path"
