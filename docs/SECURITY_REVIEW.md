# ClipToMac security review — 27 October 2026

**Update: pinned TLS and one-use QR pairing are now implemented and tested; see [Secure pairing v3](SECURE_PAIRING_V3.md). The findings below describe the audit baseline and remaining release work.**

**Release decision: do not sell the current build as a secure product.** This is a source review and targeted hardening, not a penetration test or security certification. No system can promise that it cannot be hacked. The original main blocker was unencrypted HTTP transport, including pairing; that gap is addressed by v3. Commercial release validation and signing remain incomplete.

## Scope and attacker model

Reviewed the Swift TCP/UDP servers, pairing and credential persistence, transfer routing, bucket staging, Android clients, exported entry points, backup configuration, and release configuration. Consider attackers on the same network, a malicious website, an ordinary local Mac account, a malicious Android app, and a compromised paired device. A rooted phone, compromised logged-in account, or administrator can exceed these protections.

There is no confirmed device compromise from this review. Possession of a bearer token grants access to ClipToMac's sync endpoints; it is not itself an operating-system login. Exploiting other bugs is a separate risk. SHA-256 bucket checksums detect corruption; without an authenticated channel they do not establish sender identity or prevent an active attacker replacing both bytes and hashes.

## Implemented in this round

| Finding | Change | Boundary |
| --- | --- | --- |
| Mac bearer tokens were plaintext in `trusted_devices.json` | Production storage uses macOS Keychain; JSON stores device metadata and an opaque credential reference. Existing credentials migrate after successful Keychain writes. | Existing tokens are not automatically rotated. Old backups may retain plaintext. Stable production signing remains necessary for predictable Keychain access across updates. |
| Android bearer token was plaintext in SharedPreferences | AES-GCM encryption with a random IV, fixed application-specific authenticated data, and a non-exportable Android Keystore key; successful migration removes the legacy preference. | Hardware backing depends on the device. Already-running app processes still need credentials in memory. Missing/invalid credentials fail closed. |
| Mac app support directory was mode 0755 and credential file mode 0644 | App-owned storage is restricted to 0700 directories/0600 files; private JSON writes create a 0600 temporary file and atomically rename it. Existing live metadata modes were restricted. | Does not protect against the same compromised login, administrator, inherited ACL exceptions, or user-exported files. No permissions are changed on a user-selected export directory. |
| Android automatic backups could include sensitive app data | Backup disabled; explicit legacy and Android 12+ cloud/device-transfer exclusions added. | Does not retroactively erase backups already created. Deliberate user exports remain separate. |
| Redirects could forward the custom authentication header to another endpoint | Both Android HTTP clients disable HTTP and HTTPS redirects, including derived pairing/inbox clients. | Does not prevent an attacker impersonating the original HTTP endpoint. |
| Browser access was unnecessarily enabled by wildcard CORS | Removed wildcard CORS and reject Origin/Sec-Fetch-Site requests and OPTIONS; added no-store/nosniff responses. | Browser restriction is defense in depth, not authentication; a native attacker can omit these headers. |
| Unbounded pairing prompts / loose pairing inputs | One outstanding pairing prompt, at most three attempts per rolling minute, bounded/validated device name, ID and six-digit code. New tokens use 32 cryptographically random bytes; phone display codes use SecureRandom. Credential-save failure cannot return pairing success. | Still legacy pairing: caller-supplied code/name is not cryptographic verification. Global limits can be abused to delay legitimate pairing briefly. |
| Long-poll inbox requests could monopolize six server slots | Limit to two pending inbox waits, returning 429 for excess; request reads have an elapsed-time bound and pairing bodies have a 4 KiB bound. | This custom server still needs stronger pre-body authentication, peer limits and denial-of-service testing. More than two phones may temporarily fall back/retry. |
| Legacy text/small-transfer retry IDs were global | Scope new incoming transfer IDs to the authenticated device, matching bucket-transfer isolation. | Retrying a pre-upgrade legacy ID uses the new namespace; content grouping remains, but the first such retry may count as another explicit send. |
| Public ping/discovery exposed paired-phone names | Removed those names; discovery uses proper JSON encoding and exact request matching. | Mac name/address and service presence remain discoverable; UDP is not a trusted identity source. |

