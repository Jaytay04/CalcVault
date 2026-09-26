#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 path/to/app.ipa" >&2
  exit 2
fi

ipa_path=$1
if [ ! -f "$ipa_path" ]; then
  echo "error: IPA not found: $ipa_path" >&2
  exit 1
fi
if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: authoritative IPA inspection requires macOS tooling." >&2
  exit 1
fi

inspection_dir=$(mktemp -d "${TMPDIR:-/tmp}/calcvault-inspect.XXXXXX")
trap 'rm -rf "$inspection_dir"' EXIT INT TERM
ditto -x -k "$ipa_path" "$inspection_dir"

app_path="$inspection_dir/Payload/CalcVault.app"
plist_path="$app_path/Info.plist"
if [ ! -d "$app_path" ] || [ ! -f "$plist_path" ]; then
  echo "error: IPA does not contain Payload/CalcVault.app with Info.plist" >&2
  exit 1
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path")
platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$plist_path")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist_path")
face_id_usage=$(/usr/libexec/PlistBuddy -c 'Print :NSFaceIDUsageDescription' "$plist_path")

if [ "$bundle_id" != "com.jaylintaylor.calcvault" ]; then
  echo "error: unexpected bundle identifier: $bundle_id" >&2
  exit 1
fi
if [ "$platform" != "iPhoneOS" ]; then
  echo "error: expected iPhoneOS, found $platform" >&2
  exit 1
fi
if [ -z "$face_id_usage" ]; then
  echo "error: NSFaceIDUsageDescription is missing" >&2
  exit 1
fi

file "$app_path/$executable"
if ! file "$app_path/$executable" | grep -q 'arm64'; then
  echo "error: app executable has no arm64 device slice" >&2
  exit 1
fi

echo "bundle_identifier=$bundle_id"
echo "platform=$platform"
echo "face_id_usage_description=present"
echo "artifact_verification=PASS"
