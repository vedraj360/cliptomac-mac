# ClipToMac for macOS

ClipToMac pairs a Mac with an Android phone so you can move text, links, images, and files over your local network. The Mac library lets you search clips and pin items. You can also opt in to mirror Android notifications from selected apps.

## Build and pair

Requires macOS 13 or later and the Xcode command line tools.

```sh
xcode-select --install
./build.sh
```

Open the app bundle at the path printed by the build. Use the ClipToMac menu bar icon or the library to start pairing. Scan the Mac’s QR code in the Android companion from the `cliptomac-android` repository while both devices are on the same local network. Try sending a link in each direction.

## Privacy and security

Pairing uses a one-use QR code and HTTPS pinned to the Mac identity. The Mac stores pairing credentials in Keychain. Clip history is kept locally, and mirrored notification previews can appear in macOS Notification Center. See the [pairing protocol](docs/SECURE_PAIRING_V3.md) and [security review](docs/SECURITY_REVIEW.md) for the threat model and remaining release validation.

## Contribute

Read [AGENTS.md](AGENTS.md) and [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md). Build the app and run the Swift regression harnesses:

```sh
for harness in Tests/*/run.sh; do bash "$harness" || exit 1; done
```

Use synthetic clips and redact QR codes, tokens, message previews, and private paths from reports. A project license is pending. Brand icon notices are in [Assets/BrandIcons](Assets/BrandIcons/LICENSE.md).

## Website

The static product site lives in [site/](site/). See its [publishing guide](site/README.md) for GitHub Pages setup.
