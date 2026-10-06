#!/bin/bash
# 真实进程级：用构建出的 seesee 二进制加 --move-media-folder，在临时家目录搬 3 个小文件。
# SPM 可执行文件的偏好域是 seesee，不是打包应用的 ai.openmy.seesee。
# 成功一次（旧位置文件必须一个不少），再刻意造冲突失败一次。不碰真实片库。
set -euo pipefail

binary="${1:-}"
if [[ -z "$binary" || ! -x "$binary" ]]; then
    echo "用法: $0 <seesee二进制>" >&2
    exit 2
fi

real_movies="$HOME/Movies/seesee"
existing_pref=$(defaults read seesee MediaFolderPath 2>/dev/null || true)
if [[ -n "$existing_pref" && ( "$existing_pref" == "$real_movies" || "$existing_pref" == /Volumes/* ) ]]; then
    echo "拒绝：seesee 偏好域已指向真实片库 $existing_pref" >&2
    exit 3
fi
# 清掉上次实测残留，让 CFFIXED_USER_HOME 下的 ~/Movies/seesee 成为源。
defaults delete seesee MediaFolderPath 2>/dev/null || true

work=$(mktemp -d /tmp/seesee-launch-move.XXXXXX)
home="$work/home"
source_dir="$home/Movies/seesee"
dest_ok="$work/dest-ok"
dest_fail="$work/dest-fail"
support="$home/Library/Application Support/seesee"
prefs="$home/Library/Preferences"
id1="11111111-1111-1111-1111-111111111111"
id2="22222222-2222-2222-2222-222222222222"
id3="33333333-3333-3333-3333-333333333333"

cleanup() {
    if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    defaults delete seesee MediaFolderPath 2>/dev/null || true
    defaults delete seesee MediaFolderPreviousPath 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$source_dir" "$support" "$prefs" "$dest_ok" "$dest_fail"
write_library_files() {
    printf 'video-one-bytes\n' > "$source_dir/${id1}.mp4"
    printf 'video-two-bytes\n' > "$source_dir/${id2}.mp4"
    printf 'video-three-bytes\n' > "$source_dir/${id3}.mp4"
    printf 'thumb-one-bytes\n' > "$source_dir/${id1}.jpg"
    printf 'thumb-two-bytes\n' > "$source_dir/${id2}.jpg"
    printf 'thumb-three-bytes\n' > "$source_dir/${id3}.jpg"
    printf 'sub-one-bytes\n' > "$source_dir/${id1}.zh.srt"
    printf 'sub-two-bytes\n' > "$source_dir/${id2}.zh.srt"
    printf 'sub-three-bytes\n' > "$source_dir/${id3}.zh.srt"
}

write_library_files
hash1=$(/usr/bin/shasum -a 256 "$source_dir/${id1}.mp4" | awk '{print $1}')
hash2=$(/usr/bin/shasum -a 256 "$source_dir/${id2}.mp4" | awk '{print $1}')
hash3=$(/usr/bin/shasum -a 256 "$source_dir/${id3}.mp4" | awk '{print $1}')
hash1t=$(/usr/bin/shasum -a 256 "$source_dir/${id1}.jpg" | awk '{print $1}')
hash2t=$(/usr/bin/shasum -a 256 "$source_dir/${id2}.jpg" | awk '{print $1}')
hash3t=$(/usr/bin/shasum -a 256 "$source_dir/${id3}.jpg" | awk '{print $1}')
hash1s=$(/usr/bin/shasum -a 256 "$source_dir/${id1}.zh.srt" | awk '{print $1}')
hash2s=$(/usr/bin/shasum -a 256 "$source_dir/${id2}.zh.srt" | awk '{print $1}')
hash3s=$(/usr/bin/shasum -a 256 "$source_dir/${id3}.zh.srt" | awk '{print $1}')

write_queue() {
    python3 - "$support/queue.json" "$source_dir" "$id1" "$id2" "$id3" <<'PY'
import json, sys
path, folder, *ids = sys.argv[1:]
items = [
    {
        "id": ids[0],
        "urlString": "https://example.com/1",
        "title": "视频1",
        "author": "launch",
        "duration": 10,
        "addedAt": "2024-01-01T00:00:00Z",
        "watchedAt": "2024-02-01T00:00:00Z",
        "state": "ready",
        "progress": 1,
        "progressLabel": "已下载",
        "localFilePath": f"{folder}/{ids[0]}.mp4",
        "errorMessage": None,
        "playbackPosition": 30.5,
        "chapters": [
            {"title": "开场", "startTime": 0, "endTime": 12},
            {"title": "正片", "startTime": 12},
        ],
        "thumbnailFilePath": f"{folder}/{ids[0]}.jpg",
        "subtitleFilePath": f"{folder}/{ids[0]}.zh.srt",
    },
    {
        "id": ids[1],
        "urlString": "https://example.com/2",
        "title": "视频2",
        "author": "launch",
        "duration": 10,
        "addedAt": "2024-01-01T00:00:00Z",
        "watchedAt": None,
        "state": "ready",
        "progress": 1,
        "progressLabel": "已下载",
        "localFilePath": f"{folder}/{ids[1]}.mp4",
        "errorMessage": "上次下载中断过",
        "playbackPosition": None,
        "chapters": None,
        "thumbnailFilePath": f"{folder}/{ids[1]}.jpg",
        "subtitleFilePath": f"{folder}/{ids[1]}.zh.srt",
    },
    {
        "id": ids[2],
        "urlString": "https://example.com/3",
        "title": "视频3",
        "author": "launch",
        "duration": 10,
        "addedAt": "2024-01-01T00:00:00Z",
        "watchedAt": None,
        "state": "ready",
        "progress": 1,
        "progressLabel": "已下载",
        "localFilePath": f"{folder}/{ids[2]}.mp4",
        "errorMessage": None,
        "playbackPosition": None,
        "chapters": None,
        "thumbnailFilePath": f"{folder}/{ids[2]}.jpg",
        "subtitleFilePath": f"{folder}/{ids[2]}.zh.srt",
    },
]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(items, handle)
PY
}

write_queue
cp "$support/queue.json" "$work/queue.before.json"

if [[ "$source_dir" == "$real_movies" || "$dest_ok" == "$real_movies" ]]; then
    echo "拒绝：路径落到了真实片库" >&2
    exit 3
fi

file_hash() {
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

run_move() {
    local dest="$1"
    local log="$2"
    local until_source_gone="${3:-0}"
    CFFIXED_USER_HOME="$home" HOME="$home" \
        "$binary" --move-media-folder "$dest" >"$log" 2>&1 &
    app_pid=$!
    local waited=0
    local limit=15
    if [[ "$until_source_gone" != "1" ]]; then
        limit=6
    fi
    while kill -0 "$app_pid" 2>/dev/null && [[ $waited -lt $limit ]]; do
        sleep 1
        waited=$((waited + 1))
        if [[ "$until_source_gone" == "1" \
            && -f "$dest/${id1}.mp4" && -f "$dest/${id2}.mp4" && -f "$dest/${id3}.mp4" \
            && -f "$dest/${id1}.jpg" && -f "$dest/${id2}.jpg" && -f "$dest/${id3}.jpg" \
            && -f "$dest/${id1}.zh.srt" && -f "$dest/${id2}.zh.srt" && -f "$dest/${id3}.zh.srt" \
            && ! -f "$support/media-folder-move.inprogress" ]]; then
            sleep 1
            break
        fi
    done
    sleep 1
    if kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    app_pid=""
}

echo "=== 成功搬移 ==="
run_move "$dest_ok" "$work/success.log" 1

for id in "$id1" "$id2" "$id3"; do
    test -f "$dest_ok/${id}.mp4"
    test -f "$dest_ok/${id}.jpg"
    test -f "$dest_ok/${id}.zh.srt"
    test -f "$source_dir/${id}.mp4"
    test -f "$source_dir/${id}.jpg"
    test -f "$source_dir/${id}.zh.srt"
done
# 旧位置逐文件比对：切换后一个不少、内容不变。
test "$(file_hash "$source_dir/${id1}.mp4")" = "$hash1"
test "$(file_hash "$source_dir/${id2}.mp4")" = "$hash2"
test "$(file_hash "$source_dir/${id3}.mp4")" = "$hash3"
test "$(file_hash "$source_dir/${id1}.jpg")" = "$hash1t"
test "$(file_hash "$source_dir/${id2}.jpg")" = "$hash2t"
test "$(file_hash "$source_dir/${id3}.jpg")" = "$hash3t"
test "$(file_hash "$source_dir/${id1}.zh.srt")" = "$hash1s"
test "$(file_hash "$source_dir/${id2}.zh.srt")" = "$hash2s"
test "$(file_hash "$source_dir/${id3}.zh.srt")" = "$hash3s"
test "$(file_hash "$dest_ok/${id1}.mp4")" = "$hash1"
test "$(file_hash "$dest_ok/${id2}.mp4")" = "$hash2"
test "$(file_hash "$dest_ok/${id3}.mp4")" = "$hash3"
test "$(file_hash "$dest_ok/${id1}.jpg")" = "$hash1t"
test "$(file_hash "$dest_ok/${id2}.jpg")" = "$hash2t"
test "$(file_hash "$dest_ok/${id3}.jpg")" = "$hash3t"
test "$(file_hash "$dest_ok/${id1}.zh.srt")" = "$hash1s"
test "$(file_hash "$dest_ok/${id2}.zh.srt")" = "$hash2s"
test "$(file_hash "$dest_ok/${id3}.zh.srt")" = "$hash3s"
backup=$(ls "$support"/queue.json.bak-* 2>/dev/null | head -n 1)
test -n "$backup"
test -f "$backup"
python3 - "$support/queue.json" "$work/queue.before.json" "$backup" "$dest_ok" "$id1" "$id2" "$id3" <<'PY'
import json, os, sys
after_path, before_path, backup_path, dest, *ids = sys.argv[1:]
after = json.load(open(after_path, encoding="utf-8"))
before = json.load(open(before_path, encoding="utf-8"))
backup = json.load(open(backup_path, encoding="utf-8"))
all_keys = [
    "id", "urlString", "title", "author", "duration", "addedAt", "watchedAt",
    "state", "progress", "progressLabel", "localFilePath", "errorMessage",
    "playbackPosition", "chapters", "thumbnailFilePath", "subtitleFilePath",
]
path_keys = {"localFilePath", "thumbnailFilePath", "subtitleFilePath"}
suffix = {"localFilePath": ".mp4", "thumbnailFilePath": ".jpg", "subtitleFilePath": ".zh.srt"}

def by_id(items):
    return {item["id"]: item for item in items}

def same_path(left, right):
    if not left and not right:
        return True
    if not left or not right:
        return False
    return os.path.realpath(left) == os.path.realpath(right)

def same_value(left, right):
    if left == right:
        return True
    if isinstance(left, list) and isinstance(right, list):
        return [strip_nulls(item) for item in left] == [strip_nulls(item) for item in right]
    return strip_nulls(left) == strip_nulls(right)

def strip_nulls(value):
    if isinstance(value, dict):
        return {key: strip_nulls(item) for key, item in value.items() if item is not None}
    if isinstance(value, list):
        return [strip_nulls(item) for item in value]
    return value

if {item["id"] for item in after} != set(ids):
    raise SystemExit(f"queue id 集合不对: {[item['id'] for item in after]}")
before_map, backup_map, after_map = by_id(before), by_id(backup), by_id(after)
if {item["id"] for item in backup} != set(ids):
    raise SystemExit("备份 queue 条目与搬移前不一致")
for item_id in ids:
    original, remapped, saved = before_map[item_id], after_map[item_id], backup_map[item_id]
    extra = (set(original) | set(remapped) | set(saved)) - set(all_keys)
    if extra:
        raise SystemExit(f"{item_id} 出现未覆盖字段: {sorted(extra)}")
    for key in all_keys:
        if key in path_keys:
            expected = f"{dest}/{item_id}{suffix[key]}"
            if not same_path(remapped.get(key), expected):
                raise SystemExit(f"{item_id} {key} 未改到新目录: {remapped.get(key)} != {expected}")
            if not same_path(saved.get(key), original.get(key)):
                raise SystemExit(f"备份 {item_id} {key} 不是搬移前的值")
            continue
        if not same_value(original.get(key), remapped.get(key)) or not same_value(original.get(key), saved.get(key)):
            raise SystemExit(
                f"{item_id} 字段 {key} 被意外改动: before={original.get(key)} after={remapped.get(key)} backup={saved.get(key)}"
            )
PY
test ! -f "$support/media-folder-move.inprogress"
pref=$(defaults read seesee MediaFolderPath)
test "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$pref")" = "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dest_ok")"
echo "success dest=$dest_ok backup=$backup pref=$pref marker=cleared source_kept=9/9"

echo "=== 冲突失败回滚 ==="
write_queue
cp "$support/queue.json" "$work/queue.fail-before.json"
defaults delete seesee MediaFolderPath 2>/dev/null || true
defaults delete seesee MediaFolderPreviousPath 2>/dev/null || true
printf 'different-existing\n' > "$dest_fail/${id1}.mp4"
run_move "$dest_fail" "$work/fail.log" 0

for id in "$id1" "$id2" "$id3"; do
    test -f "$source_dir/${id}.mp4"
    test -f "$source_dir/${id}.jpg"
    test -f "$source_dir/${id}.zh.srt"
done
printf 'video-one-bytes\n' | cmp -s - "$source_dir/${id1}.mp4"
printf 'video-two-bytes\n' | cmp -s - "$source_dir/${id2}.mp4"
printf 'video-three-bytes\n' | cmp -s - "$source_dir/${id3}.mp4"
printf 'thumb-one-bytes\n' | cmp -s - "$source_dir/${id1}.jpg"
printf 'thumb-two-bytes\n' | cmp -s - "$source_dir/${id2}.jpg"
printf 'thumb-three-bytes\n' | cmp -s - "$source_dir/${id3}.jpg"
printf 'sub-one-bytes\n' | cmp -s - "$source_dir/${id1}.zh.srt"
printf 'sub-two-bytes\n' | cmp -s - "$source_dir/${id2}.zh.srt"
printf 'sub-three-bytes\n' | cmp -s - "$source_dir/${id3}.zh.srt"
printf 'different-existing\n' | cmp -s - "$dest_fail/${id1}.mp4"
test ! -f "$dest_fail/${id2}.mp4"
test ! -f "$dest_fail/${id3}.mp4"
test ! -f "$dest_fail/${id1}.jpg"
test ! -f "$dest_fail/${id2}.jpg"
test ! -f "$dest_fail/${id3}.jpg"
test ! -f "$dest_fail/${id1}.zh.srt"
test ! -f "$dest_fail/${id2}.zh.srt"
test ! -f "$dest_fail/${id3}.zh.srt"
python3 - "$support/queue.json" "$work/queue.fail-before.json" <<'PY'
import json, os, sys
after = json.load(open(sys.argv[1], encoding="utf-8"))
before = json.load(open(sys.argv[2], encoding="utf-8"))
all_keys = [
    "id", "urlString", "title", "author", "duration", "addedAt", "watchedAt",
    "state", "progress", "progressLabel", "localFilePath", "errorMessage",
    "playbackPosition", "chapters", "thumbnailFilePath", "subtitleFilePath",
]
path_keys = {"localFilePath", "thumbnailFilePath", "subtitleFilePath"}

def by_id(items):
    return {item["id"]: item for item in items}

def strip_nulls(value):
    if isinstance(value, dict):
        return {key: strip_nulls(item) for key, item in value.items() if item is not None}
    if isinstance(value, list):
        return [strip_nulls(item) for item in value]
    return value

def same(left, right, is_path):
    if not left and not right:
        return True
    if is_path and left and right:
        return os.path.realpath(left) == os.path.realpath(right)
    if left == right:
        return True
    return strip_nulls(left) == strip_nulls(right)

if [item["id"] for item in after] != [item["id"] for item in before]:
    raise SystemExit(f"失败后 queue 条目顺序或 id 变了: {[item['id'] for item in after]}")
after_map, before_map = by_id(after), by_id(before)
for item_id, original in before_map.items():
    remapped = after_map[item_id]
    extra = (set(original) | set(remapped)) - set(all_keys)
    if extra:
        raise SystemExit(f"失败后 {item_id} 出现未覆盖字段: {sorted(extra)}")
    for key in all_keys:
        if not same(remapped.get(key), original.get(key), key in path_keys):
            raise SystemExit(f"失败后 {item_id} 字段 {key} 被改写: {remapped.get(key)} != {original.get(key)}")
PY
test ! -f "$support/media-folder-move.inprogress"
if defaults read seesee MediaFolderPath >/dev/null 2>&1; then
    echo "失败后不得写入 MediaFolderPath" >&2
    exit 1
fi
echo "fail rollback source_kept dest_conflict_untouched marker=cleared pref_unchanged"

echo "media_folder_launch_move=passed work=$work"
