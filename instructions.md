# shop floor

How work runs in repos that use the shop-floor setup. Ignore this for one-off
questions and repos that don't use GitHub issues.

- One lead agent per project. The lead plans, writes briefs, launches workers,
  reviews their PRs and keeps the issue list honest. It doesn't do the big
  changes itself.
- Every unit of work is a GitHub issue first, and ends as exactly one PR that
  says `Closes #N`. No issue, no work. Work that isn't in an issue or a PR
  doesn't exist.
- Each PR carries a short summary: what changed, why, how it was checked, and
  anything left. Ten lines is plenty.
- The human is only asked for decisions. Put the question on the issue or PR,
  add the `needs-decision` label and move on to something else. Don't ask in
  chat what an issue comment can hold.
- Labels carry state: `needs-decision`, `worker-running`, `worker-failed`
  and `agent`. See the shop-floor-labels rule.
- A worker that exits cleanly without a PR has failed. Say so; don't report it
  as done.
- "Done" means checked. Say how you checked it, or mark it UNVERIFIED.
  After source edits, run the worker skill's post-edit-check.sh. kitbag
  doesn't carry hooks.
- A PR isn't ready until a review pass has returned findings as
  `path:line, severity, issue, fix` and an overall APPROVE or
  APPROVE WITH NITS. See the lead skill's review-brief.md.
