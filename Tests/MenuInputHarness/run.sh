#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library "$root/Sources/GlassMenuPanel.swift" "$root/Tests/MenuInputHarness/main.swift" -o "$out/menu-input-tests"
"$out/menu-input-tests"
