#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$root_dir/build/DerivedData-device"
artifact_dir="$root_dir/build/artifacts"
entitlements_path="$root_dir/config/host-keychain.entitlements"

if [ "$(uname -s)" != "Darwin" ] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: an iphoneos IPA requires macOS with Xcode." >&2
  exit 1
fi

sh "$root_dir/scripts/generate-project.sh"
python3 "$root_dir/scripts/credential-entitlements.py" "$entitlements_path"
mkdir -p "$artifact_dir"

echo "Building a SideStore re-signing candidate with an ad-hoc signature; this is not an installable signed IPA."

set --
case "${CALCVAULT_NATIVE_PREFLIGHT:-0}" in
  0) ;;
  1) set -- CURRENT_PROJECT_VERSION=21 ;;
  *) echo "error: unsupported native preflight selection" >&2; exit 1 ;;
esac

xcodebuild \
  -project "$root_dir/CalcVault.xcodeproj" \
  -scheme CalcVault \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  "$@" \
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

staged_app="$staging_dir/Payload/CalcVault.app"
# Mark only the staged candidate, before signing; do not contaminate cached
# build products used by a later default (non-preflight) package.
if [ "${CALCVAULT_NATIVE_PREFLIGHT:-0}" = 1 ]; then
  /usr/libexec/PlistBuddy -c 'Add :CVNativeIntegrationStage string credential-preflight-21' "$staged_app/Info.plist"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CVNativeIntegrationStage' "$staged_app/Info.plist")" = credential-preflight-21
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$staged_app/Info.plist")" = 21
fi
# Xcode leaves the device product unsigned. Sign nested code first, then sign the
# host with its explicit entitlement blob so SideSign can inspect and replace it.
codesign --force --deep --sign - "$staged_app"
codesign --force --sign - --entitlements "$entitlements_path" "$staged_app"
codesign --verify --deep --strict "$staged_app"

ipa_path="$artifact_dir/CalcVault-unsigned.ipa"
(
  cd "$staging_dir"
  ditto -c -k --sequesterRsrc --keepParent Payload "$ipa_path"
)

sh "$root_dir/scripts/verify-artifact.sh" "$ipa_path"
shasum -a 256 "$ipa_path" | tee "$ipa_path.sha256"
echo "artifact_signing=ad-hoc SideStore re-signing candidate; not installable as-is"
echo "IPA=$ipa_path"
