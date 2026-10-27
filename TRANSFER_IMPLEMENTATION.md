# ClipToMac transfer implementation

## Implemented protocol

The Mac listens on the existing port 5678. Existing `/ping`, `/pair/request`, `/clip`, and `/clip/batch` routes remain. All device routes require an exact nonempty paired-device token in `X-ClipToMac-Token`; unpair is authenticated too. `/pair/request` remains the native user-approved pairing flow.

- `POST /transfer`: raw bytes with an exact `Content-Length`, maximum 25 MiB. `X-ClipToMac-Metadata` is base64 JSON containing `transferId`, `kind` (`text`, `image`, or `file`), `mimeType`, `name`, `app`, `package`, `timestamp`, `size`, and optional `sha256`. Text is UTF-8 in the body. Repeated attempts with the same ID are acknowledged idempotently.
- `GET /inbox`: authenticated device-specific JSON array of queued Mac-to-Android metadata.
- `GET /download/{transferId}`: authenticated binary bytes for that device's queued item.
- `POST /inbox/ack`: JSON `{ "ids": ["..."] }`; only that device's acknowledged items are removed and history is marked delivered.

The Mac persists its outbound inbox at `Application Support/ClipToMac/transfer-inbox.json`, and managed attachment copies live under the configured attachment directory. Android captures share URIs into its private `files/attachments` folder, downloads to a `.part` file, verifies declared length and SHA-256, atomically renames, writes the local library before ACK, and keeps a transfer attempt ledger so retries do not recreate deleted entries. Receiving never writes to Android's clipboard. Copy remains a user action.

## APIs

- Mac: `MacTransferService.shared.sendText(_:to:)`, `sendFile(_:to:)`, and `cancel(id:)`; `outboundItems` is observable with per-attempt state/progress.
- Android: `AttachmentStore.importUri/openUri/saveToTree`; repository pin, collection, bulk delete/undo, safe import, and transfer ledger APIs; `SyncEngine.sendExistingClip`, `receivePendingClips`, `enqueueAttachment`; `TransferProgress.observe/cancel`.

Logical duplicate rows are grouped by content and source while a per-attempt transfer ID keeps retries idempotent and intentional resends distinct. Transfers over 25 MiB are rejected. The HTTP parser reads complete bounded bodies, rejects chunked framing and duplicate headers, applies socket timeouts, and sends complete responses despite partial socket writes.

## Isolated protocol harness

`Tests/TransferProtocolHarness/run.sh` compiles the real Mac HTTP and transfer sources with a test-only `ClipStore` stub. `CLIPTOMAC_TRANSFER_TEST` redirects the service inbox into a unique temporary directory. The harness exercises fragmented requests with a binary body above 64 KiB, checksum and size rejection, authentication, per-device inbox/download isolation, retry idempotence, and ACK removal. It does not open or mutate the user's ClipToMac library. Run it with:

```sh
./Tests/TransferProtocolHarness/run.sh
```

## Remaining integration verification

Build and protocol harness execution are delegated to the parent integration pass. Device installation and live-phone tests are intentionally excluded. Android UI actions, transfer cancellation during device shutdown, and inbound transfers while the app is force-stopped still need end-to-end device verification.
