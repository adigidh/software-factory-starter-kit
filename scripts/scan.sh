#!/usr/bin/env bash
# Usage: scan.sh <job-id> <round>
# Runs whichever security scanners are installed against the job's change and writes
# <job>/round-<N>/scan.md. Scoped to what the branch adds: gitleaks over the branch's commits,
# semgrep against a baseline of the base branch, and npm audit / pip-audit compared
# with the base's dependency files, so an old vulnerability never blocks an unrelated
# job. scan.md names rule, file and line only: never a secret value or code.
# Exit 0: nothing blocks. Exit 1: blocking under GATE_MODE (see README).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=gate-lib.sh
. "$HERE/gate-lib.sh"
job_init "${1:?job id}" "${2:?round}"

SEMGREP_CONFIG="${SEMGREP_CONFIG:-p/default}"
out="$round_dir/scan.md"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
: >"$tmp/findings"; : >"$tmp/tools"
ran=0; errored=0

TO=""
if command -v timeout >/dev/null; then TO="timeout -k 10 $GATE_TIMEOUT_SEC"
elif command -v gtimeout >/dev/null; then TO="gtimeout -k 10 $GATE_TIMEOUT_SEC"; fi

tool_row() { printf '| %s | %s | %s |\n' "$1" "$2" "$3" >>"$tmp/tools"; }
tool_ok()  { ran=$((ran + 1)); tool_row "$1" ran "$2"; }
tool_err() { errored=$((errored + 1)); tool_row "$1" error "$2"; }
# add_findings <tool> <jq filter producing {rule,path,line,severity} objects>; reads stdin
add_findings() {
  jq -c --arg t "$1" "$2 | . + {tool:\$t}" >>"$tmp/findings"
}

changed="$(git -C "$worktree" diff --name-only "$BASE_REF...HEAD")"

# --- secrets ------------------------------------------------------------------------
if command -v gitleaks >/dev/null; then
  rc=0
  # shellcheck disable=SC2086
  $TO gitleaks detect --source "$worktree" --log-opts="$BASE_REF..HEAD" --redact --no-banner \
    --report-format json --report-path "$tmp/gl.json" --exit-code 0 </dev/null >"$tmp/gl.out" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && { [ ! -e "$tmp/gl.json" ] || jq -e 'type=="array" or .==null' "$tmp/gl.json" >/dev/null 2>&1; }; then
    [ ! -s "$tmp/gl.json" ] || jq -c '(. // [])[] | {rule:.RuleID, path:.File, line:.StartLine, severity:"critical"}' "$tmp/gl.json" \
      | add_findings gitleaks '.'
    tool_ok gitleaks "commits $BASE_REF..HEAD"
  else
    tool_err gitleaks "failed or timed out (exit $rc)"
  fi
else
  tool_row gitleaks "not installed" "secrets in the branch's commits were not scanned"
fi

# --- code ---------------------------------------------------------------------------
if command -v semgrep >/dev/null; then
  rc=0
  (cd "$worktree" && $TO semgrep scan --config "$SEMGREP_CONFIG" --baseline-commit "$BASE_REF" \
      --json --quiet --metrics=off --disable-version-check .) </dev/null >"$tmp/sg.json" 2>"$tmp/sg.err" || rc=$?
  if [ "$rc" = 0 ] && jq -e '.results' "$tmp/sg.json" >/dev/null 2>&1; then
    jq -c '.results[] | {rule:.check_id, path:.path, line:.start.line,
        severity:(if .extra.severity=="ERROR" then "high" elif .extra.severity=="WARNING" then "medium" else "low" end)}' \
      "$tmp/sg.json" | add_findings semgrep '.'
    nerr="$(jq '.errors | length' "$tmp/sg.json")"
    tool_ok semgrep "rules $SEMGREP_CONFIG, new findings vs $BASE_REF$([ "$nerr" = 0 ] || printf ', %s rule/file errors' "$nerr")"
  else
    tool_err semgrep "failed or timed out (exit $rc); rules $SEMGREP_CONFIG may need network access"
  fi
else
  tool_row semgrep "not installed" "code was not scanned"
fi

# --- dependencies: only what the branch adds over the base ---------------------------
base_file() { git -C "$worktree" show "$BASE_REF:$1" 2>/dev/null; }

# jq filter that turns `npm audit --json` into "name<TAB>severity" lines
npm_lines='.vulnerabilities | to_entries[] | [.key, (if .value.severity=="moderate" then "medium" else .value.severity end)] | @tsv'

npm_audit() { # dir -> lines on stdout; non-zero when npm audit itself could not run
  (cd "$1" && $TO npm audit --package-lock-only --omit=dev --json) </dev/null >"$1/audit.json" 2>/dev/null || true
  jq -e '.vulnerabilities' "$1/audit.json" >/dev/null 2>&1 || return 1
  jq -r "$npm_lines" "$1/audit.json"
}

