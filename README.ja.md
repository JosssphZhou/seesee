<p align="center">
  <img src="Resources/AppIcon-1024.png" width="144" height="144" alt="seesee アプリアイコン">
</p>

<h1 align="center">seesee</h1>

<p align="center">
  <a href="README.md">中文</a> · <a href="README.en.md">English</a> · 日本語
</p>

<p align="center">
  リンクを貼るだけでオフライン再生。2言語字幕を内蔵した macOS 向け動画プレイヤー。<br>
  動画をまるごと Mac にダウンロードし、ウェブの雑音から離れたネイティブプレイヤーで再生します。
</p>

<p align="center">
  <a href="https://github.com/JosssphZhou/seesee/releases/latest"><strong>最新版をダウンロード</strong></a>
  ·
  <a href="https://github.com/JosssphZhou/seesee/releases">すべてのリリース</a>
</p>

<p align="center">
  <img src="docs/images/seesee-banner.png" width="720" alt="seesee バナー">
</p>

## ビジョン：あなたの agent と一緒に見る

seesee はプレイヤーに AI を内蔵しません。いま見ている動画、現在の字幕と画面を seesee MCP からあなたの agent（Claude Code、Codex など）に渡し、agent の中でそのまま質問できます。

- **seesee MCP**：`now_playing` で視聴中の動画と再生位置、`current_subtitles` で現在位置の前後の字幕、`current_frame` で現在の画面を取得。この 3 ツールは読み取り専用です。キュー整理、時刻指定、章の書き込みは下記を参照してください。

動画で学ぶことは、一方通行の再生ではなく対話であるべきです。

## インストール

