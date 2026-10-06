#!/bin/bash
set -euo pipefail

# 标题分开存的三条检查，都从真实的 QueueStore 走，不联网：
# 1. 旧格式 queue.json 的迁移：原样备份一次，读进来、存出去、再读回来，字段一个不少。
#    备份写不成时不覆盖旧队列：目录恢复可写后先补备份再保存；一直写不成时用户的写操作被拒。
# 2. 下载中改的名，下完以后不被元数据覆盖。从真实的 QueueStore() 启动，放在临时应用和临时家目录里，
#    yt-dlp、ffmpeg、deno 都是假的。队列要等系统报告在线才开始下载，所以这台机器要连着网。
# 3. YouTube 作者的中文标题：后台取到以后做主标题，来源记作 author。和第 2 条用同一个临时应用。
# 4. 旧条目补翻：启动时没看的旧条目用本机翻译补中文主标题，已看的不翻，不问作者标题。要装了英文到简体中文的
#    翻译语言包，没装时跳过。

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir=$(mktemp -d)
app_dir="$scratch_dir/TitleFieldsCheck.app"
tools_dir="$app_dir/Contents/Resources/Tools"
# 偏好设置不跟着临时家目录走，会写进真实家目录下这个测试专用的域；开始前和结束后都删掉。
test_domain="ai.openmy.seesee.tests.title-fields"
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

# QueueStore 要用到的源文件。标题翻译相关的文件只在有的时候加上，同一个脚本在改动之前的代码上也能跑。
source_dir="$project_dir/Sources/seesee"
store_sources=()
for name in WatchItem ChapterMetadata VideoSubtitles SubtitleTrackRank NetworkMonitor PowerModeMonitor \
    AppFolders QueueRowMeta URLIntake DownloadRetryPolicy ChannelLink PlaylistListing ChannelSubscription \
    DownloadEngine ChannelWatchStore MediaFolderCopy MediaFolderAvailability MediaFolderPreference \
    MediaFolderLaunchArguments MediaLibraryMover PlayerReadyDecision QueueStore \
    SponsorSkip VideoTitle TitleTranslation SubtitleVersionStore SubtitleSentenceBlocks LocalTranscription AppleSpeechModelBackend TranscriptionModelStatus; do
    if [[ -f "$source_dir/$name.swift" ]]; then
        store_sources+=("$source_dir/$name.swift")
    fi
done

# 只跑其中一条时设 TITLE_CHECK_ONLY=migration、rename、author 或 backfill。
only="${TITLE_CHECK_ONLY:-}"

# 1. 迁移检查。
if [[ -z "$only" || "$only" == "migration" ]]; then
swiftc -module-cache-path "$scratch_dir/module-cache" \
    "${store_sources[@]}" \
    "$project_dir/tools/title_migration_check.swift" \
    -o "$scratch_dir/title_migration_check"
"$scratch_dir/title_migration_check"
# 备份写不成时不覆盖旧队列。
swiftc -module-cache-path "$scratch_dir/module-cache" \
    "${store_sources[@]}" \
    "$project_dir/tools/title_backup_failure_check.swift" \
    -o "$scratch_dir/title_backup_failure_check"
"$scratch_dir/title_backup_failure_check"
fi
[[ "$only" == "migration" ]] && exit 0

# 2. 改名回归检查。
mkdir -p "$app_dir/Contents/MacOS" "$tools_dir" "$scratch_dir/home/Library"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.openmy.seesee.tests.title-fields</string>
<key>CFBundleExecutable</key><string>TitleFieldsCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# 假 yt-dlp。改名检查（TITLE_CHECK_MODE=rename）：下载时先报元数据，等检查程序改完名（root/go 出现）
# 再写出视频、报下完；平铺列表不给结果。作者标题检查（author）：下载时报英文原标题、直接下完；
# 平铺列表（取作者中文标题）报中文标题。两种都不给预览、不给单独的元数据。
cat > "$tools_dir/yt-dlp" <<'FAKE'
#!/bin/bash
set -euo pipefail
root="$TITLE_CHECK_ROOT"
mode="${TITLE_CHECK_MODE:-rename}"
paths=""
output=""
flat=0
while (($#)); do
    case "$1" in
        --paths) paths="$2"; shift ;;
        --output) output="$2"; shift ;;
        --get-url) exit 1 ;;
        --flat-playlist) flat=1 ;;
        --skip-download) [[ "$flat" == 1 ]] || exit 0 ;;
    esac
    shift
