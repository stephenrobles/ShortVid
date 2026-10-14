#!/bin/zsh
# Builds a Release app signed with Developer ID (helpers included, via the bundle-tools.sh
# run-script phase, and Sparkle's nested code re-signed inside-out), optionally notarizes it,
# packages a DMG, and optionally publishes it on beardfm.app: the download for new users plus a
# Sparkle update for existing users. Nothing here deploys the site: run `npm run deploy` there yourself.
#
# Usage:  Tools/release.sh [--notarize] [--publish]
#   --notarize   uses the notarytool keychain profile in $NOTARY_PROFILE (default "ipodpromax-notary",
#                the team-wide profile shared with the other beardfm.app apps). Create one with:
#                xcrun notarytool store-credentials <name> --apple-id you@example.com --team-id J9228F689B
#   --publish    (requires --notarize) uploads the DMG to the beardfm.app R2 bucket (beardfm-downloads) as
#                ShortVid-<version>.dmg and ShortVid.dmg, which the site's worker serves at /downloads/<name>,
#                signs the DMG for Sparkle with the EdDSA key in the keychain (account "shortvid"), and adds it
#                to site/static/shortvid/appcast.xml (with release-notes/<version>.html if present).
#                The DMG is too big for the site's static assets (25 MiB per file), so it never goes in
#                site/static/downloads. Update the version and size on site/pages/shortvid.html by hand,
#                then deploy the site so the appcast (and with it the update) goes live.
#
# Output: dist/ShortVid <version>.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SITE="${BEARDFM_SITE:-$HOME/Movies/Apps/beardfm.app}"
NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --publish) PUBLISH=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done
[[ $PUBLISH -eq 1 && $NOTARIZE -eq 0 ]] && { echo "--publish requires --notarize so users never get an unnotarized build."; exit 1; }
NOTARY_PROFILE="${NOTARY_PROFILE:-ipodpromax-notary}"

DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
[[ -n "$DEVID" ]] || { echo "No Developer ID Application certificate found in the keychain."; exit 1; }
for tool in yt-dlp ffmpeg ffprobe deno; do
  [[ -x "$ROOT/Vendor/bin/$tool" ]] || { echo "Vendor/bin/$tool is missing. Run Scripts/fetch-tools.sh first."; exit 1; }
done

BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

# Xcode signs the app and, through Scripts/bundle-tools.sh, each helper with this identity,
# hardened runtime and the helpers' entitlements.
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps the "build" action from adding get-task-allow,
# which notarization rejects, and OTHER_CODE_SIGN_FLAGS adds the secure timestamp notarization
# requires (the "archive" action does both on its own).
echo "▶ Building Release, signing with $DEVID…"
xcodebuild -project "ShortVid.xcodeproj" -scheme "ShortVid" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD/DerivedData" build \
  CODE_SIGN_IDENTITY="$DEVID" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
  2>&1 | grep -E "error:|Bundled and signed|BUILD (SUCCEEDED|FAILED)" || true

APP="$BUILD/DerivedData/Build/Products/Release/ShortVid.app"
[[ -d "$APP" ]] || { echo "Build failed: app not found"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILDNUM=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "▶ Version $VERSION ($BUILDNUM)"

# Sparkle ships pre-signed; re-sign its nested code inside-out (per Sparkle's docs) with our identity,
# hardened runtime and a timestamp, then the app once more so its seal covers the re-signed framework.
# The helpers in Contents/Helpers keep the signatures and entitlements bundle-tools.sh gave them.
echo "▶ Signing Sparkle…"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework is missing from the app."; exit 1; }
sign() { codesign --force --options runtime --timestamp --sign "$DEVID" "$@"; }
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign "$APP"

echo "▶ Verifying signatures…"
codesign --verify --strict --deep --verbose=2 "$APP"
for item in "$APP" "$APP"/Contents/Helpers/* "$SPARKLE" "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" \
            "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"; do
  info=$(codesign -dvv --entitlements - "$item" 2>&1)
  [[ "$info" == *"flags="*"(runtime)"* ]] || { echo "$item is not signed with the hardened runtime"; exit 1; }
  [[ "$info" == *"Authority=Developer ID Application"* ]] || { echo "$item is not signed with Developer ID"; exit 1; }
  [[ "$info" != *"get-task-allow"* ]] || { echo "$item carries get-task-allow, which notarization rejects"; exit 1; }
  [[ "$info" == *"Timestamp="* ]] || { echo "$item has no secure timestamp, which notarization requires"; exit 1; }
done

if [[ $NOTARIZE -eq 1 ]]; then
  echo "▶ Notarizing app…"
  ZIP="$BUILD/app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "▶ Packaging DMG…"
STAGE="$BUILD/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/ShortVid $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "ShortVid" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" > /dev/null
codesign --force --timestamp --sign "$DEVID" "$DMG"
if [[ $NOTARIZE -eq 1 ]]; then
  echo "▶ Notarizing DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

if [[ $PUBLISH -eq 1 ]]; then
  [[ -f "$SITE/wrangler.jsonc" ]] || { echo "beardfm.app site not found at $SITE (set BEARDFM_SITE)."; exit 1; }
  SPARKLE_BIN=$(find "$BUILD/DerivedData/SourcePackages/artifacts" -type d -name bin -path "*parkle*" | head -1)
  [[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle's sign_update tool wasn't found."; exit 1; }
  echo "▶ Signing update for Sparkle…"
  SIGNATURE=$("$SPARKLE_BIN/sign_update" --account shortvid "$DMG")
  MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
  UPDATE_NAME="ShortVid-$VERSION.dmg"

  BUCKET="${R2_BUCKET:-beardfm-downloads}"
  for name in "$UPDATE_NAME" "ShortVid.dmg"; do
    echo "▶ Uploading $name to R2 bucket $BUCKET…"
    (cd "$SITE" && npx wrangler r2 object put "$BUCKET/$name" --file "$DMG" --content-type application/x-apple-diskimage --remote > /dev/null)
  done
  echo "▶ Live at https://beardfm.app/downloads/$UPDATE_NAME and /downloads/ShortVid.dmg (the worker serves them from R2)."

  echo "▶ Adding the update to the appcast…"
  NOTES=()
  [[ -f "$ROOT/release-notes/$VERSION.html" ]] && NOTES=("$ROOT/release-notes/$VERSION.html")
  "$ROOT/Tools/update-appcast.py" "$SITE/site/static/shortvid/appcast.xml" "$VERSION" "$BUILDNUM" "$MIN_MACOS" \
    "https://beardfm.app/downloads/$UPDATE_NAME" "$SIGNATURE" "${NOTES[@]}"
  echo "▶ Update $VERSION ($BUILDNUM) is in site/static/shortvid/appcast.xml. Update site/pages/shortvid.html, then deploy the site (npm run deploy) to offer it."
fi

ls -la "$DMG"
echo "✔ Done: $DMG"
