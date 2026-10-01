#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
upstream="$(cd "${1:?upstream source path required}" && pwd)"
work="${2:?temporary work path required}"
device_project="$repo_root/experiments/native-social-liveprocess-device"
kit_project="$repo_root/experiments/native-social-integration"
logs="$work/logs"
evidence="$work/evidence"
output="$work/output"
mkdir -p "$logs" "$evidence" "$output"

(cd "$device_project" && xcodegen generate)
(cd "$kit_project" && xcodegen generate)

build_target() {
    local sdk="$1" destination="$2" products="$3"
    printf 'Building CalcVaultKit and synthetic runtime for %s\n' "$sdk"
    xcodebuild build -project "$kit_project/CalcVaultKit.xcodeproj" -scheme CalcVaultKit \
        -configuration Release -sdk "$sdk" -destination "$destination" \
        -derivedDataPath "$work/kit-$sdk" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES > "$logs/kit-$sdk.log" 2>&1 || {
            tail -n 100 "$logs/kit-$sdk.log"
            return 1
        }
    xcodebuild build -project "$device_project/CVLPGuest.xcodeproj" -scheme CVLPGuest \
        -configuration Release -sdk "$sdk" -destination "$destination" \
        -derivedDataPath "$work/guest-$sdk" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES > "$logs/guest-$sdk.log" 2>&1 || {
            tail -n 100 "$logs/guest-$sdk.log"
            return 1
        }
    xcodebuild build -project "$upstream/LiveContainer.xcodeproj" -scheme LiveContainer \
        -configuration Debug -sdk "$sdk" -destination "$destination" \
        -derivedDataPath "$work/host-$sdk" \
        LIVECONTAINER_BUNDLE_IDENTIFIER=com.jaylintaylor.calcvault \
        IPHONEOS_DEPLOYMENT_TARGET=18.0 \
        CV_INTEGRATION_KIT_DIR="$products" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        > "$logs/host-$sdk.log" 2>&1 || {
            tail -n 120 "$logs/host-$sdk.log"
            return 1
        }
}

sim_products="$work/kit-iphonesimulator/Build/Products/Release-iphonesimulator"
device_products="$work/kit-iphoneos/Build/Products/Release-iphoneos"

simulator="$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name | startswith("iPhone")) | .udid][0] // empty')"
test -n "$simulator"
if ! xcrun simctl boot "$simulator"; then
    xcrun simctl bootstatus "$simulator" -b
fi
xcrun simctl bootstatus "$simulator" -b

