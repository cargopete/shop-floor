# shop-floor

the agent setup i actually run, packed as a [kitbag](https://github.com/cargopete/kitbag) profile.

one lead agent per project. every bit of work is a github issue that ends in one PR. headless claude code workers do the changes, each on its own branch. the lead only comes to me when it needs a decision, and it asks on the issue, not in a chat thread i have to scroll.

the longer story, with the honest numbers, is in the article: https://x.com/cargo_pete/status/2125888240087396700

## what you get

- one lead per project, and workers on their own branches
- every job is a github issue that ends in one PR
- needs-me, the inbox of what's waiting on you
- a post-edit typecheck workers have to run (kitbag doesn't carry hooks; a claude code hook snippet is in the worker skill if you want it)
- a reviewer that returns `path:line, severity, issue, fix` verdicts before a PR is marked ready
- follow-ups: the agent fixes only what its change broke, files everything else it finds as a `followup` issue (or `.followups.md`), and stops

## install

```sh
kitbag apply github:cargopete/shop-floor --to claude-code,codex
```

kitbag shows you the plan and asks before it writes anything. `kitbag undo` takes it back out. `--to all` also does cursor and gemini cli. this profile has no mcp servers or permission rules. kitbag doesn't carry hooks, so the post-edit check ships as a script in the worker skill (run it with bash) and an optional claude code hook snippet you copy into settings yourself; nothing needs `--trust-source`.

needs kitbag 0.1.2 or newer (`cargo install kitbag`). the target id is `claude-code`, not `claude`.

the `needs-me` command is a separate small binary:

```sh
cargo install --git https://github.com/cargopete/shop-floor needs-me
```

## the profile

**the rules** (`instructions.md`, lands in `CLAUDE.md` / `AGENTS.md` / `GEMINI.md`). one lead per project. issue first, then exactly one PR that says `Closes #N`. a short summary on every PR: what changed, why, how it was checked. the human gets asked for decisions and nothing else. a worker that exits cleanly without a PR has failed.

**labels** (`rules/shop-floor-labels.md`). the state lives in labels, not in anyone's memory:

| label | means |
|---|---|
| `needs-decision` | a human has to choose. the question, the options and the lead's pick are in the latest comment |
| `worker-running` | a worker is on it right now |
| `worker-failed` | the last run ended without a PR |
| `agent` | small and clear enough to hand to a worker |
| `followup` | found while doing something else; out of scope then, worth doing later |

`labels.sh owner/repo` in the lead skill creates them. `file-followup.sh` creates `followup` on its own if it's missing.

**the lead skill** (`skills/shop-floor-lead`). the loop the lead follows: issue, decide or ask, brief, launch, check the result, review, merge or hand over. comes with:

- `brief-template.md`: the brief every worker gets. scope, what not to touch, where to look, how to check (including the post-edit typecheck), how to finish.
- `review-brief.md`: the brief for a `--review` pass, including the verdict shape.
- `launch-worker.sh`: the headless worker launcher. more below.
- `labels.sh`: creates the labels.

**the worker skill** (`skills/shop-floor-worker`). what a worker does when nobody's watching: stay on its branch, commit, write the PR text, finish with a summary of ten lines or fewer, and say when it's blocked instead of working around it. after source edits it runs `post-edit-check.sh`, which auto-detects `cargo check`, a `typecheck` script, `tsc --noEmit` or `go build`, or uses `$SF_CHECK` / a `.shop-floor-check` in the repo. `claude-code-hook.json` in the same folder is a PostToolUse hook you can copy into `~/.claude/settings.json` or the project's `.claude/settings.json`; kitbag will not install it for you.

**the reviewer** (`skills/shop-floor-reviewer`, plus `review-brief.md` in the lead skill). a fresh-context pass the lead runs before a PR is marked ready. the result is a verdict (`APPROVE`, `APPROVE WITH NITS` or `REQUEST CHANGES`) and findings as `path:line, severity, issue, fix`. `launch-worker.sh --review` uses this; REQUEST CHANGES goes back to the worker with `SF_CONTINUE=1`.

**commands**: `/brief <issue>` writes a worker brief, `/needs-me` lists what's waiting on you, `/summary` writes the PR summary for the current branch, `/followup <what's wrong>` files one follow-up by hand.

## follow-ups

agents keep finding things that aren't the job: a bug in code they only read, a flaky test, a missing check. in a chat that finding either turns into scope creep or it scrolls away and dies with the session. this is the fix for that (the shape is the one asked for in [anthropics/claude-code#112120](https://github.com/anthropics/claude-code/issues/112120)), and because it's plain rules, a skill and a command, kitbag carries it to every tool, not just claude code.

- **the rule** (`rules/followups.md`, always on): fix only what this change broke or is about. everything else gets filed, not fixed. when the task is done, list what you filed and stop. no "should i also...?".
- **the skill** (`skills/shop-floor-followups`): `file-followup.sh` opens a github issue labelled `followup` with a title, `path:line`, why it matters, a suggested fix and a link back to the PR or issue it came from. it creates the label if it's missing and won't file the same open title twice. with no github remote, no `gh`, `--file`, or when `gh` can't create the issue, it appends a `- [ ]` entry to `.followups.md` at the repo root instead, so nothing gets dropped.
- **`/followup`**: file one by hand, mid-task, without derailing it.
- **workers and the reviewer**: workers have no github token, so they list follow-ups in the PR text and the lead files them. the reviewer has a `followup` severity for real problems the PR didn't cause; those don't hold the PR.
- **needs-me** counts open follow-ups per repo under its list, and `needs-me --followups` lists them. they're backlog, so they don't change the exit code.

```sh
bash ~/.claude/skills/shop-floor-followups/file-followup.sh \
  --title "Parser drops a trailing comma" --where src/parse.rs:120 \
  --why "configs written by tool X fail to load" \
  --fix "accept an optional comma before the closing bracket" \
  --from https://github.com/you/repo/pull/42
```

it's a convention plus a script. nothing stops an agent that ignores the rule, but the rule is short and in every tool's instructions, and the reviewer pass catches scope creep.

## the launcher

```sh
cd your-repo
SF_ISSUE=42 bash ~/.claude/skills/shop-floor-lead/launch-worker.sh fix-42 brief.md opus
bash ~/.claude/skills/shop-floor-lead/launch-worker.sh --review fix-42 review-brief.md opus
bash ~/.claude/skills/shop-floor-lead/launch-worker.sh --status
```

for each run it makes a git worktree on branch `agent/<name>` from the default branch and starts `claude -p` in tmux session `sf-<name>` on its own tmux server (`tmux -L sf-<name> attach` to watch), with a turn cap, a timeout and an optional spend cap (`SF_MAX_TURNS`, `SF_TIMEOUT`, `SF_MAX_BUDGET`). the worker runs without github tokens in its environment and is told to commit only. when it exits, the launcher:

- reads the result from claude's json log, not the exit code
- calls it `FAILED` if there are no commits or no PR text, `CAP HIT` if a cap stopped it, `ABORTED` if it timed out or crashed
- refuses to push if a commit or the PR text carries an AI co-author trailer (`SF_ALLOW_ATTRIBUTION=1` if you don't care)
- otherwise pushes the branch and opens or updates one PR, with your normal `gh` login
- moves `worker-running` to `worker-failed` on the issue when the run didn't end in a PR

`SF_CONTINUE=1` with the same name sends a worker back to its own branch, say to fix what a review found. its push updates the same PR.

`--review` runs a second worker with a fresh context on a detached checkout of the branch, without edit tools, and records its verdict (`APPROVE`, `APPROVE WITH NITS` or `REQUEST CHANGES`, then `path:line, severity, issue, fix`). it never pushes. a PR isn't ready until that pass is APPROVE or APPROVE WITH NITS.

if your workers run as a user with no github access (mine do), `SF_GH` sets the gh command and `SF_PUBLISH` swaps in your own push-and-open-PR script.

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
- `--followups` lists the follow-up backlog instead (open `followup` issues, plus open entries in `.followups.md` in the repo you're in). without it, a `backlog: N open follow-ups in owner/repo` line per repo closes the list
- repos come from the arguments, `$NEEDS_ME_REPOS`, or the repo you're in
- exits 0 when nothing needs you, 1 when something does, 2 on errors. follow-ups never count as needing you, except under `--followups`, where 1 means there are some

it's a thin wrapper over `gh`, so it uses whatever login `gh` has.

## honest bit

this is what i run, written down. three projects, each with a lead bot (grok bot, in my case, but the profile doesn't care what leads), and claude code workers on a thinkpad. it's not a product and there's no dashboard. the inbox is the issue list. if you want something with a ui there are about ten of those, and some of them are good.

it works for me because the work is mostly small, well-scoped issues on repos with decent tests. on a messy codebase with no CI the "a PR counts as done when CI is green and a review pass is happy" part has nothing to stand on.

issues and PRs welcome, ideally through the same loop.

## license

MIT