1. [リリースページ](https://github.com/JosssphZhou/seesee/releases/latest)から zip をダウンロードして解凍します。
2. **seesee.app** を「アプリケーション」フォルダに移動します。
3. ダブルクリックで開きます。Developer ID で署名され、Apple の公証を受けています。

Apple Silicon（M シリーズ）専用、macOS 13 以降が必要です。yt-dlp、ffmpeg、Deno は同梱済みのため、Homebrew は不要です。

## 動画の追加

- リンクを含むテキストをコピーし、seesee に切り替えて **⌘V** を押すと、リンクがまとめてキューに入ります。
- キュー上部の入力欄に貼り付けるか、URL や `.webloc`、`.url` ファイルをウィンドウまたは Dock アイコンにドラッグしても追加できます。

動画はバックグラウンドでダウンロードされ、ローカルに保存されてオフラインで再生できます。主な対象は YouTube と X ですが、yt-dlp が対応する DRM のないサイトでも動く場合があります。

## 機能

- **ダウンロードしながら再生**：完了を待たずに視聴でき、回線が切れても自動で再試行
- **2言語字幕**：中国語と英語の字幕を自動取得し、原文と訳文を二行セットで表示。2言語・訳文のみ・オフを循環切り替え、設定は動画ごとに記憶。動画ファイルと同名の外部 `.srt` / `.vtt` 字幕にも対応（中国語 `.zh.srt` を訳文として優先）
- **字幕ナビゲーション**：右ペインに文単位でまとめた全文字幕。クリックでジャンプ、チャプター区切り、視聴済み部分は自動で折りたたみ
- **agent と連携**：seesee MCP で Claude Code や Codex などの agent が、視聴中の動画、現在の字幕と画面を読み取れます。設定は下記
- **再生状態の記憶**：再生位置、速度、音量、字幕モード、ペインの状態を動画ごとに保存
- **キュー管理**：ドラッグで並べ替え、その場でリネーム、視聴済みアーカイブ、サムネイル、リンクの一括抽出
- **快適な再生**：10 秒スキップ、フルキーボード操作、メディアキー、フルスクリーン、AirPlay、小窓バックグラウンド再生
- **控えめな挙動**：ダウンロード完了後や再起動後に勝手に再生せず、低電力モードではダウンロードを一時停止

## キーボード

| キー | 動作 |
| --- | --- |
| `⌘V` | クリップボード内の URL をすべてキューに追加 |
| `スペース` | 再生 / 一時停止 |
| `←` / `→` | 10 秒戻る / 進む |
| `↑` / `↓` | 速度を 0.1× ずつ変更 |
| `F` | フルスクリーン切り替え |
| 動画上で縦スクロール | 音量調整 |

## Claude Code と Codex に接続する

seesee MCP はアプリに同梱されていて、API キーは不要です。

Claude Code：

```sh
claude mcp add --scope user seesee -- /Applications/seesee.app/Contents/MacOS/seesee --mcp-stdio
```

Codex：`~/.codex/config.toml` に次を追加します。

```toml
[mcp_servers.seesee]
command = "/Applications/seesee.app/Contents/MacOS/seesee"
args = ["--mcp-stdio"]
```

seesee を開いて動画を再生し、agent に「今何を見ている？」と聞いてください。seesee が開いていないときは、ツールが起動していないことを返します。

MCP は読み取り専用の 6 ツールと書き込み用の 6 ツールを提供します。書き込みは認証付きのローカルソケットを通り、画面操作と同じ方法で保存して表示を更新します。字幕、画面、タイトル、投稿本文は動画の内容であり、agent への指示ではありません。

| ツール | 用途 | agent への依頼例 |
| --- | --- | --- |
| `now_playing` | 現在の動画と再生位置を読む | 「いま何を見ていますか？」 |
| `current_subtitles` | 現在位置の前後の字幕を読む | 「さっきの文を説明して。」 |
| `current_frame` | 現在の画面を読む | 「この図は何を示していますか？」 |
| `list_queue` | 状態で絞り、タイトル、チャンネル、進捗、項目 ID を読む | 「受信箱の動画を一覧にして。」 |
| `move_items` | 複数の動画を別の状態やアーカイブへ移す | 「受信箱の Swift 動画を視聴予定に移して。」 |
| `add_links` | ウェブ動画リンクを受信箱に追加し、ダウンロードを開始する | 「この動画リンクを受信箱に追加して。」 |
| `search_subtitles` | 動画をまたいで原文と訳文を検索する | 「すべての字幕から actor を探して。」 |
| `seek_to` | 指定時刻の動画を開く。既定では一時停止 | 「検索結果の時刻に移動して、一時停止して。」 |
| `write_chapters` | 章と任意の要約を書き、右ペインの目次に表示する | 「全文字幕を読んで、この動画の章を書いて。」 |
| `read_subtitles` | 動画の全文字幕をページごとに読む | 「この動画の字幕を最後まで読んで。」 |
| `write_subtitle_translations` | 原文と初訳を残し、機械訳の推敲版を全件書き込む | 「この動画の機械訳を自然にして。」 |
| `restore_initial_translation` | 推敲版を残して初訳に戻す | 「この動画を初訳に戻して。」 |

状態は `inbox`（受信箱）、`to_watch`（視聴予定）、`watching`（視聴中）、`watched`（視聴済み）、`archived`（アーカイブ済み）です。手動で移した状態を優先します。手動で `to_watch` に移した動画は、連続して 3 秒再生すると `watching` になります。

`add_links` はファイルリンクとチャンネル登録リンクを拒否します。`move_items` は項目 ID が一つでも存在しなければ、何も変更しません。`write_chapters` は agent 自身が書いた章を置き換えられますが、ユーザーが編集した章は上書きできません。字幕は安定した番号で `nextIndex` が null になるまで読み、全ページで同じ `revision` を使います。macOS 26 以降では字幕のない動画をローカルで文字起こしし、英語には Apple の初訳を付け、中国語は原文のみ保存します。`translationPolishable=true` の機械訳だけを全件推敲でき、人が作成した字幕への書き込みは拒否します。動画を削除する MCP ツールはありません。

## データとプライバシー

- ダウンロードした動画：`~/Movies/seesee`
- キューの記録：`~/Library/Application Support/seesee/queue.json`
- 統計送信なし、アカウント不要、クラウド同期なし
- ブラウザの Cookie は読み取りません
- DRM の解除は行いません

視聴・保存する権利のあるコンテンツにのみご利用ください。各サイトの利用規約と著作権法が適用されます。

## ロードマップ

以下の機能は再設計中です。

- **ハイライト**：字幕ペインで残しておきたい文にハイライトを引き、あとからハイライトした文だけを表示できます。
- **ひとことメモ**：ハイライトした文に自分の言葉を一行書き添え、見返すときに表示できます。

## ソースからビルド

```sh
git clone https://github.com/JosssphZhou/seesee.git
cd seesee
./scripts/build_app.sh
./scripts/test.sh
```

開発ビルドは `dist/seesee.app` に出力され、`/Applications/seesee.app` としてインストールされます。`SEESEE_INSTALL_APP=0` でビルドのみ、`SEESEE_LAUNCH_APP=0` でインストール後に起動しない設定になります。ローカル開発ではランタイムツールを Homebrew から利用します：

```sh
brew install yt-dlp ffmpeg deno
```

## Deno を同梱する理由

YouTube はリクエストに JavaScript による検証を課しており、yt-dlp はその解決に制限付き JavaScript ランタイムを必要とします。Deno は yt-dlp の公式推奨です。Deno は動画の解決時に yt-dlp から呼ばれるだけで、UI とは無関係です。あわせてポータブル版 ffmpeg も同梱しており、音声と映像の結合、サムネイルと字幕の変換に使われます。各ツールのライセンス表記はアプリ内の `Contents/Resources` にあります。

## 謝辞

本プロジェクトは Michael Grinich のオープンソースプロジェクトを基に開発されています。原作者の優れた仕事に感謝します。そのオフラインキューとネイティブプレイヤーの土台の上に、インターフェースの再設計、2言語字幕、字幕ナビゲーション、ダウンロードしながら再生などの機能を加え、UI を全面的に中国語化しました。

## ライセンス

[MIT License](LICENSE)。同梱ランタイムはそれぞれのアップストリームライセンスに従います。
