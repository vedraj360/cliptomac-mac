# Secure pairing and transport v3

Implemented 27 October 2026, after checkpoints Mac `c3662f5` / Android `8c789d9`.

## What the customer does

1. Install the updated Mac and Android apps. Fresh installations are supported; old unencrypted pairings are not accepted by the new server.
2. On the Mac, open ClipToMac → Settings → **Show pairing QR**.
3. On Android, tap **Pair Mac securely → Scan QR**. Grant camera access when requested. If a camera is unavailable, paste the pairing code copied directly from your own Mac.
4. Compare the displayed six-digit code with the Mac confirmation, then accept on the Mac.
5. Text, files, images, receipts, progress requests and cancellation use the encrypted connection. An IP address change does not change the trusted Mac certificate. Unpairing revokes that phone's token.

A QR is valid for starting one enrollment within two minutes. Opening another QR or cancelling closes the previous enrollment. Never scan a pairing code supplied by a stranger: the code is the out-of-band trust channel.

## Protocol and security boundary

- Mac serves HTTPS only, via Network.framework TLS with a minimum of TLS 1.2 (TLS 1.3 where supported). TLS 1.2 compatibility retains Android 8/9 support. There is no plaintext production listener or HTTP downgrade fallback.
- The public certificate is persisted in app-private `TLS/*.der` so the pin stays identical across process restarts (Keychain certificate display labels are not used for identity lookup).
- Mac identity is a persistent P-256 private key in Keychain with extraction disabled, plus a self-signed X.509 certificate. Certificate encoding is DER; key generation/signing are Security.framework operations. The certificate currently has a ten-year validity; renewal/rotation is a future explicit re-enrollment operation.
- QR JSON contains `service`, `version: 3`, numeric IPv4 host, port, full public certificate, its SHA-256 fingerprint, a 256-bit random enrollment nonce and display expiry. It contains no reusable device token or private key.
- Android validates the certificate against the scanned fingerprint before using it as an explicit trust anchor. Its own per-Mac TLS client checks certificate validity/signature, normal trust-chain validation and the exact certificate pin. The IP/hostname is routing information; the scanned certificate is the peer identity. No global certificate trust store is changed.
- Certificate pin changes create a new client/pool. Redirects and plaintext URLs are rejected. Token-bearing cancellation uses the same secure transport as upload/download.
- A valid nonce is consumed once, before local Mac approval. The server also validates the protocol version, phone metadata and confirmation-code format, and limits pairing attempts.
- Following approval, Mac issues a 256-bit bearer token inside TLS. It stores the token in Keychain and only a credential reference in JSON. Android encrypts the token using an Android Keystore AES-GCM key and atomically saves token/certificate/pin/endpoint metadata.
- Authentication is **TLS server identity plus a per-phone bearer token**, not mutual TLS or hardware-backed phone key proof. Android ID remains a device label for grouping/re-pairing, not an authentication secret. A stolen usable token remains a credential until revoked; this design does not protect a fully compromised endpoint.
- The six-digit comparison is a local intent check, not a claim that a caller-generated number independently authenticates TLS. The scanned certificate, random one-time nonce and TLS validation provide the binding.
- Legacy paired records remain visible if data is retained, but their tokens cannot authenticate. Fresh installs avoid this compatibility state. No history/file conversion is needed to use the wire protocol.

## Implementation files

Mac:
- `TLSIdentity.swift`: Keychain identity and self-signed X.509 creation.
- `TLSSocketBridge.swift`: bounded TLS-to-AF_UNIX bridge for the existing HTTP parser. Plain HTTP bytes stay in a local kernel socketpair, never on the network.
- `SecurePairing.swift`: in-memory enrollment lifecycle and nonce verification.
- `PairingQRCode.swift` / `SecurePairingView.swift`: QR generation and settings UI.
- `HTTPServer.swift`: TLS listener, secure enrollment and device authentication.
- `TrustedDeviceStorage.swift`: Keychain token references and secure-pairing metadata.

