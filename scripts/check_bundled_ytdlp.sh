#!/bin/bash
# Check the yt-dlp bundled in a built app:
#   1. it is not older than yt_dlp_version in prepare_runtime_tools.sh;
#   2. a second `yt-dlp --version` returns within the time limit.
# The first run is not timed: macOS checks every library the first time it is
# loaded from a new path. The one-file build unpacks its libraries into a new
# temporary folder on every run, so its second run is as slow as the first.
#
# Usage: scripts/check_bundled_ytdlp.sh <app> [limit in seconds, default 2]
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Usage: check_bundled_ytdlp.sh <app> [limit in seconds]}"
limit="${2:-2}"
yt_dlp="$app/Contents/Resources/Tools/yt-dlp"

pinned=$(sed -n 's/^yt_dlp_version="\(.*\)"$/\1/p' "$project_dir/scripts/prepare_runtime_tools.sh")
[[ -n "$pinned" ]] || {
    echo "Cannot read yt_dlp_version from prepare_runtime_tools.sh." >&2
    exit 1
}
[[ -x "$yt_dlp" ]] || {
    echo "FAIL: no bundled yt-dlp at $yt_dlp" >&2
    exit 1
}

failed=0
bundled=$("$yt_dlp" --version) || {
    echo "FAIL: $yt_dlp --version exited with an error" >&2
    exit 1
}
if printf '%s\n%s\n' "$pinned" "$bundled" | sort -V -C; then
    echo "ok: bundled yt-dlp $bundled is not older than $pinned"
else
    echo "FAIL: bundled yt-dlp $bundled is older than $pinned" >&2
    failed=1
fi

TIMEFORMAT=%R
seconds=$( { time "$yt_dlp" --version >/dev/null 2>&1; } 2>&1 ) || {
    echo "FAIL: second $yt_dlp --version exited with an error" >&2
    exit 1
}
if awk -v seconds="$seconds" -v limit="$limit" 'BEGIN { exit !(seconds <= limit) }'; then
    echo "ok: second yt-dlp --version took ${seconds}s (limit ${limit}s)"
else
    echo "FAIL: second yt-dlp --version took ${seconds}s (limit ${limit}s)" >&2
    failed=1
fi
exit "$failed"
