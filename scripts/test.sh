#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

# macOS 27 Command Line Tools SDK 缺 SwiftUI 宏插件时，改用相邻的 26 SDK。
if [[ -z "${SDKROOT:-}" ]]; then
    default_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    default_sdk_version=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    compatibility_sdk="$(dirname "$default_sdk")/MacOSX26.sdk"
    if [[ "$default_sdk_version" == 27.* && -d "$compatibility_sdk" ]]; then
        export SDKROOT="$compatibility_sdk"
    fi
fi

compile_and_run() {
    local name="$1"
    shift
    swiftc "$@" -o "$scratch_dir/$name"
    "$scratch_dir/$name"
}

compile_and_run url_intake \
    "$project_dir/Sources/seesee/URLIntake.swift" \
    "$project_dir/tools/url_intake_check.swift"

compile_and_run channel_watch \
    "$project_dir/Sources/seesee/URLIntake.swift" \
    "$project_dir/Sources/seesee/ChannelLink.swift" \
    "$project_dir/Sources/seesee/PlaylistListing.swift" \
    "$project_dir/Sources/seesee/ChannelSubscription.swift" \
    "$project_dir/tools/channel_watch_check.swift"

compile_and_run retry_policy \
    "$project_dir/Sources/seesee/DownloadRetryPolicy.swift" \
    "$project_dir/tools/retry_policy_check.swift"

compile_and_run resume_model \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/tools/resume_model_check.swift"

compile_and_run subtitle_parser \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/tools/subtitle_parser_check.swift"

compile_and_run subtitle_presentation \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/tools/subtitle_presentation_check.swift"

compile_and_run subtitle_dispatch \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleDispatch.swift" \
    "$project_dir/tools/subtitle_dispatch_check.swift"

compile_and_run subtitle_overlay_layout \
    "$project_dir/Sources/seesee/SubtitleOverlayLayout.swift" \
    "$project_dir/tools/subtitle_overlay_layout_check.swift"

compile_and_run subtitle_rank \
    "$project_dir/Sources/seesee/SubtitleTrackRank.swift" \
    "$project_dir/tools/subtitle_rank_check.swift"

compile_and_run power_mode \
    "$project_dir/Sources/seesee/PowerModeMonitor.swift" \
    "$project_dir/tools/power_mode_check.swift"

compile_and_run playback_command \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleOverlayLayout.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/SubtitleDispatch.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/LocalVideoPlayer.swift" \
    "$project_dir/tools/playback_command_check.swift"

compile_and_run activation_click \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/Sources/seesee/PlaybackKeyboardRouting.swift" \
    "$project_dir/Sources/seesee/PlaybackWindowFocusController.swift" \
    "$project_dir/Sources/seesee/VisualStyle.swift" \
    "$project_dir/tools/activation_click_check.swift"

compile_and_run openmy_chrome \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/tools/openmy_chrome_check.swift"

compile_and_run queue_row_meta \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/tools/queue_row_meta_check.swift"

# 下载中显示规则：圆环、队列行、等待画面和预览标记显示的数字和状态词，不漏出 yt-dlp 的占位词。
compile_and_run download_progress_display \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/DownloadProgressDisplay.swift" \
    "$project_dir/tools/download_progress_display_check.swift"

# 引擎必须带 --progress：参数里有 --print 时 yt-dlp 进入安静模式，不出进度。
# 假 yt-dlp 放在检查程序自己的目录里（引擎找工具的第一个位置），所以单独一个子目录。
mkdir -p "$scratch_dir/download_engine_progress"
compile_and_run download_engine_progress/check \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/SubtitleTrackRank.swift" \
    "$project_dir/Sources/seesee/URLIntake.swift" \
    "$project_dir/Sources/seesee/ChannelLink.swift" \
    "$project_dir/Sources/seesee/PlaylistListing.swift" \
    "$project_dir/Sources/seesee/DownloadEngine.swift" \
    "$project_dir/tools/download_engine_progress_check.swift"

compile_and_run side_pane_selection \
    "$project_dir/Sources/seesee/SidePaneSelection.swift" \
    "$project_dir/tools/side_pane_selection_check.swift"

compile_and_run digest_search \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/tools/digest_search_check.swift"

compile_and_run digest_cue_display \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/Sources/seesee/DigestCueDisplay.swift" \
    "$project_dir/tools/digest_cue_display_check.swift"

compile_and_run digest_current_row_height \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/Sources/seesee/DigestCueDisplay.swift" \
    "$project_dir/tools/digest_current_row_height_check.swift"

compile_and_run digest_row_width \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/Sources/seesee/DigestCueDisplay.swift" \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/Sources/seesee/DigestBookChrome.swift" \
    "$project_dir/Sources/seesee/DigestCueRow.swift" \
    "$project_dir/tools/digest_row_width_check.swift"

