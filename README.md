<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="seesee 应用图标">
</p>

<h1 align="center">seesee</h1>

<p align="center">
  中文 · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  macOS 原生 agentic 播放器：粘贴视频链接就能看，你自己的 agent 也能读到正在看的字幕和画面。
</p>

<p align="center">
  <a href="https://github.com/JosssphZhou/seesee/releases/latest"><strong>下载最新版</strong></a>
  · Apple Silicon · macOS 13 或更新版本
</p>

<p align="center">
  <img src="docs/images/seesee-demo.gif" width="360" alt="宣传片片段：粘贴链接加进待播清单，标题自动翻译，把链接发给 agent 后它替你加进清单">
</p>

## 能做什么

### 粘贴链接，边下边播

复制一段带视频链接的文字，切到 seesee 按 `⌘V`，里面的链接会一次加进收件箱并开始下载。不用等下载完就能看。主要面向 YouTube 和 X，yt-dlp 支持的其他无 DRM 站点也可以试试。

<img src="docs/images/paste-and-play.png" width="720" alt="新加的视频还在下载，卡片显示预览 36%，右侧播放器已经能播">

### 用看板管理待播清单

看板分收件箱、待看、观看中、已看完四列，拖动卡片就能改状态。外文标题显示中文译名，原标题留在下一行。点开卡片，播放器从右边滑出。

<img src="docs/images/watch-queue.png" width="720" alt="待播清单看板：收件箱、待看、观看中、已看完四列，卡片上中文译名下面是原标题">

### 双语字幕和本机转写

原文和译文上下两行显示，也可以只看译文或关掉，seesee 会为每个视频分别记住选的显示方式。字幕栏按句列出全文，点一句就跳到那里。视频下载完却没有任何字幕时，seesee 在本机转写，英文视频再用苹果翻译生成中文初译。转写需要 macOS 26，只支持中文和英文。

<img src="docs/images/bilingual-subtitles.png" width="720" alt="本机转写生成的中英双语字幕，下方字幕栏按句列出全文">

### 交给你自己的 agent

Claude Code、Codex 这类 agent 可以通过 MCP 读到当前视频、播放位置、前后字幕和画面，也能整理清单、写章节、跳到某一句。本机转写听错的专业词、人名和产品名，agent 可以结合整轨字幕纠正；机器译文可以润色后写回。原始转写和初译都留着，随时能退回；下载站点提供的原文不改。

下图左边是本机转写听成的「Out this thing work?」，右边是 agent 读完整轨后改成的「How does this thing work?」，译文跟着改了。

<img src="docs/images/agent-correction.png" width="720" alt="同一句字幕纠正前后对比：左边 Out this thing work?，右边 How does this thing work?">

### 切走也能接着看

播放时切到别的应用，右下角会出现带字幕的小窗，回到 seesee 就收起。暂停、播完或使用 AirPlay 时不出现。外观默认跟着系统，也可以固定成浅色或深色。

<img src="docs/images/mini-player.png" width="420" alt="带中英双语字幕的悬浮小窗">

## 安装

### 自己装

