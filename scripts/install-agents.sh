#!/usr/bin/env bash
# Installs the factory's sub-agent definitions where Claude Code looks for them
# (~/.claude/agents). Skills need no step: the platform installs bundledSkills.
# Idempotent. Run by the kit's install command and again by ONBOARDING.md.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)/agents"
DEST="${CLAUDE_AGENTS_DIR:-$HOME/.claude/agents}"
mkdir -p "$DEST"
n=0
for f in "$SRC"/*.md; do
  cp "$f" "$DEST/$(basename "$f")"
  n=$((n + 1))
done
echo "installed $n agents into $DEST"
