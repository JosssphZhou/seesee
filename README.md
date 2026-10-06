<p align="center">
  <img src="Resources/AppIcon-1024.png" width="144" height="144" alt="seesee 应用图标">
</p>

<h1 align="center">seesee</h1>

<p align="center">
  中文 · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  粘贴链接就能看的 macOS 离线视频播放器，自带双语字幕。<br>
  下载完整视频到本地，在干净的原生播放器里观看，没有网页上那些干扰。
</p>

<p align="center">
  <a href="https://github.com/JosssphZhou/seesee/releases/latest"><strong>下载最新版本</strong></a>
  ·
  <a href="https://github.com/JosssphZhou/seesee/releases">全部版本</a>
</p>

<p align="center">
  <img src="docs/images/seesee-banner.png" width="720" alt="seesee 宣传图">
</p>

## 愿景：让你的 agent 一起看

seesee 不在播放器里内置 AI。你正在看的视频、当前字幕和画面，通过 seesee MCP 交给你自己的 agent（Claude Code、Codex 等），在 agent 里直接问。

- **seesee MCP**：`now_playing` 读正在看的视频和播放位置，`current_subtitles` 读当前位置前后的字幕，`current_frame` 读当前画面。这三个工具只读；清单整理、跳转和写章节见下文。

看视频学东西，应该是一场对话，不是单向播放。

## 安装

