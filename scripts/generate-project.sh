#!/bin/sh
set -eu

required_version="2.46.0"
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: XcodeGen $required_version is required." >&2
  echo "Install that exact release from https://github.com/yonaskolb/XcodeGen/releases/tag/$required_version" >&2
  exit 1
fi

actual_version=$(xcodegen version | awk '{print $2}')
if [ "$actual_version" != "$required_version" ]; then
  echo "error: expected XcodeGen $required_version, found $actual_version" >&2
  exit 1
fi

cd "$root_dir"
xcodegen generate --spec project.yml
