# shop-floor

the agent setup i actually run, packed as a [kitbag](https://github.com/cargopete/kitbag) profile.

one lead agent per project. every bit of work is a github issue that ends in one PR. headless claude code workers do the changes, each on its own branch. the lead only comes to me when it needs a decision, and it asks on the issue, not in a chat thread i have to scroll.

the longer story, with the honest numbers, is in the article: https://x.com/cargo_pete/status/2125888240087396700

## install

```sh
kitbag apply github:cargopete/shop-floor --to claude-code,codex
```

kitbag shows you the plan and asks before it writes anything. `kitbag undo` takes it back out. `--to all` also does cursor and gemini cli. this profile has no mcp servers, permission rules or hooks, so there's nothing to `--trust`.

needs kitbag 0.1.2 or newer (`cargo install kitbag`). the target id is `claude-code`, not `claude`.

the `needs-me` command is a separate small binary:

```sh
cargo install --git https://github.com/cargopete/shop-floor needs-me
```

## what you get

**the rules** (`instructions.md`, lands in `CLAUDE.md` / `AGENTS.md` / `GEMINI.md`). one lead per project. issue first, then exactly one PR that says `Closes #N`. a short summary on every PR: what changed, why, how it was checked. the human gets asked for decisions and nothing else. a worker that exits cleanly without a PR has failed.

**labels** (`rules/shop-floor-labels.md`). the state lives in labels, not in anyone's memory:

| label | means |
|---|---|
| `needs-decision` | a human has to choose. the question, the options and the lead's pick are in the latest comment |
| `worker-running` | a worker is on it right now |
| `worker-failed` | the last run ended without a PR |
| `agent` | small and clear enough to hand to a worker |

`labels.sh owner/repo` in the lead skill creates them.

**the lead skill** (`skills/shop-floor-lead`). the loop the lead follows: issue, decide or ask, brief, launch, check the result, review, merge or hand over. comes with:

- `brief-template.md`: the brief every worker gets. scope, what not to touch, where to look, how to check, how to finish.
- `launch-worker.sh`: the headless worker launcher. more below.
- `labels.sh`: creates the labels.

**the worker skill** (`skills/shop-floor-worker`). what a worker does when nobody's watching: stay on its branch, commit, write the PR text, finish with a summary of ten lines or fewer, and say when it's blocked instead of working around it.

**commands**: `/brief <issue>` writes a worker brief, `/needs-me` lists what's waiting on you, `/summary` writes the PR summary for the current branch.

## the launcher

```sh
cd your-repo
SF_ISSUE=42 bash ~/.claude/skills/shop-floor-lead/launch-worker.sh fix-42 brief.md opus
bash ~/.claude/skills/shop-floor-lead/launch-worker.sh --status
```

for each run it makes a git worktree on branch `agent/<name>` from the default branch and starts `claude -p` in tmux session `sf-<name>`, with a turn cap, a timeout and an optional spend cap (`SF_MAX_TURNS`, `SF_TIMEOUT`, `SF_MAX_BUDGET`). the worker runs without github tokens in its environment and is told to commit only. when it exits, the launcher:

- reads the result from claude's json log, not the exit code
- calls it `FAILED` if there are no commits or no PR text, `CAP HIT` if a cap stopped it, `ABORTED` if it timed out or crashed
- refuses to push if a commit or the PR text carries an AI co-author trailer (`SF_ALLOW_ATTRIBUTION=1` if you don't care)
- otherwise pushes the branch and opens or updates one PR, with your normal `gh` login
- moves `worker-running` to `worker-failed` on the issue when the run didn't end in a PR

the first line of `~/.shop-floor/logs/<name>/result` is the verdict. `--help` lists the rest of the knobs. needs git, tmux, jq, gh and claude.

it's a convention, not a sandbox. the worker can still run anything its allowed tools allow, so give it a repo you'd let a junior loose on.

## needs-me

```console
$ needs-me cargopete/kitbag
red    cargopete/kitbag#40 Security hardening: source URL credentials, undo backup check, diff masking, secret naming  (PR, merge conflict)
       https://github.com/cargopete/kitbag/pull/40
red    cargopete/kitbag#54 Add an Antigravity target for MCP servers and instructions  (PR, merge conflict)
       https://github.com/cargopete/kitbag/pull/54
```

it lists only what needs you: issues and PRs labelled `needs-decision`, PRs with a red check or a merge conflict, issues marked `worker-failed`, and green PRs nobody has merged. decisions first, then red, then merges, oldest first. drafts, running checks and anything a worker is still on are left out.

- `--json` for scripts, or for a bot that posts you a digest
- `--next` for just the top one
- repos come from the arguments, `$NEEDS_ME_REPOS`, or the repo you're in
- exits 0 when nothing needs you, 1 when something does, 2 on errors

it's a thin wrapper over `gh`, so it uses whatever login `gh` has.

## honest bit

this is what i run, written down. three projects, each with a lead bot (grok bot, in my case, but the profile doesn't care what leads), and claude code workers on a thinkpad. it's not a product and there's no dashboard. the inbox is the issue list. if you want something with a ui there are about ten of those, and some of them are good.

it works for me because the work is mostly small, well-scoped issues on repos with decent tests. on a messy codebase with no CI the "a PR counts as done when CI is green and a review pass is happy" part has nothing to stand on.

issues and PRs welcome, ideally through the same loop.

## license

MIT
