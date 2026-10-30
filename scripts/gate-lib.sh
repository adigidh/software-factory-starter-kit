#!/usr/bin/env bash
# Sourced by eval.sh and scan.sh (which set HERE first). Loads factory.conf and one job.
# shellcheck source=lib.sh
. "$HERE/lib.sh"

GATE_MODE="${GATE_MODE:-warn}"
GATE_TIMEOUT_SEC="${GATE_TIMEOUT_SEC:-900}"
case "$GATE_MODE" in
  shadow|warn|enforce) ;;
  *) echo "GATE_MODE must be shadow, warn or enforce (got '$GATE_MODE')" >&2; exit 2 ;;
esac
case "$GATE_TIMEOUT_SEC" in
  ''|*[!0-9]*) echo "GATE_TIMEOUT_SEC must be a number of seconds" >&2; exit 2 ;;
esac

# job_init <job-id> <round>. Sets: id job round_dir worktree branch BASE_REF
job_init() {
  id="$1"
  job="$CHECKOUT/factory/jobs/$id"
  [ -f "$job/job.json" ] || { echo "no job $id" >&2; exit 2; }
  case "$2" in ''|*[!0-9]*) echo "round must be a number" >&2; exit 2 ;; esac
  round_dir="$job/round-$2"
  mkdir -p "$round_dir"
  branch="$(jq -r .branch "$job/job.json")"
  worktree="$(jq -r .worktree "$job/job.json")"
  [ -d "$worktree" ] || { echo "worktree $worktree is missing" >&2; exit 2; }
  # The worktree is cut from origin/<base>; compare against that, not a stale local base.
  if git -C "$worktree" rev-parse --verify -q "origin/$BASE_BRANCH^{commit}" >/dev/null; then
    BASE_REF="origin/$BASE_BRANCH"
  else
    BASE_REF="$BASE_BRANCH"
  fi
}
