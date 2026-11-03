# Open source release review

Scope: Android and macOS source, recent notification changes, tracked asset and credential filenames, selected secret signatures in Git history, and release documentation.

| Priority | Finding | Release action |
| --- | --- | --- |
| High | [HTTPServer](../Sources/HTTPServer.swift) reads and buffers request bodies before route authentication. A peer on the local network can occupy request slots without pairing. Path limits and deadlines bound each request. | Authenticate protected routes before reading their bodies. Exercise slow unauthenticated requests alongside legitimate transfers. |
| Medium | The Android WhatsApp relay infers ownership for some updates from missing sender identifiers and notification flags. An incoming message can share those traits. A cloned WhatsApp profile can also post a separate incoming alert. | Test incoming, outgoing, inline reply and cloned profile cases. Make any profile or conversation exclusions explicit. |
| Medium | The Android sync engine logs raw exceptions from clip refresh. Exception messages can include file paths or endpoint details. | Log safe error categories and review production logs with synthetic data before sharing diagnostics. |
| Release blocker | Neither repository has a project license or configured GitHub remote. Bundled notices cover specific third-party assets. | Choose a project license, confirm asset provenance, and supply the repository destinations. |

The targeted history scan found no private key blocks, GitHub personal access tokens matching the selected prefix, or AWS access key IDs matching the selected pattern. A full secret and personal data scan, including binary assets and all publishable refs, is still required.

See [the security review](SECURITY_REVIEW.md) and [the pairing protocol](SECURE_PAIRING_V3.md) for the existing security model and remaining validation.
