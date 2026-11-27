---
name: shop-floor-worker
description: How to work as a headless shop-floor worker on one GitHub issue - stay on your branch, commit, write the PR text and a short result summary, and treat ending without a PR as a failure. Use when you were started from a brief to fix or build one issue, or are working on an agent/* branch.
---

# shop-floor worker

You were started headless with a brief for one GitHub issue. Nobody is
watching the chat. Your output is a branch, PR text and a short summary.

1. **Read the brief, then the issue** (`gh issue view <n> --comments` if `gh`
   works; the brief is enough if it doesn't). Do only what they ask. Other
   problems you find are follow-ups (see the shop-floor-followups skill):
   don't fix them, list them under **Follow-ups** in the PR text and your
   summary as `title | path:line | why | fix`. You have no GitHub token, so
   the lead files them.
2. **Stay put.** Work in the checkout you were started in, on the
   `agent/<name>` branch you're on. Don't switch branches, push, open PRs,
   comment, merge, tag or publish. The launcher pushes and opens the PR after
   you exit.
3. **Commit as you go**, small commits with plain messages. No AI co-author
   trailers and no "generated with" lines; the launcher refuses to push them.
4. **Check your work.** After you edit source files, run this skill's
   `post-edit-check.sh` with bash (it auto-detects `cargo check`, a
   `typecheck` script, `tsc --noEmit` or `go build`, or uses `$SF_CHECK` /
   a `.shop-floor-check` in the repo). It must pass. Then run the commands
   in the brief (build, tests, lint). Every claim says how you checked it,
   or is marked UNVERIFIED. kitbag doesn't carry hooks, so this script is
   the required step on every tool; `claude-code-hook.json` next to it is
   an optional Claude Code hook you can copy into settings yourself.
5. **Write the PR text** to the file the brief or launcher names: line 1 the
   title, a blank line, then what changed, why, how you checked it, and
   `Closes #N` (or `Part of #N` plus what's left), then the **Follow-ups**
   list if there is one.
6. **Finish with a summary** of at most 10 lines: `DONE`, `PARTIAL` or
   `BLOCKED` on line 1, then what you did, the checks and their results,
   anything left, and the follow-ups.

A clean exit with no commits or no PR text is recorded as a failed run.
If you're blocked (a login wall, a permission error, a decision only the
human can make), stop and say exactly what's needed instead of working
around it. That's a useful result; silence isn't.
