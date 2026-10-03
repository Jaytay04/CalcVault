#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
experiment_dir="$(cd "$script_dir/.." && pwd)"
output="${1:?new output directory required}"
test "$(uname -s)" = Darwin
test ! -e "$output"
mkdir -p "$output"
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcodebuild -version | tee "$output/toolchain.txt"
xcrun --sdk iphoneos clang --version >> "$output/toolchain.txt"
xcrun --sdk iphoneos --show-sdk-version >> "$output/toolchain.txt"

# Only independently authored source. No proprietary imports, private binaries,
# account data, network downloads, license code or containing-app source.
xcrun --sdk iphoneos clang \
  -target arm64-apple-ios18.0 -isysroot "$sdk" \
  -dynamiclib -fobjc-arc -fblocks -std=c11 -Wall -Wextra -Werror \
  -Wl,-install_name,@rpath/TKP.dylib \
  "$experiment_dir/Guest/TKPProfileControls.m" \
  "$experiment_dir/Guest/TKPDevicePanel.m" \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -o "$output/TKP.dylib"
xcrun lipo "$output/TKP.dylib" -verify_arch arm64
xcrun vtool -show-build "$output/TKP.dylib" | tee "$output/platform.txt"
grep -Eq '^[[:space:]]*platform IOS$' "$output/platform.txt"
grep -Eq '^[[:space:]]*minos 18\.0$' "$output/platform.txt"
xcrun otool -L "$output/TKP.dylib" | tee "$output/dependencies.txt"
xcrun nm -gU "$output/TKP.dylib" | tee "$output/exports.txt"
grep -Eq '[[:space:]]_TKPDevicePanelStart$' "$output/exports.txt"
if grep -Eq '[[:space:]]_TKPTestClassImage(Status|PathStatus)$' "$output/exports.txt"; then
  echo 'Device module unexpectedly exports a test-only class diagnostic entry.' >&2
  exit 1
fi
codesign --force --sign - "$output/TKP.dylib"
codesign --verify --strict "$output/TKP.dylib"
python3 - "$experiment_dir" "$output" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from assemble_device_candidate import verify_addon
output = Path(sys.argv[2])
module = (output / 'TKP.dylib').read_bytes()
verify_addon(module)
receipt = {'schema': 1, 'source_commit': os.environ.get('GITHUB_SHA', 'local'),
           'platform': 'iOS', 'architecture': 'arm64', 'minimum_os': '18.0',
           'scope': 'profile-tab entry diagnostics, gear entry and opt-in local profile eligibility settings',
           'module_sha256': hashlib.sha256(module).hexdigest(), 'module_bytes': len(module),
           'private_input_used': False, 'device_execution': 'NOT RUN'}
(output / 'source-build.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
(output / 'TKP.dylib.sha256').write_text(receipt['module_sha256'] + '  TKP.dylib\n')
PY
echo 'PASS: independently authored ARM64 iOS18 device module linked and verified.'
