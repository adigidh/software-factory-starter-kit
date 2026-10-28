#!/usr/bin/env bash
# Schedule gate. Exit 0 runs the schedule's task, exit 1 skips this fire without waking a model.
# Writes the worklist to $STATE_DIR/worklist.json and prints that path.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

mkdir -p "$STATE_DIR"
out="$STATE_DIR/worklist.json"
"$HERE/worklist.sh" >"$out.tmp"
mv "$out.tmp" "$out"
echo "$out"
jq -e '(.orphaned | length) > 0 or ((.queued | length) > 0 and .slots > 0)' "$out" >/dev/null
