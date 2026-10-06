#!/bin/bash
set -euo pipefail

# 边下边播的重试检查：下载中途失败、自动重试时，正在播的预览不能断，也不换地址。
# 从真实的 QueueStore() 启动，放在临时应用和临时家目录里；yt-dlp、ffmpeg、deno 都是假的，不联网。
# 队列要等系统报告在线才开始下载，所以这台机器要连着网，但检查本身不发任何网络请求。

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir=$(mktemp -d)
app_dir="$scratch_dir/ProgressiveRetryCheck.app"
tools_dir="$app_dir/Contents/Resources/Tools"
# 偏好设置不跟着临时家目录走，会写进真实家目录下这个测试专用的域；开始前和结束后都删掉。
test_domain="ai.openmy.seesee.tests.progressive-retry"
remove_test_domain() {
    defaults delete "$test_domain" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$test_domain.plist"
}
cleanup() {
    # 检查中途失败时，假 yt-dlp 可能还在等；按临时应用的路径停掉，不留后台进程。
    pkill -f "$tools_dir/" >/dev/null 2>&1 || true
    remove_test_domain
    rm -rf "$scratch_dir"
}
trap cleanup EXIT
remove_test_domain

# macOS 27 Command Line Tools SDK 缺 SwiftUI 宏插件时，改用相邻的 26 SDK（同 scripts/test.sh）。
if [[ -z "${SDKROOT:-}" ]]; then
    default_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    default_sdk_version=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    compatibility_sdk="$(dirname "$default_sdk")/MacOSX26.sdk"
    if [[ "$default_sdk_version" == 27.* && -d "$compatibility_sdk" ]]; then
        export SDKROOT="$compatibility_sdk"
    fi
fi

mkdir -p "$app_dir/Contents/MacOS" "$tools_dir" "$scratch_dir/home/Library" "$scratch_dir/attempts"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.openmy.seesee.tests.progressive-retry</string>
<key>CFBundleExecutable</key><string>ProgressiveRetryCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# 假 yt-dlp：按链接里的视频编号分两条，解析和下载各自记第几次运行。
# 每一轮下载都等这一轮的预览地址交出去再结束；第一轮失败，第二轮（自动重试）下完。
# 重试那一轮的解析慢一秒，旧做法清掉预览以后的空档足够长，检查一定看得到。
cat > "$tools_dir/yt-dlp" <<'FAKE'
#!/bin/bash
set -euo pipefail
root="$PROGRESSIVE_CHECK_ROOT"
source="${*: -1}"
paths=""
output=""
skip_download=false
resolver=false
while (($#)); do
    case "$1" in
        --paths) paths="$2"; shift ;;
        --output) output="$2"; shift ;;
        --skip-download) skip_download=true ;;
        --get-url) resolver=true ;;
    esac
    shift
done
case "$source" in
    *retrykeep01*) fixture=keep ;;
    *retryfresh1*) fixture=fresh ;;
    *) exit 0 ;;
esac
# mkdir 是原子操作：同时启动的几个进程不会数成同一轮。
next_attempt() {
    local n=1
    until mkdir "$root/attempts/$fixture-$1-$n" 2>/dev/null; do n=$((n + 1)); done
    printf '%s' "$n"
}
if $resolver; then
    n=$(next_attempt resolver)
    if [[ "$n" == 1 ]]; then /bin/sleep 0.2; else /bin/sleep 1; fi
    printf 'https://fixture.invalid/%s-preview-%s.mp4\n' "$fixture" "$n"
    : > "$root/attempts/$fixture-resolver-$n/printed"
    exit 0
fi
if [[ -z "$output" ]] || $skip_download; then
    exit 0
fi
n=$(next_attempt download)
prefix="${output%%.*}"
printf 'WL_META\t"Retry fixture"\t"seesee test"\t12\t[]\n'
printf 'WL_PROGRESS\t10.0%%\t1.00KiB/s\t00:03\n'
deadline=$((SECONDS + 20))
until [[ -e "$root/attempts/$fixture-resolver-$n/printed" ]]; do
    if ((SECONDS >= deadline)); then
        printf '%s\n' "ERROR: fixture resolver $n never printed"
        exit 3
    fi
    /bin/sleep 0.05
done
# 留半秒，让预览地址先到队列。
/bin/sleep 0.5
if [[ "$n" == 1 ]]; then
    # 第一轮下载中途出错，和真实遇到的 YouTube 403 一样。
    printf '%s\n' 'ERROR: unable to download video data: HTTP Error 403: Forbidden'
    exit 1
fi
: > "$paths/$prefix.mp4"
printf 'WL_PROGRESS\t100.0%%\t1.00KiB/s\t00:00\n'
printf 'WL_DONE\t"%s"\t"Retry fixture"\t"seesee test"\t12\t[]\n' "$paths/$prefix.mp4"
FAKE
cat > "$tools_dir/ffmpeg" <<'FAKE'
#!/bin/bash
# 假 yt-dlp 自己写出视频文件；真去执行 ffmpeg 就是缺陷。
exit 99
FAKE
cp "$tools_dir/ffmpeg" "$tools_dir/deno"
chmod +x "$tools_dir/yt-dlp" "$tools_dir/ffmpeg" "$tools_dir/deno"

source_dir="$project_dir/Sources/seesee"
swiftc -module-cache-path "$scratch_dir/module-cache" \
    "$source_dir/WatchItem.swift" \
    "$source_dir/ChapterMetadata.swift" \
    "$source_dir/VideoSubtitles.swift" \
    "$source_dir/SubtitleTrackRank.swift" \
    "$source_dir/NetworkMonitor.swift" \
    "$source_dir/PowerModeMonitor.swift" \
    "$source_dir/AppFolders.swift" \
    "$source_dir/QueueRowMeta.swift" \
    "$source_dir/URLIntake.swift" \
    "$source_dir/DownloadRetryPolicy.swift" \
    "$source_dir/ChannelLink.swift" \
    "$source_dir/PlaylistListing.swift" \
    "$source_dir/ChannelSubscription.swift" \
    "$source_dir/DownloadEngine.swift" \
    "$source_dir/ChannelWatchStore.swift" \
    "$source_dir/MediaFolderCopy.swift" \
    "$source_dir/MediaFolderAvailability.swift" \
    "$source_dir/MediaFolderPreference.swift" \
    "$source_dir/MediaFolderLaunchArguments.swift" \
    "$source_dir/MediaLibraryMover.swift" \
    "$source_dir/PlayerReadyDecision.swift" \
    "$source_dir/QueueStore.swift" \
    "$source_dir/LocalTranscription.swift" \
    "$source_dir/AppleSpeechModelBackend.swift" \
    "$source_dir/TranscriptionModelStatus.swift" \
    "$source_dir/SubtitleVersionStore.swift" \
    "$source_dir/SubtitleSentenceBlocks.swift" \
    "$source_dir/SponsorSkip.swift" \
    "$source_dir/VideoTitle.swift" \
    "$source_dir/TitleTranslation.swift" \
    "$project_dir/tools/progressive_retry_check.swift" \
    -o "$app_dir/Contents/MacOS/ProgressiveRetryCheck"

# 临时家目录：检查程序开工前先核对自己确实在临时应用和临时家目录里。
CFFIXED_USER_HOME="$scratch_dir/home" PROGRESSIVE_CHECK_ROOT="$scratch_dir" \
    "$app_dir/Contents/MacOS/ProgressiveRetryCheck"
