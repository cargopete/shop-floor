---
description: List only what needs the human across some repos
argument-hint: "[owner/repo ...]"
---

Show what is waiting on the human in $ARGUMENTS (or in `$NEEDS_ME_REPOS`, or
the current repo if neither is set).

If the `needs-me` binary is installed (`command -v needs-me`), run
`needs-me --json <repos>` and summarise it. Otherwise get the same thing with
`gh`: open issues labelled `needs-decision` or `worker-failed`, open PRs that
aren't drafts with a failing check or a merge conflict, and open PRs whose
checks have all passed.

Group the answer as **decide**, **red** and **merge**, oldest first, one line
each with the link. Leave out everything that's still running or waiting on a
worker. If nothing needs the human, say so in one line.
