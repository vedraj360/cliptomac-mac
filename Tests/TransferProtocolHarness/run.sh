#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library "$root/Sources/SQLiteAppState.swift" "$root/Sources/AttachmentFilename.swift" "$root/Sources/PrivateAppStorage.swift" "$root/Sources/TrustedDeviceStorage.swift" -D CLIPTOMAC_TRANSFER_TEST "$root/Sources/TransferProgress.swift" "$root/Sources/TransferRateEstimator.swift" "$root/Sources/TransferManifest.swift" "$root/Sources/TransferVerifier.swift" "$root/Sources/IncomingTransferControls.swift" "$root/Sources/BucketTransferStorage.swift" "$root/Sources/IncomingByteProgress.swift" "$root/Sources/BucketTransferReceiver.swift" "$root/Sources/ClipToMacProtocol.swift" "$root/Sources/HTTPServerErrors.swift" "$root/Sources/TransferErrors.swift" "$root/Sources/PairingRequestPolicy.swift" "$root/Sources/TLSIdentity.swift" "$root/Sources/TLSSocketBridge.swift" "$root/Sources/SecurePairing.swift" "$root/Sources/AppTypography.swift" "$root/Sources/PhoneNotificationRelay.swift" "$root/Sources/HTTPServer.swift" "$root/Sources/MacTransferService.swift" "$root/Tests/TransferProtocolHarness/ClipStoreStub.swift" "$root/Tests/TransferProtocolHarness/BucketChecks.swift" "$root/Tests/TransferProtocolHarness/main.swift" -o "$out/transfer-protocol-harness"
"$out/transfer-protocol-harness" "$@"
