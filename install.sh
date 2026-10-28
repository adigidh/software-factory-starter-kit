#!/usr/bin/env bash
# Usage: ./install.sh [target-repo]   (default: current directory)
# Add --user to install skill+agents into ~/.claude instead of a repo.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--user" ]; then
  mkdir -p ~/.claude/skills ~/.claude/agents
  cp -r "$KIT"/.agents/skills/* ~/.claude/skills/
  cp "$KIT"/agents/*.md ~/.claude/agents/
  echo "Installed to ~/.claude (user scope)."; exit 0
fi
T="$(cd "${1:-.}" && pwd)"
git -C "$T" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "$T is not a git repo"; exit 1; }
B="${BASE_BRANCH:-main}"
git -C "$T" rev-parse --verify "$B" >/dev/null 2>&1 || echo "warning: no '$B' branch; the factory branches from it (set BASE_BRANCH in factory.conf)"
mkdir -p "$T/.claude/skills" "$T/.claude/agents" "$T/factory"
cp -r "$KIT"/.agents/skills/* "$T/.claude/skills/"
cp "$KIT/THIRD_PARTY_LICENSES.md" "$T/"
cp "$KIT"/agents/*.md "$T/.claude/agents/"
[ -e "$T/factory/backlog.md" ]   || cp "$KIT/factory/backlog.md" "$T/factory/"
[ -e "$T/factory/dashboard.html" ] || cp "$KIT/factory/dashboard.html" "$T/factory/"
[ -e "$T/AGENTS.md" ] || [ -e "$T/CLAUDE.md" ] || { cp "$KIT/AGENTS.template.md" "$T/AGENTS.md"; echo "Created AGENTS.md: fill it in."; }
grep -qxF 'factory/jobs/' "$T/.gitignore" 2>/dev/null || echo 'factory/jobs/' >> "$T/.gitignore"
echo "Installed into $T. Commit it, then run: /factory <feature>"
