<p align="center">
  <img src="Resources/AppIcon-1024.png" width="144" height="144" alt="seesee app icon">
</p>

<h1 align="center">seesee</h1>

<p align="center">
  <a href="README.md">中文</a> · English · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  Paste a link, watch it offline. A macOS video player with bilingual subtitles built in.<br>
  Downloads the full video to your Mac and plays it in a clean native player, away from the noise of the web.
</p>

<p align="center">
  <a href="https://github.com/JosssphZhou/seesee/releases/latest"><strong>Download the latest release</strong></a>
  ·
  <a href="https://github.com/JosssphZhou/seesee/releases">All releases</a>
</p>

<p align="center">
  <img src="docs/images/seesee-banner.png" width="720" alt="seesee banner">
</p>

## The vision: your agent watches with you

seesee has no AI built into the player. Through seesee MCP, your own agent (Claude Code, Codex and others) reads the video you are watching, the current subtitles and the current frame, and you ask it right there.

- **seesee MCP**: `now_playing` reads the video and playback position, `current_subtitles` reads the subtitles around the current position, `current_frame` reads the current frame. Read-only; it never controls playback.

Learning from video should be a conversation, not a one-way stream.

## Install

1. Download the zip from the [releases page](https://github.com/JosssphZhou/seesee/releases/latest) and unzip it.
2. Drag **seesee.app** into your Applications folder.
3. Double-click to open. The app is signed with a Developer ID and notarized by Apple.

Apple Silicon (M-series) only, macOS 13 or newer. yt-dlp, ffmpeg, and Deno are bundled; no Homebrew required.

## Add something to watch

- Copy any text containing links, switch to seesee, and press **⌘V** to queue them all at once.
- Or paste into the field at the top of the queue, or drag a URL, `.webloc`, or `.url` file onto the window or Dock icon.

Videos download in the background and are stored locally for offline playback. YouTube and X are the primary targets; other non-DRM sites supported by yt-dlp may work too.

## Features

- **Play while downloading**: no need to wait for the download to finish; it automatically retries if the connection drops
- **Bilingual subtitles**: fetches Chinese and English subtitles automatically and shows the original and translation as a paired two-line caption, cycling through bilingual, translation-only, and off, remembered per video; external `.srt` / `.vtt` files named after the video file are picked up as well, with Chinese (`.zh.srt`) preferred as the translation track
- **Subtitle navigation pane**: full transcript grouped by sentence, click to jump, chapter sections, watched parts fold away
- **Works with your agent**: through seesee MCP, agents such as Claude Code and Codex can read the video you are watching, the current subtitles and the current frame; setup below
- **Resume everything**: position, speed, volume, subtitle mode, and pane state are saved per video
- **Queue management**: drag to reorder, rename in place, archive watched items, thumbnails, batch URL extraction
- **Playback comfort**: 10-second skips, full keyboard control, media keys, fullscreen, AirPlay, compact background player
- **Restraint**: nothing autoplays after a download or relaunch, and downloads pause in Low Power Mode

## Keyboard

| Key | Action |
| --- | --- |
| `⌘V` | Queue every URL on the clipboard |
| `Space` | Play or pause |
| `←` / `→` | Skip back or forward 10 seconds |
| `↑` / `↓` | Change speed by 0.1× |
| `F` | Toggle fullscreen |
| Vertical scroll over video | Adjust volume |

## Connect Claude Code and Codex

seesee MCP ships with the app and needs no API key.

Claude Code:

```sh
claude mcp add --scope user seesee -- /Applications/seesee.app/Contents/MacOS/seesee --mcp-stdio
```

Codex: add this to `~/.codex/config.toml`:

```toml
[mcp_servers.seesee]
command = "/Applications/seesee.app/Contents/MacOS/seesee"
args = ["--mcp-stdio"]
```

Open seesee, play a video, and ask your agent "What am I watching?". If seesee is not open, the tools report that it is not running.

## Data and privacy

- Downloaded media: `~/Movies/seesee`
- Queue metadata: `~/Library/Application Support/seesee/queue.json`
- No analytics, no accounts, no cloud sync
- No browser cookie import
- No DRM decryption

Only download media you are authorized to watch and keep. Site terms and copyright rules still apply.

## Build from source

```sh
git clone https://github.com/JosssphZhou/seesee.git
cd seesee
./scripts/build_app.sh
./scripts/test.sh
```

The development build is written to `dist/seesee.app` and installed as `/Applications/seesee.app`. Set `SEESEE_INSTALL_APP=0` to build without installing, or `SEESEE_LAUNCH_APP=0` to install without launching. For local development the runtime tools come from Homebrew:

```sh
brew install yt-dlp ffmpeg deno
```

## Why Deno is bundled

YouTube gates requests behind JavaScript challenges that yt-dlp needs a restricted JavaScript runtime to solve, and Deno is its official recommendation. Deno is only invoked by yt-dlp while resolving videos and has nothing to do with the UI. A portable ffmpeg is bundled as well, for merging audio and video streams and converting thumbnails and subtitles. License notices for the runtime tools live inside the app under `Contents/Resources`.

## Acknowledgements

Built on top of an open-source project by Michael Grinich; many thanks to the original author. On that foundation of an offline queue and native player, seesee adds a redesigned interface, bilingual subtitles, transcript navigation, play-while-downloading, and full Chinese localization.

## License

[MIT License](LICENSE). Bundled runtime components retain their respective upstream licenses.