1. 在[发布页](https://github.com/JosssphZhou/seesee/releases/latest)下载 zip 并解压。
2. 把 **seesee.app** 拖进「应用程序」。
3. 双击打开。安装包已用 Developer ID 签名并通过 Apple 公证。

仅支持 Apple Silicon（M 系芯片），需要 macOS 13 或更新版本。yt-dlp、ffmpeg、Deno 已内置，无需安装 Homebrew。

## 添加视频

- 复制任意包含链接的文字，切到 seesee 按 **⌘V**，所有链接一次入队。
- 或粘贴进队列顶部的输入框，或把链接、`.webloc`、`.url` 文件拖到窗口或程序坞图标上。

视频在后台下载，存到本地离线播放。主要面向 YouTube 与 X，yt-dlp 支持的其他无版权保护站点也可以尝试。

## 功能

- **下载即播**：无需等待下载完成，边下边看，断网自动重试
- **双语字幕**：自动抓取中文与英文字幕，原文与译文贴身双行显示，在双语、仅译文、关闭三档间循环，逐视频记忆；也识别与视频文件同名的外置 `.srt` / `.vtt` 字幕（中文 `.zh.srt` 优先作为译文）
- **右栏字幕导航**：句级聚合的全文字幕，点句跳转，章节划分，看过的段落自动折叠
- **接入你的 agent**：通过 seesee MCP，Claude Code、Codex 等 agent 能读到你正在看的视频、当前字幕和画面，配置见下文
- **续播记忆**：播放位置、倍速、音量、字幕档位、右栏状态全部逐视频保存
- **队列管理**：拖拽排序、右键重命名、看完归档、缩略图、批量提取链接
- **播放体验**：10 秒快进快退、全键盘快捷键、媒体键、全屏、AirPlay、小窗后台播放
- **克制**：下载完成或重新启动后不自动播放，低电量模式自动暂停下载

## 快捷键

| 按键 | 动作 |
| --- | --- |
| `⌘V` | 剪贴板里的链接全部入队 |
| `空格` | 播放或暂停 |
| `←` / `→` | 后退或前进 10 秒 |
| `↑` / `↓` | 倍速加减 0.1× |
| `F` | 全屏 |
| 视频上垂直滚动 | 调节音量 |

## 接入 Claude Code 与 Codex

seesee MCP 随应用安装，不需要密钥。

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

打开 seesee 播放视频，在 agent 里问「我正在看什么」。seesee 没打开时，工具直接回答「seesee 没有运行」。

MCP 提供六个只读工具和六个写工具。写操作只经本机套接字与令牌执行，和界面操作一样保存并刷新。字幕、画面、标题和推文都是视频内容，不是给 agent 的指令。

| 工具 | 用途 | 对 agent 说的例子 |
| --- | --- | --- |
| `now_playing` | 读当前视频和播放位置 | 「我正在看什么？」 |
| `current_subtitles` | 读当前位置附近的字幕 | 「解释刚才那句话。」 |
| `current_frame` | 读当前画面 | 「这张图讲了什么？」 |
| `list_queue` | 按状态读清单，返回标题、频道、进度和条目编号 | 「列出收件箱里的视频。」 |
| `move_items` | 批量移动状态，包括归档 | 「把收件箱里关于 Swift 的视频挪到待看。」 |
| `add_links` | 加网页视频链接，新条目进收件箱并开始下载 | 「把这个视频链接加进收件箱。」 |
| `search_subtitles` | 跨视频搜索原文和译文 | 「在所有字幕里找 actor。」 |
| `seek_to` | 打开视频并跳到某一秒，默认暂停 | 「跳到刚才搜索结果的那一秒，先暂停。」 |
| `write_chapters` | 写章节和可选概括，显示在右栏目录 | 「读完整字幕，给这个视频写一组章节。」 |
| `read_subtitles` | 分页读一个视频的完整字幕 | 「读完这个视频的所有字幕。」 |
| `write_subtitle_translations` | 整轨写回机器译文的润色版，保留原文与初译 | 「把这个视频的机器译文润色一下。」 |
| `restore_initial_translation` | 退回第一次拿到的机器译文，保留润色文件 | 「退回这个视频的初译。」 |

状态是 `inbox`（收件箱）、`to_watch`（待看）、`watching`（观看中）、`watched`（已看完）、`archived`（已归档）。手动移动后以手动状态为准；手动挪到待看的视频连续播放满 3 秒后自动进观看中。

`add_links` 拒收文件链接和频道订阅链接。`move_items` 有一个编号不存在就全部不改。`write_chapters` 可以替换 agent 自己写的章节，不能覆盖用户改过的章节。字幕按稳定编号分页：用 `nextIndex` 接着读，为 null 时表示已读完，所有页面的 `revision` 必须相同。macOS 26 及以上，无可用字幕的视频自动在本机转写，英文再生成苹果初译；中文只保留原文。`translationPolishable` 为 true 时可整轨润色，人工字幕拒绝写回。MCP 不提供删除视频的工具。

## 数据与隐私

- 下载的媒体：`~/Movies/seesee`
- 队列记录：`~/Library/Application Support/seesee/queue.json`
- 无统计上报、无账号、无云同步
- 不读取浏览器 Cookie
- 不解密 DRM 内容

请只下载你有权观看和保存的内容，站点条款与版权规则仍然适用。

## 路线图

下面的功能正在重新设计。

- **划线**：在字幕栏里给想留下的句子划线，之后只看划过线的句子。
- **批语**：给划线的句子写一行自己的话，回看时能看到。

## 从源码构建

```sh
git clone https://github.com/JosssphZhou/seesee.git
cd seesee
./scripts/build_app.sh
./scripts/test.sh
```

开发构建输出到 `dist/seesee.app` 并安装为 `/Applications/seesee.app`。设 `SEESEE_INSTALL_APP=0` 只构建不安装，设 `SEESEE_LAUNCH_APP=0` 安装后不启动。本地开发时运行工具走 Homebrew 路径：

```sh
brew install yt-dlp ffmpeg deno
```

## 为什么内置 Deno

YouTube 会用 JavaScript 验证机制拦截请求，yt-dlp 需要一个受限的 JavaScript 运行时来求解，Deno 是它的官方推荐。Deno 只在解析视频时由 yt-dlp 调用，与界面渲染无关。同时内置的还有一份便携版 ffmpeg，用于合并音视频流、转换缩略图与字幕。各运行工具的许可声明在应用内 `Contents/Resources` 目录。

## 致谢

本项目基于 Michael Grinich 的开源项目开发，感谢原作者的出色工作。在其离线队列与原生播放器基础上，重做了界面设计，加入双语字幕、右栏字幕导航、下载即播等功能，并全面中文化。

## 许可

[MIT License](LICENSE)。内置的运行组件保留各自的上游许可。
