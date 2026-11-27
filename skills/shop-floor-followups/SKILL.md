---
name: shop-floor-followups
description: Keep out-of-scope findings from vanishing with the session - fix only what the current change broke, file everything else as a GitHub issue labelled followup (or an entry in .followups.md), then stop. Use when you notice a bug, smell, flaky test or missing check that isn't part of the task, when a review finds something outside the PR's scope, or when asked to file a follow-up.
---

# follow-ups

You'll find things that aren't your job right now. Don't fix them and don't
forget them: file them, then finish the job you were given.

## What's in scope

Fix it now only if **this change broke it or this change is about it**:

- a test or check that fails because of your edit
- a bug in lines you added or changed
- a review comment on this PR
- something the issue or brief asks for

Everything else is a follow-up, however small: a bug in code you only read,
a flaky test that was flaky before you, a missing check, dead code, a doc
that's wrong, a "while I'm here" refactor.

## Filing one

```sh
bash <this skill's dir>/file-followup.sh \
  --title "Parser drops a trailing comma" \
  --where src/parse.rs:120 \
  --why "configs written by tool X fail to load" \
  --fix "accept an optional comma before the closing bracket" \
  --from https://github.com/owner/repo/pull/42
```

- With a GitHub remote and a working `gh` it opens an issue labelled
  `followup` (and creates the label if it's missing). Without one, with
  `--file`, or if `gh` can't create it, it appends an entry to
  `.followups.md` at the repo root. It won't file the same open title twice.
- The title says what's wrong, not what to do. `--where` is `path:line`.
  `--why` is one sentence on what goes wrong for whom. `--fix` is what you'd
  do. `--from` links back to the PR, issue or branch you were on.
- No script? `gh issue create --label followup` with the same four things in
  the body does the same job, or add a `- [ ] title` entry with `where`,
  `why`, `fix` and `from` lines to `.followups.md`.
- If you can't reach GitHub (a headless worker has no token), list them in
  your PR text and summary under **Follow-ups** in the same shape. The lead
  files them.

## Then stop

When the task is done, list the follow-ups you filed (links or titles) in
your summary and stop. Don't ask "should I also fix…?" and don't start on
them. They're on the list now; somebody picks them up when they're the job.

`needs-me` counts open follow-ups per repo, and `needs-me --followups` lists
them.