Unpairing and replacement remove unused Keychain secrets after metadata commits. Failed Keychain/metadata writes roll back new secrets and preserve the previous pairing. If credential loading fails, further metadata writes are blocked so re-pairing cannot silently overwrite inaccessible existing credentials. Test-only isolated stores do not access production credentials.

The receive cue was also changed from Pop/beep to a quieter built-in Tink sound, respecting the sound setting.

## Audit roadmap (P0 transport/QR enrollment subsequently implemented by v3; other items remain)

### P0: encrypted transport with authenticated peer identity — implemented; release audit pending

1. Replace plaintext TCP HTTP with TLS using platform implementations (Network.framework on Mac and OkHttp's supported TLS stack on Android). Prefer TLS 1.3; permit only an explicitly justified minimum such as TLS 1.2. Do not invent encryption or use a trust-all certificate callback.
2. Pin the Mac's public identity during a verified enrollment flow. An IP address, Android ID, display name or discovery response is never proof of identity. IP changes must preserve the pin; unexpected identity changes must require explicit re-pairing.
3. Carry all content, filenames, manifests, hashes, acknowledgements and credentials inside the authenticated encrypted connection. Disable legacy HTTP transfer/pairing in the shipping build. Never fall back to HTTP after TLS/pin failures.
4. Ensure any diagnostic protocol fixtures remain isolated test-only services. Raw socket servers are not protected automatically by Apple's App Transport Security rules.

Acceptance: packet capture reveals no tokens/content; a substituted certificate, spoofed discovery response, changed pin and downgrade attempt all fail. Normal discovery/IP changes and large-file resume still work.

### P0: replace legacy pairing with verified enrollment — QR/TLS + token implemented; client-key/mTLS proposal deferred

Recommended customer flow:

1. User opens **Pair a device** on the Mac; a short enrollment window begins.
2. Mac shows a QR containing its public-key fingerprint, endpoint, protocol version and a random, short-lived, single-use enrollment nonce. It does not contain a reusable bearer token.
3. Phone scans it, verifies the Mac's TLS identity against the fingerprint, and generates its own signing/client key in Android Keystore.
4. Use a standard TLS client-authentication enrollment design with proof of possession of that key. Bind enrollment to the nonce, the verified Mac identity, and local user approval. No caller-provided six-digit number should be treated as cryptographic verification.
5. Mac lists the paired phone and supports immediate revocation. Subsequent sync uses enrolled client identity (prefer mutual TLS), not a device name or Android ID. Separate enrollment-only access from authenticated transfer access.
6. Reject reused/expired nonces, unexpected peer keys and pairing while the local window is closed. Review the exact enrollment design before implementation; do not implement an improvised key-exchange protocol.
7. After this is in place, require secure re-enrollment/rotation of credentials exposed by the old HTTP design. Clearing app data loses the phone's key and requires a new enrollment; stable Android ID remains a useful label, not a secret.

Acceptance: fake Mac/phone, replay, expired enrollment, concurrent enrollment, changed device key and revoked device tests; visible confirmation cannot approve a different cryptographic peer.

### P1: resource exhaustion and transfer authorization

- Bound concurrent transfers per paired device, cumulative reserved staging space and pending requests. Check disk headroom throughout streaming, including unknown-size provider streams; preserve multi-gigabyte transfers rather than imposing a tiny size limit.
- Expire abandoned partial transfers by a clear retention policy; delete completed staging only after durable history/receipt commits. Completed receipt cleanup remains separate unfinished work from the earlier transfer task.
- Authenticate before accepting large request bodies; per-peer limits and stronger slow-client protection. Prefer a maintained HTTP/TLS implementation to expanding the custom parser.
- Cancel/reject remaining work when a device is revoked; revalidate authorization at commit and download boundaries. Test parallel buckets during revocation, not just a request started afterward.
- Bound manifest bucket counts, response sizes and JSON collection counts to prevent pathological memory/CPU use, even from a compromised paired device.

### P1: local content, external entry points and privacy

- Decide the customer promise for history/file encryption at rest. Current history, transfer metadata, attachments and deliberate backups are not application-encrypted. OS disk encryption is useful but not the same as an app vault. Design resumable large-file encryption/streaming separately.
- Review exported Android Share/ProcessText handlers for confused-deputy and unsolicited-send behavior. Accept only appropriate actions and granted content URIs, validate inputs and offer a suitable confirmation boundary; do not break normal user-initiated sharing.
- Audit logs and notification previews for sensitive text/filenames; provide a private-preview setting and sensible retention/clear-data controls. Never log tokens or clipboard contents.
- Treat received files as untrusted: no automatic execution, safe previews/open behavior, platform quarantine/origin metadata where appropriate, path traversal/symlink tests, and safe filename/extension handling.
- Document clipboard/accessibility collection clearly; preserve explicit sending and give exclusions for sensitive apps. Avoid claiming every Android app/device permits identical capture behavior.

### P1: commercial distribution and policy

- Ship a signed, non-debug Android release using a protected release signing key. The currently built APK is a debug artifact, not a customer release.
- Mac currently has only an ad-hoc linker signature, no Developer ID/team identity and no sealed-resource distribution signature. Establish Developer ID signing, hardened runtime, notarization, and signed updates before selling. Use the same stable identity for Keychain access across updates.
- Review broad package visibility, both exact-alarm permissions, accessibility disclosure/consent, overlay behavior and background-service use against current Play policy. Approval is not guaranteed. Do not designate this as a disability accessibility tool unless that is its actual primary purpose.
- Publish a privacy policy/data-retention statement, incident-response/contact process and supported OS/device matrix. Inventory dependencies, review vulnerabilities and licenses, and secure build/update credentials.
- Commission an independent penetration test after the transport/enrollment redesign; include hostile-LAN, parser/fuzz, stolen-token, multi-device isolation, revocation, malicious-share and large-transfer tests. Passing our regression tests is not a substitute.

## Audit-baseline validation and deployment status (superseded by v3 notes)

- Mac SecurityHarness passed: isolated real Keychain write/read/removal; fake-vault legacy migration, rotation/revocation, failure rollback, missing-secret rejection, overwrite prevention, permissions, pairing validation/rate limits, random token length.
- Mac LibraryStoreHarness passed: history migration, pins/collections, backup/reload, deletion/Undo/original-file protection and stable device identity.
- Mac TransferProtocolHarness passed: auth/isolation, browser rejection, malformed pairing, public ping privacy, two-waiter capacity limit, same wire ID across two devices, checksums, resume, duplicate handling and sparse offsets above 5 GiB. This is not a new full 5 GiB throughput benchmark.
- Android debug app/test APK builds and lint passed. New CredentialSecurityTest covers encrypted migration, fresh IVs, tampering/no-plaintext-fallback, clearing, and progress-estimator behavior. These new instrumented tests are **not yet run on the phone** because ADB disconnected during this round.
- Mac and Android build artifacts are prepared. The running apps were not restarted/reinstalled in this round; credential migration occurs on the next updated app launch. Existing live Mac file modes were hardened without reading or changing credential values.
- Keychain smoke-test entries are removed by the harness. Temporary logs/test fixtures from this round are cleaned after results are recorded; source tests and final app artifacts are retained.

## Primary references

- Android Keystore: https://developer.android.com/privacy-and-security/keystore
- Android TLS guidance: https://developer.android.com/privacy-and-security/security-ssl
- Android Network Security Configuration: https://developer.android.com/privacy-and-security/security-config
- Apple Keychain: https://developer.apple.com/documentation/security/using-the-keychain-to-manage-user-secrets
- Apple notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Google Play sensitive permissions: https://support.google.com/googleplay/android-developer/answer/16558241
- Google Play accessibility: https://support.google.com/googleplay/android-developer/answer/10964491
- Google Play package visibility: https://support.google.com/googleplay/android-developer/answer/10158779
