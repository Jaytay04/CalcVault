#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
source_dir=$(CDPATH= cd "$script_dir/.." && pwd)
tmp_root=${TMPDIR:-/tmp}
build_dir=$(mktemp -d "$tmp_root/cvlp-cooperative-bootstrap.XXXXXX")
cleanup() {
    case "$build_dir" in
        "$tmp_root"/cvlp-cooperative-bootstrap.*) rm -rf "$build_dir" ;;
        *) exit 1 ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

clang -fobjc-arc -fmodules -framework Foundation \
    -I "$source_dir" \
    "$source_dir/CVLPCooperativePause.m" \
    "$script_dir/CooperativeBootstrapFixture.m" \
    -o "$build_dir/cooperative-bootstrap-fixture"

run=1
while [ "$run" -le 3 ]; do
    printf 'RUN cooperative bootstrap fixture %s/3\n' "$run"
    "$build_dir/cooperative-bootstrap-fixture"
    run=$((run + 1))
done
