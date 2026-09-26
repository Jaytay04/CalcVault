#!/bin/sh
set -eu

echo "os=$(uname -s)"
echo "architecture=$(uname -m)"

if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -version
else
  echo "xcodebuild=NOT_FOUND"
fi

if command -v swift >/dev/null 2>&1; then
  swift --version
else
  echo "swift=NOT_FOUND"
fi

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen version
else
  echo "xcodegen=NOT_FOUND"
fi