if [[ "${CV_HIGHLIGHTS_DIAGNOSTICS:-0}" == 1 ]]; then
    # Run default-off, each isolated viewing mode, replay and admission discovery.
    # no proprietary guest, account or network is used by this executable.
    fixture_app="$work/HighlightsDiagnosticsFixture.app"
    mkdir -p "$fixture_app"
    cp "$device_project/HighlightsDiagnosticsFixture-Info.plist" "$fixture_app/Info.plist"
    # Synthetic libraries only: never part of the containing-app IPA. The fixture
    # obtains their UUIDs before arming the callback; no linker UUID override.
    mkdir -p "$fixture_app/Frameworks"
    for fixture_library in CVLPEarlyLoaderTarget CVLPEarlyLoaderAlreadyLoaded CVLPEarlyLoaderMismatch; do
        xcrun --sdk iphonesimulator clang -dynamiclib -arch arm64 \
            -mios-simulator-version-min=18.0 -fobjc-arc -fblocks \
            -framework Foundation -I "$device_project" \
            -Wl,-install_name,@rpath/"$fixture_library.dylib" \
            "$device_project/CVLPEarlyLoaderSyntheticImage.m" \
            -o "$fixture_app/Frameworks/$fixture_library.dylib" \
            > "$logs/$fixture_library-compile.log" 2>&1 || {
                tail -n 100 "$logs/$fixture_library-compile.log"
                exit 1
            }
        codesign --force --sign - "$fixture_app/Frameworks/$fixture_library.dylib"
    done
    for fixture_mode in 0 1 2 3 4 5; do
    viewing_mode=0
    direct_mode=0
    early_mode=0
    admission_mode=0
    early_replay_only=0
    fixture_suffix=""
    if [[ "$fixture_mode" == 1 ]]; then viewing_mode=1; fixture_suffix="-viewing"; fi
    if [[ "$fixture_mode" == 2 ]]; then direct_mode=1; fixture_suffix="-directviewing"; fi
    if [[ "$fixture_mode" == 3 ]]; then early_mode=1; fixture_suffix="-earlyviewing"; fi
    if [[ "$fixture_mode" == 4 ]]; then early_mode=1; early_replay_only=1; fixture_suffix="-earlyreplay"; fi
    if [[ "$fixture_mode" == 5 ]]; then admission_mode=1; fixture_suffix="-admission"; fi
    xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=18.0 \
        -DCVLP_HIGHLIGHTS_VIEWING_EXPERIMENT="$viewing_mode" \
        -DCVLP_HIGHLIGHTS_DIRECT_VIEWING_EXPERIMENT="$direct_mode" \
        -DCVLP_HIGHLIGHTS_EARLY_VIEWING_EXPERIMENT="$early_mode" \
        -DCVLP_HIGHLIGHTS_ADMISSION_METADATA="$admission_mode" \
        -fobjc-arc -fblocks -framework Foundation -framework UIKit -framework QuartzCore \
        -Wl,-rpath,@executable_path/Frameworks \
        -I "$device_project" -I "$upstream/LiveContainer" \
        "$device_project/HighlightsDiagnosticsFixture.m" \
        -o "$fixture_app/HighlightsDiagnosticsFixture" > "$logs/highlights-fixture$fixture_suffix-compile.log" 2>&1 || {
            tail -n 100 "$logs/highlights-fixture$fixture_suffix-compile.log"
            exit 1
        }
    codesign --force --sign - "$fixture_app"
    xcrun simctl install "$simulator" "$fixture_app"
    fixture_failure_evidence() {
        # This simulator contains synthetic fixtures only. Limit captured logs
        # and crash reports to this fixture process, never a private guest.
        xcrun simctl spawn "$simulator" log show --last 5m --style compact \
            --predicate 'process == "HighlightsDiagnosticsFixture"' \
            > "$evidence/highlights-fixture-runtime.log" 2>&1 || true
        for report in "$HOME"/Library/Logs/DiagnosticReports/HighlightsDiagnosticsFixture*.ips; do
            if [[ -f "$report" ]]; then cp "$report" "$evidence/"; fi
        done
    }
    fixture_result_name="cv-highlights-$(uuidgen)-$fixture_mode.result"
    fixture_data="$(xcrun simctl get_app_container "$simulator" org.example.synthetic.highlights-observer-tests data)"
    fixture_result="$fixture_data/tmp/$fixture_result_name"
    test ! -e "$fixture_result"
    SIMCTL_CHILD_CV_HIGHLIGHTS_RESULT_NAME="$fixture_result_name" \
    SIMCTL_CHILD_CV_HIGHLIGHTS_EARLY_REPLAY_ONLY="$early_replay_only" \
    python3 "$kit_project/run-highlights-fixture.py" "$simulator" \
        "$evidence/highlights-fixture$fixture_suffix.log" || {
            cat "$evidence/highlights-fixture$fixture_suffix.log"
            fixture_failure_evidence
            exit 1
        }
    for fixture_result_attempt in {1..30}; do
        test -f "$fixture_result" && break
        sleep 1
    done
    if ! test -f "$fixture_result" ||
        ! test "$(<"$fixture_result")" = "CV_HIGHLIGHTS_FIXTURE_PASS viewing=$viewing_mode direct=$((direct_mode || early_mode)) early=$early_mode admission=$admission_mode"; then
        cat "$evidence/highlights-fixture$fixture_suffix.log"
        if [[ -f "$fixture_result" ]]; then cat "$fixture_result"; fi
        fixture_failure_evidence
        exit 1
    fi
    cp "$fixture_result" "$evidence/highlights-fixture$fixture_suffix-result.log"
    if [[ "$early_replay_only" == 1 ]]; then
        grep -Fq 'CV_HIGHLIGHTS_EARLY_FIXTURE_PASS case=exact-target-replay-terminal' \
            "$evidence/highlights-fixture$fixture_suffix.log"
    fi
    if [[ "$admission_mode" == 1 ]]; then
        grep -Fq 'CV_ADMISSION_METADATA_FIXTURE_PASS' \
            "$evidence/highlights-fixture$fixture_suffix.log"
    fi
    # This marker is emitted only after the exact fresh, mode-tagged result.
    printf 'CV_HIGHLIGHTS_FIXTURE_PASS mode=%s\n' "$fixture_mode"
    done