compile_and_run digest_typography_proof \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/Sources/seesee/DigestCueDisplay.swift" \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/Sources/seesee/DigestBookChrome.swift" \
    "$project_dir/Sources/seesee/DigestCueRow.swift" \
    "$project_dir/tools/digest_typography_proof.swift"

compile_and_run digest_book_chrome_proof \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/Sources/seesee/DigestCueDisplay.swift" \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/Sources/seesee/DigestBookChrome.swift" \
    "$project_dir/Sources/seesee/DigestCopy.swift" \
    "$project_dir/Sources/seesee/DigestSidebarViews.swift" \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/DigestTOC.swift" \
    "$project_dir/Sources/seesee/DigestTOCViews.swift" \
    "$project_dir/tools/digest_book_chrome_proof.swift"

compile_and_run digest_jump \
    "$project_dir/Sources/seesee/DigestJumpPlayback.swift" \
    "$project_dir/tools/digest_jump_check.swift"

compile_and_run digest_book_narrow_proof \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/Sources/seesee/DigestCueDisplay.swift" \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/Sources/seesee/DigestBookChrome.swift" \
    "$project_dir/Sources/seesee/DigestCueRow.swift" \
    "$project_dir/Sources/seesee/DigestSidebarViews.swift" \
    "$project_dir/Sources/seesee/DigestCopy.swift" \
    "$project_dir/Sources/seesee/DigestTOC.swift" \
    "$project_dir/Sources/seesee/DigestTOCViews.swift" \
    "$project_dir/tools/digest_book_narrow_proof.swift"

compile_and_run player_ready \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/PlayerReadyDecision.swift" \
    "$project_dir/tools/player_ready_check.swift"

# 边下边播：当前该播哪个源、预览下完换成本地文件时从哪里接着播。
compile_and_run progressive_playback \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/PlayerReadyDecision.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleOverlayLayout.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/SubtitleDispatch.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/LocalVideoPlayer.swift" \
    "$project_dir/tools/progressive_playback_check.swift"

# 边下边播的下载引擎：假工具，不联网；预览流、字幕陆续到达、拿不到预览时退回、删除时停掉解析进程。
"$project_dir/scripts/test_progressive_engine.sh"

# 边下边播的重试：真实 QueueStore，假工具，不联网；下载失败自动重试时，正在播的预览不断、不换地址。
"$project_dir/scripts/test_progressive_retry.sh"

compile_and_run keyboard_routing \
    "$project_dir/Sources/seesee/PlaybackKeyboardRouting.swift" \
    "$project_dir/Sources/seesee/PlaybackWindowFocusController.swift" \
    "$project_dir/tools/keyboard_routing_check.swift"

compile_and_run digest_keyboard \
    "$project_dir/Sources/seesee/PlaybackKeyboardRouting.swift" \
    "$project_dir/Sources/seesee/DigestKeyboardRouting.swift" \
    "$project_dir/tools/digest_keyboard_check.swift"

compile_and_run sidebar_hittest \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/Sources/seesee/SidebarQueueLayout.swift" \
    "$project_dir/tools/sidebar_hittest_check.swift"

# 窄窗滑出左栏：挂载真实 ContentView，排除带 @main 的入口 SeeseeEntry 与 SeeseeApp。
sidebar_slideout_sources=()
while IFS= read -r file; do
    sidebar_slideout_sources+=("$file")
done < <(find "$project_dir/Sources/seesee" -name '*.swift' ! -name 'SeeseeApp.swift' ! -name 'SeeseeEntry.swift' | sort)
compile_and_run sidebar_slideout \
    -parse-as-library \
    "${sidebar_slideout_sources[@]}" \
    "$project_dir/tools/sidebar_slideout_check.swift"

compile_and_run subtitle_blocks \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/tools/subtitle_blocks_check.swift"

compile_and_run sponsor_skip \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/tools/sponsor_skip_check.swift"
compile_and_run media_library_mover \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/MediaFolderCopy.swift" \
    "$project_dir/Sources/seesee/MediaFolderAvailability.swift" \
    "$project_dir/Sources/seesee/MediaFolderPreference.swift" \
    "$project_dir/Sources/seesee/MediaFolderLaunchArguments.swift" \
    "$project_dir/Sources/seesee/MediaLibraryMover.swift" \
    "$project_dir/tools/media_library_mover_check.swift"

compile_and_run media_folder_settings_proof \
    "$project_dir/Sources/seesee/OpenMyChrome.swift" \
    "$project_dir/Sources/seesee/MediaFolderCopy.swift" \
    "$project_dir/Sources/seesee/DigestSettings.swift" \
    "$project_dir/Sources/seesee/DigestSettingsView.swift" \
    "$project_dir/tools/media_folder_settings_proof.swift"

