#!/usr/bin/env bash
# Usage: issue-labels.sh <issue-number> claim|pr|human
# Moves an issue to one state label and removes the others. The trigger label stays.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

n="${1:?issue number}"
case "${2:?claim|pr|human}" in
  claim) want="$LABEL_ACTIVE" ;;
  pr)    want="$LABEL_PR" ;;
  human) want="$LABEL_HUMAN" ;;
  *) echo "unknown state: $2" >&2; exit 2 ;;
esac

for l in "$LABEL_ACTIVE" "$LABEL_PR" "$LABEL_HUMAN"; do
  gh label create "$l" -R "$REPO" --force >/dev/null
done

have="$(gh issue view "$n" -R "$REPO" --json labels | jq -r '.labels[].name')"
args=(--add-label "$want")
for l in "$LABEL_ACTIVE" "$LABEL_PR" "$LABEL_HUMAN"; do
  if [ "$l" != "$want" ] && grep -qxF "$l" <<<"$have"; then args+=(--remove-label "$l"); fi
done
gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null
echo "#$n -> $want"
