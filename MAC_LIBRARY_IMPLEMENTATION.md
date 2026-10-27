# Mac library implementation

## Phases

- **Local library model and storage:** Clip rows now carry kind, attachment metadata, transfer ID, direction, pin, collection, repeat count, update time, and delivery state. Decoding old history JSON supplies defaults for every new field. Duplicate transfer attempts are ignored by ID; distinct matching transfers update repeat counts. Attachments default to Application Support/ClipToMac/attachments.
- **Library and menu:** Added a resizable Library window with All, Pinned, Sent, Received, Text, Images, Files, collection, and source-app filters, search, multi-select pin/delete/export/collection actions, local delete Undo, and row copy/open/reveal/send actions. The status menu offers Open Library and a recent panel with app filters.
- **Sending and hotkey:** The Library can explicitly send the current Mac clipboard text, selected text, or a chosen file to a paired device using the transfer service API. A registered Carbon global hotkey opens or hides the Library; it does not monitor keyboard input.
- **Storage and backup:** Settings show the library directory and storage use, open Finder, choose a destination for future attachments, and import/export validated JSON backup packages that embed attachment bytes. Imports write attachments into the configured managed folder under generated names and ignore source paths in the package. Paired-device credentials are excluded.

## Validation

- Compile with ./build.sh after the transfer service source is integrated (build.sh compiles Sources/*.swift).
- Manual checks: open the menu and Library, resize the Library, exercise sidebar/search/pin/collection/multi-select/delete/Undo, copy or open a text clip, send clipboard text and a file to a paired phone, change the attachment destination, and round-trip a JSON backup.
- Migration check: launch with a copy of an older history.json and confirm existing clips load with default text/received/unpinned values. Do not replace the user's live history for this check.

## Limitations

- Mac UI automation permission was unavailable; no live UI automation or app restart was performed.
- App icons use installed bundle icons when macOS can resolve them and app-specific SF Symbols otherwise. No third-party branded artwork is bundled.
- Backup format is a bounded JSON package (25 MB per attachment, 100 MB total attachment bytes). Larger libraries must be split into multiple selected-item exports.
- Source apps resolve genuine installed bundle icons first, then bundled Simple Icons brand artwork for available brands, with SF Symbols as neutral fallback for apps without local assets.
- The shortcut picker exposes a small supported key set and three modifier combinations.