fi

build_target iphonesimulator 'generic/platform=iOS Simulator' "$sim_products"
build_target iphoneos 'generic/platform=iOS' "$device_products"

raw_sim_host="$work/host-iphonesimulator/Build/Products/Debug-iphonesimulator/LiveContainer.app"
codesign --force --deep --sign - "$raw_sim_host"
xcrun simctl install "$simulator" "$raw_sim_host"

prepatch_payload() {
    local sdk="$1" guest="$2" payload="$3"
    cp "$guest/CVLPGuest" "$payload"
    xcrun otool -hv "$payload" | grep -q EXECUTE
    if SIMCTL_CHILD_CVLP_PREPATCH_PATH="$payload" \
        xcrun simctl launch --terminate-running-process "$simulator" com.jaylintaylor.calcvault \
        > "$logs/prepatch-$sdk.log" 2>&1; then
        :
    fi
    for attempt in {1..20}; do
        test -f "$payload.result" && break
        sleep 2
    done
    test -f "$payload.result"
    test "$(<"$payload.result")" = PATCHED
    xcrun otool -hv "$payload" > "$payload.header"
    grep -q DYLIB "$payload.header"
    xcrun vtool -show-build "$payload" > "$payload.build"
    if [[ "$sdk" == iphoneos ]]; then
        grep -Eq 'platform IOS([[:space:]]|$)' "$payload.build"
    else
        grep -Eq 'platform IOSSIMULATOR([[:space:]]|$)' "$payload.build"
    fi
}

sim_guest="$work/guest-iphonesimulator/Build/Products/Release-iphonesimulator/CVLPGuest.app"
device_guest="$work/guest-iphoneos/Build/Products/Release-iphoneos/CVLPGuest.app"
sim_payload="$work/SyntheticGuest-iphonesimulator.dylib"
device_payload="$work/SyntheticGuest-iphoneos.dylib"
prepatch_payload iphonesimulator "$sim_guest" "$sim_payload"
prepatch_payload iphoneos "$device_guest" "$device_payload"