done
if [[ "$flat" == 1 ]]; then
    : > "$root/asked-author"
    [[ "$mode" == "author" ]] && printf 'WL_TITLE\t0e3GPea1Tyg\t"现实版鱿鱼游戏，坚持到最后赢得456,000美元！"\n'
    exit 0
fi
[[ -n "$output" && -n "$paths" ]] || exit 0
prefix="${output%%.*}"
if [[ "$mode" == "author" ]]; then
    printf 'WL_META\t"$456,000 Squid Game In Real Life!"\t"MrBeast"\t1500\t[]\tnull\t"en"\n'
    : > "$paths/$prefix.mp4"
    printf 'WL_DONE\t"%s"\t"$456,000 Squid Game In Real Life!"\t"MrBeast"\t1500\t[]\tnull\t"en"\n' "$paths/$prefix.mp4"
    exit 0
fi
printf 'WL_META\t"视频网站给的原标题"\t"seesee test"\t12\t[]\n'
printf 'WL_PROGRESS\t10.0%%\t1.00KiB/s\t00:03\n'
deadline=$((SECONDS + 30))
until [[ -e "$root/go" ]]; do
    if ((SECONDS >= deadline)); then
        printf '%s\n' "ERROR: check never renamed the item"
        exit 3
    fi
    /bin/sleep 0.05
done
: > "$paths/$prefix.mp4"
printf 'WL_PROGRESS\t100.0%%\t1.00KiB/s\t00:00\n'
printf 'WL_DONE\t"%s"\t"视频网站给的原标题"\t"seesee test"\t12\t[]\n' "$paths/$prefix.mp4"
FAKE
cat > "$tools_dir/ffmpeg" <<'FAKE'
#!/bin/bash
# 假 yt-dlp 自己写出视频文件；真去执行 ffmpeg 就是缺陷。
exit 99
FAKE
cp "$tools_dir/ffmpeg" "$tools_dir/deno"
chmod +x "$tools_dir/yt-dlp" "$tools_dir/ffmpeg" "$tools_dir/deno"

# 临时家目录：检查程序开工前先核对自己确实在临时应用和临时家目录里。
if [[ -z "$only" || "$only" == "rename" ]]; then
    swiftc -module-cache-path "$scratch_dir/module-cache" \
        "${store_sources[@]}" \
        "$project_dir/tools/title_rename_regression_check.swift" \
        -o "$app_dir/Contents/MacOS/TitleFieldsCheck"
    CFFIXED_USER_HOME="$scratch_dir/home" TITLE_CHECK_ROOT="$scratch_dir" TITLE_CHECK_MODE=rename \
        "$app_dir/Contents/MacOS/TitleFieldsCheck"
fi

# 3. 作者中文标题检查：另一个临时家目录，队列从空的开始。
if [[ -z "$only" || "$only" == "author" ]]; then
    remove_test_domain
    mkdir -p "$scratch_dir/home-author/Library"
    swiftc -module-cache-path "$scratch_dir/module-cache" \
        "${store_sources[@]}" \
        "$project_dir/tools/title_author_check.swift" \
        -o "$app_dir/Contents/MacOS/TitleFieldsCheck"
    CFFIXED_USER_HOME="$scratch_dir/home-author" TITLE_CHECK_ROOT="$scratch_dir" TITLE_CHECK_MODE=author \
        "$app_dir/Contents/MacOS/TitleFieldsCheck"
fi

# 4. 旧条目补翻检查：又一个临时家目录，队列是旧格式，全是已下载的条目，不会开始下载。
if [[ -z "$only" || "$only" == "backfill" ]]; then
    remove_test_domain
    rm -f "$scratch_dir/asked-author"
    mkdir -p "$scratch_dir/home-backfill/Library"
    swiftc -module-cache-path "$scratch_dir/module-cache" \
        "${store_sources[@]}" \
        "$project_dir/tools/title_backfill_check.swift" \
        -o "$app_dir/Contents/MacOS/TitleFieldsCheck"
    CFFIXED_USER_HOME="$scratch_dir/home-backfill" TITLE_CHECK_ROOT="$scratch_dir" TITLE_CHECK_MODE=backfill \
        "$app_dir/Contents/MacOS/TitleFieldsCheck"
fi
