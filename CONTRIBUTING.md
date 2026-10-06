# Contributing

Thanks for helping improve seesee.

## Local setup

seesee requires macOS 13 or newer and Swift 5.9 or newer.

```sh
git clone https://github.com/JosssphZhou/seesee.git
cd seesee
./scripts/build_app.sh
./scripts/test.sh
```

Development builds use `yt-dlp`, `ffmpeg`, and optionally `deno` from the app bundle first, then fall back to Homebrew locations. Install local copies with:

```sh
brew install yt-dlp ffmpeg deno
```

`build_app.sh` installs the finished app at `/Applications/seesee.app` and launches it by default. Use `SEESEE_INSTALL_APP=0` for a build-only run or `SEESEE_LAUNCH_APP=0` to install without launching.

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Run `swift build -c release` and `./scripts/test.sh` before opening a pull request.
- Do not commit downloaded media, app bundles, or files from `.build`.

## Releases

The version comes from `Resources/Info.plist`. To publish a release, update both bundle version fields, then build a signed and notarized archive locally:

```bash
./scripts/prepare_runtime_tools.sh
SEESEE_SIGNING_IDENTITY="Developer ID Application: YIQI XIE (ANVS3UQK9W)" \
SEESEE_NOTARIZE=1 SEESEE_NOTARY_PROFILE=openmy-notary \
SEESEE_UNIVERSAL=0 SEESEE_BUNDLED_TOOLS_DIR=.build/runtime-tools/arm64 \
    ./scripts/package_release.sh
```

`prepare_runtime_tools.sh` downloads and verifies yt-dlp (the one-folder build), Deno, and the FFmpeg source, builds FFmpeg, and writes the Apple Silicon tool set to `.build/runtime-tools/arm64`. The release script signs every bundled executable and library with the hardened runtime and a secure timestamp (Deno keeps its own Developer ID signature), checks with `scripts/check_bundled_ytdlp.sh` that the bundled yt-dlp is the pinned version and starts within 2 seconds, submits the app for notarization, staples the ticket, and writes `dist/release-v<version>/seesee-v<version>-apple-silicon.zip` plus its SHA-256 checksum. Push a matching `v*` tag and attach both files to the GitHub release. Never publish an archive whose notarization was not accepted.
