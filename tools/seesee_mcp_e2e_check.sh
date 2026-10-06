#!/bin/bash
# seesee MCP 端到端检查，从真实入口走：启动构建好的应用，打开一段带字幕的测试视频，
# 再起 seesee --mcp-stdio，调十个工具、验证真实播放状态，最后关掉应用走失败路径。
# SEESEE_MCP_PROOF_DIR 指定证明目录时，还会运行真实 claude -p 会话并截取测试窗口。
# 同时设 SEESEE_MCP_CLAUDE=0 时只截取测试窗口，不运行 claude -p 会话。
# 用法：tools/seesee_mcp_e2e_check.sh [应用路径]，默认 dist/seesee.app（先运行 SEESEE_INSTALL_APP=0 scripts/build_app.sh）。
# 会在后台开一个 seesee 窗口（不抢前台），跑完自动关掉。
# 不碰正在用的 seesee：测的是换了 bundle id 的副本，偏好设置写进单独的域；
# 家目录换成临时目录，队列、片库、查询通道都在里面。两样结束时都删掉。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_source="${1:-$project_dir/dist/seesee.app}"
bundle_id="ai.openmy.seesee.mcp"

if [[ ! -x "$app_source/Contents/MacOS/seesee" ]]; then
    echo "找不到应用：$app_source" >&2
    exit 2
fi

# 家目录放在 /private/tmp 下的短路径：查询通道的套接字路径不能超过 104 字节。
work_dir=$(mktemp -d /private/tmp/ssmcp.XXXXXX)
# 系统可能把路径报成 /tmp/...，按目录名匹配自己起的进程。
driver_pid=""
stop_children() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null || true); do
        stop_children "$child"
        kill -TERM "$child" >/dev/null 2>&1 || true
    done
}
cleanup() {
    if [[ -n "$driver_pid" ]]; then
        stop_children "$driver_pid"
        kill -TERM "$driver_pid" >/dev/null 2>&1 || true
        wait "$driver_pid" >/dev/null 2>&1 || true
    fi
    # 只处理本轮启动并登记的 pid。清理它的下载子进程，不按应用名找进程。
    if [[ -f "$work_dir/home/app.pid" ]]; then
        app_pid=$(cat "$work_dir/home/app.pid")
        if [[ "$app_pid" =~ ^[0-9]+$ ]]; then
            app_command=$(ps -p "$app_pid" -o command= 2>/dev/null || true)
            if [[ "$app_command" == "$work_dir/check.app/Contents/MacOS/seesee-mcp"* || "$app_command" == "/tmp/$(basename "$work_dir")/check.app/Contents/MacOS/seesee-mcp"* ]]; then
                stop_children "$app_pid"
                kill -TERM "$app_pid" >/dev/null 2>&1 || true
            fi
        fi
    fi
    defaults delete "$bundle_id" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$bundle_id.plist"
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# macOS 27 Command Line Tools SDK 缺 SwiftUI 宏插件时，改用相邻的 26 SDK（与 scripts/test.sh 相同）。
if [[ -z "${SDKROOT:-}" ]]; then
    default_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    default_sdk_version=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
    compatibility_sdk="$(dirname "$default_sdk")/MacOSX26.sdk"
    if [[ "$default_sdk_version" == 27.* && -d "$compatibility_sdk" ]]; then
        export SDKROOT="$compatibility_sdk"
    fi
fi

ditto "$app_source" "$work_dir/check.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$work_dir/check.app/Contents/Info.plist"
mv "$work_dir/check.app/Contents/MacOS/seesee" "$work_dir/check.app/Contents/MacOS/seesee-mcp"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable seesee-mcp" "$work_dir/check.app/Contents/Info.plist"
codesign --force --deep --sign - "$work_dir/check.app" >/dev/null 2>&1
mkdir -p "$work_dir/home"

swiftc -parse-as-library \
    "$project_dir/Sources/seesee/WatchItem.swift" \
    "$project_dir/tools/seesee_mcp_e2e_check.swift" \
    -o "$work_dir/driver"

"$work_dir/driver" --app "$work_dir/check.app" --home "$work_dir/home" --bundle-id "$bundle_id" &
driver_pid=$!
wait "$driver_pid"
driver_pid=""
