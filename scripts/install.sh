#!/bin/bash
# 非交互安装已签名、公证的发布包；不修改清单、片库或客户端配置。
main() {
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

fail() { printf '安装停止：%s\n' "$*" >&2; exit 1; }
work=""; stage=""; lock=""; old_staged=""; trash_stage=""; committed=0
cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if [[ -n "$old_staged" && -d "$old_staged" && "$committed" == 0 ]]; then
        if [[ ! -e "$app" && ! -L "$app" ]] && mv -n "$old_staged" "$app"; then
            printf '已恢复旧应用：%s\n' "$app" >&2
        else
            printf '旧应用保留在 %s，请手动恢复。\n' "$old_staged" >&2
            stage=""
        fi
    fi
    [[ -z "$stage" ]] || rm -rf "$stage"
    [[ -z "$trash_stage" ]] || rm -rf "$trash_stage"
    [[ -z "$work" ]] || rm -rf "$work"
    if [[ -n "$lock" ]]; then
        rm -f "$lock/pid" "$lock/stage"
        rmdir "$lock" 2>/dev/null
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "需要 Apple Silicon Mac。"
os_major="$(sw_vers -productVersion | cut -d. -f1)"
(( os_major >= 13 )) || fail "需要 macOS 13 或更新版本。"

# 限制数值长度，避免未受约束的标签进入算术或文件路径。
valid_version() { [[ "$1" =~ ^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$ ]]; }
supported_version() {
    valid_version "$1" || return 1
    local major=$((10#${BASH_REMATCH[1]})) minor=$((10#${BASH_REMATCH[2]})) patch=$((10#${BASH_REMATCH[3]}))
    (( major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 1))) ))
}
requested="${SEESEE_VERSION:-}"; requested="${requested#v}"
if [[ -n "$requested" ]]; then
    supported_version "$requested" || fail "指定版本必须是 1.1.1 或更新的正式版本。"