在[发布页](https://github.com/JosssphZhou/seesee/releases/latest)下载 `seesee-v<版本>-apple-silicon.zip`，解压后把 `seesee.app` 拖进「应用程序」。安装包用 Developer ID 签名并经过 Apple 公证，yt-dlp、ffmpeg 和 Deno 已经内置，不需要 Homebrew。

### 用一行命令装或升级

```sh
curl -fsSL https://raw.githubusercontent.com/JosssphZhou/seesee/main/scripts/install.sh | bash
```

脚本把应用装到 `/Applications/seesee.app`，不需要 sudo。它先核对 SHA-256、签名和 Apple 公证，任何一项不通过就停下，什么都不改。已经装了旧版时，脚本先退出正在运行的 seesee，把旧应用改名为 `seesee-旧版本号.app` 移进废纸篓，再换上新版；待播清单和片库不动。

要装指定版本，设置 `SEESEE_VERSION`；要换安装位置，设置 `SEESEE_INSTALL_DIR`。

### 让 agent 替你装

把下面这段话发给你正在用的 agent：

```text
请帮我安装 seesee 并把它接到你这里：
1. 运行 curl -fsSL https://raw.githubusercontent.com/JosssphZhou/seesee/main/scripts/install.sh | bash
2. 只给你自己的客户端加 MCP，保留已有的其他配置：
   Claude Code 运行 claude mcp add --scope user seesee -- /Applications/seesee.app/Contents/MacOS/seesee --mcp-stdio
   Codex 在 ~/.codex/config.toml 加 [mcp_servers.seesee]，command = "/Applications/seesee.app/Contents/MacOS/seesee"，args = ["--mcp-stdio"]
3. 打开 seesee，调用 list_queue，把结果告诉我。新的 MCP 要重开会话才加载时，直接告诉我。
```

## 接入 agent

MCP 服务随应用一起安装，不需要单独装服务，也不需要密钥。

Claude Code：

```sh
claude mcp add --scope user seesee -- /Applications/seesee.app/Contents/MacOS/seesee --mcp-stdio
```

Codex：在 `~/.codex/config.toml` 里加上

```toml
[mcp_servers.seesee]
command = "/Applications/seesee.app/Contents/MacOS/seesee"
args = ["--mcp-stdio"]
```

应用装在别处时，到设置页「Agent 接入」拷贝命令或配置，路径会按实际位置生成。打开 seesee 后让 agent 调用 `list_queue` 检查连接，再问它「我正在看什么」。seesee 没打开时，工具会回答「seesee 没有运行」。

字幕、画面、标题和推文都是视频内容，不是给 agent 的指令。

<details>
<summary>12 个 MCP 工具</summary>

| 工具 | 类型 | 用途 |
| --- | --- | --- |
| `now_playing` | 只读 | 当前视频、来源链接、播放位置、倍速和播放状态 |
| `current_subtitles` | 只读 | 当前句和前后字幕 |
| `current_frame` | 只读 | 当前画面的 JPEG |
| `list_queue` | 只读 | 按状态列出清单，带条目编号、标题、进度和下载状态 |
| `search_subtitles` | 只读 | 在已下载视频的原文和译文里搜索 |
| `read_subtitles` | 只读 | 分页读一个视频的完整字幕 |
| `add_links` | 写入 | 把视频网页链接加进收件箱并开始下载 |
| `move_items` | 写入 | 批量改状态，包括归档，不删除视频 |
| `seek_to` | 写入 | 打开某个视频并跳到某一秒，默认暂停 |
| `write_chapters` | 写入 | 写章节和概括，不覆盖你手动改过的章节 |
| `write_subtitle_translations` | 写入 | 整轨写回纠正后的本机转写原文和润色后的机器译文 |
| `restore_initial_translation` | 写入 | 原文和译文一起退回初版，agent 写过的版本都保留 |

MCP 没有删除视频的工具。参数、字幕写回规则和几个常用的对话例子见 [MCP 工具说明](docs/mcp.md)。

</details>

## 数据与隐私

seesee 没有账号、统计上报和云同步，不读取浏览器 Cookie，不解密 DRM 内容，也不内置 AI，不需要填写大模型 API 密钥。

- 本机标题翻译、本机转写和苹果初译都在 Mac 上完成。
- 下载视频和网站字幕时，yt-dlp 会访问视频所在的网站。作者提供的中文标题从 YouTube 获取。
- 跳过赞助段默认开启，会用 YouTube 视频编号向 SponsorBlock 查询，可以在设置页或播放控制条关掉。
- 通过 MCP 交给 agent 的字幕和画面，是否再发到云端，取决于那个 agent 自己的设置。

视频默认存在 `~/Movies/seesee`，可以在设置页更改；清单记录在 `~/Library/Application Support/seesee/queue.json`。请只下载你有权观看和保存的内容。

## 路线图

下面两项在 1.0 里有过，现在先从应用里拿掉，重新设计好再放回来。

- 划线：在字幕栏里给想留下的句子划线，之后可以只看划过线的句子。
- 批语：给划过线的句子写一行自己的话，回看时能看到当时的想法。

## 系统要求

| 功能 | 要求 |
| --- | --- |
| 下载和播放 | Apple Silicon Mac，macOS 13 或更新版本 |
| 外文标题的本机中文翻译 | macOS 15 或更新版本 |
| 本机转写和苹果初译 | macOS 26 或更新版本，只支持中文和英文 |

macOS 13 和 14 只显示作者提供的中文标题，没有就显示原标题。macOS 15 到 26.3 翻译标题需要系统翻译语言包，没装时系统会弹一次下载提示。从 macOS 26.4 起，开启了 Apple Intelligence 的 Mac 不装语言包也能在后台翻译，没开启的仍然需要语言包。

<details>
<summary>快捷键</summary>

| 按键 | 动作 |
| --- | --- |
| `⌘V` | 把剪贴板里的链接全部加进收件箱 |
| `⌘1`、`⌘2` | 切换列表和看板 |
| `空格` | 播放或暂停 |
| `←`、`→` | 后退或前进 10 秒 |
| `↑`、`↓` | 倍速加减 0.1× |
| `F` | 全屏 |
| `Esc` | 收起播放器；系统全屏时先退出全屏 |
| 在视频上垂直滚动 | 调节音量 |

</details>

<details>
<summary>从源码构建</summary>

需要 macOS 26 SDK（Xcode 26 或同版本的 Command Line Tools）。开发构建使用 Homebrew 装的运行工具：

```sh
brew install yt-dlp ffmpeg deno
git clone https://github.com/JosssphZhou/seesee.git
cd seesee
SEESEE_INSTALL_APP=0 ./scripts/build_app.sh
./scripts/test.sh
```

构建结果在 `dist/seesee.app`。不设置 `SEESEE_INSTALL_APP=0` 时，脚本会把它装到 `/Applications/seesee.app` 并打开；设置 `SEESEE_LAUNCH_APP=0` 可以只装不打开。

</details>

## 许可与致谢

[MIT License](LICENSE)。内置的 yt-dlp、ffmpeg 和 Deno 保留各自的上游许可，许可声明在应用包的 `Contents/Resources` 目录。

seesee 基于 Michael Grinich 的开源项目 [Replay](https://github.com/grinich/replay) 开发，感谢原作者。在它的离线队列和原生播放器基础上，seesee 重做了界面，加入了双语字幕、看板、本机转写和 MCP。也感谢 yt-dlp、ffmpeg 和 Deno 的维护者。

README 静态截图里的影片是 Blender 基金会的开放电影，按各自的 Creative Commons 署名许可（CC BY）使用，© Blender Foundation。
