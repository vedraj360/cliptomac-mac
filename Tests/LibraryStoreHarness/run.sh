#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library "$root/Sources/AttachmentClipboard.swift" "$root/Sources/AttachmentFilename.swift" "$root/Sources/PrivateAppStorage.swift" "$root/Sources/TrustedDeviceStorage.swift" "$root/Sources/ClipItem.swift" "$root/Sources/ClipStore.swift" "$root/tests/LibraryStoreHarness/PlatformStubs.swift" "$root/tests/LibraryStoreHarness/main.swift" -o "$out/library-tests"
"$out/library-tests"
