#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

REMOTE="$TMP_ROOT/remote.git"
WORK="$TMP_ROOT/work"

git init --bare --quiet "$REMOTE"
git clone --quiet "$REMOTE" "$WORK"
git -C "$WORK" config user.name "Paper Library Test"
git -C "$WORK" config user.email "paper-library@example.com"
mkdir -p "$WORK/scripts" "$WORK/papers"
cp "$PROJECT_ROOT/scripts/commit-paper-library.sh" "$WORK/scripts/"
touch "$WORK/papers/.gitkeep"
printf '# Gallery\n' > "$WORK/gallery.md"
git -C "$WORK" add scripts papers gallery.md
git -C "$WORK" commit --quiet -m 'chore: 初期化'
git -C "$WORK" push --quiet -u origin HEAD:main
git -C "$WORK" branch -M main

paper_dir="$WORK/papers/arxiv.org/cs.CL/1706.03762"
mkdir -p "$paper_dir"
printf 'test paper\n' > "$paper_dir/paper.pdf"
printf '{"id":"1706.03762"}\n' > "$paper_dir/meta.json"

git -C "$WORK" remote set-url origin git@github.com:taiseee/paper-translate.git
if "$WORK/scripts/commit-paper-library.sh"; then
  echo 'expected the root-repository guard to reject paper changes' >&2
  exit 1
fi
git -C "$WORK" remote set-url origin "$REMOTE"

"$WORK/scripts/commit-paper-library.sh"

[[ "$(git --git-dir="$REMOTE" log -1 --format=%s main)" == 'docs: 論文 1706.03762 を追加' ]]
git --git-dir="$REMOTE" cat-file -e 'main:papers/arxiv.org/cs.CL/1706.03762/paper.pdf'

before="$(git -C "$WORK" rev-parse HEAD)"
"$WORK/scripts/commit-paper-library.sh"
[[ "$(git -C "$WORK" rev-parse HEAD)" == "$before" ]]

printf 'local code change\n' > "$WORK/README.md"
git -C "$WORK" add README.md
printf 'updated paper\n' >> "$paper_dir/paper.pdf"
"$WORK/scripts/commit-paper-library.sh"

git -C "$WORK" diff --cached --name-only | grep -qx 'README.md'
[[ "$(git --git-dir="$REMOTE" show main:README.md 2>/dev/null || true)" == '' ]]

before="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" commit --quiet -m 'feat: 未公開のコード変更'
printf 'updated paper\n' >> "$paper_dir/paper.pdf"

if "$WORK/scripts/commit-paper-library.sh"; then
  echo 'expected the safety check to reject an unrelated unpushed commit' >&2
  exit 1
fi

[[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$before" ]]
git -C "$WORK" status --short | grep -q 'paper.pdf'

echo 'commit-paper-library tests passed'
