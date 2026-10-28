#!/usr/bin/env bash
# Stub tests for the factory scripts. No network: a fake gh replays fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
chmod +x "$HERE/bin/gh"
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="$HERE/bin:$PATH" FAKE_GH_DIR="$T/gh" FACTORY_CONF="$T/factory.conf" FACTORY_STATE_DIR="$T/state"
mkdir -p "$T/gh" "$T/repo/factory/jobs"
printf 'REPO=o/r\nCHECKOUT=%s\nMAX_PARALLEL=2\n' "$T/repo" >"$FACTORY_CONF"
now='2026-01-01T00:00:00Z'

issue() { # number title createdAt labels...
  local n=$1 t=$2 c=$3; shift 3
  local l; l="$(printf '%s\n' "$@" | jq -R '{name:.}' | jq -sc .)"; [ $# -eq 0 ] && l='[]'
  jq -nc --argjson n "$n" --arg t "$t" --arg c "$c" --argjson l "$l" '{number:$n,title:$t,createdAt:$c,labels:$l}'
}
events() { jq -nc --arg who "$2" '[{event:"labeled",label:{name:"factory"},actor:{login:$who}}]' >"$T/gh/events-$1.json"; }

# --- worklist: who may start a job -------------------------------------------------
jq -sc . <(issue 1 "ok" "$now" factory; issue 2 "outsider" "$now" factory; issue 3 "taken" "$now" factory factory:in-progress; issue 4 "newer" "2026-02-01T00:00:00Z" factory) >"$T/gh/issues.json"
events 1 alice; events 2 mallory; events 3 alice; events 4 alice
echo '{"alice":"write","mallory":"read"}' >"$T/gh/perms.json"
: >"$T/gh/calls.log"
wl="$("$S/worklist.sh")"
check "write-access labeller is queued"            '[ "$(jq -r ".queued[0].number" <<<"$wl")" = 1 ]'
check "queue is oldest first"                      '[ "$(jq -c ".queued|map(.number)" <<<"$wl")" = "[1,4]" ]'
check "read-only labeller is ignored with reason"  'jq -e ".ignored[]|select(.number==2 and (.reason|test(\"lacks write\")))" <<<"$wl" >/dev/null'
check "issue already in progress is not queued"    '! jq -e ".queued[]|select(.number==3)" <<<"$wl" >/dev/null'
check "in-progress with no job is orphaned"        '[ "$(jq -c .orphaned <<<"$wl")" = "[3]" ]'
check "orphan frees its slot"                      '[ "$(jq .slots <<<"$wl")" = 2 ]'

# a live job holds a slot and is not orphaned
mkdir -p "$T/repo/factory/jobs/001-x"
echo '{"id":"001-x","issue":3,"stage":"build"}' >"$T/repo/factory/jobs/001-x/job.json"
wl="$("$S/worklist.sh")"
check "live job is not orphaned"                   '[ "$(jq -c .orphaned <<<"$wl")" = "[]" ]'
check "live job holds a slot"                      '[ "$(jq .slots <<<"$wl")" = 1 ]'
touch -t 202001010000 "$T/repo/factory/jobs/001-x/job.json"
wl="$("$S/worklist.sh")"
check "stale job.json makes the issue orphaned"    '[ "$(jq -c .orphaned <<<"$wl")" = "[3]" ]'
rm -rf "$T/repo/factory/jobs/001-x"

# GH_HOST in factory.conf reaches gh
printf 'GH_HOST=ghe.test\n' >>"$FACTORY_CONF"
check "GH_HOST from factory.conf is exported"      '[ "$(bash -c ". \"$S/lib.sh\"; env | grep ^GH_HOST=")" = "GH_HOST=ghe.test" ]'
sed -i.bak "/^GH_HOST=/d" "$FACTORY_CONF"; rm -f "$FACTORY_CONF.bak"

# --- precheck: gate -----------------------------------------------------------------
"$S/precheck.sh" >"$T/pc.out"; rc=$?
check "precheck exits 0 when work is queued"       '[ $rc = 0 ]'
check "precheck prints the worklist path"          '[ "$(cat "$T/pc.out")" = "$T/state/worklist.json" ] && [ -s "$T/state/worklist.json" ]'
jq -sc . <(issue 2 "outsider" "$now" factory) >"$T/gh/issues.json"
"$S/precheck.sh" >/dev/null; rc=$?
check "precheck exits 1 when nothing is startable" '[ $rc = 1 ]'

# --- issue-labels -------------------------------------------------------------------
jq -sc . <(issue 5 "x" "$now" factory factory:needs-human) >"$T/gh/issues.json"
: >"$T/gh/calls.log"
"$S/issue-labels.sh" 5 claim >/dev/null
check "claim adds in-progress"                     'grep -q -- "--add-label factory:in-progress" "$T/gh/calls.log"'
check "claim removes the other state label"        'grep -q -- "--remove-label factory:needs-human" "$T/gh/calls.log"'
check "claim keeps the trigger label"              '! grep -q -- "--remove-label factory " "$T/gh/calls.log"'
"$S/issue-labels.sh" 5 bogus >/dev/null 2>&1; rc=$?
check "unknown state is rejected"                  '[ $rc = 2 ]'

# --- open-pr: pushes, opens PR, never merges ---------------------------------------
git init -q "$T/wt" && git -C "$T/wt" checkout -q -b main \
  && git -C "$T/wt" -c user.email=a@b -c user.name=t commit -q --allow-empty -m base \
  && git -C "$T/wt" checkout -q -b factory/002-y \
  && git -C "$T/wt" -c user.email=a@b -c user.name=t commit -q --allow-empty -m work
git init -q --bare "$T/origin.git" && git -C "$T/wt" remote add origin "$T/origin.git"
mkdir -p "$T/repo/factory/jobs/002-y"
jq -nc --arg w "$T/wt" '{id:"002-y",feature:"do y",branch:"factory/002-y",worktree:$w,issue:5,pr:null,stage:"approve"}' >"$T/repo/factory/jobs/002-y/job.json"
printf '# Do Y\n' >"$T/repo/factory/jobs/002-y/spec.md"; printf 'APPROVE\n\n## Why\nfine\n' >"$T/repo/factory/jobs/002-y/decision.md"
echo '[]' >"$T/gh/prs.json"; : >"$T/gh/calls.log"
url="$("$S/open-pr.sh" 002-y ready 2>/dev/null)"
check "open-pr prints the PR URL"                  '[ "$url" = "https://github.test/o/r/pull/7" ]'
check "open-pr pushes the job branch"              'git -C "$T/origin.git" rev-parse --verify -q factory/002-y >/dev/null'
check "open-pr does not push main"                 '! git -C "$T/origin.git" rev-parse --verify -q main >/dev/null'
check "open-pr targets main with a Closes line"    'grep -q -- "--base main" "$T/gh/calls.log"'
check "ready PR moves the issue to pr-open"        'grep -q -- "--add-label factory:pr-open" "$T/gh/calls.log"'
: >"$T/gh/calls.log"; "$S/open-pr.sh" 002-y draft >/dev/null 2>&1
check "draft PR is created as draft"               'grep -q -- "--draft" "$T/gh/calls.log"'
check "draft PR moves the issue to needs-human"    'grep -q -- "--add-label factory:needs-human" "$T/gh/calls.log"'
check "no script ever calls pr merge"              '! grep -q "MERGE ATTEMPTED\|pr merge" "$T/gh/calls.log"'
check "no script mentions gh pr merge"             '! grep -rn "pr merge\|--auto\|git merge\|push.* main" "$S"/*.sh | grep -v "^.*#" | grep -q .'
# a non-main base branch: PR targets it and the commit-ahead check uses it
git -C "$T/wt" checkout -q -b develop main && git -C "$T/wt" -c user.email=a@b -c user.name=t commit -q --allow-empty -m dev \
  && git -C "$T/wt" checkout -q -b factory/004-dev \
  && git -C "$T/wt" -c user.email=a@b -c user.name=t commit -q --allow-empty -m devwork
mkdir -p "$T/repo/factory/jobs/004-dev"
jq -nc --arg w "$T/wt" '{id:"004-dev",feature:"d",branch:"factory/004-dev",worktree:$w,issue:null,stage:"approve"}' >"$T/repo/factory/jobs/004-dev/job.json"
printf 'BASE_BRANCH=develop\n' >>"$FACTORY_CONF"; : >"$T/gh/calls.log"
"$S/open-pr.sh" 004-dev ready >/dev/null 2>&1
check "BASE_BRANCH sets the PR base"               'grep -q -- "--base develop" "$T/gh/calls.log" && ! grep -q -- "--base main" "$T/gh/calls.log"'
git -C "$T/wt" branch -q -f factory/003-empty develop
git -C "$T/wt" checkout -q develop
jq -nc --arg w "$T/wt" '{id:"003-empty",feature:"z",branch:"factory/003-empty",worktree:$w,issue:null,stage:"build"}' >"$T/x.json"
mkdir -p "$T/repo/factory/jobs/003-empty"; cp "$T/x.json" "$T/repo/factory/jobs/003-empty/job.json"
"$S/open-pr.sh" 003-empty draft >/dev/null 2>&1; rc=$?
check "branch with no commits exits 3"             '[ $rc = 3 ]'

[ $fail = 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