Android:
- `security/MacTransport.kt`: explicit per-Mac trust anchor/pin and TLS client factory.
- `security/PairingEnrollment.kt`: bounded QR input parsing.
- `security/PairingSecretStore.kt`: Keystore encryption and atomic metadata commit.
- `network/MacClient.kt` / `transfer/BucketTransferClient.kt`: all endpoints routed through the transport.
- `MainActivity.kt`: scan/paste pairing and camera permission handling.
- QR scanner uses JourneyApps ZXing Android Embedded 4.3.0, Apache-2.0. It works locally without Google Play Services. Keep its license notice with app notices.

## Testing

`Tests/SecureTransportHarness/run.sh` starts an isolated loopback TLS server on **15769**, with a temporary Keychain identity and fake ClipStore. It never loads the user's Mac history/pairing tokens. Python checks TLS, public-CA rejection of the self-signed identity before enrollment, browser rejection, legacy-token rejection, one-use QR pairing, encrypted parallel bucket uploads, duplicate completion, revocation and rejection of plaintext HTTP.

For real Kotlin/Swift client interoperability:

```
CLIPTOMAC_ANDROID_PROJECT=/Users/ved/AndroidStudioProjects/cliptomac-android sh Tests/SecureTransportHarness/run.sh
```

For the explicitly selected physical phone as well:

```
CLIPTOMAC_ANDROID_PROJECT=/Users/ved/AndroidStudioProjects/cliptomac-android CLIPTOMAC_ANDROID_SERIAL=VSMBTSVWI75LJRR8 sh Tests/SecureTransportHarness/run.sh
```

The device run installs with `-r`, uses ADB reverse only for fixture port 15769, and sends fixture data to app-private test cache. It does not replace actual pairing preferences or add clips to the user's Mac library. Five device tests passed (including the final certificate-persistence build): credential migration/encryption/tamper rejection, speed/ETA behavior, actual QR decode at 260 px, secure enrollment/replay/revocation, real two-worker bucket upload (10 MiB + 123 bytes), download (16 MiB + 123 bytes) with checksum verification/ACK, and existing delayed-handshake/live-progress tests. This is not a new 5 GiB throughput or Wi-Fi benchmark.

Four JVM tests also passed against the Swift TLS fixture: invalid pins, malicious QR authority input, certificate validation, and actual Kotlin pairing/text/revocation. Camera preview interaction and the real Mac approval dialog still need a user walkthrough; the fixture's Mac approval is an isolated test stub.

Debug instrumentation has a **127.0.0.1-only** plaintext exception for old parser fixtures. Its TestHttpTransport is compiled into the test APK only. The release manifest has no such exception, and all application transport clients forbid plaintext. The raw Swift parser fixture is only compiled with `CLIPTOMAC_TRANSFER_TEST`; the production build does not set this flag.

## Before selling

This milestone closes the plaintext transport and unverified-first-contact design gaps. It is not a security certification or a completed commercial release.

Certificate signing requires explicit authorization and a `CLIPTOMAC_SIGN_IDENTITY` opt-in. The build does not discover/select developer identities automatically. Default builds are ad-hoc and can trigger Keychain access prompts after changes. A local build was signed with the installed Apple Development identity before the user objected; further certificate use and signed-build deployment are paused pending approval.

Still required: customer Developer ID signing/notarization, signed Android release and updates, independent review of the enrollment/certificate/server implementation, hostile-network/fuzz/resource-exhaustion testing, disk quotas/partial-transfer retention, untrusted-file handling, history/attachment encryption policy, privacy/permission/store-policy review, and a supported-device/OS test matrix. Optional stronger device proof using enrolled client keys/mTLS can be a separate protocol phase.

Primary references:
- Apple local-network TLS: https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls
- Android TLS: https://developer.android.com/privacy-and-security/security-ssl
- Scanner documentation/license: https://github.com/journeyapps/zxing-android-embedded

Mac settings scrolling was also constrained/clipped to its content region, with scroll indicators enabled and the settings position reset to the secure-pairing section on reopen. Header/footer remain separate from the scroll area.
