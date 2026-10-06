#!/bin/bash
set -euo pipefail

# 边下边播的引擎检查：在临时应用里放假的 yt-dlp、ffmpeg、deno，从 DownloadEngine.start 走一遍。
# 不联网，不碰真实的片库、队列和偏好设置。写法照上游项目的 scripts/test_browser_auth_engine.sh。

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT
app_dir="$scratch_dir/ProgressiveEngineCheck.app"
tools_dir="$app_dir/Contents/Resources/Tools"
mkdir -p "$app_dir/Contents/MacOS" "$tools_dir" "$scratch_dir/home/Library" "$scratch_dir/calls" "$scratch_dir/pids"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.openmy.seesee.tests.progressive-engine</string>
<key>CFBundleExecutable</key><string>ProgressiveEngineCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# 假 yt-dlp 只记下参数、写几个小文件。按链接里的视频编号决定行为：
# preview0001 能拿到预览；nopreview01 拿不到合流；slowresolv1 解析和下载都一直不结束，用来测删除。
cat > "$tools_dir/yt-dlp" <<'FAKE'
#!/bin/bash
set -euo pipefail
root="$PROGRESSIVE_CHECK_ROOT"
call_file=$(/usr/bin/mktemp "$root/calls/call.XXXXXX")
printf '%s\0' "$@" > "$call_file"
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
    *preview0001*) fixture=preview ;;
    *nopreview01*) fixture=nopreview ;;
    *slowresolv1*) fixture=slow ;;
    *) fixture=other ;;
esac
if $resolver; then
    case "$fixture" in
        preview)
            /bin/sleep 0.2
            printf '%s\n' 'https://fixture.invalid/progressive.mp4'
            exit 0
            ;;
        slow)
            printf '%s' "$$" > "$root/pids/resolver"
            exec /bin/sleep 30
            ;;
        *)
            printf '%s\n' "ERROR: [youtube] $fixture: Requested format is not available" >&2
            exit 1
            ;;
    esac
fi
if [[ -z "$output" ]] || $skip_download; then
    exit 0
fi
prefix="${output%%.*}"
if [[ "$fixture" == slow ]]; then
    printf '%s' "$$" > "$root/pids/download"
    exec /bin/sleep 30
fi
# 字幕先于视频数据落盘；更优的双语 .zh.srt 过一会儿才到。
printf '1\n00:00:00,000 --> 00:00:01,000\nHello\n' > "$paths/$prefix.en.srt"
printf 'WL_META\t"Offline fixture"\t"seesee test"\t12\t[]\n'
printf 'WL_PROGRESS\t10.0%%\t1.00KiB/s\t00:03\n'
if [[ "$fixture" == preview ]]; then
    /bin/sleep 1.3
    printf '1\n00:00:00,000 --> 00:00:01,000\nHello\n你好\n' > "$paths/$prefix.zh.srt"
    printf 'WL_PROGRESS\t50.0%%\t1.00KiB/s\t00:02\n'
    # 引擎每秒扫一次目录，留够时间让它在下完之前看到 .zh.srt。
    /bin/sleep 1.5
fi
: > "$paths/$prefix.mp4"
printf 'WL_PROGRESS\t100.0%%\t1.00KiB/s\t00:00\n'
printf 'WL_DONE\t"%s"\t"Offline fixture"\t"seesee test"\t12\t[]\n' "$paths/$prefix.mp4"
FAKE
cat > "$tools_dir/ffmpeg" <<'FAKE'
#!/bin/bash
# 假 yt-dlp 自己写出字幕和视频文件；真去执行 ffmpeg 就是缺陷。
exit 99
FAKE
cp "$tools_dir/ffmpeg" "$tools_dir/deno"
chmod +x "$tools_dir/yt-dlp" "$tools_dir/ffmpeg" "$tools_dir/deno"

swiftc -module-cache-path "$scratch_dir/module-cache" \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/URLIntake.swift" \
    "$project_dir/Sources/seesee/ChannelLink.swift" \
    "$project_dir/Sources/seesee/PlaylistListing.swift" \
    "$project_dir/Sources/seesee/SubtitleTrackRank.swift" \
    "$project_dir/Sources/seesee/DownloadEngine.swift" \
    "$project_dir/tools/progressive_engine_check.swift" \
    -o "$app_dir/Contents/MacOS/ProgressiveEngineCheck"

# 临时家目录：检查程序开工前先核对自己确实在临时应用和临时家目录里。
CFFIXED_USER_HOME="$scratch_dir/home" PROGRESSIVE_CHECK_ROOT="$scratch_dir" \
    "$app_dir/Contents/MacOS/ProgressiveEngineCheck"