fi
local_zip="${SEESEE_ZIP:-}"; local_sha="${SEESEE_SHA256_FILE:-}"
[[ -z "$local_zip" && -z "$local_sha" || -n "$local_zip" && -n "$local_sha" ]] || fail "SEESEE_ZIP 和 SEESEE_SHA256_FILE 必须一起提供。"
test_skip="${SEESEE_TEST_SKIP_NOTARIZATION:-0}"
[[ "$test_skip" == 0 || "$test_skip" == 1 ]] || fail "检查开关只能为 0 或 1。"
install_dir="${SEESEE_INSTALL_DIR:-/Applications}"
[[ "$install_dir" == /* && "$install_dir" != *$'\n'* ]] || fail "安装目录须为不含换行的绝对路径。"
if [[ -d "$install_dir" ]]; then install_dir="$(cd "$install_dir" && pwd -P)"; fi
if [[ "$test_skip" == 1 ]]; then
    [[ -n "$local_zip" && -d "$install_dir" && "$install_dir" == /private/tmp/* ]] || fail "TEST 开关只允许本地包和 /private/tmp 内已存在的安装目录。"
    printf '检查模式：跳过公证，仍校验 SHA-256、签名、Developer ID、团队号和 bundle id。\n'
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/seesee-install.XXXXXX")"
if [[ -n "$local_zip" ]]; then
    [[ -f "$local_zip" && -f "$local_sha" ]] || fail "找不到本地包或校验文件。"
    cp "$local_zip" "$work/payload.zip"
    cp "$local_sha" "$work/payload.sha256"
else
    repo=https://github.com/JosssphZhou/seesee
    if [[ -z "$requested" ]]; then
        release_url="$(curl --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 -fLsS -o /dev/null -w '%{url_effective}' "$repo/releases/latest")" || fail "无法取得 GitHub 最新发布。"
        case "$release_url" in "$repo/releases/tag/v"*) requested="${release_url##*/}"; requested="${requested#v}" ;; *) fail "无法识别最新发布地址。" ;; esac
        supported_version "$requested" || fail "最新发布尚未达到 1.1.1，请稍后再试。"
    fi
    asset="seesee-v${requested}-apple-silicon.zip"
    curl --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 600 -fLsS "$repo/releases/download/v$requested/$asset" -o "$work/payload.zip" || fail "发布包下载失败。"
    curl --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 -fLsS "$repo/releases/download/v$requested/$asset.sha256" -o "$work/payload.sha256" || fail "校验文件下载失败。"
fi
checksum_line="$(cat "$work/payload.sha256")"
[[ "$checksum_line" != *$'\n'* && "$checksum_line" =~ ^([0-9A-Fa-f]{64})[[:space:]][[:space:]].+$ ]] || fail "无法识别 .sha256：须为单条 SHA-256 与文件名。"
expected="$(printf '%s' "${BASH_REMATCH[1]}" | tr A-F a-f)"
actual="$(shasum -a 256 "$work/payload.zip" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || fail "SHA-256 校验失败，目标目录未改。"
printf 'SHA-256 校验通过。\n'

# 解压前限制成员路径和链接；发布包允许内部 Python.framework 等相对链接。
unzip -Z -1 "$work/payload.zip" > "$work/members" || fail "无法读取 ZIP。"
while IFS= read -r entry; do
    case "$entry" in /*|../*|*/../*|*/..|./*) fail "ZIP 含不安全路径。" ;; esac
    case "$entry" in seesee.app/|seesee.app/*|__MACOSX/|__MACOSX/*) ;; *) fail "ZIP 根目录须为 seesee.app。" ;; esac
done < "$work/members"
LC_ALL=C unzip -Z -l "$work/payload.zip" > "$work/entries" || fail "无法读取 ZIP 元数据。"
awk '$1 ~ /^l/ { line=$0; for (i=1;i<=9;i++) sub(/^[^[:space:]]+[[:space:]]+/, "", line); print line }' "$work/entries" > "$work/links"
while IFS= read -r entry; do
    [[ "$entry" != *[\*\?\[\]]* ]] || fail "ZIP 含无法核对的链接名。"
    link_target="$(unzip -p "$work/payload.zip" "$entry")" || fail "无法核对 ZIP 链接。"
    case "$link_target" in ""|/*|../*|*/../*|*/..|*$'\n'*) fail "ZIP 链接须留在应用内部。" ;; esac
done < "$work/links"
ditto -x -k "$work/payload.zip" "$work/unpacked" || fail "ZIP 解压失败。"
src="$work/unpacked/seesee.app"
[[ -d "$src" && ! -L "$src" && -f "$src/Contents/MacOS/seesee" && -x "$src/Contents/MacOS/seesee" ]] || fail "安装包结构不符。"
plist="$src/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" || fail "缺少应用版本。"
supported_version "$version" || fail "包内应用必须是 1.1.1 或更新的正式版本。"
[[ -z "$requested" || "$version" == "$requested" ]] || fail "包内版本与请求版本不同。"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" || fail "缺少 bundle id。"
[[ "$bundle_id" == ai.openmy.seesee ]] || fail "bundle id 不符。"
codesign --verify --deep --strict "$src" || fail "应用签名校验失败。"
codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "ANVS3UQK9W" and identifier "ai.openmy.seesee"' "$src" || fail "需要指定团队 ANVS3UQK9W 的 Developer ID 签名。"
if [[ "$test_skip" == 0 ]]; then
    assessment="$(spctl -a -vv --type execute "$src" 2>&1)" || fail "公证检查未通过：$assessment"
    [[ "$assessment" == *"source=Notarized Developer ID"* ]] || fail "应用不是已公证的 Developer ID 发布包：$assessment"
fi
printf '应用校验通过：seesee %s。\n' "$version"

mkdir -p "$install_dir" || fail "安装目录不可创建，不请求 sudo 或密码。"
install_dir="$(cd "$install_dir" && pwd -P)"
app="$install_dir/seesee.app"
[[ ! -L "$app" ]] || fail "目标应用不能是符号链接。"
[[ -w "$install_dir" ]] || fail "安装目录不可写，不请求 sudo 或密码。"
lock_candidate="$install_dir/.seesee-install.lock"
if ! mkdir "$lock_candidate" 2>/dev/null; then
    [[ -d "$lock_candidate" && ! -L "$lock_candidate" ]] || fail "无法创建安装锁：$lock_candidate"
    owner="$(cat "$lock_candidate/pid" 2>/dev/null)" || fail "安装锁缺少进程号，请核对后手动处理：$lock_candidate"
    [[ "$owner" =~ ^[1-9][0-9]*$ ]] || fail "安装锁进程号不符，请核对后手动处理：$lock_candidate"
    ! kill -0 "$owner" 2>/dev/null || fail "该目录已有安装在进行（PID ${owner}）：$lock_candidate"
    # 恢复操作也互斥；恢复本身被杀时保留现场，不让另一安装器误删旧版。
    mkdir "$lock_candidate/recovering" 2>/dev/null || fail "残留锁正在恢复或需手动处理：$lock_candidate"
    printf '发现已退出进程的残留安装锁，开始恢复：%s\n' "$lock_candidate"
    stale_stage="$(cat "$lock_candidate/stage" 2>/dev/null)" || stale_stage=""
    if [[ -n "$stale_stage" ]]; then
        [[ "${stale_stage%/*}" == "$install_dir" && "${stale_stage##*/}" == .seesee-install.* && "$stale_stage" != "$lock_candidate" && ! -L "$stale_stage" ]] || fail "残留锁的暂存路径不符，请手动处理：$lock_candidate"
        [[ ! -L "$stale_stage/old.app" ]] || fail "残留旧应用不能是链接：$lock_candidate"
        if [[ -d "$stale_stage/old.app" && ! -e "$app" && ! -L "$app" ]]; then
            mv -n "$stale_stage/old.app" "$app" || fail "无法恢复残留旧应用：$lock_candidate"
            [[ ! -e "$stale_stage/old.app" && -d "$app" ]] || fail "旧应用未恢复，请手动处理：$lock_candidate"
            printf '已恢复旧应用：%s\n' "$app"
        fi
        # 若新版已经放入，完整备份已在替换前保存；此处仅清理本次暂存目录。
        [[ -d "$app" || ! -e "$stale_stage/old.app" ]] || fail "旧应用仍在暂存目录，请手动处理：$lock_candidate"
        rm -rf "$stale_stage" || fail "无法清理残留暂存目录：$lock_candidate"
    fi
    rm -f "$lock_candidate/pid" "$lock_candidate/stage" || fail "无法清理残留锁：$lock_candidate"
    rmdir "$lock_candidate/recovering" "$lock_candidate" || fail "无法移除残留锁：$lock_candidate"
    mkdir "$lock_candidate" 2>/dev/null || fail "恢复后安装锁被占用：$lock_candidate"
fi
lock="$lock_candidate"
printf '%s\n' "$$" > "$lock/pid"

shell_quote() {
    local LC_ALL=C
    if [[ "$1" != *[^a-zA-Z0-9/._+@%:,=-]* && -n "$1" ]]; then printf '%s' "$1"
    else local escaped; escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; printf "'%s'" "$escaped"; fi
}
print_result() {
    printf '已安装版本：%s\n安装路径：%s\nClaude Code 接入命令：\nclaude mcp add --scope user seesee -- %s --mcp-stdio\n' "$version" "$app" "$(shell_quote "$app/Contents/MacOS/seesee")"
    printf '已开着的 Claude Code 或 Codex 会话要重开，或重新连接 seesee，才会用上新版。\n'
}
version_greater() {
    local left="$1" right="$2" a b c x y z
    valid_version "$left" || return 1
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); c=$((10#${BASH_REMATCH[3]}))
    valid_version "$right" || return 1
    x=$((10#${BASH_REMATCH[1]})); y=$((10#${BASH_REMATCH[2]})); z=$((10#${BASH_REMATCH[3]}))
    (( a > x || (a == x && (b > y || (b == y && c > z))) ))
}
old_version=""
if [[ -e "$app" ]]; then
    [[ -d "$app" ]] || fail "目标位置不是应用目录。"
    old_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" || fail "无法读取旧应用版本。"
    valid_version "$old_version" || fail "旧应用版本无法识别，请手动处理。"
    if version_greater "$old_version" "$version" && [[ "${SEESEE_ALLOW_DOWNGRADE:-0}" != 1 ]]; then
        fail "已装版本 $old_version 比待装版本 $version 更新；停止降级。确需降级可设 SEESEE_ALLOW_DOWNGRADE=1。"
    fi
    if [[ "$old_version" == "$version" ]]; then
        printf '已是版本 %s，不重装。\n' "$version"
        print_result
        exit 0
    fi
fi
stage="$(mktemp -d "$install_dir/.seesee-install.XXXXXX")"
printf '%s\n' "$stage" > "$lock/stage"
ditto "$src" "$stage/seesee.app" || fail "暂存新版失败，旧应用未动。"
codesign --verify --deep --strict "$stage/seesee.app" || fail "暂存新版签名损坏，旧应用未动。"

target_pids() {
    ps -axww -o pid=,comm= | while read -r pid process_path; do
        [[ "${process_path##*/}" == "$old_name" && "$process_path" == /* ]] || continue
        # 系统可能以/tmp记录启动路径，安装目录则为/private/tmp。两边按物理父目录比较。
        physical_path="$(cd "${process_path%/*}" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "${process_path##*/}")" || continue
        [[ "$physical_path" == "$old_executable" ]] || continue
        arguments="$(ps -ww -o args= -p "$pid")" || continue
        case " $arguments " in *" --mcp-stdio "*) continue ;; esac
        # 只有 AppKit 登记的图形应用才进入退出、等待名单。
        osascript -l AppleScript - "$pid" "$old_executable" <<'APPLESCRIPT'
use framework "AppKit"
on run argv
    set processID to (item 1 of argv) as integer
    set runningApp to current application's NSRunningApplication's runningApplicationWithProcessIdentifier:processID
    if runningApp is missing value then return ""
    set expectedURL to (current application's NSURL's fileURLWithPath:(item 2 of argv))'s URLByResolvingSymlinksInPath()
    set actualURL to runningApp's executableURL()'s URLByResolvingSymlinksInPath()
    if (actualURL's isEqual:expectedURL) as boolean then return processID as text
    return ""
end run
APPLESCRIPT
    done
}
backup_matches() {
    # 不跟随framework内部目录链接，逐个核对普通文件和链接目标，避免diff的目录循环。
    local directory output counter=0
    for directory in "$1" "$2"; do
        counter=$((counter + 1)); output="$work/backup-$counter.manifest"
        (
            cd "$directory"
            find . -type f -exec shasum -a 256 '{}' + || exit 1
            find . -type l -exec /bin/sh -c 'for link in "$@"; do printf "link %s -> %s\n" "$link" "$(readlink "$link")"; done' sh '{}' + || exit 1
        ) | LC_ALL=C sort > "$output" || return 1
    done
    cmp -s "$work/backup-1.manifest" "$work/backup-2.manifest"
}
if [[ -n "$old_version" ]]; then
    old_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" || fail "无法读取旧可执行文件。"
    [[ -n "$old_name" && "$old_name" != */* ]] || fail "旧可执行文件名不符。"
    old_executable="$app/Contents/MacOS/$old_name"
    pids="$(target_pids)"
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        printf '请求旧应用退出：PID %s，%s\n' "$pid" "$old_executable"
        osascript -l AppleScript - "$pid" "$old_executable" <<'APPLESCRIPT' || fail "无法请求旧应用退出，请手动退出后重试。"
use framework "AppKit"
on run argv
    set processID to (item 1 of argv) as integer
    set expectedPath to item 2 of argv
    set runningApp to current application's NSRunningApplication's runningApplicationWithProcessIdentifier:processID
    if runningApp is missing value then return
    set expectedURL to (current application's NSURL's fileURLWithPath:expectedPath)'s URLByResolvingSymlinksInPath()
    set actualURL to runningApp's executableURL()'s URLByResolvingSymlinksInPath()
    if (actualURL's isEqual:expectedURL) as boolean is false then error "进程可执行文件路径已改变，停止退出请求。"
    if (runningApp's terminate()) as boolean is false then error "应用拒绝退出。"
end run
APPLESCRIPT
    done <<< "$pids"
    for (( attempt=0; attempt<75; attempt++ )); do
        [[ -n "$(target_pids)" ]] || break
        sleep 0.2
    done
    [[ -z "$(target_pids)" ]] || fail "旧应用尚未退出，请手动退出后重试；旧应用没有被替换。"

    # 原应用仍在原位时复制并核对备份，避免复制期间出现应用空缺。
    backup_dir="$install_dir"
    trash_stage=""
    if [[ -d "$HOME/.Trash" && -w "$HOME/.Trash" ]]; then
        trash_stage="$(mktemp -d "$HOME/.Trash/.seesee-install.XXXXXX" 2>/dev/null)" || trash_stage=""
        if [[ -n "$trash_stage" ]]; then
            if ditto "$app" "$trash_stage/old.app" && backup_matches "$app" "$trash_stage/old.app"; then backup_dir="$HOME/.Trash"
            else rm -rf "$trash_stage" || true; trash_stage=""; fi
        fi
    fi
    backup="$backup_dir/seesee-$old_version.app"; suffix=1
    while [[ -e "$backup" || -L "$backup" ]]; do backup="$backup_dir/seesee-$old_version-$suffix.app"; (( suffix+=1 )); done
    if [[ -n "$trash_stage" ]] && mv -n "$trash_stage/old.app" "$backup" && [[ ! -e "$trash_stage/old.app" ]]; then
        rmdir "$trash_stage" || true
    else
        [[ -z "$trash_stage" ]] || rm -rf "$trash_stage" || true
        trash_stage=""
        backup_dir="$install_dir"
        backup="$backup_dir/seesee-$old_version.app"; suffix=1
        while [[ -e "$backup" || -L "$backup" ]]; do backup="$backup_dir/seesee-$old_version-$suffix.app"; (( suffix+=1 )); done
        # 废纸篓创建、复制或改名不可用时，旧应用备份留在同目录。
        ditto "$app" "$stage/backup.app" || fail "无法保存同目录备份。"
        backup_matches "$app" "$stage/backup.app" || fail "同目录备份与旧应用不符。"
        mv -n "$stage/backup.app" "$backup" || fail "无法放入同目录备份。"
        [[ ! -e "$stage/backup.app" ]] || fail "备份位置已出现同名文件，停止替换。"
    fi
    printf '旧应用备份：%s\n' "$backup"
    if [[ "$backup_dir" == "$install_dir" ]]; then
        printf '废纸篓不可写，旧版留在 %s；确认新版没问题后可以删掉。\n' "$backup"
    fi
    # 完整备份已经保存；目标空缺只发生在以下两次同卷改名之间。
    old_staged="$stage/old.app"
    mv -n "$app" "$old_staged" || fail "无法保留旧应用。"
fi
[[ ! -e "$app" && ! -L "$app" ]] || fail "目标应用已出现，停止替换。"
mv -n "$stage/seesee.app" "$app" || fail "无法放入新版应用。"
[[ ! -e "$stage/seesee.app" && -d "$app" ]] || fail "新版未放入目标，旧应用将恢复。"
committed=1
print_result

}
main "$@"
