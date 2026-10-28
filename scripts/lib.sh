#!/usr/bin/env bash
# Sourced by the other scripts. Loads $HOME/factory.conf, written by ONBOARDING.md.
CONF="${FACTORY_CONF:-$HOME/factory.conf}"
[ -f "$CONF" ] || { echo "no $CONF: follow ONBOARDING.md first" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
: "${REPO:?factory.conf must set REPO (owner/name)}" "${CHECKOUT:?factory.conf must set CHECKOUT}"
TRIGGER_LABEL="${TRIGGER_LABEL:-factory}"
MAX_PARALLEL="${MAX_PARALLEL:-1}"
STALE_MIN="${STALE_MIN:-180}"
BASE_BRANCH="${BASE_BRANCH:-main}"
if [ -n "${GH_HOST:-}" ]; then export GH_HOST; fi
LABEL_ACTIVE="$TRIGGER_LABEL:in-progress"
LABEL_PR="$TRIGGER_LABEL:pr-open"
LABEL_HUMAN="$TRIGGER_LABEL:needs-human"
STATE_DIR="${FACTORY_STATE_DIR:-$HOME/.factory}"
