# paper-translate

arXiv 論文を arq で取得し、pdf2zh + Ollama (minimax-m3:cloud) で日本語 PDF 化・要約し、引用関係・図・Obsidian ノートまで生成する基盤リポジトリ。

## ワークフロー

1. `arq get <arxiv_id>` — 論文を `papers/` に取得
2. watchexec デーモンが `paper.pdf` の追加を検知し、自動で以下を実行
   - `pdf2zh` による本文翻訳 → `paper_ja.pdf`
   - Ollama による日本語要約 → `summary.md`
   - Semantic Scholar から引用関係取得 → `references.json`
   - 図クロップ＋概要図サムネイル → `figures/fig-NN.png`・`overview.png`（`arq thumbnail` にも登録）
   - Obsidian ノート生成（引用 wikilink 付き）→ 各論文ディレクトリ内 `<snake_caseタイトル>.md`
   - 別名 symlink → `papers/by-title/<snake_caseタイトル>/`
   - `papers/` と `gallery.md` の変更を commit し、現在のブランチを `origin` へ push
3. `scripts/arq-select.sh`（または Ctrl-A）で閲覧、または Obsidian でギャラリー/グラフ表示

## ディレクトリ構成

```
papers/
├── arxiv.org/<category>/<id>/   # arq の実体（変更不可）
│   ├── paper.pdf                # 原文
│   ├── paper_ja.pdf             # 日本語訳
│   ├── summary.md               # 日本語要約
│   ├── references.json          # 引用・被引用（Semantic Scholar）
│   ├── figures/                 # Figure N ごとにクロップした図（+ figures.json）
│   ├── overview.png             # 選定した手法概要図（最高スコアの図クロップ）
│   ├── thumbnail.png            # arq thumbnail set が overview.png を複製
│   ├── <snake_caseタイトル>.md   # Obsidian ノート（生成物・git 管理）
│   └── meta.json                # arq 所有（手動編集禁止）
└── by-title/<snake_caseタイトル>/ # 上記実体への symlink（人間用の別名）

gallery.md                       # ルート直下の Dataview ギャラリー（一覧）
.obsidian/snippets/paper-gallery.css
```

> 図は PyMuPDF で「Figure N」キャプションごとに領域をクロップする（ベクタ図も可）。`overview.png`
> はキャプションのキーワード（Figure 1 / architecture / framework / overview …）で最高スコアの図。
> `thumbnail.png` は `arq thumbnail set` が overview.png を複製した arq view 用。自動選定が外れたら
> `<dir>/.overview-figure` に図番号を書いて `extract-figures.sh --force` で上書きできる。

## リポジトリ運用

[`taiseee/paper-translate`](https://github.com/taiseee/paper-translate) を公開 root repository とし、各利用者はその fork を使用する。
fork では `origin` を自分の fork、`upstream` を root repository に向ける。`papers/` も履歴に含め、PDF と PNG は Git LFS で管理する。
pdf2zh の中間生成物（`*-dual.pdf` / `*-mono.pdf`）とローカル実行環境・ログは追跡しない。

root repository の `papers/` は `.gitkeep` だけを保持し、論文本体・翻訳・生成物は置かない。
`.lfs-seed` は public fork でGit LFSを利用可能にする初期化ファイルであり、論文データは含まない。
論文ライブラリは各forkだけで管理する。

デーモンは処理完了後に `scripts/commit-paper-library.sh` を実行する。このスクリプトは `papers/` と
`gallery.md` だけを commit し、現在のブランチを `origin` へ push する。remote が先行・分岐している場合、
または未pushコミットにそれ以外のパスが含まれる場合は停止する。コード変更を自動公開することはない。
push先がroot repositoryの場合も停止する。

## セットアップ

```bash
# 初回のみ
scripts/setup.sh
scripts/install_agent.sh install

# Ollama 認証（minimax-m3:cloud に必要）
ollama signin
```

## コマンド

```bash
# 論文取得
arq get 2501.12345

# インタラクティブ選択（fzf）
scripts/arq-select.sh

# デーモン操作
scripts/install_agent.sh install
scripts/install_agent.sh status
scripts/install_agent.sh uninstall

# 手動で翻訳+要約+引用+図+ノート+by-title更新（未処理分をまとめて）
scripts/translate-papers-daemon.sh

# 単一論文の要約のみ生成（--force で再生成）
scripts/summarize-paper.sh papers/arxiv.org/cs.CL/1706.03762

# 引用関係を取得（Semantic Scholar）
scripts/fetch-references.sh papers/arxiv.org/cs.CL/1706.03762

# 図クロップ＋概要図サムネイル（--candidates-only で図抽出のみ）
scripts/extract-figures.sh papers/arxiv.org/cs.CL/1706.03762

# Obsidian ノート生成（引用 wikilink 付き）
scripts/generate-obsidian-note.sh papers/arxiv.org/cs.CL/1706.03762 --force

# by-title symlink の再構築
scripts/update-by-title.sh
```

## Obsidian で見る

リポジトリルートを Obsidian の vault として開く。`OBSIDIAN.md` にセットアップ手順あり（Dataview プラグイン + JavaScript Queries 有効化、`paper-gallery` CSS snippet 有効化）。ルート直下の `gallery.md` がカードギャラリー、グラフビューで引用 wikilink を辿れる。

## 環境変数

| 変数 | デフォルト | 説明 |
|---|---|---|
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama エンドポイント |
| `OLLAMA_MODEL` | `minimax-m3:cloud` | 翻訳・要約モデル |
| `SUMMARY_MAX_CHARS` | `50000` | 要約に渡す本文の最大文字数 |
| `S2_SLEEP` | `3` | Semantic Scholar 各呼び出し後のスリープ秒 |
| `S2_MAX_RETRY` | `4` | 429/5xx 時の最大リトライ回数（指数バックオフ 5→15→45…秒） |
| `S2_LIMIT` | `1000` | references/citations の取得上限 |
| `FIGURE_ZOOM` | `3` | 図クロップのレンダリング倍率 |
| `OVERVIEW_MAX_WIDTH` | `1400` | 概要図の最大幅(px) |
| `FIGURE_DPI` | `130` | フォールバック時のページ描画解像度 |
| `OVERVIEW_TOP_N` | `3` | フォールバック時の候補ページ数 |
| `PAPER_LIBRARY_AUTO_PUSH` | `1` | `0` にすると論文ライブラリの自動 commit/push を無効化 |
| `PAPER_LIBRARY_GIT_REMOTE` | `origin` | 論文ライブラリを push する Git remote |
| `PAPER_LIBRARY_GIT_BRANCH` | 現在のブランチ | push 先ブランチ（detached HEAD 時は指定必須） |
| `PAPER_LIBRARY_ROOT_REPOSITORY` | `taiseee/paper-translate` | 論文のcommitを禁止するroot repository |

`scripts/com.taisei.translate-papers.plist` の `EnvironmentVariables` で上書き可能。

## 要件

- `arq` (brew)
- `pdf2zh` (uv tool)
- `watchexec` (brew)
- `ollama`（`ollama signin` 済み）
- `fzf` (brew)
- `poppler`（`pdfinfo`/`pdftotext`/`pdftoppm`、フォールバック用、brew）
- `uv` + PyMuPDF（`scripts/setup.sh` が `.venv` に自動導入）
- `git-lfs`（`papers/` の PDF/PNG を管理、brew）
- `jq` (brew)、`python3`、`sips`（macOS 標準）
- Skim（PDF ビューア）
- Obsidian + Dataview プラグイン（ギャラリー表示）
