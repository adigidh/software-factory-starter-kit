#!/usr/bin/env bash
# Usage: open-pr.sh <job-id> ready|draft
# Pushes the job branch and opens (or updates) its pull request. Never merges.
# Prints the PR URL. Exit 3 when the branch has no commits to propose. Exit 4 when the
# last security scan found a secret in the branch's commits: nothing is pushed.
# When the job has an issue, moves its label and links the PR there.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

id="${1:?job id}"
mode="${2:?ready|draft}"
case "$mode" in ready|draft) ;; *) echo "mode must be ready or draft" >&2; exit 2 ;; esac

job="$CHECKOUT/factory/jobs/$id"
[ -f "$job/job.json" ] || { echo "no job $id" >&2; exit 2; }
branch="$(jq -r .branch "$job/job.json")"
worktree="$(jq -r .worktree "$job/job.json")"
issue="$(jq -r '.issue // empty' "$job/job.json")"
feature="$(jq -r .feature "$job/job.json")"

[ "$(git -C "$worktree" rev-list --count "$BASE_BRANCH..$branch")" -gt 0 ] \
  || { echo "$branch has no commits ahead of $BASE_BRANCH" >&2; exit 3; }

last_round="$(ls -1 "$job" | sed -n 's/^round-//p' | sort -n | tail -1)"
round_dir="${last_round:+$job/round-$last_round}"
# Whatever the gate mode, a branch with a leaked secret in its commits is never pushed.
if [ -n "$round_dir" ] && grep -q '^| critical | gitleaks |' "$round_dir/scan.md" 2>/dev/null; then
  echo "scan.md reports a secret in the commits of $branch: not pushed. Remove it from history and rotate it." >&2
  exit 4
fi
git -C "$worktree" push -u origin "$branch" >&2

title="$(sed -n 's/^# //p;T;q' "$job/spec.md" 2>/dev/null || true)"
title="${title:-$feature}"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
{
  if [ -n "$issue" ]; then printf 'Closes #%s\n\n' "$issue"; fi
  printf 'Opened by the software factory (job `%s`, branch `%s`). Review it like any PR; the factory never merges.\n\n' "$id" "$branch"
  if [ -f "$job/decision.md" ]; then printf '## Approver decision\n\n%s\n\n' "$(cat "$job/decision.md")"; fi
  for f in eval scan; do
    if [ -n "$round_dir" ] && [ -f "$round_dir/$f.md" ]; then printf '## Gate: %s (round %s)\n\n%s\n\n' "$f" "$last_round" "$(cat "$round_dir/$f.md")"; fi
  done
  for f in spec build; do
    if [ -f "$job/$f.md" ]; then printf '<details><summary>%s.md</summary>\n\n%s\n\n</details>\n\n' "$f" "$(cat "$job/$f.md")"; fi
  done
} | head -c 60000 >"$body"

existing="$(gh pr list -R "$REPO" --head "$branch" --state open --json number,url,isDraft)"
if [ "$(jq length <<<"$existing")" -gt 0 ]; then
  num="$(jq -r '.[0].number' <<<"$existing")"
  url="$(jq -r '.[0].url' <<<"$existing")"
  gh pr edit "$num" -R "$REPO" --body-file "$body" >/dev/null
  if [ "$mode" = ready ] && [ "$(jq -r '.[0].isDraft' <<<"$existing")" = true ]; then
    gh pr ready "$num" -R "$REPO" >/dev/null
  fi
else
  draft_flag=""
  if [ "$mode" = draft ]; then draft_flag="--draft"; fi
  # shellcheck disable=SC2086
  url="$(gh pr create -R "$REPO" --head "$branch" --base "$BASE_BRANCH" --title "$title" --body-file "$body" $draft_flag)"
fi

if [ -n "$issue" ]; then
  if [ "$mode" = ready ]; then
    "$HERE/issue-labels.sh" "$issue" pr >/dev/null
    gh issue comment "$issue" -R "$REPO" --body "Pull request ready for review: $url" >/dev/null
  else
    "$HERE/issue-labels.sh" "$issue" human >/dev/null
    gh issue comment "$issue" -R "$REPO" --body "The factory needs a human on this one. Draft pull request: $url. Remove the \`$LABEL_HUMAN\` label to run it again." >/dev/null
  fi
fi
echo "$url"
