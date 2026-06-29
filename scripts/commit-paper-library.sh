#!/usr/bin/env bash
# Commit and push generated paper-library changes without including code edits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE="${PAPER_LIBRARY_GIT_REMOTE:-origin}"
ROOT_REPOSITORY="${PAPER_LIBRARY_ROOT_REPOSITORY:-taiseee/paper-translate}"

log() {
  printf '[paper-library-git] %s\n' "$*" >&2
}

git_root() {
  git -C "$ROOT" "$@"
}

branch="${PAPER_LIBRARY_GIT_BRANCH:-$(git_root symbolic-ref --quiet --short HEAD || true)}"
if [[ -z "$branch" ]]; then
  log "ERROR: detached HEAD; set PAPER_LIBRARY_GIT_BRANCH or checkout a branch"
  exit 1
fi

if ! remote_url="$(git_root remote get-url "$REMOTE" 2>/dev/null)"; then
  log "ERROR: Git remote '$REMOTE' does not exist"
  exit 1
fi

remote_repository="$(printf '%s' "$remote_url" \
  | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
if [[ "$remote_repository" == "$ROOT_REPOSITORY" ]]; then
  log "ERROR: refusing to commit papers to root repository $ROOT_REPOSITORY"
  exit 1
fi

# Fetch first so automation never overwrites remote work or publishes unrelated
# local commits. A previous paper-only commit is safe to retry after a failed push.
if ! git_root fetch --quiet "$REMOTE" "$branch"; then
  log "ERROR: failed to fetch $REMOTE/$branch; leaving library changes uncommitted"
  exit 1
fi

remote_ref="refs/remotes/$REMOTE/$branch"
if ! git_root merge-base --is-ancestor "$remote_ref" HEAD; then
  log "ERROR: $REMOTE/$branch is not an ancestor of HEAD; reconcile the branch manually"
  exit 1
fi

unsafe_paths=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    papers/* | gallery.md) ;;
    *) unsafe_paths+=("$path") ;;
  esac
# Inspect every unpushed commit, not only the aggregate tree diff. This also
# catches a code change that was reverted by a later local commit.
done < <(git_root log --format= --name-only "$remote_ref"..HEAD)

if [[ ${#unsafe_paths[@]} -gt 0 ]]; then
  log "ERROR: unpushed commits contain changes outside papers/ and gallery.md:"
  printf '  %s\n' "${unsafe_paths[@]}" >&2
  exit 1
fi

git_root add -A -- papers gallery.md

if ! git_root diff --cached --quiet -- papers gallery.md; then
  added_ids=()
  while IFS= read -r paper; do
    [[ -z "$paper" ]] && continue
    added_ids+=("$(basename "$(dirname "$paper")")")
  done < <(git_root diff --cached --diff-filter=A --name-only -- ':(glob)papers/**/paper.pdf')

  case "${#added_ids[@]}" in
    0) message="docs: 論文ライブラリを更新" ;;
    1) message="docs: 論文 ${added_ids[0]} を追加" ;;
    *) message="docs: 論文ライブラリに${#added_ids[@]}件追加" ;;
  esac

  # --only prevents unrelated pre-staged changes from entering this commit.
  git_root commit --only -m "$message" -- papers gallery.md
  log "committed: $message"
else
  log "no paper-library changes to commit"
fi

if git_root diff --quiet "$remote_ref"..HEAD; then
  log "nothing to push"
  exit 0
fi

git_root push "$REMOTE" "HEAD:refs/heads/$branch"
log "pushed: $REMOTE/$branch"