# 删除接线：经真实生产入口 QueueStore.remove（注入隔离目录）验证 qa sidecar 一并清掉。
compile_and_run qa_remove \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleTrackRank.swift" \
    "$project_dir/Sources/seesee/NetworkMonitor.swift" \
    "$project_dir/Sources/seesee/PowerModeMonitor.swift" \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/Sources/seesee/URLIntake.swift" \
    "$project_dir/Sources/seesee/DownloadRetryPolicy.swift" \
    "$project_dir/Sources/seesee/ChannelLink.swift" \
    "$project_dir/Sources/seesee/PlaylistListing.swift" \
    "$project_dir/Sources/seesee/ChannelSubscription.swift" \
    "$project_dir/Sources/seesee/DownloadEngine.swift" \
    "$project_dir/Sources/seesee/ChannelWatchStore.swift" \
    "$project_dir/Sources/seesee/MediaFolderCopy.swift" \
    "$project_dir/Sources/seesee/MediaFolderAvailability.swift" \
    "$project_dir/Sources/seesee/MediaFolderPreference.swift" \
    "$project_dir/Sources/seesee/MediaFolderLaunchArguments.swift" \
    "$project_dir/Sources/seesee/MediaLibraryMover.swift" \
    "$project_dir/Sources/seesee/PlayerReadyDecision.swift" \
    "$project_dir/Sources/seesee/QueueStore.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/VideoTitle.swift" \
    "$project_dir/Sources/seesee/TitleTranslation.swift" \
    "$project_dir/tools/qa_remove_check.swift"

compile_and_run media_folder_store \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleTrackRank.swift" \
    "$project_dir/Sources/seesee/NetworkMonitor.swift" \
    "$project_dir/Sources/seesee/PowerModeMonitor.swift" \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/Sources/seesee/URLIntake.swift" \
    "$project_dir/Sources/seesee/DownloadRetryPolicy.swift" \
    "$project_dir/Sources/seesee/ChannelLink.swift" \
    "$project_dir/Sources/seesee/PlaylistListing.swift" \
    "$project_dir/Sources/seesee/ChannelSubscription.swift" \
    "$project_dir/Sources/seesee/DownloadEngine.swift" \
    "$project_dir/Sources/seesee/ChannelWatchStore.swift" \
    "$project_dir/Sources/seesee/MediaFolderCopy.swift" \
    "$project_dir/Sources/seesee/MediaFolderAvailability.swift" \
    "$project_dir/Sources/seesee/MediaFolderPreference.swift" \
    "$project_dir/Sources/seesee/MediaFolderLaunchArguments.swift" \
    "$project_dir/Sources/seesee/MediaLibraryMover.swift" \
    "$project_dir/Sources/seesee/PlayerReadyDecision.swift" \
    "$project_dir/Sources/seesee/QueueStore.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/VideoTitle.swift" \
    "$project_dir/Sources/seesee/TitleTranslation.swift" \
    "$project_dir/tools/media_folder_store_check.swift"

# 更改片库位置的数据安全：旧位置一个不删；复制中途、核对失败、改写队列中途退出后启动退回；queue.json 坏了不动文件。
compile_and_run media_folder_move_safety \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleTrackRank.swift" \
    "$project_dir/Sources/seesee/NetworkMonitor.swift" \
    "$project_dir/Sources/seesee/PowerModeMonitor.swift" \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/Sources/seesee/URLIntake.swift" \
    "$project_dir/Sources/seesee/DownloadRetryPolicy.swift" \
    "$project_dir/Sources/seesee/ChannelLink.swift" \
    "$project_dir/Sources/seesee/PlaylistListing.swift" \
    "$project_dir/Sources/seesee/ChannelSubscription.swift" \
    "$project_dir/Sources/seesee/DownloadEngine.swift" \
    "$project_dir/Sources/seesee/ChannelWatchStore.swift" \
    "$project_dir/Sources/seesee/MediaFolderCopy.swift" \
    "$project_dir/Sources/seesee/MediaFolderAvailability.swift" \
    "$project_dir/Sources/seesee/MediaFolderPreference.swift" \
    "$project_dir/Sources/seesee/MediaFolderLaunchArguments.swift" \
    "$project_dir/Sources/seesee/MediaLibraryMover.swift" \
    "$project_dir/Sources/seesee/PlayerReadyDecision.swift" \
    "$project_dir/Sources/seesee/QueueStore.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/VideoTitle.swift" \
    "$project_dir/Sources/seesee/TitleTranslation.swift" \
    "$project_dir/tools/media_folder_move_safety_check.swift"

# 标题：显示优先级、改名不被覆盖、X 原标题、何时翻译、作者中文标题。
compile_and_run title_display \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/Sources/seesee/VideoTitle.swift" \
    "$project_dir/tools/title_display_check.swift"

