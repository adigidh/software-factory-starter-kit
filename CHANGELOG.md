# Changelog

**Migration instructions, not a change log.** Per version, the idempotent **Upgrade**
steps a deployed agent applies when a Kit Update moves its checkout across it. What
changed and why lives in the pull request and commit history, not here.

Authoring rules:

- Every change bumps `VERSION` once and adds the matching entry on top, in the same PR.
  Entries already on `main` are never edited; correct them with a new entry.
- Most versions need nothing: write `Nothing — docs and scripts are re-read per run.`
- **A change to anything in `agents/` needs an Upgrade step.** A Kit Update moves the
  checkout but does not re-run the kit's install command, so the copies in
  `~/.claude/agents/` stay old. The step is: `bash "$HOME/scripts/install-agents.sh"`,
  then tell the operator to start a new Claude Code session (sessions load agents at
  start). CI fails a pull request that changes `agents/` without bumping `VERSION`.
- Skills in `.agents/skills/` and scripts in `scripts/` need no step: the harness and the
  schedule read them from the checkout.
- A new `factory.conf` key is an Upgrade step too: name the key, its default, and
  whether the operator must set it.

## 0.1.0 — 2026-10-27

**Upgrade:** Nothing — first release.