verify_and_sign() {
    local sdk="$1" host="$2" entitlements="$3"
    local extension="$host/PlugIns/LiveProcess.appex"
    local ui_binary="$host/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI"
    local extension_binary="$extension/LiveProcess"
    test -f "$host/Frameworks/CalcVaultKit.framework/CalcVaultKit"
    test -f "$host/Frameworks/NativeGuest.framework/NativeGuest"
    test -f "$ui_binary" && test -f "$extension_binary"

    codesign --force --sign - "$host/Frameworks/SyntheticNativeGuestPayload.dylib"
    find "$host/Frameworks" -type d -name '*.framework' -prune -print0 |
        while IFS= read -r -d '' framework; do
            codesign --force --deep --sign - "$framework"
        done
    codesign --force --deep --sign - "$host"
    codesign --force --sign - --entitlements "$entitlements/extension.entitlements" "$extension"
    codesign --force --sign - --entitlements "$entitlements/host.entitlements" "$host"
    codesign --verify --deep --strict "$host"
    codesign --verify --strict "$host/Frameworks/CalcVaultKit.framework"
    codesign --verify --strict "$host/Frameworks/NativeGuest.framework"

    otool -L "$ui_binary" > "$evidence/ui-framework-links-$sdk.txt"
    grep -q 'CalcVaultKit.framework/CalcVaultKit' "$evidence/ui-framework-links-$sdk.txt"
    otool -L "$extension_binary" > "$evidence/extension-links-$sdk.txt"
    if grep -q 'CalcVaultKit.framework/CalcVaultKit' "$evidence/extension-links-$sdk.txt"; then
        echo 'LiveProcess must not link CalcVaultKit' >&2
        return 1
    fi
    otool -L "$host/Frameworks/CalcVaultKit.framework/CalcVaultKit" \
        > "$evidence/kit-links-$sdk.txt"
    python3 - "$host" "$ui_binary" "$extension_binary" \
        "$host/Frameworks/CalcVaultKit.framework/CalcVaultKit" \
        "$evidence/ui-framework-links-$sdk.txt" "$evidence/extension-links-$sdk.txt" \
        "$evidence/kit-links-$sdk.txt" <<'PY'
import sys
from pathlib import Path
host = Path(sys.argv[1])
for binary_arg, listing_arg in zip(sys.argv[2:5], sys.argv[5:8]):
    binary = Path(binary_arg)
    for line in Path(listing_arg).read_text().splitlines()[1:]:
        dependency = line.strip().split(' ', 1)[0]
        if not dependency.startswith('@rpath/'):
            continue
        if Path(dependency).name == binary.name:
            continue
        resolved = host / 'Frameworks' / dependency[len('@rpath/'):]
        if not resolved.exists():
            raise SystemExit(f'unresolved @rpath dependency: {dependency}')
PY
    # Explicit XML is required: the default display is human-readable on this toolchain.
    codesign -d --entitlements - --xml "$extension" 2>/dev/null > "$evidence/extension-entitlements-$sdk.plist"
    codesign -d --entitlements - --xml "$host" 2>/dev/null > "$evidence/host-entitlements-$sdk.plist"
    python3 - "$host" "$evidence/extension-entitlements-$sdk.plist" \
        "$evidence/host-entitlements-$sdk.plist" "$entitlements" <<'PY'
import plistlib, sys
from pathlib import Path
host = Path(sys.argv[1])
info = plistlib.loads((host / 'Info.plist').read_bytes())
assert info.get('CFBundleVersion') == '23'
assert info.get('CVNativeIntegrationStage') == 'synthetic-integration-23'
assert info.get('CVNativeGuestKind') == 'synthetic'
assert info.get('CVLPFrameworkGuestMode') == 1
assert info.get('CFBundleIdentifier') == 'com.jaylintaylor.calcvault'
assert info.get('UIFileSharingEnabled') is False
assert info.get('LSSupportsOpeningDocumentsInPlace') is False
assert 'NSAppTransportSecurity' not in info and 'UIBackgroundModes' not in info
assert sorted(p.name for p in (host / 'PlugIns').iterdir()) == ['LiveProcess.appex']
assert not list(host.rglob('*.app'))
entitlements = plistlib.loads(Path(sys.argv[2]).read_bytes())
groups = entitlements.get('keychain-access-groups', [])
assert not any('hostonly' in group.lower() for group in groups)
for kind, signed_path in (('extension', sys.argv[2]), ('host', sys.argv[3])):
    signed = plistlib.loads(Path(signed_path).read_bytes())
    expected = plistlib.loads((Path(sys.argv[4]) / (kind + '.entitlements')).read_bytes())
    for key, value in expected.items():
        assert signed.get(key) == value, (kind, key)
for path in host.rglob('*'):
    assert path.suffix.lower() not in ('.p12', '.pfx', '.mobileprovision')
PY
}