# 标题分开存：旧 queue.json 迁移、下载中改的名不被覆盖（真实 QueueStore，假工具）。
"$project_dir/scripts/test_title_fields.sh"

# 正在看的位置：结果构造只取播放器时间；本机套接字鉴权与限制；MCP 桥接协议。
compile_and_run now_playing_query \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/AgentLink.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/Sources/seesee/VideoTitle.swift" \
    "$project_dir/Sources/seesee/NowPlayingQuery.swift" \
    "$project_dir/tools/now_playing_query_check.swift"

# 单语字幕轨一条折成两行时，第二行不当译文；浮层、右栏和 MCP 三处一致，双语轨不变。
compile_and_run mono_subtitle_track \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/DigestTranscriptSearch.swift" \
    "$project_dir/Sources/seesee/DigestCueDisplay.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/AgentLink.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/Sources/seesee/VideoTitle.swift" \
    "$project_dir/Sources/seesee/NowPlayingQuery.swift" \
    "$project_dir/tools/mono_subtitle_track_check.swift"

compile_and_run agent_link \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/AgentLink.swift" \
    "$project_dir/tools/agent_link_check.swift"

# MCP 端到端（从真实入口走）：启动 dist/seesee.app 的副本、在后台开一个窗口，默认不跑。
# 先运行 SEESEE_INSTALL_APP=0 scripts/build_app.sh，再设 SEESEE_MCP_E2E=1 跑这一条。
if [[ "${SEESEE_MCP_E2E:-0}" == "1" ]]; then
    "$project_dir/tools/seesee_mcp_e2e_check.sh" "$project_dir/dist/seesee.app"
fi

compile_and_run seesee_mcp_bridge \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/Sources/seesee/ChapterMetadata.swift" \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/AppFolders.swift" \
    "$project_dir/Sources/seesee/AgentLink.swift" \
    "$project_dir/Sources/seesee/QueueRowMeta.swift" \
    "$project_dir/Sources/seesee/VideoTitle.swift" \
    "$project_dir/Sources/seesee/NowPlayingQuery.swift" \
    "$project_dir/Sources/seesee/SeeseeMCPBridge.swift" \
    "$project_dir/tools/seesee_mcp_bridge_check.swift"

compile_and_run lan_player \
    "$project_dir/tools/LanPlayer.swift" \
    "$project_dir/tools/lan_player_check.swift"

# 局域网播放命令行：--bind 给 0.0.0.0 或公网地址必须直接报错退出，不能监听。
swiftc -parse-as-library \
    "$project_dir/tools/LanPlayer.swift" \
    "$project_dir/tools/lan_player_main.swift" \
    -o "$scratch_dir/lan_player_cli"
printf '[]' > "$scratch_dir/lan_queue.json"
for bind_host in 0.0.0.0 8.8.8.8; do
    set +e
    perl -e 'alarm 5; exec @ARGV' "$scratch_dir/lan_player_cli" \
        --queue "$scratch_dir/lan_queue.json" \
        --token-file "$scratch_dir/lan_token" \
        --bind "$bind_host" --port 0 >/dev/null 2>"$scratch_dir/lan_cli_err"
    bind_status=$?
    set -e
    if [[ $bind_status -ne 1 ]] || ! grep -q "只能监听" "$scratch_dir/lan_cli_err"; then
        echo "lan_player_cli: --bind $bind_host 必须拒绝，退出码 $bind_status" >&2
        exit 1
    fi
    if [[ -e "$scratch_dir/lan_token" ]]; then
        echo "lan_player_cli: --bind $bind_host 被拒绝前不得生成访问码文件" >&2
        exit 1
    fi
done
echo "lan_player_cli_bind=passed"

# 看视频时屏幕不熄：主窗口、全屏、悬浮小窗共用的播放器必须阻止播放期间熄屏。
compile_and_run display_sleep \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleOverlayLayout.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/SubtitleDispatch.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/LocalVideoPlayer.swift" \
    "$project_dir/tools/display_sleep_check.swift"

# 播放器字幕换句零位移：离屏驱动真实浮层，逐帧断言底边、底条尺寸与旧句位置。
compile_and_run subtitle_overlay_stability \
    "$project_dir/Sources/seesee/VideoSubtitles.swift" \
    "$project_dir/Sources/seesee/SubtitleOverlayLayout.swift" \
    "$project_dir/Sources/seesee/SubtitleSentenceBlocks.swift" \
    "$project_dir/Sources/seesee/SubtitleDispatch.swift" \
    "$project_dir/Sources/seesee/SponsorSkip.swift" \
    "$project_dir/Sources/seesee/LocalVideoPlayer.swift" \
    "$project_dir/tools/subtitle_overlay_stability_check.swift"
