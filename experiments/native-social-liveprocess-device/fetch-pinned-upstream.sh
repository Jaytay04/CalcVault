#!/usr/bin/env bash
# Public source only. Mirrors must supply the exact previously reviewed commits.
set -euo pipefail
source="$(mkdir -p "$1" && cd "$1" && pwd)"
pin=e370a92dfc03ce109ebce00ed4a7cfc64ad1c801
test ! -e "$source/.git"
git init -q "$source"
git -C "$source" remote add origin https://github.com/LiveContainer/LiveContainer.git
if ! git -C "$source" fetch --depth 1 origin "$pin"; then
    git -C "$source" remote set-url origin https://github.com/xieyos/livecontainer.git
    git -C "$source" fetch --depth 1 origin "$pin"
fi
git -C "$source" checkout --detach FETCH_HEAD
test "$(git -C "$source" rev-parse HEAD)" = "$pin"
git -C "$source" submodule init
# Original organization endpoint is currently unavailable. This public mirror
# contains the same gitlink object; the immutable commit checks below are required.
git -C "$source" config submodule.litehook.url https://github.com/opa334/litehook.git
git -C "$source" submodule update --init --recursive --depth 1
test "$(git -C "$source/OpenSSL" rev-parse HEAD)" = 623c84da314e85363236507ca38a4bde65df21c3
test "$(git -C "$source/litehook" rev-parse HEAD)" = 8025e0c8ebdf5cdd1d2a4f45025813234bf9dc55
git -C "$source" remote get-url origin
git -C "$source" submodule status
