# Onboarding

Every step is idempotent, so a failed run is safe to repeat from the top. Stop at the
first step that cannot be completed and tell the operator what is missing.

## Where things stand

The platform decides whether onboarding is pending (it clears its own marker to re-run
it); this file keeps no marker of its own. Look at what already exists:

```bash
[ -f "$HOME/factory.conf" ] && grep -E '^(REPO|TRIGGER_LABEL|BASE_BRANCH)=' "$HOME/factory.conf"
```

- **No `factory.conf`**: a fresh agent. Do every step below.
- **`factory.conf` exists**: onboarding is being re-run. Show the operator the three
  values printed above (never the whole file), ask whether to keep them, and repeat the
  steps below as a verification. Finish exactly as a fresh run does: onboarding is only
  over when you call `mark_onboarding_complete`.

## The checklist

An agent created from the kit has the onboarding tools (`set_onboarding_checklist`,
`complete_onboarding_step`, `mark_onboarding_complete`) and the `factory-issues`
schedule, **held until onboarding completes**. An agent set up by hand has neither: say
so in chat and create the schedule from `kit.yaml` yourself.

The checklist is only what you need **from the operator**: a value, a decision, or an
action only they can take. Never put your own work on it. Open it with one step:

1. Target repository, trigger label and base branch

Add a step with `set_onboarding_checklist` only when you hit something the operator must
do, and tick it with `complete_onboarding_step` when they have:

- **Grant write access to `<owner/name>`**, when the access check below fails.
- **Merge or dismiss the `AGENTS.md` pull request**, when the setup step below opens one.

Everything else in this file (access checks, cloning, writing the config, installing the
agents, verifying) is yours. Narrate it in chat as you go; do not tick it.

## 1. Ask

Ask the operator, in one message:

1. The repository to work on, as `owner/name`.
2. The label that starts a job (default `factory`).
3. The branch pull requests should target (default: the repository's default branch).

Tick the first checklist step when they answer.

## 2. Check access

```bash
gh auth status
gh repo view <owner/name> --json viewerPermission,defaultBranchRef
```

Run `gh auth setup-git` so `git push` uses the same credentials as `gh`.

`viewerPermission` must be `WRITE`, `MAINTAIN` or `ADMIN`. If it is not, add the
**Grant write access** step and wait for the operator. The factory branches from and
opens pull requests against one base branch: the repository's default branch unless the
operator names another. Remember it as `BASE_BRANCH` (for example `main` or `develop`).

## 3. Clone and keep job state out of the repo

```bash
git clone https://github.com/<owner/name>.git "$HOME/work/<name>"
echo 'factory/jobs/' >> "$HOME/work/<name>/.git/info/exclude"
```

Use the host the GitHub connection names if it is GitHub Enterprise. The exclude file
keeps job state out of the target's `.gitignore` and out of every commit. If the clone
already exists, `git -C "$HOME/work/<name>" fetch origin` instead, and add the exclude
line only if it is missing.

## 4. Write factory.conf

```bash
cat > "$HOME/factory.conf" <<EOF
REPO=<owner/name>
CHECKOUT=$HOME/work/<name>
TRIGGER_LABEL=<label>
BASE_BRANCH=<base branch>
MAX_PARALLEL=1
STALE_MIN=180
EOF
```

For GitHub Enterprise, add a `GH_HOST=<host>` line (for example `github.example.com`):
the scripts export it so `gh` talks to the right host.

Create the labels: `bash "$HOME/scripts/issue-labels.sh"` creates the state labels on
first use, so create only the trigger label now:
`gh label create <label> -R <owner/name> --description "Start the software factory" --force`.

## 5. Install the agents and teach the factory the repository

```bash
bash "$HOME/scripts/install-agents.sh"
```

The kit's install command already ran this; it is idempotent. The seven sub-agents
(`spec-writer`, `builder`, four reviewers, `approver`) must be in `~/.claude/agents/` or
the factory cannot spawn them.

The agents read `AGENTS.md` (or `CLAUDE.md`) in the target repository for everything
repo-specific. If it has neither, or it lacks any of the four sections below, work them
out from the repository (README, package manifests, CI config, existing scripts) and
write them into `AGENTS.md` on a branch `factory/onboarding`, then open a pull request
with `gh pr create` for the operator to merge. Branch from, and target, `BASE_BRANCH`;
never push to it. Add the **Merge or dismiss the `AGENTS.md` pull request** step, so the
first jobs run with the repository's conventions in place.

- **Setup** (fresh checkout or new worktree): the exact install command.
- **Dev server**: the command and how to pass a port, for example `npm run dev -- --port $PORT`.
- **Validation**: tests, build, lint, type-check. Run each once in the clone to confirm it
  works. Record any that fail on the base branch as known failures instead of hiding them.
- **Conventions**: formatting, naming, layout, things to avoid.

If the repository has pages to look at, install the browser CLI the UX and UI reviewers use:
`npm install -g agent-browser && agent-browser install` (the second command downloads Chrome).
If either fails, for example because egress to the download host is blocked, say so; the
reviewers then fall back to reading the code and the job still runs.

**Egress.** The kit asks for the `trusted` egress preset (npm, PyPI, GitHub and similar). It may
not include the host that serves the Chrome download, nor a GitHub Enterprise host the target
lives on. The operator owns the egress rules, so when a step above fails on a blocked host, name
the host and tell the operator to allow it in the agent's egress settings, then retry. Do not try
to work around a block.

## 6. Verify, release the schedule, and finish

```bash
bash "$HOME/scripts/worklist.sh" | jq .          # must print JSON with slots >= 1, no error
ls "$HOME/.claude/agents" | wc -l                # at least 7
```

Fix anything that fails and re-run. When the worklist and agents check pass and every
checklist step is ticked, call `mark_onboarding_complete`, only now: it releases the
`factory-issues` schedule.

Tell the operator: the repository, the trigger label, that labelling an issue (by anyone
with write access) starts a job within about ten minutes, that `/factory <feature>` starts
one now, that every result is a pull request and nothing merges without them, and the
URL of the `factory/onboarding` pull request if step 5 opened one.
Recommend a branch protection rule on the base branch requiring a review, so the rule the
factory follows is also one GitHub enforces.
