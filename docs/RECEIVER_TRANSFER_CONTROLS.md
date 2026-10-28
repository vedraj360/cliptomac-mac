# Receiver controls

Mac popover and Library expose Pause, Resume and Cancel for Android-to-Mac file uploads. The authenticated control endpoint is scoped to the requesting device. Android polls it once per second only while an upload is live; pausing cancels in-flight upload calls and preserves bucket receipts. Mac Resume reopens the upload gate. Cancel stops Android retries and removes unfinished Mac payloads. The original Android source file is kept.

Control decisions are persisted without authentication tokens in `incoming-transfer-controls.json`. Cancellation markers prevent late requests from recreating cancelled transfers. Startup restores pending transfers and removes cancelled temporary payloads left by an interrupted cleanup. Final verification disables receiver actions to prevent a late UI action from undoing a committed file.

The host-side Android tests exercise remote pause, resume, cancellation and active-call cancellation. The native protocol harness exercises the Mac action methods through actual HTTP bucket requests, receiver isolation, paused write rejection, cancellation commit rejection, durable state and cleanup.

# Local signing

The developer explicitly approved the existing Apple Development identity for local builds. Its fingerprint is stored only in ignored `.local-signing-identity`; the build script does not automatically select certificates. `CLIPTOMAC_SIGN_IDENTITY` overrides that local choice, including an explicit empty value for ad-hoc signing. No certificate private key is exported or bundled.

Stable certificate signing preserves the designated app requirement between builds. Existing Keychain items may still prompt during the first switch from ad-hoc signing; their protection and access rules have not been weakened. This configuration does not publish or notarize the app.
