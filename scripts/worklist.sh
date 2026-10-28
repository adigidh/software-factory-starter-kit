#!/usr/bin/env bash
# Prints the factory worklist as JSON. Read-only: it never edits labels.
#   queued    issues carrying the trigger label and no state label, whose label was last
#             applied by someone with write access, oldest first
#   orphaned  issues labelled in-progress with no live job (no job.json touched within
#             STALE_MIN minutes): the orchestrator marks them needs-human
#   ignored   labelled issues skipped, with the reason
#   slots     how many more jobs may start (MAX_PARALLEL minus live jobs)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

issues="$(gh issue list -R "$REPO" -l "$TRIGGER_LABEL" -s open -L 100 --json number,title,labels,createdAt)"

live='[]'
for f in "$CHECKOUT"/factory/jobs/*/job.json; do
  [ -f "$f" ] || continue
  [ -n "$(find "$f" -mmin "-$STALE_MIN" 2>/dev/null)" ] || continue
  live="$(jq -c --slurpfile j "$f" '. + [$j[0] | select(.stage | IN("spec","build","review","approve")) | .issue // empty]' <<<"$live")"
done

queued='[]'
ignored='[]'
candidates="$(jq -c --arg t "$TRIGGER_LABEL" '
  map(select(([.labels[].name] | map(select(startswith($t + ":"))) | length) == 0))
  | sort_by(.createdAt) | .[]' <<<"$issues")"
while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  n="$(jq -r .number <<<"$issue")"
  actor="$(gh api "repos/$REPO/issues/$n/events" --paginate \
    | jq -rs --arg t "$TRIGGER_LABEL" '[.[][] | select(.event=="labeled" and .label.name==$t)] | last | .actor.login // empty')"
  reason=""
  if [ -z "$actor" ]; then
    reason="no labeled event found"
  else
    perm="$(gh api "repos/$REPO/collaborators/$actor/permission" --jq .permission 2>/dev/null || echo none)"
    case "$perm" in admin|write) ;; *) reason="labelled by $actor, who lacks write access" ;; esac
  fi
  if [ -z "$reason" ]; then
    queued="$(jq -c --argjson i "$issue" --arg a "$actor" '. + [{number:$i.number, title:$i.title, labeledBy:$a}]' <<<"$queued")"
  else
    ignored="$(jq -c --argjson n "$n" --arg r "$reason" '. + [{number:$n, reason:$r}]' <<<"$ignored")"
  fi
done <<<"$candidates"

active="$(jq -c --arg a "$LABEL_ACTIVE" 'map(select([.labels[].name] | index($a))) | map(.number)' <<<"$issues")"
orphaned="$(jq -c --argjson live "$live" '. - $live' <<<"$active")"

jq -n -c --arg repo "$REPO" --argjson queued "$queued" --argjson ignored "$ignored" \
  --argjson active "$active" --argjson orphaned "$orphaned" --argjson max "$MAX_PARALLEL" '
  {repo:$repo, queued:$queued, orphaned:$orphaned, ignored:$ignored,
   slots: ([$max - (($active - $orphaned) | length), 0] | max)}'
