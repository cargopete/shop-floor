---
description: File one out-of-scope finding as a follow-up so it isn't lost
argument-hint: "<what's wrong, and where if you know>"
---

File this as a follow-up, not a fix: $ARGUMENTS

1. Work out the four parts, looking at the code only as much as you need:
   a short title saying what's wrong, `path:line`, why it matters (one
   sentence), and the fix you'd suggest. If you're on a PR, issue or branch,
   that's where it came from.
2. File it with the shop-floor-followups skill's `file-followup.sh`
   (`--title`, `--where`, `--why`, `--fix`, `--from`). Without the script,
   use `gh issue create --label followup` with the same parts in the body,
   or add a `- [ ] title` entry to `.followups.md` at the repo root when
   there's no GitHub remote or `gh`.
3. Print the issue link or the file entry, then go back to what you were
   doing. Don't start fixing it.
