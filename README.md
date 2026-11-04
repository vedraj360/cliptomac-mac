# ClipToMac product site

This static site uses HTML and CSS. It has no build step or runtime dependencies.

## Preview locally

From this directory, run `python3 -m http.server 8000` and open `http://localhost:8000`.

## Product screenshots

Use real captures of the Mac Library, grouped Phone Notifications, and Android sharing or pairing. Capture with sample content and check that no contact information, private paths, QR codes, or device identifiers are visible before adding images to `assets/`.

## Publish on GitHub Pages

After the release review, publish the contents of this directory at the root of a dedicated Pages branch or repository. In GitHub, open **Settings → Pages**, choose **Deploy from a branch**, and select that branch and the root folder. Keep the included `.nojekyll` file. Use the published URL shown by GitHub Pages.

## Offer direct downloads

Attach the Android APK to the Android repository's GitHub Release and the Mac ZIP to the Mac repository's GitHub Release. Use stable asset names, such as `ClipToMac-android.apk` and `ClipToMac-macos-arm64.zip`. Once both assets are published and tested from their public URLs, add **Download for Android** and **Download for Mac** to the landing page. Keep the source install guides in Setup.

### Android APK

1. Run `./gradlew :app:assembleRelease` in the Android repository. The current release build produces `app/build/outputs/apk/release/app-release-unsigned.apk`.
2. Use the Android SDK's `zipalign` before signing. Sign the aligned APK using `apksigner` and the project's release keystore. Keep the private key out of the repositories and use the same release key for updates.
3. Run `apksigner verify --verbose --print-certs ClipToMac-android.apk`. Install the APK on a test device, pair with the Mac, and send a sample clip in both directions. Also test updating an existing release install once one is available. A differently signed debug install cannot be updated in place with the release APK.

### Apple silicon Mac ZIP

1. Run `./build.sh` with `CLIPTOMAC_SIGN_IDENTITY` set to the **Developer ID Application** signing identity. Use the `ClipToMac.app` at the build path printed by the script.
2. Create a ZIP with `ditto -c -k --keepParent ClipToMac.app ClipToMac-macos-arm64.zip`. Submit the ZIP with `xcrun notarytool submit ClipToMac-macos-arm64.zip --keychain-profile PROFILE --wait`.
3. After Apple accepts the submission, run `xcrun stapler staple ClipToMac.app` and `xcrun stapler validate ClipToMac.app`. Recreate the ZIP from the stapled app and test opening a browser-downloaded copy on a clean Apple silicon Mac.
