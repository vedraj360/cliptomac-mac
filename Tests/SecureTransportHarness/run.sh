#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp -d)
server_pid=""
cleanup() {
    touch "$out/stop"
    if [ -n "$server_pid" ]; then wait "$server_pid" || true; fi
    rm -rf "$out"
}
trap cleanup EXIT
swiftc -parse-as-library -D CLIPTOMAC_TRANSFER_TEST "$root/Sources/AttachmentFilename.swift" "$root/Sources/PrivateAppStorage.swift" "$root/Sources/TrustedDeviceStorage.swift" "$root/Sources/TransferProgress.swift" "$root/Sources/TransferRateEstimator.swift" "$root/Sources/TransferManifest.swift" "$root/Sources/TransferVerifier.swift" "$root/Sources/BucketTransferStorage.swift" "$root/Sources/IncomingByteProgress.swift" "$root/Sources/BucketTransferReceiver.swift" "$root/Sources/PairingRequestPolicy.swift" "$root/Sources/TLSIdentity.swift" "$root/Sources/TLSSocketBridge.swift" "$root/Sources/PairingQRCode.swift" "$root/Sources/SecurePairing.swift" "$root/Sources/HTTPServer.swift" "$root/Sources/MacTransferService.swift" "$root/Tests/TransferProtocolHarness/ClipStoreStub.swift" "$root/Tests/SecureTransportHarness/main.swift" -o "$out/secure-server"
"$out/secure-server" "$out" > "$out/server.log" 2>&1 &
server_pid=$!
python3 "$root/Tests/SecureTransportHarness/check.py" "$out" "$@"

if [ -n "${CLIPTOMAC_ANDROID_PROJECT:-}" ]; then
    touch "$out/renew"
    count=0
    while [ ! -f "$out/renewed" ] && [ "$count" -lt 50 ]; do sleep 0.1; count=$((count + 1)); done
    CLIPTOMAC_TLS_FIXTURE="$out" "$CLIPTOMAC_ANDROID_PROJECT/gradlew" -p "$CLIPTOMAC_ANDROID_PROJECT" testDebugUnitTest --tests com.vdx.cliptomac.security.PinnedMacTransportTest
fi

if [ -n "${CLIPTOMAC_ANDROID_SERIAL:-}" ]; then
    rm -f "$out/renewed"
    touch "$out/renew"
    count=0
    while [ ! -f "$out/renewed" ] && [ "$count" -lt 50 ]; do sleep 0.1; count=$((count + 1)); done
    python3 "$root/Tests/SecureTransportHarness/device.py" "$out" "$CLIPTOMAC_ANDROID_SERIAL" "$CLIPTOMAC_ANDROID_PROJECT"
fi
