#!/bin/bash
# Downloads the yt-dlp, ffmpeg, ffprobe and deno binaries that ShortVid bundles.
# Run from anywhere: ./Scripts/fetch-tools.sh [--nightly]
#   --nightly  takes yt-dlp from the nightly builds (yt-dlp/yt-dlp-nightly-builds)
#              instead of the latest stable release; nightlies carry YouTube fixes
#              weeks before the next release, and the app's updater knows both channels.
# Binaries land in Vendor/bin (git-ignored); the build copies and signs them.
set -euo pipefail

YTDLP_REPO="yt-dlp/yt-dlp"
for arg in "$@"; do
  case "$arg" in
    --nightly) YTDLP_REPO="yt-dlp/yt-dlp-nightly-builds" ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/bin"
ARCH="$(uname -m)"          # arm64 or x86_64
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ yt-dlp (official universal macOS build from $YTDLP_REPO)"
curl -fsSL -o "$DEST/yt-dlp" \
  "https://github.com/$YTDLP_REPO/releases/latest/download/yt-dlp_macos"

echo "→ ffmpeg + ffprobe (static $ARCH builds from ffmpeg.martin-riedl.de)"
for tool in ffmpeg ffprobe; do
  curl -fsSL -o "$TMP/$tool.zip" \
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$ARCH/release/$tool.zip"
  unzip -o -q "$TMP/$tool.zip" -d "$TMP"
  mv -f "$TMP/$tool" "$DEST/$tool"
done

echo "→ deno (JavaScript runtime yt-dlp uses for YouTube)"
case "$ARCH" in
  arm64)  DENO_ASSET="deno-aarch64-apple-darwin.zip" ;;
  x86_64) DENO_ASSET="deno-x86_64-apple-darwin.zip" ;;
esac
curl -fsSL -o "$TMP/deno.zip" \
  "https://github.com/denoland/deno/releases/latest/download/$DENO_ASSET"
unzip -o -q "$TMP/deno.zip" -d "$TMP"
mv -f "$TMP/deno" "$DEST/deno"

chmod 755 "$DEST"/yt-dlp "$DEST"/ffmpeg "$DEST"/ffprobe "$DEST"/deno
xattr -c "$DEST"/yt-dlp "$DEST"/ffmpeg "$DEST"/ffprobe "$DEST"/deno

echo
echo "Installed to $DEST:"
echo "  yt-dlp  $("$DEST/yt-dlp" --version)"
echo "  ffmpeg  $("$DEST/ffmpeg" -version | head -1 | cut -d' ' -f3)"
echo "  ffprobe $("$DEST/ffprobe" -version | head -1 | cut -d' ' -f3)"
echo "  deno    $("$DEST/deno" --version | head -1 | cut -d' ' -f2)"
