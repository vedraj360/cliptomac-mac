# ClipToMac SQLite migration plan

Use one local, versioned SQLite database per installation. Use SQLite through a Swift repository on Mac and Room on Android. The two apps can evolve their schemas independently and continue exchanging the same network payloads.

## Implementation status

Mac clip history and incoming receipts use typed SQLite rows in `library.sqlite3`. Android clip history, the send queue and incoming receipts use typed Room rows. Both platforms now also persist their app-owned transfer controls, checkpoints, pending deletions, preferences and pairing metadata in SQLite. Mac transfer inbox and phone notification history use the same database. Lower-volume stores retain serialized records inside SQLite. Existing file bytes, protected secrets, and OS-owned settings stay in their existing locations.

Legacy data is imported on first access. The database records a completed import, including an empty store, to prevent legacy state from replaying after a clear. Legacy files remain available for recovery where applicable, with plaintext pairing credentials scrubbed after migration to protected storage. Synchronous repository calls still need a background I/O pass. The production upgrade and paired-device interoperability checks are separate from fixture tests.

## Storage scope

| Data | Mac sources | Android sources | Destination |
| --- | --- | --- | --- |
| Clips and delivery history | `history.json` | `clips_queue.json` | Clip rows, stable IDs, timestamps, source apps, directions, pins, collections and attachment references |
| Send and receive state | `transfer-inbox.json`, `seen_transfer_ids.json`, incoming transfer controls | Queue entries, received transfer IDs and transfer controls | Transfer jobs, delivery receipts and retry records. Commit a received clip and its receipt in one transaction. |
| Partial transfers and pending deletions | Bucket receipts and attachment deletion schedule | Bucket ledgers and attachment deletion records | Transfer checkpoints and pending file operations. Keep partial file bytes on disk. |
| Notification history and settings | Notification history JSON and preferences | Relay preferences and app selections | History rows where supported, retention limits, forwarding settings and selected apps |
| Preferences and pairing metadata | UserDefaults and trusted device records | SharedPreferences and pairing preferences | Typed preferences, paired device metadata, allowlists and opaque credential references |

Keep attachment and partial transfer bytes as files. Keep Keychain items and Android Keystore keys under platform protection. Pairing tokens must stay in Keychain on Mac or encrypted under the existing Keystore key on Android, even if the encrypted Android payload moves to a database row. Keep JSON support for existing backups and network payloads. SQLite alone does not encrypt clip history at rest.

## Implementation order

1. **Inventory and fixtures.** List every persistent field and its defaults, including shortcuts, notification consent, device pins, retry counters, deletion deadlines and references to partial files. Capture fixtures from current and older formats without real user content. Verify which preferences the OS owns before moving app settings.
2. **Build the storage layer.** Add schema versioning, foreign keys, unique constraints for existing receipt IDs and indexes for recent clips, queue scheduling and notification history. Keep storage behind the existing repository interfaces. Run disk work off the UI thread. Preserve search behavior before introducing full-text search.
3. **Import and verify.** Stop writers before opening the first-run import. Read the legacy files and preferences, validate them, then import related rows and the completion marker in one database transaction. Compare counts, stable IDs, timestamps, attachment references and credential access before switching the app to SQLite. Preserve the original files. A failed or interrupted import must be retryable without duplicates or silent data loss.
4. **Switch the repositories.** Move clip history and transfer state first, including interrupted jobs, receive receipts and retry behavior. Then switch partial-transfer checkpoints, pending deletions, notification history, preferences and pairing metadata. Use a recoverable pending-operation record when a database update also moves or deletes a file. Preserve unpairing and secret deletion behavior.
5. **Verify upgrades and recovery.** Test fresh installs and upgrades with empty, populated and older fixtures. Cover malformed files, low disk space, forced shutdown during import, duplicate receipts, interrupted transfers, pending deletions, notification retention, backups, and pairing after upgrade. Run both apps on real devices and verify transfers in both directions with one side upgraded first.
6. **Roll out and retire legacy writes.** Ship after migration and compatibility checks pass. If initialization fails before cutover, leave the originals available and report the error. After cutover, recover from the database or export current rows before rolling back to an old build. The preserved JSON files are a pre-upgrade snapshot and will not contain new writes. Remove legacy import code only after the supported upgrade window closes.

The migration is complete when both apps use SQLite for app-owned structured state, existing data survives upgrade and restart, and backup and transfer formats still interoperate.
