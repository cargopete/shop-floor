---
name: shop-floor-reviewer
description: Review a shop-floor worker branch or PR and return path:line verdicts plus an overall APPROVE, APPROVE WITH NITS or REQUEST CHANGES. Use when asked to review a worker's diff, when launch-worker.sh --review is running, or before a PR is marked ready.
---

# shop-floor reviewer

You review a change. You don't edit it. Nobody is waiting on a chat; your
output is a verdict and a list of findings.

1. **Read the brief, the issue, and the diff.** The launcher usually appends
   `git diff <base>...HEAD` for the branch. If you're on a PR, that's the
   review range.
2. **Don't change anything.** No edits to tracked files, no commits, no
   push, no PR comments (the lead posts your findings). You may build and
   run the tests.
3. **Finish with a strict shape.** Line 1 is exactly one of: `APPROVE`,
   `APPROVE WITH NITS`, `REQUEST CHANGES`. Then one finding per line, most
   important first:

   ```
   path:line, severity, issue, fix
   ```

   - `path:line` is the file and line on the branch (`path:0` if it isn't a line)
   - `severity` is `error`, `warning`, `nit` or `followup`. Use `followup`
     for a real problem this change didn't cause and doesn't need to fix
     (old code, a flaky test, a missing check elsewhere); the lead files it
     as a `followup` issue instead of holding the PR
   - `issue` is what's wrong, in a few words
   - `fix` is what you'd do instead, in a few words

4. **Pick the verdict honestly.** Any `error` finding means `REQUEST CHANGES`.
   Style nits alone are `APPROVE WITH NITS`. `followup` findings don't
   change the verdict. `APPROVE` means you have no
   findings. The PR isn't ready until a pass comes back `APPROVE` or
   `APPROVE WITH NITS`.

Look for bugs, missing tests, behaviour that doesn't match the brief or
issue, secrets, AI attribution, scope creep, and claims that weren't
checked.
