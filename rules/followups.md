---
description: Fix only what the current change broke; file every other finding as a follow-up and stop.
alwaysApply: true
---

# Follow-ups, not scope creep

- Fix only what this change broke or is about: failures caused by your edit,
  bugs in lines you changed, review comments on this PR, and what the task
  asks for.
- Anything else you notice is a follow-up. Don't fix it. File it so it
  outlives this session: a GitHub issue labelled `followup` with a title,
  `path:line`, why it matters, a suggested fix and a link back to the PR or
  issue you were on. The shop-floor-followups skill's `file-followup.sh`
  does this, and falls back to `.followups.md` at the repo root when there's
  no GitHub remote or `gh`. A headless shop-floor worker (no GitHub token)
  doesn't run it and doesn't write `.followups.md`: it lists them under
  **Follow-ups** in the PR text and summary, and the lead files them.
- When the task is done, list what you filed and stop. Don't offer to fix the
  follow-ups too.
