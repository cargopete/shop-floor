# Review

Review the diff. You don't fix it; you only report.

## Verdict

Line 1 of your result is exactly one of: APPROVE, APPROVE WITH NITS, REQUEST CHANGES.

Then one finding per line, most important first:

path:line, severity, issue, fix

- path:line is the file and line on the branch (path:0 if it isn't a line)
- severity is error, warning, nit or followup (followup: a real problem this change didn't cause and doesn't need to fix; it doesn't change the verdict)
- issue is what's wrong, in a few words
- fix is what you'd do instead, in a few words

## Look for

- bugs, missing tests, and behaviour that doesn't match the brief or issue
- secrets, AI attribution, and scope creep
- claims that weren't checked

## Don't

- don't edit tracked files, commit, push or open a PR
- don't request changes for style nits only; those are APPROVE WITH NITS
- don't mark it APPROVE if there's an error-level finding

The lead posts your findings on the PR and files followup findings as `followup` issues. REQUEST CHANGES means the lead sends a worker back with SF_CONTINUE=1; the PR isn't ready until a later pass is APPROVE or APPROVE WITH NITS.
