# Brief: <short title> (#<issue>)

## Issue
<link>. One paragraph in your own words: what's wrong or wanted, and why it
matters.

## Do
- <the change, as concrete steps or acceptance points>

## Don't
- No drive-by refactors, renames, dependency or version bumps.
- <anything else out of scope>

## Where to look
- <files, functions, docs, related issues or PRs>

## Check
- After source edits, run the shop-floor-worker skill's `post-edit-check.sh`
  with bash. It must pass. It auto-detects `cargo check`, a `typecheck`
  script, `tsc --noEmit` or `go build`, or uses `$SF_CHECK` / a
  `.shop-floor-check` in the repo. kitbag doesn't carry hooks, so this is
  the required typecheck on every tool.
- <exact commands: build, tests, lint, a manual run>
- Every claim in your summary says how you checked it, or is marked UNVERIFIED.

## Rules
- Stay in this worktree and on this branch. Commit only; the launcher pushes
  and opens the PR.
- Never print, log or commit secrets. Tests use obviously fake values.
- If you hit a login wall, a permission error or something that needs a human
  decision, stop and say exactly what's needed. Don't work around it.

## Finish
- PR text: title, then what changed, why, how you checked it, `Closes #<issue>`
  (or `Part of #<issue>` and what's left).
- Final summary, at most 10 lines: DONE, PARTIAL or BLOCKED on line 1, then
  what you did, checks run and results, anything left.
