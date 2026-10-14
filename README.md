# ShortVid

A small Mac app whose only job is to add a **Download Video** action to Shortcuts.
Give the action a URL, and it hands the downloaded video file to the next action,
Downie-style. It bundles [yt-dlp](https://github.com/yt-dlp/yt-dlp) for extraction
(YouTube, Vimeo, X, TikTok, Instagram, direct media links and hundreds more),
[ffmpeg](https://ffmpeg.org) for merging and conversion, and
[Deno](https://deno.com) as the JavaScript runtime yt-dlp needs for YouTube.

## The Shortcuts action

**Download Video** (category "Video")

| Parameter | Type | Notes |
| --- | --- | --- |
| URL | URL | A video page or a direct link to a media file. |
| Quality | Highest quality (default), 1080p, 720p, 480p | Caps the frame height yt-dlp will pick (`[height<=…]` in the format selector); the best streams that fit are used. If a site only offers larger streams, the best available is taken rather than failing. |
| Force MP4 | toggle, on by default | Deliver an H.264/HEVC + AAC MP4 that QuickTime and Photos can play. Streams that already fit are remuxed without re-encoding; anything else (VP9, AV1, Opus, MKV, WebM) is converted with ffmpeg, using the hardware encoder when possible. Off: whatever yt-dlp's best quality is, in its native container. |

Output: a **File**, which can go straight into Save File, Share, Quick Look, Save to Photos, etc.

Files are written to `~/Library/Caches/fm.beard.ShortVid/Downloads/<job>/` and swept
after 24 hours. Shortcuts copies the file wherever the next action puts it, so the
cache is only a staging area.

The app itself is just a status window: it shows the tool versions, has an
**Update yt-dlp…** button (see below), and a "Try it" field for testing a URL without
Shortcuts. Shortcuts launches the app hidden
when it runs the action; it does not need to be open. The app keeps itself current
with [Sparkle](https://sparkle-project.org): **ShortVid ▸ Check for Updates…**, plus a
daily automatic check.

## Building

1. Fetch the tool binaries (git-ignored, ~250 MB):

   ```bash
   ./Scripts/fetch-tools.sh
   ```

   This downloads the official yt-dlp macOS build, static ffmpeg/ffprobe builds from
   ffmpeg.martin-riedl.de, and the official Deno build for this Mac's architecture
   into `Vendor/bin`. Re-run it any time to pick up newer versions, then rebuild.

2. Build and run in Xcode (or `xcodebuild -scheme ShortVid`). The
   **Bundle yt-dlp & ffmpeg** run-script phase copies the four binaries into
   `ShortVid.app/Contents/Helpers` and signs each one with the app's identity and the
   hardened runtime. yt-dlp gets `disable-library-validation` (it is a PyInstaller
   bundle that unpacks its own Python dylibs) and Deno gets `allow-jit` (V8).

3. Launch the app once. Shortcuts picks up the action as soon as the app has been
   registered with Launch Services.

The app icon is generated, not drawn by hand: `swift Tools/make-icon.swift
ShortVid/Assets.xcassets/AppIcon.appiconset` rewrites the macOS icon set, and
`swift Tools/make-icon.swift --site shortvid.png` produces the 320 px tile the
website uses. `ShortVid/AppIcon.icon` is the same glyph as an Icon Composer icon
(a gradient fill plus `foreground.svg`), which macOS 26 and later render; keep
both in sync. Shortcuts draws a generic placeholder on the Download Video action
once it is placed in a shortcut: it loads icons for App Intents actions from the
app's App Store listing, and ShortVid has none. The action library and shortcut
tiles use the local icon and are fine.

The project is macOS-only and arm64-only, because the bundled helpers are arm64
builds. Intel support would just mean fetching x86_64 helpers and building universal.

## Distribution

This app can't go in the Mac App Store: it isn't sandboxed (it spawns bundled
binaries) and App Review guideline 5.2.3 forbids downloading from YouTube and
friends. Distribute it directly:

- The **Release** configuration signs with **Developer ID Application** (manual
  signing, team J9228F689B), including the helpers, so an archive is ready to notarize.
- `Tools/release.sh --notarize --publish` does the whole thing from the command line:
  Release build signed with Developer ID (Sparkle's XPC services, `Autoupdate` and
  `Updater.app` re-signed inside-out with the hardened runtime), notarize and staple the
  app, package `dist/ShortVid <version>.dmg`, notarize and staple that too, upload it to
  the beardfm.app R2 bucket as `ShortVid-<version>.dmg` and `ShortVid.dmg`, which the site
  serves at `/downloads/…` (the DMG is too big for the site's static assets), sign the DMG
  for Sparkle, and add it to the site's `site/static/shortvid/appcast.xml`.
  It uses the team-wide `ipodpromax-notary` keychain profile and never deploys the site;
  bump the version and size on `site/pages/shortvid.html`, then run `npm run deploy`
  there when the download and the update should go live.
- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` together before a release:
  Sparkle compares the build number (`CFBundleVersion`), so it has to grow every time.
- Updates are signed with an EdDSA key. The private key lives in the release Mac's
  keychain under the account `shortvid` (Sparkle's `generate_keys --account shortvid`
  made it; `generate_keys --account shortvid -x key.txt` exports it for another Mac),
  and the matching public key is `SUPublicEDKey` in `ShortVid/Info.plist`, next to
  `SUFeedURL` (`https://beardfm.app/shortvid/appcast.xml`). Release notes for an update
  go in `release-notes/<version>.html`; `Tools/update-appcast.py` embeds them in the
  appcast item, and the site's Latest Updates page reads them from there.

## Updating yt-dlp

yt-dlp changes often as sites change, and the copy in the bundle is frozen at build
time. Two ways past that:

- **In the app:** choose **ShortVid ▸ Update yt-dlp…** (or the button in the status
  window). The app downloads the latest official macOS build from GitHub into
  `~/Library/Application Support/fm.beard.ShortVid/yt-dlp`, marks it executable,
  strips any quarantine flag, and runs `yt-dlp --version` on it before swapping it
  into place atomically. The copy it replaces is kept as `yt-dlp.previous` and put
  back if the new one fails that check. From then on **Download Video** runs the
  downloaded copy whenever its version is newer than the bundled one (versions are
  dates, e.g. `2026.08.19`), and the status window labels the active copy
  "bundled" or "updated". ffmpeg, ffprobe and Deno always come from the bundle.
  If the latest release is no newer than the bundled copy, nothing is installed and
  any stale downloaded copy is removed.
- **In the build:** re-run `./Scripts/fetch-tools.sh` and rebuild. Once the bundle
  catches up with the downloaded copy, the bundled (Developer ID signed) one is used
  again.

The downloaded binary carries only yt-dlp's own ad-hoc signature. That is fine for a
child process: the hardened runtime's library validation applies to code loaded into
the app, not to executables it spawns, and the update refuses to install a copy that
does not launch. Don't run `yt-dlp -U` inside the app bundle; it would replace a
signed binary and break the app's signature.

## Layout

```
ShortVid/
  ShortVidApp.swift        App entry point
  AppUpdater.swift         Sparkle updater behind "Check for Updates…"
  Info.plist               Sparkle feed URL and public key (merged into the generated Info.plist)
  AppIcon.icon/            Icon Composer icon (gradient + foreground.svg), used by macOS 26+
  ContentView.swift        Status window + "Try it" tester
  DownloadVideoIntent.swift The App Intent exposed to Shortcuts
  VideoDownloader.swift    yt-dlp invocation (format selector), ffprobe check, ffmpeg conversion
  BundledTools.swift       Locates the helpers; runs subprocesses
  YtdlpUpdater.swift       Picks bundled vs updated yt-dlp; "Update yt-dlp…" download/verify/swap
Tools/
  make-icon.swift          Renders the app icon set and the website icon
  release.sh               Developer ID build, notarize, DMG, upload to beardfm.app, appcast entry
  update-appcast.py        Adds a release to the appcast (called by release.sh)
release-notes/             One HTML fragment per version, embedded in the appcast
Scripts/
  fetch-tools.sh           Downloads the helper binaries into Vendor/bin
  bundle-tools.sh          Run-script phase: copy + codesign helpers
  yt-dlp.entitlements      Hardened-runtime exceptions for yt-dlp
  deno.entitlements        Hardened-runtime exceptions for Deno
Vendor/bin/                Fetched binaries (git-ignored)
```

## License

MIT, see [LICENSE](LICENSE). yt-dlp, ffmpeg, ffprobe and Deno keep their own licenses.
