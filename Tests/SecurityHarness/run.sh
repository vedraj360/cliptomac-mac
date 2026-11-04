#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library "$root/Sources/SQLiteAppState.swift" "$root/Sources/ClipToMacProtocol.swift" "$root/Sources/HTTPServerErrors.swift" "$root/Sources/TransferErrors.swift" "$root/Sources/PrivateAppStorage.swift" "$root/Sources/TrustedDeviceStorage.swift" "$root/Sources/PairingRequestPolicy.swift" "$root/Tests/SecurityHarness/main.swift" -o "$out/security-tests"
"$out/security-tests" "$@"
