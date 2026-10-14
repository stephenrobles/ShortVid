#!/bin/bash
# Xcode "Run Script" phase: copies yt-dlp, ffmpeg, ffprobe and deno from Vendor/bin
# into ShortVid.app/Contents/Helpers and signs each one with the same identity
# as the app, hardened runtime on, so the bundle passes notarization.
set -euo pipefail

SRC="${SRCROOT}/Vendor/bin"
DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

mkdir -p "$DEST"

for tool in yt-dlp ffmpeg ffprobe deno; do
  if [ ! -x "$SRC/$tool" ]; then
    echo "error: $SRC/$tool is missing. Run Scripts/fetch-tools.sh first." >&2
    exit 1
  fi

  # Skip the copy + sign when the bundled copy is already newer than the source.
  if [ -f "$DEST/$tool" ] && [ "$DEST/$tool" -nt "$SRC/$tool" ]; then
    continue
  fi

  cp -f "$SRC/$tool" "$DEST/$tool"
  chmod 755 "$DEST/$tool"
  xattr -c "$DEST/$tool"

  SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
  if [[ "$IDENTITY" == *"Developer ID"* ]] || [[ "${CODE_SIGN_IDENTITY:-}" == *"Developer ID"* ]]; then
    SIGN_ARGS+=(--timestamp)
  else
    SIGN_ARGS+=(--timestamp=none)
  fi
  case "$tool" in
    yt-dlp)
      # yt-dlp is a PyInstaller bundle that unpacks its own Python dylibs at
      # runtime; hardened runtime needs library validation relaxed for that.
      SIGN_ARGS+=(--entitlements "${SRCROOT}/Scripts/yt-dlp.entitlements") ;;
    deno)
      # V8 needs JIT under the hardened runtime.
      SIGN_ARGS+=(--entitlements "${SRCROOT}/Scripts/deno.entitlements") ;;
  esac

  codesign "${SIGN_ARGS[@]}" "$DEST/$tool"
  echo "Bundled and signed $tool"
done