stage_and_package() {
    local sdk="$1" guest="$2" payload="$3" kit="$4" host_product="$5"
    local host="$work/staged-$sdk/Build/Products/Debug-$sdk/LiveContainer.app"
    local entitlements="$work/entitlements-$sdk"
    mkdir -p "$(dirname "$host")"
    ditto "$host_product" "$host"
    package_args=("$host" "$guest" "$payload" "$entitlements")
    if [[ "$sdk" == iphonesimulator ]]; then package_args+=(--simulator); fi
    python3 "$device_project/package-fixture.py" "${package_args[@]}" > "$logs/package-fixture-$sdk.log"
    python3 "$device_project/package-framework-fixture.py" "$host" "$guest" "$payload" \
        > "$logs/package-framework-$sdk.log"
    python3 "$kit_project/stage-integration.py" "$host" "$kit" > "$logs/stage-integration-$sdk.log"
    verify_and_sign "$sdk" "$host" "$entitlements"
}

sim_host_product="$work/host-iphonesimulator/Build/Products/Debug-iphonesimulator/LiveContainer.app"
device_host_product="$work/host-iphoneos/Build/Products/Debug-iphoneos/LiveContainer.app"
stage_and_package iphonesimulator "$sim_guest" "$sim_payload" \
    "$sim_products/CalcVaultKit.framework" "$sim_host_product"
stage_and_package iphoneos "$device_guest" "$device_payload" \
    "$device_products/CalcVaultKit.framework" "$device_host_product"
sim_host="$work/staged-iphonesimulator/Build/Products/Debug-iphonesimulator/LiveContainer.app"
device_host="$work/staged-iphoneos/Build/Products/Debug-iphoneos/LiveContainer.app"

started="$(date '+%Y-%m-%d %H:%M:%S')"
xcrun simctl install "$simulator" "$sim_host"
xcrun simctl launch --terminate-running-process "$simulator" com.jaylintaylor.calcvault \
    > "$logs/locked-root-launch.log" 2>&1
found=0
for attempt in {1..12}; do
    sleep 5
    xcrun simctl spawn "$simulator" log show --start "$started" --style compact \
        --predicate 'eventMessage CONTAINS "CV_INTEGRATION_" OR eventMessage CONTAINS "CVLP_"' \
        > "$evidence/simulator-locked-root.log"
    if grep -q CV_INTEGRATION_ROOT_ACTIVE "$evidence/simulator-locked-root.log"; then
        found=1
        break
    fi
done
test "$found" = 1
if grep -Eq 'CVLP_HOST_LAUNCHED|CVLP_GUEST_VISIBLE' "$evidence/simulator-locked-root.log"; then
    echo 'Locked-root smoke unexpectedly launched the synthetic guest' >&2
    exit 1
fi
xcrun simctl io "$simulator" screenshot "$evidence/simulator-locked-root.png"

mkdir -p "$output/Payload"
ditto "$device_host" "$output/Payload/LiveContainer.app"
(cd "$output" && zip -qry CalcVault-integration-host-23.ipa Payload)
shasum -a 256 "$output/CalcVault-integration-host-23.ipa" \
    > "$output/CalcVault-integration-host-23.ipa.sha256"
unzip -t "$output/CalcVault-integration-host-23.ipa" > "$evidence/ipa-zip-check.txt"
printf '%s\n' 'Build 23 synthetic integration-host artifact created.' \
    'Simulator evidence covers only the locked CalcVault root; no guest launch was attempted.' \
    'Physical-device signing, install, native guest launch and isolation remain NOT RUN.' \
    > "$evidence/result.txt"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$evidence/result.txt" >> "$GITHUB_STEP_SUMMARY"
fi
