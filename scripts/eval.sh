#!/usr/bin/env bash
# Usage: eval.sh <job-id> <round>
# Runs the repo's quality gates in the job's worktree and writes <job>/round-<N>/eval.md.
# The gates are the `factory-gates` block of AGENTS.md (or CLAUDE.md) as it is on the
# BASE branch, so the branch under test cannot edit its own gates. One `name: command`
# per line. A gate that fails is re-run twice: failing every time is `fail`, passing on a
# re-run is `flaky`. Full logs go to <job>/round-<N>/eval/<name>.log and stay local; eval.md holds
# no command output so it is safe in a pull request body.
# Exit 0: nothing blocks. Exit 1: a gate blocks under GATE_MODE (see README).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=gate-lib.sh
. "$HERE/gate-lib.sh"
job_init "${1:?job id}" "${2:?round}"

RETRIES=2
out="$round_dir/eval.md"
logs="$round_dir/eval"
rm -rf "$logs"; mkdir -p "$logs"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

finish() { # verdict blocking(yes|no) reason
  { printf 'EVAL: %s\nMODE: %s\nBLOCKING: %s\n' "$1" "$GATE_MODE" "$2"
    [ -z "${3:-}" ] || printf '\n%s\n' "$3"
    [ ! -s "$tmp/rows" ] || { printf '\n| Gate | Result | Runs | Seconds |\n|---|---|---|---|\n'; cat "$tmp/rows"; }
    [ ! -s "$tmp/rows" ] || printf '\nLogs: factory/jobs/%s/%s/eval/<gate>.log (local only, not in the pull request).\n' "$id" "$(basename "$round_dir")"
  } >"$out.tmp"
  mv "$out.tmp" "$out"
  echo "eval: $1 (mode $GATE_MODE, blocking $2)"
  [ "$2" = no ] || exit 1
  exit 0
}
: >"$tmp/rows"

doc=""
for f in AGENTS.md CLAUDE.md; do
  d="$(git -C "$worktree" show "$BASE_REF:$f" 2>/dev/null)" || continue
  if grep -q '^```factory-gates[[:space:]]*$' <<<"$d"; then doc="$d"; break; fi
done
[ -n "$doc" ] || finish SKIPPED no "No \`factory-gates\` block in AGENTS.md on $BASE_REF, so nothing was run. The reviewers' own checks are the only quality evidence."

awk '/^```factory-gates[[:space:]]*$/{on=1;next} on&&/^```[[:space:]]*$/{exit} on{print}' <<<"$doc" >"$tmp/gates"

TO=""
if command -v timeout >/dev/null; then TO="timeout -k 10 $GATE_TIMEOUT_SEC"
elif command -v gtimeout >/dev/null; then TO="gtimeout -k 10 $GATE_TIMEOUT_SEC"; fi

n=0; failed=0; flaky=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  if [[ "$line" =~ ^([A-Za-z0-9._-]+):[[:space:]]+(.+)$ ]]; then
    name="${BASH_REMATCH[1]}"; cmd="${BASH_REMATCH[2]}"
  else
    : >"$tmp/rows"
    finish SKIPPED no "Malformed line in the factory-gates block (expected \`name: command\`): ${line:0:80}"
  fi
  n=$((n + 1))
  log="$logs/$name.log"; : >"$log"
  start=$SECONDS; attempt=0; result=fail; rc=0
  while [ "$attempt" -le "$RETRIES" ]; do
    attempt=$((attempt + 1))
    rc=0
    printf '== attempt %s ==\n' "$attempt" >>"$log"
    # shellcheck disable=SC2086
    (cd "$worktree" && $TO env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN bash -c "$cmd") </dev/null >>"$log" 2>&1 || rc=$?
    printf '== exit %s ==\n' "$rc" >>"$log"
    if [ "$rc" = 0 ]; then
      if [ "$attempt" = 1 ]; then result=pass; else result="flaky (passed on run $attempt)"; fi
      break
    fi
    [ "$rc" != 124 ] && [ "$rc" != 137 ] || break # a timeout will time out again
  done
  tail -c 20000 "$log" >"$log.tail"; mv "$log.tail" "$log"
  case "$result" in
    pass) ;;
    fail) failed=$((failed + 1)); [ "$rc" != 124 ] && [ "$rc" != 137 ] || result="fail (timed out after ${GATE_TIMEOUT_SEC}s)" ;;
    *) flaky=$((flaky + 1)) ;;
  esac
  printf '| %s | %s | %s | %s |\n' "$name" "$result" "$attempt" "$((SECONDS - start))" >>"$tmp/rows"
done <"$tmp/gates"

[ "$n" -gt 0 ] || finish SKIPPED no "The factory-gates block on $BASE_REF is empty, so nothing was run."

verdict=PASS; blocking=no
[ "$flaky" = 0 ] || verdict=FLAKY
[ "$failed" = 0 ] || verdict=FAIL
case "$GATE_MODE:$verdict" in
  warn:FAIL|enforce:FAIL|enforce:FLAKY) blocking=yes ;;
esac
finish "$verdict" "$blocking" "$n gate(s): $failed failed, $flaky flaky."
