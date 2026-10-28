# Software Factory (DAM starter kit)

Label an issue, or ask in chat, and get a reviewed pull request. For each request the
agent writes a spec with testable acceptance criteria, builds it test-first on a
`factory/<job-id>` branch, runs security, UX, UI and code reviews in parallel, loops
until they pass, and opens a PR whose body carries the spec, build log and the
approver's decision.

**It never merges and never pushes to the base branch.** A human reviews every PR. When the approver or the review loop can't settle something, the PR opens as a draft and the
issue is labelled `factory:needs-human`.

Bundled skills from mattpocock/skills (MIT, see THIRD_PARTY_LICENSES.md): `tdd` and the
`code-review` two-axis check inside `reviewer-code`.

## Start a job

| How | What happens |
|---|---|
| Chat: `/factory <feature>` | Runs one job now in the target repo. |
| Chat: `/factory issues` | Runs the labelled-issue sweep now. |
| Label an issue `factory` | The `factory-issues` schedule (every 10 min, gated by `scripts/precheck.sh` so an empty queue wakes no model) picks it up. Only labels applied by someone with write access count. |

Issue labels: `factory:in-progress` (claimed) → `factory:pr-open` or `factory:needs-human`.
Remove the state label to run an issue again.

## Create the agent

Pick **Software Factory** from the catalog, connect GitHub (a bot or app with write
access to the target repo), and answer the onboarding questions. Onboarding clones the
repo, fills in its `AGENTS.md` (setup, dev server, validation, conventions) through a PR,
and creates the trigger label. The PR target is the repo's default branch, or any branch you name (`BASE_BRANCH`, e.g. `develop`). Add a branch protection rule on it requiring review.

## What a job costs

Measured on one real run (Sonnet, a 15-test Vite/TypeScript blog, the feature "show an
estimated reading time on each post"): spec, one build, four parallel reviews that all
passed in round 1, approver, ready PR (5 files, +46/−3).

| | |
|---|---|
| Agents run | 7 (spec-writer, builder, 4 reviewers, approver) plus the orchestrating session |
| Model calls | 59 |
| Tokens | about 0.64M fresh input and cache writes, 1.0M cache reads, 23.5K output |
| Active agent time | about 20 min on the critical path (builder ~13, approver ~4, spec ~1, reviewers ~2 in parallel) |

This is one small job. A bigger repo, a harder feature, or a second review round will cost
more, roughly in proportion to the rounds. Elapsed time depends on how long your approvals
and machine idle time add; the run above sat for hours between steps while waiting.

## Known limits

- **One repository per agent.** `factory.conf` names one `REPO`. Run another agent for another repo.
- **Jobs run one at a time** by default (`MAX_PARALLEL=1`). Raise it only once you have seen a job run clean.
- **UX and UI reviews need a browser.** They use `agent-browser` when installed, otherwise any headless
  Chrome on the machine (the run above used the local Chrome), otherwise they read the code and say so
  in their review. On a DAM agent neither may exist: see the egress note in `ONBOARDING.md`.
- **The target needs working `npm`/package install, tests and a build** that run unattended. Tests that
  need a login or a live service will make the builder and reviewers guess.
- **No auto-recovery.** A job that stalls is found by the `STALE_MIN` orphan check and handed to a person.
- **Every PR still needs a human.** The approver only decides ready or draft.

## Layout

```
kit.yaml                  the DAM kit manifest (validated in CI against kit.schema.json)
CLAUDE.md, ONBOARDING.md  the agent's rules and first-run procedure
.agents/skills/           factory (the loop: spec → build → 4 reviews → approve → PR) and tdd
agents/                   spec-writer, builder, reviewer-{security,ux,ui,code}, approver
scripts/                  worklist, precheck (schedule gate), issue-labels, open-pr, install-agents, tests/
factory/dashboard.html    job board; open it against factory/jobs/
```

## Without DAM

`./install.sh /path/to/repo` still copies the skill and agents into a repo for local
use. Chat-driven only: the issue sweep and PR scripts expect the DAM home layout.

## Listing it in the catalog

Add `- url: https://github.com/<you>/software-factory-starter-kit` to `catalog.yaml` in
dam-agents/dam-starter-kits and open a PR.

## License

Apache License 2.0, see [`LICENSE`](LICENSE). The bundled `tdd` skill and the review
checklist adapted in `reviewer-code` are MIT, see [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