if grep -qE '^package(-lock)?\.json$' <<<"$changed" && [ -f "$worktree/package-lock.json" ]; then
  if command -v npm >/dev/null; then
    mkdir -p "$tmp/npm-head" "$tmp/npm-base"
    cp "$worktree/package.json" "$worktree/package-lock.json" "$tmp/npm-head/"
    if npm_audit "$tmp/npm-head" >"$tmp/npm-head.txt"; then
      if base_file package.json >"$tmp/npm-base/package.json" && base_file package-lock.json >"$tmp/npm-base/package-lock.json"; then
        npm_audit "$tmp/npm-base" >"$tmp/npm-base.txt" || : >"$tmp/npm-base.txt"
      else
        : >"$tmp/npm-base.txt"
      fi
      # new = a package whose severity is not already on the base
      grep -vxFf "$tmp/npm-base.txt" "$tmp/npm-head.txt" \
        | jq -R -c 'split("\t") | {rule:.[0], path:"package-lock.json", line:0, severity:.[1]}' \
        | add_findings npm-audit '.' || true
      tool_ok npm-audit "package-lock.json, new vs $BASE_REF"
    else
      tool_err npm-audit "could not run (registry unreachable or lockfile unreadable)"
    fi
  else
    tool_row npm-audit "not installed" "package-lock.json changed but npm is missing"
  fi
else
  tool_row npm-audit skipped "package-lock.json unchanged"
fi

reqs="$(grep -E '(^|/)requirements[^/]*\.txt$' <<<"$changed" || true)"
if [ -n "$reqs" ]; then
  if command -v pip-audit >/dev/null; then
    pip_bad=0; : >"$tmp/pip-head.txt"; : >"$tmp/pip-base.txt"
    while IFS= read -r r; do
      [ -f "$worktree/$r" ] || continue
      pip_lines='.dependencies[] | select(.vulns|length>0) | .name as $n | .vulns[] | "\($n)\t\(.id)\t\($r)"'
      rc=0; $TO pip-audit -r "$worktree/$r" --format json --progress-spinner off </dev/null >"$tmp/pa.json" 2>/dev/null || rc=$?
      if jq -e '.dependencies' "$tmp/pa.json" >/dev/null 2>&1; then jq -r --arg r "$r" "$pip_lines" "$tmp/pa.json" >>"$tmp/pip-head.txt"; else pip_bad=1; fi
      if base_file "$r" >"$tmp/base-req.txt"; then
        $TO pip-audit -r "$tmp/base-req.txt" --format json --progress-spinner off </dev/null >"$tmp/pa.json" 2>/dev/null || true
        jq -r --arg r "$r" "$pip_lines" "$tmp/pa.json" >>"$tmp/pip-base.txt" 2>/dev/null || true
      fi
    done <<<"$reqs"
    if [ "$pip_bad" = 0 ]; then
      grep -vxFf "$tmp/pip-base.txt" "$tmp/pip-head.txt" \
        | jq -R -c 'split("\t") | {rule:"\(.[0]) \(.[1])", path:.[2], line:0, severity:"high"}' \
        | add_findings pip-audit '.' || true
      tool_ok pip-audit "requirements files changed, new vs $BASE_REF"
    else
      tool_err pip-audit "could not run (index unreachable or file unparsable)"
    fi
  else
    tool_row pip-audit "not installed" "a requirements file changed but pip-audit is missing"
  fi
else
  tool_row pip-audit skipped "no requirements file changed"
fi

# --- verdict ------------------------------------------------------------------------
# Strip anything that could carry a value or markup into a pull request body.
jq -c 'map_values(if type=="string" then (gsub("[^A-Za-z0-9._/@+:#, -]";"?") | .[0:120]) else . end)' \
  "$tmp/findings" >"$tmp/clean" 2>/dev/null || : >"$tmp/clean"
total="$(wc -l <"$tmp/clean" | tr -d ' ')"
serious="$(jq -s '[.[] | select(.severity=="critical" or .severity=="high")] | length' "$tmp/clean")"

if [ "$total" -gt 0 ]; then verdict=FINDINGS
elif [ "$ran" = 0 ] || [ "$errored" -gt 0 ]; then verdict=INCOMPLETE
else verdict=CLEAN; fi

blocking=no
case "$GATE_MODE" in
  warn)    [ "$serious" -eq 0 ] || blocking=yes ;;
  enforce) { [ "$total" -gt 0 ] || [ "$verdict" = INCOMPLETE ]; } && blocking=yes ;;
esac

{
  printf 'SCAN: %s\nMODE: %s\nBLOCKING: %s\n\n' "$verdict" "$GATE_MODE" "$blocking"
  printf '%s finding(s), %s high or critical. Scanners that ran: %s.\n' "$total" "$serious" "$ran"
  [ "$ran" != 0 ] || printf 'No scanner ran, so this branch has had no automated security scan.\n'
  printf '\n| Tool | Status | Note |\n|---|---|---|\n'; cat "$tmp/tools"
  if [ "$total" -gt 0 ]; then
    printf '\n| Severity | Tool | Rule | Location |\n|---|---|---|---|\n'
    jq -s -r 'sort_by(.severity as $s | ["critical","high","medium","low"] | index($s)) | .[0:50][]
      | "| \(.severity) | \(.tool) | \(.rule) | \(.path):\(.line) |"' "$tmp/clean"
    [ "$total" -le 50 ] || printf '\n%s more not shown.\n' "$((total - 50))"
  fi
} >"$out.tmp"
mv "$out.tmp" "$out"
echo "scan: $verdict (mode $GATE_MODE, blocking $blocking)"
[ "$blocking" = no ] || exit 1
exit 0
