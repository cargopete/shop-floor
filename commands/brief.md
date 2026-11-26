---
description: Write a worker brief for a GitHub issue
argument-hint: "<issue number or URL>"
---

Write a worker brief for issue $ARGUMENTS, using the shop-floor-lead skill's
`brief-template.md`.

1. Read the issue and its comments with `gh issue view <n> --comments`.
2. Read enough of the code to name the files involved and how to check the
   change. Don't change anything.
3. Fill in every section of the template. Keep scope to what the issue asks;
   list what's out of scope.
4. If the issue is too vague to brief, don't guess: write the open question as
   an issue comment draft, suggest the `needs-decision` label, and stop.
5. Save the brief as `briefs/<issue-number>-<short-name>.md` outside the repo
   (or where the user says) and print the path and the launch command.
