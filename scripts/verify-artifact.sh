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

app_bundle_count=$(find "$inspection_dir" -type d -name '*.app' -print | wc -l | tr -d '[:space:]')
if [ "$app_bundle_count" != "1" ]; then
  echo "error: expected exactly one app bundle in the IPA, found $app_bundle_count" >&2
  exit 1
fi

extension_count=$(find "$inspection_dir" -type d -name '*.appex' -print | wc -l | tr -d '[:space:]')
if [ "$extension_count" != "0" ]; then
  echo "error: IPA contains an embedded app extension ($extension_count found)" >&2
  exit 1
fi

credential_file=$(find "$inspection_dir" \( -iname '*.p12' -o -iname '*.pfx' \) -print -quit)
if [ -n "$credential_file" ]; then
  echo "error: exported signing credential file is present in the IPA" >&2
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

signed_entitlements="$inspection_dir/signed-entitlements.plist"
if ! codesign -d --entitlements :- "$app_path" > "$signed_entitlements" 2>/dev/null; then
  echo "error: app signature does not expose an entitlement blob" >&2
  exit 1
fi
python3 "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/credential-entitlements.py" "$signed_entitlements"

signature_details="$inspection_dir/signature-details.txt"
if ! codesign -dv --verbose=4 "$app_path" 2> "$signature_details"; then
  echo "error: app does not have a readable code signature" >&2
  exit 1
fi
if ! grep -q '^Signature=adhoc$' "$signature_details"; then
  echo "error: app signature is not ad-hoc" >&2
  exit 1
fi
codesign --verify --deep --strict "$app_path"

file "$app_path/$executable"
if ! file "$app_path/$executable" | grep -q 'arm64'; then
  echo "error: app executable has no arm64 device slice" >&2
  exit 1
fi

echo "bundle_identifier=$bundle_id"
echo "platform=$platform"
echo "face_id_usage_description=present"
echo "app_bundle_count=$app_bundle_count"
echo "embedded_extensions=0"
echo "exported_p12_pfx_files=0"
echo "code_signature=valid ad-hoc"
echo "entitlements=exact SideStore host keychain template"
echo "artifact_verification=PASS"
